-- #180 武器栏、鱼饵栏单格与弹窗（spec #178）。
-- 接缝：ScreenMain 处理器 + ItemBarState / CastState 客户端事件 + 假 World 替身；
-- 只看节点的可见性、文字、可点性、位置（对照布局模块输出）与发出的命令。
--
-- 动手前列出的失败方式：
--   1. 武器栏、鱼饵栏不在布局给的格位，或道具栏格数变化后没跟着重排；
--   2. 候选格不在 PopupCells 给的位置（出屏或与栏位错开）；
--   3. 武器弹窗漏掉库存为 0 的武器，或这些武器没置灰、仍可点；
--   4. 候选格发出的命令与原平铺按钮不一致（attack 带 seq、SelectBait id / nil、EatBait worm）；
--   5. 选中后弹窗不关；两个弹窗同时开；点空白不关；再点栏位不收起；
--   6. 蚯蚓为 0 时「吃蚯蚓」仍可点；
--   7. 栏位文字不随快照更新（手持武器 / 选中饵变化后仍显示旧的；没有武器时残留）；
--   8. 弹窗开着时快照刷新，内容不更新（数量、动态饵移除后残留或占位）；
--   9. 背包打开时栏位与弹窗没收起；关背包后栏位不恢复或弹窗复活；
--  10. 「蚯蚓用尽」仍是按钮文字；临时提示不出现、不消失；开局即 0 时误报；
--      抛竿扣掉最后一只蚯蚓时，提示打断「等待上钩」与浮标，或被随后的 CastState 立刻清掉；
--  11. 「吃」按钮没有食物时仍显示或可点（吃蚯蚓入口残留）；
--  12. 重进界面后弹窗节点或监听残留。
local MainHudLayout = require('client.MainHudLayout')
local GameCfg = require('common.GameCfg')

-- 玩家可见名取自物品表；折行只为放进 80 宽的格子，比较文字时去掉换行
local NAME = setmetatable({}, { __index = function(_, id) return GameCfg.Items.Definitions[id].Name end })
local function plain(text) return (tostring(text or ''):gsub('\n', '')) end

local function signal()
    local listeners = {}
    return {
        Connect = function(_, fn)
            listeners[#listeners + 1] = fn
            return { Disconnect = function()
                for i, cb in ipairs(listeners) do
                    if cb == fn then table.remove(listeners, i) break end
                end
            end }
        end,
        Fire = function(_, ...) for _, fn in ipairs(listeners) do fn(...) end end,
        Count = function() return #listeners end,
    }
end

local GLOBALS = { 'game', 'Vector2', 'Vector3', 'Color', 'REUtil', 'GameUI', 'MgrGameUI', 'LocalReelIn' }

local function setUp(height)
    local ctx = { nodes = {}, created = {}, commands = {}, sent = {}, events = {}, now = 100,
        height = height or 1080 }
    ctx.previous = {}
    for _, key in ipairs(GLOBALS) do ctx.previous[key] = rawget(_G, key) end
    ctx.previousAttack = package.loaded['client.LocalAttackButton']
    package.loaded['client.LocalAttackButton'] = nil
    _G.MgrGameUI = { SetCustomControlUI = function() end }
    local world = { Created = ctx.created }
    function world:CreateUnit(kind, attrs)
        local node = { Kind = kind, OnClicked = signal() }
        for key, value in pairs(attrs) do node[key] = value end
        function node:Destroy()
            self.Destroyed = true
            for _, child in ipairs(world.Created) do
                if child.Parent == self then child:Destroy() end
            end
        end
        ctx.nodes[node.Name] = node
        ctx.created[#ctx.created + 1] = node
        return node
    end
    function world:GetServerTime() return ctx.now end
    local players = { LocalPlayer = nil }
    _G.game = { GetService = function(_, name)
        if name == 'World' then return world end
        if name == 'Players' then return players end
    end }
    _G.Vector2 = { New = function(x, y) return { x = x, y = y } end }
    _G.Vector3 = { New = function(x, y, z) return { x = x, y = y, z = z } end }
    _G.Color = { New = function(...) return { ... } end }
    _G.GameUI = { GetEuiManager = function() return {
        GetDeviceResolution = function() return { x = 1920, y = ctx.height } end,
    } end }
    _G.REUtil = { GetRE = function(_, name)
        if not ctx.events[name] then
            ctx.events[name] = { OnClientEvent = signal(), FireServer = function(_, payload)
                ctx.sent[#ctx.sent + 1] = { name = name, payload = payload }
                if name == 'ItemBarAction' then ctx.commands[#ctx.commands + 1] = payload end
            end }
        end
        return ctx.events[name]
    end }
    _G.LocalReelIn = { SetSession = function() end, Clear = function() end, Suspend = function() end }
    ctx.states = _G.REUtil:GetRE('ItemBarState').OnClientEvent
    ctx.handler = assert(loadfile('client/ScreenHandlers/ScreenMain.lua'))()
    ctx.handler.RootNode = { Name = 'ScreenMain', FindFirstChild = function() return nil end }
    ctx.handler:Init()
    ctx.handler.IsOpen = true
    return ctx
end

local function tearDown(ctx)
    require('client.LocalAttackButton'):Destroy()
    package.loaded['client.LocalAttackButton'] = ctx.previousAttack
    for _, key in ipairs(GLOBALS) do _G[key] = ctx.previous[key] end
end

local function layoutFor(height, slots)
    return MainHudLayout.Compute({ width = 1920, height = height, itemBarSlots = slots, reeling = false })
end

local function assertAt(node, rect, label)
    assert.is_not_nil(node, label)
    assert.same({ x = rect.x, y = rect.y, w = rect.w, h = rect.h },
        { x = node.Position.x, y = node.Position.y, w = node.Size.x, h = node.Size.y }, label)
end

describe('武器栏、鱼饵栏与弹窗（#180）', function()
    local ctx
    after_each(function() if ctx then tearDown(ctx) end ctx = nil end)

    it('test_bars_follow_layout_and_relayout_with_slot_count', function()
        ctx = setUp(886)
        ctx.states:Fire({ slots = {}, slotCount = 2, bait = {}, weapons = {}, backpackCount = 5 })
        local two = layoutFor(886, 2).Rects
        assertAt(ctx.nodes.WeaponBar, two.WeaponBar, 'WeaponBar @2')
        assertAt(ctx.nodes.WeaponBarLabel, two.WeaponBar, 'WeaponBarLabel @2')
        assertAt(ctx.nodes.BaitBar, two.BaitBar, 'BaitBar @2')
        assertAt(ctx.nodes.BaitBarLabel, two.BaitBar, 'BaitBarLabel @2')
        ctx.states:Fire({ slots = {}, slotCount = 8, bait = {}, weapons = {}, backpackCount = 5 })
        local eight = layoutFor(886, 8).Rects
        assertAt(ctx.nodes.WeaponBar, eight.WeaponBar, 'WeaponBar @8')
        assertAt(ctx.nodes.BaitBar, eight.BaitBar, 'BaitBar @8')
        assertAt(ctx.nodes.BaitBarLabel, eight.BaitBar, 'BaitBarLabel @8')
    end)

    it('test_weapon_bar_shows_held_then_selected_weapon_or_empty', function()
        ctx = setUp(1080)
        ctx.states:Fire({ slots = {}, bait = {}, weapons = {} })
        assert.same('', plain(ctx.nodes.WeaponBarLabel.Text))
        ctx.states:Fire({ slots = {}, bait = {}, weapons = { item134 = 1, item136 = 2 }, selectedWeapon = 'item136' })
        assert.truthy(plain(ctx.nodes.WeaponBarLabel.Text):find(NAME.item136, 1, true))
        -- 手持优先于已选
        ctx.states:Fire({ slots = {}, bait = {}, weapons = { item134 = 1, item136 = 2 }, selectedWeapon = 'item136',
            held = { kind = 'weapon', id = 'item134' } })
        assert.truthy(plain(ctx.nodes.WeaponBarLabel.Text):find(NAME.item134, 1, true))
        -- 已选武器库存归零：不再显示
        ctx.states:Fire({ slots = {}, bait = {}, weapons = { item136 = 0 }, selectedWeapon = 'item136' })
        assert.same('', plain(ctx.nodes.WeaponBarLabel.Text))
    end)

    it('test_weapon_popup_lists_all_weapons_greys_empty_and_selects', function()
        ctx = setUp(1080)
        ctx.states:Fire({ slots = {}, bait = {}, weapons = { item136 = 0, item134 = 2, item137 = 1 } })
        assert.is_true(ctx.nodes.WeaponBar.TouchEnabled)
        ctx.nodes.WeaponBar.OnClicked:Fire()
        -- 全部持有的武器按 id 排列在 PopupCells 给的格位上，库存为 0 的置灰仍显示
        local cells = MainHudLayout.PopupCells(layoutFor(1080, 8), 'Weapon', 3)
        for i, id in ipairs({ 'item134', 'item136', 'item137' }) do
            local cell, label = ctx.nodes['WeaponPopupCell_' .. id], ctx.nodes['WeaponPopupLabel_' .. id]
            assert.is_true(cell.Visible, id)
            assert.is_true(label.Visible, id)
            assertAt(cell, cells[i], id)
            assertAt(label, cells[i], id)
            assert.truthy(plain(label.Text):find(NAME[id], 1, true), id)
        end
        assert.truthy(plain(ctx.nodes.WeaponPopupLabel_item134.Text):find('×2', 1, true))
        assert.is_false(ctx.nodes.WeaponPopupCell_item136.TouchEnabled)
        assert.is_true(ctx.nodes.WeaponPopupCell_item134.TouchEnabled)
        assert.is_not.same(ctx.nodes.WeaponPopupCell_item134.ButtonNormalColor,
            ctx.nodes.WeaponPopupCell_item136.ButtonNormalColor)
        assert.is_true(ctx.nodes.WeaponPopup.Visible)
        -- 选中：沿用切换手持操作（按武器 id 发起攻击类 Operate，带单调 seq），然后关闭弹窗
        ctx.nodes.WeaponPopupCell_item137.OnClicked:Fire()
        assert.same({ action = 'Operate', op = 'attack', weapon = 'item137', seq = 1 }, ctx.commands[#ctx.commands])
        assert.is_false(ctx.nodes.WeaponPopup.Visible)
        for _, id in ipairs({ 'item134', 'item136', 'item137' }) do
            assert.is_false(ctx.nodes['WeaponPopupCell_' .. id].Visible, id)
            assert.is_false(ctx.nodes['WeaponPopupLabel_' .. id].Visible, id)
        end
    end)

    it('test_bait_bar_shows_selected_bait_or_no_bait', function()
        ctx = setUp(1080)
        ctx.states:Fire({ slots = {}, bait = { worm = 3 } })
        assert.same('不挂鱼饵', plain(ctx.nodes.BaitBarLabel.Text))
        ctx.states:Fire({ slots = {}, bait = { worm = 3 }, selectedBait = 'worm' })
        assert.same(NAME.worm .. '×3', plain(ctx.nodes.BaitBarLabel.Text))
        ctx.states:Fire({ slots = {}, bait = { worm = 3, rareShrimp = 2 }, selectedBait = 'rareShrimp' })
        assert.same(NAME.rareShrimp .. '×2', plain(ctx.nodes.BaitBarLabel.Text))
    end)

    it('test_bait_popup_candidates_order_greying_and_commands', function()
        ctx = setUp(1080)
        local state = { slots = {}, bait = { worm = 4, sausage = 0, rareShrimp = 2, crayfish = 0 },
            selectedBait = 'worm' }
        ctx.states:Fire(state)
        ctx.nodes.BaitBar.OnClicked:Fire()
        -- 顺序：蚯蚓、香肠、鸭子、动态鱼饵（库存 > 0）、不挂鱼饵、吃蚯蚓
        local keys = { 'worm', 'sausage', 'duck', 'rareShrimp', 'NoBait', 'EatWorm' }
        local cells = MainHudLayout.PopupCells(layoutFor(1080, 8), 'Bait', #keys)
        for i, key in ipairs(keys) do
            assert.is_true(ctx.nodes['BaitPopupCell_' .. key].Visible, key)
            assertAt(ctx.nodes['BaitPopupCell_' .. key], cells[i], key)
            assertAt(ctx.nodes['BaitPopupLabel_' .. key], cells[i], key)
        end
        assert.is_nil(ctx.nodes.BaitPopupCell_crayfish) -- 库存为 0 的动态鱼饵不列
        assert.same(NAME.worm .. '×4', plain(ctx.nodes.BaitPopupLabel_worm.Text))
        assert.same(NAME.duck .. '×0', plain(ctx.nodes.BaitPopupLabel_duck.Text))
        assert.same('不挂鱼饵', plain(ctx.nodes.BaitPopupLabel_NoBait.Text))
        assert.same('吃蚯蚓', plain(ctx.nodes.BaitPopupLabel_EatWorm.Text))
        assert.is_false(ctx.nodes.BaitPopupCell_sausage.TouchEnabled)
        assert.is_false(ctx.nodes.BaitPopupCell_duck.TouchEnabled)
        assert.is_true(ctx.nodes.BaitPopupCell_worm.TouchEnabled)
        assert.is_true(ctx.nodes.BaitPopupCell_EatWorm.TouchEnabled)
        assert.is_not.same(ctx.nodes.BaitPopupCell_worm.ButtonNormalColor,
            ctx.nodes.BaitPopupCell_rareShrimp.ButtonNormalColor) -- 选中的饵高亮
        ctx.nodes.BaitBar.OnClicked:Fire() -- 再点栏位收起
        assert.is_false(ctx.nodes.BaitPopup.Visible)
        assert.is_false(ctx.nodes.BaitPopupCell_worm.Visible)
        assert.same(0, #ctx.commands)
        -- 每个候选发出与原平铺按钮相同的命令，选中后弹窗关闭
        local expected = {
            worm = { action = 'SelectBait', value = 'worm' },
            rareShrimp = { action = 'SelectBait', value = 'rareShrimp' },
            NoBait = { action = 'SelectBait' },
            EatWorm = { action = 'EatBait', value = 'worm' },
        }
        for _, key in ipairs({ 'worm', 'rareShrimp', 'NoBait', 'EatWorm' }) do
            ctx.nodes.BaitBar.OnClicked:Fire()
            assert.is_true(ctx.nodes['BaitPopupCell_' .. key].Visible, key)
            local before = #ctx.commands
            ctx.nodes['BaitPopupCell_' .. key].OnClicked:Fire()
            assert.same(before + 1, #ctx.commands, key)
            assert.same(expected[key], ctx.commands[#ctx.commands], key)
            assert.is_false(ctx.nodes.BaitPopup.Visible, key)
            assert.is_false(ctx.nodes['BaitPopupCell_' .. key].Visible, key)
        end
        -- 香肠、鸭子有货时同样发选饵
        ctx.states:Fire({ slots = {}, bait = { worm = 4, sausage = 1, duck = 1 } })
        for _, key in ipairs({ 'sausage', 'duck' }) do
            ctx.nodes.BaitBar.OnClicked:Fire()
            ctx.nodes['BaitPopupCell_' .. key].OnClicked:Fire()
            assert.same({ action = 'SelectBait', value = key }, ctx.commands[#ctx.commands], key)
        end
    end)

    it('test_only_one_popup_open_and_blank_click_closes', function()
        ctx = setUp(1080)
        ctx.states:Fire({ slots = {}, bait = { worm = 1 }, weapons = { item134 = 1 } })
        assert.is_false(ctx.nodes.PopupDismiss.Visible)
        ctx.nodes.WeaponBar.OnClicked:Fire()
        assert.is_true(ctx.nodes.WeaponPopup.Visible)
        assert.is_true(ctx.nodes.PopupDismiss.Visible)
        assert.is_true(ctx.nodes.PopupDismiss.TouchEnabled)
        -- 打开另一个时前一个自动关闭
        ctx.nodes.BaitBar.OnClicked:Fire()
        assert.is_true(ctx.nodes.BaitPopup.Visible)
        assert.is_true(ctx.nodes.BaitPopupCell_worm.Visible)
        assert.is_false(ctx.nodes.WeaponPopup.Visible)
        assert.is_false(ctx.nodes.WeaponPopupCell_item134.Visible)
        -- 空白关闭层铺满屏幕、盖在常驻控件之上，栏位与候选格在它之上
        local dismiss = ctx.nodes.PopupDismiss
        assert.same({ x = 960, y = 540 }, { x = dismiss.Position.x, y = dismiss.Position.y })
        assert.same({ x = 1920, y = 1080 }, { x = dismiss.Size.x, y = dismiss.Size.y })
        assert.is_true(ctx.nodes.BaitPopupCell_worm.LocalZOrder > dismiss.LocalZOrder)
        assert.is_true(ctx.nodes.BaitBar.LocalZOrder > dismiss.LocalZOrder)
        assert.is_true(ctx.nodes.WeaponBar.LocalZOrder > dismiss.LocalZOrder)
        assert.is_true(dismiss.LocalZOrder > (ctx.nodes.ItemAction2.LocalZOrder or 0))
        -- 点弹窗外空白处：关闭、不发命令
        dismiss.OnClicked:Fire()
        assert.is_false(ctx.nodes.BaitPopup.Visible)
        assert.is_false(ctx.nodes.BaitPopupCell_worm.Visible)
        assert.is_false(dismiss.Visible)
        assert.is_false(dismiss.TouchEnabled)
        assert.same(0, #ctx.commands)
    end)

    it('test_open_popup_follows_snapshot_refresh', function()
        ctx = setUp(1080)
        ctx.states:Fire({ slots = {}, bait = { worm = 2, baitTestA = 1, baitTestB = 3 } })
        ctx.nodes.BaitBar.OnClicked:Fire()
        local five = MainHudLayout.PopupCells(layoutFor(1080, 8), 'Bait', 7)
        assertAt(ctx.nodes.BaitPopupCell_baitTestB, five[5], 'B @5')
        -- 动态鱼饵 A 用完：从候选行消失，后面的格子补位，不留空格也不叠放
        ctx.states:Fire({ slots = {}, bait = { worm = 1, baitTestB = 3 } })
        assert.is_true(ctx.nodes.BaitPopup.Visible)
        assert.is_false(ctx.nodes.BaitPopupCell_baitTestA.Visible)
        assert.is_false(ctx.nodes.BaitPopupLabel_baitTestA.Visible)
        local six = MainHudLayout.PopupCells(layoutFor(1080, 8), 'Bait', 6)
        assertAt(ctx.nodes.BaitPopupCell_baitTestB, six[4], 'B @4')
        assertAt(ctx.nodes.BaitPopupCell_NoBait, six[5], 'NoBait @5')
        assert.same(NAME.worm .. '×1', plain(ctx.nodes.BaitPopupLabel_worm.Text))
        -- 武器库存归零：仍在候选行里，改为置灰
        ctx.handler:ClosePopup()
        ctx.states:Fire({ slots = {}, bait = {}, weapons = { item134 = 1 } })
        ctx.nodes.WeaponBar.OnClicked:Fire()
        assert.is_true(ctx.nodes.WeaponPopupCell_item134.TouchEnabled)
        ctx.states:Fire({ slots = {}, bait = {}, weapons = { item134 = 0 } })
        assert.is_true(ctx.nodes.WeaponPopupCell_item134.Visible)
        assert.is_false(ctx.nodes.WeaponPopupCell_item134.TouchEnabled)
    end)

    for _, height in ipairs({ 886, 1440 }) do
        it('test_many_candidates_stay_on_screen_' .. height, function()
            ctx = setUp(height)
            local weapons = {}
            for id, definition in pairs(GameCfg.Items.Definitions) do
                if type(definition.Type) == 'string' and definition.Type:find('武器', 1, true) then weapons[id] = 1 end
            end
            ctx.states:Fire({ slots = {}, slotCount = 2, bait = {}, weapons = weapons })
            ctx.nodes.WeaponBar.OnClicked:Fire()
            local shown = 0
            for id in pairs(weapons) do
                local cell = ctx.nodes['WeaponPopupCell_' .. id]
                assert.is_true(cell.Visible, id)
                shown = shown + 1
                assert.is_true(cell.Position.x - cell.Size.x / 2 >= 0 and cell.Position.x + cell.Size.x / 2 <= 1920, id)
                assert.is_true(cell.Position.y - cell.Size.y / 2 >= 0 and cell.Position.y + cell.Size.y / 2 <= height, id)
            end
            assert.is_true(shown >= 20)
            local plate = ctx.nodes.WeaponPopup
            assert.is_true(plate.Position.x - plate.Size.x / 2 >= 0 and plate.Position.x + plate.Size.x / 2 <= 1920)
            assert.is_true(plate.Position.y + plate.Size.y / 2 <= height)
        end)
    end

    it('test_backpack_open_folds_bars_and_popup', function()
        ctx = setUp(1080)
        local state = { slots = {}, slotCount = 2, bait = { worm = 2 }, weapons = { item134 = 1 }, backpackCount = 5 }
        ctx.states:Fire(state)
        ctx.nodes.BaitBar.OnClicked:Fire()
        assert.is_true(ctx.nodes.BaitPopup.Visible)
        ctx.nodes.BtnBackpack.OnClicked:Fire()
        for _, name in ipairs({ 'WeaponBar', 'WeaponBarLabel', 'BaitBar', 'BaitBarLabel', 'BaitPopup',
            'BaitPopupCell_worm', 'BaitPopupLabel_worm', 'PopupDismiss' }) do
            assert.is_false(ctx.nodes[name].Visible, name)
        end
        assert.is_false(ctx.nodes.WeaponBar.TouchEnabled)
        assert.is_false(ctx.nodes.BaitBar.TouchEnabled)
        -- 背包开着时点栏位不弹出
        ctx.nodes.WeaponBar.OnClicked:Fire()
        assert.is_false(ctx.nodes.WeaponPopup.Visible)
        ctx.states:Fire(state)
        assert.is_false(ctx.nodes.BaitBar.Visible)
        -- 关背包：栏位恢复，弹窗不复活
        ctx.nodes.BtnBackpack.OnClicked:Fire()
        assert.is_true(ctx.nodes.WeaponBar.Visible)
        assert.is_true(ctx.nodes.BaitBar.TouchEnabled)
        assert.is_true(ctx.nodes.BaitBarLabel.Visible)
        assert.is_false(ctx.nodes.BaitPopup.Visible)
        assert.is_false(ctx.nodes.BaitPopupCell_worm.Visible)
    end)

    it('test_close_screen_and_reentry_clear_popup', function()
        ctx = setUp(1080)
        ctx.states:Fire({ slots = {}, bait = { worm = 2 }, weapons = { item134 = 1 } })
        ctx.nodes.WeaponBar.OnClicked:Fire()
        ctx.handler:CloseScreen()
        assert.is_false(ctx.nodes.WeaponPopup.Visible)
        assert.is_false(ctx.nodes.WeaponPopupCell_item134.Visible)
        assert.is_false(ctx.nodes.PopupDismiss.Visible)
        ctx.handler:OpenScreen()
        ctx.nodes.WeaponBar.OnClicked:Fire()
        local old = { cell = ctx.nodes.WeaponPopupCell_item134, label = ctx.nodes.WeaponPopupLabel_item134,
            plate = ctx.nodes.WeaponPopup, dismiss = ctx.nodes.PopupDismiss, bar = ctx.nodes.WeaponBar }
        -- 换根节点重进：旧节点全部销毁、旧监听断开，新界面没有开着的弹窗
        ctx.handler.RootNode = { Name = 'ScreenMain', FindFirstChild = function() return nil end }
        ctx.handler:Init()
        ctx.handler.IsOpen = true
        for name, node in pairs(old) do
            assert.is_true(node.Destroyed, name)
            assert.same(0, node.OnClicked and node.OnClicked:Count() or 0, name)
        end
        assert.is_not.equal(old.bar, ctx.nodes.WeaponBar)
        old.cell.OnClicked:Fire()
        assert.same(0, #ctx.commands)
        ctx.states:Fire({ slots = {}, bait = { worm = 2 }, weapons = { item134 = 1 } })
        assert.is_false(ctx.nodes.PopupDismiss.Visible)
        assert.is_false(ctx.nodes.WeaponPopup.Visible)
    end)

    it('test_tiled_rows_gone_and_eat_button_only_for_selected_food', function()
        ctx = setUp(1080)
        ctx.states:Fire({ slots = {}, bait = { worm = 3, rareShrimp = 2, duck = 1, sausage = 1 },
            weapons = { item134 = 1 } })
        for name in pairs(ctx.nodes) do
            assert.is_nil(name:match('^BaitDyn') or name:match('^WeaponItem'), name)
        end
        for _, name in ipairs({ 'BaitWorm', 'BaitNone', 'BaitDuck', 'BaitSausage', 'BtnBaitLabel',
            'BtnNoneLabel', 'BtnDuckLabel', 'BtnSausageLabel' }) do
            assert.is_nil(ctx.nodes[name], name)
        end
        -- 没有选中食物：「吃」按钮不出现（吃蚯蚓入口已移进鱼饵栏弹窗）
        assert.is_false(ctx.nodes.BaitEat.Visible)
        assert.is_false(ctx.nodes.BaitEat.TouchEnabled)
        assert.is_false(ctx.nodes.BtnEatLabel.Visible)
        ctx.nodes.BaitEat.OnClicked:Fire()
        assert.same(0, #ctx.commands)
        -- 选中格是食物：两步进食路径照旧
        ctx.states:Fire({ slots = { [1] = { itemId = 'carp', count = 1 } }, bait = { worm = 3 }, selectedSlot = 1 })
        assert.is_true(ctx.nodes.BaitEat.Visible)
        assert.is_true(ctx.nodes.BaitEat.TouchEnabled)
        assert.is_true(ctx.nodes.BtnEatLabel.Visible)
        assert.same('手持' .. NAME.carp, ctx.nodes.BtnEatLabel.Text)
        -- 背包打开时一并收起，关闭后按快照恢复
        ctx.nodes.BtnBackpack.OnClicked:Fire()
        assert.is_false(ctx.nodes.BaitEat.Visible)
        ctx.nodes.BtnBackpack.OnClicked:Fire()
        assert.is_true(ctx.nodes.BaitEat.Visible)
        ctx.states:Fire({ slots = { [1] = { itemId = 'starterRod', count = 1 } }, bait = { worm = 3 }, selectedSlot = 1 })
        assert.is_false(ctx.nodes.BaitEat.Visible)
        ctx.nodes.BtnBackpack.OnClicked:Fire()
        ctx.nodes.BtnBackpack.OnClicked:Fire()
        assert.is_false(ctx.nodes.BaitEat.Visible)
    end)

    it('test_worm_depleted_shows_transient_hint_then_fades', function()
        ctx = setUp(1080)
        local hint = ctx.nodes.CastFailureHint
        -- 开局快照本来就是 0：不报
        ctx.states:Fire({ slots = {}, bait = { worm = 0 } })
        assert.is_false(hint.Visible)
        ctx.states:Fire({ slots = {}, bait = { worm = 1 } })
        assert.is_false(hint.Visible)
        -- 吃掉 / 用掉最后一只：上方提示区出现临时提示
        ctx.states:Fire({ slots = {}, bait = { worm = 0 } })
        assert.is_true(hint.Visible)
        assert.same('蚯蚓用尽', hint.Text)
        assertAt(hint, layoutFor(1080, 8).Rects.HintTransient, 'CastFailureHint')
        -- 仍是 0 的后续快照不重复刷新提示时长
        ctx.now = ctx.now + GameCfg.CastFeedback.SplashDurationSec - 0.5
        ctx.states:Fire({ slots = {}, bait = { worm = 0 } })
        ctx.now = ctx.now + 1
        ctx.handler:UpdateCastFeedback()
        assert.is_false(hint.Visible)
    end)

    for _, order in ipairs({ 'bait-first', 'cast-first' }) do
        it('test_worm_depleted_by_cast_keeps_waiting_feedback_' .. order, function()
            ctx = setUp(1080)
            local cast = ctx.events.CastState.OnClientEvent
            ctx.states:Fire({ slots = {}, bait = { worm = 1 }, selectedBait = 'worm' })
            -- 抛竿扣掉最后一只蚯蚓：库存快照与「已入水」两条消息先后到达，顺序不定
            local function depleted() ctx.states:Fire({ slots = {}, bait = { worm = 0 }, selectedBait = 'worm' }) end
            local function waiting()
                cast:Fire({ phase = 'cast', zoneId = 'pond', castId = 1, landing = { x = 1, y = 0, z = 2 } })
            end
            if order == 'bait-first' then depleted() waiting() else waiting() depleted() end
            assert.is_true(ctx.nodes.CastFailureHint.Visible)
            assert.same('蚯蚓用尽', ctx.nodes.CastFailureHint.Text)
            assert.is_true(ctx.nodes.CastWaitHint.Visible)
            assert.is_true(ctx.nodes.CastSplashHint.Visible)
            assert.is_false(ctx.nodes.CastFailureMark.Visible)
            -- 真正的抛竿失败照旧接管临时提示
            ctx.handler:ShowCastFailure({ reason = 'noFish' })
            assert.same('本次没有鱼上钩，请重新抛竿', ctx.nodes.CastFailureHint.Text)
        end)
    end

    it('test_eat_worm_greyed_when_no_worm', function()
        ctx = setUp(1080)
        ctx.states:Fire({ slots = {}, bait = { worm = 0 } })
        ctx.nodes.BaitBar.OnClicked:Fire()
        assert.is_true(ctx.nodes.BaitPopupCell_EatWorm.Visible)
        assert.is_false(ctx.nodes.BaitPopupCell_EatWorm.TouchEnabled)
        assert.is_false(ctx.nodes.BaitPopupCell_worm.TouchEnabled)
        assert.is_true(ctx.nodes.BaitPopupCell_NoBait.TouchEnabled)
        -- 置灰的候选即使收到点击也不发命令、不关弹窗
        ctx.nodes.BaitPopupCell_EatWorm.OnClicked:Fire()
        assert.same(0, #ctx.commands)
        assert.is_true(ctx.nodes.BaitPopup.Visible)
    end)
end)
