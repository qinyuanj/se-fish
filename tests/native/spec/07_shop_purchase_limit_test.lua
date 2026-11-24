local GameCfg = require("common.GameCfg")
local Host = require("tests.support.shop_feed_host")

local LIMITED_ROW, UNLIMITED_ROW = 51, 13
local function goods(number)
  for _, row in ipairs(GameCfg.Shop.Goods) do
    if row.Number == number then return row end
  end
  error("未知商品行 " .. tostring(number))
end

describe("条款 7-11 商店限购在原子结算内生效", function()
  local host, player, data

  before_each(function()
    host = Host.start()
    player, data = host:join(7001, GameCfg.Shop.Stands[1].AnchorName, function(d)
      assert.is_true(d:AddCoin(1000, nil, "test"))
    end)
  end)

  after_each(function() host:shutdown() end)

  local function buy(number)
    local reply = host:act(player, "ShopAction", { action = "Buy", number = number })
    assert.is_table(reply, "购买请求没有回包")
    return reply
  end

  it("上限为 1 的商品买过一次后再买被拒，且不再扣金币", function()
    local limited, unlimited = goods(LIMITED_ROW), goods(UNLIMITED_ROW)
    local first = buy(LIMITED_ROW)
    assert.is_true(first.ok, first.reason)
    assert.same(1000, first.coinBefore)
    assert.same(1000 - limited.Price, first.coinAfter)
    assert.same("Upgrade", first.action)

    local second = buy(LIMITED_ROW)
    assert.is_false(second.ok)
    assert.same("limit", second.reason)
    assert.is_nil(second.coinAfter)

    local follow = buy(UNLIMITED_ROW)
    assert.is_true(follow.ok, follow.reason)
    assert.same(1000 - limited.Price, follow.coinBefore)
    assert.same(1000 - limited.Price - unlimited.Price, follow.coinAfter)
  end)

  it("上限为 0 的商品不限购，可以连续购买", function()
    local row = goods(UNLIMITED_ROW)
    local first = buy(UNLIMITED_ROW)
    assert.is_true(first.ok, first.reason)
    assert.same(1000, first.coinBefore)
    assert.same(1000 - row.Price, first.coinAfter)
    assert.same(first.itemBefore + 1, first.itemAfter)

    local second = buy(UNLIMITED_ROW)
    assert.is_true(second.ok, second.reason)
    assert.same(first.coinAfter, second.coinBefore)
    assert.same(1000 - row.Price * 2, second.coinAfter)
    assert.same(first.itemAfter, second.itemBefore)
    assert.same(first.itemAfter + 1, second.itemAfter)
  end)
end)
