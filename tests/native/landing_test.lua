local game_cfg = require("common.game_cfg")
local host = require("tests.support.fishing_host")

describe("上岸结算（server_runtime × fish_tree × Compendium）", function()
  local env
  after_each(function() if env then env:dispose() env = nil end end)

  local function hook_and_land()
    env:cast()
    env:hook()
    local session = env:last_state().reelSession
    env:click(session, 10, 1)
    return session
  end

  it("test_fish_lands_in_front_of_player", function()
    env = host.new({ roll = 1, multiplier_roll = 100 })
    hook_and_land()
    assert.are.equal("landed", env:last_state().phase)
    local fish
    for _, unit in ipairs(env.units) do if unit.fish then fish = unit.fish end end
    assert.is_not_nil(fish)
    assert.are.equal(-11.75, fish.Position.x)
    assert.are.equal(2.5, fish.Position.y)
    assert.are.equal(-18, fish.Position.z)
  end)

  it("test_landed_notifies_land_once_and_unhook_does_not", function()
    env = host.new()
    hook_and_land()
    local lands = 0
    for _, fact in ipairs(env.quests) do if fact.kind == "Land" then lands = lands + 1 end end
    assert.are.equal(1, lands)
    assert.are.equal(1, #env.compendium)
    env:advance(game_cfg.Casting.LandedHoldSec)
    env:cast()
    env:hook()
    env:close(env:last_state().reelSession)
    assert.are.equal(1, #env.compendium)
  end)

  it("test_duplicate_and_late_packets_do_not_duplicate_landed_fish", function()
    env = host.new()
    local session = hook_and_land()
    env:click(session, 10, 1)
    env:click(session, 10, 2)
    env:close(session)
    assert.are.equal(1, env:alive_units("LandedFish_"))
    assert.are.equal(1, #env.compendium)
  end)

  it("test_holding_fish_blocks_cast_without_bait_loss", function()
    env = host.new({ holding = true })
    local before = env.data:ItemCount(game_cfg.Items.Id.Worm)
    env:cast()
    assert.are.equal("holding", env:last_state().result.reason)
    assert.are.equal(before, env.data:ItemCount(game_cfg.Items.Id.Worm))
  end)

  it("test_landed_hold_returns_to_idle", function()
    env = host.new()
    hook_and_land()
    env:advance(game_cfg.Casting.LandedHoldSec)
    assert.are.equal("idle", env:last_state().phase)
  end)

end)
