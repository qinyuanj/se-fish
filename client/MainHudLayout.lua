-- 主界面布局模块（#179，spec #178）：纯函数，只做计算。
-- 不依赖 World、EUI 或任何引擎全局；布局坐标只在本模块里。道具栏开放格数由调用方传入，
-- 上下限（初始格数 / 满格数）读共享配置 GameCfg.Items，不在这里另记一份。
--
-- 坐标约定与 EUI 一致：原点在左下、Y 向上；每个矩形是 { x, y, w, h }，x / y 指中心点。
-- 区域名（讨论界面时的叫法）：
--   StatusTopLeft   左上状态区：血量球、饥饿度球、金币
--   EntriesTopRight 右上入口组：图鉴、商店（预留格位）、盲盒
--   QuestLeft       左侧任务区：新手任务追踪条及其折叠按钮
--   HintTop         上方提示区：上钩 / 等待提示、收线进度、临时提示
--   EquipBottom     底部装备栏：武器栏｜道具栏（2–8 格）｜背包按钮｜鱼饵栏
--   ActionRight     右侧操作区：攻击键、道具按钮、丢弃键；收线期间加「结束收线」
--   CenterClear     中央留空区：不放任何常驻控件
local GameCfg = require('common.GameCfg')

local MainHudLayout = {}

local DESIGN_W, DESIGN_H = 1920, 1238
local SAFE = 16   -- 屏幕边安全距离
local GAP = 12    -- 控件之间、控件与保留区之间的间隔
local PAD = 10    -- 实测误差：保留区四边各外扩 10

-- 引擎控件占位实测：#173 第一阶段结论评论「引擎控件占位实测」表
-- （https://github.com/qinyuanj/se-fish/issues/173#issuecomment-6651176291）。
-- 取证条件：编辑器 1379×889 窗口（EUI 1920×1238），截图目测换算，误差 ±10。
-- 换算口径：EUI 宽固定 1920、高随屏幕比例变化；anchor 写明各组贴哪条边，
-- 贴顶的按离顶距离平移，贴右的按离右距离平移，其余保持原值。
local ENGINE_RESERVED = {
    { name = 'SystemButtons', anchor = 'top-left', l = 49, r = 393, b = 1057, t = 1161 },   -- 左上系统按钮组
    { name = 'WarningKey', anchor = 'top-right', l = 1817, r = 1873, b = 1108, t = 1164 },  -- 右上警告键
    { name = 'Joystick', anchor = 'bottom-left', l = 227, r = 372, b = 191, t = 336 },      -- 左下摇杆底座
    { name = 'Jump', anchor = 'bottom-right', l = 1543, r = 1807, b = 164, t = 429 },       -- 右下跳跃
    { name = 'Roll', anchor = 'bottom-right', l = 1353, r = 1493, b = 191, t = 330 },       -- 翻滚
    { name = 'SkillKey', anchor = 'bottom-right', l = 1458, r = 1597, b = 26, t = 166 },    -- 黄色技能键
    { name = 'Avatar', anchor = 'bottom-right', l = 1710, r = 1920, b = 0, t = 140 },       -- 右下角色头像
    { name = 'Version', anchor = 'bottom-left', l = 14, r = 710, b = 15, t = 45 },          -- 底部版本号
}
-- 摇杆触控热区可能比可见底座大（实测未知）：本模块另外把底座再外扩 30 作为左下摇杆区
local JOYSTICK_ZONE_EXTRA = 30

local function rect(x, y, w, h)
    return { x = x, y = y, w = w, h = h }
end

local function fromEdges(left, right, bottom, top)
    return rect((left + right) / 2, (bottom + top) / 2, right - left, top - bottom)
end

local function edgesOf(r)
    return r.x - r.w / 2, r.x + r.w / 2, r.y - r.h / 2, r.y + r.h / 2
end

local function scaledReserved(spec, width, height)
    local l, r, b, t = spec.l, spec.r, spec.b, spec.t
    if spec.anchor:find('top', 1, true) then
        b, t = b - DESIGN_H + height, t - DESIGN_H + height
    end
    if spec.anchor:find('right', 1, true) then
        l, r = l - DESIGN_W + width, r - DESIGN_W + width
    end
    return fromEdges(l - PAD, r + PAD, b - PAD, t + PAD)
end

-- 一组矩形的外包框，再外扩 pad
local function bounds(controls, pad)
    local l, r, b, t
    for _, c in pairs(controls) do
        local cl, cr, cb, ct = edgesOf(c)
        l, r = math.min(l or cl, cl), math.max(r or cr, cr)
        b, t = math.min(b or cb, cb), math.max(t or ct, ct)
    end
    return fromEdges(l - pad, r + pad, b - pad, t + pad)
end

-- 道具栏格数夹到「初始格数–满格数」（GameCfg.Items，现为 2–8）
local function clampSlots(n)
    local items = GameCfg.Items
    n = type(n) == 'number' and math.floor(n) or items.InitialItemBarSlots
    return math.max(items.InitialItemBarSlots, math.min(items.ItemBarSlots, n))
end

-- 尺寸常量（调试期占位方块）
local RING = 100                       -- 血量球 / 饥饿度球
local COIN_ICON, COIN_LABEL_W, COIN_LABEL_H = 56, 130, 50
local ENTRY_W, ENTRY_H, ENTRY_GAP = 130, 60, 8
local QUEST_W, QUEST_TOGGLE_W, QUEST_TOGGLE_H, QUEST_PANEL_H = 450, 120, 48, 110
local CELL, SLOT_STEP, GROUP_GAP = 80, 84, 12   -- 装备栏单格、道具栏步距、组间距
local BACKPACK_W = 130
local ATTACK = 180
local ACTION_W, ACTION_H = 180, 90
local BACKPACK_PANEL_W, BACKPACK_PANEL_H = 850, 690   -- 背包面板内部排版不变，尺寸照旧
local POPUP_STEP = 86                  -- 候选格 80 + 间隔 6
local CENTER_HALF_W, CENTER_HALF_H_RATIO = 280, 0.18

-- input = { width, height, itemBarSlots, reeling }
-- 返回 { Regions = { 区域名 = { Bounds, Controls } }, Rects = 扁平索引,
--        ItemBarSlots = { 第 1..N 格 }, Panels = { BackpackPanel }, Reserved = { { name, rect } },
--        Popup = 候选行参数（供 PopupCells） }
function MainHudLayout.Compute(input)
    input = type(input) == 'table' and input or {}
    local W = type(input.width) == 'number' and input.width or DESIGN_W
    local H = type(input.height) == 'number' and input.height or 1080
    local slots = clampSlots(input.itemBarSlots)

    local reserved, zone = {}, {}
    for _, spec in ipairs(ENGINE_RESERVED) do
        local r = scaledReserved(spec, W, H)
        reserved[#reserved + 1] = { name = spec.name, rect = r }
        zone[spec.name] = r
    end
    local stick = zone.Joystick
    local stickZone = rect(stick.x, stick.y, stick.w + 2 * JOYSTICK_ZONE_EXTRA, stick.h + 2 * JOYSTICK_ZONE_EXTRA)
    reserved[#reserved + 1] = { name = 'JoystickZone', rect = stickZone }
    local function left(r) return (edgesOf(r)) end
    local function right(r) local _, x = edgesOf(r) return x end
    local function bottom(r) local _, _, y = edgesOf(r) return y end
    local function top(r) local _, _, _, y = edgesOf(r) return y end

    -- 左上状态区：系统按钮组正下方一行，血量球｜饥饿度球｜金币图标｜金币文字
    local statusTop = bottom(zone.SystemButtons) - GAP
    local ringY = statusTop - RING / 2
    local x0 = SAFE + 8
    local status = {
        HealthRing = rect(x0 + RING / 2, ringY, RING, RING),
        HungerRing = rect(x0 + RING * 1.5 + GAP, ringY, RING, RING),
    }
    local coinX = right(status.HungerRing) + GAP + COIN_ICON / 2
    status.CoinIcon = rect(coinX, ringY, COIN_ICON, COIN_ICON)
    status.CoinLabel = rect(coinX + COIN_ICON / 2 + 8 + COIN_LABEL_W / 2, ringY, COIN_LABEL_W, COIN_LABEL_H)

    -- 右上入口组：警告键左侧一行，从左到右 图鉴｜商店（预留，暂无按钮）｜盲盒
    local entryY = H - 105
    local entryRight = left(zone.WarningKey) - GAP
    local entries = {
        BlindboxEntry = rect(entryRight - ENTRY_W / 2, entryY, ENTRY_W, ENTRY_H),
    }
    entries.ShopEntry = rect(entries.BlindboxEntry.x - ENTRY_W - ENTRY_GAP, entryY, ENTRY_W, ENTRY_H)
    entries.CompendiumEntry = rect(entries.ShopEntry.x - ENTRY_W - ENTRY_GAP, entryY, ENTRY_W, ENTRY_H)

    -- 上方提示区：屏幕顶部居中三行；同一行的控件互斥显示（上钩提示 / 等待提示同位，
    -- 收线进度 / 入水提示同位），临时提示（抛竿失败、蚯蚓用尽等）单独一行
    local hintTop = H - SAFE - 4
    local hints = { HintPrimary = rect(W / 2, hintTop - 32, 520, 64) }
    hints.HintSecondary = rect(W / 2, bottom(hints.HintPrimary) - 8 - 28, 520, 56)
    hints.HintTransient = rect(W / 2, bottom(hints.HintSecondary) - 8 - 30, 740, 60)

    -- 左侧任务区：状态区下方到左下摇杆区上方；宽不超过屏幕 1/4，折叠按钮在上、面板在下
    local questTop = ringY - RING / 2 - GAP * 2
    local questBottom = top(stickZone) + GAP
    local questLeft = SAFE + 4
    local quest = {
        QuestToggle = rect(questLeft + QUEST_TOGGLE_W / 2, questTop - QUEST_TOGGLE_H / 2,
            QUEST_TOGGLE_W, QUEST_TOGGLE_H),
    }
    quest.QuestPanel = rect(questLeft + QUEST_W / 2, bottom(quest.QuestToggle) - 8 - QUEST_PANEL_H / 2,
        QUEST_W, QUEST_PANEL_H)
    local questBounds = fromEdges(questLeft, questLeft + QUEST_W, questBottom, questTop)

    -- 底部装备栏：摇杆区右侧到技能键左侧的底边带；整体以屏幕中线居中，放不下时向内收
    local bandLeft, bandRight = right(stickZone) + GAP, left(zone.SkillKey) - GAP
    local barY = top(zone.Version) + GAP + 8 + CELL / 2
    local slotsW = CELL + SLOT_STEP * (slots - 1)
    local total = CELL + GROUP_GAP + slotsW + GROUP_GAP + BACKPACK_W + GROUP_GAP + CELL
    local barLeft = math.max(bandLeft, math.min(bandRight - total, W / 2 - total / 2))
    local equip = { WeaponBar = rect(barLeft + CELL / 2, barY, CELL, CELL) }
    local itemBar = {}
    local firstSlot = right(equip.WeaponBar) + GROUP_GAP + CELL / 2
    for i = 1, slots do
        local r = rect(firstSlot + (i - 1) * SLOT_STEP, barY, CELL, CELL)
        itemBar[i] = r
        equip['ItemBarSlot' .. i] = r
    end
    equip.BackpackButton = rect(right(itemBar[slots]) + GROUP_GAP + BACKPACK_W / 2, barY, BACKPACK_W, CELL)
    equip.BaitBar = rect(right(equip.BackpackButton) + GROUP_GAP + CELL / 2, barY, CELL, CELL)
    local equipBounds = fromEdges(bandLeft, bandRight, barY - CELL / 2 - 8, barY + CELL / 2 + 8)

    -- 右侧操作区：跳跃键上方。攻击键贴右，道具按钮在其左；丢弃在攻击键上方，
    -- 收线期间「结束收线」在道具按钮上方，与攻击键左右错开
    local actionBase = top(zone.Jump) + GAP
    local action = { AttackControl = rect(W - 230, actionBase + ATTACK / 2, ATTACK, ATTACK) }
    action.ItemAction = rect(left(action.AttackControl) - GAP - ACTION_W / 2, action.AttackControl.y,
        ACTION_W, ACTION_H)
    action.Discard = rect(action.AttackControl.x, top(action.AttackControl) + GAP + ACTION_H / 2,
        ACTION_W, ACTION_H)
    if input.reeling then
        action.ReelClose = rect(action.ItemAction.x, top(action.ItemAction) + GAP + ACTION_H / 2,
            ACTION_W, ACTION_H)
    end

    local centerClear = rect(W / 2, H / 2, CENTER_HALF_W * 2, H * CENTER_HALF_H_RATIO * 2)

    -- 背包面板：装备栏上方、屏幕上缘以下的竖直居中；水平居中，避开左侧任务区
    local panelBottom = top(equipBounds) + GAP
    local panelY = math.max(panelBottom + BACKPACK_PANEL_H / 2, (panelBottom + H - SAFE) / 2)
    local backpackPanel = rect(W / 2, panelY, BACKPACK_PANEL_W, BACKPACK_PANEL_H)

    local regions = {
        StatusTopLeft = { Bounds = bounds(status, 4), Controls = status },
        EntriesTopRight = { Bounds = bounds(entries, 4), Controls = entries },
        QuestLeft = { Bounds = questBounds, Controls = quest },
        HintTop = { Bounds = bounds(hints, 4), Controls = hints },
        EquipBottom = { Bounds = equipBounds, Controls = equip },
        ActionRight = { Bounds = bounds(action, 4), Controls = action },
        CenterClear = { Bounds = centerClear, Controls = {} },
    }
    local rects = {}
    for _, region in pairs(regions) do
        for name, r in pairs(region.Controls) do rects[name] = r end
    end
    return {
        Regions = regions, Rects = rects, ItemBarSlots = itemBar,
        Panels = { BackpackPanel = backpackPanel },
        Reserved = reserved,
        Popup = { left = bandLeft, right = left(zone.Roll) - GAP, firstY = top(equipBounds) + GAP + CELL / 2,
            cell = CELL, step = POPUP_STEP },
    }
end

-- 武器栏 / 鱼饵栏弹窗候选行（#180 使用）：kind = 'Weapon' | 'Bait'，返回 count 个候选格矩形。
-- 候选行在栏位正上方，以栏位为中心水平展开，夹在摇杆区与翻滚键之间；一行放不下时向上续行。
function MainHudLayout.PopupCells(layout, kind, count)
    local bar = layout and layout.Rects and layout.Rects[kind .. 'Bar']
    if not bar or type(count) ~= 'number' or count < 1 then return {} end
    local p = layout.Popup
    local perRow = math.max(1, math.floor((p.right - p.left - p.cell) / p.step) + 1)
    local cells = {}
    local remaining, row = math.floor(count), 0
    while remaining > 0 do
        local n = math.min(perRow, remaining)
        local width = p.cell + p.step * (n - 1)
        local rowLeft = math.max(p.left, math.min(p.right - width, bar.x - width / 2))
        for i = 1, n do
            cells[#cells + 1] = rect(rowLeft + p.cell / 2 + (i - 1) * p.step, p.firstY + row * p.step,
                p.cell, p.cell)
        end
        remaining, row = remaining - n, row + 1
    end
    return cells
end

-- Anchor=(0,0) 的节点（如盲盒入口）用：中心矩形换成左下角坐标
function MainHudLayout.BottomLeft(r)
    return r.x - r.w / 2, r.y - r.h / 2
end

return MainHudLayout
