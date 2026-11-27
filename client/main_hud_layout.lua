-- 坐标约定与 EUI 一致：原点在左下、Y 向上；每个矩形是 { x, y, w, h }，x / y 指中心点。
local GameCfg = require('common.game_cfg')

local MainHudLayout = {}

local DESIGN_W, DESIGN_H = 1920, 1238
local SAFE = 16
local GAP = 12
local PAD = 10

-- 引擎控件占位实测：#173 第一阶段结论评论「引擎控件占位实测」表
-- （https://github.com/qinyuanj/se-fish/issues/173#issuecomment-6651176291）。
-- 取证条件：编辑器 1379×889 窗口（EUI 1920×1238），截图目测换算，误差 ±10。
-- 换算口径：EUI 宽固定 1920、高随屏幕比例变化；anchor 写明各组贴哪条边，
-- 贴顶的按离顶距离平移，贴右的按离右距离平移，其余保持原值。
local ENGINE_RESERVED = {
    { name = 'SystemButtons', anchor = 'top-left', l = 49, r = 393, b = 1057, t = 1161 },
    { name = 'WarningKey', anchor = 'top-right', l = 1817, r = 1873, b = 1108, t = 1164 },
    { name = 'Joystick', anchor = 'bottom-left', l = 227, r = 372, b = 191, t = 336 },
    { name = 'Jump', anchor = 'bottom-right', l = 1543, r = 1807, b = 164, t = 429 },
    { name = 'Roll', anchor = 'bottom-right', l = 1353, r = 1493, b = 191, t = 330 },
    { name = 'SkillKey', anchor = 'bottom-right', l = 1458, r = 1597, b = 26, t = 166 },
    { name = 'Avatar', anchor = 'bottom-right', l = 1710, r = 1920, b = 0, t = 140 },
    { name = 'Version', anchor = 'bottom-left', l = 14, r = 710, b = 15, t = 45 },
}
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

local function bounds(controls, pad)
    local l, r, b, t
    for _, c in pairs(controls) do
        local cl, cr, cb, ct = edgesOf(c)
        l, r = math.min(l or cl, cl), math.max(r or cr, cr)
        b, t = math.min(b or cb, cb), math.max(t or ct, ct)
    end
    if not l then return nil end
    return fromEdges(l - pad, r + pad, b - pad, t + pad)
end

local function clampSlots(n)
    local items = GameCfg.Items
    n = type(n) == 'number' and math.floor(n) or items.InitialItemBarSlots
    return math.max(items.InitialItemBarSlots, math.min(items.ItemBarSlots, n))
end

local RING = 100
local COIN_ICON, COIN_LABEL_W, COIN_LABEL_H = 56, 130, 50
local ENTRY_W, ENTRY_H, ENTRY_GAP = 130, 60, 8
local QUEST_W, QUEST_TOGGLE_W, QUEST_TOGGLE_H, QUEST_PANEL_H = 450, 120, 48, 110
local CELL, SLOT_STEP, GROUP_GAP = 80, 84, 12
local BACKPACK_W = 130
local ATTACK = 180
local ACTION_W, ACTION_H = 180, 90
local BACKPACK_PANEL_W, BACKPACK_PANEL_H = 850, 690
local POPUP_STEP = 86
local CENTER_HALF_W, CENTER_HALF_H_RATIO = 280, 0.18

-- input = { width, height, itemBarSlots, reeling }
-- 返回 { Regions = { 区域名 = { bounds, Controls } }, Rects = 扁平索引,
--        ItemBarSlots = { 第 1..N 格 }, Panels = { BackpackPanel }, Reserved = { { name, rect } },
--        Popup = 候选行参数（供 popup_cells） }
function MainHudLayout.compute(input)
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

    local statusTop = bottom(zone.SystemButtons) - GAP
    local ringY = statusTop - RING / 2
    local x0 = SAFE + 8
    local status = {
        HealthRing = rect(x0 + RING / 2, ringY, RING, RING),
        HungerRing = rect(x0 + RING * 1.5 + GAP, ringY, RING, RING),
    }
    local coinX = right(status.HungerRing) + GAP + COIN_ICON / 2
    status.coin_icon = rect(coinX, ringY, COIN_ICON, COIN_ICON)
    status.coin_label = rect(coinX + COIN_ICON / 2 + 8 + COIN_LABEL_W / 2, ringY, COIN_LABEL_W, COIN_LABEL_H)

    local entryY = H - 105
    local entryRight = left(zone.WarningKey) - GAP
    local entries = {
        BlindboxEntry = rect(entryRight - ENTRY_W / 2, entryY, ENTRY_W, ENTRY_H),
    }
    entries.ShopEntry = rect(entries.BlindboxEntry.x - ENTRY_W - ENTRY_GAP, entryY, ENTRY_W, ENTRY_H)
    entries.CompendiumEntry = rect(entries.ShopEntry.x - ENTRY_W - ENTRY_GAP, entryY, ENTRY_W, ENTRY_H)

    local hintTop = H - SAFE - 4
    local hints = { hint_primary = rect(W / 2, hintTop - 32, 520, 64) }
    hints.hint_secondary = rect(W / 2, bottom(hints.hint_primary) - 8 - 28, 520, 56)
    hints.hint_transient = rect(W / 2, bottom(hints.hint_secondary) - 8 - 30, 740, 60)

    local questTop = ringY - RING / 2 - GAP * 2
    local questBottom = top(stickZone) + GAP
    local questLeft = SAFE + 4
    local quest = {
        quest_toggle = rect(questLeft + QUEST_TOGGLE_W / 2, questTop - QUEST_TOGGLE_H / 2,
            QUEST_TOGGLE_W, QUEST_TOGGLE_H),
    }
    quest.quest_panel = rect(questLeft + QUEST_W / 2, bottom(quest.quest_toggle) - 8 - QUEST_PANEL_H / 2,
        QUEST_W, QUEST_PANEL_H)
    local questBounds = fromEdges(questLeft, questLeft + QUEST_W, questBottom, questTop)

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
    equip.backpack_button = rect(right(itemBar[slots]) + GROUP_GAP + BACKPACK_W / 2, barY, BACKPACK_W, CELL)
    equip.BaitBar = rect(right(equip.backpack_button) + GROUP_GAP + CELL / 2, barY, CELL, CELL)
    local equipBounds = fromEdges(bandLeft, bandRight, barY - CELL / 2 - 8, barY + CELL / 2 + 8)

    local actionBase = top(zone.Jump) + GAP
    local action = { attack_control = rect(W - 230, actionBase + ATTACK / 2, ATTACK, ATTACK) }
    action.item_action = rect(left(action.attack_control) - GAP - ACTION_W / 2, action.attack_control.y,
        ACTION_W, ACTION_H)
    action.discard = rect(action.attack_control.x, top(action.attack_control) + GAP + ACTION_H / 2,
        ACTION_W, ACTION_H)
    if input.reeling then
        action.reel_close = rect(action.item_action.x, top(action.item_action) + GAP + ACTION_H / 2,
            ACTION_W, ACTION_H)
    end

    local centerClear = rect(W / 2, H / 2, CENTER_HALF_W * 2, H * CENTER_HALF_H_RATIO * 2)

    local panelBottom = top(equipBounds) + GAP
    local panelY = math.max(panelBottom + BACKPACK_PANEL_H / 2, (panelBottom + H - SAFE) / 2)
    local backpackPanel = rect(W / 2, panelY, BACKPACK_PANEL_W, BACKPACK_PANEL_H)

    local regions = {
        StatusTopLeft = { bounds = bounds(status, 4), controls = status },
        EntriesTopRight = { bounds = bounds(entries, 4), controls = entries },
        QuestLeft = { bounds = questBounds, controls = quest },
        HintTop = { bounds = bounds(hints, 4), controls = hints },
        EquipBottom = { bounds = equipBounds, controls = equip },
        ActionRight = { bounds = bounds(action, 4), controls = action },
        CenterClear = { bounds = centerClear, controls = {} },
    }
    local rects = {}
    for _, region in pairs(regions) do
        for name, r in pairs(region.controls) do rects[name] = r end
    end
    return {
        regions = regions, rects = rects, ItemBarSlots = itemBar,
        panels = { BackpackPanel = backpackPanel },
        reserved = reserved,
        popup = { left = bandLeft, right = left(zone.Roll) - GAP, firstY = top(equipBounds) + GAP + CELL / 2,
            cell = CELL, step = POPUP_STEP },
    }
end

-- 以设备分辨率与道具栏格数算主 HUD 布局。格数口径由调用方视图给出（各视图读
-- item_bar 状态的有效性判定与兜底不同），这里不替调用方归一。
function MainHudLayout.from_resolution(resolution, item_bar_slots)
    return MainHudLayout.compute({
        width = resolution.x,
        height = resolution.y,
        itemBarSlots = item_bar_slots,
    })
end

function MainHudLayout.popup_cells(layout, kind, count)
    local bar = layout and layout.rects and layout.rects[kind .. 'Bar']
    if not bar or type(count) ~= 'number' or count < 1 then return {} end
    local p = layout.popup
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

function MainHudLayout.bounds(rects, pad)
    return bounds(rects or {}, pad or 0)
end

function MainHudLayout.bottom_left(r)
    return r.x - r.w / 2, r.y - r.h / 2
end

return MainHudLayout
