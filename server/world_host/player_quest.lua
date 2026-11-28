local GameCfg = require('common.game_cfg')
local QuestSteps = require('common.quest_steps')
local SignalRouter = require('server.world_host.world_signal_router')

---@class PlayerQuestHost
---@field States table<any, any>
---@field Players table<any, any>
---@field queues table<any, any>
---@field Save any
---@field player_data any
local Mgr = { States = {}, Players = {}, queues = {} }

local function cfg()
    return GameCfg.Quest
end

-- 持久业务在自己的隔离 draft 内记事实，让扣件/扣费/发货与任务进度同键落账。
function Mgr:record_fact(draft, kind, payload)
    local state = QuestSteps.restore(cfg().Steps, draft.extra.quest)
    local counted, advanced = QuestSteps.apply(cfg().Steps, state, {
        kind = kind, itemId = payload.itemId, category = payload.category, count = payload.count,
        eventId = tostring(draft.save_meta.epoch) .. ':' .. payload.eventId,
    })
    if counted then draft.extra.quest = state end
    return counted, advanced
end

function Mgr:refresh_committed(player, data)
    local previous = self:get_state(player)
    if not previous or not data or not data.inited then return end
    local restored = QuestSteps.restore(cfg().Steps, data.extra.quest)
    if restored.step == previous.step and restored.count == previous.count then return end
    self.States[player.UserId] = restored
    local queue = self.queues[player.UserId]
    if queue and not queue.writing then
        for i = #queue.events, 1, -1 do
            if restored.seen[queue.events[i].eventId] then table.remove(queue.events, i) end
        end
        local tail = QuestSteps.restore(cfg().Steps, restored)
        for _, fact in ipairs(queue.events) do QuestSteps.apply(cfg().Steps, tail, fact) end
        queue.tail = #queue.events > 0 and tail or nil
    end
    local nextStep = cfg().Steps[restored.step]
    self:publish(player, restored.step > previous.step
        and (nextStep and string.format(cfg().NextNotice, nextStep.Text) or cfg().DoneText) or nil)
    if queue and not queue.writing and #queue.events == 0 and queue.leave then
        local leave = queue.leave
        queue.leave = nil
        leave()
    end
end

function Mgr:send(player, state)
    _G.REUtil:get_re('QuestState'):FireClient(player, state)
end

function Mgr:get_state(player)
    if player and self.Players[player.UserId] == player then return self.States[player.UserId] end
end

function Mgr:publish(player, notice)
    local state = self:get_state(player)
    if not state then return end
    local c = cfg()
    local current = c.Steps[state.step]
    local text = QuestSteps.text(c.Steps, state, c.Title, c.DoneText)
    local ok, err = pcall(function()
        player:SetAttribute('QuestStep', state.step)
        player:SetAttribute('QuestText', text)
    end)
    if not ok then print('[PlayerQuest] 属性发布失败', player.UserId, tostring(err)) end
    self:send(player, {
        step = state.step, total = #c.Steps, count = state.count, need = current and current.Need or 0,
        text = text, done = current == nil, notice = notice,
    })
end

-- 有 Save：事件先入队再 drain，由 drain 在隔离 draft 上落库。
local function queue_fact(self, kind, player, payload, state)
    local c = cfg()
    local queue = self.queues[player.UserId]
    if queue.leaving then return false end
    local data = self.player_data and self.player_data:get_data_inst(player)
    if not data and queue and self.Save:status(player.UserId).loadState == 'ready'
        and queue.data.Player == player then data = queue.data end
    if not data then return false end
    local event_id = payload.eventId
    if type(event_id) ~= 'string' or #event_id < 1 or #event_id > 160 then return false end
    local candidate = QuestSteps.restore(c.Steps, queue.tail or state)
    local fact = { kind = kind, itemId = payload.itemId, category = payload.category,
        eventId = tostring(data.save_meta.epoch) .. ':' .. event_id, count = payload.count }
    if not QuestSteps.apply(c.Steps, candidate, fact) then return false end
    queue.events[#queue.events + 1] = fact
    queue.tail = candidate
    self:drain(player)
    return true
end

-- 进度日志：完成一步打完成日志，否则打计数日志；返回要下发的 notice。
local function log_quest_progress(kind, player, payload, state, c, advanced)
    if not advanced then
        print('[PlayerQuest] 计数', player.UserId, 'step=' .. tostring(state.step), kind,
            tostring(state.count) .. '/' .. tostring(c.Steps[state.step].Need), tostring(payload.eventId))
        return nil
    end
    local finished = c.Steps[state.step - 1]
    local next_step = c.Steps[state.step]
    print('[PlayerQuest] 完成', player.UserId, 'step=' .. tostring(state.step - 1), finished.Kind, tostring(payload.eventId))
    return next_step and string.format(c.NextNotice, next_step.Text) or c.DoneText
end

-- 无 Save：直接改内存 state 并发布，不落库。
local function apply_inline(self, kind, player, payload, state, c)
    local counted, advanced = QuestSteps.apply(c.Steps, state, { kind = kind, itemId = payload.itemId,
        category = payload.category, eventId = payload.eventId, count = payload.count })
    if not counted then return false end
    local notice = log_quest_progress(kind, player, payload, state, c, advanced)
    self:publish(player, notice)
    return true
end

function Mgr:notify(kind, player, payload)
    if self.Save and self.player_data then
        self:refresh_committed(player, self.player_data:get_data_inst(player))
    end
    local state = self:get_state(player)
    if not state or type(payload) ~= 'table' then return false end
    local c = cfg()
    if self.Save then return queue_fact(self, kind, player, payload, state) end
    return apply_inline(self, kind, player, payload, state, c)
end

function Mgr:on_player_added(player)
    if not player or self.Players[player.UserId] == player then return end
    local data = self.player_data and self.player_data:get_data_inst(player)
    if self.Save and not data then return end
    self.Players[player.UserId] = player
    self.States[player.UserId] = data and QuestSteps.restore(cfg().Steps, data.extra.quest) or QuestSteps.new()
    self.queues[player.UserId] = { player = player, data = data, events = {} }
    self:publish(player)
end

function Mgr:on_player_removing(player)
    if player and self.Players[player.UserId] == player then
        self.States[player.UserId], self.Players[player.UserId], self.queues[player.UserId] = nil, nil, nil
    end
end

function Mgr:drain(player)
    local queue = player and self.queues[player.UserId]
    if not queue or queue.player ~= player or queue.writing or #queue.events == 0 then return end
    local status = self.Save:status(player.UserId)
    if status.autosavePaused or status.loadState == 'failed' then
        queue.failed = true
        local leave = queue.leave
        queue.leave = nil
        if leave then leave() end
        return
    end
    local data = self.player_data and self.player_data:get_data_inst(player)
    if not data then return end
    local operation = self.Save:next_operation(player, 'quest-fact')
    if not operation then return end
    local fact, c = queue.events[1], cfg()
    queue.writing = true
    local accepted = self.Save:execute(player, data, operation, function(draft)
        local state = QuestSteps.restore(c.Steps, draft.extra.quest)
        local counted, advanced = QuestSteps.apply(c.Steps, state, fact)
        draft.extra.quest = state
        return { counted = counted, advanced = advanced }
    end, function(written, result)
        if self.queues[player.UserId] ~= queue then return end
        queue.writing = false
        if not written then
            print('[PlayerQuest] 任务未落账', player.UserId, tostring(result))
            queue.failed = true
            local leave = queue.leave
            queue.leave = nil
            if leave then leave() end
            return
        end
        table.remove(queue.events, 1)
        local restored = QuestSteps.restore(c.Steps, data.extra.quest)
        self.States[player.UserId] = restored
        local notice
        if result.advanced then
            local nextStep = rawget(c.Steps, restored.step)
            notice = nextStep and string.format(c.NextNotice, nextStep.Text) or c.DoneText
        end
        print('[PlayerQuest] 任务落账', player.UserId, 'step=' .. restored.step,
            'count=' .. restored.count, fact.eventId)
        self:publish(player, notice)
        if #queue.events == 0 then queue.tail = nil end
        self:drain(player)
        if #queue.events == 0 and not queue.writing and queue.leave then
            local leave = queue.leave
            queue.leave = nil
            leave()
        end
    end)
    if not accepted then queue.writing = false end
end

function Mgr:flush_before_leave(player, done)
    local queue = player and self.queues[player.UserId]
    if not self.Save or not queue or queue.player ~= player or queue.failed
        or self.Save:status(player.UserId).loadState ~= 'ready'
        or #queue.events == 0 and not queue.writing then return false end
    if self.Save:status(player.UserId).autosavePaused then
        queue.failed = true
        queue.leave = nil
        print('[PlayerQuest] 保存已暂停，离场放弃未落账事实', player.UserId)
        return false
    end
    queue.leaving, queue.leave = true, done
    self:drain(player)
    return true
end

function Mgr:update()
    for _, queue in pairs(self.queues) do self:drain(queue.player) end
end

function Mgr.mount(scope, player_tree, opts)
    local player = opts.player
    local session = setmetatable({
        States = {}, Players = {}, queues = {}, player_data = opts.player_data, Save = opts.save,
    }, { __index = Mgr })
    player_tree.quest = session
    session:on_player_added(player)
    SignalRouter.bind_player(scope, _G.REUtil:get_re('RequestQuest').OnServerEvent, player, function(actor)
        if _G.REUtil:check_recd(actor, 'RequestQuest', 0.5) then return end
        session:on_player_added(actor)
        session:publish(actor)
    end)
    scope:subscribe(opts.clock.on_second, function() session:drain(player) end)
    scope:on_cleanup(function()
        session:on_player_removing(player)
        if player_tree.quest == session then player_tree.quest = nil end
    end)
    return session
end

return Mgr
