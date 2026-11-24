-- #179 主界面布局模块（client.main_hud_layout）：纯函数，只断言约束，不断言具体坐标。
-- 接缝：MainHudLayout.compute(input) 的输出矩形 + MainHudLayout.popup_cells(layout, kind, count)。
--
-- 动手前列出的失败方式（本文件逐条覆盖）：
--   1. 常驻控件两两重叠（结束收线压攻击键、提示行互叠、入口组叠在一起……）；
--   2. 矮屏（EUI 1920×886）时上下区域挤压，任务区 / 状态区高度为负或越出屏幕；
--   3. 控件出屏或贴边（没有安全边距）；
--   4. 控件进入引擎保留区（顶部组随屏幕高度平移时方向算反）；
--   5. 中央留空区里有控件，或者留空区小到形同虚设；
--   6. 道具栏只开 2 格时偏向一边；格数变化后格子数量不对；
--   7. 武器栏 / 鱼饵栏候选行取最大候选数时出屏、压进引擎保留区或压住栏位本身；
--   8. 任务追踪条宽度超过屏幕 1/4；
--   9. 收线期间「结束收线」没有占位，或与攻击键重叠；
--  10. 背包面板与装备栏、任务区重叠；
--  11. 区域名不全，或控件不在自己所属的区域范围内。
--
-- 参数矩阵（提速，2026-11-18）：原来是「屏高 × 格数 × 是否收线」的 16 组全组合。
-- 有意义的只是三个因子的两两组合——每个屏高都配过两种格数、两种收线态，每个格数也都配过
-- 两种收线态。改成 8 组两两覆盖后，任一「对」因子取值仍各出现一次；被略去的 8 组只会
-- 让三个因子同时取到第三档，不产生新的几何约束（compute 是纯函数，同组输入只算一次）。
--
-- 断言消息（同一轮提速）：以前每个「通过」的断言也拼一次 string.format 与 describe_rect，
-- 单是 popup 用例就有数万次格式化，是文件级 2.2 s 的主要来源。现在只在失败分支里拼。
local MainHudLayout = require('client.main_hud_layout')
local GameCfg = require('common.game_cfg')

-- 三因子两两覆盖：{ 屏幕高, 道具栏格数, 是否收线 }
--   屏高 × 格数：886/1080/1238/1440 各自都配过 2 与 8；
--   屏高 × 收线：每个屏高都配过一次 true、一次 false；
--   格数 × 收线：2 格与 8 格都各配过 true 与 false。
local CASES = {
    { 886, 2, false },
    { 886, 8, true },
    { 1080, 2, true },
    { 1080, 8, false },
    { 1238, 2, false },
    { 1238, 8, true },
    { 1440, 2, true },
    { 1440, 8, false },
}
-- 安全边距的独立口径：所有常驻控件离屏幕边至少这么远
local EDGE = 10

local REGION_NAMES = { 'StatusTopLeft', 'EntriesTopRight', 'QuestLeft', 'HintTop',
    'EquipBottom', 'ActionRight', 'CenterClear' }

local function edges(r)
    return r.x - r.w / 2, r.x + r.w / 2, r.y - r.h / 2, r.y + r.h / 2
end

local function overlaps(a, b)
    local al, ar, ab, at = edges(a)
    local bl, br, bb, bt = edges(b)
    return al < br and bl < ar and ab < bt and bb < at
end

local function inside(inner, outer)
    local il, ir, ib, it = edges(inner)
    local ol, orr, ob, ot = edges(outer)
    return il >= ol and ir <= orr and ib >= ob and it <= ot
end

local function describe_rect(r)
    return string.format('(%.0f,%.0f %.0fx%.0f)', r.x, r.y, r.w, r.h)
end

-- 只在失败时构造消息：调用点写成 if not cond then fail(fmt, ...) end，
-- 通过时不产生任何字符串。assert.is_true(false, msg) 与直接写断言等价，失败信息照旧。
local function fail(fmt, ...)
    assert.is_true(false, string.format(fmt, ...))
end

-- 常驻控件：除中央留空区外各区的全部命名矩形（中央留空区本身没有控件）。
-- 每个布局只排一次表：以前每次调用 residents 都重排一次。
local RESIDENTS = {}
local function residents(layout)
    local cached = RESIDENTS[layout]
    if cached then return cached end
    local out = {}
    for _, region in ipairs(REGION_NAMES) do
        for name, rect in pairs(layout.Regions[region].Controls) do
            out[#out + 1] = { name = name, rect = rect, region = region }
        end
    end
    table.sort(out, function(a, b) return a.name < b.name end)
    RESIDENTS[layout] = out
    return out
end

-- compute 是纯函数（test_compute_is_pure_and_rejects_bad_input 逐条断言）：同样的输入只算一次。
local LAYOUTS = {}

local function each_case(fn)
    for _, combo in ipairs(CASES) do
        local height, slots, reeling = combo[1], combo[2], combo[3]
        local key = string.format('%d:%d:%s', height, slots, tostring(reeling))
        local layout = LAYOUTS[key]
        if not layout then
            layout = MainHudLayout.compute({ width = 1920, height = height,
                itemBarSlots = slots, reeling = reeling })
            LAYOUTS[key] = layout
        end
        fn(layout, string.format('1920x%d slots=%d reeling=%s', height, slots, tostring(reeling)),
            { height = height, slots = slots, reeling = reeling })
    end
end

-- 候选数上限取真实配置：武器 = 近战 + 远程；鱼饵栏 = 全部鱼饵 + 「不挂鱼饵」+「吃蚯蚓」
local function max_candidates()
    local weapons, baits = 0, 2
    for _, def in pairs(GameCfg.Items.Definitions) do
        if def.Type == '近战武器' or def.Type == '远程武器' then weapons = weapons + 1 end
        if def.Type == '鱼饵' then baits = baits + 1 end
    end
    return { Weapon = weapons, Bait = baits }
end

describe('主界面布局模块', function()
    it('test_regions_named_and_controls_inside_their_region', function()
        each_case(function(layout, case)
            for _, region in ipairs(REGION_NAMES) do
                local entry = layout.Regions[region]
                if type(entry) ~= 'table' or type(entry.bounds) ~= 'table' then
                    fail('%s %s 区域或边界缺失', case, region)
                end
                for name, rect in pairs(entry.Controls) do
                    if not inside(rect, entry.bounds) then
                        fail('%s %s.%s 越出自己的区域', case, region, name)
                    end
                    if rect ~= layout.Rects[name] then
                        assert.equal(rect, layout.Rects[name], case .. ' 扁平索引 ' .. name)
                    end
                end
            end
            assert.same({}, layout.Regions.CenterClear.Controls, case)
        end)
    end)

    it('test_residents_pairwise_disjoint', function()
        each_case(function(layout, case)
            local list = residents(layout)
            if #list < 20 then fail('%s 常驻控件只有 %d 个', case, #list) end
            for i = 1, #list do
                local a = list[i]
                for j = i + 1, #list do
                    local b = list[j]
                    if overlaps(a.rect, b.rect) then
                        fail('%s %s%s 与 %s%s 重叠', case,
                            a.name, describe_rect(a.rect), b.name, describe_rect(b.rect))
                    end
                end
            end
        end)
    end)

    it('test_residents_on_screen_with_margin', function()
        each_case(function(layout, case, input)
            local screen = { x = 960, y = input.height / 2, w = 1920 - 2 * EDGE, h = input.height - 2 * EDGE }
            for _, item in ipairs(residents(layout)) do
                if not (item.rect.w > 0 and item.rect.h > 0) then
                    fail('%s %s 尺寸非正', case, item.name)
                end
                if not inside(item.rect, screen) then
                    fail('%s 出屏 %s%s', case, item.name, describe_rect(item.rect))
                end
            end
        end)
    end)

    it('test_residents_avoid_engine_reserved', function()
        each_case(function(layout, case, input)
            if #layout.Reserved < 8 then fail('%s 保留区只有 %d 个', case, #layout.Reserved) end
            -- 保留区自身随屏幕比例换算：顶部组离顶距离不变，都在屏幕内
            for _, zone in ipairs(layout.Reserved) do
                local _, _, bottom, top = edges(zone.rect)
                if not (bottom >= -20 and top <= input.height + 20) then
                    fail('%s 保留区 %s 跑出屏幕', case, zone.name)
                end
            end
            for _, item in ipairs(residents(layout)) do
                for _, zone in ipairs(layout.Reserved) do
                    if overlaps(item.rect, zone.rect) then
                        fail('%s %s%s 进入保留区 %s%s', case,
                            item.name, describe_rect(item.rect), zone.name, describe_rect(zone.rect))
                    end
                end
            end
        end)
    end)

    it('test_top_reserved_follow_screen_top', function()
        -- 左上系统按钮组实测在 1238 高时离顶 77–181；换算到 886 高时仍贴着顶部，而不是留在原 y
        local low = MainHudLayout.compute({ width = 1920, height = 886, itemBarSlots = 2 })
        local found
        for _, zone in ipairs(low.Reserved) do
            local left, _, _, top = edges(zone.rect)
            if left < 100 and top > 800 then found = zone end
        end
        assert.is_not_nil(found, '886 高时左上保留区应贴着屏幕顶部')
    end)

    it('test_center_clear_is_meaningful', function()
        each_case(function(layout, case, input)
            -- 角色周围至少留出 ±240 × ±150 的空白
            local core = { x = 960, y = input.height / 2, w = 480, h = 300 }
            if not inside(core, layout.Regions.CenterClear.bounds) then
                fail('%s 中央留空区不足 ±240 × ±150', case)
            end
            for _, item in ipairs(residents(layout)) do
                if overlaps(item.rect, layout.Regions.CenterClear.bounds) then
                    fail('%s 中央留空区内有 %s', case, item.name)
                end
            end
        end)
    end)

    it('test_item_bar_slot_count_and_centered', function()
        each_case(function(layout, case, input)
            if #layout.ItemBarSlots ~= input.slots then
                fail('%s 道具栏格数 %d，期望 %d', case, #layout.ItemBarSlots, input.slots)
            end
            for i, rect in ipairs(layout.ItemBarSlots) do
                if rect ~= layout.Rects['ItemBarSlot' .. i] then
                    assert.equal(rect, layout.Rects['ItemBarSlot' .. i], case)
                end
            end
            -- 装备栏一行（武器栏｜道具栏｜背包｜鱼饵栏）从左到右，整体居中（偏离屏幕中线不超过 60）
            local weapon, bait = layout.Rects.WeaponBar, layout.Rects.BaitBar
            local first, last = layout.ItemBarSlots[1], layout.ItemBarSlots[#layout.ItemBarSlots]
            local backpack = layout.Rects.BackpackButton
            if not (weapon.x < first.x and last.x < backpack.x and backpack.x < bait.x) then
                fail('%s 装备栏一行左右顺序不对', case)
            end
            local left = edges(weapon)
            local _, right = edges(bait)
            if math.abs((left + right) / 2 - 960) > 60 then
                fail('%s 装备栏偏离中线 %.0f', case, math.abs((left + right) / 2 - 960))
            end
        end)
    end)

    it('test_quest_width_at_most_quarter_screen', function()
        each_case(function(layout, case)
            local bounds = layout.Regions.QuestLeft.bounds
            if bounds.w > 1920 / 4 then fail('%s 任务区宽 %.0f 超过屏幕 1/4', case, bounds.w) end
            assert.is_not_nil(layout.Rects.QuestPanel, case)
            assert.is_not_nil(layout.Rects.QuestToggle, case)
            -- 面板至少能放三行 24 号字
            if layout.Rects.QuestPanel.h < 3 * 24 then
                fail('%s 任务面板高 %.0f 放不下三行', case, layout.Rects.QuestPanel.h)
            end
        end)
    end)

    it('test_reel_close_only_while_reeling_and_clear_of_attack', function()
        each_case(function(layout, case, input)
            local close, attack = layout.Rects.ReelClose, layout.Rects.AttackControl
            assert.is_not_nil(attack, case)
            assert.is_not_nil(layout.Rects.ItemAction, case)
            if input.reeling then
                assert.is_not_nil(close, case)
                if overlaps(close, attack) then fail('%s 结束收线压住攻击键', case) end
            else
                assert.is_nil(close, case)
            end
        end)
    end)

    it('test_entries_reserve_shop_slot', function()
        each_case(function(layout, case)
            for _, name in ipairs({ 'CompendiumEntry', 'ShopEntry', 'BlindboxEntry' }) do
                if layout.Regions.EntriesTopRight.Controls[name] == nil then
                    fail('%s 入口区缺 %s', case, name)
                end
            end
        end)
    end)

    it('test_backpack_panel_clear_of_equip_bar_and_quest', function()
        each_case(function(layout, case, input)
            local panel = layout.Panels.BackpackPanel
            local screen = { x = 960, y = input.height / 2, w = 1920, h = input.height }
            if not inside(panel, screen) then
                fail('%s 背包面板出屏 %s', case, describe_rect(panel))
            end
            if not (panel.w >= 850 and panel.h >= 690) then
                fail('%s 背包面板缩到 %s', case, describe_rect(panel))
            end
            for _, region in ipairs({ 'EquipBottom', 'QuestLeft' }) do
                for name, rect in pairs(layout.Regions[region].Controls) do
                    if overlaps(panel, rect) then
                        fail('%s 背包面板压住 %s', case, name)
                    end
                end
            end
        end)
    end)

    it('test_popup_rows_with_max_candidates_stay_on_screen', function()
        local max = max_candidates()
        assert.is_true(max.Weapon >= 2 and max.Bait >= 3)
        each_case(function(layout, case, input)
            local screen = { x = 960, y = input.height / 2, w = 1920 - 2 * EDGE, h = input.height - 2 * EDGE }
            for kind, count in pairs(max) do
                local bar = layout.Rects[kind .. 'Bar']
                for n = 1, count do
                    local cells = MainHudLayout.popup_cells(layout, kind, n)
                    if #cells ~= n then
                        fail('%s %s 候选 %d 只生成 %d 格', case, kind, n, #cells)
                    end
                    for i, cell in ipairs(cells) do
                        if not inside(cell, screen) then
                            fail('%s %s 候选 %d/%d 出屏 %s', case, kind, i, n, describe_rect(cell))
                        end
                        if not (cell.y > bar.y) then
                            fail('%s %s 候选 %d/%d 不在栏位上方', case, kind, i, n)
                        end
                        if overlaps(cell, bar) then
                            fail('%s %s 候选 %d/%d 压住栏位', case, kind, i, n)
                        end
                        for _, zone in ipairs(layout.Reserved) do
                            if overlaps(cell, zone.rect) then
                                fail('%s %s 候选 %d/%d 进入保留区 %s%s', case, kind, i, n,
                                    zone.name, describe_rect(zone.rect))
                            end
                        end
                        for j = i + 1, #cells do
                            if overlaps(cell, cells[j]) then
                                fail('%s %s 候选 %d/%d 与 %d/%d 互叠', case, kind, i, n, j, n)
                            end
                        end
                    end
                end
            end
        end)
    end)

    it('test_compute_is_pure_and_rejects_bad_input', function()
        local a = MainHudLayout.compute({ width = 1920, height = 1080, itemBarSlots = 8 })
        local b = MainHudLayout.compute({ width = 1920, height = 1080, itemBarSlots = 8 })
        assert.same(a, b)
        assert.is_not.equal(a, b) -- 每次返回新表，调用方改动不串到下一次
        -- 道具栏格数越界时夹到 2–8
        assert.same(8, #MainHudLayout.compute({ width = 1920, height = 1080, itemBarSlots = 20 }).ItemBarSlots)
        assert.same(2, #MainHudLayout.compute({ width = 1920, height = 1080, itemBarSlots = 0 }).ItemBarSlots)
        assert.same(2, #MainHudLayout.compute({ width = 1920, height = 1080 }).ItemBarSlots)
    end)
end)
