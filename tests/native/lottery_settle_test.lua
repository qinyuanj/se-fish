-- 抽奖机服务端宿主规格（#312）：真实 ServerRuntime / MgrSave / MgrPlayerData。
-- 仅替换支付、时钟、存档引擎与 RemoteEvents；不加载旧 MgrLottery，也不访问会话私有字段。
local World = require("tests.support.economy_world")

describe("抽奖机服务端原子结算（#312 ServerRuntime 宿主）", function()
  local world
  local ITEM_BAR = "itemBar"

  before_each(function()
    world = World.new()
  end)
  after_each(function()
    if world then world:tearDown(); world = nil end
  end)

  local function give(itemId, mult)
    world:givePremium(itemId, mult)
    world:persistReady()
  end

  it("test_bet_value_uses_individual_mult_and_never_cooked_price", function()
    give("item31", 2)
    world.rolls = { 96, 100, 5 }
    assert.is_true(world:lotteryDraw(1, 1))
    local result = world:messages("LotteryResult")[1]
    assert.same(100, result.betValue)
    assert.same(2000, result.coins)
    assert.same(2000, world.data.Data.FishCoin)
  end)

  it("test_consecutive_draws_settle_independently", function()
    give("item7", 1.5)
    assert.is_true(world.data:AddItem("item31"))
    world:persistReady()
    world.rolls = { 1, 22, 23 }
    assert.is_true(world:lotteryDraw(1, 1))
    world.rolls = { 96, 96, 1 }
    assert.is_true(world:lotteryDraw(2, 2))
    local results = world:messages("LotteryResult")
    assert.same(2, #results)
    assert.same(1000, results[2].coins)
    assert.same(1008, world.data.Data.FishCoin)
    assert.same(0, world.data:ItemCount("item7"))
    assert.same(0, world.data:ItemCount("item31"))
  end)

  it("test_duplicate_seq_and_operation_replay_return_the_unique_result", function()
    give("item7")
    world.rolls = { 1, 22, 23 }
    assert.is_true(world:lotteryDraw(1, 1))
    local first = world:messages("LotteryResult")[1]
    world:clearEvents()
    assert.is_true(world:lotteryAction({ action = "Draw", slot = 1, seq = 1 }))
    local seqReplay = world:messages("LotteryResult")
    assert.same(1, #seqReplay)
    assert.same(first.coins, seqReplay[1].coins)
    world:clearEvents()
    assert.is_true(world:lotteryAction({ action = "Draw", slot = 1, seq = 2, operation = first.operation }))
    local replayed = world:messages("LotteryResult")
    assert.same(1, #replayed)
    assert.same(first.coins, replayed[1].coins)
    assert.same(first.operation.id, replayed[1].operation.id)
    assert.same(6, world.data.Data.FishCoin)
    assert.same(0, world.data:ItemCount("item7"))
  end)

  it("test_failed_write_never_publishes_success_or_mutates_live_inventory", function()
    give("item7")
    world.rolls = { 1, 22, 23 }
    world.failWrites = true
    assert.is_true(world:lotteryDraw(1, 1))
    for _ = 1, 4 do
      world.save:Update()
      world:drain()
    end
    assert.same(0, world.data.Data.FishCoin)
    assert.same("item7", world.data.Data.Containers[ITEM_BAR][1].itemId)
    assert.same({}, world:messages("ItemBarState"))
    assert.is_false(world:messages("LotteryResult")[1].ok)
  end)

  it("test_no_pair_consumes_only_the_bet", function()
    give("item7")
    world.rolls = { 1, 23, 43 }
    assert.is_true(world:lotteryDraw(1, 1))
    local result = world:messages("LotteryResult")[1]
    assert.is_true(result.ok)
    assert.same("none", result.outcome)
    assert.is_nil(result.coins)
    assert.is_nil(result.prize)
    assert.same(0, world.data.Data.FishCoin)
    assert.is_nil(world.data.Data.Containers[ITEM_BAR][1])
  end)

  it("test_non_premium_cooked_and_grilled_token_are_rejected", function()
    world.data.Data.UpgradeLevel = 1
    assert.is_true(world.data:AddItem("carp"))
    assert.is_true(world.data:AddItem("item7", nil, 1.5))
    assert.is_true(world.data:AddItem("item31"))
    world.data.Data.Containers[ITEM_BAR][3].saved = { cooked = true }
    world:persistReady()
    for slot, reason in ipairs({ "not-premium", "cooked", "cooked" }) do
      world:lotteryDraw(slot, slot)
      local result = world:messages("LotteryResult")[slot]
      assert.is_false(result.ok)
      assert.same(reason, result.reason)
    end
    assert.same(1, world.data:ItemCount("carp"))
    assert.same(1, world.data:ItemCount("item7"))
    assert.same(1, world.data:ItemCount("item31"))
    assert.same(0, world.data.Data.FishCoin)
    assert.same(0, world.data:Serialize().meta.sequence)
  end)

  it("test_pair_pays_actual_bet_value_times_multiplier_and_consumes_one", function()
    give("item7", 1.5)
    world.rolls = { 1, 22, 23 }
    assert.is_true(world:lotteryDraw(1, 1))
    local result = world:messages("LotteryResult")[1]
    assert.is_true(result.ok)
    assert.same("pair", result.outcome)
    assert.same(4, result.betValue)
    assert.same(2, result.multiplier)
    assert.same(8, result.coins)
    assert.same({ 1, 1, 2 }, result.axes)
    assert.same(8, world.data.Data.FishCoin)
    assert.is_nil(world.data.Data.Containers[ITEM_BAR][1])
    assert.same(0, result.coinBefore)
    assert.same(8, result.coinAfter)
  end)

  it("test_pending_window_second_handle_is_dropped_silently", function()
    give("item7")
    world.rolls = { 1, 22, 23 }
    assert.is_true(world:lotteryAction({ action = "Draw", slot = 1, seq = 1 }, false))
    local before = #world.events
    assert.is_false(world:lotteryAction({ action = "Draw", slot = 1, seq = 2 }, false))
    assert.same(before, #world.events)
    world:drain()
    assert.same(1, #world:messages("LotteryResult"))
  end)

  it("test_range_and_bad_slot_are_rejected_without_mutation", function()
    give("item7")
    world.rolls = { 1, 1, 23 }
    world.inRange = false
    world:lotteryDraw(1, 1)
    local range = world:messages("LotteryResult")[1]
    assert.is_false(range.ok)
    assert.same("range", range.reason)
    assert.same(1, world.data:ItemCount("item7"))
    world.inRange = true
    for _, slot in ipairs({ 0, 100, 2, "x", 1.5 }) do
      assert.is_false(world:lotteryAction({ action = "Draw", slot = slot, seq = 10 }))
    end
    assert.same(1, world.data:ItemCount("item7"))
    assert.same(0, world.data.Data.FishCoin)
    assert.same(0, world.data:Serialize().meta.sequence)
  end)

  for _, entry in ipairs({ "on_player_added", "state_request" }) do
    it("test_recovered_result_pushed_once_" .. entry, function()
      give("item31")
      world.rolls = { 61, 70, 76 }
      assert.is_true(world:lotteryDraw(1, 1))
      local settled = world:messages("LotteryResult")[1]
      world:clearEvents()
      world:reconnect()
      world.data = world.players:GetDataInst(world.player)
      if entry == "state_request" then
        world:clearEvents()
        assert.is_true(world:lotteryState())
      end
      local recovered = world:messages("LotteryResult")
      assert.same(1, #recovered)
      assert.is_true(recovered[1].recovered)
      assert.same(settled.axes, recovered[1].axes)
      assert.same(settled.prize, recovered[1].prize)
      assert.same(1, world.data:ItemCount("item167"))
      assert.same(0, world.data:ItemCount("item31"))
      assert.same(0, world.data.Data.FishCoin)
    end)
  end

  it("test_triple_item_returns_to_the_freed_slot", function()
    give("item31")
    world.rolls = { 61, 70, 76 }
    assert.is_true(world:lotteryDraw(1, 1))
    local result = world:messages("LotteryResult")[1]
    assert.same("triple", result.outcome)
    assert.same({ kind = "item", itemId = "item167", name = "加速药水" }, result.prize)
    local item = world.data.Data.Containers[ITEM_BAR][1]
    assert.same("item167", item.itemId)
    assert.same(1, item.count)
    assert.is_nil(item.mult)
  end)
end)
