local World = game:GetService('World')
local GameCfg = require('common.GameCfg')
local DamageFloat = require('client.DamageFloat')
local MainHudLayout = require('client.MainHudLayout')
local OwnedUnits = require('common.OwnedUnits')

local ScreenHandler = { UINodes = {}, UINodeMap = {} }

function ScreenHandler:Operate(payload)
    self.OpSeq = (self.OpSeq or 0) + 1
    payload.seq = self.OpSeq
    payload.action = 'Operate'
    _G.REUtil:GetRE('ItemBarAction'):FireServer(payload)
end

local function baitStock(state, id)
    local bait = type(state) == 'table' and type(state.bait) == 'table' and state.bait or {}
    local count = id ~= nil and bait[id] or nil
    return type(count) == 'number' and count or 0
end

local function wormCount(state)
    return baitStock(state, GameCfg.Items.Id.Worm)
end

function ScreenHandler:Show(state)
    if type(state) ~= 'table' or type(state.slots) ~= 'table' then return end
    local depleted = self.Snapshot ~= nil and wormCount(self.Snapshot) > 0 and wormCount(state) <= 0
    self.Snapshot = state
    local capacity = state.slotCount or GameCfg.Items.ItemBarSlots
    self:ApplyLayout(capacity, nil)
    self:ShowCast()
    self:ApplyBackpackOcclusion()
    if depleted then self:ShowCastFailure({ reason = 'wormDepleted' }) end
end

function ScreenHandler:StartHookAlert(session)
    if session == nil or session == self.AlertedSession then return end
    self.AlertedSession = session
    local alert = GameCfg.HookAlert
    self.HookAlertUntil = World:GetServerTime() + alert.DurationSec
    local ok, err = false, '未配置提示音'
    if alert.Sound then
        ok, err = pcall(function()
            game:GetService('SoundService'):PlayLocalSound(alert.Sound, alert.Volume, 1)
        end)
    end
    print('[ScreenMain] 上钩提示', tostring(session), ok and ('音效 ' .. alert.Sound)
        or ('音效缺失，只保留文字与高亮 ' .. tostring(err)))
end

local function wrapColumns(text, columns)
    local out, count = {}, 0
    for character in text:gmatch('[%z\1-\127\194-\244][\128-\191]*') do
        if character == '\n' then
            count = 0
        else
            if count >= columns then out[#out + 1], count = '\n', 0 end
            count = count + 1
        end
        out[#out + 1] = character
    end
    return table.concat(out)
end

function ScreenHandler:ShowQuest(state)
    if not self.QuestLabel or type(state) ~= 'table' or type(state.text) ~= 'string' then return end
    local columns = math.max(1, math.floor(self.QuestLabel.Size.x / self.QuestLabel.FontSize))
    self.QuestLabel.Text = wrapColumns(state.text, columns)
    self.QuestShown = true
    self:RenderQuest()
    if type(state.notice) == 'string' and _G.LocalMsgNotice then _G.LocalMsgNotice(state.notice) end
end

function ScreenHandler:RenderQuest()
    if not self.QuestLabel then return end
    local shown = self.QuestShown == true
    local expanded = shown and not self.QuestCollapsed
    self.QuestLabel.Visible = expanded
    if self.QuestBackground then self.QuestBackground.Visible = expanded end
    if self.QuestToggle then
        self.QuestToggle.Visible = shown
        self.QuestToggle.TouchEnabled = shown
        self.QuestToggleLabel.Visible = shown
        self.QuestToggleLabel.Text = self.QuestCollapsed and '展开任务' or '收起任务'
    end
end

function ScreenHandler:ShowDialogue(payload)
    if type(payload) ~= 'table' or not self.DialogueNodes then return end
    local lines = payload.lines
    if type(lines) ~= 'table' or #lines == 0 then return end
    for _, line in ipairs(lines) do if type(line) ~= 'string' then return end end
    self.DialoguePayload, self.DialoguePage = payload, 1
    for _, node in ipairs(self.DialogueNodes) do node.Visible = true end
    self:ShowDialoguePage()
end

function ScreenHandler:ShowDialoguePage()
    local payload = self.DialoguePayload
    if not payload then return end
    self.DialogueTitle.Text = (payload.title or '钓鱼佬') .. '  ' .. self.DialoguePage .. '/' .. #payload.lines
    local wrapped, count = {}, 0
    for character in payload.lines[self.DialoguePage]:gmatch('[%z\1-\127\194-\244][\128-\191]*') do
        wrapped[#wrapped + 1] = character
        count = character == '\n' and 0 or count + 1
        if count >= self.DialogueColumns then wrapped[#wrapped + 1], count = '\n', 0 end
    end
    self.DialogueBody.Text = table.concat(wrapped)
    self.DialogueNext.TouchEnabled = self.DialoguePage < #payload.lines
    self.DialogueRead.TouchEnabled = true
    self.DialogueReadLabel.Text = payload.readKey and '已读，开始钓鱼' or '知道了'
end

function ScreenHandler:HideDialogue()
    for _, node in ipairs(self.DialogueNodes or {}) do node.Visible = false end
    self.DialoguePayload = nil
end

local CAST_PHASES = { idle = true, cast = true, hooked = true, landed = true, unhooked = true }

local function castProgress(self, reel, active)
    local result = reel and reel.LastResult
    return active and reel.DisplayProgress and reel:DisplayProgress()
        or result and self.CastState and result.session == self.CastState.reelSession and result.progress or 50
end

local function showCastFeedback(self, phase, active, alerting, progress)
    if self.ReelBar then
        self.ReelBar.Visible = active == true
        self.ReelBarBg.Visible = active == true
        self.ReelBar.Percent = progress
    end
    if self.HookHint then
        self.HookHint.Visible = active == true or phase == 'landed'
        self.HookHint.Text = phase == 'landed' and '鱼已上岸' or alerting and GameCfg.HookAlert.Text
            or active and '收线 ' .. tostring(math.floor(progress + 0.5)) .. '%' or ''
    end
    if self.BtnReelClose then
        self.BtnReelClose.Visible = active == true
        self.BtnReelCloseLabel.Visible = active == true
    end
end

local castFailureText = {
    wormDepleted = '蚯蚓用尽',
    invalidLanding = '落点不在可钓水域，请重新抛竿',
    noFish = '本次没有鱼上钩，请重新抛竿',
    holding = '先放下鱼再抛竿',
    invalidRod = '请重新选择鱼竿',
    cooldown = '操作太快，请稍后重试',
    baitUnavailable = '鱼饵不足，请重新挂饵',
    unavailable = '暂时无法抛竿，请稍后重试',
    alreadyCasting = '正在钓鱼，请先收竿',
    cannotAct = '现在无法行动，等恢复后再试',
}

local noticeOnly = { wormDepleted = true }

function ScreenHandler:ShowCastFailure(result)
    local text = type(result) == 'table' and castFailureText[result.reason]
    if not text or not self.IsOpen then return end
    local notice = noticeOnly[result.reason] == true
    if not notice then self.SplashUntil = nil end
    self.FailureNotice = notice
    self.FailureUntil = World:GetServerTime() + GameCfg.CastFeedback.SplashDurationSec
    self.CastFailureHint.Text = text
    self.FailureLanding = result.reason == 'invalidLanding' and result.landing or nil
    self:UpdateCastFeedback()
    print('[ScreenMain] ' .. (notice and '临时提示' or '抛竿失败'), result.reason, text)
end

local function clearCastFailure(self)
    if self.FailureNotice then return end
    self.FailureUntil = nil
    self.FailureLanding = nil
end

local function waitingCast(state)
    local landing = state and state.landing
    return state and state.phase == 'cast' and state.zoneId ~= nil
        and type(state.castId) == 'number' and type(landing) == 'table'
        and type(landing.x) == 'number' and type(landing.y) == 'number'
        and type(landing.z) == 'number'
end

function ScreenHandler:UpdateCastFeedback()
    if not self.CastFloat then return end
    local now = (self.FailureUntil or self.SplashUntil) and World:GetServerTime() or 0
    local waiting = self.IsOpen and waitingCast(self.CastState)
    local hinting = self.IsOpen and self.FailureUntil ~= nil and now < self.FailureUntil
    local failing = hinting and not self.FailureNotice
    self.CastFailureHint.Visible = hinting == true
    self.CastWaitHint.Visible = waiting == true and not failing
    self.CastSplashHint.Visible = waiting == true and not failing and self.SplashUntil ~= nil
        and now < self.SplashUntil
    local camera = game:GetService('CameraService')
    local function project(landing, marker)
        if type(landing) ~= 'table' or type(landing.x) ~= 'number'
            or type(landing.y) ~= 'number' or type(landing.z) ~= 'number' or not camera then return false end
        local screen, onScreen = camera:WorldToViewportPoint(Vector3.New(landing.x, landing.y, landing.z))
        if not screen or not onScreen or screen.z <= 0 then return false end
        marker.Position = Vector2.New(screen.x, self.EuiResolution.y - screen.y)
        return true
    end
    self.CastFloat.Visible = waiting == true and not failing
        and project(self.CastState.landing, self.CastFloat) or false
    self.CastFailureMark.Visible = failing == true and self.FailureLanding ~= nil
        and project(self.FailureLanding, self.CastFailureMark) or false
end

function ScreenHandler:ShowCast()
    local phase = self.CastState and self.CastState.phase or 'idle'
    -- 收线条由 ReelOverlayView 统一承载，旧 ScreenMain 只保留抛竿提示。
    local active = false
    if self.LastReelActive ~= active then
        self.LastReelActive = active
        if type(self.OnReelActiveChanged) == 'function' then
            self.OnReelActiveChanged(active)
        end
    end
    if not self.BtnReelClose and not self.ReelBar and not self.HookHint then return end
    self:ApplyLayout(nil, false)
    local progress = castProgress(self, nil, active)
    if type(progress) ~= 'number' or progress ~= progress then progress = 50 end
    progress = math.max(0, math.min(100, progress))
    showCastFeedback(self, phase, active, false, progress)
    self:UpdateCastFeedback()
end

local function button(owner, parent, name, x, y, width)
    local btn = OwnedUnits.Track(owner, World:CreateUnit('EUIButton', {
        Parent = parent, Name = name,
        Position = Vector2.New(x, y), Size = Vector2.New(width, 90),
    }))
    btn.TouchEnabled = true
    btn.ButtonText = ''
    btn.NormalImage = 'official://image/11017'
    btn.PressImage = 'official://image/11017'
    btn.DisableImage = 'official://image/11017'
    btn.ButtonNormalColor = Color.New(54, 100, 140, 255)
    return btn
end

local function overlay(owner, parent, name, x, y, width, height, text, size, color)
    local label = OwnedUnits.Track(owner, World:CreateUnit('EUITextLabel', {
        Parent = parent, Name = name,
        Position = Vector2.New(x, y), Size = Vector2.New(width, height),
        Text = text, FontSize = size, TextColor = color,
    }))
    label.TextHorizontalAlignment = 1
    label.TextVerticalAlignment = 1
    label.TouchEnabled = false
    label.SwallowTouchEnabled = false
    label.LocalZOrder = 1
    return label
end

local function color(rgba)
    return Color.New(rgba[1], rgba[2], rgba[3], rgba[4])
end

local function passive(node)
    node.TouchEnabled = false
    node.SwallowTouchEnabled = false
    return node
end

function ScreenHandler:SetBackpackOpen(is_open)
    self.BackpackOpen = is_open == true
    self:ApplyBackpackOcclusion()
end

function ScreenHandler:ApplyBackpackOcclusion()
    local hidden = self.BackpackOpen == true
    if self.BtnReelClose then
        self.BtnReelClose.Visible = not hidden
        self.BtnReelClose.TouchEnabled = not hidden
    end
    if self.BtnReelCloseLabel then
        self.BtnReelCloseLabel.Visible = not hidden
    end
    if not hidden then
        self:ShowCast()
    end
end

local function place(node, r)
    if not node or not r then return end
    node.Position = Vector2.New(r.x, r.y)
    node.Size = Vector2.New(r.w, r.h)
end

function ScreenHandler:ApplyLayout(slots, reeling)
    local key, resolution = self.LayoutKey, self.EuiResolution
    if not key or not resolution then return end
    if slots == nil then slots = key.slots end
    if reeling == nil then reeling = key.reeling end
    if key.slots == slots and key.reeling == reeling then return end
    self.LayoutKey = { slots = slots, reeling = reeling }
    local layout = MainHudLayout.Compute({ width = resolution.x, height = resolution.y,
        itemBarSlots = slots, reeling = reeling })
    self.HudLayout = layout
    local r = layout.Rects
    place(self.BtnReelClose, r.ReelClose)
    place(self.BtnReelCloseLabel, r.ReelClose)
end

function ScreenHandler:Listen(source, callback)
    self.Connections[#self.Connections + 1] = source:Connect(callback)
end

function ScreenHandler:Cleanup()
    local rootGeneration = self.BoundRootNode or self.RootNode
    local function continueAfterFailure(stage, fn)
        local ok, err = pcall(fn)
        if not ok then
            print('[ScreenMain] 清理失败', stage, tostring(rootGeneration), tostring(err))
        end
    end
    continueAfterFailure('浮动表现', function()
        DamageFloat:Clear()
    end)
    continueAfterFailure('CloseScreen', function() self:CloseScreen() end)
    continueAfterFailure('连接', function()
        for _, connection in ipairs(self.Connections or {}) do connection:Disconnect() end
    end)
    continueAfterFailure('OwnedUnits', function()
        OwnedUnits.Clear(self)
    end)
    self.Connections = nil
    self.BackpackOpen = false
    self.UIRoot = nil
    self.LastOperateOperation = nil
    self.LastReelActive = nil
    self.BtnReelClose = nil
    self.BtnReelCloseLabel = nil
    self.HookHint = nil
    self.CastFloat = nil
    self.CastFailureMark = nil
    self.CastFailureHint = nil
    self.EuiResolution = nil
    self.CastWaitHint = nil
    self.CastSplashHint = nil
    self.SplashUntil = nil
    self.AlertedCastId = nil
    self.QuestLabel = nil
    self.QuestBackground = nil
    self.DialogueNodes = nil
    self.DialoguePayload = nil
    self.ReelBar = nil
    self.ReelBarBg = nil
    self.HudLayout = nil
    self.LayoutKey = nil
    self.QuestToggle = nil
    self.QuestToggleLabel = nil
    self.QuestShown = nil
    self.Snapshot = nil
    self.CastState = nil
    self.BoundRootNode = nil
    self.Inited = false
end

function ScreenHandler:Init()
    if self.Inited then
        if self.BoundRootNode == self.RootNode then return end
        self:Cleanup()
    end
    local ok, err = pcall(function()
        self:_initializeRoot()
    end)
    if ok then return end
    self:Cleanup()
    error(err, 0)
end

function ScreenHandler:_initializeRoot()
    local euiMgr = _G.GameUI:GetEuiManager()
    if not euiMgr then return end
    local resolution = euiMgr:GetDeviceResolution()
    self.EuiResolution = resolution
    local root = self.RootNode
    DamageFloat:Bind(root, resolution)
    local count = GameCfg.Items.ItemBarSlots
    local layout = MainHudLayout.Compute({ width = resolution.x, height = resolution.y,
        itemBarSlots = count, reeling = true })
    self.HudLayout = layout
    local rects = layout.Rects
    self.Connections = {}
    self.UIRoot = root
    self.BackpackOpen = self.BackpackOpen == true
    local reelClose = rects.ReelClose
    self.BtnReelClose = button(self, root, 'ReelClose', reelClose.x, reelClose.y, reelClose.w)
    place(self.BtnReelClose, reelClose)
    self.BtnReelCloseLabel = overlay(self, root, 'BtnReelCloseLabel',
        self.BtnReelClose.Position.x, self.BtnReelClose.Position.y,
        self.BtnReelClose.Size.x, self.BtnReelClose.Size.y,
        '结束收线', 30, Color.New(255, 255, 255, 255))
    local primary, secondary, transient = rects.HintPrimary, rects.HintSecondary, rects.HintTransient
    self.HookHint = overlay(self, root, 'HookHint', primary.x, primary.y, primary.w, primary.h,
        '', 32, Color.New(255, 220, 40, 255))
    self.HookHint.Visible = false
    local feedback = GameCfg.CastFeedback
    self.CastFloat = overlay(self, root, 'CastFloat', 0, 0, feedback.FloatSize, feedback.FloatSize,
        '●', 48, color(feedback.FloatColor))
    self.CastWaitHint = overlay(self, root, 'CastWaitHint', primary.x, primary.y, primary.w, primary.h,
        '等待上钩…', 32, Color.New(255, 255, 255, 255))
    self.CastSplashHint = overlay(self, root, 'CastSplashHint', secondary.x, secondary.y, secondary.w, secondary.h,
        '已入水，等待上钩', 30, Color.New(255, 225, 70, 255))
    self.CastFailureHint = overlay(self, root, 'CastFailureHint', transient.x, transient.y, transient.w, transient.h,
        '', 30, Color.New(255, 90, 90, 255))
    self.CastFailureMark = overlay(self, root, 'CastFailureMark', 0, 0, feedback.FloatSize, feedback.FloatSize,
        '●', 48, Color.New(255, 65, 65, 255))
    for _, node in ipairs({ self.CastFloat, self.CastWaitHint, self.CastSplashHint,
        self.CastFailureHint, self.CastFailureMark }) do
        node.Visible = false
    end
    local questPanel, questToggle = rects.QuestPanel, rects.QuestToggle
    self.QuestBackground = passive(OwnedUnits.Track(self, World:CreateUnit('EUIImage', {
        Parent = root, Name = 'QuestBackground',
        Position = Vector2.New(questPanel.x, questPanel.y), Size = Vector2.New(questPanel.w, questPanel.h),
        Image = 'official://image/11017', Color = Color.New(16, 24, 34, 180),
    })))
    self.QuestBackground.Visible = false
    self.QuestLabel = overlay(self, root, 'QuestLabel', questPanel.x, questPanel.y, questPanel.w - 20,
        questPanel.h - 12, '', 24, Color.New(255, 255, 255, 255))
    self.QuestLabel.Visible = false
    self.QuestToggle = button(self, root, 'QuestToggle', questToggle.x, questToggle.y, questToggle.w)
    place(self.QuestToggle, questToggle)
    self.QuestToggleLabel = overlay(self, root, 'QuestToggleLabel', questToggle.x, questToggle.y,
        questToggle.w, questToggle.h, '收起任务', 22, Color.New(255, 255, 255, 255))
    self:Listen(self.QuestToggle.OnClicked, function()
        self.QuestCollapsed = not self.QuestCollapsed
        self:RenderQuest()
    end)
    self:RenderQuest()
    local cx, cy = resolution.x / 2, resolution.y / 2
    local width = math.min(1000, resolution.x - 60)
    self.DialogueColumns = math.max(12, math.floor((width - 80) / 26))
    local panel = OwnedUnits.Track(self, World:CreateUnit('EUIImage', {
        Parent = root, Name = 'DialogueBackground', Position = Vector2.New(cx, cy),
        Size = Vector2.New(width, 360), Image = 'official://image/11017',
        Color = Color.New(22, 38, 54, 250),
    }))
    panel.TouchEnabled, panel.SwallowTouchEnabled, panel.LocalZOrder = true, true, 20
    self.DialogueTitle = overlay(self, root, 'DialogueTitle', cx, cy + 120, width - 50, 50,
        '', 30, Color.New(255, 225, 130, 255))
    self.DialogueBody = overlay(self, root, 'DialogueBody', cx, cy - 10, width - 80, 130,
        '', 26, Color.New(255, 255, 255, 255))
    self.DialogueNext = button(self, root, 'DialogueNext', cx - 160, cy - 115, 260)
    self.DialogueRead = button(self, root, 'DialogueRead', cx + 160, cy - 115, 300)
    local nextLabel = overlay(self, root, 'DialogueNextLabel', cx - 160, cy - 115, 260, 80,
        '下一段', 26, Color.New(255, 255, 255, 255))
    self.DialogueReadLabel = overlay(self, root, 'DialogueReadLabel', cx + 160, cy - 115, 300, 80,
        '已读，开始钓鱼', 26, Color.New(255, 255, 255, 255))
    self.DialogueNodes = { panel, self.DialogueTitle, self.DialogueBody,
        self.DialogueNext, self.DialogueRead, nextLabel, self.DialogueReadLabel }
    for _, node in ipairs(self.DialogueNodes) do
        if node ~= panel then node.LocalZOrder = 21 end
        if node == nextLabel or node == self.DialogueReadLabel then node.LocalZOrder = 22 end
        node.Visible = false
    end
    self:Listen(self.DialogueNext.OnClicked, function()
        if not self.DialoguePayload or self.DialoguePage >= #self.DialoguePayload.lines then return end
        self.DialoguePage = self.DialoguePage + 1
        self:ShowDialoguePage()
    end)
    self:Listen(self.DialogueRead.OnClicked, function()
        local payload = self.DialoguePayload
        if not payload then return end
        if not payload.readKey then return self:HideDialogue() end
        self.DialogueReadLabel.Text = '保存已读中…'
        self.DialogueRead.TouchEnabled = false
        _G.REUtil:GetRE('StoryRead'):FireServer({ action = 'read', readKey = payload.readKey })
    end)
    self.ReelBarBg = OwnedUnits.Track(self, World:CreateUnit('EUIImage', {
        Parent = root, Name = 'ReelProgressBg',
        Position = Vector2.New(secondary.x, secondary.y), Size = Vector2.New(400, 36),
        Image = 'official://image/30008',
    }))
    self.ReelBar = OwnedUnits.Track(self, World:CreateUnit('EUILoadingBar', {
        Parent = root, Name = 'ReelProgress',
        Position = Vector2.New(secondary.x, secondary.y), Size = Vector2.New(400, 36),
        Image = 'official://image/30007', Direction = 0, Percent = 50,
        Color = Color.New(36, 200, 94, 255),
    }))
    for _, node in ipairs({ self.ReelBarBg, self.ReelBar }) do
        node.TouchEnabled = false
        node.SwallowTouchEnabled = false
        node.Visible = false
    end
    self.BtnReelClose.Visible = false
    self.BtnReelCloseLabel.Visible = false
    self:Listen(self.BtnReelClose.OnClicked, function()
        self:ShowCast()
    end)
    self:Listen(_G.REUtil:GetRE('ItemBarState').OnClientEvent, function(state) self:Show(state) end)
    _G.REUtil:GetRE('SpecialItemStateRequest'):FireServer()
    self:Listen(_G.REUtil:GetRE('SpecialItemResult').OnClientEvent, function(result)
        if type(result) ~= 'table' or result.ok ~= false then return end
        local hints = { cooldown = '原子吐息冷却中', ['not-godzilla'] = '需要选中哥斯拉变身',
            ['not-wings'] = '需要选中风神之翼', ['not-alive'] = '现在不能行动',
            ['no-character'] = '角色未就绪' }
        if _G.LocalMsgNotice then
            _G.LocalMsgNotice(hints[result.reason] or ('操作失败 ' .. tostring(result.reason)))
        end
    end)
    self:Listen(_G.REUtil:GetRE('ItemBarResult').OnClientEvent, function(result)
        if type(result) ~= 'table' or result.ok ~= false then return end
        self.LastOperateOperation = result.operation or self.LastOperateOperation
        if result.reason == 'combat-pending' then
            return
        end
        local hints = { empty = '物品已不在格子里', ['cannot-eat'] = '现在不能吃',
            ['drop-unavailable'] = '丢弃通道未就绪（地面物品）', ['drop-rejected'] = '这里丢不下',
            ['potion-capped'] = '这类药水已到上限', ['combat-pending'] = '战斗结算未接入（#128）',
            ['bad-weapon'] = '没有这件武器', ['bad-slot'] = '格子不存在', ['unknown-op'] = '未知操作' }
        if _G.LocalMsgNotice then
            _G.LocalMsgNotice(hints[result.reason] or ('操作失败 ' .. tostring(result.reason)))
        end
    end)
    self:Listen(_G.REUtil:GetRE('CastState').OnClientEvent, function(state)
        if type(state) ~= 'table' then return end
        if state.result then
            if state.castId and self.AlertedCastId and state.castId < self.AlertedCastId then return end
            if state.phase == 'idle' and not state.castId and waitingCast(self.CastState) then return end
            if state.phase == 'idle' and state.castId
                and self.CastState and self.CastState.castId == state.castId then
                self.SplashUntil = nil
                self.CastState = state
                self:ShowCast()
            end
            self:ShowCastFailure(state.result)
            return
        end
        if not CAST_PHASES[state.phase] then return end
        if not self.IsOpen then return end
        if waitingCast(state) then
            if self.AlertedCastId and state.castId < self.AlertedCastId then return end
            clearCastFailure(self)
            if self.AlertedCastId ~= state.castId then
                self.AlertedCastId = state.castId
                self.SplashUntil = nil
                if not state.snapshot then
                    self.SplashUntil = World:GetServerTime() + GameCfg.CastFeedback.SplashDurationSec
                    print('[ScreenMain] 已入水，等待上钩', state.castId, state.zoneId)
                end
            end
        else
            self.SplashUntil = nil
            if not state.snapshot or state.phase ~= 'idle' then clearCastFailure(self) end
        end
        if state.phase == 'hooked' then
            self:StartHookAlert(state.reelSession)
        end
        self.CastState = state
        self:ShowCast()
    end)
    self:Listen(_G.REUtil:GetRE('DamageNotice').OnClientEvent, function(payload)
        if self.IsOpen then DamageFloat:Show(payload) end
    end)
    self:Listen(_G.REUtil:GetRE('QuestState').OnClientEvent, function(state) self:ShowQuest(state) end)
    self:Listen(_G.REUtil:GetRE('StoryNotice').OnClientEvent, function(payload)
        self:ShowDialogue(payload)
    end)
    self:Listen(_G.REUtil:GetRE('StoryState').OnClientEvent, function(payload)
        if type(payload) == 'table' and payload.read == true and self.DialoguePayload
            and payload.readKey == self.DialoguePayload.readKey then
            self:HideDialogue()
        elseif type(payload) == 'table' and payload.read == false and self.DialoguePayload
            and payload.readKey == self.DialoguePayload.readKey then
            self.DialogueBody.Text = payload.text or '已读尚未保存'
            self.DialogueReadLabel.Text = '稍后重进再试'
        end
    end)
    self:Listen(_G.REUtil:GetRE('ReelInRE').OnClientEvent, function()
        self:ShowCast()
    end)
    local runService = game:GetService('RunService')
    if runService and runService.Heartbeat then
        self:Listen(runService.Heartbeat, function()
            if self.ReelBar and self.ReelBar.Visible then self:ShowCast() end
            if self.CastFloat and self.IsOpen then self:UpdateCastFeedback() end
            DamageFloat:Update()
        end)
    end
    self.LayoutKey = { slots = count, reeling = true }
    self.BoundRootNode = root
    self.Inited = true
    self.IsOpen = false
end

function ScreenHandler:OpenScreen()
    DamageFloat:Bind(self.RootNode, self.EuiResolution)
    self.IsOpen = true
    if type(self.OnOpenChanged) == 'function' then
        self.OnOpenChanged(true)
    end
    self:ShowCast()
    _G.REUtil:GetRE('SpecialItemStateRequest'):FireServer()
    _G.REUtil:GetRE('RequestItemBar'):FireServer()
    _G.REUtil:GetRE('RequestCastState'):FireServer()
    _G.REUtil:GetRE('RequestQuest'):FireServer()
    _G.REUtil:GetRE('RequestFishCombat'):FireServer()
    local combatRequest = {}
    self.CombatRequest = combatRequest
    local task = game:GetService('Task')
    if task and task.Delay then
        task:Delay(0.6, function()
            if self.IsOpen and self.CombatRequest == combatRequest then
                _G.REUtil:GetRE('RequestFishCombat'):FireServer()
            end
        end)
    end
    _G.REUtil:GetRE('RequestStory'):FireServer()
end

function ScreenHandler:CloseScreen()
    self:HideDialogue()
    self.CombatRequest = nil
    DamageFloat:Clear()
    self.IsOpen = false
    if type(self.OnOpenChanged) == 'function' then
        self.OnOpenChanged(false)
    end
    self.FailureUntil = nil
    self.FailureLanding = nil
    self.FailureNotice = nil
    self.CastState = nil
    self.SplashUntil = nil
    self:ShowCast()
end

function ScreenHandler:Destroy()
    self:Cleanup()
    self.RootNode = nil
end

return ScreenHandler
