-- 条款 4-06 / 4-07 / 4-11（docs/acceptance/04-fishing-system.md）：
--   4-06 收线进度从 50% 起步；
--   4-07 收线进度每秒下降 5%，每次点收线按钮上升 5%；
--   4-11 进度降到 0 即脱钩，本次钓鱼结束。
-- A 级黑盒路径：客户端 CastAction 请求进入 MgrMap 注册的 MgrCast，真实上钩流程启动
-- MgrReelIn；测试只从玩家可见的 CastState 取收线会话号，再经 ReelInRE 发送点击，
-- 断言 ReelInRE 回包与 CastState 脱钩状态。不写 Cast.Sessions，不直接调用 Begin，
-- 不读会话内部字段。引擎边界（RE、World 时钟、Players）由 tests/support/reel_env.lua 替身适配。
-- 失败方式（先列后写）：
--   1. 起步不是 50：真实抛竿上钩后第一条收线回包的 progress 不是 50；
--   2. 衰减不是每秒 5%：空档 2 秒后进度不是 40；点击一次不是 +5；
--   3. 归零不脱钩：进度到 0 后玩家收不到 unhooked，或 CastState 没进入 unhooked。
local Reel = require('tests.support.reel_env')
local GameCfg = require('common.GameCfg')
local PlayerData = require('server.Data.PlayerData')

local function lastReply(player)
  return player.messages[#player.messages]
end

describe('条款 4：收线进度规则', function()
  local env, restore

  local function lastCastState()
    return env.a.castStates[#env.a.castStates]
  end

  -- 只发送玩家抛竿请求；收线会话由真实 MgrCast 上钩流程创建并自动开始。
  -- 会话号取自玩家可见的 CastState，而非管理器内部 Sessions。
  local function startReel()
    env.events.CastAction.OnServerEvent:Fire(env.a, {
      action = 'Cast', slot = 1, itemId = GameCfg.Items.Id.StarterRod,
    })
    env.now = env.now + GameCfg.Casting.HookDelaySec
    env.cast:Update()
    local state = lastCastState()
    assert.are.equal('hooked', state.phase)
    assert.are.equal('string', type(state.reelSession))
    local started = lastReply(env.a)
    assert.are.equal('started', started.action)
    assert.are.equal(state.reelSession, started.session)
    return state.reelSession, started
  end

  before_each(function()
    restore = {
      data = package.loaded['server.Mgr.MgrPlayerData'],
      fish = package.loaded['server.Mgr.MgrFishUnit'],
    }
    env = Reel.new('server')
    env:setUp()
    env.onFireClient = function(name, player, value)
      if name == 'ReelInRE' then
        player.messages[#player.messages + 1] = value
      elseif name == 'CastState' then
        player.castStates[#player.castStates + 1] = value
      end
    end
    env.a = {
      UserId = 1,
      messages = {},
      castStates = {},
      SetAttribute = function() end,
      CharacterAdded = Reel.signal(),
      CharacterRemoving = Reel.signal(),
      Character = {
        Position = { x = -11.75, y = 2, z = -17.25 },
        Rotation = { GetForward = function() return { x = 0, y = 0, z = 1 } end },
      },
    }
    env.data = PlayerData.New(env.a)
    env.data:Init()
    env.data:SelectSlot(1)
    env.data:SelectBait(GameCfg.Items.Id.Worm)
    package.loaded['server.Mgr.MgrPlayerData'] = {
      GetDataInst = function(_, player) return player == env.a and env.data end,
      SendItemBar = function() end,
    }
    package.loaded['server.Mgr.MgrFishUnit'] = {
      CanCast = function() return true end,
      HeldInfo = function() end,
    }
    env.cast = assert(loadfile('server/Mgr/MgrCast.lua'))()
    env.reel = assert(loadfile('server/Mgr/MgrReelIn.lua'))()
    env.reel.Cast = env.cast
    env.cast.ReelIn = env.reel
    env.cast.Quest = { Notify = function() end }
    env.reel:Start()
    env.cast:Start()
    env.reel:OnPlayerAdded(env.a)
    env.now = 0
  end)

  after_each(function()
    if env then
      if env.reel then env.reel:Stop() end
      if env.cast then env.cast:Stop() end
      if env.data then env.data:Destroy() end
      env:tearDown()
    end
    package.loaded['server.Mgr.MgrPlayerData'] = restore and restore.data
    package.loaded['server.Mgr.MgrFishUnit'] = restore and restore.fish
  end)

  -- 4-06：上钩那一刻玩家看到的进度就是 50%。
  it('4-06 收线进度从 50% 起步', function()
    local _, started = startReel()
    assert.are.equal('started', started.action)
    assert.are.equal(50, started.progress)
  end)

  -- 4-07：服务端按心跳把当前进度推给玩家；相邻两秒的读数差正好是一个「每秒 5%」。
  it('4-07 进度每秒下降 5%', function()
    startReel()
    env.now = env.now + 1.1
    env.reel:Update()
    local first = lastReply(env.a)
    assert.are.equal('progress', first.action)
    assert.near(45, first.progress, 0.01)
    env.now = env.now + 1
    env.reel:Update()
    local second = lastReply(env.a)
    assert.are.equal('progress', second.action)
    assert.near(5, first.progress - second.progress, 0.01)
  end)

  -- 4-07：同一时刻连点两次，两次读数之差正好是一次点击的 +5。
  -- 第一次点击那一包会顺带把 100 ms 聚合窗口的衰减算进去（-0.5），所以差值取第二、三包。
  it('4-07 每次点收线按钮上升 5%', function()
    local session = startReel()
    env.now = env.now + 2
    env.reel:Update()
    env.events.ReelInRE.OnServerEvent:Fire(env.a, { s = session, n = 1, q = 1 })
    local first = lastReply(env.a)
    assert.are.equal('progress', first.action)
    env.events.ReelInRE.OnServerEvent:Fire(env.a, { s = session, n = 1, q = 2 })
    local second = lastReply(env.a)
    assert.are.equal('progress', second.action)
    assert.near(5, second.progress - first.progress, 0.01)
  end)

  -- 4-11：停手后进度归零，玩家收到脱钩回包与 CastState，本次钓鱼结束。
  it('4-11 进度降到 0 即脱钩', function()
    local session = startReel()
    env.now = env.now + 30
    env.reel:Update()
    local reply = lastReply(env.a)
    assert.are.equal('unhooked', reply.action)
    assert.are.equal('unhooked', lastCastState().phase)
    assert.are.equal(session, lastCastState().reelSession)
    -- 会话结束：再点收线按钮不会再有新回包。
    local count = #env.a.messages
    env.events.ReelInRE.OnServerEvent:Fire(env.a, { s = session, n = 1, q = 2 })
    assert.are.equal(count, #env.a.messages)
  end)
end)
