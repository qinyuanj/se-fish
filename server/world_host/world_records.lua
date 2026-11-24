local game_cfg = require('common.game_cfg')
local records = require('common.records')
local adapter = require('server.data.records_adapter')
local signal_router = require('server.world_host.world_signal_router')

local mgr = {
    adapter = adapter,
    Cache = {},
    Pending = {},
    Reading = {},
    LastSeq = {},
    LastSeqPlayers = {},
    Stats = { Writes = 0, Merged = 0, Failures = 0, Retries = 0, Dropped = 0, Rejected = 0 },
}

local function cfg() return game_cfg.records end
local function task() return game:GetService('Task') end

local function now()
    local ok, value = pcall(function() return game:GetService('World'):GetServerTime() end)
    return ok and tonumber(value) or 0
end

local isValidPlayer = signal_router.is_valid_player

local function validPlayerId(player)
    local userId = isValidPlayer(player) and player.UserId or nil
    return records.ValidUserId(userId)
end

local function reject(self, player, fishId, detail, reason)
    self.Stats.Rejected = self.Stats.Rejected + 1
    print('[world_records] 全服纪录拒收', player and player.UserId, tostring(fishId), detail, tostring(reason))
    return false, reason
end

function mgr:NoteLanding(player, fishId, weight)
    if type(fishId) ~= 'string' or not game_cfg.Fish[fishId] then
        return reject(self, player, fishId, 'unknown-fish', 'fish')
    end
    if not validPlayerId(player) then
        return reject(self, player, fishId, 'bad-player', 'player')
    end
    local scaled, reason = records.Scale(weight)
    if not scaled then
        return reject(self, player, fishId, 'weight=' .. tostring(weight), reason)
    end
    local entry = records.Entry(scaled, player.UserId, player.Name)
    if not entry then return reject(self, player, fishId, 'entry', 'invalid') end
    local pending = self.Pending[fishId]
    if pending and pending.entry then
        self.Stats.Merged = self.Stats.Merged + 1
        if records.Wins(entry, pending.entry) then pending.entry = entry end
        return true, 'merged'
    end
    if pending then
        pending.entry, pending.attempts = entry, 0
        pending.dueAt = now() + cfg().FlushIntervalSec
        return true, 'queued'
    end
    self.Pending[fishId] = { entry = entry, attempts = 0, dueAt = now() + cfg().FlushIntervalSec }
    return true, 'queued'
end

function mgr:Update()
    local current = now()
    for fishId, pending in pairs(self.Pending) do
        if pending.entry and current >= pending.dueAt then self:Flush(fishId) end
    end
end

function mgr:CacheSet(fishId, entry, failed)
    self.Cache[fishId] = { entry = records.Valid(entry), at = now(), failed = failed }
end

function mgr:Fresh(cached)
    local age = now() - (cached.at or 0)
    if cached.failed or not cached.entry then return age < cfg().MissCacheTtlSec end
    return age < cfg().HolderCacheTtlSec
end

function mgr:Flush(fishId)
    local pending = self.Pending[fishId]
    if not pending or not pending.entry or pending.Writing then return end
    local entry = pending.entry
    pending.entry = nil
    local cached = self.Cache[fishId]
    if cached and not cached.failed and not records.Wins(entry, cached.entry) then
        if not pending.entry then self.Pending[fishId] = nil end
        return
    end
    pending.Writing = true
    task():Spawn(function()
        local ok, won, saved, kind = self.adapter:Submit(fishId, function(current)
            if not records.Wins(entry, current) then return nil end
            return entry
        end)
        pending.Writing = false
        if ok then
            self.Stats.Writes = self.Stats.Writes + (won and 1 or 0)
            pending.attempts = 0
            if saved then self:CacheSet(fishId, saved, nil) end
            if pending.entry then
                pending.dueAt = now() + cfg().FlushIntervalSec
            else
                self.Pending[fishId] = nil
            end
            return
        end
        self.Stats.Failures = self.Stats.Failures + 1
        pending.attempts = pending.attempts + 1
        if not pending.entry or records.Wins(entry, pending.entry) then pending.entry = entry end
        if pending.attempts > cfg().MaxRetries then
            self.Stats.Dropped = self.Stats.Dropped + 1
            self.Pending[fishId] = nil
            print('[world_records] 全服纪录提交放弃（重试耗尽）', fishId, entry.w, entry.u, tostring(kind))
            return
        end
        self.Stats.Retries = self.Stats.Retries + 1
        pending.dueAt = now() + cfg().RetryDelaySec
        print('[world_records] 全服纪录提交失败，稍后重试', fishId, entry.w, entry.u, tostring(kind))
    end)
end

function mgr:State(fishId)
    local cached = self.Cache[fishId]
    if not cached then return { state = 'unavailable', fishId = fishId, error = 'cold' } end
    if cached.entry then
        local state = records.State(cached.entry)
        state.fishId, state.stale = fishId, cached.failed ~= nil
        return state
    end
    if cached.failed then return { state = 'unavailable', fishId = fishId, error = cached.failed } end
    return { state = 'missing', fishId = fishId }
end

function mgr:Read(fishId, done)
    if type(fishId) ~= 'string' or not game_cfg.Fish[fishId] then
        if done then done({ state = 'unavailable', fishId = fishId, error = 'unknown-fish' }) end
        return
    end
    local cached = self.Cache[fishId]
    if cached and self:Fresh(cached) then
        if done then done(self:State(fishId)) end
        return
    end
    local waiting = self.Reading[fishId]
    if waiting then
        if done then waiting[#waiting + 1] = done end
        return
    end
    self.Reading[fishId] = done and { done } or {}
    task():Spawn(function()
        local ok, entry, kind = self.adapter:Read(fishId)
        local waiters = self.Reading[fishId] or {}
        self.Reading[fishId] = nil
        if ok then
            self:CacheSet(fishId, entry, nil)
        else
            local previous = self.Cache[fishId]
            self:CacheSet(fishId, previous and previous.entry or nil, kind)
            print('[world_records] 全服纪录读取失败', fishId, tostring(kind))
        end
        local state = self:State(fishId)
        for _, callback in ipairs(waiters) do callback(state) end
    end)
end

function mgr:OnPlayerRemoving(player)
    if isValidPlayer(player) then
        self.LastSeq[player.UserId] = nil
        if self.LastSeqPlayers then self.LastSeqPlayers[player.UserId] = nil end
    end
end

-- 读到什么回什么（含 'unavailable'），绝不回客户端臆造或本地缓存里已经过期的「确定值」。
-- seq 单调递增才受理：重放/乱序的旧包不产生第二次回包。
function mgr:Handle(player, payload)
    if not validPlayerId(player) or type(payload) ~= 'table' then return end
    local fishId, seq = payload.fishId, payload.seq
    if type(seq) ~= 'number' or seq ~= math.floor(seq) or seq < 1 or seq > 2147483647 then return end
    local last = self.LastSeq[player.UserId]
    local owner = self.LastSeqPlayers and self.LastSeqPlayers[player.UserId]
    if last and (owner == nil or owner == player) and seq <= last then return end
    self.LastSeq[player.UserId] = seq
    if self.LastSeqPlayers then self.LastSeqPlayers[player.UserId] = player end
    self:Read(fishId, function(state)
        state.seq = seq
        self:Reconcile(player, state)
        local re = _G.re_util and _G.re_util:GetRE('RecordsState')
        if re then re:FireClient(player, state) end
    end)
end

function mgr:Reconcile(player, state)
    if state.state == 'unavailable' then return end
    local data = self.player_data and self.player_data:GetDataInst(player)
    local best = data and data.PersonalBestScaled and data:PersonalBestScaled(state.fishId)
    if not best then return end
    if state.state == 'ok' and best <= state.scaled then return end
    self:NoteLanding(player, state.fishId, records.Unscale(best))
end

function mgr.mount(scope, world, opts)
    local adapter = setmetatable({ Checked = false, Holder = nil }, { __index = adapter })
    local session = setmetatable({
        adapter = adapter, Cache = {}, Pending = {}, Reading = {}, LastSeq = {}, LastSeqPlayers = {},
        Stats = { Writes = 0, Merged = 0, Failures = 0, Retries = 0, Dropped = 0, Rejected = 0 },
        player_data = opts.player_data,
    }, { __index = mgr })
    world.records = session
    signal_router.bind_world(scope, _G.re_util:GetRE('RecordsRequest').OnServerEvent, session, function(player, payload)
        if _G.re_util:CheckRECD(player, 'RecordsRequest', cfg().RequestCooldownSec) then return end
        session:Handle(player, payload)
    end)
    scope:subscribe(world.clock.on_second, function() session:Update() end)
    scope:on_cleanup(function()
        session.LastSeq = {}
        session.LastSeqPlayers = {}
        if world.records == session then world.records = nil end
    end)
    return session
end

return mgr
