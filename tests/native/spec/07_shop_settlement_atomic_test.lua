local GameCfg = require("common.game_cfg")
local Host = require("tests.support.shop_feed_host")

local ROW, ROW_ITEM = 14, "starterRod"
local ROW_PRICE
for _, row in ipairs(GameCfg.Shop.Goods) do
  if row.Number == ROW then ROW_PRICE = row.Price break end
end
assert(ROW_PRICE)

describe("条款 7-17 商店购买的扣费与发奖在一次结算里落地", function()
  local host, player, data, baseline

  before_each(function()
    host = Host.start()
  end)

  after_each(function() host:shutdown() end)

  local function join(coins, fill)
    player, data = host:join(7017, GameCfg.Shop.Stands[1].AnchorName, function(d)
      if coins > 0 then assert.is_true(d:AddCoin(coins, nil, "test")) end
      if fill then while d:AddItem("tilapia") do end end
      baseline = d:ItemCount(ROW_ITEM)
    end)
  end

  local function buy()
    local reply = host:act(player, "ShopAction", { action = "Buy", number = ROW })
    assert.is_table(reply, "购买请求没有回包")
    return reply
  end

  it("成功的一笔同时扣金币与发物品", function()
    join(1000, false)
    local price = ROW_PRICE
    local reply = buy()
    assert.is_true(reply.ok, reply.reason)
    assert.same(1000, reply.coinBefore)
    assert.same(1000 - price, reply.coinAfter)
    assert.same(baseline, reply.itemBefore)
    assert.same(baseline + 1, reply.itemAfter)
    assert.same(1000 - price, data.Data.FishCoin)
    assert.same(baseline + 1, data:ItemCount(ROW_ITEM))
  end)

  it("余额不足时整体失败：不扣金币也不发物品", function()
    join(0, false)
    local reply = buy()
    assert.is_false(reply.ok)
    assert.same("coin", reply.reason)
    assert.is_nil(reply.coinAfter)
    assert.same(0, data.Data.FishCoin)
    assert.same(baseline, data:ItemCount(ROW_ITEM))
  end)

  it("库存满格时整体失败：不扣金币也不发物品", function()
    join(1000, true)
    local reply = buy()
    assert.is_false(reply.ok)
    assert.same("full", reply.reason)
    assert.is_nil(reply.coinAfter)
    assert.same(1000, data.Data.FishCoin)
    assert.same(baseline, data:ItemCount(ROW_ITEM))
  end)
end)
