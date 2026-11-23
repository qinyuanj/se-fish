-- 抽奖机界面宿主规格（#312）：真实 ClientStore + RootView + LotteryView，EUI 为测试双。
-- 保留旧规格失败方式：选错投注格、客户端决定奖项、停轴顺序错、重复请求、重播动画、关窗丢结果、失败无提示。
local GameCfg = require("common.GameCfg")
local ClientWorld = require("tests.support.economy_client")

describe("抽奖机界面（#312 RootView 宿主）", function()
  local env
  before_each(function()
    env = ClientWorld.new()
    env:bar({ selectedSlot = 1, slots = { { itemId = "item7", count = 1, mult = 1 } } })
    env:open("lottery")
  end)
  after_each(function() if env then env:cleanup(); env = nil end end)

  local function result(extra)
    local value = {
      ok = true, seq = 1, axes = { 1, 2, 3 }, outcome = "pair",
      patternName = "鳄雀鳝", coins = 6, operation = { id = "op-1" },
    }
    for key, item in pairs(extra or {}) do value[key] = item end
    return value
  end

  it("test_awaiting_latch_releases_on_reply_timeout", function()
    assert.is_true(env:click("BtnLotteryDraw"))
    assert.is_false(env:click("BtnLotteryDraw"))
    assert.same(1, #env.sent.lottery)
    env:step(GameCfg.Lottery.ResultTimeoutSec - 0.1)
    assert.is_false(env:click("BtnLotteryDraw"))
    env:step(0.1)
    assert.is_true(env:click("BtnLotteryDraw"))
    assert.same(2, #env.sent.lottery)
    assert.matches("超时", env.notices[#env.notices])
  end)

  it("test_axis_stop_order_follows_config", function()
    local old = GameCfg.Lottery.AxisOrder
    GameCfg.Lottery.AxisOrder = { "middle", "left", "right" }
    env:click("BtnLotteryDraw")
    env:ingest("LotteryResult", result())
    env:step(GameCfg.Lottery.SpinSec)
    assert.same("蟹老板", env:child("LabelReelMiddle").Text)
    assert.same("?", env:child("LabelReelLeft").Text)
    env:step(GameCfg.Lottery.AxisStopIntervalSec)
    assert.same("鳄雀鳝", env:child("LabelReelLeft").Text)
    assert.same("?", env:child("LabelReelRight").Text)
    env:step(GameCfg.Lottery.AxisStopIntervalSec)
    assert.same("小白龙", env:child("LabelReelRight").Text)
    GameCfg.Lottery.AxisOrder = old
  end)

  it("test_bet_box_rejects_cooked_and_ordinary_and_empty", function()
    for _, entry in ipairs({
      { itemId = "carp", count = 1 },
      { itemId = "item7", count = 1, cooked = 1 },
      { itemId = "item31", count = 1, saved = { cooked = true } },
    }) do
      env:bar({ selectedSlot = 1, slots = { entry } })
      assert.is_false(env:child("BtnLotteryDraw").TouchEnabled)
      assert.is_false(env:click("BtnLotteryDraw"))
    end
    env:bar({ selectedSlot = 1, slots = {} })
    assert.matches("请先", env:child("LabelLotteryBet").Text)
    assert.same(0, #env.sent.lottery)
  end)

  it("test_bet_box_shows_selected_premium_with_actual_value", function()
    env:bar({ selectedSlot = 2, slots = { [2] = { itemId = "item31", count = 1, mult = 2 } } })
    assert.matches("100", env:child("LabelLotteryBet").Text)
    env:click("BtnLotteryDraw")
    assert.same(2, env.sent.lottery[1].slot)
  end)

  it("test_close_mid_animation_keeps_the_settled_result", function()
    env:click("BtnLotteryDraw")
    env:ingest("LotteryResult", result())
    env:step(GameCfg.Lottery.SpinSec)
    env:click("BtnLotteryClose")
    env:open("lottery")
    assert.matches("金币", env:child("LabelLotteryResult").Text)
    assert.same("鳄雀鳝", env:child("LabelReelLeft").Text)
    assert.same("小白龙", env:child("LabelReelRight").Text)
    assert.same("蟹老板", env:child("LabelReelMiddle").Text)
  end)

  it("test_draw_sends_slot_and_seq_once_per_click", function()
    env:click("BtnLotteryDraw")
    env:click("BtnLotteryDraw")
    assert.same({ { action = "Draw", slot = 1, seq = 1 } }, env.sent.lottery)
    env:ingest("LotteryResult", { ok = false, seq = 1, reason = "range" })
    env:click("BtnLotteryDraw")
    assert.same(2, env.sent.lottery[2].seq)
  end)

  it("test_failure_reasons_have_readable_notice", function()
    for _, reason in ipairs({ "not-premium", "cooked", "range", "slot" }) do
      env:ingest("LotteryResult", { ok = false, reason = reason })
      assert.is_true(#env.notices > 0)
      assert.is_true(env.notices[#env.notices] ~= "")
    end
  end)

  it("test_recovered_result_shows_without_animation", function()
    env:ingest("LotteryResult", result({ recovered = true }))
    assert.matches("金币", env:child("LabelLotteryResult").Text)
    assert.same("鳄雀鳝", env:child("LabelReelLeft").Text)
    env:step(0.1)
    assert.matches("金币", env:child("LabelLotteryResult").Text)
  end)

  it("test_reels_stop_left_right_middle_after_spin_seconds", function()
    env:click("BtnLotteryDraw")
    env:ingest("LotteryResult", result())
    env:step(GameCfg.Lottery.SpinSec - 0.01)
    assert.same("?", env:child("LabelReelLeft").Text)
    env:step(0.01)
    assert.same("鳄雀鳝", env:child("LabelReelLeft").Text)
    env:step(GameCfg.Lottery.AxisStopIntervalSec)
    assert.same("小白龙", env:child("LabelReelRight").Text)
    env:step(GameCfg.Lottery.AxisStopIntervalSec)
    assert.same("蟹老板", env:child("LabelReelMiddle").Text)
    assert.matches("金币", env:child("LabelLotteryResult").Text)
  end)

  it("test_replay_callback_does_not_restart_animation_or_result", function()
    env:click("BtnLotteryDraw")
    env:ingest("LotteryResult", result({ recovered = true }))
    local text = env:child("LabelLotteryResult").Text
    env:ingest("LotteryResult", result({ recovered = true, outcome = "none", axes = { 3, 2, 1 } }))
    assert.same(text, env:child("LabelLotteryResult").Text)
    assert.same("鳄雀鳝", env:child("LabelReelLeft").Text)
  end)

  it("test_triple_shows_jackpot_text_without_coins", function()
    env:ingest("LotteryResult", result({
      recovered = true, outcome = "triple", coins = nil,
      prize = { kind = "item", name = "加速药水" }, patternName = "三头鲨",
    }))
    assert.matches("加速药水", env:child("LabelLotteryResult").Text)
    assert.not_matches("金币", env:child("LabelLotteryResult").Text)
  end)

  it("test_clear_destroys_every_registered_node_and_listeners", function()
    local panel = env:child("ScreenLottery")
    local button = env:child("BtnLotteryDraw")
    env:cleanup()
    assert.is_true(panel.Destroyed)
    assert.is_true(button.Destroyed)
    assert.same(0, button.OnClicked:Count())
    env = nil
  end)

  it("test_rebuild_does_not_stack_previous_attempt", function()
    local first = env:child("ScreenLottery")
    local firstButton = env:child("BtnLotteryDraw")
    env:click("BtnLotteryClose")
    env:open("lottery")
    assert.is_true(first.Destroyed)
    assert.same(0, firstButton.OnClicked:Count())
    assert.is_not_nil(env:child("ScreenLottery"))
    assert.are_not.equal(first, env:child("ScreenLottery"))
  end)
end)
