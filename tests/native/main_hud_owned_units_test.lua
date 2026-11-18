-- #209 主界面 HUD 的运行期节点归属（client/ScreenHandlers/ScreenMain.lua）：每个建点建完即交给
-- OwnedUnits，关屏时按所有者一次清空；私有桶（Buttons / Overlays / Slots[i].Background）不再
-- 承担生命周期。接缝与 item_bar_ui_test / hud_popup_ui_test 同款：整屏假环境 + 假 World 的
-- CreateUnit（节点自带销毁标记与销毁次数）+ OwnedUnits.Count。
--
-- 动手前列出的失败方式：
--   1. 某个建点建完没登记 → 关屏后它还在场上（私有桶已经不兜底了）；
--   2. 清空没走登记表、清的不是这个所有者、或同一个节点登记了两次 → 关屏后登记表仍非空，
--      登记表自己成了泄漏源；
--   3. 短命的瞄准拾取层挂在主界面名下、又在 EndAim 先拆一次 → 关屏时同一个节点被拆第二遍
--      （真引擎里重复销毁会报错）；
--   4. 每次长按瞄准留下的登记记录不回收 → 一局下来登记表只增不减。
local OwnedUnits = require('common.OwnedUnits')

local GLOBALS = { 'game', 'Vector2', 'Color', 'REUtil', 'GameUI', 'MgrGameUI', 'LocalReelIn' }

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
        local node = { Kind = kind, Destroys = 0, OnClicked = signal(),
            OnTouchBegan = signal(), OnTouchEnded = signal() }
        for key, value in pairs(attrs) do node[key] = value end
        function node:Destroy()
            self.Destroyed = true
            self.Destroys = self.Destroys + 1
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
        -- 走一遍惰性建点：两个弹窗的候选格都是点开才建，不点就漏掉这批建点
        ctx.states:Fire({ slots = {}, slotCount = 4, bait = { worm = 2, sausage = 1 },
            weapons = { item134 = 1 }, backpackCount = 5 })
        ctx.nodes.WeaponBar.OnClicked:Fire()
        ctx.nodes.BaitBar.OnClicked:Fire()
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

    it('test_aim_overlay_destroyed_once_without_leaving_registry_trail', function()
        ctx = setUp()
        local hudNodes = OwnedUnits.Count(ctx.handler)
        local overlays = {}
        for index = 1, 3 do
            ctx.handler:BeginAim(1)
            local overlay = ctx.created[#ctx.created]
            assert.same('ThrowAimOverlay', overlay.Name)
            -- 拾取层是立刻回收的单例：活着时也不挂在主界面名下，否则 EndAim 拆过之后
            -- 登记表还留着它，关屏时得再拆一遍（登记表没有「取消登记」）
            assert.same(hudNodes, OwnedUnits.Count(ctx.handler))
            ctx.handler:EndAim()
            assert.is_true(overlay.Destroyed, '瞄准结束后拾取层应立刻销毁')
            overlays[index] = overlay
        end
        ctx.handler:Cleanup()
        for _, overlay in ipairs(overlays) do
            if overlay.Destroys ~= 1 then
                assert.is_true(false, '瞄准拾取层被销毁 ' .. overlay.Destroys .. ' 次，应为 1 次')
            end
        end
        assert.same(0, OwnedUnits.Count(ctx.handler))
    end)
end)
