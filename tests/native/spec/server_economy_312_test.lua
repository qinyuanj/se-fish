local GameCfg = require("common.game_cfg")
local EconomyWorld = require("tests.support.economy_world")

local ITEM_BAR = GameCfg.Items.ContainerId.ItemBar

describe("服务端抽奖机、盲盒与地图商店宿主接缝（#312）", function()
  local world
  before_each(function() world = EconomyWorld.new() end)
  after_each(function()
    if world then world:tear_down() end
    world = nil
  end)

  it("抽奖拒绝普通鱼获与烤鱼，极品信物的扣除和金币大奖同批结算", function()
    assert.is_true(world.data:AddItem("carp"))
    assert.is_false(world:lottery_draw(1, 1))
    assert.same(1, world.data:ItemCount("carp"))

    world.data.Data.Containers[ITEM_BAR][1] = nil
    world:give_premium("item31", 2, { grilled = true })
    assert.is_false(world:lottery_draw(1, 2))
    assert.same(1, world.data:ItemCount("item31"))

    world.data.Data.Containers[ITEM_BAR][1] = nil
    world:give_premium("item31", 2)
    world:persist_ready()
    world:script_axes(96, 100, 5)
    assert.is_true(world:lottery_draw(1, 3))
    local result = world:last_result("LotteryResult")
    assert.same(100, result.betValue)
    assert.same(2000, result.coins)
    assert.same(2000, world.data.Data.FishCoin)
    assert.is_nil(world.data.Data.Containers[ITEM_BAR][1])
  end)

  it("三同武器大奖进入独立武器库存且不叠加金币", function()
    world:give_premium("item7")
    world:persist_ready()
    world:script_axes(1, 10, 22, 3)
    assert.is_true(world:lottery_draw(1, 1))
    local result = world:last_result("LotteryResult")
    assert.same("triple", result.outcome)
    assert.same({ kind = "weapon", itemId = "item154", name = "黄金匕首" }, result.prize)
    assert.is_nil(result.coins)
    assert.same(0, world.data.Data.FishCoin)
    assert.same(1, world.data:WeaponCount("item154"))
    assert.is_nil(world.data.Data.Containers[ITEM_BAR][1])
  end)

  it("test_old_epoch_does_not_block_current_delivery", function()
    local bag = world.data.Extra.lottery
    bag.deliveries = {
      old = { epoch = "old-world", itemId = "item7" },
      current = { epoch = "test-world", itemId = "item7" },
    }
    world:persist_ready()
    world:pump()
    assert.same(1, #world:ground_items())
    assert.is_not_nil(world.data.Extra.lottery.deliveries.old)
    assert.is_nil(world.data.Extra.lottery.deliveries.current)
  end)

  it("盲盒支付重试与重连不重复扣费或发奖", function()
    world.rolls = { 1000 }
    assert.is_true(world:blindbox_draw(1, 1))
    local requestId = next(world.data.Extra.lottery.intents)
    assert.is_true(world:blindbox_draw(1, 1))
    world:resolve_platform("success")
    assert.same(1, world.data:ItemCount("item7"))
    local sequence = world.data:Serialize().meta.sequence
    assert.is_true(world:blindbox_query(1, requestId))
    assert.same(sequence, world.data:Serialize().meta.sequence)
    world:reconnect()
    assert.same(1, world.data:ItemCount("item7"))
    assert.is_true(world:blindbox_query(1, requestId))
    assert.is_true(world:last_result("BlindboxResult").recovered)
    assert.same(1, world.data:ItemCount("item7"))
  end)

  it("地图商店商品满库存时保留独立待交付意图并只落地一次", function()
    while world.data:AddItem("carp") do end
    world:persist_ready()
    assert.is_true(world:platform_action({ action = "Purchase", goods = "adrenaline1", seq = 1 }))
    local requestId = next(world.data.Extra.platformShop.intents)
    assert.is_not_nil(requestId)
    world:resolve_platform("success")
    local result = world:last_result("PlatformResult")
    assert.same("Grant", result.action)
    assert.same(1, result.overflow)
    assert.same(1, #world:ground_items())
    assert.is_nil(next(world.data.Extra.platformShop.deliveries))

    assert.is_true(world:platform_action({ action = "Purchase", goods = "adrenaline1", seq = 1 }))
    assert.same(1, #world:ground_items())
    assert.is_false(world.platform:has_flow(world.player))
  end)

  it("乐园币购买按原请求重放到账结果且不重复加金币", function()
    GameCfg.Platform.Placeholder.Enabled = true
    assert.is_true(world:platform_action({ action = "BuyCoin", goods = "coinPouch", seq = 1 }))
    world:resolve_platform("success")
    assert.same(600, world.data.Data.FishCoin)
    local sequence = world.data:Serialize().meta.sequence
    assert.is_true(world:platform_action({ action = "BuyCoin", goods = "coinPouch", seq = 1 }))
    assert.same(600, world.data.Data.FishCoin)
    assert.same(sequence, world.data:Serialize().meta.sequence)
  end)

  it("PlatformHost:Share 兼容 SE 引擎 userdata 玩家对象", function()
    local real_type = _G.type
    local userdata_player = world.player
    local ok_call, err = pcall(function()
      _G.type = function(value)
        if value == userdata_player then return "userdata" end
        return real_type(value)
      end
      local ok, reason = world.platform:Share(userdata_player, "invite")
      assert.is_false(ok)
      assert.not_same("invalid", reason)
      local reply = world:last_result("PlatformResult")
      assert.is_not_nil(reply)
      assert.same("Share", reply.action)
      assert.same("invite", reply.purpose)
    end)
    _G.type = real_type
    if not ok_call then error(err, 0) end
  end)
end)
