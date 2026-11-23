-- #209 主界面 HUD 的运行期节点归属（client/ScreenHandlers/ScreenMain.lua）：每个建点建完即交给
-- OwnedUnits，关屏时按所有者一次清空；私有桶（Buttons / Overlays / Slots[i].Background）不再
-- 承担生命周期。接缝与 item_bar_ui_test / hud_popup_ui_test 同款：整屏假环境 + 假 World 的
-- CreateUnit（节点自带销毁标记与销毁次数）+ OwnedUnits.Count。
--
-- 动手前列出的失败方式：
--   1. 某个建点建完没登记 → 关屏后它还在场上（私有桶已经不兜底了）；
--   2. 清空没走登记表、清的不是这个所有者、或同一个节点登记了两次 → 关屏后登记表仍非空，
--      登记表自己成了泄漏源；
--   （#297-C2 起瞄准拾取层归 MainHudItemBarView，其节点归属由 spec/client_main_hud_item_bar_test 守）。
local OwnedUnits = require('common.OwnedUnits')

local GLOBALS = { 'game', 'Vector2', 'Color', 'REUtil', 'GameUI', 'MgrGameUI', 'LocalReelIn', 'print' }

local cleanupFaults = {}

local function signal()
    local listeners = {}
    return {
        Connect = function(_, fn)
            listeners[#listeners + 1] = fn
            return { Disconnect = function()
                if cleanupFaults.disconnect then error('injected disconnect failure', 0) end
                for i, cb in ipairs(listeners) do
                    if cb == fn then table.remove(listeners, i) break end
                end
            end }
        end,
        Fire = function(_, ...) for _, fn in ipairs(listeners) do fn(...) end end,
        Count = function() return #listeners end,
    }
end

local function setUp()
    local ctx = { nodes = {}, created = {}, events = {}, now = 100 }
    ctx.previous = {}
    for _, key in ipairs(GLOBALS) do ctx.previous[key] = rawget(_G, key) end
    -- 攻击键模块是别的所有者（自己建、自己拆），本单只验主界面：换成空壳，
    -- ctx.created 里就只剩下主界面建的节点，断言「一个不剩」才不含混。
    ctx.previousAttack = package.loaded['client.LocalAttackButton']
    package.loaded['client.LocalAttackButton'] = { Start = function() end, Destroy = function() end,
        SetOpen = function() end, SetEquipped = function() end,
        EquippedWeapon = function() return nil end }
    _G.MgrGameUI = { SetCustomControlUI = function() end, GetScreen = function() end, CloseScreen = function() end }
    local world = { Created = ctx.created }
    function world:CreateUnit(kind, attrs)
        if ctx.failCreate == attrs.Name then error('injected init failure', 0) end
        local node = { Kind = kind, Destroys = 0, OnClicked = signal(),
            OnTouchBegan = signal(), OnTouchEnded = signal() }
        for key, value in pairs(attrs) do node[key] = value end
        function node:Destroy()
            self.Destroyed = true
            self.Destroys = self.Destroys + 1
            if ctx.failDestroy == self.Name then error('injected rollback destroy failure', 0) end
        end
        if node.Name then ctx.nodes[node.Name] = node end
        ctx.created[#ctx.created + 1] = node
        return node
    end
    function world:GetServerTime() return ctx.now end
    local attributes = { Health = 80, MaxHealth = 100, Hunger = 60, MaxHunger = 100, FishCoin = 5 }
    local player = { GetAttribute = function(_, key) return attributes[key] end,
        GetAttributeChangedSignal = function() return signal() end }
    _G.game = { GetService = function(_, name)
        if name == 'World' then return world end
        if name == 'Players' then return { LocalPlayer = player } end
    end }
    _G.Vector2 = { New = function(x, y) return { x = x, y = y } end }
    _G.Color = { New = function(...) return { ... } end }
    _G.GameUI = { GetEuiManager = function() return {
        GetDeviceResolution = function() return { x = 1920, y = 1080 } end,
    } end, GetUIRoot = function() return nil end }
    _G.REUtil = { GetRE = function(_, name)
        if not ctx.events[name] then
            ctx.events[name] = { OnClientEvent = signal(), FireServer = function() end }
        end
        return ctx.events[name]
    end }
    _G.LocalReelIn = { SetSession = function() end, Clear = function() end,
        Suspend = function() end, Close = function() end }
    -- 编辑器摆放的金币节点：ScreenMain 的直接子节点，运行时按名查找，不算脚本建点
    ctx.nodes.ImageCoin = { Name = 'ImageCoin', Position = { x = 864, y = 1145 }, Size = { x = 80, y = 80 } }
    ctx.nodes.LabelCoin = { Name = 'LabelCoin', Position = { x = 960, y = 1145 }, Size = { x = 200, y = 60 } }
    ctx.states = _G.REUtil:GetRE('ItemBarState').OnClientEvent
    ctx.handler = assert(loadfile('client/ScreenHandlers/ScreenMain.lua'))()
    ctx.handler.RootNode = { Name = 'ScreenMain',
        FindFirstChild = function(_, name) return ctx.nodes[name] end }
    ctx.handler:Init()
    ctx.handler.IsOpen = true
    return ctx
end

local function tearDown(ctx)
    package.loaded['client.LocalAttackButton'] = ctx.previousAttack
    for _, key in ipairs(GLOBALS) do _G[key] = ctx.previous[key] end
end

describe('主界面 HUD 的节点归属（#209）', function()
    local ctx

    after_each(function()
        if ctx then tearDown(ctx) end
        ctx = nil
    end)

    it('test_cleanup_destroys_and_unregisters_every_hud_node', function()
        ctx = setUp()
        ctx.states:Fire({ slots = {}, slotCount = 4, bait = { worm = 2, sausage = 1 },
            weapons = { item134 = 1 }, backpackCount = 5 })
        -- 世界建了多少个节点，主界面名下就该有多少个：漏登记或多登记都在这里露出
        assert.same(#ctx.created, OwnedUnits.Count(ctx.handler))
        ctx.handler:Cleanup()
        assert.same(0, OwnedUnits.Count(ctx.handler))
        for _, node in ipairs(ctx.created) do
            if not node.Destroyed then
                assert.is_true(false, '关屏后仍活着的节点: ' .. tostring(node.Name))
            end
        end
    end)


    it('test_partial_init_rolls_back_listeners_and_preserves_original_error', function()
        ctx = setUp()
        ctx.handler:Cleanup()
        ctx.failCreate = 'QuestBackground'
        ctx.failDestroy = 'ItemDiscard'
        local logs = {}
        _G.print = function(...) logs[#logs + 1] = table.concat({ ... }, '	') end

        local ok, err = pcall(function() ctx.handler:Init() end)
        assert.is_false(ok)
        assert.same('injected init failure', err)
        assert.same(0, ctx.states:Count(), '失败 Init 的 ItemBarState 监听必须回滚')
        assert.same(0, OwnedUnits.Count(ctx.handler), '失败 Init 不得继续持有部分节点')
        assert.matches('injected rollback destroy failure', table.concat(logs, '\n'), 1, true)

        ctx.failCreate = nil
        ctx.failDestroy = nil
        ctx.handler:Init()
        assert.same(1, ctx.states:Count(), '回滚后重试应只有当前一组监听')
    end)

    it('test_cleanup_continues_after_close_failure_and_records_it', function()
        ctx = setUp()
        ctx.handler.CloseScreen = function() error('injected close failure', 0) end
        local logs = {}
        _G.print = function(...) logs[#logs + 1] = table.concat({ ... }, '	') end

        ctx.handler:Cleanup()
        assert.same(0, ctx.states:Count(), 'CloseScreen 失败后仍须断开根监听')
        assert.same(0, OwnedUnits.Count(ctx.handler), 'CloseScreen 失败后仍须销毁根节点')
        assert.matches('injected close failure', table.concat(logs, '\n'), 1, true)
    end)

    it('test_cleanup_records_every_stage_failure_and_continues', function()
        local DamageFloat = require('client.DamageFloat')
        local savedClear, savedOwnedClear = DamageFloat.Clear, OwnedUnits.Clear
        local function restoreStages()
            DamageFloat.Clear = savedClear
            OwnedUnits.Clear = savedOwnedClear
            cleanupFaults.disconnect = nil
        end
        local stages = {
            { name = '浮动表现', message = 'injected float failure',
                arm = function() DamageFloat.Clear = function() error('injected float failure', 0) end end },
            { name = '攻击键', message = 'injected attack failure',
                arm = function() package.loaded['client.LocalAttackButton'].Destroy =
                    function() error('injected attack failure', 0) end end },
            { name = '连接', message = 'injected disconnect failure', before = true,
                arm = function() cleanupFaults.disconnect = true end,
                later = function() return OwnedUnits.Count(ctx.handler) == 0 end },
            { name = 'OwnedUnits', message = 'injected owned units failure',
                arm = function() OwnedUnits.Clear = function() error('injected owned units failure', 0) end end },
        }
        local logs = {}
        _G.print = function(...) logs[#logs + 1] = table.concat({ ... }, '	') end

        for _, stage in ipairs(stages) do
            restoreStages()
            ctx = setUp()
            stage.arm()
            local ok, err = pcall(function() ctx.handler:Cleanup() end)
            assert.is_true(ok, stage.name .. ' 失败不得传给 Cleanup 调用方: ' .. tostring(err))
            if stage.later then
                assert.is_true(stage.later(), stage.name .. ' 失败后后续清理阶段必须完成')
            else
                assert.same(0, ctx.states:Count(), stage.name .. ' 失败后仍须断开根监听')
                if stage.name ~= 'OwnedUnits' then
                    assert.same(0, OwnedUnits.Count(ctx.handler), stage.name .. ' 失败后仍须清空节点登记')
                end
            end
            assert.matches(stage.message, table.concat(logs, '\n'), 1, true)
            tearDown(ctx)
            ctx = nil
        end

        restoreStages()
        ctx = setUp()
        DamageFloat.Clear = function() error('injected float failure', 0) end
        package.loaded['client.LocalAttackButton'].Destroy =
            function() error('injected attack failure', 0) end
        cleanupFaults.disconnect = true
        OwnedUnits.Clear = function() error('injected owned units failure', 0) end
        local ok, err = pcall(function() ctx.handler:Cleanup() end)
        restoreStages()
        assert.is_true(ok, '多个清理阶段失败不得聚合成调用方错误: ' .. tostring(err))
        local report = table.concat(logs, '\n')
        for _, stage in ipairs(stages) do
            assert.matches(stage.message, report, 1, true)
        end
    end)
end)
