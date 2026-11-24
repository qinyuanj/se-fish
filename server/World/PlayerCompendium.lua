local GameCfg = require('common.GameCfg')
local FishCatch = require('common.FishCatch')
local Records = require('common.Records')

local Mgr = { Queues = {}, LastSeq = {}, KIND = 'compendium-land', MaxQueue = 16 }
local bound_signals = setmetatable({}, { __mode = 'k' })

local function isValidPlayer(player)
    local kind = type(player)
    return (kind == 'table' or kind == 'userdata') and player.UserId ~= nil
end

local function registerPlayerSignal(scope, signal, player, fn)
    if not signal then return end
    local slot = bound_signals[signal]
    if not slot then
        local handlers = {}
        local connection = signal:Connect(function(actor, ...)
            if not isValidPlayer(actor) then return end
            local entry = handlers[actor.UserId]
            if entry and entry.player == actor then
                entry.fn(actor, ...)
            end
        end)
        slot = { connection = connection, handlers = handlers }
        bound_signals[signal] = slot
    end
    local uid = player.UserId
    local entry = { player = player, fn = fn }
    slot.handlers[uid] = entry
    scope:on_cleanup(function()
        if slot.handlers[uid] == entry then
            slot.handlers[uid] = nil
        end
    end)
end

local function copy(value)
    local out = {}
    for k, v in pairs(value or {}) do out[k] = v end
    return out
end

local function collection(extra)
    local bag = extra.collection
    bag.weights = bag.weights or {}
    bag.unlocked = bag.unlocked or {}
    bag.catches = bag.catches or {}
    bag.total = bag.total or 0
    return bag
end

function Mgr:Snapshot(player)
    local data = self.PlayerData and self.PlayerData:GetDataInst(player)
    local bag = data and data.Extra and data.Extra.collection or nil
    if not bag or data.LoadState ~= 'ready' then
        return { state = data and data.LoadState == 'loading' and 'loading' or 'unavailable',
            unlocked = {}, catches = {}, weights = {}, total = 0 }
    end
    return { unlocked = copy(bag.unlocked), catches = copy(bag.catches),
        weights = copy(bag.weights), total = bag.total or 0, state = 'ready',
        completed = data.Extra.achievements and data.Extra.achievements.final == true }
end

function Mgr:Handle(player, payload)
    if not isValidPlayer(player) or not Records.ValidUserId(player.UserId) or type(payload) ~= 'table' then return end
    local seq = payload.seq
    if type(seq) ~= 'number' or seq ~= math.floor(seq) or seq < 1 or seq > 2147483647 then return end
    local last = self.LastSeq[player.UserId]
    if last and last.player == player and seq <= last.seq then return end
    self.LastSeq[player.UserId] = { player = player, seq = seq }
    local state = self:Snapshot(player)
    state.seq = seq
    _G.REUtil:GetRE('CompendiumState'):FireClient(player, state)
end

function Mgr:Weight(fishId, mult)
    local species = GameCfg.Fish[fishId]
    return species and FishCatch.Weight(species, mult) or nil
end

local function apply(draft, event, weight)
    local bag = collection(draft.Extra)
    local previous = bag.weights[event.fishId]
    local record = previous == nil or weight > previous
    bag.unlocked[event.fishId] = true
    bag.catches[event.fishId] = (bag.catches[event.fishId] or 0) + 1
    if record then bag.weights[event.fishId] = weight end
    bag.total = bag.total + 1
    return { fishId = event.fishId, weight = weight, best = bag.weights[event.fishId],
        record = record, count = bag.catches[event.fishId], total = bag.total }
end

function Mgr:RecordLanding(player, event)
    if not player or type(event) ~= 'table' then return false, 'invalid' end
    local weight = self:Weight(event.fishId, event.mult)
    if not weight or type(event.reelSerial) ~= 'number'
        or event.reelSerial ~= math.floor(event.reelSerial) or event.reelSerial < 1 then
        return false, 'invalid'
    end
    local queue = self.Queues[player.UserId]
    if not queue or queue.player ~= player then
        queue = { player = player, events = {} }
        self.Queues[player.UserId] = queue
    end
    for _, queued in ipairs(queue.events) do
        if queued.reelSerial == event.reelSerial then return false, 'duplicate' end
    end
    if #queue.events >= self.MaxQueue then return false, 'busy' end
    queue.events[#queue.events + 1] = { reelSerial = event.reelSerial,
        fishId = event.fishId, mult = event.mult }
    local mode = self:Drain(player)
    if mode == 'replay' or mode == 'invalid' then return false, mode end
    return true
end

local function finish_leave(queue)
    if queue and queue.leaving and not queue.writing and #queue.events == 0 then
        local done = queue.leave
        queue.leave = nil
        if done then done() end
    end
end

function Mgr:FlushBeforeLeave(player, done)
    local queue = player and self.Queues[player.UserId]
    if not queue or queue.player ~= player or (#queue.events == 0 and not queue.writing) then return false end
    queue.leaving, queue.leave = true, done
    self:Drain(player)
    finish_leave(queue)
    return true
end

function Mgr:Drain(player)
    local queue = self.Queues[player.UserId]
    if not queue or queue.player ~= player or queue.writing then return end
    if #queue.events == 0 then finish_leave(queue) return end
    local data = self.PlayerData and self.PlayerData:GetDataInst(player)
    if not data then return end
    local onlyEvent = #queue.events == 1
    local event = queue.events[1]
    local operation, mode = self.Save:ResolveRequest(player, data, self.KIND, event.reelSerial)
    if not operation then
        if mode ~= 'pending' then
            table.remove(queue.events, 1)
            finish_leave(queue)
            return onlyEvent and mode or nil
        end
        return
    end
    table.remove(queue.events, 1)
    if mode == 'replay' then finish_leave(queue) return onlyEvent and 'replay' or nil end
    local weight = self:Weight(event.fishId, event.mult)
    queue.writing = true
    self.Save:Execute(player, data, operation, function(draft)
        if self.Quest and self.Quest.RecordFact then
            self.Quest:RecordFact(draft, 'Land', { itemId = event.fishId,
                eventId = 'reel:' .. tostring(event.reelSerial) })
        end
        return apply(draft, event, weight)
    end, function(written, result)
        queue.writing = false
        if not written then
            finish_leave(queue)
            print('[PlayerCompendium] 图鉴未落账', player.UserId, event.fishId, tostring(result))
            return
        end
        print('[PlayerCompendium] 图鉴', player.UserId, result.fishId,
            'weight=' .. tostring(result.weight), 'best=' .. tostring(result.best),
            'count=' .. tostring(result.count), 'total=' .. tostring(result.total))
        if self.Quest and self.Quest.RefreshCommitted then self.Quest:RefreshCommitted(player, data) end
        if result.record and self.Records then
            self.Records:NoteLanding(player, result.fishId, result.weight)
        end
        if #queue.events > 0 then
            self:Drain(player)
        end
        finish_leave(queue)
    end)
end

function Mgr:Update()
    for _, queue in pairs(self.Queues) do self:Drain(queue.player) end
end

function Mgr:OnPlayerRemoving(player)
    if not isValidPlayer(player) then return end
    local queue = self.Queues[player.UserId]
    if queue and queue.player == player then self.Queues[player.UserId] = nil end
    local request = self.LastSeq[player.UserId]
    if request and request.player == player then self.LastSeq[player.UserId] = nil end
end

-- 图鉴会话由 PlayerTree Stage 1 拥有；全局 RE 按信号对象单次绑定并按 UserId O(1) 路由，
-- 队列由上岸与落账回调事件驱动，仅以秒级心跳兜底重试。
function Mgr.mount(scope, player_tree, opts)
    local player = opts.player
    local session = setmetatable({
        Queues = {}, LastSeq = {}, PlayerData = opts.player_data, Save = opts.save,
        Quest = player_tree.quest, Records = opts.records,
    }, { __index = Mgr })
    player_tree.compendium = session
    registerPlayerSignal(scope, _G.REUtil:GetRE('CompendiumRequest').OnServerEvent, player, function(actor, payload)
        if _G.REUtil:CheckRECD(actor, 'CompendiumRequest', GameCfg.Compendium.RequestCooldownSec) then return end
        session:Handle(actor, payload)
    end)
    scope:subscribe(opts.clock.on_second, function() session:Drain(player) end)
    scope:on_cleanup(function()
        session:OnPlayerRemoving(player)
        if session.Records and type(session.Records.OnPlayerRemoving) == 'function' then
            session.Records:OnPlayerRemoving(player)
        end
        if player_tree.compendium == session then player_tree.compendium = nil end
    end)
    return session
end

return Mgr
