-- #86 迁移（原 tests/gameplay/shop_ui_test.lua，#130）。失败方式先列：
-- 页签缺失/页内容错（排序与 ListForPage 口径不一致）、
-- 升级页不分页、行状态错（锁定可点/已购可重复买）、购买发了 itemKey 而不是编号、
-- 金币页平台不可用时伪成功或卡死（不可返回）、失败提示缺 limit/level/金币页引导。
local GameCfg = require('common.GameCfg')
local OwnedUnits = require('common.OwnedUnits')
local Eui = require('tests.support.eui_double')

local signal = Eui.Signal

-- luassert 没有 fail()：只在失败分支拼消息（通过的断言不付一次 string.format 的钱）
local function fail(fmt, ...) error(string.format(fmt, ...), 0) end

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

    -- #218 的五类失败文案：#214 要求每类都有一条玩家能读懂的话（不是 reason 码），且只在这一张表里。
    it("test_fail_text_covers_the_five_failure_classes", function()
        local text = ctx.localShop.FailText
        if not (text.coin and text.coin:find('金币不足', 1, true)) then fail('金币不足缺文案') end
        if not (text.full and text.full:find('背包已满', 1, true)) then fail('背包已满缺文案') end
        if not (text.limit and text.limit:find('上限', 1, true)) then fail('已达上限缺文案') end
        if not (text.level and text.level:find('前一级', 1, true)) then fail('前一级升级缺文案') end
        if not (text.stand and text.stand:find('更高等级摊位', 1, true)) then fail('摊位等级缺文案') end
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

    -- 回包 → 消息条（#218）：四类服务端失败各给对应文案（不分错类），成功给「购买成功：X，花费 N 金币」。
    -- 失败方式：两类失败共用一句（分不清是没钱还是背包满）；未知原因没兜底；成功文案漏掉花费金额。
    it("test_notice_mapping_for_success_and_server_failures", function()
        ctx.localShop:Start() -- 连接 ShopResult；摊位锚点缺失只打日志
        for _, reason in ipairs({ 'coin', 'full', 'limit', 'level' }) do
            ctx.shopResult:Fire({ ok = false, reason = reason, number = 51 })
        end
        ctx.shopResult:Fire({ ok = false, reason = 'newReason', number = 51 })
        ctx.shopResult:Fire({ ok = true, number = 51, kind = 'melee', level = 1, price = 50, name = '近战武器升级1' })
        assert.same({
            ctx.localShop.FailText.coin,
            ctx.localShop.FailText.full,
            ctx.localShop.FailText.limit,
            ctx.localShop.FailText.level,
            '购买失败',
            '购买成功：近战武器升级1，花费 50 金币',
        }, ctx.notices)
    end)
end)

-- ===== 商店界面（#216 固定骨架 + 运行期填行，#217 行内容与选中，#218 详情与唯一购买） =====
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
--  10. 运行期建行没登记、或 Init 里就渲染 → 重建界面后旧行叠加、登记表不归零；
--  11. 新品标记按编号或「前两行」写死（不是 MinShopLevel == 摊位等级）→ 换摊位后「新品」标到别行；
--  12. 点行直接下单（#216 旧行为）→ 玩家想看一眼详情就花了钱；
--  13. 选中只活在点击当帧、重绘后丢失 → 买完看不见选中的是哪一行；selected 同时标在多行。
--  14. 详情区不显示描述/限购次数、价格口径与行不一致 → 玩家不知道买什么、还能买几次；
--  15. 升级行不给当前等级与买完的等级 → 不知道这一级值不值；
--  16. 切页签/重开商店后详情区留着上一条、购买按钮仍可点 → 买家以为还能买上一页的商品；
--  17. 详情区购买按钮没接线、或行点击也下单（#216 旧行为）→ 唯一购买入口失效或误下单；
--  18. 已购行能点（白点）/ 锁定行点不了、或点了详情不写原因 → 玩家看不出这件商品是什么、往哪升；
--  19. 服务端拒绝时客户端伪成功（扣金币 / 行转已购）→ 玩家以为买到了；
--  20. 买成后金币条等属性刷新、行与详情不刷新 → 当场看不到扣款，已买满的行还能点；
--  21. 本地拒绝静默 → 玩家不知道为什么买不了。
--  22. 买不起仍显示「购买」并发出必被拒的请求（#219）→ 玩家被拒两次，还找不到获得金币的入口；
--  23. 金币页平台缺失/抛错时伪成功、发请求或卡住页签（#219）→ 玩家以为买到了，或回不去商店；
--  24. 金币页写出汇率、价目换算或平台商品 ID（#219 编造后台参数），界面另写第二套文案。
describe("钓场商店界面（#216 固定骨架 / #217 行与选中 / #218 详情与购买 / #219 金币引导与降级）", function()
    local ctx

    -- 行下标按商店编号找：行序取自 GameCfg.Shop.ListForPage，别在用例里数下标（数错就测成别的商品）
    local function rowIndexOf(view, number)
        for _, row in ipairs(view.rows or {}) do
            if row.number == number then return row.index end
        end
    end

    before_each(function()
        ctx = { nodes = {}, created = {}, commands = {}, events = {}, notices = {},
            attributes = { FishCoin = 77 } }
        ctx.previous = { game = rawget(_G, 'game'), Vector2 = rawget(_G, 'Vector2'),
            Color = rawget(_G, 'Color'), REUtil = rawget(_G, 'REUtil'),
            MgrGameUI = rawget(_G, 'MgrGameUI'),
            PlatformShop = rawget(_G, 'PlatformShop'), LocalMsgNotice = rawget(_G, 'LocalMsgNotice') }
        ctx.previousLocalShop = package.loaded['client.LocalShop']
        ctx.previousHandler = package.loaded['client.ScreenHandlers.ScreenShop']
        _G.LocalMsgNotice = function(msg) ctx.notices[#ctx.notices + 1] = msg end
        package.loaded['client.ScreenHandlers.ScreenShop'] = nil
        -- 共享夹具复刻 EUI 的属性副作用、层级查询与递归销毁；契约见 eui_double_test。
        local function newNode(name, kind, parent)
            local node = Eui.Node{ Name = name, Kind = kind, Parent = parent }
            if name then ctx.nodes[name] = node end
            return node
        end
        -- 假 World：建点即挂到 Parent 的子节点表上（供 FindFirstChild 取行与行内子节点）
        local world = {}
        function world:CreateUnit(kind, attrs)
            local node = newNode(attrs and attrs.Name, kind)
            for key, value in pairs(attrs or {}) do node[key] = value end
            if node.Parent and node.Name then node.Parent.Children[node.Name] = node end
            ctx.created[#ctx.created + 1] = node
            return node
        end
        _G.game = { GetService = function(_, name)
            if name == 'World' then return world end
            if name == 'Players' then
                -- 余额在用例里可改：金币不足的引导（#219）据此切换购买按钮文案
                return { LocalPlayer = { GetAttribute = function(_, key) return ctx.attributes[key] end } }
            end
        end }
        _G.Vector2 = { New = function(x, y) return { x = x, y = y } end }
        _G.Color = { New = function(...) return { ... } end }
        _G.MgrGameUI = { CloseScreen = function() end }
        _G.PlatformShop = nil
        _G.REUtil = { GetRE = function(_, name)
            if not ctx.events[name] then
                ctx.events[name] = { OnClientEvent = signal(), FireServer = function(_, payload)
                    ctx.commands[#ctx.commands + 1] = payload end }
            end
            return ctx.events[name]
        end }
        -- 真 LocalShop 只取 Stand 与 FailText（文案唯一来源）：它的 Start 不调用，不建点也不连信号
        local localShop = assert(loadfile('client/LocalShop.lua'))()
        localShop.Stand = { AnchorName = 'TGUnitShopShrimp', Level = 2 }
        package.loaded['client.LocalShop'] = localShop
        ctx.localShop = localShop
        ctx.handler = assert(loadfile('client/ScreenHandlers/ScreenShop.lua'))()
        -- 预制体骨架替身：名册里的节点按名字挂在 RootNode 子树下（Init 自己按名字深查填表）；
        -- 层级与几何不进单测，契约在共享简报里。换树重建时用同一份名册再建一棵。
        local function makeRoot()
            local root = newNode('ScreenShop')
            for _, name in ipairs(ctx.handler.UINodes) do newNode(name, 'EUITextLabel', root) end
            return root
        end
        ctx.makeRoot = makeRoot
        ctx.handler.RootNode = makeRoot()
        ctx.handler:Init()
        ctx.handler:OpenScreen()
    end)

    after_each(function()
        package.loaded['client.LocalShop'] = ctx.previousLocalShop
        package.loaded['client.ScreenHandlers.ScreenShop'] = ctx.previousHandler
        for _, key in ipairs({ 'game', 'Vector2', 'Color', 'REUtil', 'MgrGameUI', 'PlatformShop',
            'LocalMsgNotice' }) do
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

    -- 页签是文字加短下划线，不再换黄色胶囊；切页时只能有一条下划线可见。
    -- 失败方式：选中标记停留在旧页，或多个标记同时显示；关闭文字没落到 LabelShopClose。
    it("test_selected_tab_moves_single_underline", function()
        assert.is_true(ctx.nodes.ImageShopTabIndicator1.Visible)
        assert.is_false(ctx.nodes.ImageShopTabIndicator2.Visible)
        ctx.handler:SetPage('武器')
        assert.is_false(ctx.nodes.ImageShopTabIndicator1.Visible)
        assert.is_true(ctx.nodes.ImageShopTabIndicator2.Visible)
        for index = 3, #GameCfg.Shop.Pages do
            assert.is_false(ctx.nodes['ImageShopTabIndicator' .. index].Visible)
        end
        assert.same('', ctx.nodes.BtnShopPage1.NormalImage)
        assert.is_nil(ctx.nodes.BtnShopClose.NormalImage)
        assert.same('关闭', ctx.nodes.LabelShopClose.Text)
    end)

    -- 行背景必须独立于按钮底图：11017 作为 EUIButton 图片会遮住子文字。
    it("test_row_background_is_independent_and_selected_text_inverts", function()
        ctx.handler:SetPage('升级')
        ctx.handler:Select(1)
        local row = ctx.nodes.ShopList:FindFirstChild('ShopRow1', true)
        local background = row and row:FindFirstChild('ShopRowBackground1', true)
        local name = row and row:FindFirstChild('ShopRowName1', true)
        assert.is_not_nil(background)
        assert.same('', row.NormalImage)
        assert.same(0, background.LocalZOrder)
        assert.same(1, name.LocalZOrder)
        assert.same({ 240, 231, 208, 255 }, name.TextColor)
    end)

    -- 没有美术资源的商品不能显示引擎白色占位块；隐藏图标但保留名字与详情。
    it("test_missing_item_icon_is_hidden_instead_of_placeholder", function()
        ctx.handler:SetPage('升级')
        ctx.handler:Select(1)
        local view = ctx.handler:View()
        assert.is_nil(view.detail.icon)
        assert.is_false(ctx.nodes.ImageShopDetailIcon.Visible)
        local row = ctx.nodes.ShopList:FindFirstChild('ShopRow1', true)
        local icon = row and row:FindFirstChild('ShopRowIcon1', true)
        assert.is_not_nil(icon)
        assert.is_false(icon.Visible)
    end)

    -- 四页签逐个点：页名、容器可见性与选中三样一起换
    it("test_every_tab_switches_container_and_clears_selection", function()
        local coin = GameCfg.Shop.Pages[#GameCfg.Shop.Pages]
        for index, page in ipairs(GameCfg.Shop.Pages) do
            for _, row in ipairs(ctx.handler:View().rows) do -- 选当前页第一个能点的行（已购行不可点）
                if row.selectable then ctx.handler:Select(row.index) break end
            end
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

    -- 新品标记：MinShopLevel == 当前摊位等级（不新增数据字段）。名字金色只进皮肤表，断言只看快照文本。
    -- 失败方式：新品按编号或「前两行」写死 → 换摊位等级后「新品」标到别行；标记只在皮肤表里、快照看不见。
    it("test_new_badge_follows_stand_level", function()
        local rows = ctx.handler:View().rows
        -- 2 级虾池摊「钓具」页：香肠(11)/钓虾竿(12) 是本摊新解锁
        assert.same({ 11, 12, 1 }, { rows[1].number, rows[2].number, rows[3].number })
        assert.same({ true, true, false }, { rows[1].isNew, rows[2].isNew, rows[3].isNew })
        assert.same({ '新品', '新品', '' }, { rows[1].newText, rows[2].newText, rows[3].newText })
        -- 换 3 级蟹湖摊重刷本页：新品变成鲱鱼罐头(9)/捕蟹竿(10)，科技假饵(1) 仍不是
        package.loaded['client.LocalShop'].Stand = { AnchorName = 'Z3_Shop', Level = 3 }
        ctx.handler:SetPage('钓具')
        local level3 = ctx.handler:View().rows
        assert.same({ 9, 10, 1 }, { level3[1].number, level3[2].number, level3[3].number })
        assert.same({ true, true, false }, { level3[1].isNew, level3[2].isNew, level3[3].isNew })
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

    -- 行三态与行文字：锁定不可买、逐级开放、已购拦截；服务端成功回包后行转已购并放出下一级。
    -- 失败方式：三态判错（锁定能买/已购能重买/逐级升级不开放）；行文字带旧括号或漏写原因；
    --           越级与摊位等级不够混成同一句；玩家可见文案出现术语表禁用的「强化」。
    it("test_row_states_lock_buy_and_owned", function()
        local function rowOf(number)
            for _, row in ipairs(ctx.handler:View().rows) do
                if row.number == number then return row end
            end
        end
        -- 钓具页：科技假饵(1) 要 7 级摊，2 级虾池摊只能灰显写原因
        assert.same('locked', rowOf(1).state)
        assert.same('需 7 级摊位', rowOf(1).stateText)
        ctx.handler:SetPage('升级')
        -- 跨真源：行上的越级原因与本地拒绝文案是同一句（LocalShop.FailText.level），界面不另写一份
        assert.same(ctx.localShop.FailText.level, rowOf(32).stateText) -- 背包升级2：越级（当前 0 级）
        assert.same('buy', rowOf(41).state)                    -- 弹容量升级1：逐级可买
        assert.same('', rowOf(41).stateText)
        assert.same('buy', rowOf(51).state)                    -- 近战武器升级1
        ctx.events.ShopResult.OnClientEvent:Fire({ ok = true, number = 51, kind = 'melee', level = 1, price = 50 })
        assert.same('owned', rowOf(51).state)
        assert.same('已购', rowOf(51).stateText)
        assert.same('buy', rowOf(50).state) -- 下一级放开
        ctx.commands = {}
        ctx.handler:Buy(rowOf(51).index) -- 已购不可重买
        assert.same({}, ctx.commands)
        for _, page in ipairs(GameCfg.Shop.Pages) do -- 术语守卫：四页的行文字都不许出现术语表禁用的「强化」
            ctx.handler:SetPage(page)
            for _, row in ipairs(ctx.handler:View().rows) do
                assert.is_nil(row.stateText:find('强化', 1, true), row.name .. ' 的行文字用了「强化」')
            end
        end
        for name, text in pairs(ctx.localShop.ShopText) do -- 文案表（#219 的真源）同样守这一条
            if text:find('强化', 1, true) then fail('文案 ' .. name .. ' 用了「强化」：' .. text) end
        end
    end)

    -- 唯一购买入口（#218）：只有详情区的 BtnShopBuyDetail 会下单，点列表行只换选中（#217）。
    -- 指令一律发商店编号，不发 itemKey（升级行没有 itemKey，发旧键根本买不了）。
    -- 失败方式：行点击也下单（#216 旧行为）；购买按钮没接线（点了没反应）；payload 发 itemKey 或选中项错位。
    it("test_buy_button_is_the_only_entry_and_sends_shop_number", function()
        assert.is_true(ctx.handler:Select(1)) -- 香肠（编号 11，itemKey = sausage）
        ctx.nodes.ShopRow2.OnClicked:Fire()  -- 钓具页第 2 行 = 钓虾竿（编号 12）
        assert.same({}, ctx.commands)
        assert.same(2, ctx.handler:View().selected)
        assert.is_true(Eui.Click(ctx.nodes.BtnShopBuyDetail))
        assert.same({ { action = 'Buy', number = 12, seq = 1 } }, ctx.commands)
        -- 升级行走同一条入口与同一个购买键（编号 41 = 弹容量升级1，200 金币）：这里测的是下单入口，
        -- 余额调到买得起——买不起时按钮会就地变成「去地图商店」（#219），下单路径另有用例覆盖。
        ctx.attributes.FishCoin = 1000
        ctx.events.ItemBarState.OnClientEvent:Fire({})
        ctx.handler:SetPage('升级')
        assert.is_true(ctx.handler:Select(rowIndexOf(ctx.handler:View(), 41)))
        assert.is_true(Eui.Click(ctx.nodes.BtnShopBuyDetail))
        assert.same(41, ctx.commands[2].number)
        assert.is_nil(ctx.commands[2].itemId)
        assert.same(2, ctx.commands[2].seq)
    end)

    -- 金币不足就地引导（#219）：余额买不起选中行时，详情区的购买按钮就地变成「去地图商店」，
    -- 点了落到金币页且**不发购买请求**；余额回来后按钮变回「购买」，点了才下单。
    -- 失败方式：
    --   1. 买不起仍写「购买」→ 点了发出必被服务端拒的请求（玩家被拒两次还不知道出路）；
    --   2. 引导按钮照样下单（或跳外部、关屏），玩家花了冤枉钱或回不来；
    --   3. 余额够了按钮仍是引导（买得起的商品反而买不了）；
    --   4. 买完余额降到价格以下、按钮不跟着变（当场还能点一次必被拒的购买）。
    it("test_insufficient_coin_turns_buy_into_coin_page_guide", function()
        local texts = ctx.localShop.ShopText
        ctx.attributes.FishCoin = 1
        ctx.events.ItemBarState.OnClientEvent:Fire({})    -- 属性刷新：重读余额 1 金币
        assert.is_true(ctx.handler:Select(1))             -- 钓具页第 1 行 = 香肠（编号 11，2 金币）
        local detail = ctx.handler:View().detail
        assert.same(texts.GoPlatformShop, detail.buyText)
        assert.same('coin', detail.buyAction)
        assert.is_true(detail.buyEnabled)                 -- 引导是可点的入口，不是灰按钮
        assert.same(texts.GoPlatformShop, ctx.nodes.LabelShopBuyDetail.Text)
        assert.is_true(Eui.Click(ctx.nodes.BtnShopBuyDetail))
        assert.same({}, ctx.commands)                     -- 这一步没有发出购买请求
        local view = ctx.handler:View()
        assert.same(GameCfg.Shop.Pages[#GameCfg.Shop.Pages], view.page) -- 就地落到金币页
        assert.is_true(view.panels.coin)
        assert.is_nil(view.selected)
        -- 切回商品页、余额也回来：按钮变回「购买」，点了才下单
        ctx.attributes.FishCoin = 100
        ctx.events.ItemBarState.OnClientEvent:Fire({})
        ctx.handler:SetPage('钓具')
        assert.is_true(ctx.handler:Select(1))
        assert.same(texts.Buy, ctx.handler:View().detail.buyText)
        assert.same(texts.Buy, ctx.nodes.LabelShopBuyDetail.Text)
        assert.is_true(Eui.Click(ctx.nodes.BtnShopBuyDetail))
        assert.same({ { action = 'Buy', number = 11, seq = 1 } }, ctx.commands)
        -- 买完余额只剩 1 金币（服务端回包 coinAfter）：按钮当场变回引导，不再发出必被拒的购买
        ctx.commands = {}
        ctx.events.ShopResult.OnClientEvent:Fire({ ok = true, number = 11, price = 2, coinAfter = 1 })
        local after = ctx.handler:View()
        assert.same('1', after.coinText)
        assert.same(texts.GoPlatformShop, after.detail.buyText)
        assert.same('coin', after.detail.buyAction)
        assert.same({}, ctx.commands)
    end)

    -- 选中：点行只选中不下单（可买行与锁定行都能点，已购行不可点见上一条用例）；
    -- 快照逐行暴露 selected；整体重绘（购买回包）后选中的还是同一行。
    -- 失败方式：点行直接下单（#216 旧行为）→ 想看一眼详情就花了钱；选中只活在点击当帧、重绘后丢失；
    --           selected 同时标在多行（下标比较写成「有值即选中」）；点了行节点没接上（没反应）。
    it("test_row_click_selects_without_buying_and_survives_refresh", function()
        ctx.nodes.ShopRow1.OnClicked:Fire() -- 香肠：可买
        assert.same(1, ctx.handler:View().selected)
        assert.same({}, ctx.commands)
        ctx.nodes.ShopRow3.OnClicked:Fire() -- 科技假饵：锁定行也可点（看详情），仍不下单
        assert.same(3, ctx.handler:View().selected)
        assert.same({}, ctx.commands)
        local rows = ctx.handler:View().rows
        assert.same({ false, false, true }, { rows[1].selected, rows[2].selected, rows[3].selected })
        ctx.events.ShopResult.OnClientEvent:Fire({ ok = true, number = 11, price = 2 })
        local after = ctx.handler:View()
        assert.same(3, after.selected)
        assert.same({ false, false, true }, { after.rows[1].selected, after.rows[2].selected, after.rows[3].selected })
        assert.same({}, ctx.commands)
    end)

    -- 详情区（#218）：选中一行后给全决策信息——名字、描述、价格、限购次数；快照与节点文字一致。
    -- 失败方式：详情只给名字、缺描述或限购次数（玩家不知道买什么、还能买几次）；
    --           价格口径与行/货架行不一致（详情价与扣费价对不上）。
    it("test_detail_shows_name_desc_price_and_limit", function()
        assert.is_true(ctx.handler:Select(1)) -- 钓具页第 1 行 = 香肠（编号 11，不限购）
        local detail = ctx.handler:View().detail
        assert.same(11, detail.number)
        assert.same('香肠', detail.name)
        assert.same('香咸可口的香肠，虾子们也喜欢它。', detail.desc)
        assert.same('2', detail.priceText)
        assert.same('不限购', detail.limitText)
        assert.same('', detail.upgradeText)
        assert.is_true(detail.buyEnabled)
        assert.same('香肠', ctx.nodes.LabelShopDetailName.Text)
        assert.same('2', ctx.nodes.LabelShopDetailPrice.Text)
        assert.same('不限购', ctx.nodes.LabelShopDetailLimit.Text)
    end)

    -- 升级类详情（#218）：另给「当前几级、买完升到几级」——决定买不买的关键信息。
    -- 失败方式：升级行不给等级（玩家不知道现在几级、买完到几级）；目标等级写成当前等级。
    it("test_detail_upgrade_row_shows_current_and_target_level", function()
        ctx.handler:SetPage('升级')
        assert.is_true(ctx.handler:Select(rowIndexOf(ctx.handler:View(), 41))) -- 弹容量升级1：0 级 → 1 级
        local detail = ctx.handler:View().detail
        assert.same('弹容量升级1', detail.name)
        assert.same('已购 0 / 1 次', detail.limitText)
        assert.same('当前 0 级，买完升到 1 级', detail.upgradeText)
        assert.same(detail.upgradeText, ctx.nodes.LabelShopDetailUpgrade.Text)
    end)

    -- 空态（#218）：没选中（切页签 / 重开商店）时详情区清空、购买按钮禁用，不留上一条的残留。
    -- 失败方式：切页签后详情区还写着上一页的商品、按钮仍可点（玩家以为还能买到上一页的东西）。
    it("test_detail_empty_state_clears_texts_and_disables_buy", function()
        assert.is_true(ctx.handler:Select(1))
        ctx.nodes['BtnShopPage' .. #GameCfg.Shop.Pages].OnClicked:Fire() -- 金币页：内容区换容器、选中清空
        local detail = ctx.handler:View().detail
        assert.is_nil(detail.number)
        assert.same({ '', '', '', '', '' }, { detail.name, detail.desc, detail.priceText,
            detail.limitText, detail.upgradeText })
        assert.is_false(detail.buyEnabled)
        for _, name in ipairs({ 'LabelShopDetailName', 'LabelShopDetailDesc', 'LabelShopDetailPrice',
            'LabelShopDetailLimit', 'LabelShopDetailUpgrade' }) do
            if ctx.nodes[name].Text ~= '' then fail(name .. ' 空态应清空，实际：' .. ctx.nodes[name].Text) end
        end
        assert.is_true(ctx.nodes.BtnShopBuyDetail.Disabled)
        assert.is_false(ctx.nodes.BtnShopBuyDetail.TouchEnabled) -- 没商品可谈：点下去只会静默，不接收触摸
        ctx.commands = {}
        assert.is_false(Eui.Click(ctx.nodes.BtnShopBuyDetail)) -- 空态不命中，也不发请求
        assert.same({}, ctx.commands)
    end)

    -- #235 购买按钮「看得见、点不动」：Init 的空态把它 Disabled 之后，运行期 TouchEnabled 一直是 false，
    -- 界面渲染成可买也点不中。有选中行时两种状态都要能被真实点按命中——不可买时由 Buy 兜底本地拒绝、
    -- 给出同一条文案，而不是把按钮变成一块点不动的图。
    -- 失败方式：只设 Disabled、不管 TouchEnabled（本单的 bug）；只在初始化时开一次触摸（渲染写 Disabled 又关掉）；
    --           或反过来跟着 Disabled 一起关掉触摸，不可买时点按走不到本地拒绝，玩家连差什么才能买都看不到。
    it("test_buy_button_accepts_touch_in_both_buy_states", function()
        assert.is_true(ctx.handler:Select(1)) -- 香肠：可买
        assert.is_true(ctx.handler:View().detail.buyEnabled)
        assert.is_true(ctx.nodes.BtnShopBuyDetail.TouchEnabled)
        assert.is_true(ctx.handler:Select(3)) -- 科技假饵：锁定，详情区照常给原因
        assert.is_false(ctx.handler:View().detail.buyEnabled)
        assert.is_true(ctx.nodes.BtnShopBuyDetail.TouchEnabled)
    end)

    -- 可选与可买是两个概念（#214 用户故事 8 / 20 / 21）：已购行不可点（买满限购的别让玩家白点）；
    -- 锁定行可点、详情区照常给描述与原因，只是买不了；可买行两者皆真。快照逐行给 selectable / purchasable；
    -- 购买按钮的可触摸另有用例单守（#235）。
    -- 失败方式：把「可买」当成「可选」→ 锁定行点不动，玩家看不出这件商品是什么、差哪一级；
    --           把锁定行当可买（或节点可点）→ 客户端发出必被服务端拒的请求；已购行仍可点（白点）。
    it("test_selectable_and_purchasable_are_independent", function()
        local rows = ctx.handler:View().rows
        assert.same({ true, true, true }, { rows[1].selectable, rows[2].selectable, rows[3].selectable })
        assert.same({ true, true, false }, { rows[1].purchasable, rows[2].purchasable, rows[3].purchasable })
        assert.is_true(ctx.handler:Select(3)) -- 科技假饵：需 7 级摊位，仍可选
        assert.same(3, ctx.handler:View().selected)
        ctx.handler:SetPage('升级')
        local view = ctx.handler:View()
        local leap = view.rows[rowIndexOf(view, 32)] -- 背包升级2：越级（当前 0 级），锁定但可点
        assert.same('locked', leap.state)
        assert.is_true(leap.selectable)
        assert.is_false(leap.purchasable)
        local index = rowIndexOf(view, 51) -- 近战武器升级1：限购 1 次
        assert.is_true(ctx.handler:Select(index))
        assert.is_true(Eui.Click(ctx.nodes.BtnShopBuyDetail))
        assert.same(1, #ctx.commands)
        ctx.events.ShopResult.OnClientEvent:Fire({ ok = true, number = 51, kind = 'melee', level = 1, price = 50 })
        local after = ctx.handler:View()
        assert.same('owned', after.rows[index].state)
        assert.is_false(after.rows[index].selectable) -- 已买满：行不可点
        assert.is_false(after.rows[index].purchasable)
        local other = rowIndexOf(after, 41) -- 弹容量升级1：仍可买
        assert.is_true(ctx.handler:Select(other))
        assert.is_false(ctx.handler:Select(index)) -- 已购行：拒绝，选中不跟着挪
        assert.same(other, ctx.handler:View().selected)
    end)

    -- 锁定行详情（#214 故事 8 / 21）：点了照常选中，详情区给描述、价格与「需 N 级摊位」，
    -- 购买按钮禁用并把原因写在按钮上——玩家知道这件商品是什么、差什么才能买。
    -- 失败方式：锁定行详情只灰不解释（按钮上仍写「购买」）；按钮可点，或点了发出必被拒的请求；
    --           原因写成 reason 码（stand / level）而不是玩家能读懂的话。
    it("test_locked_row_detail_shows_reason_on_disabled_buy_button", function()
        assert.is_true(ctx.handler:Select(3)) -- 科技假饵：需 7 级摊位
        local detail = ctx.handler:View().detail
        assert.same(1, detail.number)
        assert.same('科技假饵', detail.name)
        assert.same('可以在火山岛钓到各种神奇生物的高科技。别吃！', detail.desc)
        assert.same('7', detail.priceText)
        assert.same('需 7 级摊位', detail.buyText) -- 原因写在按钮上
        assert.is_false(detail.buyEnabled)
        assert.same('需 7 级摊位', ctx.nodes.LabelShopBuyDetail.Text)
        assert.is_true(ctx.nodes.BtnShopBuyDetail.Disabled)
        ctx.commands = {}
        assert.is_true(Eui.Click(ctx.nodes.BtnShopBuyDetail)) -- 点了：本地拒绝、同一条文案，不发请求
        assert.same({}, ctx.commands)
        assert.same({ ctx.localShop.FailText.stand }, ctx.notices)
    end)

    -- 服务端拒绝（#218）：不伪成功——金币不动、行不算已购、限购次数与按钮不变。
    -- 失败方式：失败回包也扣本地金币或把行转已购（玩家以为买到了，重试还被客户端自拒）。
    it("test_server_rejection_keeps_coin_and_row_state", function()
        ctx.handler:SetPage('升级')
        local index = rowIndexOf(ctx.handler:View(), 51)
        assert.is_true(ctx.handler:Select(index))
        assert.is_true(Eui.Click(ctx.nodes.BtnShopBuyDetail))
        assert.same(1, #ctx.commands)
        ctx.events.ShopResult.OnClientEvent:Fire({ ok = false, reason = 'coin', number = 51 })
        local view = ctx.handler:View()
        assert.same('77', view.coinText) -- 属性仍是 77：客户端没有自行扣款
        assert.same('buy', view.rows[index].state)
        assert.same('已购 0 / 1 次', view.detail.limitText)
        assert.is_true(view.detail.buyEnabled)
    end)

    -- 购买成功（#218）：金币条取服务端结算后的金币（属性刷新滞后也不停旧数）、行与详情立刻刷新。
    -- 失败方式：金币条等属性刷新才变（当场看不到扣款）；行状态/详情限购次数不刷新；已买满的行仍能点。
    it("test_success_refreshes_coin_row_and_detail_at_once", function()
        ctx.handler:SetPage('升级')
        local index = rowIndexOf(ctx.handler:View(), 51)
        assert.is_true(ctx.handler:Select(index))
        ctx.events.ShopResult.OnClientEvent:Fire({ ok = true, number = 51, kind = 'melee', level = 1,
            price = 50, coinAfter = 27 })
        local view = ctx.handler:View()
        assert.same('27', view.coinText)
        assert.same('27', ctx.nodes.LabelCurCoin.Text)
        assert.same('owned', view.rows[index].state)
        assert.is_false(view.rows[index].selectable)
        assert.same('已购 1 / 1 次', view.detail.limitText)
        assert.is_false(view.detail.buyEnabled)
        assert.same('buy', view.rows[rowIndexOf(view, 50)].state) -- 下一级放开
    end)

    -- 本地拒绝（#218）：不可买状态在发请求前就拒绝，但要用同一份文案说明原因，不许静默；
    -- 文案只来自 LocalShop.FailText，界面里不再写第二套。
    -- 失败方式：点了没反应（玩家不知道为什么卖不了他）；本地拒绝照样发请求（必然被服务端拒）；
    --           界面自己另写一套文案（服务端改了原因，界面还是旧的）。
    it("test_blocked_buy_stays_local_and_shares_one_fail_text", function()
        ctx.handler:SetPage('升级')
        ctx.handler:Buy(rowIndexOf(ctx.handler:View(), 32)) -- 背包升级2：越级
        assert.same({}, ctx.commands)
        assert.same({ ctx.localShop.FailText.level }, ctx.notices)
        ctx.notices = {}
        ctx.handler:SetPage('钓具')
        ctx.handler:Buy(3) -- 科技假饵：摊位等级不够
        assert.same({}, ctx.commands)
        assert.same({ ctx.localShop.FailText.stand }, ctx.notices)
        if not ctx.notices[1]:find('更高等级摊位', 1, true) then
            fail('摊位等级不够要写成玩家能读懂的话，实际：' .. tostring(ctx.notices[1]))
        end
    end)

    -- 金币页降级（#219 按新结构重写 #218 的旧用例：旧断言只查提示子串，看不出「发了请求 / 伪成功 / 卡住」）：
    -- 平台能力缺失 / 打开抛错都只提示、不发请求、不伪成功，页签照常切换（不卡死在金币页）；
    -- 打开成功时请求归平台模块，本屏只给中性提示、不承诺买到了。
    -- 失败方式：
    --   1. 平台缺失或抛错时记成已打开（伪成功）或照样发请求；
    --   2. 提示留在旧值，或金币页把页签占死（切不回其它分页）；
    --   3. 金币页写出汇率、价目换算或平台商品 ID（编造后台参数）；
    --   4. 界面另写一套文案（LocalShop 里的文案改了，界面还是旧句子）。
    it("test_coin_page_degrades_without_faking_success", function()
        local texts = ctx.localShop.ShopText
        ctx.handler:SetPage('金币')
        local view = ctx.handler:View()
        assert.same({}, numbersOf(view.rows))          -- 金币页没有商品行
        assert.is_true(view.panels.coin)
        assert.is_false(view.panels.list)
        assert.is_false(view.panels.detail)            -- 金币页不叠详情区（#218）
        assert.is_nil(view.detail.number)
        assert.same(texts.CoinPageHint, view.coinHint) -- 进入金币页的默认提示
        assert.same('idle', view.coinState)

        -- 平台能力缺失：只提示、不发请求、屏不关
        ctx.nodes.BtnOpenPlatformShop.OnClicked:Fire()
        view = ctx.handler:View()
        assert.same('unavailable', view.coinState)
        assert.same(texts.PlatformUnavailable, view.coinHint)
        assert.same(view.coinHint, ctx.nodes.LabelCoinPageHint.Text)
        assert.same({}, ctx.commands)
        assert.is_true(ctx.handler.IsOpen)

        -- 页签照常切回：不卡死在金币页
        ctx.handler:SetPage('钓具')
        assert.same('钓具', ctx.handler:View().page)
        assert.same(11, numbersOf(ctx.handler:View().rows)[1])

        -- 打开抛错：记失败，错误串只进日志、不拼进玩家文案
        ctx.handler:SetPage('金币')
        _G.PlatformShop = { Open = function() error('平台未接入') end }
        ctx.nodes.BtnOpenPlatformShop.OnClicked:Fire()
        view = ctx.handler:View()
        assert.same('failed', view.coinState)
        assert.same(texts.PlatformOpenFailed, view.coinHint)
        assert.same({}, ctx.commands)
        ctx.handler:SetPage('武器')
        assert.same('武器', ctx.handler:View().page)

        -- 打开成功：请求由平台模块发出（本屏不发购买请求），提示中性、不承诺买到
        ctx.handler:SetPage('金币')
        local opened = 0
        _G.PlatformShop = { Open = function() opened = opened + 1 end }
        ctx.nodes.BtnOpenPlatformShop.OnClicked:Fire()
        view = ctx.handler:View()
        assert.same(1, opened)
        assert.same('opened', view.coinState)
        assert.same(texts.PlatformOpened, view.coinHint)
        assert.same({}, ctx.commands)

        -- 不编造数据：金币页可见文案里没有汇率、价目换算与平台商品 ID
        for _, text in ipairs({ texts.CoinPageHint, texts.PlatformUnavailable, texts.PlatformOpenFailed,
            texts.PlatformOpened }) do
            if text:find('%d') then fail('金币页文案不该出现数字（汇率/价目）：' .. text) end
            for _, banned in ipairs({ '汇率', '兑换', '折', '商品ID', 'goodsId' }) do
                if text:find(banned, 1, true) then fail('金币页文案不该出现「' .. banned .. '」：' .. text) end
            end
        end
    end)

    -- 重开商店：回到钓具页，不残留选中与上一条详情（关屏不做事，复位靠 OpenScreen）
    it("test_reopen_resets_to_first_page_without_selection", function()
        ctx.handler:SetPage('升级')
        ctx.handler:Select(2)
        ctx.handler:CloseScreen()
        ctx.handler:OpenScreen()
        local view = ctx.handler:View()
        assert.same('钓具', view.page)
        assert.is_nil(view.selected)
        assert.is_nil(view.detail.number) -- 详情区跟着空态走（#218）
        assert.is_false(view.detail.buyEnabled)
        assert.same(11, numbersOf(view.rows)[1])
        assert.same('77', view.coinText)
    end)

    -- 归属登记：商品行一行一个登记项，页签下划线一页一个；行内子节点随行递归销毁。
    -- 换 RootNode 再 Init 时上一轮整体销毁，只留新一轮装饰，重开渲染后再补新一轮商品行。
    it("test_rebuild_clears_registry_and_keeps_one_owner", function()
        local decorations = #GameCfg.Shop.Pages
        assert.same(#ctx.handler:View().rows + decorations, OwnedUnits.Count(ctx.handler))
        local previous = ctx.created
        ctx.created = {}
        ctx.handler.RootNode = ctx.makeRoot() -- 换 RootNode 重建：同名节点都是新树上的
        ctx.handler:Init()
        assert.same(decorations, OwnedUnits.Count(ctx.handler))
        for _, node in ipairs(previous) do
            assert.is_true(node.Destroyed, '上一轮运行期建点应被销毁')
        end
        ctx.handler:OpenScreen()
        assert.same(#ctx.handler:View().rows + decorations, OwnedUnits.Count(ctx.handler))
    end)
end)
