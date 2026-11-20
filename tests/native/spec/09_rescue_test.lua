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
--   7. 濒死断线重连仍继续濒死计时，或多结算一次复活（11-35）。
local function vec(x, y, z) return { x = x, y = y, z = z } end
local GameCfg = require('common.GameCfg')

local WIRING = {
  'MgrMap.MgrInteract.PlayerData = MgrMap.MgrPlayerData',
  'MgrMap.MgrInteract.Save = MgrMap.MgrSave',
  'MgrMap.MgrInteract.Vitals = MgrMap.MgrVitals',
  'MgrMap.MgrInteract.Survival = MgrMap.MgrSurvival',
  'MgrMap.MgrSurvival.Vitals = MgrMap.MgrVitals',
  'MgrMap.MgrVitals:SetLifeHooks(MgrMap.MgrSurvival:Hooks())',
}
local function assert_wiring()
  local handle = assert(io.open('server/main.lua', 'rb'), '读不到 server/main.lua')
  local source = handle:read('a')
  handle:close()
  for _, line in ipairs(WIRING) do
    assert.is_truthy(source:find(line, 1, true), 'server/main.lua 里找不到接线：' .. line)
  end
end

local function signal()
  local slots = {}
  return {
    Connect = function(_, fn) slots[#slots + 1] = fn return { Disconnect = function() end } end,
    Fire = function(_, ...) for _, fn in ipairs(slots) do fn(...) end end,
  }
end

local function newPlayer(userId, x)
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

  local function lastReply(name)
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
    local player = newPlayer(userId, x)
    env.players:OnPlayerAdded(player)
    drain()
    env.v:OnPlayerAdded(player)
    env.s:OnPlayerAdded(player)
    drain()
    return player
  end

  local function down(player)
    env.v:ApplyHit(env.v:NewHit(nil, 'fishAttack'), player, GameCfg.Vitals.MaxHealth + 10)
    assert.same('downed', env.s:Phase(player))
  end

  local function advance(seconds)
    env.now = env.now + seconds
    env.s:Update()
    env.v:Update()
    drain()
  end

  before_each(function()
    assert_wiring()
    env = { cfg = GameCfg, now = 100, queue = {}, sent = {}, re = {}, values = {} }
    env.cfg.Debug = { Enabled = false }
    env.cfg.Save.QaSlot = ''
    env.saved = { game = rawget(_G, 'game'), Vector3 = rawget(_G, 'Vector3'),
      Vector2 = rawget(_G, 'Vector2'), Color = rawget(_G, 'Color'),
      REUtil = rawget(_G, 'REUtil'), reutil = package.loaded['common.REUtil'] }
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
    end, CreateRemoteEvent = function() return signal() end }
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
    local re = { GetRE = function(_, name) return reStub(name) end, CheckRECD = function() return false end }
    package.loaded['common.REUtil'] = re
    _G.REUtil = re

    package.loaded['server.Data.PlayerData'] = nil
    env.PlayerData = require('server.Data.PlayerData')
    env.save = assert(loadfile('server/Mgr/MgrSave.lua'))()
    env.players = assert(loadfile('server/Mgr/MgrPlayerData.lua'))()
    env.v = assert(loadfile('server/Mgr/MgrVitals.lua'))()
    env.s = assert(loadfile('server/Mgr/MgrSurvival.lua'))()
    env.interact = assert(loadfile('server/Mgr/MgrInteract.lua'))()
    env.players.Save, env.save.PlayerData = env.save, env.players
    env.v.PlayerData = env.players
    env.s.Vitals, env.s.PlayerData, env.s.Save = env.v, env.players, env.save
    env.s.Modifier = { ClearTarget = function() end, Clear = function() end,
      Apply = function() return true end, GetRemaining = function() return 0 end }
    env.s.SpeedWriter = { ApplyGrowth = function() return { Ok = true } end,
      RefreshMoveSpeed = function() return true end }
    env.interact.PlayerData, env.interact.Save = env.players, env.save
    env.interact.Vitals, env.interact.Survival = env.v, env.s
    env.v:SetLifeHooks(env.s:Hooks())
    env.interact:Start()
    env.s:Start()
  end)

  after_each(function()
    if not env then return end
    _G.game = env.saved.game
    _G.Vector3 = env.saved.Vector3
    _G.Vector2 = env.saved.Vector2
    _G.Color = env.saved.Color
    _G.REUtil = env.saved.REUtil
    package.loaded['common.REUtil'] = env.saved.reutil
    env = nil
  end)

  -- 9-17：2 米内他人抢救成立（含边界）；超距、目标已醒、已有施救者都不发起。
  it('9-17 两米内可发起他人抢救，超距与非濒死目标被拒', function()
    local downed = join(7001, 0)
    local rescuer = join(7002, 2)
    local far = join(7003, 2.5)
    down(downed)
    request(rescuer, { target = 'downedPlayer', action = 'Rescue', targetUserId = downed.UserId, seq = 1 })
    assert.is_true(lastReply('InteractResult').payload.ok, '正好 2 米可以发起抢救')
    assert.same('rescuing', env.s:Phase(downed), '发起后进入抢救中')

    request(far, { target = 'downedPlayer', action = 'Rescue', targetUserId = downed.UserId, seq = 1 })
    assert.is_false(lastReply('InteractResult').payload.ok, '超距发起被拒')

    local other = join(7004, 1)
    request(other, { target = 'downedPlayer', action = 'Rescue', targetUserId = downed.UserId, seq = 1 })
    assert.is_false(lastReply('InteractResult').payload.ok, '已有施救者时并发请求被拒')

    advance(GameCfg.Rescue.DurationSec + 0.1)
    assert.same('alive', env.s:Phase(downed))
    request(join(7005, 1), { target = 'downedPlayer', action = 'Rescue', targetUserId = downed.UserId, seq = 1 })
    assert.is_false(lastReply('InteractResult').payload.ok, '已恢复的目标不能再次被救')
  end)

  -- 9-17 客户端：抢救提示复用现有 InteractionBubble 与 InteractAction 通道，不另造入口。
  it('9-17 客户端复用交互气泡发起抢救', function()
    env.clientNodes = {}
    local localPlayer = { Character = { Position = vec(0, 0, 0) },
      PlayerGui = { EuiManager = { CreateSceneNodeAtPosition = function(_, position)
        local node = { Position = position, Visible = false }
        env.clientNodes.RescueRoot = node
        return node
      end } } }
    env.playersService.LocalPlayer = localPlayer
    local target = { UserId = 42, Character = { Position = vec(1, 0, 0) },
      GetAttribute = function(_, key) return key == 'SurvivalPhase' and 'downed' or nil end }
    env.clientPlayers = { localPlayer, target }
    local client = assert(loadfile('client/LocalInteract.lua'))()
    client:Update()
    assert.is_true(env.clientNodes.RescueRoot.Visible, '2 米内的濒死玩家显示抢救气泡')

    local sent = env.sent.InteractAction or {}
    local before = #sent
    env.clientNodes.BtnRescue42.OnClicked:Fire()
    assert.same(before + 1, #sent, '点击气泡只发一次交互请求')
    assert.same('downedPlayer', sent[#sent].payload.target)
    assert.same('Rescue', sent[#sent].payload.action)
    assert.same(42, sent[#sent].payload.targetUserId)
    assert.same(before + 1, sent[#sent].payload.seq, '与喂食共用递增 seq')

    target.Character.Position = vec(5, 0, 0)
    client:Update()
    assert.is_false(env.clientNodes.RescueRoot.Visible, '走出 2 米后收起气泡')
    target.Character.Position = vec(1, 0, 0)
    target.GetAttribute = function() return 'alive' end
    client:Update()
    assert.is_false(env.clientNodes.RescueRoot.Visible, '被救起后收起气泡')
  end)

  -- 9-18 / 11-36：恢复量取被救者的成长上限 10%，夹在上限内。
  it('9-18 11-36 抢救恢复被救者血量上限的 10% 且不超上限', function()
    assert.same(10, GameCfg.Survival.ReviveHealthPercent)
    local downed = join(7011, 0)
    local rescuer = join(7012, 1)
    env.v.MaxHealthProvider = function(player)
      if player == downed then return 900 end
      return GameCfg.Vitals.MaxHealth
    end
    down(downed)
    request(rescuer, { target = 'downedPlayer', action = 'Rescue', targetUserId = downed.UserId, seq = 1 })
    advance(GameCfg.Rescue.DurationSec + 0.1)
    assert.same(90, downed.Character.Controller.Health, '900 上限的 10% 是 90')
    assert.is_true(downed.Character.Controller.Health <= downed.Character.Controller.MaxHealth)
    local _, maxHealth = env.v:SnapshotHealth(downed)
    assert.same(900, maxHealth)
  end)

  -- 9-03：血量只能经 Vitals 的统一 Rescue 接缝落地；接缝被拒时不产生任何血量写入。
  it('9-03 抢救只经统一状态转换接口改血量', function()
    local downed = join(7021, 0)
    local rescuer = join(7022, 1)
    down(downed)
    local calls = { rescue = 0, revive = 0 }
    local hooks = env.v.LifeHooks
    local originalRescue = hooks.Rescue
    local originalRevive = env.v.ApplyRevive
    hooks.Rescue = function()
      calls.rescue = calls.rescue + 1
      return false -- 统一接口拒绝：不得绕过它写血
    end
    env.v.ApplyRevive = function(self, state, health, hunger)
      calls.revive = calls.revive + 1
      return originalRevive(self, state, health, hunger)
    end
    request(rescuer, { target = 'downedPlayer', action = 'Rescue', targetUserId = downed.UserId, seq = 1 })
    advance(GameCfg.Rescue.DurationSec + 0.1)
    assert.same(1, calls.rescue, '结算只走统一 Rescue 接缝一次')
    assert.same(0, calls.revive, '统一接缝拒绝时不得落到 ApplyRevive')
    assert.same('downed', env.s:Phase(downed))
    assert.same(1, downed.Character.Controller.Health, '血量未被绕过写入')

    hooks.Rescue = originalRescue
    request(rescuer, { target = 'downedPlayer', action = 'Rescue', targetUserId = downed.UserId, seq = 2 })
    advance(GameCfg.Rescue.DurationSec + 0.1)
    assert.same(1, calls.revive, '接口放行时正好一次 ApplyRevive')
    assert.same('alive', env.s:Phase(downed))
  end)

  -- 9-05：同一 seq 重放、两个施救者同时抢、断线重连同 operation 重放，都只结算一次。
  it('9-05 抢救在重复、并发与断线重连下只结算一次', function()
    local downed = join(7031, 0)
    local rescuer = join(7032, 1)
    local rival = join(7033, 1)
    down(downed)
    local revived = 0
    local original = env.v.ApplyRevive
    env.v.ApplyRevive = function(self, state, health, hunger)
      revived = revived + 1
      return original(self, state, health, hunger)
    end
    request(rescuer, { target = 'downedPlayer', action = 'Rescue', targetUserId = downed.UserId, seq = 1 })
    request(rescuer, { target = 'downedPlayer', action = 'Rescue', targetUserId = downed.UserId, seq = 1 })
    request(rival, { target = 'downedPlayer', action = 'Rescue', targetUserId = downed.UserId, seq = 1 })
    advance(GameCfg.Rescue.DurationSec + 0.1)
    assert.same(1, revived, '重复与并发请求只结算一次')

    env.players:OnPlayerRemoving(rescuer)
    env.s:OnPlayerRemoving(rescuer)
    drain()
    local reconnected = join(7032, 1)
    request(reconnected, { target = 'downedPlayer', action = 'Rescue', targetUserId = downed.UserId, seq = 1 })
    advance(GameCfg.Rescue.DurationSec + 0.1)
    assert.same(1, revived, '重连重放同一请求不产生第二次恢复')
    assert.same('alive', env.s:Phase(downed))
  end)

  -- 9-05 持久操作身份：服务端颁发的 operation 带同一请求号重放，只回放原结果、不发起第二次抢救。
  it('9-05 同一抢救请求号重放只回放原结果', function()
    local downed = join(7071, 0)
    local rescuer = join(7072, 1)
    down(downed)
    request(rescuer, { target = 'downedPlayer', action = 'Rescue', targetUserId = downed.UserId, seq = 1 })
    local reply = lastReply('InteractResult')
    assert.is_true(reply.payload.ok, '首次抢救请求被受理')
    assert.is_not_nil(reply.payload.operation, '回包带服务端颁发的操作身份')
    local operation = reply.payload.operation
    assert.same('rescue', operation.kind)

    -- 断线重进：同一玩家拿同一请求号重放，服务端按操作身份回放原结果，不再发起第二次抢救。
    env.players:OnPlayerRemoving(rescuer)
    env.v:OnPlayerRemoving(rescuer)
    env.s:OnPlayerRemoving(rescuer)
    drain()
    local back = join(7072, 1)
    request(back, { target = 'downedPlayer', action = 'Rescue', targetUserId = downed.UserId, seq = 2,
      operation = operation })
    advance(GameCfg.Rescue.DurationSec + 0.1)
    assert.same('alive', env.s:Phase(downed), '抢救仍然结算一次')
    assert.same(math.floor(GameCfg.Vitals.MaxHealth * GameCfg.Survival.ReviveHealthPercent / 100),
      downed.Character.Controller.Health, '只恢复一次 10%')
  end)

  -- 11-01 / 11-03 / 11-34：致命伤害锁 1 血濒死，濒死期间伤害与饥饿伤害都不再扣血。
  it('11-01 11-03 11-34 致命伤害锁一血濒死，濒死期间不再扣血', function()
    local downed = join(7041, 0)
    local attacker = join(7042, 1)
    env.v:ApplyHit(env.v:NewHit(attacker, 'fishAttack'), downed, GameCfg.Vitals.MaxHealth + 10)
    assert.same('downed', env.s:Phase(downed))
    assert.same(1, downed.Character.Controller.Health, '濒死锁 1 血而不是直接死亡')
    env.v:ApplyDamage(downed, 50, env.v:NewHit(attacker, 'fishAttack'))
    env.v:ApplyDamage(downed, 50, env.v:NewHit(nil, 'hunger'))
    env.v:Update()
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
    env.s:BeforeLeave(downed)
    env.players:OnPlayerRemoving(downed)
    env.v:OnPlayerRemoving(downed)
    env.s:OnPlayerRemoving(downed)
    drain()
    local back = newPlayer(7061, 0)
    env.players:OnPlayerAdded(back)
    drain()
    env.v:OnPlayerAdded(back)
    env.s:OnPlayerAdded(back)
    drain()
    advance(GameCfg.Survival.DeadSec + GameCfg.Survival.DownedSec + 5)
    assert.same('alive', env.s:Phase(back))
    assert.same(math.floor(GameCfg.Vitals.MaxHealth * GameCfg.Survival.ReviveHealthPercent / 100),
      back.Character.Controller.Health)
  end)
end)
