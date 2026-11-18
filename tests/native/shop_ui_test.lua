-- #86 迁移（原 tests/gameplay/shop_ui_test.lua，#130）。失败方式先列：
-- 页签缺失/页内容错（排序与 ListForPage 口径不一致）、
-- 升级页不分页、行状态错（锁定可点/已购可重复买）、购买发了 itemKey 而不是编号、
-- 金币页平台不可用时伪成功或卡死（不可返回）、失败提示缺 limit/level/金币页引导。
local GameCfg = require('common.GameCfg')
local OwnedUnits = require('common.OwnedUnits')

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

local function numbersOf(rows)
    local out = {}
    for i, row in ipairs(rows or {}) do out[i] = row and row.number or nil end
    return out
end

-- ===== LocalShop 失败提示（#130 文案） =====
describe("钓场商店的失败提示", function()
    local ctx

    before_each(function()
        ctx = { notices = {}, created = {}, bubbleRoots = {}, anchors = {} }
        ctx.previous = { game = rawget(_G, 'game'), Vector2 = rawget(_G, 'Vector2'),
            Vector3 = rawget(_G, 'Vector3'), Color = rawget(_G, 'Color'),
            GameUI = rawget(_G, 'GameUI'), LocalMsgNotice = rawget(_G, 'LocalMsgNotice') }
        ctx.previousModules = { ['common.REUtil'] = package.loaded['common.REUtil'],
            ['common.Util'] = package.loaded['common.Util'], ['client.LocalShop'] = package.loaded['client.LocalShop'] }
        ctx.shopResult = signal()
        package.loaded['common.REUtil'] = { GetRE = function(_, name)
            if name == 'ShopResult' then return { OnClientEvent = ctx.shopResult,
                FireClient = function() end } end
            return { FireClient = function() end }
        end }
        package.loaded['common.Util'] = { WaitForChild = function(_, _, name) return ctx.anchors[name] end,
            MsgNotice = function() end }
        package.loaded['client.LocalShop'] = nil
        _G.LocalMsgNotice = function(msg) ctx.notices[#ctx.notices + 1] = msg end
        local world = {}
        function world:CreateUnit(_, attrs)
            local node = attrs or {}
            node.OnClicked = signal()
            node.Destroy = function(self) self.Destroyed = true end
            ctx.created[#ctx.created + 1] = node
            return node
        end
        _G.game = { GetService = function(_, name)
            if name == 'World' then return world end
            if name == 'Players' then return { LocalPlayer = { Character = nil } } end
            if name == 'RunService' then return { IsServer = function() return false end,
                Heartbeat = { Connect = function() end } } end
        end }
        _G.Vector2 = { New = function(x, y) return { x = x, y = y } end }
        _G.Vector3 = { New = function(x, y, z) return { x = x, y = y, z = z } end }
        _G.Color = { New = function(...) return { ... } end }
        _G.GameUI = { CreateSceneNode = function() error('无预设') end,
            GetEuiManager = function() return { CreateSceneNodeAtPosition = function()
                local node = { Visible = true, FindFirstChild = function() return nil end,
                    Destroy = function(self) self.Destroyed = true end }
                ctx.bubbleRoots[#ctx.bubbleRoots + 1] = node
                return node
            end } end }
        _G.REUtil = { GetRE = function(_, name)
            if name == 'ShopResult' then return { OnClientEvent = ctx.shopResult } end
            return { FireClient = function() end }
        end }
        ctx.localShop = assert(loadfile('client/LocalShop.lua'))()
    end)

    after_each(function()
        for key, value in pairs(ctx.previousModules) do package.loaded[key] = value end
        for _, key in ipairs({ 'game', 'Vector2', 'Vector3', 'Color', 'GameUI', 'LocalMsgNotice' }) do
            _G[key] = ctx.previous[key]
        end
    end)

    it("test_fail_text_covers_limit_level_and_coin_guidance", function()
        assert.matches('上限', ctx.localShop.FailText.limit, nil, true)
        assert.matches('前一级', ctx.localShop.FailText.level, nil, true)
        assert.matches('金币页', ctx.localShop.FailText.coin, nil, true)
    end)

    -- 入口气泡关闭（清空）后：登记表归空、按钮与文字确被销毁、气泡根节点也销毁；重复清空幂等
    it("test_clear_destroys_bubble_nodes_and_empties_registry", function()
        for _, stand in ipairs(GameCfg.Shop.Stands) do
            ctx.anchors[stand.AnchorName] = { Name = stand.AnchorName, Position = { x = 0, y = 0, z = 0 } }
        end
        ctx.localShop:Start()
        assert.same(2 * #GameCfg.Shop.Stands, OwnedUnits.Count(ctx.localShop))
        assert.same(#GameCfg.Shop.Stands, #ctx.localShop.Bubbles)
        ctx.localShop:Clear()
        assert.same(0, OwnedUnits.Count(ctx.localShop)) -- 登记表归空
        assert.same(0, #ctx.localShop.Bubbles)
        assert.same(2 * #GameCfg.Shop.Stands, #ctx.created)
        for _, node in ipairs(ctx.created) do
            assert.is_true(node.Destroyed, "入口按钮与文字都应销毁")
        end
        for _, node in ipairs(ctx.bubbleRoots) do
            assert.is_true(node.Destroyed, "气泡根节点也应销毁")
        end
        ctx.localShop:Clear() -- 幂等：重复清空不报错
        assert.same(0, OwnedUnits.Count(ctx.localShop))
    end)

    it("test_notice_mapping_for_new_reasons", function()
        ctx.localShop:Start() -- 连接 ShopResult；摊位锚点缺失只打日志
        ctx.shopResult:Fire({ ok = false, reason = 'limit', number = 51 })
        ctx.shopResult:Fire({ ok = false, reason = 'level', number = 50 })
        ctx.shopResult:Fire({ ok = false, reason = 'coin', itemId = 'starterRod' })
        ctx.shopResult:Fire({ ok = true, number = 51, kind = 'melee', level = 1, price = 50, name = '近战武器升级1' })
        assert.same({
            ctx.localShop.FailText.limit,
            ctx.localShop.FailText.level,
            ctx.localShop.FailText.coin,
            '购买成功：近战武器升级1，花费 50 金币',
        }, ctx.notices)
    end)
end)

-- ===== 商店界面（#216 固定骨架 + 运行期填行） =====
-- 本屏唯一的测试接缝是 handler:View()（纯显示快照）与行/页签按钮发出的指令；不断言节点数量、
-- 坐标、颜色与层级——那些由共享简报的骨架契约与编辑器试玩负责。
-- 动手前列出的失败方式（每例对应其中一条）：
--   1. 页签文字不取 GameCfg.Shop.Pages（写死旧文案）→ 改术语后界面与配置对不上；
--   2. 打开不回钓具页、金币条不刷新 → 重开商店停在上次的页、读到旧金币；
--   3. 切页签只改字不切容器（或只切容器不改字）→ 金币页叠着商品列表；
--   4. 切页签不清选中 → 详情区留着上一页的商品；
--   5. 行序与 ListForPage 不一致、锁定行不写原因 → 摊位等级不够时看不出为什么不能买；
--   6. 升级页仍按 8 行切页 → 滚动列表里只看到 8 条；
--   7. 三态判错（锁定能买、已购能重买、逐级升级不开放）→ 客户端发出必被服务端拒的请求；
--   8. 购买 payload 发 itemKey 而不是商店编号 → 升级行没有 itemKey，根本买不了；
--   9. 平台不可用/抛错时伪成功或关屏 → 玩家以为买到了，或回不去其他分页；
--  10. 运行期建行没登记、或 Init 里就渲染 → 重建界面后旧行叠加、登记表不归零。
describe("钓场商店界面（#216 固定骨架）", function()
    local ctx

    before_each(function()
        ctx = { nodes = {}, created = {}, commands = {}, events = {} }
        ctx.previous = { game = rawget(_G, 'game'), Vector2 = rawget(_G, 'Vector2'),
            Color = rawget(_G, 'Color'), REUtil = rawget(_G, 'REUtil'),
            GameUI = rawget(_G, 'GameUI'), MgrGameUI = rawget(_G, 'MgrGameUI'),
            PlatformShop = rawget(_G, 'PlatformShop') }
        ctx.previousLocalShop = package.loaded['client.LocalShop']
        ctx.previousHandler = package.loaded['client.ScreenHandlers.ScreenShop']
        package.loaded['client.LocalShop'] = { Stand = { AnchorName = 'TGUnitShopShrimp', Level = 2 } }
        package.loaded['client.ScreenHandlers.ScreenShop'] = nil
        -- 假 World：建点即挂到 Parent 的子节点表上（供 FindFirstChild 取行与行内子节点），
        -- 销毁按引擎口径递归（EUI 节点 Destroy 带走子节点，所以行内子节点不必单独登记）。
        local world = {}
        function world:CreateUnit(kind, attrs)
            local node = { Kind = kind, OnClicked = signal(), Children = {} }
            function node:FindFirstChild(name) return self.Children[name] end
            function node:Destroy()
                self.Destroyed = true
                -- 真引擎销毁会同时把节点从父节点子表里摘掉；不摘会让「复用行」按名找回死节点
                if self.Parent and self.Parent.Children[self.Name] == self then
                    self.Parent.Children[self.Name] = nil
                end
                local children = self.Children
                self.Children = {}
                for _, child in pairs(children) do child:Destroy() end
            end
            for key, value in pairs(attrs or {}) do node[key] = value end
            if node.Parent and node.Name then node.Parent.Children[node.Name] = node end
            if node.Name then ctx.nodes[node.Name] = node end
            ctx.created[#ctx.created + 1] = node
            return node
        end
        _G.game = { GetService = function(_, name)
            if name == 'World' then return world end
            if name == 'Players' then
                return { LocalPlayer = { GetAttribute = function() return 77 end } }
            end
        end }
        _G.Vector2 = { New = function(x, y) return { x = x, y = y } end }
        _G.Color = { New = function(...) return { ... } end }
        _G.GameUI = { GetEuiManager = function() return {
            GetDeviceResolution = function() return { x = 1920, y = 1080 } end } end }
        _G.MgrGameUI = { CloseScreen = function() end }
        _G.PlatformShop = nil
        _G.REUtil = { GetRE = function(_, name)
            if not ctx.events[name] then
                ctx.events[name] = { OnClientEvent = signal(), FireServer = function(_, payload)
                    ctx.commands[#ctx.commands + 1] = payload end }
            end
            return ctx.events[name]
        end }
        ctx.handler = assert(loadfile('client/ScreenHandlers/ScreenShop.lua'))()
        -- 预制体骨架替身：名册里的节点按名字给；层级与几何不进单测，契约在共享简报里。
        for _, name in ipairs(ctx.handler.UINodes) do
            ctx.nodes[name] = { Name = name, Visible = true, Text = '', Children = {},
                OnClicked = signal(), FindFirstChild = function(self, child) return self.Children[child] end }
        end
        ctx.handler.UINodeMap = ctx.nodes
        ctx.handler.RootNode = { Name = 'ScreenShop' }
        ctx.handler:Init()
        ctx.handler:OpenScreen()
    end)

    after_each(function()
        package.loaded['client.LocalShop'] = ctx.previousLocalShop
        package.loaded['client.ScreenHandlers.ScreenShop'] = ctx.previousHandler
        for _, key in ipairs({ 'game', 'Vector2', 'Color', 'REUtil', 'GameUI', 'MgrGameUI', 'PlatformShop' }) do
            _G[key] = ctx.previous[key]
        end
    end)

    it("test_open_shows_skeleton_tabs_on_first_page", function()
        local view = ctx.handler:View()
        assert.same(GameCfg.Shop.Pages, view.tabs)
        assert.same('钓具', view.page)
        assert.is_nil(view.selected)
        assert.is_true(view.panels.list)
        assert.is_false(view.panels.coin)
        assert.same('77', view.coinText)
    end)

    -- 四页签逐个点：页名、容器可见性与选中三样一起换
    it("test_every_tab_switches_container_and_clears_selection", function()
        local coin = GameCfg.Shop.Pages[#GameCfg.Shop.Pages]
        for index, page in ipairs(GameCfg.Shop.Pages) do
            ctx.handler:Select(1)
            ctx.nodes['BtnShopPage' .. index].OnClicked:Fire()
            local view = ctx.handler:View()
            assert.same(page, view.page)
            assert.is_nil(view.selected)
            assert.same(page == coin, view.panels.coin)
            assert.same(page ~= coin, view.panels.list)
        end
    end)

    it("test_rows_follow_list_for_page_order_with_locked_reason", function()
        local rows = ctx.handler:View().rows
        -- 2 级摊「钓具」页：当地新品（香肠 11 / 钓虾竿 12）置顶，其余按商店编号升序，锁定行也在列
        assert.same({ 11, 12, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 13, 14 }, numbersOf(rows))
        assert.same('香肠', rows[1].name)
        assert.same('2', rows[1].priceText)
        assert.same('buy', rows[1].state)
        assert.same('', rows[1].stateText)
        -- 科技假饵（编号 1）需 7 级摊位：列出来，但要说清为什么不能买
        assert.same('locked', rows[3].state)
        assert.matches('需 7 级摊位', rows[3].stateText, 1, true)
    end)

    -- 滚动列表：升级页 24 行一次进列表，不再按 8 行切页（翻页按钮随骨架一起消失）
    it("test_upgrade_page_lists_every_row_without_paging", function()
        package.loaded['client.LocalShop'].Stand = { AnchorName = 'TGUnitShop7', Level = 7 }
        ctx.handler:SetPage('升级')
        local numbers = numbersOf(ctx.handler:View().rows)
        assert.same(24, #numbers)
        assert.same(34, numbers[1]) -- 7 级新品置顶：远程武器升级5
        assert.same(45, numbers[3]) -- 近战武器升级7
        assert.same(28, numbers[4]) -- 之后回到编号升序：背包升级6
        assert.same(51, numbers[#numbers])
    end)

    -- 行三态：锁定不可买、逐级开放、已购拦截；服务端成功回包后行转已购并放出下一级
    it("test_row_states_lock_buy_and_owned", function()
        ctx.handler:SetPage('升级')
        local function rowOf(number)
            for _, row in ipairs(ctx.handler:View().rows) do
                if row.number == number then return row end
            end
        end
        assert.same('locked', rowOf(32).state) -- 背包升级2：越级（当前 0 级）
        assert.same('buy', rowOf(41).state)    -- 弹容量升级1：逐级可买
        assert.same('locked', rowOf(50).state) -- 近战武器升级2：越级
        assert.same('buy', rowOf(51).state)    -- 近战武器升级1
        assert.matches('前一级', rowOf(32).stateText, 1, true)
        ctx.nodes['ShopRow' .. rowOf(51).index].OnClicked:Fire()
        assert.same(51, ctx.commands[1].number)
        ctx.events.ShopResult.OnClientEvent:Fire({ ok = true, number = 51, kind = 'melee', level = 1, price = 50 })
        assert.same('owned', rowOf(51).state)
        assert.same('buy', rowOf(50).state)
        ctx.commands = {}
        ctx.nodes['ShopRow' .. rowOf(51).index].OnClicked:Fire()
        assert.same({}, ctx.commands)
    end)

    -- 购买一律发商店编号（升级行没有 itemKey）
    it("test_buy_sends_shop_number_not_item_key", function()
        ctx.nodes.ShopRow1.OnClicked:Fire() -- 钓具页第 1 行 = 香肠（编号 11）
        assert.same({ { action = 'Buy', number = 11, seq = 1 } }, ctx.commands)
        ctx.handler:SetPage('升级')
        ctx.nodes.ShopRow2.OnClicked:Fire() -- 升级页第 2 行 = 弹容量升级1（编号 41）
        assert.same(41, ctx.commands[2].number)
        assert.is_nil(ctx.commands[2].itemId)
    end)

    -- 金币页：只显示自己的容器、没有商品行；平台缺失或抛错都只提示、不关屏、不发购买请求
    it("test_coin_page_degrades_without_faking_success", function()
        ctx.handler:SetPage('金币')
        local view = ctx.handler:View()
        assert.same({}, numbersOf(view.rows))
        assert.is_true(view.panels.coin)
        assert.is_false(view.panels.list)
        ctx.nodes.BtnOpenPlatformShop.OnClicked:Fire()
        assert.matches('平台商店暂不可用', ctx.handler:View().coinHint, 1, true)
        assert.is_true(ctx.handler.IsOpen)
        _G.PlatformShop = { Open = function() error('平台未接入') end }
        ctx.nodes.BtnOpenPlatformShop.OnClicked:Fire()
        assert.matches('打开失败', ctx.handler:View().coinHint, 1, true)
        assert.is_true(ctx.handler.IsOpen)
        ctx.handler:SetPage('钓具')
        assert.same(11, numbersOf(ctx.handler:View().rows)[1])
        assert.same({}, ctx.commands)
    end)

    -- 重开商店：回到钓具页，不残留选中（关屏不做事，复位靠 OpenScreen）
    it("test_reopen_resets_to_first_page_without_selection", function()
        ctx.handler:SetPage('升级')
        ctx.handler:Select(2)
        ctx.handler:CloseScreen()
        ctx.handler:OpenScreen()
        local view = ctx.handler:View()
        assert.same('钓具', view.page)
        assert.is_nil(view.selected)
        assert.same(11, numbersOf(view.rows)[1])
        assert.same('77', view.coinText)
    end)

    -- 归属登记：本屏运行期只建商品行（行内子节点随行递归销毁，不单独登记），一行一个登记项；
    -- 换 RootNode 再 Init 时上一轮整体销毁、登记表归零，重开渲染只留新一轮。
    it("test_rebuild_clears_registry_and_keeps_one_owner", function()
        assert.same(#ctx.handler:View().rows, OwnedUnits.Count(ctx.handler))
        local previous = ctx.created
        ctx.created = {}
        ctx.handler.RootNode = { Name = 'ScreenShopRebuilt' }
        ctx.handler:Init()
        assert.same(0, OwnedUnits.Count(ctx.handler))
        for _, node in ipairs(previous) do
            assert.is_true(node.Destroyed, '上一轮运行期建点应被销毁')
        end
        ctx.handler:OpenScreen()
        assert.same(#ctx.handler:View().rows, OwnedUnits.Count(ctx.handler))
    end)
end)
