local GameCfg = require('common.game_cfg')
local Records = require('common.records')
local Adapter = require('server.data.records_adapter')
local SignalRouter = require('server.world_host.world_signal_router')

local Mgr = {
    adapter = Adapter,
    cache = {},
    pending = {},
    reading = {},
    last_seq = {},
    last_seq_players = {},
    stats = { writes = 0, merged = 0, failures = 0, retries = 0, dropped = 0, rejected = 0 },
}

local function cfg() return GameCfg.Records end
local function task() return game:GetService('Task') end

local function now()
    local ok, value = pcall(function() return game:GetService('World'):GetServerTime() end)
    return ok and tonumber(value) or 0
end

local isValidPlayer = SignalRouter.is_valid_player

local function validPlayerId(player)
    local userId = isValidPlayer(player) and player.UserId or nil
    return Records.valid_user_id(userId)
end

local function reject(self, player, fishId, detail, reason)
    self.stats.rejected = self.stats.rejected + 1
    print('[WorldRecords] 全服纪录拒收', player and player.UserId, tostring(fishId), detail, tostring(reason))
    return false, reason
end

function Mgr:note_landing(player, fishId, weight)
    if type(fishId) ~= 'string' or not GameCfg.Fish[fishId] then
        return reject(self, player, fishId, 'unknown-fish', 'fish')
    end
    if not validPlayerId(player) then
        return reject(self, player, fishId, 'bad-player', 'player')
    end
    local scaled, reason = Records.scale(weight)
    if not scaled then
        return reject(self, player, fishId, 'weight=' .. tostring(weight), reason)
    end
    local entry = Records.entry(scaled, player.UserId, player.Name)
    if not entry then return reject(self, player, fishId, 'entry', 'invalid') end
    local pending = self.pending[fishId]
    if pending and pending.entry then
        self.stats.merged = self.stats.merged + 1
        if Records.wins(entry, pending.entry) then pending.entry = entry end
        return true, 'merged'
    end
    if pending then
        pending.entry, pending.attempts = entry, 0
        pending.dueAt = now() + cfg().FlushIntervalSec
        return true, 'queued'
    end
    self.pending[fishId] = { entry = entry, attempts = 0, dueAt = now() + cfg().FlushIntervalSec }
    return true, 'queued'
end

function Mgr:update()
    local current = now()
    for fishId, pending in pairs(self.pending) do
        if pending.entry and current >= pending.dueAt then self:flush(fishId) end
    end
end

function Mgr:cache_set(fishId, entry, failed)
    self.cache[fishId] = { entry = Records.valid(entry), at = now(), failed = failed }
end

function Mgr:fresh(cached)
    local age = now() - (cached.at or 0)
    if cached.failed or not cached.entry then return age < cfg().MissCacheTtlSec end
    return age < cfg().HolderCacheTtlSec
end

function Mgr:flush(fishId)
    local pending = self.pending[fishId]
    if not pending or not pending.entry or pending.writing then return end
    local entry = pending.entry
    pending.entry = nil
    local cached = self.cache[fishId]
    if cached and not cached.failed and not Records.wins(entry, cached.entry) then
        if not pending.entry then self.pending[fishId] = nil end
        return
    end
    pending.writing = true
    task():Spawn(function()
        local ok, won, saved, kind = self.adapter:Submit(fishId, function(current)
            if not Records.wins(entry, current) then return nil end
            return entry
        end)
        pending.writing = false
        if ok then
            self.stats.writes = self.stats.writes + (won and 1 or 0)
            pending.attempts = 0
            if saved then self:cache_set(fishId, saved, nil) end
            if pending.entry then
                pending.dueAt = now() + cfg().FlushIntervalSec
            else
                self.pending[fishId] = nil
            end
            return
        end
        self.stats.failures = self.stats.failures + 1
        pending.attempts = pending.attempts + 1
        if not pending.entry or Records.wins(entry, pending.entry) then pending.entry = entry end
        if pending.attempts > cfg().MaxRetries then
            self.stats.dropped = self.stats.dropped + 1
            self.pending[fishId] = nil
            print('[WorldRecords] 全服纪录提交放弃（重试耗尽）', fishId, entry.w, entry.u, tostring(kind))
            return
        end
        self.stats.retries = self.stats.retries + 1
        pending.dueAt = now() + cfg().RetryDelaySec
        print('[WorldRecords] 全服纪录提交失败，稍后重试', fishId, entry.w, entry.u, tostring(kind))
    end)
end

function Mgr:state(fishId)
    local cached = self.cache[fishId]
    if not cached then return { state = 'unavailable', fishId = fishId, error = 'cold' } end
    if cached.entry then
        local state = Records.state(cached.entry)
        state.fishId, state.stale = fishId, cached.failed ~= nil
        return state
    end
    if cached.failed then return { state = 'unavailable', fishId = fishId, error = cached.failed } end
    return { state = 'missing', fishId = fishId }
end

function Mgr:read(fishId, done)
    if type(fishId) ~= 'string' or not GameCfg.Fish[fishId] then
        if done then done({ state = 'unavailable', fishId = fishId, error = 'unknown-fish' }) end
        return
    end
    local cached = self.cache[fishId]
    if cached and self:fresh(cached) then
        if done then done(self:state(fishId)) end
        return
    end
    local waiting = self.reading[fishId]
    if waiting then
        if done then waiting[#waiting + 1] = done end
        return
    end
    self.reading[fishId] = done and { done } or {}
    task():Spawn(function()
        local ok, entry, kind = self.adapter:read(fishId)
        local waiters = self.reading[fishId] or {}
        self.reading[fishId] = nil
        if ok then
            self:cache_set(fishId, entry, nil)
        else
            local previous = self.cache[fishId]
            self:cache_set(fishId, previous and previous.entry or nil, kind)
            print('[WorldRecords] 全服纪录读取失败', fishId, tostring(kind))
        end
        local state = self:state(fishId)
        for _, callback in ipairs(waiters) do callback(state) end
    end)
end

function Mgr:on_player_removing(player)
    if isValidPlayer(player) then
        self.last_seq[player.UserId] = nil
        if self.last_seq_players then self.last_seq_players[player.UserId] = nil end
    end
end

-- 读到什么回什么（含 'unavailable'），绝不回客户端臆造或本地缓存里已经过期的「确定值」。
-- seq 单调递增才受理：重放/乱序的旧包不产生第二次回包。
function Mgr:handle(player, payload)
    if not validPlayerId(player) or type(payload) ~= 'table' then return end
    local fishId, seq = payload.fishId, payload.seq
    if type(seq) ~= 'number' or seq ~= math.floor(seq) or seq < 1 or seq > 2147483647 then return end
    local last = self.last_seq[player.UserId]
    local owner = self.last_seq_players and self.last_seq_players[player.UserId]
    if last and (owner == nil or owner == player) and seq <= last then return end
    self.last_seq[player.UserId] = seq
    if self.last_seq_players then self.last_seq_players[player.UserId] = player end
    self:read(fishId, function(state)
        state.seq = seq
        self:reconcile(player, state)
        local re = _G.REUtil and _G.REUtil:get_re('RecordsState')
        if re then re:FireClient(player, state) end
    end)
end

function Mgr:reconcile(player, state)
    if state.state == 'unavailable' then return end
    local data = self.player_data and self.player_data:get_data_inst(player)
    local best = data and data.PersonalBestScaled and data:PersonalBestScaled(state.fishId)
    if not best then return end
    if state.state == 'ok' and best <= state.scaled then return end
    self:note_landing(player, state.fishId, Records.unscale(best))
end

function Mgr.mount(scope, world, opts)
    local adapter = setmetatable({ checked = false, holder = nil }, { __index = Adapter })
    local session = setmetatable({
        adapter = adapter, cache = {}, pending = {}, reading = {}, last_seq = {}, last_seq_players = {},
        stats = { writes = 0, merged = 0, failures = 0, retries = 0, dropped = 0, rejected = 0 },
        player_data = opts.player_data,
    }, { __index = Mgr })
    world.records = session
    SignalRouter.bind_world(scope, _G.REUtil:get_re('RecordsRequest').OnServerEvent, session, function(player, payload)
        if _G.REUtil:check_recd(player, 'RecordsRequest', cfg().RequestCooldownSec) then return end
        session:handle(player, payload)
    end)
    scope:subscribe(world.clock.on_second, function() session:update() end)
    scope:on_cleanup(function()
        session.last_seq = {}
        session.last_seq_players = {}
        if world.records == session then world.records = nil end
    end)
    return session
end

return Mgr
