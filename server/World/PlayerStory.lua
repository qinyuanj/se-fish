local GameCfg = require('common.GameCfg')

local Mgr = { States = {}, Requested = {} }
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

local function cfg()
    return GameCfg.Story
end

function Mgr:Now()
    self.World = self.World or game:GetService('World')
    return self.World:GetServerTime()
end

function Mgr:Fallback(player, state, reason)
    if state.phase ~= 'pending' then return end
    state.phase = 'fallback'
    state.deadline = nil
    print('[PlayerStory] 降级 开场剧情', player.UserId, '原因=' .. tostring(reason),
        '影响=展示可读对话，正式剧情表现留待资源验收')
    self:SendFallback(player)
end

function Mgr:SendFallback(player)
    _G.REUtil:GetRE('StoryNotice'):FireClient(player, {
        text = cfg().FallbackText, lines = cfg().Lines or { cfg().FallbackText },
        readKey = cfg().ReadKey or 'opening', title = cfg().Title or '欢迎来到钓场',
    })
end

function Mgr:Begin(player)
    if not player then return end
    self.Requested[player.UserId] = player
    local data = self.PlayerData and self.PlayerData:GetDataInst(player)
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
    print('[PlayerStory] StartStory', player.UserId, storyId)
    if state.phase == 'pending' then state.deadline = self:Now() + cfg().StartTimeoutSec end
end

function Mgr:OnSignal(name, player, storyId)
    local state = player and self.States[player.UserId]
    print('[PlayerStory]', name, player and player.UserId, tostring(storyId), state and state.phase)
    if not state or state.player ~= player or storyId ~= cfg().StoryId or storyId == nil then return end
    if name == 'OnStoryStart' and state.phase == 'pending' then
        state.phase = 'started'
        state.deadline = nil
    elseif (name == 'OnStoryEnd' or name == 'OnStorySkip')
        and (state.phase == 'started' or state.phase == 'pending') then
        self:Complete(player, state.readKey, name == 'OnStorySkip' and 'skip' or 'end')
    end
end

function Mgr:Complete(player, readKey, source)
    local state = player and self.States[player.UserId]
    if not state or state.player ~= player or readKey ~= state.readKey
        or source == 'read' and state.phase ~= 'fallback'
        or source ~= 'read' and source ~= 'end' and source ~= 'skip'
        or state.phase == 'read' or state.phase == 'saving' then return false end
    state.completeSource = source
    return self:PersistRead(player, state)
end

function Mgr:PersistRead(player, state)
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
    local data = self.PlayerData and self.PlayerData:GetDataInst(player)
    if self.Save and not data then return false end
    if not self.Save then
        state.phase = 'read'
        _G.REUtil:GetRE('StoryState'):FireClient(player, { read = true, readKey = state.readKey })
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
            print('[PlayerStory] 已读未落账', player.UserId, tostring(result))
            _G.REUtil:GetRE('StoryState'):FireClient(player, {
                read = false, readKey = state.readKey, text = '已读尚未保存，请稍后重进再试。',
            })
            local leave = state.leave
            state.leave = nil
            if leave then leave() end
            return
        end
        state.phase, state.completeSource, state.deadline = 'read', nil, nil
        print('[PlayerStory] 已读落账', player.UserId, state.readKey)
        _G.REUtil:GetRE('StoryState'):FireClient(player, result)
        local leave = state.leave
        state.leave = nil
        if leave then leave() end
    end)
    if not accepted then state.phase = previousPhase end
    return accepted
end

function Mgr:FlushBeforeLeave(player, done)
    local state = player and self.States[player.UserId]
    if not self.Save or not state or state.player ~= player or state.failed
        or not state.completeSource or self.Save:Status(player.UserId).loadState ~= 'ready' then return false end
    if self.Save:Status(player.UserId).autosavePaused then
        state.failed, state.leave = true, nil
        print('[PlayerStory] 保存已暂停，离场保留未读', player.UserId)
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

function Mgr:OnPlayerAdded(player)
    if self.Requested[player.UserId] == player then self:Begin(player) end
end

function Mgr:Update()
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

function Mgr:OnPlayerRemoving(player)
    if isValidPlayer(player) then
        if self.Requested[player.UserId] == player then self.Requested[player.UserId] = nil end
        local state = self.States[player.UserId]
        if state and state.player == player then self.States[player.UserId] = nil end
    end
end

-- 剧情服务与已读请求均挂在玩家树作用域；全局信号按对象单次绑定并按 UserId O(1) 路由，
-- 仅用秒级心跳检查启动超时与失败重试。
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
                registerPlayerSignal(scope, signal, player, function(actor, storyId)
                    session:OnSignal(name, actor, storyId)
                end)
            end
        end
    end
    registerPlayerSignal(scope, _G.REUtil:GetRE('RequestStory').OnServerEvent, player, function(actor)
        if _G.REUtil:CheckRECD(actor, 'RequestStory', 0.5) then return end
        session:Begin(actor)
    end)
    registerPlayerSignal(scope, _G.REUtil:GetRE('StoryRead').OnServerEvent, player, function(actor, payload)
        if type(payload) ~= 'table' or payload.action ~= 'read'
            or type(payload.readKey) ~= 'string' or _G.REUtil:CheckRECD(actor, 'StoryRead', 0.5) then return end
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

return Mgr
