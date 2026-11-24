-- 条款 1-12（docs/acceptance/01-overview-and-scope.md）：适配层的失败路径可走通：
-- 平台拒绝或超时后给出明确提示，且不扣费、不发放。
-- 再读 main.lua 的源码核对那三条接线确实存在（见 WIRING）——接线一改，本文件先红，逼人复核断言。
-- 只断言玩家可观察的结果：PlatformResult 回包载荷（客户端据此显示提示）与玩家数据快照（金币、库存件数）。
-- 失败方式（先列后写）：
--   0. main.lua 的接线被改掉（平台不再拿存档与玩家数据）：本文件先红；
--   1. 超时不给回包，或回包不写明 reason（玩家看不到明确提示）；
--   2. 拒绝或超时后照常发放商品（「不发放」被破坏）；
--   3. 拒绝或超时后玩家金币被扣（「不扣费」被破坏）；
--   4. 适配层不可用时仍建立 flow 或发放权益（把不可用伪装成成功）。
local GameCfg = require('common.game_cfg')
local EconomyWorld = require('tests.support.economy_world')

-- 前提守卫：本文件复现的是 main.lua 的接线，而不是自造一套协作关系。
local WIRING = {
    'local PlatformHost = require("server.platform_host")',
    'player_data = PlayerDataHost',
    'save = SaveHost',
    'platform = PlatformHost',
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

-- 引擎侧信号替身：Connect 收回调，Fire 由测试自己驱动。
local function signal()
    local s = { handlers = {} }
    function s:Connect(fn)
        self.handlers[#self.handlers + 1] = fn
        return { Disconnect = function() end }
    end
    function s:Fire(...)
        for _, fn in ipairs(self.handlers) do fn(...) end
    end
    return s
end

describe('条款 1-12：适配层失败路径', function()
    local env, restore

    local function drain()
        while #env.queue > 0 do table.remove(env.queue, 1)() end
    end

    -- 客户端收到的那一路推送：PlatformResult 的载荷就是玩家可见的提示。
    -- 只取某个 action 的回包：同一通道还会推送测试 flow 的开合通知，那不是给玩家的失败提示。
    local function replies(action)
        local values = {}
        for _, event in ipairs(env.events) do
            if event.name == 'PlatformResult' and event.value and event.value.action == action then
                values[#values + 1] = event.value
            end
        end
        return values
    end

    local function persist_ready()
        assert.is_true(env.save:save_explicit(env.player.UserId, env.data, function(ok)
            assert.is_true(ok)
        end))
        drain()
        env.events = {}
    end

    before_each(function()
        assert_wiring()
        restore = { Debug = GameCfg.Debug, game = rawget(_G, 'game'), REUtil = rawget(_G, 'REUtil'),
            PlaceholderEnabled = GameCfg.Platform.Placeholder.Enabled }
        GameCfg.Debug = { Enabled = true }
        -- #249 占位闸门：调试构建里占位面优先于测试驱动器，本文件取证的是适配层失败路径的测试 flow，
        -- 显式关掉占位通道（占位通道自身见 spec/07、spec/11、spec/17）。
        GameCfg.Platform.Placeholder.Enabled = false
        env = { now = 1000, values = {}, queue = {}, events = {}, replies = {} }
        local store = {
            GetAsync = function(_, key) return env.values[key] end,
            UpdateAsync = function(_, key, transform)
                local value = transform(env.values[key])
                if value then env.values[key] = value end
                return value
            end,
            SetAsync = function(_, key, value) env.values[key] = value end,
        }
        rawset(_G, 'game', { GetService = function(_, name)
            if name == 'Task' then
                return { Spawn = function(_, fn) env.queue[#env.queue + 1] = fn end, Wait = function() end }
            end
            if name == 'DataStoreService' then return { GetDataStore = function() return store end } end
            if name == 'World' then return { GetServerTime = function() return env.now end } end
            if name == 'Players' then return { GetPlayers = function() return {} end } end
            if name == 'CommodityService' then return { GoodsPurchaseCompleted = signal() } end
            if name == 'AdvertisementService' then return {} end
        end })
        rawset(_G, 'REUtil', { get_re = function(_, name)
            return {
                FireClient = function(_, player, value)
                    env.events[#env.events + 1] = { name = name, player = player, value = value }
                end,
                OnServerEvent = signal(),
            }
        end })
        -- loadfile 每次得到全新的管理器实例表，避免 Flows / DataMap 跨案例残留。
        env.save = assert(loadfile('server/save_host.lua'))()
        env.players = assert(loadfile('server/player_data_host.lua'))()
        env.platform = assert(loadfile('server/platform_host.lua'))()
        env.players.Save, env.save.PlayerData = env.save, env.players
        env.platform.Save, env.platform.PlayerData = env.save, env.players
        env.platform.now = function() return env.now end
        env.platform:Start()
        env.player = { UserId = 1201, Character = { Position = { x = 0, y = 0, z = 0 } },
            CharacterAdded = signal(), CharacterRemoving = signal(), SetAttribute = function() end }
        env.players:on_player_added(env.player)
        drain()
        env.data = env.players:get_data_inst(env.player)
        env.events = {}
    end)

    after_each(function()
        if restore then
            rawset(_G, 'game', restore.game)
            rawset(_G, 'REUtil', restore.REUtil)
            GameCfg.Debug = restore.Debug
            GameCfg.Platform.Placeholder.Enabled = restore.PlaceholderEnabled
        end
        env, restore = nil, nil
    end)

    local itemId = GameCfg.Survival.AdrenalineItemId

    it('timeout_replies_clear_reason_without_charge_or_grant', function()
        GameCfg.Platform.Goods.adrenaline1.goodsId = 'goodsAdr1'
        local shop = EconomyWorld.new()
        local coin = shop.data.Data.FishCoin
        assert.is_true(shop:platform_action({ action = 'Purchase', goods = 'adrenaline1', seq = 1 }))
        shop.now = shop.now + (GameCfg.Platform.FlowTimeoutSec or 0) + 1
        shop.platform:update()
        shop:drain()
        local last = shop:last_result('PlatformResult')
        assert.is_table(last)
        assert.is_false(last.ok)
        assert.same('Purchase', last.action)
        assert.same('adrenaline1', last.goods)
        assert.same('timeout', last.reason)
        assert.same(coin, shop.data.Data.FishCoin)
        assert.same(0, shop.data:ItemCount(itemId))
        assert.is_false(shop.platform:has_flow(shop.player))
        shop:tear_down()
    end)

    it('fail_replies_clear_reason_without_charge_or_grant', function()
        GameCfg.Platform.Goods.adrenaline1.goodsId = 'goodsAdr1'
        local shop = EconomyWorld.new()
        local coin = shop.data.Data.FishCoin
        assert.is_true(shop:platform_action({ action = 'Purchase', goods = 'adrenaline1', seq = 1 }))
        shop:resolve_platform('fail')
        local last = shop:last_result('PlatformResult')
        assert.is_table(last)
        assert.is_false(last.ok)
        assert.same('Purchase', last.action)
        assert.same('adrenaline1', last.goods)
        assert.same('fail', last.reason)
        assert.same(coin, shop.data.Data.FishCoin)
        assert.same(0, shop.data:ItemCount(itemId))
        assert.is_false(shop.platform:has_flow(shop.player))
        shop:tear_down()
    end)


    it('unavailable_entry_replies_reason_and_keeps_account_untouched', function()
        GameCfg.Platform.Placeholder.Enabled = false
        local shop = EconomyWorld.new()
        local coin = shop.data.Data.FishCoin
        assert.is_false(shop:platform_action({ action = 'OpenCoinShop' }))
        local last = shop:last_result('PlatformResult')
        assert.is_table(last)
        assert.is_false(last.ok)
        assert.same('CoinShop', last.action)
        assert.same('unavailable', last.reason)
        assert.is_false(shop.platform:has_flow(shop.player))
        assert.same(coin, shop.data.Data.FishCoin)
        assert.same(0, shop.data:ItemCount(itemId))
        shop:tear_down()
    end)
end)
