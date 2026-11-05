-- #86 迁移（原 tests/gameplay/item_bar_ui_test.lua）：道具栏界面的节点生成、状态刷新与重进清理。
-- 接缝：ScreenMain 处理器 + ItemBarState 客户端事件。
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

describe("道具栏的界面侧", function()
    local ctx

    -- 与旧 LuaUnit 的每例 setUp/tearDown 同级成对：整屏假环境逐例重建，
    -- ScreenMain 逐例重载以清掉模块级状态。
    before_each(function()
        ctx = { nodes = {}, created = {}, commands = {}, events = {} }
        ctx.previous = { game = _G.game, Vector2 = _G.Vector2, Color = _G.Color,
            REUtil = _G.REUtil, GameUI = _G.GameUI, MgrGameUI = _G.MgrGameUI }
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
        _G.game = { GetService = function(_, name) if name == 'World' then return world end end }
        _G.Vector2 = { New = function(x, y) return { x = x, y = y } end }
        _G.Color = { New = function(...) return { ... } end }
        _G.GameUI = { GetEuiManager = function() return {
            GetDeviceResolution = function() return { x = 1920, y = 1080 } end,
        } end, GetUIRoot = function() return ctx.uiRoot end }
        _G.REUtil = { GetRE = function(_, name)
            if not ctx.events[name] then
                ctx.events[name] = { OnClientEvent = signal(), FireServer = function(_, payload)
                    if name == 'ItemBarAction' then ctx.commands[#ctx.commands + 1] = payload end
                end }
            end
            return ctx.events[name]
        end }
        ctx.states = _G.REUtil:GetRE('ItemBarState').OnClientEvent
        ctx.handler = assert(loadfile('client/ScreenHandlers/ScreenMain.lua'))()
        ctx.handler.RootNode = {
            Name = 'ScreenMain',
            FindFirstChild = function(_, name) return ctx.nodes[name] end,
        }
        ctx.currentRoot = ctx.handler.RootNode
        ctx.uiRoot = { FindFirstChild = function(_, name)
            if name == 'ScreenMain' then return ctx.currentRoot end
        end }
        ctx.handler:Init()
    end)

    -- 攻击按钮逐例销毁，全局与模块缓存恢复；setUp 中途失败也照样清理。
    after_each(function()
        require('client.LocalAttackButton'):Destroy()
        package.loaded['client.LocalAttackButton'] = ctx.previousAttack
        for _, key in ipairs({ 'game', 'Vector2', 'Color', 'REUtil', 'GameUI', 'MgrGameUI' }) do
            _G[key] = ctx.previous[key]
        end
    end)

    it("test_backpack_transfer_controls_and_slot_visibility", function()
        ctx.states:Fire({ slots = { [1] = { itemId = 'starterRod', count = 1 } }, slotCount = 2,
            backpack = { [1] = { itemId = 'bass', count = 1 } }, backpackCount = 5, bait = {} })
        assert.is_true(ctx.nodes.ItemBarSlot2.Visible)
        assert.is_false(ctx.nodes.ItemBarSlot3.Visible)
        ctx.nodes.BtnBackpack.OnClicked:Fire()
        assert.is_true(ctx.nodes.BackpackSlot1.Visible)
        assert.is_false(ctx.nodes.BackpackSlot6.Visible)
        ctx.nodes.BackpackSlot1.OnClicked:Fire()
        assert.is_true(ctx.nodes.BtnMoveToItemBar.TouchEnabled)
        ctx.nodes.BtnMoveToItemBar.OnClicked:Fire()
        assert.same({ action = 'MoveToItemBar', value = 1 }, ctx.commands[#ctx.commands])
        ctx.states:Fire({ slots = { [1] = { itemId = 'starterRod', count = 1 },
            [2] = { itemId = 'carp', count = 1 } }, slotCount = 2,
            backpack = { [1] = { itemId = 'bass', count = 1 } }, backpackCount = 5, bait = {} })
        assert.is_false(ctx.nodes.BtnMoveToItemBar.TouchEnabled)
    end)

    it("test_empty_and_depleted_state_refresh", function()
        ctx.states:Fire({ slots = {}, bait = { worm = 0 } })
        assert.is_false(ctx.nodes.ItemBarIcon1.Visible)
        assert.is_false(ctx.nodes.ItemBarLabel1.Visible)
        assert.is_false(ctx.nodes.ItemBarAmount1.Visible)
        assert.is_false(ctx.nodes.ItemAction2.Visible)
        assert.is_false(ctx.nodes.BtnItemActionLabel.Visible)
        assert.is_false(ctx.nodes.ItemDiscard.Visible)
        assert.is_false(ctx.nodes.BtnDiscardLabel.Visible)
        assert.is_false(ctx.nodes.BaitWorm.TouchEnabled)
        assert.is_false(ctx.nodes.BaitEat.TouchEnabled)
        assert.same('蚯蚓 ×0', ctx.nodes.BtnBaitLabel.Text)
        assert.same('蚯蚓用尽', ctx.nodes.BtnEatLabel.Text)
        assert.same('不挂鱼饵', ctx.nodes.BtnNoneLabel.Text)
        ctx.nodes.BaitNone.OnClicked:Fire()
        assert.same('SelectBait', ctx.commands[1].action)
        assert.is_nil(ctx.commands[1].value)
        ctx.nodes.ItemBarSlot8.OnClicked:Fire()
        assert.same(8, ctx.commands[2].value)
    end)

    it("test_fixed_slots_bait_and_action_placement", function()
        for index = 1, 8 do assert.is_not_nil(ctx.nodes['ItemBarSlot' .. index]) end
        assert.is_nil(ctx.nodes.ItemBarSlot9)
        local slot = ctx.nodes.ItemBarSlot1
        for _, name in ipairs({ 'ItemBarIcon1', 'ItemBarLabel1', 'ItemBarAmount1' }) do
            assert.equal(ctx.handler.RootNode, ctx.nodes[name].Parent)
            assert.is_false(ctx.nodes[name].TouchEnabled)
            assert.is_false(ctx.nodes[name].SwallowTouchEnabled)
            assert.same(1, ctx.nodes[name].LocalZOrder)
        end
        assert.same({ x = slot.Position.x, y = slot.Position.y + 15 }, ctx.nodes.ItemBarIcon1.Position)
        assert.same({ x = slot.Position.x, y = slot.Position.y - 35 }, ctx.nodes.ItemBarLabel1.Position)
        assert.same({ x = slot.Position.x + 37, y = slot.Position.y + 37 }, ctx.nodes.ItemBarAmount1.Position)
        assert.same('official://image/11017', ctx.nodes.ItemBarSlot1.NormalImage)
        assert.same('official://image/11017', ctx.nodes.BaitWorm.NormalImage)
        for labelName, buttonName in pairs({ BtnBaitLabel = 'BaitWorm', BtnNoneLabel = 'BaitNone',
            BtnEatLabel = 'BaitEat', BtnDiscardLabel = 'ItemDiscard', BtnItemActionLabel = 'ItemAction2' }) do
            local label, button = ctx.nodes[labelName], ctx.nodes[buttonName]
            assert.equal(ctx.handler.RootNode, label.Parent)
            assert.same(button.Position, label.Position)
            assert.same(button.Size, label.Size)
            assert.is_false(label.TouchEnabled)
            assert.is_false(label.SwallowTouchEnabled)
            assert.same(1, label.LocalZOrder)
            assert.same('', button.ButtonText)
        end
        assert.is_true(ctx.nodes.BtnBaitLabel.FontSize >= 28)
        assert.is_not_nil(ctx.nodes.BaitWorm)
        assert.is_not_nil(ctx.nodes.BaitNone)
        assert.is_not_nil(ctx.nodes.ItemDiscard)
        assert.is_false(ctx.nodes.ItemAction2.TouchEnabled)
        assert.equal(ctx.handler.RootNode, ctx.nodes.AttackControl.Parent)
        assert.equal(ctx.nodes.AttackControl, ctx.nodes.BtnAttack.Parent)
        assert.is_false(ctx.nodes.BtnAttack.TouchEnabled)
        ctx.states:Fire({ slots = { [1] = { itemId = 'starterRod', count = 1 } },
            bait = { worm = 10 }, selectedSlot = 1 })
        assert.is_true(ctx.nodes.ItemBarIcon1.Visible)
        assert.is_true(ctx.nodes.ItemBarLabel1.Visible)
        assert.is_true(ctx.nodes.ItemBarAmount1.Visible)
        assert.is_not_nil(ctx.nodes.ItemBarIcon1.Image)
        assert.is_not.equal('', ctx.nodes.ItemBarLabel1.Text)
        assert.same('1', ctx.nodes.ItemBarAmount1.Text)
        assert.same('蚯蚓 ×10', ctx.nodes.BtnBaitLabel.Text)
        assert.same('吃蚯蚓', ctx.nodes.BtnEatLabel.Text)
        assert.same('丢弃选中物', ctx.nodes.BtnDiscardLabel.Text)
        assert.is_true(ctx.nodes.BtnDiscardLabel.Visible)
        assert.same('抛竿', ctx.nodes.BtnItemActionLabel.Text)
        assert.is_true(ctx.nodes.ItemAction2.Visible)
        assert.is_true(ctx.nodes.BtnItemActionLabel.Visible)
        ctx.states:Fire({ slots = {}, bait = { worm = 10 }, selectedBait = 'worm' })
        assert.same('不挂鱼饵', ctx.nodes.BtnNoneLabel.Text)
        ctx.nodes.ItemBarSlot1.OnClicked:Fire()
        assert.same('SelectSlot', ctx.commands[1].action)
        assert.same(1, ctx.commands[1].value)
        ctx.nodes.BaitWorm.OnClicked:Fire()
        assert.same('worm', ctx.commands[2].value)
        ctx.nodes.BaitNone.OnClicked:Fire()
        assert.same('SelectBait', ctx.commands[3].action)
        assert.is_nil(ctx.commands[3].value)
    end)

    it("test_reentry_cleans_old_root_and_listeners", function()
        local originals = {
            ['common.Util'] = package.loaded['common.Util'],
            ['common.REUtil'] = package.loaded['common.REUtil'],
            ['client.GameUI'] = package.loaded['client.GameUI'],
            ['client.ScreenHandlers.ScreenMain'] = package.loaded['client.ScreenHandlers.ScreenMain'],
        }
        package.loaded['common.Util'] = {}
        package.loaded['common.REUtil'] = _G.REUtil
        package.loaded['client.GameUI'] = _G.GameUI
        package.loaded['client.ScreenHandlers.ScreenMain'] = ctx.handler
        -- pcall 包住主体：模块缓存改写后即使断言失败也要恢复，再抛错让本例失败。
        local ok, err = pcall(function()
            local mgr = assert(loadfile('client/MgrGameUI.lua'))()
            local oldRoot, oldButton = ctx.currentRoot, ctx.nodes.ItemBarSlot1
            local oldIcon, oldLabel = ctx.nodes.ItemBarIcon1, ctx.nodes.BtnBaitLabel
            assert.equal(oldRoot, mgr:GetScreen('ScreenMain').RootNode)
            assert.equal(oldRoot, mgr:GetScreen('ScreenMain').RootNode)
            assert.same(1, ctx.states:Count())
            assert.same(1, oldButton.OnClicked:Count())
            ctx.currentRoot = { Name = 'ScreenMain', Visible = true,
                FindFirstChild = function() return nil end }
            mgr:GetScreen('ScreenMain')
            assert.is_true(oldButton.Destroyed)
            assert.is_true(oldIcon.Destroyed)
            assert.is_true(oldLabel.Destroyed)
            assert.same(0, oldButton.OnClicked:Count())
            assert.same(1, ctx.states:Count())
            local newButton = ctx.nodes.ItemBarSlot1
            assert.is_not.equal(newButton, oldButton)
            oldButton.OnClicked:Fire()
            assert.same(0, #ctx.commands)
            newButton.OnClicked:Fire()
            assert.same(1, #ctx.commands)
            local newIcon, newLabel = ctx.nodes.ItemBarIcon1, ctx.nodes.BtnBaitLabel
            ctx.handler:Cleanup()
            assert.same(0, ctx.states:Count())
            assert.is_true(newButton.Destroyed)
            assert.is_true(newIcon.Destroyed)
            assert.is_true(newLabel.Destroyed)
            ctx.handler:Destroy()
        end)
        for _, key in ipairs({ 'common.Util', 'common.REUtil', 'client.GameUI',
            'client.ScreenHandlers.ScreenMain' }) do
            package.loaded[key] = originals[key]
        end
        assert.is_true(ok, tostring(err))
    end)

    it("test_screen_main_is_opened_on_start", function()
        local clientFile = assert(io.open('client/main.lua', 'r'))
        local client = clientFile:read('*a')
        clientFile:close()
        assert.matches("OpenScreen('ScreenMain')", client, nil, true)
    end)

    -- #174 #8：动态行集合变化后每次 Show 都按当前排序重排，可见按钮 x 两两不同且连续
    it("test_dynamic_rows_reflow_after_membership_change", function()
        -- 用配置里不存在的 bait 键（走 definition 兜底的 id 显示），保证 id 排序可预期
        local baitA, baitB, baitC, baitD = 'baitTestA', 'baitTestB', 'baitTestC', 'baitTestD'
        ctx.states:Fire({ slots = {}, bait = { [baitB] = 2, [baitD] = 1 } })
        assert.same(120, ctx.nodes['BaitDyn_' .. baitB].Position.x)
        assert.same(300, ctx.nodes['BaitDyn_' .. baitD].Position.x)
        assert.same(120, ctx.nodes['BaitDynLabel_' .. baitB].Position.x)
        assert.same(300, ctx.nodes['BaitDynLabel_' .. baitD].Position.x)
        -- 集合先 A、B、C 再 B、D：隐藏按钮不占位，可见按钮连续排布
        ctx.states:Fire({ slots = {}, bait = { [baitA] = 1, [baitB] = 2, [baitC] = 3 } })
        assert.same(120, ctx.nodes['BaitDyn_' .. baitA].Position.x)
        assert.same(300, ctx.nodes['BaitDyn_' .. baitB].Position.x)
        assert.same(480, ctx.nodes['BaitDyn_' .. baitC].Position.x)
        assert.is_false(ctx.nodes['BaitDyn_' .. baitD].Visible)
        ctx.states:Fire({ slots = {}, bait = { [baitB] = 5, [baitD] = 1 } })
        assert.is_false(ctx.nodes['BaitDyn_' .. baitA].Visible)
        assert.is_false(ctx.nodes['BaitDyn_' .. baitC].Visible)
        assert.same(120, ctx.nodes['BaitDyn_' .. baitB].Position.x)
        assert.same(300, ctx.nodes['BaitDyn_' .. baitD].Position.x)
        assert.same(120, ctx.nodes['BaitDynLabel_' .. baitB].Position.x)
        assert.same(300, ctx.nodes['BaitDynLabel_' .. baitD].Position.x)
        -- 武器行同理（按 id 字典序：axe < spear < sword）
        ctx.states:Fire({ slots = {}, bait = {}, weapons = { sword = 1, axe = 1, spear = 1 } })
        assert.same(120, ctx.nodes.WeaponItem_axe.Position.x)
        assert.same(300, ctx.nodes.WeaponItem_spear.Position.x)
        assert.same(480, ctx.nodes.WeaponItem_sword.Position.x)
        ctx.states:Fire({ slots = {}, bait = {}, weapons = { axe = 1, bow = 1 } })
        assert.is_false(ctx.nodes.WeaponItem_sword.Visible)
        assert.same(120, ctx.nodes.WeaponItem_axe.Position.x)
        assert.same(300, ctx.nodes.WeaponItem_bow.Position.x)
        assert.same(120, ctx.nodes.WeaponItemLabel_axe.Position.x)
    end)

    -- #174 #11：主界面原点左下、Y 向上——标题在上、正文居中、按钮在下
    it("test_dialogue_layout_y_up_title_above_body_above_buttons", function()
        local title, body = ctx.nodes.DialogueTitle, ctx.nodes.DialogueBody
        assert.is_true(title.Position.y > body.Position.y)
        for _, name in ipairs({ 'DialogueNext', 'DialogueRead', 'DialogueNextLabel', 'DialogueReadLabel' }) do
            assert.is_true(body.Position.y > ctx.nodes[name].Position.y)
        end
        assert.same(ctx.nodes.DialogueNext.Position, ctx.nodes.DialogueNextLabel.Position)
        assert.same(ctx.nodes.DialogueRead.Position, ctx.nodes.DialogueReadLabel.Position)
    end)

    -- #174 #13：背包打开时被面板盖住的鱼饵键、武器条及文字标签一起隐藏，关闭后恢复
    it("test_backpack_open_hides_covered_buttons_and_labels", function()
        ctx.states:Fire({ slots = { [1] = { itemId = 'starterRod', count = 1 } }, slotCount = 2,
            bait = { worm = 3 }, weapons = { sword = 1 }, backpackCount = 4 })
        assert.is_true(ctx.nodes.BaitWorm.Visible)
        assert.is_true(ctx.nodes.BaitDuck.Visible)
        assert.is_true(ctx.nodes.WeaponItem_sword.Visible)
        ctx.nodes.BtnBackpack.OnClicked:Fire()
        for _, name in ipairs({ 'BaitWorm', 'BaitNone', 'BaitEat', 'BaitDuck', 'BaitSausage',
            'ItemDiscard', 'ItemAction2', 'ReelClose', 'WeaponItem_sword', 'WeaponItemLabel_sword' }) do
            assert.is_false(ctx.nodes[name].Visible, name)
        end
        for _, name in ipairs({ 'BtnBaitLabel', 'BtnNoneLabel', 'BtnEatLabel', 'BtnDuckLabel',
            'BtnSausageLabel', 'BtnItemActionLabel', 'BtnDiscardLabel', 'ItemBarLabel1' }) do
            assert.is_false(ctx.nodes[name].Visible, name)
        end
        assert.is_false(ctx.nodes.BaitWorm.TouchEnabled)
        assert.is_false(ctx.nodes.WeaponItem_sword.TouchEnabled)
        ctx.nodes.BtnBackpack.OnClicked:Fire()
        assert.is_true(ctx.nodes.BaitWorm.Visible)
        assert.is_true(ctx.nodes.BaitWorm.TouchEnabled)
        assert.is_true(ctx.nodes.BtnBaitLabel.Visible)
        assert.is_true(ctx.nodes.WeaponItem_sword.Visible)
        -- 快照已移除的动态项在关闭背包后不得复活
        ctx.states:Fire({ slots = {}, slotCount = 2, bait = { worm = 1 }, weapons = {}, backpackCount = 4 })
        assert.is_false(ctx.nodes.WeaponItem_sword.Visible)
        ctx.nodes.BtnBackpack.OnClicked:Fire()
        assert.is_false(ctx.nodes.WeaponItem_sword.Visible)
        assert.is_false(ctx.nodes.WeaponItem_sword.TouchEnabled)
        assert.is_false(ctx.nodes.WeaponItemLabel_sword.Visible)
    end)

    -- #174 #14：背包格底色与面板有区分；#1：任务条带深色半透明底板
    it("test_backpack_slot_color_differs_and_quest_has_backplate", function()
        assert.is_not.same(ctx.nodes.BackpackPanel.ButtonNormalColor,
            ctx.nodes.BackpackSlot1.ButtonNormalColor)
        local plate = ctx.nodes.QuestBackground
        assert.is_not_nil(plate)
        assert.is_false(plate.TouchEnabled)
        assert.is_false(plate.SwallowTouchEnabled)
        assert.same(plate.Position, ctx.nodes.QuestLabel.Position)
        assert.is_true(plate.Size.x >= ctx.nodes.QuestLabel.Size.x)
        assert.is_true(plate.Size.y >= ctx.nodes.QuestLabel.Size.y)
        local rgba = plate.Color
        assert.is_true(rgba[4] < 255 and rgba[4] > 0)
        assert.is_true(rgba[1] <= 60 and rgba[2] <= 60 and rgba[3] <= 60)
        ctx.states:Fire({ slots = {}, bait = {} })
        -- 底板随任务文字一起显隐
        assert.is_false(plate.Visible)
        ctx.events.QuestState.OnClientEvent:Fire({ text = '新手任务 1/5：去钓鱼' })
        assert.is_true(ctx.nodes.QuestLabel.Visible)
        assert.is_true(plate.Visible)
    end)

    -- #174 #18：overlay 生成的按钮文字水平、垂直居中
    it("test_button_labels_center_aligned", function()
        for _, name in ipairs({ 'BtnBaitLabel', 'BtnNoneLabel', 'BtnEatLabel', 'LabelBackpack',
            'DialogueNextLabel', 'DialogueReadLabel', 'WeaponItemLabel_sword', 'QuestLabel' }) do
            local label = ctx.nodes[name]
            if label then
                assert.same(1, label.TextHorizontalAlignment, name)
                assert.same(1, label.TextVerticalAlignment, name)
            end
        end
        assert.same(1, ctx.nodes.BtnBaitLabel.TextHorizontalAlignment)
    end)
end)
