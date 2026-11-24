local GameCfg = require('common.GameCfg')
local QuestSteps = require('common.QuestSteps')
local SignalRouter = require('server.WorldHost.WorldSignalRouter')

local Mgr = { States = {}, Players = {}, Queues = {} }

local function cfg()
    return GameCfg.Quest
end

-- 持久业务在自己的隔离 draft 内记事实，让扣件/扣费/发货与任务进度同键落账。
function Mgr:RecordFact(draft, kind, payload)
    local state = QuestSteps.Restore(cfg().Steps, draft.Extra.quest)
    local counted, advanced = QuestSteps.Apply(cfg().Steps, state, {
        kind = kind, itemId = payload.itemId, category = payload.category, count = payload.count,
        eventId = tostring(draft.SaveMeta.epoch) .. ':' .. payload.eventId,
    })
    if counted then draft.Extra.quest = state end
    return counted, advanced
end

function Mgr:RefreshCommitted(player, data)
    local previous = self:GetState(player)
    if not previous or not data or not data.Inited then return end
    local restored = QuestSteps.Restore(cfg().Steps, data.Extra.quest)
    if restored.step == previous.step and restored.count == previous.count then return end
    self.States[player.UserId] = restored
    local queue = self.Queues[player.UserId]
    if queue and not queue.writing then
        for i = #queue.events, 1, -1 do
            if restored.seen[queue.events[i].eventId] then table.remove(queue.events, i) end
        end
        local tail = QuestSteps.Restore(cfg().Steps, restored)
        for _, fact in ipairs(queue.events) do QuestSteps.Apply(cfg().Steps, tail, fact) end
        queue.tail = #queue.events > 0 and tail or nil
    end
    local nextStep = cfg().Steps[restored.step]
    self:Publish(player, restored.step > previous.step
        and (nextStep and string.format(cfg().NextNotice, nextStep.Text) or cfg().DoneText) or nil)
    if queue and not queue.writing and #queue.events == 0 and queue.leave then
        local leave = queue.leave
        queue.leave = nil
        leave()
    end
end

function Mgr:Send(player, state)
    _G.REUtil:GetRE('QuestState'):FireClient(player, state)
end

function Mgr:GetState(player)
    if player and self.Players[player.UserId] == player then return self.States[player.UserId] end
end

function Mgr:Publish(player, notice)
    local state = self:GetState(player)
    if not state then return end
    local c = cfg()
    local current = c.Steps[state.step]
    local text = QuestSteps.Text(c.Steps, state, c.Title, c.DoneText)
    local ok, err = pcall(function()
        player:SetAttribute('QuestStep', state.step)
        player:SetAttribute('QuestText', text)
    end)
    if not ok then print('[PlayerQuest] 属性发布失败', player.UserId, tostring(err)) end
    self:Send(player, {
        step = state.step, total = #c.Steps, count = state.count, need = current and current.Need or 0,
        text = text, done = current == nil, notice = notice,
    })
end

function Mgr:Notify(kind, player, payload)
    if self.Save and self.PlayerData then
        self:RefreshCommitted(player, self.PlayerData:GetDataInst(player))
    end
    local state = self:GetState(player)
    if not state or type(payload) ~= 'table' then return false end
    local c = cfg()
    if self.Save then
        local queue = self.Queues[player.UserId]
        if queue.leaving then return false end
        local data = self.PlayerData and self.PlayerData:GetDataInst(player)
        if not data and queue and self.Save:Status(player.UserId).loadState == 'ready'
            and queue.data.Player == player then data = queue.data end
        if not data then return false end
        local eventId = payload.eventId
        if type(eventId) ~= 'string' or #eventId < 1 or #eventId > 160 then return false end
        local candidate = QuestSteps.Restore(c.Steps, queue.tail or state)
        local fact = { kind = kind, itemId = payload.itemId, category = payload.category,
            eventId = tostring(data.SaveMeta.epoch) .. ':' .. eventId, count = payload.count }
        if not QuestSteps.Apply(c.Steps, candidate, fact) then return false end
        queue.events[#queue.events + 1] = fact
        queue.tail = candidate
        self:Drain(player)
        return true
    end
    local counted, advanced = QuestSteps.Apply(c.Steps, state, { kind = kind, itemId = payload.itemId,
        category = payload.category, eventId = payload.eventId, count = payload.count })
    if not counted then return false end
    local notice
    if advanced then
        local finished = c.Steps[state.step - 1]
        local nextStep = c.Steps[state.step]
        notice = nextStep and string.format(c.NextNotice, nextStep.Text) or c.DoneText
        print('[PlayerQuest] 完成', player.UserId, 'step=' .. tostring(state.step - 1), finished.Kind, tostring(payload.eventId))
    else
        print('[PlayerQuest] 计数', player.UserId, 'step=' .. tostring(state.step), kind,
            tostring(state.count) .. '/' .. tostring(c.Steps[state.step].Need), tostring(payload.eventId))
    end
    self:Publish(player, notice)
    return true
end

function Mgr:OnPlayerAdded(player)
    if not player or self.Players[player.UserId] == player then return end
    local data = self.PlayerData and self.PlayerData:GetDataInst(player)
    if self.Save and not data then return end
    self.Players[player.UserId] = player
    self.States[player.UserId] = data and QuestSteps.Restore(cfg().Steps, data.Extra.quest) or QuestSteps.New()
    self.Queues[player.UserId] = { player = player, data = data, events = {} }
    self:Publish(player)
end

function Mgr:OnPlayerRemoving(player)
    if player and self.Players[player.UserId] == player then
        self.States[player.UserId], self.Players[player.UserId], self.Queues[player.UserId] = nil, nil, nil
    end
end

function Mgr:Drain(player)
    local queue = player and self.Queues[player.UserId]
    if not queue or queue.player ~= player or queue.writing or #queue.events == 0 then return end
    local status = self.Save:Status(player.UserId)
    if status.autosavePaused or status.loadState == 'failed' then
        queue.failed = true
        local leave = queue.leave
        queue.leave = nil
        if leave then leave() end
        return
    end
    local data = self.PlayerData and self.PlayerData:GetDataInst(player)
    if not data then return end
    local operation = self.Save:NextOperation(player, 'quest-fact')
    if not operation then return end
    local fact, c = queue.events[1], cfg()
    queue.writing = true
    local accepted = self.Save:Execute(player, data, operation, function(draft)
        local state = QuestSteps.Restore(c.Steps, draft.Extra.quest)
        local counted, advanced = QuestSteps.Apply(c.Steps, state, fact)
        draft.Extra.quest = state
        return { counted = counted, advanced = advanced }
    end, function(written, result)
        if self.Queues[player.UserId] ~= queue then return end
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
        local restored = QuestSteps.Restore(c.Steps, data.Extra.quest)
        self.States[player.UserId] = restored
        local notice
        if result.advanced then
            local nextStep = c.Steps[restored.step]
            notice = nextStep and string.format(c.NextNotice, nextStep.Text) or c.DoneText
        end
        print('[PlayerQuest] 任务落账', player.UserId, 'step=' .. restored.step,
            'count=' .. restored.count, fact.eventId)
        self:Publish(player, notice)
        if #queue.events == 0 then queue.tail = nil end
        self:Drain(player)
        if #queue.events == 0 and not queue.writing and queue.leave then
            local leave = queue.leave
            queue.leave = nil
            leave()
        end
    end)
    if not accepted then queue.writing = false end
end

function Mgr:FlushBeforeLeave(player, done)
    local queue = player and self.Queues[player.UserId]
    if not self.Save or not queue or queue.player ~= player or queue.failed
        or self.Save:Status(player.UserId).loadState ~= 'ready'
        or #queue.events == 0 and not queue.writing then return false end
    if self.Save:Status(player.UserId).autosavePaused then
        queue.failed = true
        queue.leave = nil
        print('[PlayerQuest] 保存已暂停，离场放弃未落账事实', player.UserId)
        return false
    end
    queue.leaving, queue.leave = true, done
    self:Drain(player)
    return true
end

function Mgr:Update()
    for _, queue in pairs(self.Queues) do self:Drain(queue.player) end
end

function Mgr.mount(scope, player_tree, opts)
    local player = opts.player
    local session = setmetatable({
        States = {}, Players = {}, Queues = {}, PlayerData = opts.player_data, Save = opts.save,
    }, { __index = Mgr })
    player_tree.quest = session
    session:OnPlayerAdded(player)
    SignalRouter.bind_player(scope, _G.REUtil:GetRE('RequestQuest').OnServerEvent, player, function(actor)
        if _G.REUtil:CheckRECD(actor, 'RequestQuest', 0.5) then return end
        session:OnPlayerAdded(actor)
        session:Publish(actor)
    end)
    scope:subscribe(opts.clock.on_second, function() session:Drain(player) end)
    scope:on_cleanup(function()
        session:OnPlayerRemoving(player)
        if player_tree.quest == session then player_tree.quest = nil end
    end)
    return session
end

return Mgr
