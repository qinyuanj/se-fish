-- 条款 7-11（docs/acceptance/07-economy-and-shop.md）：每人上限为 1 的商品每档只能购买一次；
-- 上限为 0 表示不限购。
-- 只走业务入口：进入的是 server/main.lua 的 **MgrMap 里注册的管理器**——MgrShop（购买请求）、
-- MgrPlayerData（玩家数据）、MgrGM（调试发金币），三者按 main.lua 的接线注入同一份协作关系；
-- 交互点距离用替身置真。**不执行 main.lua 本体**：它一开头就要完整引擎服务
-- （common/ZoneMarkers.lua 那一步就起不来），所以在原生测试里只能读它的源码核对接线（见 assert_wiring）。
-- 只断言玩家可观察的结果：ShopResult 回包载荷（客户端据此显示余额与已购）与库存件数。
-- 失败方式（先列后写）：
--   0. main.lua 的接线被改掉（商店不再拿玩家数据/交互点，或 MgrGM 不再注册）：本文件先红，逼人复核断言；
--   1. 上限为 1 的商品能被买第二次（限购没生效，或结算绕过了限购）；
--   2. 第二次被拒但金币照扣（扣了钱没给货）；
--   3. 上限为 0 的商品被当成限购、只能买一次（把 0 误解成「不许买」）。
local GameCfg = require('common.GameCfg')

-- 前提守卫：本文件复现的是 main.lua 的接线，而不是自造一套协作关系。
-- 三个管理器怎么互相注入写死在 server/main.lua 的 MgrMap 段，这里按源码子串核对；
-- 接线一改（换注入对象、删掉 MgrGM 注册），这条断言先红，逼人回来复核黑盒断言。
local WIRING = {
    'MgrMap.MgrShop.PlayerData = MgrMap.MgrPlayerData',
    'MgrMap.MgrShop.Interact = MgrMap.MgrInteract',
    'MgrGM = require("server.Mgr.MgrGM")',
}

local function assert_wiring()
    local handle = assert(io.open('server/main.lua', 'rb'), '读不到 server/main.lua')
    local source = handle:read('a')
    handle:close()
    for _, line in ipairs(WIRING) do
        assert.is_truthy(source:find(line, 1, true),
            'server/main.lua 里找不到本文件复现的接线：' .. line)
    end
end

-- 引擎侧信号替身：MgrPlayerData 只用到 Connect，回调由测试自己驱动。
local function signal()
    local handlers = {}
    return {
        Connect = function(_, fn)
            handlers[#handlers + 1] = fn
            return { Disconnect = function() end }
        end,
    }
end

-- REUtil 替身：按通道名收 FireClient 的载荷，就是客户端会收到的推送。
local function channels()
    local posts, registry = {}, {}
    local function channel(name)
        if not registry[name] then
            registry[name] = {
                FireClient = function(_, _, payload)
                    posts[name] = posts[name] or {}
                    table.insert(posts[name], payload)
                end,
                OnServerEvent = { Connect = function() end },
            }
        end
        return registry[name]
    end
    return { posts = posts, GetRE = function(_, name) return channel(name) end }
end

-- 货架行号：51 = 近战武器升级第 1 级（每人上限 1，售价 50，最低商店等级 1）；
-- 13 = 普通鱼饵（每人上限 0 表示不限购，售价 1，最低商店等级 1）。号与价都取自 GameCfg.Shop.Goods。
local LIMITED_ROW, UNLIMITED_ROW = 51, 13

describe('条款 7-11 商店限购', function()
    local ctx

    before_each(function()
        assert_wiring()
        ctx = { seq = 0, outcome = {} }
        ctx.savedREUtil = rawget(_G, 'REUtil')
        ctx.re = channels()
        _G.REUtil = { GetRE = ctx.re.GetRE }
        ctx.shop = assert(loadfile('server/Mgr/MgrShop.lua'))()
        ctx.playerData = assert(loadfile('server/Mgr/MgrPlayerData.lua'))()
        ctx.gm = assert(loadfile('server/Mgr/MgrGM.lua'))()
        -- 与 server/main.lua 的 MgrMap 接线同形：商店读玩家数据、GM 读玩家数据。
        ctx.shop.PlayerData = ctx.playerData
        ctx.gm.PlayerData = ctx.playerData
        -- 交互点距离：本条款判的是限购账，不判距离，范围置真让请求进到结算。
        ctx.shop.Interact = { InRange = function() return true end }
        -- 玩家对象只给业务真正用到的成员：进世界信号与同步金币属性（客户端 HUD 的数据源）。
        ctx.me = {
            UserId = 7001,
            CharacterAdded = signal(),
            CharacterRemoving = signal(),
            SetAttribute = function() end,
        }
        -- 进世界：main.lua 的 MgrSave.OnReady 之后由 MgrPlayerData 建数据实例。
        ctx.playerData:OnPlayerAdded(ctx.me)
        -- 买得起：调试入口是把金币发到手上的唯一业务路径。
        assert.is_true(ctx.gm:Handle(ctx.me, { action = 'Coin', amount = 1000 }))
    end)

    after_each(function()
        _G.REUtil = ctx.savedREUtil
    end)

    local function buy(row)
        ctx.seq = ctx.seq + 1
        ctx.shop:Handle(ctx.me, { action = 'Buy', number = row, seq = ctx.seq })
        local replies = ctx.re.posts.ShopResult or {}
        return replies[#replies]
    end

    it('上限为 1 的商品买过一次后再买被拒，且不再扣金币', function()
        local first = buy(LIMITED_ROW)
        assert.is_true(first.ok, first.reason)
        assert.same(1000, first.coinBefore)
        assert.same(950, first.coinAfter, '第一次购买应扣掉售价')
        assert.same('Upgrade', first.action)

        local second = buy(LIMITED_ROW)
        assert.is_false(second.ok, '上限为 1 的商品第二次购买必须被拒')
        assert.same('limit', second.reason)
        assert.is_nil(second.coinAfter, '被拒的请求不得结算金币')

        -- 换个商品再买一次：余额仍是 950，证明上一次被拒时什么都没扣。
        local follow = buy(UNLIMITED_ROW)
        assert.is_true(follow.ok, follow.reason)
        assert.same(950, follow.coinBefore, '被拒的那次不得扣掉金币')
        assert.same(949, follow.coinAfter)
    end)

    it('上限为 0 的商品不限购，可以连续购买', function()
        -- 起始库存由调试发放决定（进图白送若干鱼饵），所以件数只断言增量，不钉绝对值。
        local first = buy(UNLIMITED_ROW)
        assert.is_true(first.ok, first.reason)
        assert.same(1000, first.coinBefore)
        assert.same(999, first.coinAfter)
        assert.same(first.itemBefore + 1, first.itemAfter, '第一次购买应真的发一件')

        local second = buy(UNLIMITED_ROW)
        assert.is_true(second.ok, second.reason)
        assert.same(999, second.coinBefore)
        assert.same(998, second.coinAfter)
        assert.same(first.itemAfter, second.itemBefore)
        assert.same(first.itemAfter + 1, second.itemAfter, '不限购的商品第二次购买应再发一件')
    end)
end)
