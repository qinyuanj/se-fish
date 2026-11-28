local GameCfg = require('common.game_cfg')
local FishCatch = require('common.fish_catch')
local Records = require('common.records')
local SignalRouter = require('server.world_host.world_signal_router')

---@class PlayerCompendiumHost
---@field queues table<any, any>
---@field last_seq table<any, any>
---@field KIND string
---@field max_queue integer
---@field player_data any
---@field Save any
---@field Quest any
---@field Records any
local Mgr = { queues = {}, last_seq = {}, KIND = 'compendium-land', max_queue = 16 }
local isValidPlayer = SignalRouter.is_valid_player

local function shallow_copy(value)
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

function Mgr:snapshot(player)
    local data = self.player_data and self.player_data:get_data_inst(player)
    local bag = data and data.extra and data.extra.collection or nil
    if not data or not bag or data.load_state ~= 'ready' then
        return { state = data and data.load_state == 'loading' and 'loading' or 'unavailable',
            unlocked = {}, catches = {}, weights = {}, total = 0 }
    end
    ---@type table<string, any>
    local extra = data.extra
    return { unlocked = shallow_copy(bag.unlocked), catches = shallow_copy(bag.catches),
        weights = shallow_copy(bag.weights), total = bag.total or 0, state = 'ready',
        completed = extra.achievements and extra.achievements.final == true }
end

function Mgr:handle(player, payload)
    if not isValidPlayer(player) or not Records.valid_user_id(player.UserId) or type(payload) ~= 'table' then return end
    local seq = payload.seq
    if type(seq) ~= 'number' or seq ~= math.floor(seq) or seq < 1 or seq > 2147483647 then return end
    local last = self.last_seq[player.UserId]
    if last and last.player == player and seq <= last.seq then return end
    self.last_seq[player.UserId] = { player = player, seq = seq }
    ---@type table<string, any>
    local state = self:snapshot(player)
    state.seq = seq
    _G.REUtil:get_re('CompendiumState'):FireClient(player, state)
end

function Mgr:weight(fishId, mult)
    local species = GameCfg.Fish[fishId]
    return species and FishCatch.weight(species, mult) or nil
end

local function apply(draft, event, weight)
    local bag = collection(draft.extra)
    local previous = bag.weights[event.fishId]
    local record = previous == nil or weight > previous
    bag.unlocked[event.fishId] = true
    bag.catches[event.fishId] = (bag.catches[event.fishId] or 0) + 1
    if record then bag.weights[event.fishId] = weight end
    bag.total = bag.total + 1
    return { fishId = event.fishId, weight = weight, best = bag.weights[event.fishId],
        record = record, count = bag.catches[event.fishId], total = bag.total }
end

function Mgr:record_landing(player, event)
    if not player or type(event) ~= 'table' then return false, 'invalid' end
    local weight = self:weight(event.fishId, event.mult)
    if not weight or type(event.reelSerial) ~= 'number'
        or event.reelSerial ~= math.floor(event.reelSerial) or event.reelSerial < 1 then
        return false, 'invalid'
    end
    local queue = self.queues[player.UserId]
    if not queue or queue.player ~= player then
        queue = { player = player, events = {} }
        self.queues[player.UserId] = queue
    end
    for _, queued in ipairs(queue.events) do
        if queued.reelSerial == event.reelSerial then return false, 'duplicate' end
    end
    if #queue.events >= self.max_queue then return false, 'busy' end
    queue.events[#queue.events + 1] = { reelSerial = event.reelSerial,
        fishId = event.fishId, mult = event.mult }
    local mode = self:drain(player)
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

function Mgr:flush_before_leave(player, done)
    local queue = player and self.queues[player.UserId]
    if not queue or queue.player ~= player or (#queue.events == 0 and not queue.writing) then return false end
    queue.leaving, queue.leave = true, done
    self:drain(player)
    finish_leave(queue)
    return true
end

function Mgr:drain(player)
    local queue = self.queues[player.UserId]
    if not queue or queue.player ~= player or queue.writing then return end
    if #queue.events == 0 then finish_leave(queue) return end
    local data = self.player_data and self.player_data:get_data_inst(player)
    if not data then return end
    local onlyEvent = #queue.events == 1
    local event = queue.events[1]
    local operation, mode = self.Save:resolve_request(player, data, self.KIND, event.reelSerial)
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
    local weight = self:weight(event.fishId, event.mult)
    queue.writing = true
    self.Save:execute(player, data, operation, function(draft)
        if self.Quest and self.Quest.record_fact then
            self.Quest:record_fact(draft, 'Land', { itemId = event.fishId,
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
        if self.Quest and self.Quest.refresh_committed then self.Quest:refresh_committed(player, data) end
        if result.record and self.Records then
            self.Records:note_landing(player, result.fishId, result.weight)
        end
        if #queue.events > 0 then
            self:drain(player)
        end
        finish_leave(queue)
    end)
end

function Mgr:update()
    for _, queue in pairs(self.queues) do self:drain(queue.player) end
end

function Mgr:on_player_removing(player)
    if not isValidPlayer(player) then return end
    local queue = self.queues[player.UserId]
    if queue and queue.player == player then self.queues[player.UserId] = nil end
    local request = self.last_seq[player.UserId]
    if request and request.player == player then self.last_seq[player.UserId] = nil end
end

function Mgr.mount(scope, player_tree, opts)
    local player = opts.player
    local session = setmetatable({
        queues = {}, last_seq = {}, player_data = opts.player_data, Save = opts.save,
        Quest = player_tree.quest, Records = opts.records,
    }, { __index = Mgr })
    player_tree.compendium = session
    SignalRouter.bind_player(scope, _G.REUtil:get_re('CompendiumRequest').OnServerEvent, player, function(actor, payload)
        if _G.REUtil:check_recd(actor, 'CompendiumRequest', GameCfg.Compendium.RequestCooldownSec) then return end
        session:handle(actor, payload)
    end)
    scope:subscribe(opts.clock.on_second, function() session:drain(player) end)
    scope:on_cleanup(function()
        session:on_player_removing(player)
        if session.Records and type(session.Records.on_player_removing) == 'function' then
            session.Records:on_player_removing(player)
        end
        if player_tree.compendium == session then player_tree.compendium = nil end
    end)
    return session
end

return Mgr
