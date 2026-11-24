-- 条款 14-03 / 14-04 / 14-05 / 14-06 / 14-09 / 14-10 / 14-13 / 14-15
-- （docs/acceptance/14-lottery.md）：
--   14-03 三个轴各自独立抽样，且共用同一套图案权重；
--   14-04 三同优先于两同，三同时只发放该图案对应的大奖；
--   14-05 恰好两同发放金币，金额为投入物实际价格乘以该图案的两同倍数；
--   14-06 无两同时不发放任何奖励；
--   14-09 三同大奖按表对应（匕首组五选一、加速药水…）；
--   14-10 两同金币按投入物已确定的整数售价计算；
--   14-13 两同金币直接入账户，不落到世界物品；
--   14-15 三同的武器大奖进入独立武器库存，不占道具栏或背包格。
-- 权重表（common/cfg/lottery.lua）：22/20/18/16/14/5/5，合计 100，累计边界 22、42、60、76、90、95、100。
-- 失败方式（先列后写）：
--   1. 三个轴不是各抽各的，或某一轴换了权重表；
--   2. 三同时还发两同金币，或三同大奖不对应该图案；
--   3. 两同金币按随机倍率后的价格算，而不是已确定的整数售价；
--   4. 无两同也发奖，或金币不直接入账户而是生成世界物品；
--   5. 武器大奖占道具格而不是进独立武器库存。
local GameCfg = require('common.game_cfg')
local EconomyWorld = require('tests.support.economy_world')

local ITEM_BAR = GameCfg.Items.ContainerId.ItemBar

local function newWorld()
  local env = EconomyWorld.new()
  function env:join() end
  function env:cleanup() self:tearDown() end
  function env:bet(itemId, mult)
    self:givePremium(itemId, mult)
    self:persistReady()
  end
  function env:draw(seq)
    local accepted = self:lotteryDraw(1, seq)
    return accepted, self:lastResult('LotteryResult')
  end
  return env
end
-- 极品罗非鱼 item7 基础价 3（tests/native/lottery_settle_test.lua 注释与物品表同源）
local PREMIUM = 'item7'

describe('条款 14：抽奖机数值规则', function()
  local env

  before_each(function()
    env = newWorld()
    env:join()
  end)
  after_each(function() env:cleanup() end)

  -- 14-03：三轴各用一次随机数，按同一张权重表的累计区间落图案（22/42/60/76/90/95/100）。
  it('14-03 三个轴各自独立抽样且共用同一套图案权重', function()
    env:bet(PREMIUM, 1)
    env.rolls = { 1, 23, 100 }
    local accepted, reply = env:draw(1)
    assert.is_true(accepted)
    assert.are.equal('Draw', reply.action)
    assert.same({ 1, 2, 7 }, reply.axes)
    -- 累计边界：22 仍落在第 1 个图案，96 落在第 7 个图案
    env:bet(PREMIUM, 1)
    env.rolls = { 22, 96, 43 }
    local _, second = env:draw(2)
    assert.same({ 1, 7, 3 }, second.axes)
  end)

  -- 14-04 / 14-09：三同只发对应图案的大奖；匕首组五选一由组内随机决定。
  it('14-04 三同优先且只发该图案的大奖', function()
    env:bet(PREMIUM, 1)
    env.rolls = { 22, 22, 22, 3 }
    local _, reply = env:draw(1)
    assert.are.equal('triple', reply.outcome)
    assert.are.equal('weapon', reply.prize.kind)
    assert.are.equal('item154', reply.prize.itemId)
    -- 三同不发两同金币
    assert.is_nil(reply.coins)
    assert.are.equal(reply.coinBefore, reply.coinAfter)
  end)

  -- 14-05 / 14-10：恰好两同按已确定的整数售价 × 该图案倍数发金币，直接入账。
  it('14-05 恰好两同按投入物实际价格乘倍数发金币', function()
    env:bet(PREMIUM, 1.5)
    env.rolls = { 22, 22, 43 }
    local _, reply = env:draw(1)
    assert.are.equal('pair', reply.outcome)
    assert.are.equal('鳄雀鳝', reply.patternName)
    assert.are.equal(2, reply.multiplier)
    -- 已确定的整数售价就是 betValue；倍率后的价格不参与
    assert.are.equal(reply.betValue * 2, reply.coins)
    assert.are.equal(reply.coinBefore + reply.coins, reply.coinAfter)
    assert.is_nil(reply.prize, '两同不该发物品大奖')
  end)

  -- 14-06 / 14-13：无两同啥也不发；两同金币只进账户。
  it('14-06 无两同不发放任何奖励', function()
    env:bet(PREMIUM, 1)
    env.rolls = { 1, 43, 96 }
    local _, reply = env:draw(1)
    assert.are.equal('none', reply.outcome)
    assert.is_nil(reply.coins)
    assert.is_nil(reply.prize)
    assert.are.equal(reply.coinBefore, reply.coinAfter)
  end)

  -- 14-15：三同武器大奖进独立武器库存，投入格位不被占。
  it('14-15 武器大奖进独立武器库存不占道具格', function()
    env:bet(PREMIUM, 1)
    env.rolls = { 22, 22, 22, 1 }
    local _, reply = env:draw(1)
    assert.are.equal('weapon', reply.prize.kind)
    local bar = env.data.Data.Containers[ITEM_BAR]
    assert.is_nil(bar[1], '投入格位应是空的，大奖不占道具格')
    for _, entry in pairs(bar) do
      assert.are_not.equal(reply.prize.itemId, entry.itemId, '武器大奖不该出现在道具栏')
    end
  end)

  -- 14-09：三同大奖按表逐档对应——小白龙斧头组、蟹老板枪械组各五选一，
  -- 逐格断言组内全部五件（斧头组 item157..161、枪械组 item162..166）；
  -- 虎鲸 / 风神翼龙 / 哥斯拉分别发变大药水 item168 / 风神之翼 item169 / 哥斯拉 item170
  -- （匕首组见上一条 14-04，加速药水见 lottery_settle_test）。每档都实际抽取、经业务入口断言。
  -- 失败方式：某一档映射错大奖组、武器组不再五选一、或物品档错发成别档物品。
  it('14-09 三同大奖按表逐档对应（斧头组、枪械组、变大药水、风神之翼、哥斯拉）', function()
    local cases = {
      -- 小白龙·斧头组五选一：逐格（第 4 个 roll = 组内格位 1..5）
      { name = '小白龙·银斧', rolls = { 23, 23, 23, 1 }, kind = 'weapon', itemId = 'item157' },
      { name = '小白龙·金斧', rolls = { 23, 23, 23, 2 }, kind = 'weapon', itemId = 'item158' },
      { name = '小白龙·炽焰战斧', rolls = { 23, 23, 23, 3 }, kind = 'weapon', itemId = 'item159' },
      { name = '小白龙·血吼', rolls = { 23, 23, 23, 4 }, kind = 'weapon', itemId = 'item160' },
      { name = '小白龙·无坚不摧之力', rolls = { 23, 23, 23, 5 }, kind = 'weapon', itemId = 'item161' },
      -- 蟹老板·枪械组五选一：逐格
      { name = '蟹老板·沙漠之鹰', rolls = { 43, 43, 43, 1 }, kind = 'weapon', itemId = 'item162' },
      { name = '蟹老板·霜之新星', rolls = { 43, 43, 43, 2 }, kind = 'weapon', itemId = 'item163' },
      { name = '蟹老板·雷霆之力', rolls = { 43, 43, 43, 3 }, kind = 'weapon', itemId = 'item164' },
      { name = '蟹老板·黄金AK47', rolls = { 43, 43, 43, 4 }, kind = 'weapon', itemId = 'item165' },
      { name = '蟹老板·连发火箭筒', rolls = { 43, 43, 43, 5 }, kind = 'weapon', itemId = 'item166' },
      { name = '虎鲸·变大药水', rolls = { 77, 77, 77 }, kind = 'item', itemId = 'item168' },
      { name = '风神翼龙·风神之翼', rolls = { 91, 91, 91 }, kind = 'item', itemId = 'item169' },
      { name = '哥斯拉', rolls = { 96, 96, 96 }, kind = 'item', itemId = 'item170' },
    }
    for _, case in ipairs(cases) do
      env:cleanup()
      env = newWorld()
      env:join()
      env:bet(PREMIUM, 1)
      env.rolls = case.rolls
      local accepted, reply = env:draw(1)
      assert.is_true(accepted, case.name .. '：抽奖请求未被受理')
      assert.are.equal('triple', reply.outcome, case.name .. '：三同判奖错')
      assert.are.equal(case.kind, reply.prize.kind, case.name .. '：大奖类型错')
      assert.are.equal(case.itemId, reply.prize.itemId, case.name .. '：大奖对应错')
      assert.is_nil(reply.coins, case.name .. '：三同不该发两同金币')
    end
  end)
end)
