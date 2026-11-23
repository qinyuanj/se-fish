local World = game:GetService('World')
local GameCfg = require('common.GameCfg')
local LocalAttackButton = require('client.LocalAttackButton')
local WeaponAim = require('client.WeaponAim')
local PressGesture = require('client.PressGesture')
local DamageFloat = require('client.DamageFloat')
local FishCombatLabel = require('client.FishCombatLabel')
local MainHudLayout = require('client.MainHudLayout')
local OwnedUnits = require('common.OwnedUnits')

local ScreenHandler = { UINodes = {}, UINodeMap = {} }

local AIM_OWNER = {}
ScreenHandler.AimOwner = AIM_OWNER

function ScreenHandler:Action(action, value)
    _G.REUtil:GetRE('ItemBarAction'):FireServer({ action = action, value = value })
end

function ScreenHandler:Operate(payload)
    self.OpSeq = (self.OpSeq or 0) + 1
    payload.seq = self.OpSeq
    payload.action = 'Operate'
    _G.REUtil:GetRE('ItemBarAction'):FireServer(payload)
end

function ScreenHandler:bindDrag(btn, container, index)
    if not btn.OnTouchBegan or not btn.OnTouchEnded then return end
    self:Listen(btn.OnTouchBegan, function(touch)
        self.DragSource = { container = container, index = index,
            began = touch and touch.BeganPosition }
    end)
    self:Listen(btn.OnTouchEnded, function(touch)
        local source = self.DragSource
        self.DragSource = nil
        if not source or source.container ~= container or source.index ~= index then return end
        local ended = touch and touch.EndedPosition
        if not ended or not source.began then return end
        if math.abs(ended.x - source.began.x) < 10 and math.abs(ended.y - source.began.y) < 10 then return end
        local target = self:SlotAtPosition(ended)
        if not target or target.container == source.container and target.index == source.index then return end
        self:Action('MoveSlot', { from = source.container, index = source.index,
            target = target.container, slot = target.index })
    end)
end

function ScreenHandler:SlotAtPosition(pos)
    if type(pos) ~= 'table' or type(pos.x) ~= 'number' or type(pos.y) ~= 'number' then return nil end
    for index, p in ipairs(self.ItemBarSlotPos or {}) do
        local slot = self.Slots and self.Slots[index]
        if slot and slot.Background.Visible
            and math.abs(pos.x - p.x) <= p.hw and math.abs(pos.y - p.y) <= p.hh then
            return { container = GameCfg.Items.ContainerId.ItemBar, index = index }
        end
    end
    return nil
end

local function nowSec()
    return World.GetServerTime and World:GetServerTime() or 0
end

function ScreenHandler:SlotDefinition(index)
    local entry = self.Snapshot and self.Snapshot.slots[index]
    return entry and GameCfg.Items.Definitions[entry.itemId] or nil
end

function ScreenHandler:IsExplosiveSlot(index)
    local definition = self:SlotDefinition(index)
    return definition ~= nil and definition.Type == '爆炸物'
end

function ScreenHandler:BindSlotGesture(btn, index)
    if not btn.OnTouchBegan or not btn.OnTouchEnded then return end
    self:Listen(btn.OnTouchBegan, function(touch)
        self.SlotPress = { index = index, gesture = PressGesture.New({
            LongPressSec = GameCfg.Ability.Throw.LongPressSec }) }
        self.SlotPress.gesture:Begin(nowSec(),
            touch and touch.BeganPosition or nil)
    end)
    self:Listen(btn.OnTouchEnded, function(touch)
        local press = self.SlotPress
        if not press or press.index ~= index then return end
        self.SlotPress = nil
        if not self:IsExplosiveSlot(index) then return end
        local result = press.gesture:End(nowSec(),
            touch and touch.EndedPosition or nil)
        if result == 'tap' then
            self.ThrowHandled = { index = index, valid = true }
            self:ThrowExplosive(index, nil)
        elseif result == 'long' then
            self.ThrowHandled = { index = index, valid = true }
            self:BeginAim(index)
        end
    end)
end

function ScreenHandler:ConsumeThrowClick(index)
    local handled = self.ThrowHandled
    if handled and handled.index == index and handled.valid then
        handled.valid = false
        return true
    end
    return false
end

function ScreenHandler:ThrowExplosive(slot, target)
    self.WeaponSeq = (self.WeaponSeq or 0) + 1
    local payload = { action = 'throw', slot = slot, seq = self.WeaponSeq }
    if type(target) == 'table' then payload.target = target end
    print('[ScreenMain] 投掷 slot=' .. tostring(slot) .. ' seq=' .. tostring(self.WeaponSeq))
    _G.REUtil:GetRE('WeaponAction'):FireServer(payload)
end

function ScreenHandler:BeginAim(slot)
    self:EndAim()
    if not self.UIRoot or not self.EuiResolution then return end
    self.AimSlot = slot
    local resolution = self.EuiResolution
    local overlay = OwnedUnits.Track(AIM_OWNER, World:CreateUnit('EUIButton', {
        Parent = self.UIRoot, Name = 'ThrowAimOverlay',
        Position = Vector2.New(resolution.x / 2, resolution.y / 2),
        Size = Vector2.New(resolution.x, resolution.y),
    }))
    if not overlay then self.AimSlot = nil return end
    overlay.ButtonText = ''
    pcall(function() overlay.ButtonNormalColor = Color.New(30, 40, 30, 40) end)
    pcall(function() overlay.ButtonPressColor = Color.New(30, 40, 30, 60) end)
    if _G.LocalMsgNotice then _G.LocalMsgNotice('点击屏幕选择投掷落点') end
    self:Listen(overlay.OnTouchEnded, function(touch) self:PickAim(touch) end)
end

function ScreenHandler:PickAim(touch)
    local pos = touch and touch.EndedPosition
    local slot = self.AimSlot
    self:EndAim()
    if not slot or not pos then return end
    local target
    local ok, ray = pcall(function()
        local camera = game:GetService('CameraService')
        return camera and camera:ScreenPointToRay(pos.x, pos.y,
            GameCfg.Ability.Throw.Range * 2)
    end)
    if ok and ray and ray.Origin and ray.Direction then
        local physics = game:GetService('PhysicsService')
        local hit = physics and physics.Raycast
            and physics:Raycast(ray.Origin, ray.Direction, nil)
        local p = hit and hit.Position
        if p then target = { x = p.x, y = p.y, z = p.z } end
    end
    self:ThrowExplosive(slot, target)
end

function ScreenHandler:EndAim()
    OwnedUnits.Clear(AIM_OWNER)
    self.AimSlot = nil
end

local function baitStock(state, id)
    local bait = type(state) == 'table' and type(state.bait) == 'table' and state.bait or {}
    local count = id ~= nil and bait[id] or nil
    return type(count) == 'number' and count or 0
end

local function wormCount(state)
    return baitStock(state, GameCfg.Items.Id.Worm)
end

local function heldSlot(state)
    local held = type(state) == 'table' and state.held
    return type(held) == 'table' and held.kind == 'slot' and held.slot or nil
end

function ScreenHandler:Show(state)
    if type(state) ~= 'table' or type(state.slots) ~= 'table' then return end
    local depleted = self.Snapshot ~= nil and wormCount(self.Snapshot) > 0 and wormCount(state) <= 0
    self.Snapshot = state
    LocalAttackButton:SetEquipped(state)
    local capacity = state.slotCount or GameCfg.Items.ItemBarSlots
    self:ApplyLayout(capacity, nil)
    for index, slot in ipairs(self.Slots or {}) do
        local entry = state.slots[index]
        local definition = entry and GameCfg.Items.Definitions[entry.itemId]
        slot.Background.Visible = index <= capacity
        slot.Background.TouchEnabled = index <= capacity
        slot.Icon.Visible = index <= capacity and definition ~= nil
        if definition then
            slot.Icon.Image = definition.Icon
            local tint = definition.IconColor
            slot.Icon.Color = Color.New(tint[1], tint[2], tint[3], tint[4])
        end
        slot.Label.Text = definition
            and ((GameCfg.Items.CookRate(entry) ~= nil and GameCfg.Grill.CookedPrefix or '') .. definition.Name) or ''
        slot.Label.Visible = index <= capacity and definition ~= nil
        slot.Count.Text = definition and tostring(entry.count) or ''
        slot.Count.Visible = index <= capacity and definition ~= nil
        slot.Background.ButtonNormalColor = index == state.selectedSlot
            and Color.New(36, 130, 94, 255) or Color.New(54, 100, 140, 255)
    end
    self:ShowCast()
    local selected = state.selectedSlot and state.slots[state.selectedSlot]
    self.BtnDiscard.Visible = selected ~= nil
    self.BtnDiscardLabel.Visible = selected ~= nil
    self.BtnDiscardLabel.Text = selected and heldSlot(state) == state.selectedSlot
        and '确认丢弃' or '丢弃选中物'
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

function ScreenHandler:SelectedFood()
    local state = self.Snapshot
    local slot = state and state.selectedSlot
    local entry = slot and state.slots[slot]
    local definition = entry and GameCfg.Items.Definitions[entry.itemId]
    if definition and type(definition.EatPercent) == 'number' then return entry, slot end
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

local function lineStillOut(phase)
    return phase == 'cast' or phase == 'unhooked'
end

local function selectedRod(state)
    local entry = state and state.selectedSlot and state.slots[state.selectedSlot]
    local definition = entry and GameCfg.Items.Definitions[entry.itemId]
    return definition ~= nil and type(definition.Level) == 'number'
end

function ScreenHandler:ItemActionMode()
    local phase = self.CastState and self.CastState.phase or 'idle'
    local drop = phase == 'idle' and self.CastState ~= nil and self.CastState.holding ~= nil
    if phase == 'idle' and not drop and self.SpecialEffect then return 'special' end
    if phase == 'hooked' then return 'hooked' end
    if lineStillOut(phase) then return 'lineOut' end
    if phase == 'landed' then return 'landed' end
    if drop then return 'drop' end
    if self:SelectedFood() then return 'food' end
    if selectedRod(self.Snapshot) then return 'rod' end
    return 'none'
end

local function foodActionText(self)
    local food, foodSlot = self:SelectedFood()
    local name = GameCfg.Items.Definitions[food.itemId].Name
    return heldSlot(self.Snapshot) == foodSlot and ('吃' .. name) or ('手持' .. name)
end

local function castActionColor(phase, now, alert)
    if not now then
        return phase == 'landed' and Color.New(120, 120, 120, 255)
            or Color.New(54, 100, 140, 255)
    end
    local k = (math.sin(now * 2 * math.pi / alert.BreathPeriodSec) + 1) / 2
    local h = alert.HighlightColor
    return Color.New(math.floor(54 + (h[1] - 54) * k),
        math.floor(100 + (h[2] - 100) * k), math.floor(140 + (h[3] - 140) * k), h[4])
end

local function fireCast(action, extra)
    local payload = { action = action }
    for key, value in pairs(extra or {}) do payload[key] = value end
    _G.REUtil:GetRE('CastAction'):FireServer(payload)
end

local function breathLeft(self)
    return self.BreathCooldownUntil and (self.BreathCooldownUntil - World:GetServerTime()) or 0
end

local SPECIAL_ACTIONS = {
    wings = {
        text = '长按飞行', enabled = true,
        pressBegan = function()
            _G.REUtil:GetRE('SpecialItemAction'):FireServer({ action = 'fly', holding = true })
        end,
    },
    godzilla = {
        text = function(self)
            local left = breathLeft(self)
            return left > 0 and string.format('吐息冷却 %d秒', math.ceil(left)) or '原子吐息'
        end,
        enabled = function(self) return breathLeft(self) <= 0 end,
        click = function(self)
            if breathLeft(self) <= 0 then _G.REUtil:GetRE('SpecialItemAction'):FireServer({ action = 'breath' }) end
        end,
    },
}
local UNKNOWN_SPECIAL = {}

local ITEM_ACTIONS = {
    hooked = {
        text = '点击收线',
        enabled = function(_, active) return active == true end,
        click = function(self)
            if _G.LocalReelIn.SessionId == self.CastState.reelSession then
                _G.LocalReelIn:Click()
                self:ShowCast()
            end
        end,
    },
    lineOut = { text = '收竿', enabled = true, click = function() fireCast('Reel') end },
    landed = { text = '已上岸', enabled = false },
    drop = { text = '放下', enabled = true, click = function() fireCast('Drop') end },
    food = {
        text = foodActionText, enabled = true,
        click = function(self)
            local _, slot = self:SelectedFood()
            self:Operate({ op = 'eat', slot = slot })
        end,
    },
    rod = {
        text = '抛竿', enabled = true,
        click = function(self)
            local slot = self.Snapshot.selectedSlot
            fireCast('Cast', { slot = slot, itemId = self.Snapshot.slots[slot].itemId })
        end,
    },
    none = {
        text = '使用', enabled = false, visible = false,
        click = function(self)
            if not self.Snapshot then return end
            self.FailureUntil = nil
            self.FailureLanding = nil
            self:ShowCast()
            self:ShowCastFailure({ reason = 'invalidRod' })
        end,
    },
}

local function itemAction(self, mode)
    if mode == 'special' then return SPECIAL_ACTIONS[self.SpecialEffect] or UNKNOWN_SPECIAL end
    return ITEM_ACTIONS[mode]
end

local function resolve(value, self, active)
    if type(value) == 'function' then return value(self, active) end
    return value
end

local function showItemAction(self, mode, phase, active, alertNow)
    local entry = itemAction(self, mode)
    local visible = entry.visible ~= false
    self.BtnItemAction.Visible = visible
    self.BtnItemActionLabel.Visible = visible
    self.BtnItemAction.ButtonNormalColor = castActionColor(phase, alertNow, GameCfg.HookAlert)
    local enabled = resolve(entry.enabled, self, active)
    if enabled ~= nil then self.BtnItemAction.TouchEnabled = self.IsOpen == true and enabled == true end
    local text = resolve(entry.text, self, active)
    if text ~= nil then self.BtnItemActionLabel.Text = text end
end

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
    if not self.BtnItemAction then return end
    local phase = self.CastState and self.CastState.phase or 'idle'
    local reel = _G.LocalReelIn
    local active = self.IsOpen and phase == 'hooked' and reel
        and reel.SessionId == self.CastState.reelSession
    self:ApplyLayout(nil, active == true)
    local now = active == true and self.HookAlertUntil ~= nil and World:GetServerTime()
    local alerting = now and now < self.HookAlertUntil
    showItemAction(self, self:ItemActionMode(), phase, active, alerting and now)
    local progress = castProgress(self, reel, active)
    if type(progress) ~= 'number' or progress ~= progress then progress = 50 end
    progress = math.max(0, math.min(100, progress))
    showCastFeedback(self, phase, active, alerting, progress)
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
    local fixed = {
        { self.BtnDiscard, self.BtnDiscardLabel },
        { self.BtnItemAction, self.BtnItemActionLabel }, { self.BtnReelClose, self.BtnReelCloseLabel },
    }
    for _, pair in ipairs(fixed) do
        local btn, label = pair[1], pair[2]
        if btn then
            btn.Visible = not hidden
            btn.TouchEnabled = not hidden
        end
        if label then label.Visible = not hidden end
    end
    local state = self.Snapshot
    for index, slot in ipairs(self.Slots or {}) do
        if state and type(state.slots) == 'table' then
            local capacity = state.slotCount or GameCfg.Items.ItemBarSlots
            local entry = state.slots[index]
            local hasItem = index <= capacity and entry ~= nil and GameCfg.Items.Definitions[entry.itemId] ~= nil
            slot.Background.Visible = not hidden and index <= capacity
            slot.Background.TouchEnabled = not hidden and index <= capacity
            slot.Icon.Visible = not hidden and hasItem
            slot.Label.Visible = not hidden and hasItem
            slot.Count.Visible = not hidden and hasItem
        else
            slot.Label.Visible = slot.Label.Visible and not hidden
            slot.Count.Visible = slot.Count.Visible and not hidden
        end
    end
    if not hidden then
        self:ShowCast()
        local selected = state and state.selectedSlot
            and state.slots and state.slots[state.selectedSlot]
        if self.BtnDiscard then self.BtnDiscard.Visible = selected ~= nil end
        if self.BtnDiscardLabel then self.BtnDiscardLabel.Visible = selected ~= nil end
    end
end

local function place(node, r)
    if not node or not r then return end
    node.Position = Vector2.New(r.x, r.y)
    node.Size = Vector2.New(r.w, r.h)
end

local function placeSlot(slot, r)
    local x, y, w, h = r.x, r.y, r.w, r.h
    slot.Background.Position = Vector2.New(x, y)
    slot.Background.Size = Vector2.New(w, h)
    slot.Icon.Position = Vector2.New(x, y + h * 0.1)
    slot.Icon.Size = Vector2.New(w * 0.6, h * 0.6)
    slot.Label.Position = Vector2.New(x, y - h * 0.34)
    slot.Label.Size = Vector2.New(w, h * 0.28)
    slot.Count.Position = Vector2.New(x + w * 0.33, y + h * 0.33)
    slot.Count.Size = Vector2.New(w * 0.32, h * 0.32)
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
    for index, slot in ipairs(self.Slots or {}) do
        local cell = layout.ItemBarSlots[index]
        if cell then
            placeSlot(slot, cell)
            self.ItemBarSlotPos[index] = { x = cell.x, y = cell.y, hw = cell.w / 2, hh = cell.h / 2 }
        end
    end
    place(self.BtnItemAction, r.ItemAction)
    place(self.BtnItemActionLabel, r.ItemAction)
    place(self.BtnDiscard, r.Discard)
    place(self.BtnDiscardLabel, r.Discard)
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
        FishCombatLabel:Clear()
    end)
    continueAfterFailure('CloseScreen', function() self:CloseScreen() end)
    continueAfterFailure('攻击键', function() LocalAttackButton:Destroy() end)
    continueAfterFailure('连接', function()
        for _, connection in ipairs(self.Connections or {}) do connection:Disconnect() end
    end)
    continueAfterFailure('OwnedUnits', function()
        OwnedUnits.Clear(AIM_OWNER)
        OwnedUnits.Clear(self)
    end)
    self.Connections = nil
    self.Slots = nil
    self.ItemBarSlotPos = nil
    self.BackpackOpen = false
    self.DragSource = nil
    self.UIRoot = nil
    self.LastOperateOperation = nil
    self.BtnDiscard = nil
    self.BtnItemAction = nil
    self.BtnReelClose = nil
    self.BtnReelCloseLabel = nil
    self.BtnDiscardLabel = nil
    self.BtnItemActionLabel = nil
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
    FishCombatLabel:Bind(root, resolution)
    local count = GameCfg.Items.ItemBarSlots
    local layout = MainHudLayout.Compute({ width = resolution.x, height = resolution.y,
        itemBarSlots = count, reeling = true })
    self.HudLayout = layout
    local rects = layout.Rects
    self.Slots = {}
    self.ItemBarSlotPos = {}
    self.Connections = {}
    for index = 1, count do
        local cell = layout.ItemBarSlots[index]
        local background = button(self, root, 'ItemBarSlot' .. index, cell.x, cell.y, cell.w)
        local icon = OwnedUnits.Track(self, World:CreateUnit('EUIImage', {
            Parent = root, Name = 'ItemBarIcon' .. index,
            Position = Vector2.New(cell.x, cell.y), Size = Vector2.New(cell.w, cell.h),
        }))
        icon.TouchEnabled = false
        icon.SwallowTouchEnabled = false
        icon.LocalZOrder = 1
        icon.Visible = false
        local label = overlay(self, root, 'ItemBarLabel' .. index, cell.x, cell.y, cell.w, cell.h,
            '', 18, Color.New(255, 255, 255, 255))
        local amount = overlay(self, root, 'ItemBarAmount' .. index, cell.x, cell.y, cell.w, cell.h,
            '', 20, Color.New(255, 220, 40, 255))
        label.Visible = false
        amount.Visible = false
        self.Slots[index] = { Background = background, Icon = icon, Label = label, Count = amount }
        placeSlot(self.Slots[index], cell)
        self.ItemBarSlotPos[index] = { x = cell.x, y = cell.y, hw = cell.w / 2, hh = cell.h / 2 }
        self:bindDrag(background, GameCfg.Items.ContainerId.ItemBar, index)
        self:BindSlotGesture(background, index)
        self:Listen(background.OnClicked, function()
            if self:ConsumeThrowClick(index) then return end
            self:Action('SelectSlot', index)
        end)
    end
    self.UIRoot = root
    self.BackpackOpen = self.BackpackOpen == true
    local discard = rects.Discard
    self.BtnDiscard = button(self, root, 'ItemDiscard', discard.x, discard.y, discard.w)
    local action, reelClose = rects.ItemAction, rects.ReelClose
    self.BtnItemAction = button(self, root, 'ItemAction2', action.x, action.y, action.w)
    self.BtnReelClose = button(self, root, 'ReelClose', reelClose.x, reelClose.y, reelClose.w)
    place(self.BtnDiscard, discard)
    place(self.BtnItemAction, action)
    place(self.BtnReelClose, reelClose)
    local labels = {
        { 'BtnReelCloseLabel', self.BtnReelClose, '结束收线' },
        { 'BtnDiscardLabel', self.BtnDiscard, '丢弃选中物' },
        { 'BtnItemActionLabel', self.BtnItemAction, '抛竿' },
    }
    for _, entry in ipairs(labels) do
        local btn = entry[2]
        local label = overlay(self, root, entry[1], btn.Position.x, btn.Position.y,
            btn.Size.x, btn.Size.y, entry[3], 30, Color.New(255, 255, 255, 255))
        self[entry[1]] = label
    end
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
    self.BtnItemAction.TouchEnabled = false
    self.BtnItemAction.Visible = false
    self.BtnItemActionLabel.Visible = false
    self.BtnReelClose.Visible = false
    self.BtnReelCloseLabel.Visible = false
    self:Listen(self.BtnReelClose.OnClicked, function()
        _G.LocalReelIn:Close()
        self:ShowCast()
    end)
    self.BtnDiscard.Visible = false
    self.BtnDiscardLabel.Visible = false
    self:Listen(self.BtnItemAction.OnClicked, function()
        if not self.IsOpen then return end
        local click = itemAction(self, self:ItemActionMode()).click
        if click then click(self) end
    end)
    if self.BtnItemAction.OnTouchBegan and self.BtnItemAction.OnTouchEnded then
        self:Listen(self.BtnItemAction.OnTouchBegan, function()
            if not self.IsOpen then return end
            local pressBegan = itemAction(self, self:ItemActionMode()).pressBegan
            if pressBegan then pressBegan(self) end
        end)
        self:Listen(self.BtnItemAction.OnTouchEnded, function()
            if self.SpecialEffect == 'wings' then
                _G.REUtil:GetRE('SpecialItemAction'):FireServer({ action = 'fly', holding = false })
            end
        end)
    end
    self:Listen(self.BtnDiscard.OnClicked, function()
        if self.Snapshot and self.Snapshot.selectedSlot then
            self:Operate({ op = 'discard', slot = self.Snapshot.selectedSlot })
        end
    end)
    self:Listen(_G.REUtil:GetRE('ItemBarState').OnClientEvent, function(state) self:Show(state) end)
    self:Listen(_G.REUtil:GetRE('SpecialItemState').OnClientEvent, function(state)
        if type(state) ~= 'table' then return end
        self.SpecialEffect = state.effect
        if type(state.breathRemaining) == 'number' and state.breathRemaining > 0 then
            self.BreathCooldownUntil = World:GetServerTime() + state.breathRemaining
        else
            self.BreathCooldownUntil = nil
        end
        if self.BtnItemAction then self:ShowCast() end
    end)
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
            _G.REUtil:GetRE('WeaponAction'):FireServer(WeaponAim:AttackPayload())
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
    self:Listen(_G.REUtil:GetRE('WeaponResult').OnClientEvent, function(result)
        if type(result) ~= 'table' or result.ok ~= false then return end
        local hints = { ['cannot-act'] = '现在不能攻击', unavailable = '武器未就绪',
            cooldown = '出手太快', reloading = '换弹中', empty = '弹匣已空，自动换弹',
            ['not-a-gun'] = '手持的不是枪械', ['mag-full'] = '弹匣是满的',
            ['bad-slot'] = '格子不存在', ['bad-throwable'] = '这个不能投掷',
            ['bad-target'] = '落点无效', ['bad-weapon'] = '武器未配置' }
        if _G.LocalMsgNotice then
            _G.LocalMsgNotice(hints[result.reason] or ('武器操作失败 ' .. tostring(result.reason)))
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
                _G.LocalReelIn:Clear(self.CastState and self.CastState.reelSession)
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
            _G.LocalReelIn:SetSession(state.reelSession)
            self:StartHookAlert(state.reelSession)
        else
            _G.LocalReelIn:Clear(self.CastState and self.CastState.reelSession)
        end
        self.CastState = state
        self:ShowCast()
    end)
    self:Listen(_G.REUtil:GetRE('DamageNotice').OnClientEvent, function(payload)
        if self.IsOpen then DamageFloat:Show(payload) end
    end)
    self:Listen(_G.REUtil:GetRE('FishCombatState').OnClientEvent, function(payload)
        if self.IsOpen then FishCombatLabel:Apply(payload) end
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
            if self.BreathCooldownUntil and self.SpecialEffect == 'godzilla' then
                if self.BreathCooldownUntil > World:GetServerTime() then
                    self:ShowCast()
                else
                    self.BreathCooldownUntil = nil
                    self:ShowCast()
                end
            end
            if self.CastFloat and self.IsOpen then self:UpdateCastFeedback() end
            DamageFloat:Update()
            FishCombatLabel:Update()
        end)
    end
    LocalAttackButton:Start(root, rects.AttackControl)
    self.LayoutKey = { slots = count, reeling = true }
    self.BoundRootNode = root
    self.Inited = true
    self.IsOpen = false
    if _G.LocalReelIn then _G.LocalReelIn:Suspend() end
end

function ScreenHandler:OpenScreen()
    DamageFloat:Bind(self.RootNode, self.EuiResolution)
    FishCombatLabel:Bind(self.RootNode, self.EuiResolution)
    self.IsOpen = true
    if type(self.OnOpenChanged) == 'function' then
        self.OnOpenChanged(true)
    end
    LocalAttackButton:SetOpen(true)
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
    FishCombatLabel:Clear()
    self.IsOpen = false
    if type(self.OnOpenChanged) == 'function' then
        self.OnOpenChanged(false)
    end
    self.FailureUntil = nil
    self.FailureLanding = nil
    self.FailureNotice = nil
    self:EndAim()
    LocalAttackButton:SetOpen(false)
    if _G.LocalReelIn then _G.LocalReelIn:Suspend() end
    self.CastState = nil
    self.SplashUntil = nil
    self:ShowCast()
end

function ScreenHandler:Destroy()
    self:Cleanup()
    self.RootNode = nil
end

return ScreenHandler
