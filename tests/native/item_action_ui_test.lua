-- #181 道具按钮合并（spec #178）：一颗道具按钮（ItemAction2 / BtnItemActionLabel）按 7 级优先级
-- 决定文字与行为：特殊道具（空闲）> 上钩点击收线 > 鱼线在外 > 手持鱼获放下 > 手持食物两步进食
-- > 手持鱼竿抛竿 > 其他（无效鱼竿提示）。
-- 接缝：ScreenMain 处理器 + ItemBarState / CastState / SpecialItemState 客户端事件 + 假 World 替身；
-- 只看节点的可见性、文字、可点性与发出的命令。
--
-- 动手前列出的失败方式：
--   1. 空闲手持食物时道具按钮隐藏或禁点；文字不随服务端手持确认从「手持××」变「吃××」；
--      点击发出的命令与原「吃」按钮不一致（Operate eat slot，带单调 seq）；
--   2. 独立「吃」按钮（BaitEat / BtnEatLabel）残留，或食物态背包打开时道具按钮不收起、关闭后不恢复；
--   3. 特殊道具生效且空闲时手持鱼竿 / 食物：按钮仍显示抛竿 / 吃，或点击发 Cast / eat 而不是吐息；
--   4. 上钩时手持食物 / 鱼竿：显示吃 / 抛竿，或点击发 eat / Cast 而不是本地收线点击；
--   5. 鱼线在外（cast / unhooked）时手持食物：显示吃××，点击发 eat 而不是 Reel；
--   6. 手持鱼获时选中食物、鱼竿或特殊道具生效：显示与点击不一致（显示「放下」却发 eat / Cast / 吐息，
--      或长按发飞行）；
--   7. 选中的既非鱼竿也非食物：按钮仍可见可点；强行点击不给「请重新选择鱼竿」提示；
--   8. 「结束收线」被并入道具按钮或不再出现；攻击键被改动。
local GameCfg = require('common.GameCfg')

local NAME = setmetatable({}, { __index = function(_, id) return GameCfg.Items.Definitions[id].Name end })

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
    }
end

local GLOBALS = { 'game', 'Vector2', 'Vector3', 'Color', 'REUtil', 'GameUI', 'MgrGameUI', 'LocalReelIn' }

local function setUp()
    local ctx = { nodes = {}, created = {}, commands = {}, sent = {}, events = {}, now = 100, clicks = 0 }
    ctx.previous = {}
    for _, key in ipairs(GLOBALS) do ctx.previous[key] = rawget(_G, key) end
    ctx.previousAttack = package.loaded['client.LocalAttackButton']
    package.loaded['client.LocalAttackButton'] = nil
    _G.MgrGameUI = { SetCustomControlUI = function() end }
    local world = { Created = ctx.created }
    function world:CreateUnit(kind, attrs)
        local node = { Kind = kind, OnClicked = signal(), OnTouchBegan = signal(), OnTouchEnded = signal() }
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
        GetDeviceResolution = function() return { x = 1920, y = 1080 } end,
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
    _G.LocalReelIn = {
        SetSession = function(self, session) self.SessionId = session end,
        Clear = function(self) self.SessionId = nil end,
        Suspend = function() end,
        Click = function() ctx.clicks = ctx.clicks + 1 end,
        Close = function() end,
    }
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

-- 道具栏快照：第 1 格放 itemId 并选中；held 为真时表示服务端已确认手持该格
local function selecting(itemId, held)
    return { slots = { [1] = { itemId = itemId, count = 1 } }, slotCount = 8, backpackCount = 5,
        bait = { worm = 3 }, selectedSlot = 1, held = held and { kind = 'slot', id = itemId, slot = 1 } or nil }
end

local function sentNames(ctx, from)
    local names = {}
    for i = (from or 0) + 1, #ctx.sent do names[#names + 1] = ctx.sent[i].name end
    return names
end

describe('道具按钮合并（#181）', function()
    local ctx
    after_each(function() if ctx then tearDown(ctx) end ctx = nil end)

    local function push(name, payload) ctx.events[name].OnClientEvent:Fire(payload) end
    local function label() return ctx.nodes.BtnItemActionLabel.Text end
    local function click() ctx.nodes.ItemAction2.OnClicked:Fire() end

    -- 失败方式 1：空闲手持食物 → 先「手持××」再「吃××」，命令与原「吃」按钮一致
    it('test_idle_food_two_step_eat_through_item_action', function()
        ctx = setUp()
        push('ItemBarState', selecting('carp'))
        assert.is_true(ctx.nodes.ItemAction2.Visible)
        assert.is_true(ctx.nodes.BtnItemActionLabel.Visible)
        assert.is_true(ctx.nodes.ItemAction2.TouchEnabled)
        assert.same('手持' .. NAME.carp, label())
        click()
        assert.same({ action = 'Operate', op = 'eat', slot = 1, seq = 1 }, ctx.commands[1])
        -- 服务端回快照：手持已切 → 按钮进入「吃××」确认态，再点才真吃
        push('ItemBarState', selecting('carp', true))
        assert.same('吃' .. NAME.carp, label())
        click()
        assert.same({ action = 'Operate', op = 'eat', slot = 1, seq = 2 }, ctx.commands[2])
        assert.same(2, #ctx.commands)
    end)

    -- 失败方式 2：独立「吃」按钮已删除；食物态的道具按钮随背包打开收起、关闭后按快照恢复
    it('test_standalone_eat_button_removed_and_backpack_hides_food_action', function()
        ctx = setUp()
        push('ItemBarState', selecting('carp'))
        assert.is_nil(ctx.nodes.BaitEat)
        assert.is_nil(ctx.nodes.BtnEatLabel)
        for name, node in pairs(ctx.nodes) do
            if name ~= 'BtnItemActionLabel' then
                assert.is_nil(tostring(node.Text or ''):find('手持' .. NAME.carp, 1, true), name)
            end
        end
        ctx.nodes.BtnBackpack.OnClicked:Fire()
        assert.is_false(ctx.nodes.ItemAction2.Visible)
        assert.is_false(ctx.nodes.ItemAction2.TouchEnabled)
        assert.is_false(ctx.nodes.BtnItemActionLabel.Visible)
        ctx.nodes.BtnBackpack.OnClicked:Fire()
        assert.is_true(ctx.nodes.ItemAction2.Visible)
        assert.is_true(ctx.nodes.ItemAction2.TouchEnabled)
        assert.same('手持' .. NAME.carp, label())
    end)

    -- 失败方式 3：特殊道具生效且空闲时，手持鱼竿 / 食物都让位给吐息
    it('test_special_effect_overrides_rod_and_food', function()
        ctx = setUp()
        push('ItemBarState', selecting('starterRod'))
        push('SpecialItemState', { effect = 'godzilla', breathRemaining = 0 })
        assert.same('原子吐息', label())
        assert.is_true(ctx.nodes.ItemAction2.TouchEnabled)
        click()
        assert.same({ 'SpecialItemAction' }, sentNames(ctx, 1)) -- 第 1 条是初始化补取的 SpecialItemStateRequest
        assert.same({ action = 'breath' }, ctx.sent[#ctx.sent].payload)
        local sent = #ctx.sent
        push('ItemBarState', selecting('carp', true))
        assert.same('原子吐息', label())
        click()
        assert.same({ 'SpecialItemAction' }, sentNames(ctx, sent))
        assert.same(0, #ctx.commands)
    end)

    -- 失败方式 4：上钩时手持食物 / 鱼竿、甚至特殊道具生效，按钮都是「点击收线」，点击走本地收线
    it('test_hooked_overrides_food_rod_and_special', function()
        ctx = setUp()
        push('ItemBarState', selecting('carp', true))
        push('SpecialItemState', { effect = 'godzilla', breathRemaining = 0 })
        local sent = #ctx.sent
        push('CastState', { phase = 'hooked', reelSession = 7 })
        assert.same('点击收线', label())
        assert.is_true(ctx.nodes.ItemAction2.TouchEnabled)
        click()
        assert.same(1, ctx.clicks)
        assert.same({}, sentNames(ctx, sent))
        push('ItemBarState', selecting('starterRod'))
        assert.same('点击收线', label())
        click()
        assert.same(2, ctx.clicks)
        assert.same({}, sentNames(ctx, sent))
        -- 「结束收线」仍是独立的临时按钮，攻击键照旧是攻击
        assert.is_true(ctx.nodes.ReelClose.Visible)
        assert.same('结束收线', ctx.nodes.BtnReelCloseLabel.Text)
        assert.same('攻击', ctx.nodes.AttackLabel.Text)
    end)

    -- 失败方式 5：鱼线在外（未上钩 cast / 脱钩 unhooked）时手持食物，按钮仍是收回鱼线
    it('test_line_out_overrides_food', function()
        ctx = setUp()
        push('ItemBarState', selecting('carp', true))
        for _, phase in ipairs({ 'cast', 'unhooked' }) do
            push('CastState', { phase = phase })
            assert.same('收线', label(), phase)
            assert.is_true(ctx.nodes.ItemAction2.TouchEnabled, phase)
            click()
            assert.same({ name = 'CastAction', payload = { action = 'Reel' } }, ctx.sent[#ctx.sent], phase)
        end
        assert.same(0, #ctx.commands)
        assert.is_false(ctx.nodes.ReelClose.Visible)
    end)

    -- 失败方式 6：头上顶着鱼时，选中食物 / 鱼竿或特殊道具生效，显示与点击都是「放下」
    it('test_holding_fish_drops_before_food_rod_and_special', function()
        ctx = setUp()
        push('CastState', { phase = 'idle', holding = { fishId = 'carp' } })
        for _, itemId in ipairs({ 'carp', 'starterRod' }) do
            push('ItemBarState', selecting(itemId))
            assert.same('放下', label(), itemId)
            click()
            assert.same({ name = 'CastAction', payload = { action = 'Drop' } }, ctx.sent[#ctx.sent], itemId)
        end
        push('SpecialItemState', { effect = 'godzilla', breathRemaining = 0 })
        assert.same('放下', label())
        click()
        assert.same({ name = 'CastAction', payload = { action = 'Drop' } }, ctx.sent[#ctx.sent])
        push('SpecialItemState', { effect = 'wings', breathRemaining = 0 })
        assert.same('放下', label())
        local sent = #ctx.sent
        ctx.nodes.ItemAction2.OnTouchBegan:Fire()
        assert.same({}, sentNames(ctx, sent), '顶着鱼时长按不起飞')
        assert.same(0, #ctx.commands)
    end)

    -- 失败方式 6 的反面：鱼获放下后，同一选中格回到它自己的语义
    it('test_idle_rod_casts_after_fish_dropped', function()
        ctx = setUp()
        push('ItemBarState', selecting('starterRod'))
        push('CastState', { phase = 'idle', holding = { fishId = 'carp' } })
        assert.same('放下', label())
        push('CastState', { phase = 'idle' })
        assert.same('抛竿', label())
        assert.is_true(ctx.nodes.ItemAction2.TouchEnabled)
        click()
        assert.same({ name = 'CastAction', payload = { action = 'Cast', slot = 1, itemId = 'starterRod' } },
            ctx.sent[#ctx.sent])
    end)

    -- 失败方式 7：选中的既非鱼竿也非食物（船票），按钮不出现；强行点击给「请重新选择鱼竿」
    it('test_other_item_hides_button_and_forced_click_hints_invalid_rod', function()
        ctx = setUp()
        push('ItemBarState', selecting('item147'))
        assert.is_false(ctx.nodes.ItemAction2.Visible)
        assert.is_false(ctx.nodes.BtnItemActionLabel.Visible)
        assert.is_false(ctx.nodes.ItemAction2.TouchEnabled)
        local sent = #ctx.sent
        click()
        assert.same({}, sentNames(ctx, sent))
        assert.same(0, #ctx.commands)
        assert.is_true(ctx.nodes.CastFailureHint.Visible)
        assert.same('请重新选择鱼竿', ctx.nodes.CastFailureHint.Text)
    end)
end)
