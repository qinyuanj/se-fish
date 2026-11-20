-- 条款 4-06 / 4-07 / 4-11（docs/acceptance/04-fishing-system.md）：
--   4-06 收线进度从 50% 起步；
--   4-07 收线进度每秒下降 5%，每次点收线按钮上升 5%；
--   4-11 进度降到 0 即脱钩，本次钓鱼结束。
-- 只走业务入口：server/Mgr/MgrReelIn.lua 是 server/main.lua 的 MgrMap 注册管理器，玩家看到的是它下发的
-- ReelInRE 回包（action = started / progress / unhooked）。引擎边界（RE、World 时钟、Players）
-- 用 tests/support/reel_env.lua 的适配器替身，断言不读会话内部字段。
-- 失败方式（先列后写）：
--   1. 起步不是 50：Begin 后第一条回包的 progress 不是 50；
--   2. 衰减不是每秒 5%：空档 2 秒后进度不是 40；点击一次不是 +5；
--   3. 归零不脱钩：进度到 0 后玩家收不到 unhooked，会话还留着。
local Reel = require('tests.support.reel_env')

local function lastReply(player)
  return player.messages[#player.messages]
end

describe('条款 4：收线进度规则', function()
  local env, restore

  before_each(function()
    restore = { mgr = package.loaded['server.Mgr.MgrReelIn'] }
    env = Reel.new('server')
    env:setUp()
    -- 玩家收件箱只留 payload，回包内容就是玩家能看见的东西。
    env.onFireClient = function(_, player, value)
      player.messages[#player.messages + 1] = value
    end
    package.loaded['server.Mgr.MgrReelIn'] = nil
    env.mgr = require('server.Mgr.MgrReelIn')
    env.cast = { Sessions = {}, FinishReel = function(_, player, _, outcome)
      player.outcomes[#player.outcomes + 1] = outcome
    end }
    env.mgr.Cast = env.cast
    env.mgr:Start()
    env.a = { UserId = 1, messages = {}, outcomes = {},
      CharacterAdded = Reel.signal(), CharacterRemoving = Reel.signal() }
    env.mgr:OnPlayerAdded(env.a)
    env.cast.Sessions[1] = { player = env.a, session = { phase = 'hooked', reelSession = 's1' } }
    env.now = 0
  end)

  after_each(function()
    env.mgr:Stop()
    env:tearDown()
    package.loaded['server.Mgr.MgrReelIn'] = restore.mgr
  end)

  -- 4-06：上钩那一刻玩家看到的进度就是 50%。
  it('4-06 收线进度从 50% 起步', function()
    assert.is_true(env.mgr:Begin(env.a, 's1', env.now))
    local started = lastReply(env.a)
    assert.are.equal('started', started.action)
    assert.are.equal(50, started.progress)
  end)

  -- 4-07：服务端按心跳把当前进度推给玩家；相邻两秒的读数差正好是一个「每秒 5%」。
  it('4-07 进度每秒下降 5%', function()
    env.mgr:Begin(env.a, 's1', env.now)
    env.now = 1.1
    env.mgr:Update()
    local first = lastReply(env.a)
    assert.are.equal('progress', first.action)
    assert.near(45, first.progress, 0.01)
    env.now = 2.1
    env.mgr:Update()
    local second = lastReply(env.a)
    assert.are.equal('progress', second.action)
    assert.near(5, first.progress - second.progress, 0.01)
  end)

  -- 4-07：同一时刻连点两次，两次读数之差正好是一次点击的 +5。
  -- 第一次点击那一包会顺带把 100 ms 聚合窗口的衰减算进去（-0.5），所以差值取第二、三包。
  it('4-07 每次点收线按钮上升 5%', function()
    env.mgr:Begin(env.a, 's1', env.now)
    env.now = 2
    env.mgr:Update()
    env.events.ReelInRE.OnServerEvent:Fire(env.a, { s = 's1', n = 1, q = 1 })
    local first = lastReply(env.a)
    assert.are.equal('progress', first.action)
    env.events.ReelInRE.OnServerEvent:Fire(env.a, { s = 's1', n = 1, q = 2 })
    local second = lastReply(env.a)
    assert.are.equal('progress', second.action)
    assert.near(5, second.progress - first.progress, 0.01)
  end)

  -- 4-11：停手后进度归零，玩家收到脱钩回包，本次钓鱼结束。
  it('4-11 进度降到 0 即脱钩', function()
    env.mgr:Begin(env.a, 's1', env.now)
    env.now = 30
    env.mgr:Update()
    local reply = lastReply(env.a)
    assert.are.equal('unhooked', reply.action)
    assert.are.equal('unhooked', env.a.outcomes[1])
    -- 会话结束：再点收线按钮不会再有新回包。
    local count = #env.a.messages
    env.events.ReelInRE.OnServerEvent:Fire(env.a, { s = 's1', n = 1, q = 2 })
    assert.are.equal(count, #env.a.messages)
  end)
end)
