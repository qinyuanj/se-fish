local game_cfg = require('common.game_cfg')
local signal_router = require('server.world_host.world_signal_router')

local mgr = { States = {}, Requested = {} }
local isValidPlayer = signal_router.is_valid_player

local function cfg()
    return game_cfg.Story
end

function mgr:Now()
    self.World = self.World or game:GetService('World')
    return self.World:GetServerTime()
end

function mgr:Fallback(player, state, reason)
    if state.phase ~= 'pending' then return end
    state.phase = 'fallback'
    state.deadline = nil
    print('[player_story] 降级 开场剧情', player.UserId, '原因=' .. tostring(reason),
        '影响=展示可读对话，正式剧情表现留待资源验收')
    self:SendFallback(player)
end

function mgr:SendFallback(player)
    _G.re_util:GetRE('StoryNotice'):FireClient(player, {
        text = cfg().FallbackText, lines = cfg().Lines or { cfg().FallbackText },
        readKey = cfg().ReadKey or 'opening', title = cfg().Title or '欢迎来到钓场',
    })
end

function mgr:Begin(player)
    if not player then return end
    self.Requested[player.UserId] = player
    local data = self.player_data and self.player_data:GetDataInst(player)
    if self.Save and not data then return end
    local readKey = cfg().ReadKey or 'opening'
    if data and data.Extra.story.read and data.Extra.story.read[readKey] then
        self.Requested[player.UserId] = nil
        return
    end
    local previous = self.States[player.UserId]
    if previous and previous.player == player then
        if previous.phase == 'fallback' then self:SendFallback(player) end
        return
    end
    local state = { player = player, phase = 'pending', readKey = readKey }
    self.States[player.UserId] = state
    local storyId = cfg().StoryId
    if storyId == nil or storyId == '' then return self:Fallback(player, state, '未配置 storyID') end
    if not self.Service then return self:Fallback(player, state, 'StoryService 不可用') end
    local ok, err = pcall(function() self.Service:StartStory(player, storyId) end)
    if not ok then return self:Fallback(player, state, 'StartStory 报错 ' .. tostring(err)) end
    print('[player_story] StartStory', player.UserId, storyId)
    if state.phase == 'pending' then state.deadline = self:Now() + cfg().StartTimeoutSec end
end

function mgr:OnSignal(name, player, storyId)
    local state = player and self.States[player.UserId]
    print('[player_story]', name, player and player.UserId, tostring(storyId), state and state.phase)
    if not state or state.player ~= player or storyId ~= cfg().StoryId or storyId == nil then return end
    if name == 'OnStoryStart' and state.phase == 'pending' then
        state.phase = 'started'
        state.deadline = nil
    elseif (name == 'OnStoryEnd' or name == 'OnStorySkip')
        and (state.phase == 'started' or state.phase == 'pending') then
        self:Complete(player, state.readKey, name == 'OnStorySkip' and 'skip' or 'end')
    end
end

function mgr:Complete(player, readKey, source)
    local state = player and self.States[player.UserId]
    if not state or state.player ~= player or readKey ~= state.readKey
        or source == 'read' and state.phase ~= 'fallback'
        or source ~= 'read' and source ~= 'end' and source ~= 'skip'
        or state.phase == 'read' or state.phase == 'saving' then return false end
    state.completeSource = source
    return self:PersistRead(player, state)
end

function mgr:PersistRead(player, state)
    if self.Save and state.leave then
        local status = self.Save:Status(player.UserId)
        if status.autosavePaused or status.loadState == 'failed' then
            state.failed = true
            local leave = state.leave
            state.leave = nil
            leave()
            return false
        end
    end
    local data = self.player_data and self.player_data:GetDataInst(player)
    if self.Save and not data then return false end
    if not self.Save then
        state.phase = 'read'
        _G.re_util:GetRE('StoryState'):FireClient(player, { read = true, readKey = state.readKey })
        return true
    end
    local operation = self.Save:NextOperation(player, 'story-read')
    if not operation then return false end
    local previousPhase = state.phase
    state.phase = 'saving'
    local accepted = self.Save:Execute(player, data, operation, function(draft)
        draft.Extra.story.read = draft.Extra.story.read or {}
        draft.Extra.story.read[state.readKey] = true
        return { read = true, readKey = state.readKey }
    end, function(written, result)
        if self.States[player.UserId] ~= state then return end
        if not written then
            state.phase = previousPhase
            state.failed = true
            print('[player_story] 已读未落账', player.UserId, tostring(result))
            _G.re_util:GetRE('StoryState'):FireClient(player, {
                read = false, readKey = state.readKey, text = '已读尚未保存，请稍后重进再试。',
            })
            local leave = state.leave
            state.leave = nil
            if leave then leave() end
            return
        end
        state.phase, state.completeSource, state.deadline = 'read', nil, nil
        print('[player_story] 已读落账', player.UserId, state.readKey)
        _G.re_util:GetRE('StoryState'):FireClient(player, result)
        local leave = state.leave
        state.leave = nil
        if leave then leave() end
    end)
    if not accepted then state.phase = previousPhase end
    return accepted
end

function mgr:FlushBeforeLeave(player, done)
    local state = player and self.States[player.UserId]
    if not self.Save or not state or state.player ~= player or state.failed
        or not state.completeSource or self.Save:Status(player.UserId).loadState ~= 'ready' then return false end
    if self.Save:Status(player.UserId).autosavePaused then
        state.failed, state.leave = true, nil
        print('[player_story] 保存已暂停，离场保留未读', player.UserId)
        return false
    end
    state.leave = done
    local function attempt()
        state.retrying = nil
        if self.States[player.UserId] ~= state or not state.leave or state.phase == 'saving' then return end
        if self:PersistRead(player, state) or state.failed or not state.leave then return end
        if not state.retrying then
            state.retrying = true
            game:GetService('Task'):Spawn(attempt)
        end
    end
    attempt()
    return true
end

function mgr:OnPlayerAdded(player)
    if self.Requested[player.UserId] == player then self:Begin(player) end
end

function mgr:Update()
    local now
    for _, player in pairs(self.Requested) do
        if not self.States[player.UserId] then self:Begin(player) end
    end
    for userId, state in pairs(self.States) do
        if state.completeSource and state.phase ~= 'saving' then self:PersistRead(state.player, state) end
        if state.deadline then
            now = now or self:Now()
            if now >= state.deadline then
                local player
                for _, p in ipairs(game:GetService('Players'):GetPlayers()) do
                    if p.UserId == userId then player = p end
                end
                if player then
                    self:Fallback(player, state, cfg().StartTimeoutSec .. ' 秒内未收到 OnStoryStart（剧情配表里可能没有这条剧情）')
                else
                    state.deadline = nil
                end
            end
        end
    end
end

function mgr:OnPlayerRemoving(player)
    if isValidPlayer(player) then
        if self.Requested[player.UserId] == player then self.Requested[player.UserId] = nil end
        local state = self.States[player.UserId]
        if state and state.player == player then self.States[player.UserId] = nil end
    end
end

function mgr.mount(scope, player_tree, opts)
    local player = opts.player
    local session = setmetatable({
        States = {}, Requested = {}, player_data = opts.player_data, Save = opts.save,
        World = { GetServerTime = function() return opts.clock.now() end },
    }, { __index = mgr })
    local ok, service = pcall(function() return game:GetService('StoryService') end)
    session.Service = ok and service or nil
    player_tree.story = session
    if session.Service then
        for _, name in ipairs({ 'OnStoryStart', 'OnStoryEnd', 'OnStorySkip' }) do
            local signal = session.Service[name]
            if signal then
                signal_router.bind_player(scope, signal, player, function(actor, storyId)
                    session:OnSignal(name, actor, storyId)
                end)
            end
        end
    end
    signal_router.bind_player(scope, _G.re_util:GetRE('RequestStory').OnServerEvent, player, function(actor)
        if _G.re_util:CheckRECD(actor, 'RequestStory', 0.5) then return end
        session:Begin(actor)
    end)
    signal_router.bind_player(scope, _G.re_util:GetRE('StoryRead').OnServerEvent, player, function(actor, payload)
        if type(payload) ~= 'table' or payload.action ~= 'read'
            or type(payload.readKey) ~= 'string' or _G.re_util:CheckRECD(actor, 'StoryRead', 0.5) then return end
        session:Complete(actor, payload.readKey, 'read')
    end)
    scope:subscribe(opts.clock.on_second, function() session:Update() end)
    session:Begin(player)
    scope:on_cleanup(function()
        session:OnPlayerRemoving(player)
        if player_tree.story == session then player_tree.story = nil end
    end)
    return session
end

return mgr
