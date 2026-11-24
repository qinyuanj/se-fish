local GameCfg = require('common.GameCfg')
local EconomyWorld = require('tests.support.economy_world')

local COIN_GOODS = 'coinPouch'

describe('条款 7-25 / 7-16 金币页占位支付与到账', function()
    local world, savedDebug, savedEnabled, savedAllow

    local function action(payload)
        assert.is_true(world:platformAction(payload))
    end

    local function buy(seq)
        action({ action = 'BuyCoin', goods = COIN_GOODS, seq = seq })
    end

    before_each(function()
        savedDebug, savedEnabled, savedAllow = GameCfg.Debug,
            GameCfg.Platform.Placeholder.Enabled, GameCfg.Platform.Placeholder.AllowInPublish
        world = EconomyWorld.new()
        GameCfg.Debug = { Enabled = true }
        GameCfg.Platform.Placeholder.Enabled = true
    end)

    after_each(function()
        if world then world:tearDown() end
        GameCfg.Debug = savedDebug
        GameCfg.Platform.Placeholder.Enabled = savedEnabled
        GameCfg.Platform.Placeholder.AllowInPublish = savedAllow
        world = nil
    end)

    it('金币页报出占位商品 ID 与占位汇率，并注明不发放真实付费权益', function()
        action({ action = 'OpenCoinShop' })
        local reply = world:lastResult('PlatformResult')
        assert.is_true(reply.ok)
        assert.same('CoinShop', reply.action)
        assert.is_table(reply.offers)
        assert.is_true(#reply.offers > 0)
        local offer = reply.offers[1]
        assert.is_truthy(tostring(offer.goodsId):find('^placeholder%.goods%.') ~= nil)
        assert.is_truthy(offer.coin > 0)
        assert.same(GameCfg.Platform.Placeholder.CoinPage.CoinPerUnit, reply.rate)
        assert.is_truthy(tostring(reply.notice):find('不发放真实付费权益', 1, true) ~= nil)
    end)

    it('购买先开占位支付通道，确认前不到账', function()
        local before = world.data.Data.FishCoin
        buy(1)
        assert.same(before, world.data.Data.FishCoin)
        local opened = world:lastResult('PlatformResult')
        assert.same('PlaceholderFlow', opened.action)
        assert.is_true(opened.open)
        assert.is_true(world.platform:HasFlow(world.player))
    end)

    it('确认后按占位汇率到账，且不扣金币余额', function()
        buy(1)
        local before = world.data.Data.FishCoin
        world:resolvePlatform('success')
        local reply = world:lastResult('PlatformResult')
        assert.is_true(reply.ok)
        assert.same('CoinGrant', reply.action)
        assert.same(COIN_GOODS, reply.goods)
        assert.is_true(reply.coin > 0)
        assert.same(before + reply.coin, world.data.Data.FishCoin)
        assert.same(reply.coin, reply.coinAfter - reply.coinBefore)
    end)

    it('到账重放只回执、只到账一次', function()
        buy(1)
        world:resolvePlatform('success')
        local reply = world:lastResult('PlatformResult')
        local after = world.data.Data.FishCoin
        world:clearEvents()
        world:reconnect()
        assert.is_true(world:platformAction({ action = 'Query', seq = 2, requestId = reply.requestId }))
        assert.same(after, world.data.Data.FishCoin)
        local replay = world:lastResult('PlatformResult')
        assert.is_true(replay.ok)
        assert.same('CoinGrant', replay.action)
        assert.same(after, replay.coinAfter)
    end)

    it('取消不到账，也不残留待结算通道', function()
        buy(1)
        local before = world.data.Data.FishCoin
        world:resolvePlatform('cancel')
        assert.same(before, world.data.Data.FishCoin)
        assert.is_false(world.platform:HasFlow(world.player))
        assert.same('cancel', world:lastResult('PlatformResult').reason)
    end)

    it('超时按取消结算，不到账', function()
        buy(1)
        local before = world.data.Data.FishCoin
        world.now = world.now + GameCfg.Platform.FlowTimeoutSec + 1
        world.platform:Update()
        world:drain()
        assert.same(before, world.data.Data.FishCoin)
        assert.same('timeout', world:lastResult('PlatformResult').reason)
        assert.is_false(world.platform:HasFlow(world.player))
    end)

    it('重复确认只到账一次', function()
        buy(1)
        world:resolvePlatform('success')
        local after = world.data.Data.FishCoin
        assert.is_false(world.platform:ResolvePlaceholder(world.player, 'success'))
        world:drain()
        assert.same(after, world.data.Data.FishCoin)
    end)

    it('占位通道关闭时金币页明确不可用', function()
        GameCfg.Platform.Placeholder.Enabled = false
        assert.is_false(world:platformAction({ action = 'OpenCoinShop' }))
        local reply = world:lastResult('PlatformResult')
        assert.is_false(reply.ok)
        assert.same('CoinShop', reply.action)
        assert.same('unavailable', reply.reason)
        assert.is_nil(reply.offers)
    end)
end)
