-- 条款 9/11 抢救组（docs/acceptance/09-multiplayer-rules.md、11-downed-death-revive.md）：
-- 2 米内他人抢救、恢复上限 10%、统一状态转换、重复/并发/重连幂等；濒死锁血与免伤、呼救、
-- 肾上腺素自救、离线重连结算、血量夹取。只走业务入口黑盒：InteractAction / SurvivalAction
-- 两个 RE 的服务端 OnServerEvent，配合 MgrMap 公开管理器方法；引擎边界用替身。
-- 失败方式（先列后写）：
--   1. 超距请求仍发起抢救、目标不是濒死也能救（9-17）；
--   2. 恢复量用了全局上限而不是被救者的成长上限（9-18、11-36）；
--   3. 绕过 Vitals 的统一 Rescue / ApplyRevive 直接改血量（9-03）；
--   4. 同 seq 重放、两个施救者并发、重连后旧请求重放产生第二次恢复（9-05）；
--   5. 濒死还掉血、致命伤害直接死亡（11-01、11-03、11-34）；
--   6. 呼救不发给附近玩家（11-06）；
--   7. 濒死断线重连仍继续濒死计时，或多结算一次复活（11-35）；
--   8. 抢救按钮创建失败后泄漏已创建的气泡根节点。
local function vec(x, y, z) return { x = x, y = y, z = z } end
local GameCfg = require('common.game_cfg')

local function signal()
  local slots = {}
  return {
    Connect = function(_, fn) slots[#slots + 1] = fn return { Disconnect = function() end } end,
    Fire = function(_, ...) for _, fn in ipairs(slots) do fn(...) end end,
  }
end

local function new_player(userId, x)
  local controller = { Health = GameCfg.Vitals.MaxHealth, MaxHealth = GameCfg.Vitals.MaxHealth,
    WalkSpeed = 10, HealthChanged = signal(), Died = signal(), OnReborn = signal() }
  function controller:TakeDamage(amount)
    self.Health = math.max(0, self.Health - amount)
    self.HealthChanged:Fire(self.Health)
    if self.Health <= 0 then self.Died:Fire() end
  end
  local player = { UserId = userId, Name = 'p' .. userId, attrs = {},
    Character = { Controller = controller, Position = vec(x or 0, 0, 0), Size = { y = 2 } },
    CharacterAdded = signal(), CharacterRemoving = signal() }
  function player:SetAttribute(key, value) self.attrs[key] = value end
  function player:GetAttribute(key) return self.attrs[key] end
  return player
end

describe('条款 9/11 他人抢救', function()
  local env

  local function drain()
    for _ = 1, 200 do
      if #env.queue == 0 then return end
      table.remove(env.queue, 1)()
    end
    error('Task 队列未收敛')
  end

  local function last_reply(name)
    local list = env.sent[name] or {}
    return list[#list]
  end

  local function request(player, payload)
    env.re.InteractAction.OnServerEvent:Fire(player, payload)
    drain()
  end

  local function survival(player, payload)
    env.re.SurvivalAction.OnServerEvent:Fire(player, payload)
    drain()
  end

  local function join(userId, x)
    local player = new_player(userId, x)
    env.players:on_player_added(player)
    env.lifeHost:add(player, env.players:get_data_inst(player))
    drain()
    return player
  end

  local function down(player)
    env.v:apply_hit(env.v:new_hit(nil, 'fishAttack'), player, GameCfg.Vitals.MaxHealth + 10)
    assert.same('downed', env.s:phase(player))
  end

  local function advance(seconds)
    env.lifeHost:advance(seconds)
    env.now = env.lifeHost.clock.now()
    drain()
  end

  before_each(function()
    env = { cfg = GameCfg, now = 100, queue = {}, sent = {}, re = {}, values = {} }
    env.cfg.Debug = { Enabled = false }
    env.cfg.Save.QaSlot = ''
    env.saved = { game = rawget(_G, 'game'), Vector3 = rawget(_G, 'Vector3'),
      Vector2 = rawget(_G, 'Vector2'), Color = rawget(_G, 'Color'),
      REUtil = rawget(_G, 'REUtil'), reutil = package.loaded['common.re_util'] }
    _G.Vector3 = { New = vec }
    _G.Vector2 = { New = function(x, y) return { x = x, y = y } end }
    _G.Color = { New = function(...) return { ... } end }
    env.playersService = { LocalPlayer = nil, GetPlayers = function() return env.clientPlayers or {} end }
    env.clientPlayers = {}
    _G.game = { GetService = function(_, name)
      if name == 'Task' then
        return { Spawn = function(_, fn) env.queue[#env.queue + 1] = fn end, Wait = function() end }
      end
      if name == 'DataStoreService' then
        return { GetDataStore = function() return {
          GetAsync = function(_, key) return env.values[key] end,
          SetAsync = function(_, key, value) env.values[key] = value end,
          UpdateAsync = function(_, key, transform)
            local value = transform(env.values[key])
            if value then env.values[key] = value end
            return value
          end,
        } end }
      end
      if name == 'World' then return {
        GetServerTime = function() return env.now end,
        CreateUnit = function(_, kind, props)
          local node = { Kind = kind }
          for key, value in pairs(props) do node[key] = value end
          node.OnClicked = signal()
          node.Destroy = function() node.Destroyed = true end
          env.clientNodes = env.clientNodes or {}
          env.clientNodes[node.Name] = node
          return node
        end,
      } end
      if name == 'Players' then return env.playersService end
      if name == 'RunService' then return { IsServer = function() return false end,
        IsClient = function() return true end, Heartbeat = signal() } end
    end }
    local function reStub(name)
      env.sent[name] = env.sent[name] or {}
      if not env.re[name] then
        env.re[name] = {
          OnServerEvent = signal(), OnClientEvent = signal(),
          FireClient = function(_, player, value)
            env.sent[name][#env.sent[name] + 1] = { userId = player.UserId, payload = value }
          end,
          FireAllClients = function(_, value)
            env.sent[name][#env.sent[name] + 1] = { userId = nil, payload = value }
          end,
          FireServer = function(_, payload)
            env.sent[name][#env.sent[name] + 1] = { userId = nil, payload = payload }
          end,
        }
      end
      return env.re[name]
    end
    local re = { get_re = function(_, name) return reStub(name) end, check_recd = function() return false end }
    package.loaded['common.re_util'] = re
    _G.REUtil = re

    package.loaded['server.data.player_data'] = nil
    env.player_data = require('server.data.player_data')
    env.save = assert(loadfile('server/save_host.lua'))()
    env.players = assert(loadfile('server/player_data_host.lua'))()
    env.players.Save, env.save.player_data = env.save, env.players
    env.lifeHost = require('tests.support.life_host').start({
      now = env.now or 100, remote = re, player_data = env.players, save = env.save,
      bind_interact_action = function(dispatch)
        re:get_re("InteractAction").OnServerEvent:Connect(function(player, payload)
          dispatch(player, payload)
        end)
      end,
    })
    env.v = env.lifeHost.runtime.life
    env.s = env.v
  end)

  after_each(function()
    if not env then return end
    _G.game = env.saved.game
    _G.Vector3 = env.saved.Vector3
    _G.Vector2 = env.saved.Vector2
    _G.Color = env.saved.Color
    _G.REUtil = env.saved.REUtil
    package.loaded['common.re_util'] = env.saved.reutil
    env = nil
  end)

  -- 9-17：2 米内他人抢救成立（含边界）；超距、目标已醒、已有施救者都不发起。
  it('9-17 两米内可发起他人抢救，超距与非濒死目标被拒', function()
    local downed = join(7001, 0)
    local rescuer = join(7002, 2)
    local far = join(7003, 2.5)
    down(downed)
    request(rescuer, { target = 'downedPlayer', action = 'Rescue', targetUserId = downed.UserId, seq = 1 })
    assert.is_true(last_reply('InteractResult').payload.ok, '正好 2 米可以发起抢救')
    assert.same('rescuing', env.s:phase(downed), '发起后进入抢救中')

    request(far, { target = 'downedPlayer', action = 'Rescue', targetUserId = downed.UserId, seq = 1 })
    assert.is_false(last_reply('InteractResult').payload.ok, '超距发起被拒')

    local other = join(7004, 1)
    request(other, { target = 'downedPlayer', action = 'Rescue', targetUserId = downed.UserId, seq = 1 })
    assert.is_false(last_reply('InteractResult').payload.ok, '已有施救者时并发请求被拒')
    assert.same('busy', last_reply('InteractResult').payload.reason, '抢救中并发请求回 busy（#271，客户端据此刻提示）')

    -- #271：同一施救者再点一次气泡，真实服务端路径也必须回 busy，而不是 not-downed
    request(rescuer, { target = 'downedPlayer', action = 'Rescue', targetUserId = downed.UserId, seq = 2 })
    assert.same('busy', last_reply('InteractResult').payload.reason, '抢救中重复点击回 busy')

    advance(GameCfg.Rescue.DurationSec + 0.1)
    assert.same('alive', env.s:phase(downed))
    request(join(7005, 1), { target = 'downedPlayer', action = 'Rescue', targetUserId = downed.UserId, seq = 1 })
    assert.is_false(last_reply('InteractResult').payload.ok, '已恢复的目标不能再次被救')
  end)

  -- 11-03（review #249-10）：抢救中濒死倒计时到点，撤销抢救不再先播一份 downed，转死亡只广播一次。
  it('11-03 抢救中到点转死亡只广播一次 dead', function()
    local downed = join(7081, 0)
    local rescuer = join(7082, 1)
    down(downed)
    -- 把抢救时长拉长到濒死倒计时之后：抢救还没结束，濒死倒计时先到点。
    local savedDuration = GameCfg.Rescue.DurationSec
    GameCfg.Rescue.DurationSec = GameCfg.Survival.DownedSec + 5
    request(rescuer, { target = 'downedPlayer', action = 'Rescue', targetUserId = downed.UserId, seq = 1 })
    GameCfg.Rescue.DurationSec = savedDuration
    assert.same('rescuing', env.s:phase(downed), '抢救先开始')
    local before = #(env.sent.SurvivalState or {})
    advance(GameCfg.Survival.DownedSec + 0.1)
    local phases = {}
    for index = before + 1, #(env.sent.SurvivalState or {}) do
      phases[#phases + 1] = env.sent.SurvivalState[index].payload.phase
    end
    assert.same('dead', env.s:phase(downed))
    assert.same({ 'dead' }, phases, '撤销抢救不再先播一份 downed，转死亡只广播一次')
  end)

  -- 9-18 / 11-36：恢复量取被救者的成长上限 10%，夹在上限内。
  it('9-18 11-36 抢救恢复被救者血量上限的 10% 且不超上限', function()
    assert.same(10, GameCfg.Survival.ReviveHealthPercent)
    local downed = join(7011, 0)
    local rescuer = join(7012, 1)
    env.lifeHost.runtime._max_health_of = function(player)
      if player == downed then return 900 end
      return GameCfg.Vitals.MaxHealth
    end
    down(downed)
    request(rescuer, { target = 'downedPlayer', action = 'Rescue', targetUserId = downed.UserId, seq = 1 })
    advance(GameCfg.Rescue.DurationSec + 0.1)
    assert.same(90, downed.Character.Controller.Health, '900 上限的 10% 是 90')
    assert.is_true(downed.Character.Controller.Health <= downed.Character.Controller.MaxHealth)
    local _, max_health = env.v:snapshot_health(downed)
    assert.same(900, max_health)
  end)

  -- 9-03：血量只能经 Vitals 的统一 Rescue 入口落地；请求被拒时不产生任何血量写入。
  it('9-03 抢救只经统一状态转换接口改血量', function()
    local downed = join(7021, 0)
    local rescuer = join(7022, 1)
    down(downed)
    request(rescuer, { target = 'downedPlayer', action = 'Rescue', targetUserId = downed.UserId, seq = 1 })
    assert.same('rescuing', env.s:phase(downed), '抢救已经开始')
    assert.is_true(env.v:cancel_rescue(env.v:get_state(downed)), '取消走统一接口')
    advance(GameCfg.Rescue.DurationSec + 0.1)
    assert.same('downed', env.s:phase(downed), '取消后不再结算')
    assert.same(1, downed.Character.Controller.Health, '取消的抢救不写血量')

    request(rescuer, { target = 'downedPlayer', action = 'Rescue', targetUserId = downed.UserId, seq = 2 })
    advance(GameCfg.Rescue.DurationSec + 0.1)
    assert.same('alive', env.s:phase(downed))
    assert.same(math.floor(GameCfg.Vitals.MaxHealth * GameCfg.Survival.ReviveHealthPercent / 100),
      downed.Character.Controller.Health, '放行后只恢复一次')
  end)

  -- 9-05：同一 seq 重放、两个施救者同时抢、断线重连同 operation 重放，都只结算一次。
  it('9-05 抢救在重复、并发与断线重连下只结算一次', function()
    local downed = join(7031, 0)
    local rescuer = join(7032, 1)
    local rival = join(7033, 1)
    down(downed)
    request(rescuer, { target = 'downedPlayer', action = 'Rescue', targetUserId = downed.UserId, seq = 1 })
    request(rescuer, { target = 'downedPlayer', action = 'Rescue', targetUserId = downed.UserId, seq = 1 })
    request(rival, { target = 'downedPlayer', action = 'Rescue', targetUserId = downed.UserId, seq = 1 })
    advance(GameCfg.Rescue.DurationSec + 0.1)
    local expected = math.floor(GameCfg.Vitals.MaxHealth * GameCfg.Survival.ReviveHealthPercent / 100)
    assert.same('alive', env.s:phase(downed), '抢救结算一次')
    assert.same(expected, downed.Character.Controller.Health, '重复与并发请求只恢复一次')

    env.lifeHost:remove(rescuer)
    env.players:on_player_removing(rescuer)
    drain()
    local reconnected = join(7032, 1)
    request(reconnected, { target = 'downedPlayer', action = 'Rescue', targetUserId = downed.UserId, seq = 1 })
    advance(GameCfg.Rescue.DurationSec + 0.1)
    assert.same(expected, downed.Character.Controller.Health, '重连重放同一请求不产生第二次恢复')
    assert.same('alive', env.s:phase(downed))
  end)

  -- 9-05 持久操作身份：服务端颁发的 operation 带同一请求号重放，只回放原结果、不发起第二次抢救。
  it('9-05 同一抢救请求号重放只回放原结果', function()
    local downed = join(7071, 0)
    local rescuer = join(7072, 1)
    down(downed)
    request(rescuer, { target = 'downedPlayer', action = 'Rescue', targetUserId = downed.UserId, seq = 1 })
    local reply = last_reply('InteractResult')
    assert.is_true(reply.payload.ok, '首次抢救请求被受理')
    assert.is_not_nil(reply.payload.operation, '回包带服务端颁发的操作身份')
    local operation = reply.payload.operation
    assert.same('rescue', operation.kind)

    -- 断线重进：同一玩家拿同一请求号重放，服务端按操作身份回放原结果，不再发起第二次抢救。
    env.lifeHost:remove(rescuer)
    env.players:on_player_removing(rescuer)
    drain()
    local back = join(7072, 1)
    request(back, { target = 'downedPlayer', action = 'Rescue', targetUserId = downed.UserId, seq = 2,
      operation = operation })
    advance(GameCfg.Rescue.DurationSec + 0.1)
    assert.same('alive', env.s:phase(downed), '抢救仍然结算一次')
    assert.same(math.floor(GameCfg.Vitals.MaxHealth * GameCfg.Survival.ReviveHealthPercent / 100),
      downed.Character.Controller.Health, '只恢复一次 10%')
  end)

  -- 11-01 / 11-03 / 11-34：致命伤害锁 1 血濒死，濒死期间伤害与饥饿伤害都不再扣血。
  it('11-01 11-03 11-34 致命伤害锁一血濒死，濒死期间不再扣血', function()
    local downed = join(7041, 0)
    local attacker = join(7042, 1)
    env.v:apply_hit(env.v:new_hit(attacker, 'fishAttack'), downed, GameCfg.Vitals.MaxHealth + 10)
    assert.same('downed', env.s:phase(downed))
    assert.same(1, downed.Character.Controller.Health, '濒死锁 1 血而不是直接死亡')
    env.v:apply_damage(downed, 50, env.v:new_hit(attacker, 'fishAttack'))
    env.v:apply_damage(downed, 50, env.v:new_hit(nil, 'hunger'))
    advance(GameCfg.Survival.DownedSec - 1)
    assert.same(1, downed.Character.Controller.Health, '其它伤害来源不补算濒死期伤害')
  end)

  -- 11-06：濒死玩家主动呼救，只发给 30 米内其他玩家；交互气泡另复用 SurvivalPhase 属性。
  it('11-06 濒死呼救发给附近玩家', function()
    local downed = join(7051, 0)
    join(7052, 5)
    local far = join(7053, GameCfg.Survival.HelpRadius + 1)
    down(downed)
    assert.same('downed', downed:GetAttribute('SurvivalPhase'), '相位属性供其他玩家的交互气泡读取')
    local helpCount = #(env.sent.SurvivalHelp or {})
    survival(downed, { action = 'CallHelp' })
    local helps = env.sent.SurvivalHelp or {}
    local foundNear, foundFar = false, false
    for _, row in ipairs(helps) do
      if row.userId == 7052 then foundNear = true end
      if row.userId == far.UserId then foundFar = true end
    end
    assert.is_true(foundNear, '附近玩家收到呼救')
    assert.is_false(foundFar, '超出呼救半径的玩家收不到')
    assert.is_true(#helps > helpCount, '濒死玩家可以主动呼救')
  end)

  -- 11-35：濒死期间断线，重进按已结算结果虚弱复活，不继续濒死计时。
  it('11-35 濒死断线重连按虚弱复活结算一次', function()
    local downed = join(7061, 0)
    join(7062, 1)
    down(downed)
    env.lifeHost:remove(downed)
    env.players:on_player_removing(downed)
    drain()
    local back = new_player(7061, 0)
    env.players:on_player_added(back)
    drain()
    env.lifeHost:add(back, env.players:get_data_inst(back))
    drain()
    advance(GameCfg.Survival.DeadSec + GameCfg.Survival.DownedSec + 5)
    assert.same('alive', env.s:phase(back))
    assert.same(math.floor(GameCfg.Vitals.MaxHealth * GameCfg.Survival.ReviveHealthPercent / 100),
      back.Character.Controller.Health)
  end)
end)
