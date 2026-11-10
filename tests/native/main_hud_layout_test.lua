-- #179 主界面布局模块（client.MainHudLayout）：纯函数，只断言约束，不断言具体坐标。
-- 接缝：MainHudLayout.Compute(input) 的输出矩形 + MainHudLayout.PopupCells(layout, kind, count)。
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
local MainHudLayout = require('client.MainHudLayout')
local GameCfg = require('common.GameCfg')

local HEIGHTS = { 886, 1080, 1238, 1440 }
local SLOT_COUNTS = { 2, 8 }
local REELING = { false, true }
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

-- 常驻控件：除中央留空区外各区的全部命名矩形（中央留空区本身没有控件）
local function residents(layout)
    local out = {}
    for _, region in ipairs(REGION_NAMES) do
        for name, rect in pairs(layout.Regions[region].Controls) do
            out[#out + 1] = { name = name, rect = rect, region = region }
        end
    end
    table.sort(out, function(a, b) return a.name < b.name end)
    return out
end

local function each_case(fn)
    for _, h in ipairs(HEIGHTS) do
        for _, slots in ipairs(SLOT_COUNTS) do
            for _, reeling in ipairs(REELING) do
                local layout = MainHudLayout.Compute({ width = 1920, height = h,
                    itemBarSlots = slots, reeling = reeling })
                fn(layout, string.format('1920x%d slots=%d reeling=%s', h, slots, tostring(reeling)),
                    { height = h, slots = slots, reeling = reeling })
            end
        end
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
                assert.is_table(entry, case .. ' ' .. region)
                assert.is_table(entry.Bounds, case .. ' ' .. region)
                for name, rect in pairs(entry.Controls) do
                    assert.is_true(inside(rect, entry.Bounds), case .. ' ' .. region .. '.' .. name)
                    assert.equal(rect, layout.Rects[name], case .. ' 扁平索引 ' .. name)
                end
            end
            assert.same({}, layout.Regions.CenterClear.Controls, case)
        end)
    end)

    it('test_residents_pairwise_disjoint', function()
        each_case(function(layout, case)
            local list = residents(layout)
            assert.is_true(#list >= 20, case)
            for i = 1, #list do
                for j = i + 1, #list do
                    local a, b = list[i], list[j]
                    assert.is_false(overlaps(a.rect, b.rect), string.format('%s %s%s 与 %s%s 重叠',
                        case, a.name, describe_rect(a.rect), b.name, describe_rect(b.rect)))
                end
            end
        end)
    end)

    it('test_residents_on_screen_with_margin', function()
        each_case(function(layout, case, input)
            local screen = { x = 960, y = input.height / 2, w = 1920 - 2 * EDGE, h = input.height - 2 * EDGE }
            for _, item in ipairs(residents(layout)) do
                assert.is_true(item.rect.w > 0 and item.rect.h > 0, case .. ' ' .. item.name)
                assert.is_true(inside(item.rect, screen), case .. ' 出屏 ' .. item.name .. describe_rect(item.rect))
            end
        end)
    end)

    it('test_residents_avoid_engine_reserved', function()
        each_case(function(layout, case, input)
            assert.is_true(#layout.Reserved >= 8, case)
            -- 保留区自身随屏幕比例换算：顶部组离顶距离不变，都在屏幕内
            for _, zone in ipairs(layout.Reserved) do
                local _, _, bottom, top = edges(zone.rect)
                assert.is_true(bottom >= -20 and top <= input.height + 20, case .. ' ' .. zone.name)
            end
            for _, item in ipairs(residents(layout)) do
                for _, zone in ipairs(layout.Reserved) do
                    assert.is_false(overlaps(item.rect, zone.rect), string.format('%s %s%s 进入保留区 %s%s',
                        case, item.name, describe_rect(item.rect), zone.name, describe_rect(zone.rect)))
                end
            end
        end)
    end)

    it('test_top_reserved_follow_screen_top', function()
        -- 左上系统按钮组实测在 1238 高时离顶 77–181；换算到 886 高时仍贴着顶部，而不是留在原 y
        local low = MainHudLayout.Compute({ width = 1920, height = 886, itemBarSlots = 2 })
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
            assert.is_true(inside(core, layout.Regions.CenterClear.Bounds), case)
            for _, item in ipairs(residents(layout)) do
                assert.is_false(overlaps(item.rect, layout.Regions.CenterClear.Bounds),
                    case .. ' 中央留空区内有 ' .. item.name)
            end
        end)
    end)

    it('test_item_bar_slot_count_and_centered', function()
        each_case(function(layout, case, input)
            assert.same(input.slots, #layout.ItemBarSlots, case)
            for i, rect in ipairs(layout.ItemBarSlots) do
                assert.equal(rect, layout.Rects['ItemBarSlot' .. i], case)
            end
            -- 装备栏一行（武器栏｜道具栏｜背包｜鱼饵栏）从左到右，整体居中（偏离屏幕中线不超过 60）
            local weapon, bait = layout.Rects.WeaponBar, layout.Rects.BaitBar
            local first, last = layout.ItemBarSlots[1], layout.ItemBarSlots[#layout.ItemBarSlots]
            local backpack = layout.Rects.BackpackButton
            assert.is_true(weapon.x < first.x and last.x < backpack.x and backpack.x < bait.x, case)
            local left = edges(weapon)
            local _, right = edges(bait)
            assert.is_true(math.abs((left + right) / 2 - 960) <= 60, case)
        end)
    end)

    it('test_quest_width_at_most_quarter_screen', function()
        each_case(function(layout, case)
            local bounds = layout.Regions.QuestLeft.Bounds
            assert.is_true(bounds.w <= 1920 / 4, case)
            assert.is_not_nil(layout.Rects.QuestPanel, case)
            assert.is_not_nil(layout.Rects.QuestToggle, case)
            -- 面板至少能放三行 24 号字
            assert.is_true(layout.Rects.QuestPanel.h >= 3 * 24, case)
        end)
    end)

    it('test_reel_close_only_while_reeling_and_clear_of_attack', function()
        each_case(function(layout, case, input)
            local close, attack = layout.Rects.ReelClose, layout.Rects.AttackControl
            assert.is_not_nil(attack, case)
            assert.is_not_nil(layout.Rects.ItemAction, case)
            if input.reeling then
                assert.is_not_nil(close, case)
                assert.is_false(overlaps(close, attack), case)
            else
                assert.is_nil(close, case)
            end
        end)
    end)

    it('test_entries_reserve_shop_slot', function()
        each_case(function(layout, case)
            for _, name in ipairs({ 'CompendiumEntry', 'ShopEntry', 'BlindboxEntry' }) do
                assert.is_not_nil(layout.Regions.EntriesTopRight.Controls[name], case .. ' ' .. name)
            end
        end)
    end)

    it('test_backpack_panel_clear_of_equip_bar_and_quest', function()
        each_case(function(layout, case, input)
            local panel = layout.Panels.BackpackPanel
            local screen = { x = 960, y = input.height / 2, w = 1920, h = input.height }
            assert.is_true(inside(panel, screen), case)
            assert.is_true(panel.w >= 850 and panel.h >= 690, case .. ' 面板内部排版不变，尺寸不缩')
            for _, region in ipairs({ 'EquipBottom', 'QuestLeft' }) do
                for name, rect in pairs(layout.Regions[region].Controls) do
                    assert.is_false(overlaps(panel, rect), case .. ' 背包面板压住 ' .. name)
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
                    local cells = MainHudLayout.PopupCells(layout, kind, n)
                    assert.same(n, #cells, case .. ' ' .. kind)
                    for i, cell in ipairs(cells) do
                        local label = string.format('%s %s 候选 %d/%d', case, kind, i, n)
                        assert.is_true(inside(cell, screen), label .. ' 出屏 ' .. describe_rect(cell))
                        assert.is_true(cell.y > bar.y, label .. ' 应在栏位上方')
                        assert.is_false(overlaps(cell, bar), label .. ' 压住栏位')
                        for _, zone in ipairs(layout.Reserved) do
                            assert.is_false(overlaps(cell, zone.rect), label .. ' 进入保留区 ' .. zone.name)
                        end
                        for j = i + 1, #cells do
                            assert.is_false(overlaps(cell, cells[j]), label .. ' 候选互叠')
                        end
                    end
                end
            end
        end)
    end)

    it('test_compute_is_pure_and_rejects_bad_input', function()
        local a = MainHudLayout.Compute({ width = 1920, height = 1080, itemBarSlots = 8 })
        local b = MainHudLayout.Compute({ width = 1920, height = 1080, itemBarSlots = 8 })
        assert.same(a, b)
        assert.is_not.equal(a, b) -- 每次返回新表，调用方改动不串到下一次
        -- 道具栏格数越界时夹到 2–8
        assert.same(8, #MainHudLayout.Compute({ width = 1920, height = 1080, itemBarSlots = 20 }).ItemBarSlots)
        assert.same(2, #MainHudLayout.Compute({ width = 1920, height = 1080, itemBarSlots = 0 }).ItemBarSlots)
        assert.same(2, #MainHudLayout.Compute({ width = 1920, height = 1080 }).ItemBarSlots)
    end)
end)
