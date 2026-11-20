-- 条款 7-25（docs/acceptance/07-economy-and-shop.md）：金币页用共享配置里的占位汇率与占位商品 ID
-- 走通购买与到账；真实汇率与商品 ID 由平台后台交付后只替换配置，不改玩法判定。
-- 条款 7-16（同一分片）：金币页商品走平台购买，不参与金币余额的扣减结算。
-- 只走业务入口：server/main.lua 的 MgrMap 里注册的两个管理器——MgrPlatform（金币页入口与占位支付通道）
-- 与 MgrPlayerData（金币账本）；接线按 main.lua 源码子串核对（不执行 main.lua 本体：它一开头就要完整
-- 引擎服务，原生测试里起不来）。
-- 只断言玩家可观察的结果：PlatformResult 回包（客户端据此渲染报价、确认面板与到账提示）与 FishCoin
-- 同步属性（HUD 与商店显示余额的数据源）。
-- 失败方式（先列后写）：
--   0. main.lua 的接线被改掉（平台适配层不再拿玩家数据 / 存档）→ 本文件先红，逼人复核黑盒断言；
--   1. 占位商品 ID 或占位汇率不在共享配置里，金币页在占位通道下仍回 unavailable（购买走不通）；
--   2. 到账金币不按共享配置的占位汇率算（写死金币数、或换成别的汇率）；
--   3. 金币页购买扣了金币余额（把平台购买当成本地金币消费）；
--   4. 取消或超时也到账（发奖单边落地，扣费与发奖不对称）；
--   5. 占位确认重复提交多到账一次；
--   6. 占位通道被调试闸门挡住：生产构建（Debug 关）只剩测试驱动器一条路。
local GameCfg = require('common.GameCfg')

-- 前提守卫：本文件复现的是 main.lua 的接线，而不是自造一套协作关系。
local WIRING = {
    'MgrMap.MgrPlatform.Save = MgrMap.MgrSave',
    'MgrMap.MgrPlatform.PlayerData = MgrMap.MgrPlayerData',
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
    local function reset()
        for name in pairs(posts) do posts[name] = nil end
    end
    return { posts = posts, reset = reset, GetRE = function(_, name) return channel(name) end }
end

-- 占位报价：金币小袋 6 元一档，占位汇率 100 金币 / 元 → 到账 600 金币。
-- 单价、汇率与商品 ID 都写在共享配置 GameCfg.Platform.Placeholder.CoinPage 里；真实汇率与真实商品 ID
-- 交付后只改那份配置（以及本行的期望值），玩法判定一行不动。
local COIN_GOODS = 'coinPouch'

describe('条款 7-25 / 7-16 金币页占位购买与到账', function()
    local ctx
    local saved

    local function drain()
        while #ctx.queue > 0 do table.remove(ctx.queue, 1)() end
    end

    local function replies()
        return ctx.re.posts.PlatformResult or {}
    end

    local function lastReply()
        local list = replies()
        return list[#list]
    end

    local function countAction(action)
        local n = 0
        for _, reply in ipairs(replies()) do
            if reply.action == action then n = n + 1 end
        end
        return n
    end

    before_each(function()
        assert_wiring()
        saved = { Debug = GameCfg.Debug, REUtil = rawget(_G, 'REUtil'), game = rawget(_G, 'game'),
            PlaceholderEnabled = GameCfg.Platform.Placeholder.Enabled }
        -- #249 占位闸门：占位通道只在调试构建（或发布构建显式 AllowInPublish）下可用。
        -- 本文件显式打开调试开关，证的是「占位路径可用」，不是「发布构建可用」——
        -- 发布构建默认关闭的那条断言在 spec/17 的平台边界用例里。
        GameCfg.Debug = { Enabled = true }
        GameCfg.Platform.Placeholder.Enabled = true
        ctx = { now = 1000, queue = {}, attributes = {} }
        ctx.re = channels()
        rawset(_G, 'REUtil', { GetRE = ctx.re.GetRE, CheckRECD = function() return false end })
        local store = {
            GetAsync = function(_, key) return ctx.values[key] end,
            UpdateAsync = function(_, key, transform)
                local value = transform(ctx.values[key])
                if value then ctx.values[key] = value end
                return value
            end,
            SetAsync = function(_, key, value) ctx.values[key] = value end,
        }
        ctx.values = {}
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
        ctx.platform = assert(loadfile('server/Mgr/MgrPlatform.lua'))()
        -- 与 server/main.lua 的 MgrMap 接线同形：适配层读玩家数据、结算走存档。
        ctx.save.PlayerData, ctx.playerData.Save = ctx.playerData, ctx.save
        ctx.platform.Save, ctx.platform.PlayerData = ctx.save, ctx.playerData
        ctx.platform.Now = function() return ctx.now end
        ctx.platform:Start()
        ctx.me = {
            UserId = 7101,
            CharacterAdded = signal(),
            CharacterRemoving = signal(),
            SetAttribute = function(_, key, value) ctx.attributes[key] = value end,
        }
        ctx.playerData:OnPlayerAdded(ctx.me)
        drain()
        ctx.data = ctx.playerData:GetDataInst(ctx.me)
        assert(ctx.save:SaveExplicit(ctx.me.UserId, ctx.data, function(ok) assert(ok) end))
        drain()
        ctx.re.reset()
    end)

    after_each(function()
        GameCfg.Debug = saved.Debug
        GameCfg.Platform.Placeholder.Enabled = saved.PlaceholderEnabled
        rawset(_G, 'REUtil', saved.REUtil)
        rawset(_G, 'game', saved.game)
        ctx = nil
    end)

    local function coin()
        return ctx.data.Data.FishCoin
    end

    local function buyCoin()
        assert.is_true(ctx.platform:HandleAction(ctx.me, { action = 'BuyCoin', goods = COIN_GOODS }))
        drain()
    end

    local function confirm(outcome)
        local accepted = ctx.platform:HandleAction(ctx.me, { action = 'PlaceholderOutcome', outcome = outcome })
        drain()
        return accepted
    end

    it('金币页报出占位商品 ID 与占位汇率，并注明不发放真实付费权益', function()
        assert.is_true(ctx.platform:HandleAction(ctx.me, { action = 'OpenCoinShop' }))
        local shop = lastReply()
        assert.is_true(shop.ok, shop.reason)
        assert.same('CoinShop', shop.action)
        local offer = shop.offers and shop.offers[1]
        assert.is_not_nil(offer, '金币页没有报价')
        assert.is_truthy(offer.goodsId:find('^placeholder%.goods%.') ~= nil,
            '占位商品 ID 必须走占位前缀，实际：' .. tostring(offer.goodsId))
        assert.same(100, shop.rate) -- 共享配置的占位汇率：100 金币 / 元
        assert.same(6, offer.price) -- 报价单价 6 元
        assert.same(600, offer.coin) -- 6 元 × 100 金币 / 元
        assert.is_truthy(shop.notice:find('不发放真实付费权益', 1, true) ~= nil, '缺少占位口径提示')
    end)

    it('购买先开占位支付通道，确认前不到账', function()
        buyCoin()
        local opened = lastReply()
        assert.same('PlaceholderFlow', opened.action)
        assert.is_true(opened.open)
        assert.same(COIN_GOODS, opened.key)
        assert.is_truthy(opened.goodsId:find('^placeholder%.goods%.') ~= nil, '通道没带占位商品 ID')
        assert.is_truthy(opened.notice:find('不发放真实付费权益', 1, true) ~= nil)
        assert.same(0, coin(), '确认前不得改金币余额')
        assert.same(0, countAction('CoinGrant'), '确认前不得到账')
    end)

    it('确认后按占位汇率到账，且不扣金币余额', function()
        buyCoin()
        assert.is_true(confirm('success'))
        local grant = lastReply()
        assert.same('CoinGrant', grant.action)
        assert.is_true(grant.ok)
        assert.same(600, grant.coin) -- 6 元 × 100 金币 / 元
        assert.same(0, grant.coinBefore, '金币页不参与金币余额的扣减结算')
        assert.same(600, grant.coinAfter)
        assert.same(600, coin())
        assert.same(600, ctx.attributes.FishCoin, '客户端可见余额必须与服务端一致')
    end)

    it('取消不到账，也不残留待结算通道', function()
        buyCoin()
        assert.is_true(confirm('cancel'))
        local reply = lastReply()
        assert.is_false(reply.ok)
        assert.same('cancel', reply.reason)
        assert.same(0, coin())
        assert.same(0, countAction('CoinGrant'))
        assert.is_false(ctx.platform:HasFlow(ctx.me))
        buyCoin() -- 不残留半截状态：下一次购买仍能开通道
        assert.same('PlaceholderFlow', lastReply().action)
    end)

    it('超时按取消结算，不到账', function()
        buyCoin()
        ctx.now = ctx.now + GameCfg.Platform.FlowTimeoutSec
        ctx.platform:Update()
        drain()
        local reply = lastReply()
        assert.is_false(reply.ok)
        assert.same('timeout', reply.reason)
        assert.same(0, coin())
        assert.same(0, countAction('CoinGrant'))
        assert.is_false(ctx.platform:HasFlow(ctx.me))
    end)

    it('重复确认只到账一次', function()
        buyCoin()
        assert.is_true(confirm('success'))
        assert.is_false(confirm('success'), '没有在飞通道时确认必须被拒')
        assert.same(600, coin())
        assert.same(1, countAction('CoinGrant'))
    end)

    it('占位通道关闭时金币页明确不可用', function()
        GameCfg.Platform.Placeholder.Enabled = false
        ctx.platform:HandleAction(ctx.me, { action = 'OpenCoinShop' })
        local shop = lastReply()
        assert.is_false(shop.ok)
        assert.same('unavailable', shop.reason)
        assert.is_nil(shop.offers)
    end)
end)
