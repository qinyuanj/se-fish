local World = game:GetService('World')
local GameCfg = require('common.GameCfg')
local LocalAttackButton = require('client.LocalAttackButton')
local WeaponAim = require('client.WeaponAim')
local PressGesture = require('client.PressGesture')
local DamageFloat = require('client.DamageFloat')
local FishCombatLabel = require('client.FishCombatLabel')
local MainHudLayout = require('client.MainHudLayout')

local ScreenHandler = { UINodes = {}, UINodeMap = {} }

function ScreenHandler:Action(action, value)
    _G.REUtil:GetRE('ItemBarAction'):FireServer({ action = action, value = value })
end

-- #124 两步操作（吃/丢弃/攻击）：每次请求带单调 seq，服务端回包带 operation 身份，
-- 断线重试可凭 seq 或原 identity 续发，重复结算由服务端操作日志挡掉。
function ScreenHandler:Operate(payload)
    self.OpSeq = (self.OpSeq or 0) + 1
    payload.seq = self.OpSeq
    payload.action = 'Operate'
    _G.REUtil:GetRE('ItemBarAction'):FireServer(payload)
end

-- #124 双向拖拽：触摸起点记源格，抬起位置命中其他格发 MoveSlot；
-- 原地（点击）与拖出格区都不发请求，容器与槽位由服务端复验。
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
    for index, p in ipairs(self.BackpackSlotPos or {}) do
        local entry = self.BackpackSlots and self.BackpackSlots[index]
        if entry and entry.Button.Visible
            and math.abs(pos.x - p.x) <= 47 and math.abs(pos.y - p.y) <= 45 then
            return { container = GameCfg.Items.ContainerId.Backpack, index = index }
        end
    end
    return nil
end

-- ===== #129 投掷（爆炸物槽位手势：点按=直接投 20 米，长按=瞄准选点） =====
-- 手势与冷却统一使用服务器时刻；SE 沙盒不提供 os
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

-- 槽位按压手势：OnClicked 与手势都会响应一次点按，用标志位保证只消费一次
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
            self:ThrowExplosive(index, nil) -- 直接投：朝向前方票面 20 米
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

-- 投掷消耗持久物，走 #124 同款单调 seq：服务端按 #123 协议幂等去重
function ScreenHandler:ThrowExplosive(slot, target)
    self.WeaponSeq = (self.WeaponSeq or 0) + 1
    local payload = { action = 'throw', slot = slot, seq = self.WeaponSeq }
    if type(target) == 'table' then payload.target = target end
    print('[ScreenMain] 投掷 slot=' .. tostring(slot) .. ' seq=' .. tostring(self.WeaponSeq))
    _G.REUtil:GetRE('WeaponAction'):FireServer(payload)
end

-- 长按进入瞄准：全屏拾取层，点哪里投哪里（落点服务端再钳到 20 米内）
function ScreenHandler:BeginAim(slot)
    self:EndAim()
    if not self.UIRoot or not self.EuiResolution then return end
    self.AimSlot = slot
    local resolution = self.EuiResolution
    local overlay = World:CreateUnit('EUIButton', {
        Parent = self.UIRoot, Name = 'ThrowAimOverlay',
        Position = Vector2.New(resolution.x / 2, resolution.y / 2),
        Size = Vector2.New(resolution.x, resolution.y),
    })
    if not overlay then self.AimSlot = nil return end
    overlay.ButtonText = ''
    pcall(function() overlay.ButtonNormalColor = Color.New(30, 40, 30, 40) end)
    pcall(function() overlay.ButtonPressColor = Color.New(30, 40, 30, 60) end)
    self.AimOverlay = overlay
    if _G.LocalMsgNotice then _G.LocalMsgNotice('点击屏幕选择投掷落点') end
    self:Listen(overlay.OnTouchEnded, function(touch) self:PickAim(touch) end)
end

function ScreenHandler:PickAim(touch)
    local pos = touch and touch.EndedPosition
    local slot = self.AimSlot
    self:EndAim()
    if not slot or not pos then return end
    -- [未查证：ScreenPointToRay 的 depth 语义按射线长度处理]，无命中时回退直接投掷
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
    if self.AimOverlay then
        pcall(function() self.AimOverlay:Destroy() end)
    end
    self.AimOverlay = nil
    self.AimSlot = nil
end

-- 快照里某种鱼饵的库存，缺失或非数字按 0（鱼饵栏文字、候选格、「蚯蚓用尽」共用这一处）
local function baitStock(state, id)
    local bait = type(state) == 'table' and type(state.bait) == 'table' and state.bait or {}
    local count = id ~= nil and bait[id] or nil
    return type(count) == 'number' and count or 0
end

local function wormCount(state)
    return baitStock(state, GameCfg.Items.Id.Worm)
end

-- 服务端确认手持的道具栏格号（手持的不是道具栏格时为 nil）
local function heldSlot(state)
    local held = type(state) == 'table' and state.held
    return type(held) == 'table' and held.kind == 'slot' and held.slot or nil
end

function ScreenHandler:Show(state)
    if type(state) ~= 'table' or type(state.slots) ~= 'table' then return end
    -- #180「蚯蚓用尽」：只在蚯蚓从有到无的那一次快照报，开局即 0 或一直是 0 都不报
    local depleted = self.Snapshot ~= nil and wormCount(self.Snapshot) > 0 and wormCount(state) <= 0
    self.Snapshot = state
    LocalAttackButton:SetEquipped(state) -- #129：攻击按钮语义随装备走（攻击/射击/连发/换弹）
    local capacity = state.slotCount or GameCfg.Items.ItemBarSlots
    self:ApplyLayout(capacity, nil) -- #179：开放格数变化时按布局重排装备栏
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
        -- #137：烤过的物品名字加前缀；CookRate 统一口径（含旧布尔档 saved.cooked==true）
        slot.Label.Text = definition
            and ((GameCfg.Items.CookRate(entry) ~= nil and GameCfg.Grill.CookedPrefix or '') .. definition.Name) or ''
        slot.Label.Visible = index <= capacity and definition ~= nil
        slot.Count.Text = definition and tostring(entry.count) or ''
        slot.Count.Visible = index <= capacity and definition ~= nil
        slot.Background.ButtonNormalColor = index == state.selectedSlot
            and Color.New(36, 130, 94, 255) or Color.New(54, 100, 140, 255)
    end
    -- 鱼饵（蚯蚓、香肠、鸭子、动态鱼饵）与武器的选择、吃蚯蚓都在武器栏 / 鱼饵栏弹窗里（#180）；
    -- 选中格食物的两步进食在道具按钮上（#181）
    self:ShowCoin(state.coin)
    self:ShowCast()
    local selected = state.selectedSlot and state.slots[state.selectedSlot]
    self.BtnDiscard.Visible = selected ~= nil
    self.BtnDiscardLabel.Visible = selected ~= nil
    self.BtnDiscardLabel.Text = selected and heldSlot(state) == state.selectedSlot
        and '确认丢弃' or '丢弃选中物'
    self:RenderEquipBars(state)
    self:ShowBackpack()
    if depleted then self:ShowCastFailure({ reason = 'wormDepleted' }) end
end

-- 上钩提示（#54）：同一收线会话只触发一次；提示音缺失或播放失败时只保留文字与高亮
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

-- 选中格里能吃的物品（配了 EatPercent 的鱼获），没有返回 nil
function ScreenHandler:SelectedFood()
    local state = self.Snapshot
    local slot = state and state.selectedSlot
    local entry = slot and state.slots[slot]
    local definition = entry and GameCfg.Items.Definitions[entry.itemId]
    if definition and type(definition.EatPercent) == 'number' then return entry, slot end
end

local function readVital(player, key, default)
    local value = tonumber(player:GetAttribute(key))
    return value and math.floor(value) or default
end

-- 球上文字前缀（术语见 GLOSSARY「饥饿度」）
local HEALTH_PREFIX, HUNGER_PREFIX = '血 ', '饥饿度 '

local function vitalPercent(value, maximum)
    return maximum > 0 and math.max(0, math.min(100, value * 100 / maximum)) or 0
end

local function updateStarving(self, health, hunger)
    local starving = hunger <= 0 and health > 0
    if starving and not self.Starving then self.NextWarnAt = nil end
    self.Starving = starving
    self:UpdateStarveFx()
end

-- 血球 / 饥饿度球（#53）：数值只读服务端写的玩家属性 Health / MaxHealth / Hunger / MaxHunger
function ScreenHandler:ShowVitals()
    if not self.HealthRing then return end
    local player = game:GetService('Players').LocalPlayer
    if not player then return end
    local c = GameCfg.Vitals
    local health = readVital(player, 'Health', c.MaxHealth)
    local maxHealth = readVital(player, 'MaxHealth', c.MaxHealth)
    local hunger = readVital(player, 'Hunger', c.MaxHunger)
    local maxHunger = readVital(player, 'MaxHunger', c.MaxHunger)
    self.HealthRing.Percent = vitalPercent(health, maxHealth)
    self.HungerRing.Percent = vitalPercent(hunger, maxHunger)
    self.HealthText.Text = HEALTH_PREFIX .. tostring(health)
    self.HungerText.Text = HUNGER_PREFIX .. tostring(hunger)
    updateStarving(self, health, hunger)
end

local function warnStarving(self, now, config)
    if self.NextWarnAt and now < self.NextWarnAt then return end
    self.NextWarnAt = now + config.WarnIntervalSec
    if _G.LocalMsgNotice then _G.LocalMsgNotice(config.WarnText) end
    print('[ScreenMain] 饥饿提示', config.WarnText)
end

local function flashVisible(self, now, config)
    return self.Starving == true and math.floor(now / config.FlashPeriodSec) % 2 == 0
end

-- 饥饿归零期间：四边红框按 FlashPeriodSec 亮灭，WarnText 每 WarnIntervalSec 秒提示一次（不刷屏）
function ScreenHandler:UpdateStarveFx()
    if not self.FlashEdges then return end
    local c = GameCfg.Vitals
    local now = World:GetServerTime()
    local on = flashVisible(self, now, c)
    for _, edge in ipairs(self.FlashEdges) do edge.Visible = on end
    if self.Starving then warnStarving(self, now, c) end
end

-- 金币 HUD（#47）：接回场景既有的 ImageCoin / LabelCoin，以服务端同步的 FishCoin 属性为准
function ScreenHandler:ShowCoin(value)
    if not self.LabelCoin then return end
    if type(value) ~= 'number' then
        local players = game:GetService('Players')
        local player = players and players.LocalPlayer
        value = player and player:GetAttribute('FishCoin')
    end
    self.LabelCoin.Text = tostring(math.floor(tonumber(value) or 0))
end

-- 按列数折行（中文按一字一列，ASCII 也按整列算，宁宽勿溢）
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

-- 新手任务追踪条（#51，#179 改到左侧任务区）：「新手任务 步号/总数：文案（计数）」按追踪条宽度折行，
-- 以服务端 QuestState 为准；推进那一次带 notice，走既有消息条提示下一步
function ScreenHandler:ShowQuest(state)
    if not self.QuestLabel or type(state) ~= 'table' or type(state.text) ~= 'string' then return end
    local columns = math.max(1, math.floor(self.QuestLabel.Size.x / self.QuestLabel.FontSize))
    self.QuestLabel.Text = wrapColumns(state.text, columns)
    self.QuestShown = true
    self:RenderQuest()
    if type(state.notice) == 'string' and _G.LocalMsgNotice then _G.LocalMsgNotice(state.notice) end
end

-- 折叠 / 展开（#179）：折叠状态 QuestCollapsed 只存在客户端处理器上，不发服务端、不进存档；
-- 重进界面（Cleanup）不清它，任务文字刷新也不改它
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

-- 服务端会发的抛竿阶段（#133 增补 unhooked：脱钩后线还在水里）。白名单外的回包一律丢弃，
-- 免得迟到 / 旧回包把界面拉回一个不存在的状态。
local CAST_PHASES = { idle = true, cast = true, hooked = true, landed = true, unhooked = true }

-- 线还在水里的阶段：还没上钩的 cast，与鱼已脱钩但没收竿的 unhooked；都按「收竿」一次收回
local function lineStillOut(phase)
    return phase == 'cast' or phase == 'unhooked'
end

-- 选中格是不是鱼竿（物品表配了 Level）
local function selectedRod(state)
    local entry = state and state.selectedSlot and state.slots[state.selectedSlot]
    local definition = entry and GameCfg.Items.Definitions[entry.itemId]
    return definition ~= nil and type(definition.Level) == 'number'
end

-- 道具按钮（#181）：显示与点击共用同一份优先级判定，避免两边各判一套而不一致。
-- 特殊道具（空闲）> 上钩 > 鱼线在外 > 上岸停留 > 手持鱼获 > 手持食物 > 手持鱼竿 > 其他。
-- 「空闲」指没有抛竿且头上没顶着鱼：顶着鱼时先放下（沿用 #140 起的显示语义）。
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
    -- 上岸停留期间按钮灰化（#37），其余时候用常规底色
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

-- 原子吐息冷却剩余秒数（本地按服务端权威剩余秒数起的倒计时），不在冷却时为 0
local function breathLeft(self)
    return self.BreathCooldownUntil and (self.BreathCooldownUntil - World:GetServerTime()) or 0
end

-- 道具按钮各档（#181）：文字、可点、点击、长按集中在一张表里，显示、点击与长按都只经 itemAction 分派。
-- text / enabled 为常量或 function(self, active)；enabled 之外还要求界面开着；visible 缺省为真；
-- click / pressBegan 缺省表示不响应。
-- #140 特殊道具：空闲且服务端生效效果（SpecialItemState.effect）存在时，
-- 道具按钮从钓鱼语义切换为「长按飞行」（风神之翼）/「原子吐息」（哥斯拉）；
-- 冷却用本地墙钟倒计时展示（服务端每次状态推送带来权威剩余秒数）。
local SPECIAL_ACTIONS = {
    -- 风神之翼：长按升空、松开缓降（松开在 OnTouchEnded 里按效果发送）；点击不做事
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
-- 服务端只会下发上面两种效果；万一是别的，按钮可见但文字、可点保持原样（text / enabled 为 nil）
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
    -- 两步进食（#53/#124）：首次只切手持，服务端快照确认手持该格后再点才真吃
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
    -- 其他：按钮隐藏；强行点击时给「请重新选择鱼竿」
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
    -- 收线中显示本地反馈并平滑追平权威进度（#38）；其余时候显示最后一次权威值
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

-- 上方提示区的临时提示通道（HintTransient）：抛竿失败与客户端状态提示共用，白名单外的 reason 丢弃
local castFailureText = {
    wormDepleted = '蚯蚓用尽', -- #180：客户端按库存快照判定，服务端不发
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

-- 只做提示、不算抛竿失败的 reason：不打断「等待上钩」、入水提示与浮标，新抛竿也不清掉它
-- （抛竿一刻扣掉最后一只蚯蚓时，库存快照与「已入水」的先后不定）
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

-- 新的抛竿反馈到来时清掉旧的失败提示；只做提示的（如蚯蚓用尽）留到自然消失
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
    self:ApplyLayout(nil, active == true) -- #179：收线期间「结束收线」按布局占位
    -- 上钩提示（#54）：本收线会话的前 DurationSec 秒按钮呼吸式高亮、文字改为提示语
    local now = active == true and self.HookAlertUntil ~= nil and World:GetServerTime()
    local alerting = now and now < self.HookAlertUntil
    -- #140：空闲且特殊道具生效时按钮让给飞行 / 吐息；钓鱼各阶段保持钓鱼语义
    showItemAction(self, self:ItemActionMode(), phase, active, alerting and now)
    local progress = castProgress(self, reel, active)
    if type(progress) ~= 'number' or progress ~= progress then progress = 50 end
    progress = math.max(0, math.min(100, progress))
    showCastFeedback(self, phase, active, alerting, progress)
    self:UpdateCastFeedback()
end

local function button(parent, name, x, y, width)
    local btn = World:CreateUnit('EUIButton', {
        Parent = parent, Name = name,
        Position = Vector2.New(x, y), Size = Vector2.New(width, 90),
    })
    btn.TouchEnabled = true
    btn.ButtonText = ''
    btn.NormalImage = 'official://image/11017'
    btn.PressImage = 'official://image/11017'
    btn.DisableImage = 'official://image/11017'
    btn.ButtonNormalColor = Color.New(54, 100, 140, 255)
    return btn
end

local function overlay(parent, name, x, y, width, height, text, size, color)
    local label = World:CreateUnit('EUITextLabel', {
        Parent = parent, Name = name,
        Position = Vector2.New(x, y), Size = Vector2.New(width, height),
        Text = text, FontSize = size, TextColor = color,
    })
    -- #174 #18：按钮与提示文字在自身框内水平、垂直居中（枚举 Center = 1，同 LocalAttackButton）
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

-- 文字列数：中文按一字一列，ASCII 也按整列算（同 wrapColumns，宁宽勿溢）
local function columnsOf(text)
    local count = 0
    for _ in text:gmatch('[%z\1-\127\194-\244][\128-\191]*') do count = count + 1 end
    return count
end

-- 球上文字字号：按满值时最长的文字（如「饥饿度 300」）放得进球宽来定，最大 20
local VITAL_FONT_MAX = 20
local function vitalFontSize(width, c)
    local longest = math.max(columnsOf(HEALTH_PREFIX .. tostring(c.MaxHealth)),
        columnsOf(HUNGER_PREFIX .. tostring(c.MaxHunger)))
    return math.max(1, math.min(VITAL_FONT_MAX, math.floor(width / longest)))
end

-- 左上状态区血球 / 饥饿度球（#53，#179 位置取自布局模块）与四边红框；图片用途见 GameCfg.Vitals
function ScreenHandler:BuildVitals(root, resolution, layout)
    local c = GameCfg.Vitals
    local rings = {
        { 'Health', layout.Rects.HealthRing, c.HealthRing, c.HealthColor },
        { 'Hunger', layout.Rects.HungerRing, c.HungerRing, c.HungerColor },
    }
    for _, spec in ipairs(rings) do
        local name, r = spec[1], spec[2]
        local bg = passive(World:CreateUnit('EUIImage', {
            Parent = root, Name = name .. 'RingBg',
            Position = Vector2.New(r.x, r.y), Size = Vector2.New(r.w, r.h), Image = c.RingBg,
        }))
        local ring = passive(World:CreateUnit('EUIProgressTimer', {
            Parent = root, Name = name .. 'Ring',
            Position = Vector2.New(r.x, r.y), Size = Vector2.New(r.w, r.h), Image = spec[3], Percent = 100,
        }))
        ring.Color = color(spec[4])
        ring.LocalZOrder = 1
        local text = overlay(root, name .. 'Text', r.x, r.y, r.w, 40, '', vitalFontSize(r.w, c),
            Color.New(255, 255, 255, 255))
        text.LocalZOrder = 2
        self[name .. 'Ring'] = ring
        self[name .. 'Text'] = text
        self.Overlays[#self.Overlays + 1] = bg
        self.Overlays[#self.Overlays + 1] = ring
        self.Overlays[#self.Overlays + 1] = text
    end
    local t, w, h = c.FlashThickness, resolution.x, resolution.y
    local edges = {
        { 'FlashTop', w / 2, h - t / 2, w, t }, { 'FlashBottom', w / 2, t / 2, w, t },
        { 'FlashLeft', t / 2, h / 2, t, h }, { 'FlashRight', w - t / 2, h / 2, t, h },
    }
    self.FlashEdges = {}
    for _, spec in ipairs(edges) do
        local edge = passive(World:CreateUnit('EUIImage', {
            Parent = root, Name = spec[1],
            Position = Vector2.New(spec[2], spec[3]), Size = Vector2.New(spec[4], spec[5]), Image = c.FlashImage,
        }))
        edge.Color = color(c.FlashColor)
        edge.LocalZOrder = 3
        edge.Visible = false
        self.FlashEdges[#self.FlashEdges + 1] = edge
        self.Overlays[#self.Overlays + 1] = edge
    end
end

-- #174 #13：背包打开时收起面板覆盖区内的固定键、装备栏两格与文字标签；关闭后按当前快照恢复
function ScreenHandler:ApplyBackpackOcclusion()
    local hidden = self.BackpackOpen == true
    -- #180：开着的弹窗随背包打开直接关闭，关背包时不复活
    if hidden and self.OpenPopup then self:ClosePopup() end
    local fixed = {
        { self.BtnDiscard, self.BtnDiscardLabel },
        { self.BtnItemAction, self.BtnItemActionLabel }, { self.BtnReelClose, self.BtnReelCloseLabel },
    }
    for _, entry in pairs(self.EquipBars or {}) do fixed[#fixed + 1] = { entry.Button, entry.Label } end
    for _, pair in ipairs(fixed) do
        local btn, label = pair[1], pair[2]
        if btn then
            btn.Visible = not hidden
            btn.TouchEnabled = not hidden
        end
        if label then label.Visible = not hidden end
    end
    for _, slot in ipairs(self.Slots or {}) do
        slot.Label.Visible = slot.Label.Visible and not hidden
        slot.Count.Visible = slot.Count.Visible and not hidden
    end
    if not hidden then
        -- 恢复既有显隐规则：道具按钮交给 ShowCast，丢弃键按快照重算，装备栏两格按快照重刷
        self:ShowCast()
        local selected = self.Snapshot and self.Snapshot.selectedSlot
            and self.Snapshot.slots and self.Snapshot.slots[self.Snapshot.selectedSlot]
        self.BtnDiscard.Visible = selected ~= nil
        self.BtnDiscardLabel.Visible = selected ~= nil
        if self.Snapshot then self:RenderEquipBars(self.Snapshot) end
    end
end

function ScreenHandler:ShowBackpack()
    if not self.BackpackButton or not self.Snapshot then return end
    local state = self.Snapshot
    if type(state.backpackCount) ~= 'number' then return end
    self.BackpackLabel.Text = '背包 ' .. tostring(state.backpackCount) .. ' 格'
    self.BackpackPanel.Visible = self.BackpackOpen == true
    self.BackpackTitle.Visible = self.BackpackOpen == true
    for index, slot in ipairs(self.Slots or {}) do
        slot.Background.Visible = not self.BackpackOpen and index <= state.slotCount
        slot.Background.TouchEnabled = slot.Background.Visible
        slot.Icon.Visible = slot.Icon.Visible and not self.BackpackOpen
        slot.Label.Visible = slot.Label.Visible and not self.BackpackOpen
        slot.Count.Visible = slot.Count.Visible and not self.BackpackOpen
    end
    for index, slot in ipairs(self.BackpackSlots) do
        local visible = self.BackpackOpen == true and index <= state.backpackCount
        local entry = state.backpack and state.backpack[index]
        local definition = entry and GameCfg.Items.Definitions[entry.itemId]
        slot.Button.Visible = visible
        slot.Button.TouchEnabled = visible and definition ~= nil
        slot.Label.Visible = visible
        -- #137：烤过的物品名字加前缀；CookRate 统一口径（含旧布尔档 saved.cooked==true）
        slot.Label.Text = definition
            and ((GameCfg.Items.CookRate(entry) ~= nil and GameCfg.Grill.CookedPrefix or '') .. definition.Name) or '空'
        slot.Button.ButtonNormalColor = index == self.SelectedBackpackSlot
            and Color.New(36, 130, 94, 255) or Color.New(120, 168, 200, 255)
    end
    local entry = state.backpack and state.backpack[self.SelectedBackpackSlot]
    self.MoveButton.Visible = self.BackpackOpen == true and entry ~= nil
    self.MoveLabel.Visible = self.MoveButton.Visible
    self.MoveButton.TouchEnabled = self.MoveButton.Visible
    local free = false
    for index = 1, state.slotCount do
        if not state.slots[index] then free = true break end
    end
    if self.BackpackOpen and entry and not free then
        self.MoveLabel.Text = '道具栏已满'
        self.MoveButton.TouchEnabled = false
    else
        self.MoveLabel.Text = '转入道具栏'
    end
    -- #174 #13：背包面板盖住的鱼饵键、武器条与文字标签一起隐藏，点面板不会点到下层；
    -- 放在 ShowBackpack 末尾，关闭时恢复逻辑能看到刚重算的道具栏显隐
    self:ApplyBackpackOcclusion()
end

-- #179：背包按钮在底部装备栏（随道具栏格数重排，见 ApplyLayout）；面板位置取自布局模块，
-- 面板内部排版不变：标题、背包格、转入按钮都按面板中心的固定偏移摆放
function ScreenHandler:BuildBackpack(root, layout)
    local entry, panelRect = layout.Rects.BackpackButton, layout.Panels.BackpackPanel
    local center, cy = panelRect.x, panelRect.y
    self.BackpackOpen = false
    self.BackpackSlots = {}
    self.BackpackSlotPos = {}
    self.BackpackButton = button(root, 'BtnBackpack', entry.x, entry.y, entry.w)
    self.BackpackButton.Size = Vector2.New(entry.w, entry.h)
    self.BackpackLabel = overlay(root, 'LabelBackpack', entry.x, entry.y, entry.w, entry.h,
        '背包', 22, Color.New(255, 255, 255, 255))
    self.BackpackPanel = button(root, 'BackpackPanel', center, cy, panelRect.w)
    self.BackpackPanel.Size = Vector2.New(panelRect.w, panelRect.h)
    self.BackpackPanel.TouchEnabled = false
    -- #174 #14：面板用深色，背包格用浅色，空格不再只剩一个「空」字
    self.BackpackPanel.ButtonNormalColor = Color.New(30, 46, 66, 240)
    self.BackpackTitle = overlay(root, 'BackpackTitle', center, cy + 290, 700, 48,
        '选择背包物品，再转入道具栏', 28, Color.New(255, 255, 255, 255))
    for index = 1, GameCfg.Items.MaxBackpackSlots do
        local col, row = (index - 1) % 8, math.floor((index - 1) / 8)
        local x, y = center - 350 + col * 100, cy + 200 - row * 100
        local btn = button(root, 'BackpackSlot' .. index, x, y, 95)
        btn.Size = Vector2.New(95, 90)
        btn.ButtonNormalColor = Color.New(120, 168, 200, 255)
        local label = overlay(root, 'BackpackLabel' .. index, x, y, 95, 80,
            '', 19, Color.New(255, 255, 255, 255))
        self.BackpackSlots[index] = { Button = btn, Label = label }
        self.BackpackSlotPos[index] = { x = x, y = y }
        self:bindDrag(btn, GameCfg.Items.ContainerId.Backpack, index)
        self.Buttons[#self.Buttons + 1] = btn
        self.Overlays[#self.Overlays + 1] = label
        self:Listen(btn.OnClicked, function()
            self.SelectedBackpackSlot = index
            self:ShowBackpack()
        end)
    end
    self.MoveButton = button(root, 'BtnMoveToItemBar', center, cy - 310, 330)
    self.MoveLabel = overlay(root, 'LabelMoveToItemBar', center, cy - 310, 330, 70,
        '转入道具栏', 26, Color.New(255, 255, 255, 255))
    self.Buttons[#self.Buttons + 1] = self.BackpackButton
    self.Buttons[#self.Buttons + 1] = self.BackpackPanel
    self.Buttons[#self.Buttons + 1] = self.MoveButton
    self.Overlays[#self.Overlays + 1] = self.BackpackLabel
    self.Overlays[#self.Overlays + 1] = self.BackpackTitle
    self.Overlays[#self.Overlays + 1] = self.MoveLabel
    self:Listen(self.BackpackButton.OnClicked, function()
        self.BackpackOpen = not self.BackpackOpen
        self.SelectedBackpackSlot = nil
        if self.Snapshot then self:Show(self.Snapshot) end
    end)
    self:Listen(self.MoveButton.OnClicked, function()
        if self.SelectedBackpackSlot then self:Action('MoveToItemBar', self.SelectedBackpackSlot) end
    end)
    self.BackpackPanel.Visible = false
    self.BackpackTitle.Visible = false
    self.MoveButton.Visible = false
    self.MoveLabel.Visible = false
    for _, slot in ipairs(self.BackpackSlots) do
        slot.Button.Visible = false
        slot.Label.Visible = false
    end
end

local function place(node, r)
    if not node or not r then return end
    node.Position = Vector2.New(r.x, r.y)
    node.Size = Vector2.New(r.w, r.h)
end

-- ===== #180 武器栏、鱼饵栏单格与弹窗 =====
-- 底部装备栏里各占一格，显示当前选中的那一种；点开在该格正上方弹出一排候选格（位置取自布局模块）。
-- 同一时间最多开一个弹窗（OpenPopup = 'Weapon' | 'Bait' | nil）；点候选格或弹窗外空白处关闭。
-- 叠放：空白关闭层 4 < 弹窗底板 5 < 栏位与候选格 6 < 文字 7；对话框 20–22 仍在最上。
-- 控件名：WeaponBar / WeaponBarLabel、BaitBar / BaitBarLabel、WeaponPopup / BaitPopup（底板）、
-- <种类>PopupCell_<键> / <种类>PopupLabel_<键>（键：武器 id、鱼饵 id、NoBait、EatWorm）、PopupDismiss。
local SELECTED_COLOR = { 36, 130, 94, 255 }
local NORMAL_COLOR = { 54, 100, 140, 255 }
local DISABLED_COLOR = { 120, 120, 120, 255 }
local CELL_FONT = 18

local function itemName(id)
    local definition = GameCfg.Items.Definitions[id]
    return definition and definition.Name or tostring(id)
end

-- 候选格 / 栏位文字：名字按格宽折行，带数量时另起一行「×N」
local function cellText(name, count, width)
    local text = wrapColumns(name, math.max(1, math.floor(width / CELL_FONT)))
    return count and (text .. '\n×' .. tostring(count)) or text
end

-- 武器候选：全部持有的武器（库存为 0 的也列出，置灰），按 id 排序；选中 = 切换手持
-- （按武器 id 发起攻击类 Operate，服务端据此切换手持，与原平铺武器行一致）
local function weaponCandidates(self, state)
    local weapons = type(state.weapons) == 'table' and state.weapons or {}
    local ids = {}
    for id, count in pairs(weapons) do
        if type(count) == 'number' then ids[#ids + 1] = id end
    end
    table.sort(ids)
    local equipped = LocalAttackButton.EquippedWeapon(state)
    local list = {}
    for _, id in ipairs(ids) do
        list[#list + 1] = { key = id, name = itemName(id), count = weapons[id], enabled = weapons[id] > 0,
            selected = id == equipped, choose = function() self:Operate({ op = 'attack', weapon = id }) end }
    end
    return list
end

-- 鱼饵候选：蚯蚓、香肠、鸭子（固定列出，库存为 0 置灰）、其余动态鱼饵（库存 > 0 才列，按 id 排序）、
-- 「不挂鱼饵」、「吃蚯蚓」（蚯蚓为 0 置灰）。命令与原平铺按钮一致：SelectBait id / SelectBait（nil）/ EatBait worm
local function baitCandidates(self, state)
    local ids = GameCfg.Items.Id
    local fixed = { ids.Worm, ids.Sausage, ids.Duck }
    local dynamic, isFixed = {}, {}
    for _, id in ipairs(fixed) do isFixed[id] = true end
    for id in pairs(type(state.bait) == 'table' and state.bait or {}) do
        if not isFixed[id] and baitStock(state, id) > 0 then dynamic[#dynamic + 1] = id end
    end
    table.sort(dynamic)
    local list = {}
    local function add(id)
        local count = baitStock(state, id)
        list[#list + 1] = { key = id, name = itemName(id), count = count, enabled = count > 0,
            selected = state.selectedBait == id, choose = function() self:Action('SelectBait', id) end }
    end
    for _, id in ipairs(fixed) do add(id) end
    for _, id in ipairs(dynamic) do add(id) end
    list[#list + 1] = { key = 'NoBait', name = '不挂鱼饵', enabled = true, selected = state.selectedBait == nil,
        choose = function() self:Action('SelectBait') end }
    list[#list + 1] = { key = 'EatWorm', name = '吃蚯蚓', enabled = wormCount(state) > 0,
        choose = function() self:Action('EatBait', ids.Worm) end }
    return list
end

local POPUP_CANDIDATES = { Weapon = weaponCandidates, Bait = baitCandidates }

function ScreenHandler:BuildEquipBars(root, layout)
    self.EquipBars = {}
    self.PopupPool = {}
    self.PopupPlates = {}
    local w, h = self.EuiResolution.x, self.EuiResolution.y
    self.PopupDismiss = button(root, 'PopupDismiss', w / 2, h / 2, w)
    self.PopupDismiss.Size = Vector2.New(w, h)
    -- 只接点击、不挡画面：带色块图时引擎不认颜色 alpha，会把整屏盖成深色（#178 试玩实测），
    -- 所以去掉图片并全透明；去图后仍可点中（同轮试玩实测点空白可关闭）
    self.PopupDismiss.NormalImage = ''
    self.PopupDismiss.PressImage = ''
    self.PopupDismiss.DisableImage = ''
    self.PopupDismiss.ButtonNormalColor = Color.New(0, 0, 0, 0)
    self.PopupDismiss.ButtonPressColor = Color.New(0, 0, 0, 0)
    self.PopupDismiss.LocalZOrder = 4
    self.PopupDismiss.Visible = false
    self.PopupDismiss.TouchEnabled = false
    self.Buttons[#self.Buttons + 1] = self.PopupDismiss
    self:Listen(self.PopupDismiss.OnClicked, function() self:ClosePopup() end)
    for _, kind in ipairs({ 'Weapon', 'Bait' }) do
        local r = layout.Rects[kind .. 'Bar']
        local btn = button(root, kind .. 'Bar', r.x, r.y, r.w)
        place(btn, r)
        btn.LocalZOrder = 6
        local label = overlay(root, kind .. 'BarLabel', r.x, r.y, r.w, r.h, '', CELL_FONT, Color.New(255, 255, 255, 255))
        label.LocalZOrder = 7
        self.Buttons[#self.Buttons + 1] = btn
        self.Overlays[#self.Overlays + 1] = label
        self.EquipBars[kind] = { Button = btn, Label = label }
        self:Listen(btn.OnClicked, function() self:TogglePopup(kind) end)
        local plate = passive(World:CreateUnit('EUIImage', {
            Parent = root, Name = kind .. 'Popup', Position = Vector2.New(r.x, r.y), Size = Vector2.New(r.w, r.h),
            Image = 'official://image/11017', Color = Color.New(16, 24, 34, 200),
        }))
        plate.LocalZOrder = 5
        plate.Visible = false
        self.Overlays[#self.Overlays + 1] = plate
        self.PopupPlates[kind] = plate
        self.PopupPool[kind] = {}
    end
end

-- 候选格按键惰性创建、复用；点击时按当前快照重新取候选，置灰的不响应
function ScreenHandler:PopupCell(kind, key)
    local pool = self.PopupPool[kind]
    if pool[key] then return pool[key] end
    local btn = button(self.UIRoot, kind .. 'PopupCell_' .. key, 0, 0, 80)
    btn.LocalZOrder = 6
    local label = overlay(self.UIRoot, kind .. 'PopupLabel_' .. key, 0, 0, 80, 80, '', CELL_FONT,
        Color.New(255, 255, 255, 255))
    label.LocalZOrder = 7
    self.Buttons[#self.Buttons + 1] = btn
    self.Overlays[#self.Overlays + 1] = label
    self:Listen(btn.OnClicked, function() self:ChoosePopup(kind, key) end)
    pool[key] = { Button = btn, Label = label }
    return pool[key]
end

function ScreenHandler:PopupCandidates(kind)
    local state = self.Snapshot
    return state and POPUP_CANDIDATES[kind](self, state) or {}
end

function ScreenHandler:TogglePopup(kind)
    if self.BackpackOpen then return end
    self.OpenPopup = self.OpenPopup ~= kind and kind or nil
    self:RenderPopup()
end

function ScreenHandler:ClosePopup()
    self.OpenPopup = nil
    self:RenderPopup()
end

function ScreenHandler:ChoosePopup(kind, key)
    if self.OpenPopup ~= kind then return end
    for _, candidate in ipairs(self:PopupCandidates(kind)) do
        if candidate.key == key then
            if not candidate.enabled then return end
            candidate.choose()
            break
        end
    end
    self:ClosePopup()
end

function ScreenHandler:RenderPopup()
    if not self.PopupPool then return end
    for kind, pool in pairs(self.PopupPool) do
        for _, cell in pairs(pool) do
            cell.Button.Visible = false
            cell.Button.TouchEnabled = false
            cell.Label.Visible = false
        end
        self.PopupPlates[kind].Visible = false
    end
    local kind = self.OpenPopup
    local open = kind ~= nil and self.HudLayout ~= nil
    self.PopupDismiss.Visible = open
    self.PopupDismiss.TouchEnabled = open
    for barKind, bar in pairs(self.EquipBars) do
        bar.Button.ButtonNormalColor = color(barKind == kind and SELECTED_COLOR or NORMAL_COLOR)
    end
    if not open then return end
    local list = self:PopupCandidates(kind)
    local rects = MainHudLayout.PopupCells(self.HudLayout, kind, #list)
    for i, candidate in ipairs(list) do
        local r, cell = rects[i], self:PopupCell(kind, candidate.key)
        place(cell.Button, r)
        place(cell.Label, r)
        cell.Label.Text = cellText(candidate.name, candidate.count, r.w)
        cell.Button.Visible = true
        cell.Button.TouchEnabled = candidate.enabled
        cell.Button.ButtonNormalColor = color(not candidate.enabled and DISABLED_COLOR
            or candidate.selected and SELECTED_COLOR or NORMAL_COLOR)
        cell.Label.Visible = true
    end
    -- 底板 = 候选格外包框四边外扩 4
    local plateRect = MainHudLayout.Bounds(rects, 4)
    if plateRect then
        local plate = self.PopupPlates[kind]
        place(plate, plateRect)
        plate.Visible = true
    end
end

-- 栏位文字：武器栏 = 当前手持或已选武器（没有就空格）；鱼饵栏 = 当前鱼饵及数量，或「不挂鱼饵」
function ScreenHandler:RenderEquipBars(state)
    if not self.EquipBars then return end
    local weapon, bar = LocalAttackButton.EquippedWeapon(state), self.EquipBars.Weapon
    bar.Label.Text = weapon and cellText(itemName(weapon), nil, bar.Button.Size.x) or ''
    local baitId, baitBar = state.selectedBait, self.EquipBars.Bait
    baitBar.Label.Text = baitId and cellText(itemName(baitId), baitStock(state, baitId), baitBar.Button.Size.x)
        or cellText('不挂鱼饵', nil, baitBar.Button.Size.x)
    for _, entry in pairs(self.EquipBars) do
        entry.Button.Visible = not self.BackpackOpen
        entry.Button.TouchEnabled = not self.BackpackOpen
        entry.Label.Visible = not self.BackpackOpen
    end
    self:RenderPopup()
end

-- 道具栏格：底板占满格子，图标、名字、数量按格子尺寸比例落在格内
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

-- 编辑器摆放的节点（金币图标 / 文字）：运行时改到布局给的位置，锚点统一按中心
-- [未查证：编辑器节点的默认 Anchor；显式设为 (0.5, 0.5) 与布局的中心点口径一致]
local function placeEditorNode(node, r)
    if not node then return end
    local ok, err = pcall(function() node.Anchor = Vector2.New(0.5, 0.5) end)
    if not ok then print('[ScreenMain] 设置节点锚点失败', tostring(node.Name), tostring(err)) end
    place(node, r)
end

-- #179：随输入变化的常驻控件（装备栏一行、右侧操作区）按主界面布局模块重排。
-- slots / reeling 传 nil 表示沿用上一次；输入不变时不重算（收线期间 ShowCast 逐帧调用）。
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
    place(self.BackpackButton, r.BackpackButton)
    place(self.BackpackLabel, r.BackpackButton)
    for kind, bar in pairs(self.EquipBars or {}) do
        place(bar.Button, r[kind .. 'Bar'])
        place(bar.Label, r[kind .. 'Bar'])
    end
    if self.OpenPopup then self:RenderPopup() end -- 候选行跟着栏位走
    place(self.BtnItemAction, r.ItemAction)
    place(self.BtnItemActionLabel, r.ItemAction)
    place(self.BtnDiscard, r.Discard)
    place(self.BtnDiscardLabel, r.Discard)
    -- 不在收线期间时布局不给「结束收线」占位（按钮本就隐藏），保留上一次的位置
    place(self.BtnReelClose, r.ReelClose)
    place(self.BtnReelCloseLabel, r.ReelClose)
end

function ScreenHandler:Listen(source, callback)
    self.Connections[#self.Connections + 1] = source:Connect(callback)
end

function ScreenHandler:Cleanup()
    DamageFloat:Clear()
    FishCombatLabel:Clear()
    self:CloseScreen()
    LocalAttackButton:Destroy()
    for _, connection in ipairs(self.Connections or {}) do connection:Disconnect() end
    for _, node in ipairs(self.Overlays or {}) do node:Destroy() end
    for _, slot in ipairs(self.Slots or {}) do slot.Background:Destroy() end
    for _, node in ipairs(self.Buttons or {}) do node:Destroy() end
    self.Connections = nil
    self.Overlays = nil
    self.Slots = nil
    self.ItemBarSlotPos = nil
    self.BackpackSlots = nil
    self.BackpackSlotPos = nil
    self.EquipBars = nil
    self.PopupPool = nil
    self.PopupPlates = nil
    self.PopupDismiss = nil
    self.OpenPopup = nil
    self.DragSource = nil
    self.OpSeq = nil
    self.UIRoot = nil
    self.LastOperateOperation = nil
    self.BackpackButton = nil
    self.BackpackPanel = nil
    self.BackpackLabel = nil
    self.BackpackTitle = nil
    self.MoveButton = nil
    self.MoveLabel = nil
    self.SelectedBackpackSlot = nil
    self.Buttons = nil
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
    self.HealthRing = nil
    self.HungerRing = nil
    self.HealthText = nil
    self.HungerText = nil
    self.FlashEdges = nil
    self.Starving = nil
    self.NextWarnAt = nil
    self.ReelBar = nil
    self.ReelBarBg = nil
    self.LabelCoin = nil
    self.ImageCoin = nil
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

local function listenPlayerAttributes(self, player)
    self:Listen(player:GetAttributeChangedSignal('FishCoin'), function() self:ShowCoin() end)
    self:ShowCoin()
    for _, key in ipairs({ 'Health', 'MaxHealth', 'Hunger', 'MaxHunger' }) do
        self:Listen(player:GetAttributeChangedSignal(key), function() self:ShowVitals() end)
    end
    self:ShowVitals()
end

function ScreenHandler:Init()
    if self.Inited then
        if self.BoundRootNode == self.RootNode then return end
        self:Cleanup()
    end
    local euiMgr = _G.GameUI:GetEuiManager()
    if not euiMgr then return end
    local resolution = euiMgr:GetDeviceResolution()
    self.EuiResolution = resolution
    local root = self.RootNode
    DamageFloat:Bind(root, resolution)
    FishCombatLabel:Bind(root, resolution)
    -- #179：主界面常驻控件的位置一律取自布局模块。首次按道具栏满格、收线期间计算，
    -- 让「结束收线」也有初始位置；快照到达后 ApplyLayout 按实际格数重排
    local count = GameCfg.Items.ItemBarSlots
    local layout = MainHudLayout.Compute({ width = resolution.x, height = resolution.y,
        itemBarSlots = count, reeling = true })
    self.HudLayout = layout
    local rects = layout.Rects
    self.LabelCoin = root:FindFirstChild('LabelCoin', true)
    self.ImageCoin = root:FindFirstChild('ImageCoin', true)
    if self.LabelCoin then self.LabelCoin.Visible = true else print('[ScreenMain] 找不到 LabelCoin 节点') end
    if self.ImageCoin then self.ImageCoin.Visible = true end
    placeEditorNode(self.ImageCoin, rects.CoinIcon)
    placeEditorNode(self.LabelCoin, rects.CoinLabel)
    self.Slots = {}
    self.ItemBarSlotPos = {}
    self.Buttons = {}
    self.Connections = {}
    self.Overlays = {}
    for index = 1, count do
        local cell = layout.ItemBarSlots[index]
        local background = button(root, 'ItemBarSlot' .. index, cell.x, cell.y, cell.w)
        local icon = World:CreateUnit('EUIImage', {
            Parent = root, Name = 'ItemBarIcon' .. index,
            Position = Vector2.New(cell.x, cell.y), Size = Vector2.New(cell.w, cell.h),
        })
        icon.TouchEnabled = false
        icon.SwallowTouchEnabled = false
        icon.LocalZOrder = 1
        icon.Visible = false
        local label = overlay(root, 'ItemBarLabel' .. index, cell.x, cell.y, cell.w, cell.h,
            '', 18, Color.New(255, 255, 255, 255))
        local amount = overlay(root, 'ItemBarAmount' .. index, cell.x, cell.y, cell.w, cell.h,
            '', 20, Color.New(255, 220, 40, 255))
        label.Visible = false
        amount.Visible = false
        self.Overlays[#self.Overlays + 1] = icon
        self.Overlays[#self.Overlays + 1] = label
        self.Overlays[#self.Overlays + 1] = amount
        self.Slots[index] = { Background = background, Icon = icon, Label = label, Count = amount }
        placeSlot(self.Slots[index], cell)
        self.ItemBarSlotPos[index] = { x = cell.x, y = cell.y, hw = cell.w / 2, hh = cell.h / 2 }
        self:bindDrag(background, GameCfg.Items.ContainerId.ItemBar, index)
        self:BindSlotGesture(background, index)
        self:Listen(background.OnClicked, function()
            if self:ConsumeThrowClick(index) then return end -- 爆炸物已由手势消费本次点击
            self:Action('SelectSlot', index)
        end)
    end
    self.UIRoot = root
    self:BuildBackpack(root, layout)
    self:BuildEquipBars(root, layout)
    local discard = rects.Discard
    self.BtnDiscard = button(root, 'ItemDiscard', discard.x, discard.y, discard.w)
    local action, reelClose = rects.ItemAction, rects.ReelClose
    self.BtnItemAction = button(root, 'ItemAction2', action.x, action.y, action.w)
    self.BtnReelClose = button(root, 'ReelClose', reelClose.x, reelClose.y, reelClose.w)
    place(self.BtnDiscard, discard)
    place(self.BtnItemAction, action)
    place(self.BtnReelClose, reelClose)
    for _, node in ipairs({ self.BtnDiscard, self.BtnItemAction, self.BtnReelClose }) do
        self.Buttons[#self.Buttons + 1] = node
    end
    local labels = {
        { 'BtnReelCloseLabel', self.BtnReelClose, '结束收线' },
        { 'BtnDiscardLabel', self.BtnDiscard, '丢弃选中物' },
        { 'BtnItemActionLabel', self.BtnItemAction, '抛竿' },
    }
    for _, entry in ipairs(labels) do
        local btn = entry[2]
        local label = overlay(root, entry[1], btn.Position.x, btn.Position.y,
            btn.Size.x, btn.Size.y, entry[3], 30, Color.New(255, 255, 255, 255))
        self[entry[1]] = label
        self.Overlays[#self.Overlays + 1] = label
    end
    -- 上方提示区：上钩 / 等待提示同位（互斥显示），入水提示与收线进度同位，临时提示单独一行
    local primary, secondary, transient = rects.HintPrimary, rects.HintSecondary, rects.HintTransient
    self.HookHint = overlay(root, 'HookHint', primary.x, primary.y, primary.w, primary.h,
        '', 32, Color.New(255, 220, 40, 255))
    self.HookHint.Visible = false
    self.Overlays[#self.Overlays + 1] = self.HookHint
    local feedback = GameCfg.CastFeedback
    self.CastFloat = overlay(root, 'CastFloat', 0, 0, feedback.FloatSize, feedback.FloatSize,
        '●', 48, color(feedback.FloatColor))
    self.CastWaitHint = overlay(root, 'CastWaitHint', primary.x, primary.y, primary.w, primary.h,
        '等待上钩…', 32, Color.New(255, 255, 255, 255))
    self.CastSplashHint = overlay(root, 'CastSplashHint', secondary.x, secondary.y, secondary.w, secondary.h,
        '已入水，等待上钩', 30, Color.New(255, 225, 70, 255))
    self.CastFailureHint = overlay(root, 'CastFailureHint', transient.x, transient.y, transient.w, transient.h,
        '', 30, Color.New(255, 90, 90, 255))
    self.CastFailureMark = overlay(root, 'CastFailureMark', 0, 0, feedback.FloatSize, feedback.FloatSize,
        '●', 48, Color.New(255, 65, 65, 255))
    for _, node in ipairs({ self.CastFloat, self.CastWaitHint, self.CastSplashHint,
        self.CastFailureHint, self.CastFailureMark }) do
        node.Visible = false
        self.Overlays[#self.Overlays + 1] = node
    end
    -- #179 左侧任务区：追踪条（#174 #1 深色半透明底板 + 折行文字）与折叠 / 展开按钮
    local questPanel, questToggle = rects.QuestPanel, rects.QuestToggle
    self.QuestBackground = passive(World:CreateUnit('EUIImage', {
        Parent = root, Name = 'QuestBackground',
        Position = Vector2.New(questPanel.x, questPanel.y), Size = Vector2.New(questPanel.w, questPanel.h),
        Image = 'official://image/11017', Color = Color.New(16, 24, 34, 180),
    }))
    self.QuestBackground.Visible = false
    self.Overlays[#self.Overlays + 1] = self.QuestBackground
    self.QuestLabel = overlay(root, 'QuestLabel', questPanel.x, questPanel.y, questPanel.w - 20,
        questPanel.h - 12, '', 24, Color.New(255, 255, 255, 255))
    self.QuestLabel.Visible = false
    self.Overlays[#self.Overlays + 1] = self.QuestLabel
    self.QuestToggle = button(root, 'QuestToggle', questToggle.x, questToggle.y, questToggle.w)
    place(self.QuestToggle, questToggle)
    self.QuestToggleLabel = overlay(root, 'QuestToggleLabel', questToggle.x, questToggle.y,
        questToggle.w, questToggle.h, '收起任务', 22, Color.New(255, 255, 255, 255))
    self.Buttons[#self.Buttons + 1] = self.QuestToggle
    self.Overlays[#self.Overlays + 1] = self.QuestToggleLabel
    self:Listen(self.QuestToggle.OnClicked, function()
        self.QuestCollapsed = not self.QuestCollapsed
        self:RenderQuest()
    end)
    self:RenderQuest()
    local cx, cy = resolution.x / 2, resolution.y / 2
    local width = math.min(1000, resolution.x - 60)
    self.DialogueColumns = math.max(12, math.floor((width - 80) / 26))
    local panel = World:CreateUnit('EUIImage', {
        Parent = root, Name = 'DialogueBackground', Position = Vector2.New(cx, cy),
        Size = Vector2.New(width, 360), Image = 'official://image/11017',
        Color = Color.New(22, 38, 54, 250),
    })
    panel.TouchEnabled, panel.SwallowTouchEnabled, panel.LocalZOrder = true, true, 20
    -- #174 #11：主界面原点左下、Y 向上——标题在上、正文居中、按钮在下
    self.DialogueTitle = overlay(root, 'DialogueTitle', cx, cy + 120, width - 50, 50,
        '', 30, Color.New(255, 225, 130, 255))
    self.DialogueBody = overlay(root, 'DialogueBody', cx, cy - 10, width - 80, 130,
        '', 26, Color.New(255, 255, 255, 255))
    self.DialogueNext = button(root, 'DialogueNext', cx - 160, cy - 115, 260)
    self.DialogueRead = button(root, 'DialogueRead', cx + 160, cy - 115, 300)
    local nextLabel = overlay(root, 'DialogueNextLabel', cx - 160, cy - 115, 260, 80,
        '下一段', 26, Color.New(255, 255, 255, 255))
    self.DialogueReadLabel = overlay(root, 'DialogueReadLabel', cx + 160, cy - 115, 300, 80,
        '已读，开始钓鱼', 26, Color.New(255, 255, 255, 255))
    self.DialogueNodes = { panel, self.DialogueTitle, self.DialogueBody,
        self.DialogueNext, self.DialogueRead, nextLabel, self.DialogueReadLabel }
    for _, node in ipairs(self.DialogueNodes) do
        if node ~= panel then node.LocalZOrder = 21 end
        if node == nextLabel or node == self.DialogueReadLabel then node.LocalZOrder = 22 end
        node.Visible = false
        self.Overlays[#self.Overlays + 1] = node
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
    self:BuildVitals(root, resolution, layout)
    self.ReelBarBg = World:CreateUnit('EUIImage', {
        Parent = root, Name = 'ReelProgressBg',
        Position = Vector2.New(secondary.x, secondary.y), Size = Vector2.New(400, 36),
        Image = 'official://image/30008',
    })
    self.ReelBar = World:CreateUnit('EUILoadingBar', {
        Parent = root, Name = 'ReelProgress',
        Position = Vector2.New(secondary.x, secondary.y), Size = Vector2.New(400, 36),
        Image = 'official://image/30007', Direction = 0, Percent = 50,
        Color = Color.New(36, 200, 94, 255),
    })
    for _, node in ipairs({ self.ReelBarBg, self.ReelBar }) do
        node.TouchEnabled = false
        node.SwallowTouchEnabled = false
        node.Visible = false
        self.Overlays[#self.Overlays + 1] = node
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
    -- 点击与长按按 ItemActionMode 查道具按钮表（ITEM_ACTIONS / SPECIAL_ACTIONS），与显示同源
    self:Listen(self.BtnItemAction.OnClicked, function()
        if not self.IsOpen then return end
        local click = itemAction(self, self:ItemActionMode()).click
        if click then click(self) end
    end)
    -- #140 风神之翼：长按升空、松开缓降（按下 / 松开成对发送，服务端以调和为准）
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
    -- #140 特殊道具状态：按钮语义随服务端生效效果切换；冷却按权威剩余秒数起本地倒计时
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
    _G.REUtil:GetRE('SpecialItemStateRequest'):FireServer() -- 安装状态监听后补取可能丢失的首包
    -- #140 特殊道具回包：冷却 / 未变身 / 未装备翅膀等失败给具体提示
    self:Listen(_G.REUtil:GetRE('SpecialItemResult').OnClientEvent, function(result)
        if type(result) ~= 'table' or result.ok ~= false then return end
        local hints = { cooldown = '原子吐息冷却中', ['not-godzilla'] = '需要选中哥斯拉变身',
            ['not-wings'] = '需要选中风神之翼', ['not-alive'] = '现在不能行动',
            ['no-character'] = '角色未就绪' }
        if _G.LocalMsgNotice then
            _G.LocalMsgNotice(hints[result.reason] or ('操作失败 ' .. tostring(result.reason)))
        end
    end)
    -- #124 操作回包：失败给具体提示；operation 身份随回包带回，凭它可跨重连重试
    self:Listen(_G.REUtil:GetRE('ItemBarResult').OnClientEvent, function(result)
        if type(result) ~= 'table' or result.ok ~= false then return end
        self.LastOperateOperation = result.operation or self.LastOperateOperation
        -- #129：武器已手持时再点武器列表=出击（结算在 MgrWeapon，伤害以服务端为准）
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
    -- #129 武器结算回包：换弹/空匣/冷却/投掷校验失败给具体提示
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
        -- #133：界面被别的界面盖住只是表现问题——收线继续由服务端权威推进，回流后照旧显示，
        -- 所以这里不再因为「界面没开」就去取消收线会话。
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
    -- 未交付正式 Story 资源时保留阅读界面，由玩家明确确认已读。
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
    -- 追平要 150–200ms 内连续变化，服务端 100ms 一报不够平滑，收线中逐帧刷新进度条
    local runService = game:GetService('RunService')
    if runService and runService.Heartbeat then
        self:Listen(runService.Heartbeat, function()
            if self.ReelBar and self.ReelBar.Visible then self:ShowCast() end
            -- #140：吐息冷却中逐帧刷新倒计时文案
            if self.BreathCooldownUntil and self.SpecialEffect == 'godzilla' then
                if self.BreathCooldownUntil > World:GetServerTime() then
                    self:ShowCast()
                else
                    self.BreathCooldownUntil = nil
                    self:ShowCast()
                end
            end
            if self.CastFloat and self.IsOpen then self:UpdateCastFeedback() end
            if self.Starving then self:UpdateStarveFx() end
            DamageFloat:Update()
            FishCombatLabel:Update()
        end)
    end
    -- 进图早期注册 FishCoin 属性监听不稳定，延迟后再挂
    local task = game:GetService('Task')
    if task and task.Delay then
        task:Delay(1, function()
            if not self.Inited or self.BoundRootNode ~= root then return end
            local player = game:GetService('Players').LocalPlayer
            if not player then return end
            listenPlayerAttributes(self, player)
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
    LocalAttackButton:SetOpen(true)
    -- #133 重开界面不需要通知收线客户端：会话与进度一直在，界面只是重新显示
    self:ShowCast()
    self:ShowCoin()
    self:ShowVitals()
    _G.REUtil:GetRE('SpecialItemStateRequest'):FireServer()
    _G.REUtil:GetRE('RequestItemBar'):FireServer()
    _G.REUtil:GetRE('RequestCastState'):FireServer()
    _G.REUtil:GetRE('RequestQuest'):FireServer()
    _G.REUtil:GetRE('RequestFishCombat'):FireServer()
    -- 重开可能落在服务端快照限频窗内；延后补取，并让旧界面的请求失效。
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
    -- 开场对话（#54）：服务端每名玩家本局只播一次，重开界面不重播
    _G.REUtil:GetRE('RequestStory'):FireServer()
end

function ScreenHandler:CloseScreen()
    self:HideDialogue()
    self.CombatRequest = nil
    DamageFloat:Clear()
    FishCombatLabel:Clear()
    self.IsOpen = false
    -- 临时提示状态整体收尾（Cleanup 经由这里），重开 / 重进不带上一轮的「只做提示」标志
    self.FailureUntil = nil
    self.FailureLanding = nil
    self.FailureNotice = nil
    self:EndAim()
    self:ClosePopup() -- #180：界面被盖住时弹窗不留到重开
    LocalAttackButton:SetOpen(false)
    -- #133 遮挡只影响表现：不主动收线，待发点击先 flush，会话与进度留给重开时接着显示
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
