-- 原生 Busted（#87 迁移自 tests/gameplay/blindbox_settle_test.lua 的 TestBlindboxSettle）。
--   1. 校验漏洞：payload 畸形（无 action/seq）、count 不是 1 或 10、同 seq 重复点击被接受；
--   2. 扣费顺序错：没等平台购买成功就抽（先发货后扣费）；购买取消/失败/超时却照发奖或动了保底计数；
--   3. 保底衔接错：Extra.lottery.pity 没进 draft（十连跨保底线不触发）、落账后 pity 写不回存档；
--   4. 满格落地错：无空格时抽中物消失（没走 Loot:SpawnItem）、或重放结果时重复落地；
--   5. 幂等错：同 seq 重试重复扣费/重复发奖；重进后 pity 丢失、State 握手不回包；
--   6. 生产守卫漏：Debug 关 + 商品未配置时仍放行（应明确 unavailable 不发付费权益）；
--   7. 并发错：购买 flow 在飞时第二抽被接受（应 busy）；flow 结算串到别的请求。
--   MgrPlatform（#123 持久操作协议），替换引擎边界（game / REUtil / DataStore / 时钟）；
-- 迁移说明：引擎边界夹具下沉到 tests/support/blindbox_world.lua（调用方各自实例化，
--   互不共享状态）；案例按旧 LuaUnit 实际执行序（方法名字典序）逐个 it 注册。
local GameCfg = require("common.game_cfg")
local BlindboxWorld = require("tests.support.blindbox_world")
local RandomGuard = require("tests.support.random_guard")

describe("盲盒服务端结算（ServerRuntime × MgrSave × MgrPlatform）", function()
  local world
  before_each(function()
    world = BlindboxWorld.new()
    world:setUp()
  end)
  after_each(function()
    -- 但 MgrSave / MgrLoot 读全局 math.random()，故逐案例还原，杜绝泄漏到后续案例。
    RandomGuard.restore()
    if world then
      world:tearDown()
      world = nil
    end
  end)

  it("test_collection_unlock_without_catch_record", function()
    world.rolls = { 1000 }
    world:draw(1, 1, "success")
    world:drain()
    assert.is_true(world.data.Extra.collection.unlocked["item7"])
    assert.same({}, world.data.Extra.collection.weights)
    assert.same({}, world.data.Extra.collection.catches or {})
    assert.same(0, world.data.Extra.collection.total or 0)
    world:reconnect()
    assert.is_true(world.players:GetDataInst(world.player).Extra.collection.unlocked["item7"])
  end)

  it("test_delivery_confirmation_rejected_then_reconnect_does_not_duplicate", function()
    while world.data:AddItem("carp") do
    end
    world:persistReady()
    local execute = world.save.Execute
    world.save.Execute = function(mgr, player, data, op, transform, done)
      if op.kind == "blindbox:delivery" then
        return false, "pending"
      end
      return execute(mgr, player, data, op, transform, done)
    end
    world.rolls = { 1000 }
    world:draw(1, 1, "success")
    assert.same(1, #world:groundItems())
    assert.is_not_nil(next(world.data.Extra.lottery.deliveries))
    world.save.Execute = execute
    world:reconnect()
    world.data = world.players:GetDataInst(world.player)
    world:blindboxState()
    world:pump()
    world:drain()
    assert.same(1, #world:groundItems())
    assert.is_nil(next(world.data.Extra.lottery.deliveries))
  end)

  it("test_failed_ground_delivery_survives_reconnect", function()
    while world.data:AddItem("carp") do
    end
    world:persistReady()
    world.failDeliveries = true
    world.rolls = { 1000 }
    world:draw(1, 1, "success")
    world:pump()
    world:drain()
    assert.is_true(world:lastResult().deliveryPending)
    assert.same(0, #world:groundItems())
    world:reconnect()
    world.data = world.players:GetDataInst(world.player)
    world.failDeliveries = false
    world:blindboxState()
    world:pump()
    world:pump()
    world:drain()
    assert.same(1, #world:groundItems())
    assert.is_nil(next(world.data.Extra.lottery.deliveries))
    world:pump()
    world:drain()
    assert.same(1, #world:groundItems())
  end)

  it("test_failed_payment_grants_nothing_and_keeps_pity", function()
    -- 取消/失败/超时：不发奖、不动 pity，回包带原因；同一 seq 可以重试（未落账不记账）
    for index, outcome in ipairs({ "cancel", "fail", "timeout" }) do
      world.events = {}
      if outcome == "timeout" then
        assert.is_true(world:blindboxAction({ action = "Draw", count = 1, seq = index }))
        world:drain()
        world.now = world.now + GameCfg.Platform.FlowTimeoutSec
        world.platform:Update()
        world:drain()
      else
        assert.is_true(world:draw(1, index, outcome))
      end
      local result = world:lastResult()
      assert.is_false(result.ok)
      assert.same(outcome, result.reason)
    end
    assert.same(0, world.data:ItemCount("item7"))
    assert.same(0, world.data.Extra.lottery.pity)
  end)

  it("test_full_inventory_lands_on_ground", function()
    -- 满格按区落地：道具栏+背包全满时抽中物落地（Loot:SpawnItem），回包带 landed 标记
    while world.data:AddItem("carp") do
    end
    world:persistReady()
    world.rolls = { 1000 }
    assert.is_true(world:draw(1, 1, "success"))
    local result = world:lastResult()
    assert.is_true(result.ok)
    assert.is_true(result.draws[1].landed)
    assert.same(1, result.grounded)
    assert.same(1, #world:groundItems())
    assert.same("item7", world:groundItems()[1].itemId)
    assert.same(1, world:groundItems()[1].mult)
    assert.same(1, world.data.Extra.lottery.pity) -- 落地也算抽过，计数照常推进
  end)

  it("test_loot_delivery_key_remains_consumed_after_entity_disappears", function()
    local ServerRuntime = require("server.WorldHost.ServerRuntime")
    local SpokeClock = require("common.spoke_clock")
    local clock = SpokeClock.new(1)
    local runtime = ServerRuntime.new({
      clock = clock, initial_now = 1,
      remote = { GetRE = function() return { FireAllClients = function() end, FireClient = function() end, OnServerEvent = { Connect = function() return { Disconnect = function() end } end } } end, CheckRECD = function() return false end },
      create_unit = function() local u = { Destroyed = false } function u:Destroy() self.Destroyed = true end return u end,
      bait_spots = { RespawnSec = 15, Spots = {} },
    })
    runtime:start()
    local world = runtime:get_world()
    local first = world:place_delivery("paid:1", "fishPond", { kind = "item", itemId = "item7", count = 1, x = 1, y = 0, z = 1 })
    local again = world:place_delivery("paid:1", "fishPond", { kind = "item", itemId = "item7", count = 1, x = 9, y = 0, z = 9 })
    assert.same(first.Id, again.Id)
    assert.equals(1, #world:ground_snapshot().list)
    runtime:shutdown()
  end)

  it("test_malformed_payloads_rejected", function()
    -- 校验：畸形 payload / 非法 count / 非法 seq 一律拒绝，不建 flow、不回包
    assert.is_false(world:blindboxAction(nil))
    assert.is_false(world:blindboxAction({ action = "Peek", count = 1, seq = 1 }))
    assert.is_false(world:blindboxAction({ action = "Draw", count = 3, seq = 1 }))
    assert.is_false(world:blindboxAction({ action = "Draw", count = "10", seq = 1 }))
    assert.is_false(world:blindboxAction({ action = "Draw", count = 1 }))
    assert.is_false(world:blindboxAction({ action = "Draw", count = 1, seq = 0 }))
    assert.is_false(world:blindboxAction({ action = "Draw", count = 1, seq = 1.5 }))
    assert.is_false(world.platform:HasFlow(world.player))
    assert.same({}, world:messages("BlindboxResult"))
  end)

  it("test_natural_jackpot_resets_persisted_pity", function()
    -- 自然中大奖：pity 立即归零落账
    world.data.Extra.lottery.pity = 30
    world:persistReady()
    world.rolls = { 3 } -- 极品美人鱼权重区
    assert.is_true(world:draw(1, 1, "success"))
    local result = world:lastResult()
    assert.is_true(result.draws[1].jackpot)
    assert.is_false(result.draws[1].guaranteed)
    assert.same(0, world.data.Extra.lottery.pity)
    assert.same(1, world.data:ItemCount("item108"))
  end)

  it("test_new_request_receives_original_pending_identity", function()
    world:draw(1, 1)
    local key = next(world.data.Extra.lottery.intents)
    world:draw(1, 2)
    local result = world:lastResult()
    assert.same(2, result.seq)
    assert.same(1, result.originalSeq)
    assert.same(key, result.requestId)
    world.rolls = { 1000 }
    world.platform:HandleTestAction(world.player, { action = "ResolveFlow", outcome = "success" })
    world:drain()
    world:blindboxAction({ action = "Query", count = 1, seq = 1, requestId = key })
    assert.is_true(world:lastResult().ok)
    assert.same(1, world:lastResult().seq)
    assert.same(1, world.data:ItemCount("item7"))
  end)

  it("test_no_character_preserves_delivery_and_unlocks_without_record", function()
    while world.data:AddItem("carp") do
    end
    world.data.Extra.collection.unlocked.item7 = true
    world.data.Extra.collection.weights.item7 = 12.34
    world:persistReady()
    local character = world.player.Character
    world.player.Character = nil
    world.rolls = { 1000 }
    world:draw(1, 1, "success")
    assert.same(0, #world:groundItems())
    assert.is_true(world:lastResult().deliveryPending)
    assert.is_true(world.data.Extra.collection.unlocked.item7)
    assert.same(12.34, world.data.Extra.collection.weights.item7)
    world.player.Character = character
    world:pump()
    world:drain()
    assert.same(1, #world:groundItems())
    world:blindboxAction({ action = "Draw", count = 1, seq = 1 })
    world:drain()
    assert.same(1, #world:groundItems())
    assert.same(12.34, world.data.Extra.collection.weights.item7)
  end)

  it("test_old_epoch_does_not_block_current_delivery", function()
    local b = world.data.Extra.lottery
    b.deliveries = {
      old = { epoch = "old-world", itemId = "item7" },
      current = { epoch = "test-world", itemId = "item7" },
    }
    world:persistReady()
    world:pump()
    world:drain()
    assert.same(1, #world:groundItems())
    assert.is_not_nil(world.data.Extra.lottery.deliveries.old)
    assert.is_nil(world.data.Extra.lottery.deliveries.current)
  end)

  it("test_paid_write_sync_rejection_keeps_recoverable_intent", function()
    world.rolls = { 1000 }
    world:draw(1, 1)
    world:drain()
    local execute = world.save.Execute
    world.save.Execute = function(mgr, player, data, op, transform, done)
      if op.kind == "blindbox" then
        return false, "expired"
      end
      return execute(mgr, player, data, op, transform, done)
    end
    world.platform:HandleTestAction(world.player, { action = "ResolveFlow", outcome = "success" })
    world:drain()
    assert.same("expired", world:lastResult().reason)
    assert.is_true(world:lastResult().deliveryPending)
    world.save.Execute = execute
    world:reconnect()
    world.data = world.players:GetDataInst(world.player)
    world:blindboxState()
    world:pump()
    world:drain()
    assert.same(1, world.data:ItemCount("item7"))
  end)

  it("test_payment_wait_does_not_reserve_sequence", function()
    -- 审查失败方式：支付等待期别的操作推进 sequence；Execute 同步拒绝；落地失败/无角色；
    -- 落地成功确认写失败后重进；盲盒收集解锁不改钓取纪录。
    world.rolls = { 1000 }
    world:draw(1, 1)
    world:drain()
    local op = assert(world.save:ResolveRequest(world.player, world.data, "other", 1))
    assert.is_true(world.save:Execute(world.player, world.data, op, function(draft)
      draft:AddFishCoin(1)
      return { ok = true }
    end, function() end))
    world:drain()
    assert.is_true(world.platform:HandleTestAction(world.player,
      { action = "ResolveFlow", outcome = "success" }))
    world:drain()
    world:pump()
    world:drain()
    assert.same(1, world.data:ItemCount("item7"))
    assert.is_true(world:lastResult().ok)
  end)

  it("test_pity_survives_reconnect_and_state_sync", function()
    -- 重进：pity 从存档恢复，State 握手回包当前计数
    world.rolls = { 1000, 1000, 1000 }
    assert.is_true(world:draw(1, 1, "success"))
    assert.is_true(world:draw(1, 2, "success"))
    assert.is_true(world:draw(1, 3, "success"))
    assert.same(3, world.data.Extra.lottery.pity)
    world.events = {}
    world:reconnect() -- 离开后新对象读档
    world:drain()
    local restored = world.players:GetDataInst(world.player)
    assert.same(3, restored.Extra.lottery.pity)
    world:blindboxState()
    world:pump()
    local state = world:lastResult()
    assert.is_true(state.ok)
    assert.same("State", state.action)
    assert.same(3, state.pity)
  end)

  it("test_pricing_uses_configured_goods", function()
    -- 单抽 10 金豆、十连 90 金豆：价目来自 GameCfg.Platform.Goods（goodsId 未交付走测试 flow）
    assert.same(10, GameCfg.Platform.Goods.blindboxSingle.beans)
    assert.same(90, GameCfg.Platform.Goods.blindboxTen.beans)
  end)

  it("test_production_build_rejects_unconfigured_goods", function()
    -- 生产守卫（#261）：Debug 关时真实通道仍关闭，占位通道也关掉才是「无可用支付通道」→
    -- 明确 unavailable，不建 flow 不发奖、不落抽奖意向。占位通道开着时的完整路径见
    -- tests/native/spec/15_blindbox_placeholder_settlement_test.lua。
    GameCfg.Debug = { Enabled = false }
    GameCfg.Platform.Placeholder.Enabled = false
    assert.is_true(world:blindboxAction({ action = "Draw", count = 1, seq = 1 }))
    world:drain()
    local result = world:lastResult()
    assert.is_false(result.ok)
    assert.same("unavailable", result.reason)
    assert.same(0, world.data:ItemCount("item7"))
    assert.same(0, world.data.Extra.lottery.pity)
    assert.is_false(world.platform:HasFlow(world.player))
  end)

  it("test_production_build_uses_placeholder_channel_not_test_driver", function()
    -- 生产守卫（#261）：Debug 关 + 占位通道开 + 显式 AllowInPublish（#249 闸门）→
    -- 只有占位确认能结算；测试驱动器在生产碰不到占位 flow（不能伪造支付成功），确认前不发奖。
    GameCfg.Debug = { Enabled = false }
    GameCfg.Platform.Placeholder.Enabled = true
    GameCfg.Platform.Placeholder.AllowInPublish = true
    world.rolls = { 1000 }
    assert.is_true(world:blindboxAction({ action = "Draw", count = 1, seq = 1 }))
    world:drain()
    assert.is_false(world.platform:HandleTestAction(world.player,
      { action = "ResolveFlow", outcome = "success" }))
    assert.same(0, world.data:ItemCount("item7"))
    assert.is_true(world.platform:HasFlow(world.player))
    assert.is_true(world.platform:HandleAction(world.player,
      { action = "PlaceholderOutcome", outcome = "success" }))
    world:drain()
    assert.same(1, world.data:ItemCount("item7"))
    assert.is_false(world.platform:HasFlow(world.player))
  end)

  it("test_query_identity_cannot_create_purchase", function()
    world:draw(1, 1)
    local key = next(world.data.Extra.lottery.intents)
    local flows = world.platform.NextFlowId
    world:blindboxAction({ action = "Query", count = 1, seq = 1, requestId = key })
    assert.same(flows, world.platform.NextFlowId)
    world:blindboxAction({ action = "Query", count = 1, seq = 99, requestId = "expired" })
    assert.same("expired", world:lastResult().reason)
    assert.same(flows, world.platform.NextFlowId)
  end)

  it("test_real_paid_write_failure_retains_fact_until_retry", function()
    world.rolls = { 1000 }
    world:draw(1, 1)
    world.failWrites = true
    world.platform:HandleTestAction(world.player, { action = "ResolveFlow", outcome = "success" })
    world:drain()
    assert.same(0, world.data:ItemCount("item7"))
    local key = next(world.data.Extra.lottery.intents)
    assert.same("awaiting", world.data.Extra.lottery.intents[key].state)
    world.failWrites = false
    world.save:Drain(world.player.UserId)
    world:drain()
    world:pump()
    world:drain()
    assert.same(1, world.data:ItemCount("item7"))
    world:reconnect()
    assert.same(1, world.data:ItemCount("item7"))
  end)

  it("test_real_write_failure_prevents_payment_open", function()
    world.failWrites = true
    world:draw(1, 1)
    assert.is_false(world.platform:HasFlow(world.player))
    assert.same(0, world.data:ItemCount("item7"))
    world.failWrites = false
  end)

  it("test_retry_replays_result_without_double_grant", function()
    -- 同 seq 重试：只回放原结果，不重复扣费（不再建 flow）、不重复发奖、不重复落地
    while world.data:AddItem("carp") do
    end
    world:persistReady()
    world.rolls = { 1000 }
    assert.is_true(world:draw(1, 7, "success"))
    assert.same(1, #world:groundItems())
    world.events = {}
    assert.is_true(world:blindboxAction({ action = "Draw", count = 1, seq = 7 }))
    world:drain()
    assert.is_false(world.platform:HasFlow(world.player)) -- 重试不再发起购买
    local replay = world:lastResult()
    assert.is_true(replay.ok)
    assert.same("item7", replay.draws[1].itemKey)
    assert.same(1, #world:groundItems())
    assert.same(1, world.data.Extra.lottery.pity) -- 计数不重复推进
  end)

  it("test_second_draw_busy_while_payment_in_flight", function()
    -- 并发：购买 flow 在飞时第二抽 busy 拒绝；第一个 flow 不受影响正常结算
    world.rolls = { 1000 }
    assert.is_true(world:blindboxAction({ action = "Draw", count = 1, seq = 1 }))
    world:drain()
    assert.is_true(world.platform:HasFlow(world.player))
    world.events = {}
    assert.is_true(world:blindboxAction({ action = "Draw", count = 1, seq = 2 }))
    local busy = world:lastResult()
    assert.is_false(busy.ok)
    assert.same("busy", busy.reason)
    assert.is_true(world.platform:HandleTestAction(world.player,
      { action = "ResolveFlow", outcome = "success" }))
    world:drain()
    assert.same(1, world.data:ItemCount("item7")) -- 只有第一抽发货
    assert.same(1, world.data.Extra.lottery.pity)
  end)

  it("test_single_draw_grants_after_payment_success", function()
    -- 单抽：购买成功后抽中物进道具栏，pity 落账，回包带逐抽明细
    world.rolls = { 1000 } -- 末权重：极品罗非鱼
    assert.is_true(world:draw(1, 1, "success"))
    assert.same(1, world.data:ItemCount("item7"))
    assert.same(1, world.data.Extra.lottery.pity)
    local result = world:lastResult()
    assert.is_true(result.ok)
    assert.same(1, result.count)
    assert.same(1, #result.draws)
    assert.same("item7", result.draws[1].itemKey)
    assert.is_false(result.draws[1].jackpot)
    assert.same(0, result.pityBefore)
    assert.same(1, result.pityAfter)
    assert.same({}, world:groundItems())
  end)

  it("test_ten_draws_settle_pity_across_the_line", function()
    -- 十连跨保底线：存档 pity=45 进场，第 5 抽（累计第 50 次）保底大奖，pity 落账归零后重计
    world.data.Extra.lottery.pity = 45
    world:persistReady()
    world.rolls = { 1000, 1000, 1000, 1000, 2, 1000, 1000, 1000, 1000, 1000 }
    assert.is_true(world:draw(10, 1, "success"))
    local result = world:lastResult()
    assert.is_true(result.ok)
    assert.same(10, #result.draws)
    assert.same(45, result.pityBefore)
    assert.is_true(result.draws[5].guaranteed)
    assert.same("item107", result.draws[5].itemKey) -- 保底二选一第二件：极品蛇颈龙
    assert.same(0, result.draws[5].pityAfter)
    assert.same(5, result.pityAfter)
    assert.same(5, world.data.Extra.lottery.pity) -- 落账后与结果一致
    -- 初始容量只有 2+5=7 格：保底大奖 + 6 件入库，余 3 件按区落地
    assert.same(1, world.data:ItemCount("item107"))
    assert.same(6, world.data:ItemCount("item7"))
    assert.same(3, result.grounded)
    assert.same(3, #world:groundItems())
    for _, drop in ipairs(world:groundItems()) do
      assert.same("item7", drop.itemId)
    end
  end)

  it("test_terminal_retention_and_safe_expiry", function()
    for seq = 1, 40 do
      world.rolls = { 1000 }
      world:draw(1, seq, "cancel")
    end
    local n = 0
    for _ in pairs(world.data.Extra.lottery.intents) do
      n = n + 1
    end
    assert.is_true(n <= 32)
    world:draw(1, 1)
    assert.is_false(world.platform:HasFlow(world.player))
    assert.same("expired", world:lastResult().reason)
  end)

  it("test_unavailable_does_not_persist_intent", function()
    -- 真实通道与占位通道都不可用时，连抽奖意向都不落（不留单边状态）。
    GameCfg.Debug = { Enabled = false }
    GameCfg.Platform.Placeholder.Enabled = false
    world:draw(1, 1)
    assert.is_nil(next(world.data.Extra.lottery.intents or {}))
  end)

  it("test_unknown_payment_blocks_new_session_purchase", function()
    world:draw(1, 1)
    world:reconnect()
    world:blindboxState()
    world:pump()
    world:drain()
    world:draw(1, 2)
    assert.is_false(world.platform:HasFlow(world.player))
    assert.same("unknown", world:lastResult().reason)
  end)

  it("test_unknown_previous_world_delivery_requires_reconciliation", function()
    while world.data:AddItem("carp") do
    end
    world:persistReady()
    world.failDeliveries = true
    world.rolls = { 1000 }
    world:draw(1, 1, "success")
    for _, delivery in pairs(world.data.Extra.lottery.deliveries) do
      delivery.epoch = "old-world"
    end
    world.failDeliveries = false
    world:pump()
    world:drain()
    assert.is_not_nil(next(world.data.Extra.lottery.deliveries))
    assert.same(0, #world:groundItems())
  end)
end)
