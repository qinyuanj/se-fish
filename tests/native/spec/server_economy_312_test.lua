local GameCfg = require("common.game_cfg")
local EconomyWorld = require("tests.support.economy_world")

local ITEM_BAR = GameCfg.Items.ContainerId.ItemBar

local function track_frame_subscriptions(world)
  local on_frame = world.runtime.clock.on_frame
  local original_subscribe = on_frame.subscribe
  local active = 0
  on_frame.subscribe = function(self, callback)
    local handle = original_subscribe(self, callback)
    local original_dispose = handle.dispose
    local counted = true
    active = active + 1
    handle.dispose = function(disposable)
      if counted then
        counted = false
        active = active - 1
      end
      return original_dispose(disposable)
    end
    return handle
  end
  return function() return active end
end

describe("服务端抽奖机、盲盒与地图商店宿主入口（#312）", function()
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

    world.data.data.containers[ITEM_BAR][1] = nil
    world:give_premium("item31", 2, { grilled = true })
    assert.is_false(world:lottery_draw(1, 2))
    assert.same(1, world.data:ItemCount("item31"))

    world.data.data.containers[ITEM_BAR][1] = nil
    world:give_premium("item31", 2)
    world:persist_ready()
    world:script_axes(96, 100, 5)
    assert.is_true(world:lottery_draw(1, 3))
    local result = world:last_result("LotteryResult")
    assert.same(100, result.betValue)
    assert.same(2000, result.coins)
    assert.same(2000, world.data.data.FishCoin)
    assert.is_nil(world.data.data.containers[ITEM_BAR][1])
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
    assert.same(0, world.data.data.FishCoin)
    assert.same(1, world.data:WeaponCount("item154"))
    assert.is_nil(world.data.data.containers[ITEM_BAR][1])
  end)

  it("test_old_epoch_does_not_block_current_delivery", function()
    local bag = world.data.extra.lottery
    bag.deliveries = {
      old = { epoch = "old-world", itemId = "item7" },
      current = { epoch = "test-world", itemId = "item7" },
    }
    world:persist_ready()
    world:reconnect()
    world:pump()
    assert.same(1, #world:ground_items())
    assert.is_not_nil(world.data.extra.lottery.deliveries.old)
    assert.is_nil(world.data.extra.lottery.deliveries.current)
  end)

  it("盲盒支付重试与重连不重复扣费或发奖", function()
    world.rolls = { 1000 }
    assert.is_true(world:blindbox_draw(1, 1))
    local requestId = next(world.data.extra.lottery.intents)
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
    local requestId = next(world.data.extra.platformShop.intents)
    assert.is_not_nil(requestId)
    world:resolve_platform("success")
    local result = world:last_result("PlatformResult")
    assert.same("Grant", result.action)
    assert.same(1, result.overflow)
    assert.same(1, #world:ground_items())
    assert.is_nil(next(world.data.extra.platformShop.deliveries))

    assert.is_true(world:platform_action({ action = "Purchase", goods = "adrenaline1", seq = 1 }))
    assert.same(1, #world:ground_items())
    assert.is_false(world.platform:has_flow(world.player))
  end)

  it("乐园币购买按原请求重放到账结果且不重复加金币", function()
    GameCfg.Platform.Placeholder.Enabled = true
    assert.is_true(world:platform_action({ action = "BuyCoin", goods = "coinPouch", seq = 1 }))
    world:resolve_platform("success")
    assert.same(600, world.data.data.FishCoin)
    local sequence = world.data:Serialize().meta.sequence
    assert.is_true(world:platform_action({ action = "BuyCoin", goods = "coinPouch", seq = 1 }))
    assert.same(600, world.data.data.FishCoin)
    assert.same(sequence, world.data:Serialize().meta.sequence)
  end)

  it("盲盒仅待处理期间按需订阅帧，交付重试后退出且新工作可恢复", function()
    while world.data:AddItem("carp") do end
    world:persist_ready()
    local active_frames = track_frame_subscriptions(world)
    world:reconnect()
    assert.same(0, active_frames(), "空闲盲盒与平台商店不得常驻 on_frame")

    world.rolls = { 1000 }
    world.failDeliveries = true
    assert.is_true(world:blindbox_draw(1, 1))
    assert.same(1, active_frames(), "awaiting intent 应恢复盲盒帧订阅")
    world:clear_events()
    world:resolve_platform("success")
    assert.same(1, active_frames(), "待交付记录存在时必须继续重试")
    world:pump()
    assert.same(1, active_frames())

    world.failDeliveries = false
    world:pump()
    assert.same(0, active_frames(), "交付完成后必须退订")
    assert.same(1, #world:ground_items())
    assert.is_nil(next(world.data.extra.lottery.deliveries))
    local delivery_notices = world:messages("BlindboxResult")
    assert.same({ true, false }, {
      delivery_notices[1] and delivery_notices[1].deliveryPending,
      delivery_notices[2] and delivery_notices[2].deliveryPending,
    })

    assert.is_true(world:blindbox_draw(1, 2))
    assert.same(1, active_frames(), "空闲后新购买必须重新激活")
    world:resolve_platform("cancel")
    assert.same(0, active_frames())

    assert.is_true(world:blindbox_draw(1, 3))
    assert.same(1, active_frames())
    world.runtime:on_player_removing(world.player)
    world.platform:on_player_removing(world.player)
    world:drain()
    assert.same(0, active_frames(), "dispose 必须退订活跃盲盒 Phase")
    local notices_before_frame = #world:messages("BlindboxResult")
    world:pump()
    assert.same(notices_before_frame, #world:messages("BlindboxResult"), "dispose 后不得再运行购买回调")
  end)

  it("平台商店仅待处理期间按需订阅帧，交付重试后退出且新工作可恢复", function()
    while world.data:AddItem("carp") do end
    world:persist_ready()
    local active_frames = track_frame_subscriptions(world)
    world:reconnect()
    assert.same(0, active_frames(), "空闲盲盒与平台商店不得常驻 on_frame")

    world.failDeliveries = true
    assert.is_true(world:platform_action({ action = "Purchase", goods = "adrenaline1", seq = 1 }))
    assert.same(1, active_frames(), "awaiting intent 应恢复平台商店帧订阅")
    world:clear_events()
    world:resolve_platform("success")
    assert.same(1, active_frames(), "待交付记录存在时必须继续重试")
    world:pump()
    assert.same(1, active_frames())

    world.failDeliveries = false
    world:pump()
    assert.same(0, active_frames(), "交付完成后必须退订")
    assert.same(1, #world:ground_items())
    assert.is_nil(next(world.data.extra.platformShop.deliveries))
    local delivery_notices = {}
    for _, notice in ipairs(world:messages("PlatformResult")) do
      if notice.action == "Grant" then delivery_notices[#delivery_notices + 1] = notice end
    end
    assert.same(2, #delivery_notices)
    assert.is_true(delivery_notices[1].deliveryPending)
    assert.is_nil(delivery_notices[2].deliveryPending)

    assert.is_true(world:platform_action({ action = "Purchase", goods = "adrenaline1", seq = 2 }))
    assert.same(1, active_frames(), "空闲后新购买必须重新激活")
    world:resolve_platform("cancel")
    assert.same(0, active_frames())

    assert.is_true(world:platform_action({ action = "Purchase", goods = "adrenaline1", seq = 3 }))
    assert.same(1, active_frames())
    world.runtime:on_player_removing(world.player)
    world.platform:on_player_removing(world.player)
    world:drain()
    assert.same(0, active_frames(), "dispose 必须退订活跃平台商店 Phase")
    local notices_before_frame = #world:messages("PlatformResult")
    world:pump()
    assert.same(notices_before_frame, #world:messages("PlatformResult"), "dispose 后不得再运行购买回调")
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
