-- 条款 17-18（docs/acceptance/17-tutorial-story-platform.md）：分享任务在平台能力未开放时走明确占位路径，
-- 不出现点了没反应的入口；平台开放情况作为生产开关。
-- 接线注入 MgrPlayerData 与 MgrSave；引擎边界（CommodityService / AdvertisementService / World 时钟 / RE 通道）
-- 源码核对那几条接线确实存在（见 WIRING）。
-- 只断言玩家可观察的结果：Share 回包（客户端据此显示占位文案）与玩家数据快照（金币、库存件数）。
-- 失败方式（先列后写）：
--   0. main.lua 的接线被改掉（平台入口不再拿玩家数据/存档）：本文件先红；
--   1. 分享能力未开放时入口静默吞掉请求（点了没反应）；
--   2. 回包不带可读文案，玩家不知道发生了什么；
--   3. 占位路径顺手发放了真实权益（商品件数或金币变化）。
local GameCfg = require('common.game_cfg')
local EconomyWorld = require('tests.support.economy_world')

local WIRING = {
    'local PlatformHost = require("server.platform_host")',
    'save = SaveHost',
    'platform = PlatformHost',
    'player_data = PlayerDataHost',
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

local function channels()
    local posts, registry = {}, {}
    local function channel(name)
        if not registry[name] then
            registry[name] = {
                FireClient = function(_, _, payload)
                    posts[name] = posts[name] or {}
                    table.insert(posts[name], payload)
                end,
                FireServer = function() end,
                OnServerEvent = { Connect = function() end },
            }
        end
        return registry[name]
    end
    return { posts = posts, GetRE = function(_, name) return channel(name) end }
end

describe('条款 17-18：分享任务的占位入口', function()
    local env, saved

    before_each(function()
        assert_wiring()
        saved = { re = rawget(_G, 'REUtil'), debug = GameCfg.Debug.Enabled,
            placeholderEnabled = GameCfg.Platform.Placeholder.Enabled,
            placeholderAllowInPublish = GameCfg.Platform.Placeholder.AllowInPublish }
        -- #249 占位闸门：分享的占位入口随调试构建放行；发布构建默认关闭（见文件末尾的闸门用例）
        GameCfg.Debug.Enabled = true
        GameCfg.Platform.Placeholder.AllowInPublish = false
        env = { now = 0, posts = nil }
        env.re = channels()
        _G.REUtil = { GetRE = env.re.GetRE, CheckRECD = function() return false end }
        env.player = { UserId = 26303, SetAttribute = function() end }
        env.data = assert(loadfile('server/data/player_data.lua'))().New(env.player, function() end)
        env.data:Init()
        env.platform = assert(loadfile('server/platform_host.lua'))()
        env.platform.PlayerData = { GetDataInst = function(_, player) return player == env.player and env.data end,
            SendItemBar = function() end }
        env.platform.Save = { NextOperation = function() return { id = '26303:1' } end,
            Execute = function(_, player, data, operation, transform, done)
                local accepted, result = transform(data)
                if not accepted then return false, 'rejected' end
                if done then done(true, result) end
                return true
            end }
        env.platform.World = { GetServerTime = function() return env.now end }
    end)

    after_each(function()
        _G.REUtil = saved.re
        GameCfg.Debug.Enabled = saved.debug
        GameCfg.Platform.Placeholder.Enabled = saved.placeholderEnabled
        GameCfg.Platform.Placeholder.AllowInPublish = saved.placeholderAllowInPublish
        env = nil
    end)

    -- 平台回包统一走 PlatformResult 通道（客户端据此显示提示），按 action 分辨是哪件事。
    local function lastReply()
        local list = env.re.posts.PlatformResult or {}
        return list[#list]
    end

    it('平台分享能力未开通时回明确占位，不点了没反应', function()
        -- 开放情况是生产开关（共享配置）：默认未开通。
        assert.is_false(GameCfg.Platform.Share.Enabled)
        local coin = env.data.Data.FishCoin
        local itemId = GameCfg.Survival.AdrenalineItemId
        local before = env.data:ItemCount(itemId)
        assert.is_false(env.platform:Share(env.player, 'tutorial'))
        local reply = lastReply()
        assert.is_table(reply, '分享入口必须有回包，不能静默吞掉')
        assert.is_false(reply.ok)
        assert.same('Share', reply.action)
        assert.same('placeholder', reply.reason, '未开放要走明确占位原因')
        assert.same(GameCfg.Platform.Share.UnavailableText, reply.text)
        assert.is_true(#reply.text > 0, '占位也要有玩家可读文案')
        -- 占位不发真实权益：金币与商品件数都不动。
        assert.same(coin, env.data.Data.FishCoin)
        assert.same(before, env.data:ItemCount(itemId))
    end)

    it('经平台操作通道进来的分享请求同样有明确回包', function()
        local handled = env.platform:HandleAction(env.player, { action = 'Share', purpose = 'tutorial' })
        assert.is_true(handled, '分享请求要被受理，不许丢掉')
        local reply = lastReply()
        assert.is_table(reply)
        assert.same('placeholder', reply.reason)
        assert.same('tutorial', reply.purpose)
    end)

    -- #249 占位通道统一闸门（ADR-0029 第三节第 5 条、第四节第 9 项；条款 19-13「发布前检查」）：
    -- 关闭调试且 AllowInPublish=false 时，占位支付、金币页、广告与分享一律被拒绝，
    -- 不发任何物品与权益，回执说明「未开放」。
    -- 失败方式（先列后写）：
    --   0. 闸门失位：发布构建里占位支付 / 广告仍能开 flow，玩家没付费就拿到物品或权益；
    --   1. 挡下了但回执静默（点了没反应），或说成「暂不可用」，玩家不知道是未开放；
    --   2. 被拒的动作顺手发了货（回执 ok=false 但库存或金币变了）。
    it('19-13 发布构建未显式打开 AllowInPublish 时占位支付、金币页、广告与分享一律拒绝并说明未开放', function()
        local shop = EconomyWorld.new()
        GameCfg.Debug.Enabled = false
        GameCfg.Platform.Placeholder.Enabled = true
        GameCfg.Platform.Placeholder.AllowInPublish = false
        local itemId = GameCfg.Survival.AdrenalineItemId
        local items = shop.data:ItemCount(itemId)
        local coin = shop.data.Data.FishCoin
        local function lastReply() return shop:lastResult('PlatformResult') end
        local function assert_not_open(reply, what)
            assert.is_table(reply, what .. ' 被拒时必须回包，不能静默')
            assert.is_false(reply.ok, what .. ' 不得回成功')
            assert.same('not_open', reply.reason, what .. ' 的原因必须是「未开放」')
            assert.is_truthy(tostring(reply.text):find('未开放', 1, true) ~= nil,
                what .. ' 的回执没说明未开放')
            assert.same(items, shop.data:ItemCount(itemId), what .. ' 被拒时不得发物品')
            assert.same(coin, shop.data.Data.FishCoin, what .. ' 被拒时不得改金币')
            assert.is_false(shop.platform:HasFlow(shop.player), what .. ' 被拒时不得建平台 flow')
        end
        assert.is_true(shop:platformAction({ action = 'Purchase', goods = 'adrenaline1', seq = 1 }))
        assert_not_open(lastReply(), '占位支付')
        assert.is_false(shop:platformAction({ action = 'OpenCoinShop' }))
        local coinShop = lastReply()
        assert.same('CoinShop', coinShop.action)
        assert_not_open(coinShop, '金币页入口')
        assert.is_nil(coinShop.offers, '闸门关闭时不得报出可购买价目')
        assert.is_true(shop:platformAction({ action = 'BuyCoin', goods = 'coinPouch', seq = 1 }))
        assert_not_open(lastReply(), '金币页购买')
        local adOpened, adReason = shop.platform:ShowAd(shop.player, 'revive', 'revive', function()
            error('闸门关闭时不得建广告 flow')
        end)
        assert.is_false(adOpened)
        assert.same('not_open', adReason)
        assert.is_true(shop.platform:HandleAction(shop.player, { action = 'Share', purpose = 'tutorial' }))
        assert_not_open(lastReply(), '分享')
        shop:tearDown()
    end)

    it('19-13 发布构建显式打开 AllowInPublish 后占位通道恢复可用', function()
        local shop = EconomyWorld.new()
        GameCfg.Debug.Enabled = false
        GameCfg.Platform.Placeholder.Enabled = true
        GameCfg.Platform.Placeholder.AllowInPublish = true
        assert.is_true(shop:platformAction({ action = 'OpenCoinShop' }))
        local coinShop = shop:lastResult('PlatformResult')
        assert.is_true(coinShop.ok)
        assert.same('CoinShop', coinShop.action)
        assert.is_table(coinShop.offers)
        assert.is_true(#coinShop.offers > 0)
        assert.is_true(shop:platformAction({ action = 'Purchase', goods = 'adrenaline1', seq = 1 }))
        local opened = shop:lastResult('PlatformResult')
        assert.same('PlaceholderFlow', opened.action)
        assert.is_true(opened.open)
        shop:tearDown()
    end)


    -- 重开侧（与上一条闸门用例配对）：显式打开 AllowInPublish 后，分享与占位广告也恢复可用——
    -- 分享不再以「未开放」拒绝，回到占位入口自身的原因与文案；占位广告能开出占位 flow。
    -- 闸门是显式开关，不是把占位通道焊死。
    -- 失败方式（先列后写）：
    --   0. 闸门打开后分享仍报「未开放」，或占位广告仍开不出 flow；
    --   1. 放开的占位路径顺手发了真实权益（金币或商品件数变化）。
    it('19-13 发布构建显式打开 AllowInPublish 后分享与占位广告恢复可用', function()
        GameCfg.Debug.Enabled = false
        GameCfg.Platform.Placeholder.Enabled = true
        GameCfg.Platform.Placeholder.AllowInPublish = true
        local coin = env.data.Data.FishCoin
        local itemId = GameCfg.Survival.AdrenalineItemId
        local before = env.data:ItemCount(itemId)
        -- 分享：不再以「未开放」拒绝，回到占位入口自身的原因与文案；仍不发真实权益
        assert.is_true(env.platform:HandleAction(env.player, { action = 'Share', purpose = 'tutorial' }))
        local share = lastReply()
        assert.is_table(share)
        assert.same('Share', share.action)
        assert.is_false(share.ok)
        assert.same('placeholder', share.reason, '显式开放后分享应回到占位入口，而不是「未开放」')
        assert.same(GameCfg.Platform.Share.UnavailableText, share.text)
        assert.same(coin, env.data.Data.FishCoin, '占位分享不得改金币')
        assert.same(before, env.data:ItemCount(itemId), '占位分享不得发物品')
        -- 占位广告：能开出占位 flow，参数来自共享配置的占位广告位
        assert.is_true(env.platform:ShowAd(env.player, 'revive', 'revive', function() end),
            '显式开放后占位广告应能开出 flow')
        local flow = lastReply()
        assert.same('PlaceholderFlow', flow.action)
        assert.is_true(flow.open)
        assert.same('ad', flow.kind)
        assert.same(GameCfg.Platform.Placeholder.Ads.revive, flow.goodsId,
            '占位广告位参数必须来自共享配置')
        assert.is_true(env.platform:HasFlow(env.player))
        -- 收起 flow，避免影响同一用例后续断言
        assert.is_true(env.platform:ResolvePlaceholder(env.player, 'cancel'))
    end)
end)
