-- 条款 4-06 / 4-07 / 4-11：真实 server_runtime 的 a 级黑盒路径。
local host = require("tests.support.fishing_host")

describe("条款 4：收线进度规则", function()
  local env
  after_each(function() if env then env:dispose() env = nil end end)

  local function start()
    env:cast()
    env:hook()
    local state = env:last_state()
    assert.are.equal("hooked", state.phase)
    return state.reelSession
  end

  it("test_reel_starts_at_fifty_and_click_adds_five", function()
    env = host.new()
    local session = start()
    assert.are.equal(50, env:reel_replies()[1].progress)
    env:click(session, 1, 1)
    assert.are.equal(55, env:reel_replies()[#env:reel_replies()].progress)
  end)

  it("test_reel_decays_five_each_second", function()
    env = host.new()
    start()
    env:advance(2)
    assert.are.equal(40, env:reel_replies()[#env:reel_replies()].progress)
  end)

  it("test_zero_unhooks_after_grace", function()
    env = host.new()
    start()
    env:advance(10.19)
    assert.are.equal("idle", env:last_state().phase)
    assert.are.equal(0, env:alive_units("CastLine_"))
  end)
end)
