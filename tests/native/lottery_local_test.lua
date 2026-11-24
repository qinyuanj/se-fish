local GameCfg = require("common.GameCfg")
local ClientWorld = require("tests.support.economy_client")

describe("抽奖机场景入口（#312 LotteryInteraction）", function()
  local env, options, anchorName
  before_each(function()
    anchorName = GameCfg.Lottery.MachineAnchors()[1]
    options = {
      interaction = true,
      anchors = { [anchorName] = { Name = anchorName, Position = { x = 0, y = 5, z = 0 } } },
      character = { Position = { x = 0, y = 0, z = 0 }, Size = { y = 2 } },
    }
    env = ClientWorld.new(options)
  end)
  after_each(function() if env then env:cleanup(); env = nil end end)

  it("test_bubble_per_anchor_and_missing_anchor_is_skipped", function()
    assert.same(1, #env.sceneNodes)
    assert.is_not_nil(env:child("BtnLotteryEnter"))
    assert.is_not_nil(env:child("LabelLotteryEnterTheme"))
  end)

  it("test_bubble_shows_within_radius_and_hides_outside", function()
    local bubble, radius = env.sceneNodes[1], GameCfg.Lottery.Radius
    options.character.Position.x = radius + 1
    env:step(0)
    assert.is_false(bubble.Visible)
    options.character.Position.x = radius - 1
    env:step(0)
    assert.is_true(bubble.Visible)
    options.character.Position.y = 999
    env:step(0)
    assert.is_true(bubble.Visible)
  end)

  it("test_click_opens_screen_and_leaving_range_closes_it", function()
    env:step(0)
    assert.is_true(env.sceneNodes[1].Visible)
    assert.is_true(env:click("BtnLotteryEnter"))
    assert.same("lottery", env.store.active_modal:now())
    options.character.Position.x = 999
    env:step(0)
    assert.is_nil(env.store.active_modal:now())
  end)

  it("test_clear_destroys_bubble_nodes_and_does_not_accumulate", function()
    local bubble = env.sceneNodes[1]
    local button, label = env:child("BtnLotteryEnter"), env:child("LabelLotteryEnterTheme")
    env:cleanup()
    assert.is_true(button.Destroyed)
    assert.is_true(label.Destroyed)
    assert.is_true(bubble.Destroyed)
    assert.same(0, button.OnClicked:Count())
    env = nil
  end)

  it("test_restart_rebuilds_instead_of_stacking_bubbles", function()
    local first, firstButton = env.sceneNodes[1], env:child("BtnLotteryEnter")
    env:cleanup()
    env = ClientWorld.new(options)
    assert.is_true(first.Destroyed)
    assert.same(0, firstButton.OnClicked:Count())
    assert.same(1, #env.sceneNodes)
    assert.are_not.equal(first, env.sceneNodes[1])
  end)

  it("test_update_does_not_touch_visibility_without_state_change", function()
    local bubble = env.sceneNodes[1]
    local writes = 0
    local mt = getmetatable(bubble)
    local old_newindex = mt.__newindex
    mt.__newindex = function(self, key, value)
      if key == "Visible" then writes = writes + 1 end
      old_newindex(self, key, value)
    end
    env:step(0)
    local after_change = writes
    env:step(0)
    env:step(0)
    assert.same(after_change, writes)
    options.character.Position.x = 999
    env:step(0)
    assert.same(after_change + 1, writes)
  end)
end)
