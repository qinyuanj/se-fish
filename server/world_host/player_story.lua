local GameCfg = require('common.game_cfg')
local SignalRouter = require('server.world_host.world_signal_router')

local Mgr = { States = {}, Requested = {} }
local isValidPlayer = SignalRouter.is_valid_player

local function cfg()
    return GameCfg.Story
end

function Mgr:now()
    self.World = self.World or game:GetService('World')
    return self.World:GetServerTime()
end

function Mgr:fallback(player, state, reason)
    if state.phase ~= 'pending' then return end
    state.phase = 'fallback'
    state.deadline = nil
    print('[PlayerStory] 降级 开场剧情', player.UserId, '原因=' .. tostring(reason),
        '影响=展示可读对话，正式剧情表现留待资源验收')
    self:send_fallback(player)
end

function Mgr:send_fallback(player)
    _G.REUtil:get_re('StoryNotice'):FireClient(player, {
        text = cfg().FallbackText, lines = cfg().Lines or { cfg().FallbackText },
        readKey = cfg().ReadKey or 'opening', title = cfg().Title or '欢迎来到钓场',
    })
end

function Mgr:begin(player)
    if not player then return end
    self.Requested[player.UserId] = player
    local data = self.PlayerData and self.PlayerData:get_data_inst(player)
    if self.Save and not data then return end
    local readKey = cfg().ReadKey or 'opening'
    if data and data.Extra.story.read and data.Extra.story.read[readKey] then
        self.Requested[player.UserId] = nil
        return
    end
    local previous = self.States[player.UserId]
    if previous and previous.player == player then
        if previous.phase == 'fallback' then self:send_fallback(player) end
        return
    end
    local state = { player = player, phase = 'pending', readKey = readKey }
    self.States[player.UserId] = state
    local storyId = cfg().StoryId
    if storyId == nil or storyId == '' then return self:fallback(player, state, '未配置 storyID') end
    if not self.Service then return self:fallback(player, state, 'StoryService 不可用') end
    local ok, err = pcall(function() self.Service:StartStory(player, storyId) end)
    if not ok then return self:fallback(player, state, 'StartStory 报错 ' .. tostring(err)) end
    print('[PlayerStory] StartStory', player.UserId, storyId)
    if state.phase == 'pending' then state.deadline = self:now() + cfg().StartTimeoutSec end
end

function Mgr:on_signal(name, player, storyId)
    local state = player and self.States[player.UserId]
    print('[PlayerStory]', name, player and player.UserId, tostring(storyId), state and state.phase)
    if not state or state.player ~= player or storyId ~= cfg().StoryId or storyId == nil then return end
    if name == 'OnStoryStart' and state.phase == 'pending' then
        state.phase = 'started'
        state.deadline = nil
    elseif (name == 'OnStoryEnd' or name == 'OnStorySkip')
        and (state.phase == 'started' or state.phase == 'pending') then
        self:complete(player, state.readKey, name == 'OnStorySkip' and 'skip' or 'end')
    end
end

function Mgr:complete(player, readKey, source)
    local state = player and self.States[player.UserId]
    if not state or state.player ~= player or readKey ~= state.readKey
        or source == 'read' and state.phase ~= 'fallback'
        or source ~= 'read' and source ~= 'end' and source ~= 'skip'
        or state.phase == 'read' or state.phase == 'saving' then return false end
    state.completeSource = source
    return self:persist_read(player, state)
end

function Mgr:persist_read(player, state)
    if self.Save and state.leave then
        local status = self.Save:status(player.UserId)
        if status.autosavePaused or status.loadState == 'failed' then
            state.failed = true
            local leave = state.leave
            state.leave = nil
            leave()
            return false
        end
    end
    local data = self.PlayerData and self.PlayerData:get_data_inst(player)
    if self.Save and not data then return false end
    if not self.Save then
        state.phase = 'read'
        _G.REUtil:get_re('StoryState'):FireClient(player, { read = true, readKey = state.readKey })
        return true
    end
    local operation = self.Save:next_operation(player, 'story-read')
    if not operation then return false end
    local previousPhase = state.phase
    state.phase = 'saving'
    local accepted = self.Save:execute(player, data, operation, function(draft)
        draft.Extra.story.read = draft.Extra.story.read or {}
        draft.Extra.story.read[state.readKey] = true
        return { read = true, readKey = state.readKey }
    end, function(written, result)
        if self.States[player.UserId] ~= state then return end
        if not written then
            state.phase = previousPhase
            state.failed = true
            print('[PlayerStory] 已读未落账', player.UserId, tostring(result))
            _G.REUtil:get_re('StoryState'):FireClient(player, {
                read = false, readKey = state.readKey, text = '已读尚未保存，请稍后重进再试。',
            })
            local leave = state.leave
            state.leave = nil
            if leave then leave() end
            return
        end
        state.phase, state.completeSource, state.deadline = 'read', nil, nil
        print('[PlayerStory] 已读落账', player.UserId, state.readKey)
        _G.REUtil:get_re('StoryState'):FireClient(player, result)
        local leave = state.leave
        state.leave = nil
        if leave then leave() end
    end)
    if not accepted then state.phase = previousPhase end
    return accepted
end

function Mgr:flush_before_leave(player, done)
    local state = player and self.States[player.UserId]
    if not self.Save or not state or state.player ~= player or state.failed
        or not state.completeSource or self.Save:status(player.UserId).loadState ~= 'ready' then return false end
    if self.Save:status(player.UserId).autosavePaused then
        state.failed, state.leave = true, nil
        print('[PlayerStory] 保存已暂停，离场保留未读', player.UserId)
        return false
    end
    state.leave = done
    local function attempt()
        state.retrying = nil
        if self.States[player.UserId] ~= state or not state.leave or state.phase == 'saving' then return end
        if self:persist_read(player, state) or state.failed or not state.leave then return end
        if not state.retrying then
            state.retrying = true
            game:GetService('Task'):Spawn(attempt)
        end
    end
    attempt()
    return true
end

function Mgr:on_player_added(player)
    if self.Requested[player.UserId] == player then self:begin(player) end
end

function Mgr:update()
    local now
    for _, player in pairs(self.Requested) do
        if not self.States[player.UserId] then self:begin(player) end
    end
    for userId, state in pairs(self.States) do
        if state.completeSource and state.phase ~= 'saving' then self:persist_read(state.player, state) end
        if state.deadline then
            now = now or self:now()
            if now >= state.deadline then
                local player
                for _, p in ipairs(game:GetService('Players'):GetPlayers()) do
                    if p.UserId == userId then player = p end
                end
                if player then
                    self:fallback(player, state, cfg().StartTimeoutSec .. ' 秒内未收到 OnStoryStart（剧情配表里可能没有这条剧情）')
                else
                    state.deadline = nil
                end
            end
        end
    end
end

function Mgr:on_player_removing(player)
    if isValidPlayer(player) then
        if self.Requested[player.UserId] == player then self.Requested[player.UserId] = nil end
        local state = self.States[player.UserId]
        if state and state.player == player then self.States[player.UserId] = nil end
    end
end

function Mgr.mount(scope, player_tree, opts)
    local player = opts.player
    local session = setmetatable({
        States = {}, Requested = {}, PlayerData = opts.player_data, Save = opts.save,
        World = { GetServerTime = function() return opts.clock.now() end },
    }, { __index = Mgr })
    local ok, service = pcall(function() return game:GetService('StoryService') end)
    session.Service = ok and service or nil
    player_tree.story = session
    if session.Service then
        for _, name in ipairs({ 'OnStoryStart', 'OnStoryEnd', 'OnStorySkip' }) do
            local signal = session.Service[name]
            if signal then
                SignalRouter.bind_player(scope, signal, player, function(actor, storyId)
                    session:on_signal(name, actor, storyId)
                end)
            end
        end
    end
    SignalRouter.bind_player(scope, _G.REUtil:get_re('RequestStory').OnServerEvent, player, function(actor)
        if _G.REUtil:check_recd(actor, 'RequestStory', 0.5) then return end
        session:begin(actor)
    end)
    SignalRouter.bind_player(scope, _G.REUtil:get_re('StoryRead').OnServerEvent, player, function(actor, payload)
        if type(payload) ~= 'table' or payload.action ~= 'read'
            or type(payload.readKey) ~= 'string' or _G.REUtil:check_recd(actor, 'StoryRead', 0.5) then return end
        session:complete(actor, payload.readKey, 'read')
    end)
    scope:subscribe(opts.clock.on_second, function() session:update() end)
    session:begin(player)
    scope:on_cleanup(function()
        session:on_player_removing(player)
        if player_tree.story == session then player_tree.story = nil end
    end)
    return session
end

return Mgr
