-- 条款 7-17（docs/acceptance/07-economy-and-shop.md）：一次购买在同一次服务端结算中完成扣费与发奖：
-- 余额不足或库存无可用格时整体失败，既不扣金币也不发物品。
-- 只走业务入口：server/main.lua 的 MgrMap 里注册的三个管理器——MgrShop（购买请求）、MgrPlayerData
-- （金币账本与库存）、MgrGM（调试发金币，把金币发到手上的唯一业务路径），三者按 main.lua 的接线注入
-- 同一份协作关系；交互点距离用替身置真。不执行 main.lua 本体（它一开头就要完整引擎服务）。
-- 只断言玩家可观察的结果：ShopResult 回包（客户端据此显示余额与已购）与库存件数。
-- 失败方式（先列后写）：
--   0. main.lua 的接线被改掉（商店不再拿玩家数据 / 存档）→ 本文件先红，逼人复核断言；
--   1. 余额不足却被放行（扣成负数或白送），或先发货后发现扣不动；
--   2. 库存无空格时仍扣金币（扣了钱没给货）；
--   3. 失败回包里带上已结算的余额（把没落地的结果当结算结果发出去）；
--   4. 成功的一笔只落了一半：金币变了、物品没进库存（或反过来）。
local GameCfg = require('common.GameCfg')

local WIRING = {
    'MgrMap.MgrShop.PlayerData = MgrMap.MgrPlayerData',
    'MgrMap.MgrShop.Save = MgrMap.MgrSave',
    'MgrMap.MgrShop.Interact = MgrMap.MgrInteract',
    'MgrGM = require("server.Mgr.MgrGM")',
}

local function assert_wiring()
    local handle = assert(io.open('server/main.lua', 'rb'), '读不到 server/main.lua')
    local source = handle:read('a')
    handle:close()
    for _, line in ipairs(WIRING) do
        assert.is_truthy(source:find(line, 1, true), 'server/main.lua 里找不到本文件复现的接线：' .. line)
    end
end

local function signal()
    local handlers = {}
    return {
        Connect = function(_, fn)
            handlers[#handlers + 1] = fn
            return { Disconnect = function() end }
        end,
    }
end

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
    local function reset()
        for name in pairs(posts) do posts[name] = nil end
    end
    return { posts = posts, reset = reset, GetRE = function(_, name) return channel(name) end }
end

-- 货架行 14 = 新手鱼竿（售价 5 金币，最低商店等级 1，每人上限 0）：它占库存一格，
-- 又不像鱼饵那样「计数库存无上限」、也不像武器那样「独立库存不占格」，
-- 所以余额不足与库存满格两条失败路径都能在最低等级摊位上走到。号与价都取自 GameCfg.Shop.Goods。
local ROW, ROW_PRICE, ROW_ITEM = 14, 5, 'starterRod'

describe('条款 7-17 商店购买的扣费与发奖在一次结算里落地', function()
    local ctx
    local saved

    local function drain()
        while #ctx.queue > 0 do table.remove(ctx.queue, 1)() end
    end

    local function replies()
        return ctx.re.posts.ShopResult or {}
    end

    local function lastReply()
        local list = replies()
        return list[#list]
    end

    before_each(function()
        assert_wiring()
        saved = { Debug = GameCfg.Debug, REUtil = rawget(_G, 'REUtil'), game = rawget(_G, 'game') }
        -- 调试开关只用来发金币（GM 是调试入口）；本条款判的是商店结算，与调试开关无关。
        GameCfg.Debug = { Enabled = true }
        ctx = { now = 1000, queue = {}, seq = 0 }
        ctx.re = channels()
        rawset(_G, 'REUtil', { GetRE = ctx.re.GetRE, CheckRECD = function() return false end })
        ctx.values = {}
        local store = {
            GetAsync = function(_, key) return ctx.values[key] end,
            UpdateAsync = function(_, key, transform)
                local value = transform(ctx.values[key])
                if value then ctx.values[key] = value end
                return value
            end,
            SetAsync = function(_, key, value) ctx.values[key] = value end,
        }
        rawset(_G, 'game', { GetService = function(_, name)
            if name == 'Task' then
                return { Spawn = function(_, fn) ctx.queue[#ctx.queue + 1] = fn end, Wait = function() end }
            end
            if name == 'DataStoreService' then return { GetDataStore = function() return store end } end
            if name == 'World' then return { GetServerTime = function() return ctx.now end } end
            if name == 'Players' then return { GetPlayers = function() return {} end } end
        end })
        ctx.save = assert(loadfile('server/Mgr/MgrSave.lua'))()
        ctx.playerData = assert(loadfile('server/Mgr/MgrPlayerData.lua'))()
        ctx.shop = assert(loadfile('server/Mgr/MgrShop.lua'))()
        ctx.gm = assert(loadfile('server/Mgr/MgrGM.lua'))()
        -- 与 server/main.lua 的 MgrMap 接线同形：商店读玩家数据、结算走存档、GM 读玩家数据。
        ctx.save.PlayerData = ctx.playerData
        ctx.playerData.Save = ctx.save
        ctx.shop.Save, ctx.shop.PlayerData, ctx.gm.PlayerData = ctx.save, ctx.playerData, ctx.playerData
        -- 交互点距离：本条款判的是结算账，不判距离，范围置真让请求进到结算。
        ctx.shop.Interact = { InRange = function() return true end }
        ctx.me = {
            UserId = 7201,
            CharacterAdded = signal(),
            CharacterRemoving = signal(),
            SetAttribute = function() end,
        }
        ctx.playerData:OnPlayerAdded(ctx.me)
        drain()
        ctx.data = ctx.playerData:GetDataInst(ctx.me)
        assert(ctx.save:SaveExplicit(ctx.me.UserId, ctx.data, function(ok) assert(ok) end))
        drain()
        ctx.re.reset()
        ctx.baseline = ctx.data:ItemCount(ROW_ITEM)
    end)

    after_each(function()
        GameCfg.Debug = saved.Debug
        rawset(_G, 'REUtil', saved.REUtil)
        rawset(_G, 'game', saved.game)
        ctx = nil
    end)

    local function coin()
        return ctx.data.Data.FishCoin
    end

    local function grant(amount)
        assert.is_true(ctx.gm:Handle(ctx.me, { action = 'Coin', amount = amount }))
    end

    -- 只判玩家可观察的结果：Handle 的返回值是「请求是否被受理」，成功与被业务拒绝都在 ShopResult 里。
    local function buy()
        ctx.seq = ctx.seq + 1
        ctx.shop:Handle(ctx.me, { action = 'Buy', number = ROW, seq = ctx.seq })
        drain()
        local reply = lastReply()
        assert.is_table(reply, '购买请求没有回包')
        return reply
    end

    it('成功的一笔同时扣金币与发物品', function()
        grant(1000)
        local reply = buy()
        assert.is_true(reply.ok, reply.reason)
        assert.same(1000, reply.coinBefore)
        assert.same(1000 - ROW_PRICE, reply.coinAfter)
        assert.same(ctx.baseline, reply.itemBefore)
        assert.same(ctx.baseline + 1, reply.itemAfter)
        assert.same(1000 - ROW_PRICE, coin())
        assert.same(ctx.baseline + 1, ctx.data:ItemCount(ROW_ITEM), '买到的物品必须真的进库存')
    end)

    it('余额不足时整体失败：不扣金币也不发物品', function()
        assert.same(0, coin()) -- 新档起手没有金币
        local reply = buy()
        assert.is_false(reply.ok)
        assert.same('coin', reply.reason)
        assert.is_nil(reply.coinAfter, '被拒的请求不得回已结算余额')
        assert.is_nil(reply.itemAfter, '被拒的请求不得回已发件数')
        assert.same(0, coin(), '失败不得扣金币')
        assert.same(ctx.baseline, ctx.data:ItemCount(ROW_ITEM), '失败不得发物品')
    end)

    it('库存无可用格时整体失败：不扣金币也不发物品', function()
        grant(1000)
        while ctx.data:AddItem('carp') do end -- 道具栏与背包全部占满
        local reply = buy()
        assert.is_false(reply.ok)
        assert.same('full', reply.reason)
        assert.is_nil(reply.coinAfter)
        assert.same(1000, coin(), '库存满格失败不得扣金币')
        assert.same(ctx.baseline, ctx.data:ItemCount(ROW_ITEM), '库存满格失败不得发物品')
    end)
end)
