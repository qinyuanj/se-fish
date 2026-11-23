-- 条款 15-21（docs/acceptance/15-map-blindbox.md）：金豆扣费在占位支付通道下走通扣费与发奖的对称结算，
-- 占位路径不发放真实付费权益；真实平台支付通道作为生产开关单列。
-- 同文件另断言：15-01（单抽 10 金豆 / 十连 90 金豆）、15-09（连续 49 抽未中大奖后第 50 抽强制保底）、
-- 15-10（保底在极品美人鱼与极品蛇颈龙之间等概率）、15-11（任意一抽出大奖立即清零连续未中计数）。
-- 只走 ServerRuntime 的 BlindboxAction 与 MgrPlatform 占位支付通道，
-- 装配按 main.lua 接线核对；引擎边界（game / REUtil / DataStore / 时钟）与随机数按共享夹具替换。
-- 只断言玩家可观察的结果：PlatformResult 回包（客户端据此开确认面板）、BlindboxResult 回包（抽到什么、
-- 保底计数）与库存件数。
-- 失败方式（先列后写）：
--   0. main.lua 的接线被改掉（盲盒不再经平台适配层收费）→ 本文件先红，逼人复核断言；
--   1. 价目不是共享配置的金豆价（单抽 10 / 十连 90），或占位通道不带占位商品 ID 与「不发真实权益」提示；
--   2. 还没确认就发奖（先发货后收费），或确认后不发奖（收了费不给货）；
--   3. 取消或超时仍发奖、仍推进保底（单边落地，扣费与发奖不对称）；
--   4. 重复确认重复发奖；
--   5. 保底边界错：49 抽未中不保底、或未满 49 抽就保底、或保底只出固定一件、或出大奖后计数没清零。
local GameCfg = require('common.GameCfg')
local BlindboxWorld = require('tests.support.blindbox_world')
local RandomGuard = require('tests.support.random_guard')

local WIRING = {
    'save = MgrMap.MgrSave,',
    'platform = MgrMap.MgrPlatform,',
    'player_data = MgrMap.MgrPlayerData,',
    'bind_blindbox_action = function(dispatch)',
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

-- 权重全表总和 1000：roll 1000 落在最后一档（极品罗非鱼 item7），是不出大奖的固定结果。
local MISS_ROLL, LAST_ITEM = 1000, 'item7'
-- 保底奖池：极品美人鱼（item108）与极品蛇颈龙（item107）等概率二选一，roll 1 / 2 分别取两者。
local GUARANTEE_A, GUARANTEE_B = 'item108', 'item107'

describe('条款 15-21 / 15-01 / 15-09 / 15-10 / 15-11 盲盒占位支付通道的对称结算', function()
    local world
    local savedPlaceholder

    local function flows()
        local open = {}
        for _, message in ipairs(world:messages('PlatformResult')) do
            if message.action == 'PlaceholderFlow' and message.open == true then open[#open + 1] = message end
        end
        return open
    end

    local function lastFlow()
        local open = flows()
        return open[#open]
    end

    local function grants()
        local list = {}
        for _, message in ipairs(world:messages('PlatformResult')) do
            if message.action == 'CoinGrant' then list[#list + 1] = message end
        end
        return list
    end

    local function draw(count, seq)
        assert.is_true(world:blindboxAction({ action = 'Draw', count = count, seq = seq }))
    end

    -- 占位通道的确认 / 取消：客户端在确认面板上按下的那一格
    local function settle(outcome)
        local accepted = world.platform:HandleAction(world.player, { action = 'PlaceholderOutcome', outcome = outcome })
        world:drain()
        return accepted
    end

    before_each(function()
        assert_wiring()
        world = BlindboxWorld.new()
        world:setUp()
        -- #249 占位闸门：占位通道随调试构建放行（发布构建要显式 AllowInPublish）；
        -- 本文件证的是占位通道整条路径，不走调试构建的测试驱动器。
        GameCfg.Debug = { Enabled = true }
        savedPlaceholder = GameCfg.Platform.Placeholder.Enabled
        GameCfg.Platform.Placeholder.Enabled = true
    end)

    after_each(function()
        GameCfg.Platform.Placeholder.Enabled = savedPlaceholder
        RandomGuard.restore()
        if world then world:tearDown(); world = nil end
    end)

    it('单抽与十连的占位通道上报金豆价目，并注明不发放真实付费权益', function()
        world.rolls = { MISS_ROLL }
        draw(1, 1)
        local single = lastFlow()
        assert.is_not_nil(single, '单抽没有开占位支付通道')
        assert.same('blindboxSingle', single.key)
        assert.same(10, single.beans) -- 单抽 10 金豆
        assert.same('金豆', single.currency)
        assert.is_truthy(single.goodsId:find('^placeholder%.goods%.') ~= nil,
            '占位商品 ID 必须走占位前缀，实际：' .. tostring(single.goodsId))
        assert.is_truthy(single.notice:find('不发放真实付费权益', 1, true) ~= nil, '缺少占位口径提示')
        assert.is_true(settle('success'))
        world.rolls = { MISS_ROLL, MISS_ROLL, MISS_ROLL, MISS_ROLL, MISS_ROLL,
            MISS_ROLL, MISS_ROLL, MISS_ROLL, MISS_ROLL, MISS_ROLL }
        draw(10, 2)
        local ten = lastFlow()
        assert.same('blindboxTen', ten.key)
        assert.same(90, ten.beans) -- 十连 90 金豆
    end)

    it('确认前不发奖，确认后一次结算：发奖与推进保底同时落地', function()
        world.rolls = { MISS_ROLL }
        draw(1, 1)
        assert.same(0, world.data:ItemCount(LAST_ITEM), '确认前不得发奖')
        assert.same(0, world.data.Extra.lottery.pity, '确认前不得推进保底计数')
        assert.is_true(settle('success'))
        local result = world:lastResult()
        assert.is_true(result.ok, result.reason)
        assert.same(1, #result.draws)
        assert.same(LAST_ITEM, result.draws[1].itemKey)
        assert.same(1, result.pityAfter)
        assert.same(1, world.data:ItemCount(LAST_ITEM), '确认后必须真的发奖')
        assert.same(1, world.data.Extra.lottery.pity)
    end)

    it('取消不发奖、不推进保底，也不残留待结算通道', function()
        world.rolls = { MISS_ROLL }
        draw(1, 1)
        local result = nil
        assert.is_true(settle('cancel'))
        result = world:lastResult()
        assert.is_false(result.ok)
        assert.same('cancel', result.reason)
        assert.same(0, world.data:ItemCount(LAST_ITEM), '取消不得发奖')
        assert.same(0, world.data.Extra.lottery.pity, '取消不得推进保底')
        assert.is_false(world.platform:HasFlow(world.player))
        -- 不残留半截状态：下一次抽取仍能开通道
        world.rolls = { MISS_ROLL }
        draw(1, 2)
        assert.same(2, #flows())
    end)

    it('超时按取消结算：不发奖、不推进保底', function()
        world.rolls = { MISS_ROLL }
        draw(1, 1)
        world.now = world.now + GameCfg.Platform.FlowTimeoutSec
        world.platform:Update()
        world:drain()
        local result = world:lastResult()
        assert.is_false(result.ok)
        assert.same('timeout', result.reason)
        assert.same(0, world.data:ItemCount(LAST_ITEM), '超时不得发奖')
        assert.same(0, world.data.Extra.lottery.pity, '超时不得推进保底')
        assert.is_false(world.platform:HasFlow(world.player))
    end)

    it('重复确认不重复发奖', function()
        world.rolls = { MISS_ROLL }
        draw(1, 1)
        assert.is_true(settle('success'))
        assert.same(1, world.data:ItemCount(LAST_ITEM))
        assert.is_false(settle('success'), '没有在飞通道时确认必须被拒')
        assert.same(1, world.data:ItemCount(LAST_ITEM), '重复确认不得重复发奖')
        assert.same(0, #grants()) -- 盲盒到账走抽数，不发金币
    end)

    it('连续 49 抽未中大奖后第 50 抽强制保底，两个保底奖品都出得来', function()
        -- 抽前已连续未中 49 次（GameCfg.Blindbox.Pity.afterMisses）：本抽强制保底
        world.data.Extra.lottery.pity = 49
        world.rolls = { 1 }
        draw(1, 1)
        assert.is_true(settle('success'))
        local first = world:lastResult()
        assert.is_true(first.draws[1].guaranteed)
        assert.same(GUARANTEE_A, first.draws[1].itemKey)
        assert.is_true(first.draws[1].jackpot)
        assert.same(0, first.pityAfter, '出大奖立即清零连续未中计数')
        -- 保底是等概率二选一：同一保底条件下 roll 2 取另一件
        world.data.Extra.lottery.pity = 49
        world.rolls = { 2 }
        draw(1, 2)
        assert.is_true(settle('success'))
        local second = world:lastResult()
        assert.is_true(second.draws[1].guaranteed)
        assert.same(GUARANTEE_B, second.draws[1].itemKey)
    end)

    it('未满 49 抽不保底，自然出大奖也立即清零计数', function()
        world.data.Extra.lottery.pity = 48
        world.rolls = { MISS_ROLL }
        draw(1, 1)
        assert.is_true(settle('success'))
        local miss = world:lastResult()
        assert.is_false(miss.draws[1].guaranteed, '未满 49 抽不得保底')
        assert.same(49, miss.pityAfter)
        assert.same(49, world.data.Extra.lottery.pity)
        -- 自然出大奖（权重区间第一档，极品美人鱼）：计数立即清零
        world.data.Extra.lottery.pity = 10
        world.rolls = { 5 }
        draw(1, 2)
        assert.is_true(settle('success'))
        local jackpot = world:lastResult()
        assert.is_true(jackpot.draws[1].jackpot)
        assert.is_false(jackpot.draws[1].guaranteed)
        assert.same(0, jackpot.pityAfter)
        assert.same(0, world.data.Extra.lottery.pity)
    end)
end)
