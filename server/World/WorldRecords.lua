local GameCfg = require('common.GameCfg')
local Records = require('common.Records')
local Adapter = require('server.Data.RecordsAdapter')

local Mgr = {
    Adapter = Adapter,
    Cache = {},
    Pending = {},
    Reading = {},
    LastSeq = {},
    Stats = { Writes = 0, Merged = 0, Failures = 0, Retries = 0, Dropped = 0, Rejected = 0 },
}

local function cfg() return GameCfg.Records end
local function task() return game:GetService('Task') end

local function now()
    local ok, value = pcall(function() return game:GetService('World'):GetServerTime() end)
    return ok and tonumber(value) or 0
end

local function validPlayerId(player)
    local userId = player and player.UserId
    return Records.ValidUserId(userId)
end

local function reject(self, player, fishId, detail, reason)
    self.Stats.Rejected = self.Stats.Rejected + 1
    print('[WorldRecords] 全服纪录拒收', player and player.UserId, tostring(fishId), detail, tostring(reason))
    return false, reason
end

function Mgr:NoteLanding(player, fishId, weight)
    if type(fishId) ~= 'string' or not GameCfg.Fish[fishId] then
        return reject(self, player, fishId, 'unknown-fish', 'fish')
    end
    if not validPlayerId(player) then
        return reject(self, player, fishId, 'bad-player', 'player')
    end
    local scaled, reason = Records.Scale(weight)
    if not scaled then
        return reject(self, player, fishId, 'weight=' .. tostring(weight), reason)
    end
    local entry = Records.Entry(scaled, player.UserId, player.Name)
    if not entry then return reject(self, player, fishId, 'entry', 'invalid') end
    local pending = self.Pending[fishId]
    if pending and pending.entry then
        self.Stats.Merged = self.Stats.Merged + 1
        if Records.Wins(entry, pending.entry) then pending.entry = entry end
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

function Mgr:Update()
    local current = now()
    for fishId, pending in pairs(self.Pending) do
        if pending.entry and current >= pending.dueAt then self:Flush(fishId) end
    end
end

function Mgr:CacheSet(fishId, entry, failed)
    self.Cache[fishId] = { entry = Records.Valid(entry), at = now(), failed = failed }
end

function Mgr:Fresh(cached)
    local age = now() - (cached.at or 0)
    if cached.failed or not cached.entry then return age < cfg().MissCacheTtlSec end
    return age < cfg().HolderCacheTtlSec
end

function Mgr:Flush(fishId)
    local pending = self.Pending[fishId]
    if not pending or not pending.entry or pending.Writing then return end
    local entry = pending.entry
    pending.entry = nil
    local cached = self.Cache[fishId]
    if cached and not cached.failed and not Records.Wins(entry, cached.entry) then
        if not pending.entry then self.Pending[fishId] = nil end
        return
    end
    pending.Writing = true
    task():Spawn(function()
        local ok, won, saved, kind = self.Adapter:Submit(fishId, function(current)
            if not Records.Wins(entry, current) then return nil end
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
        if not pending.entry or Records.Wins(entry, pending.entry) then pending.entry = entry end
        if pending.attempts > cfg().MaxRetries then
            self.Stats.Dropped = self.Stats.Dropped + 1
            self.Pending[fishId] = nil
            print('[WorldRecords] 全服纪录提交放弃（重试耗尽）', fishId, entry.w, entry.u, tostring(kind))
            return
        end
        self.Stats.Retries = self.Stats.Retries + 1
        pending.dueAt = now() + cfg().RetryDelaySec
        print('[WorldRecords] 全服纪录提交失败，稍后重试', fishId, entry.w, entry.u, tostring(kind))
    end)
end

function Mgr:State(fishId)
    local cached = self.Cache[fishId]
    if not cached then return { state = 'unavailable', fishId = fishId, error = 'cold' } end
    if cached.entry then
        local state = Records.State(cached.entry)
        state.fishId, state.stale = fishId, cached.failed ~= nil
        return state
    end
    if cached.failed then return { state = 'unavailable', fishId = fishId, error = cached.failed } end
    return { state = 'missing', fishId = fishId }
end

function Mgr:Read(fishId, done)
    if type(fishId) ~= 'string' or not GameCfg.Fish[fishId] then
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
        local ok, entry, kind = self.Adapter:Read(fishId)
        local waiters = self.Reading[fishId] or {}
        self.Reading[fishId] = nil
        if ok then
            self:CacheSet(fishId, entry, nil)
        else
            local previous = self.Cache[fishId]
            self:CacheSet(fishId, previous and previous.entry or nil, kind)
            print('[WorldRecords] 全服纪录读取失败', fishId, tostring(kind))
        end
        local state = self:State(fishId)
        for _, callback in ipairs(waiters) do callback(state) end
    end)
end

function Mgr:OnPlayerRemoving(player)
    if player then self.LastSeq[player.UserId] = nil end
end

-- 读到什么回什么（含 'unavailable'），绝不回客户端臆造或本地缓存里已经过期的「确定值」。
-- seq 单调递增才受理：重放/乱序的旧包不产生第二次回包。
function Mgr:Handle(player, payload)
    if not validPlayerId(player) or type(payload) ~= 'table' then return end
    local fishId, seq = payload.fishId, payload.seq
    if type(seq) ~= 'number' or seq ~= math.floor(seq) or seq < 1 or seq > 2147483647 then return end
    local last = self.LastSeq[player.UserId]
    if last and seq <= last then return end
    self.LastSeq[player.UserId] = seq
    self:Read(fishId, function(state)
        state.seq = seq
        self:Reconcile(player, state)
        local re = _G.REUtil and _G.REUtil:GetRE('RecordsState')
        if re then re:FireClient(player, state) end
    end)
end

function Mgr:Reconcile(player, state)
    if state.state == 'unavailable' then return end
    local data = self.PlayerData and self.PlayerData:GetDataInst(player)
    local best = data and data.PersonalBestScaled and data:PersonalBestScaled(state.fishId)
    if not best then return end
    if state.state == 'ok' and best <= state.scaled then return end
    self:NoteLanding(player, state.fishId, Records.Unscale(best))
end

local function managed_connect(scope, signal, callback)
    local connection = signal:Connect(callback)
    scope:on_cleanup(function() connection:Disconnect() end)
end

-- 全服纪录挂在 SharedWorldTree；DataStore UpdateAsync 仍是唯一写入边界。
function Mgr.mount(scope, world, opts)
    local adapter = setmetatable({ Checked = false, Holder = nil }, { __index = Adapter })
    local session = setmetatable({
        Adapter = adapter, Cache = {}, Pending = {}, Reading = {}, LastSeq = {},
        Stats = { Writes = 0, Merged = 0, Failures = 0, Retries = 0, Dropped = 0, Rejected = 0 },
        PlayerData = opts.player_data,
    }, { __index = Mgr })
    world.records = session
    managed_connect(scope, _G.REUtil:GetRE('RecordsRequest').OnServerEvent, function(player, payload)
        if _G.REUtil:CheckRECD(player, 'RecordsRequest', cfg().RequestCooldownSec) then return end
        session:Handle(player, payload)
    end)
    scope:subscribe(world.clock.on_frame, function() session:Update() end)
    scope:on_cleanup(function()
        if world.records == session then world.records = nil end
    end)
    return session
end

return Mgr
