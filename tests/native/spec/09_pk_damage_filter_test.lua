-- 条款 9（docs/acceptance/09-multiplayer-rules.md）：PK 伤害过滤。
-- 9-01 统一入口；9-12 同队全武器免伤；9-13 鱼塘免伤；9-14 鱼塘外非同队互伤；
-- 9-15 PK 不以在线人数为条件；9-16 安全区不挡鱼攻击；9-11 离队后立即失去队友免伤。
-- 黑盒入口：server/main.lua 的 MgrMap 装配 Vitals / Party / ZoneMarkers / DamageFilter，
-- 测试只调 mgr 公开方法 NewHit / ApplyHit / PartyAction / SameParty，不直接调被过滤的 ApplyDamage。
-- 失败方式（先列后写）：
--   1. 近战、枪械、范围、爆炸里任一类别绕过统一入口，导致同队仍掉血；
--   2. 过滤器缓存队伍归属，离队后同队免伤仍生效；
--   3. 鱼塘区内非同队互伤；鱼塘外非同队被拦；
--   4. 过滤器读在线人数，玩家少于 8 时 PK 不成立；
--   5. 过滤鱼攻击，安全区里的玩家不被鱼扣血。
local function vec(x, y, z) return { x = x, y = y, z = z } end

local function signal()
  local slots = {}
  return {
    Connect = function(_, fn) slots[#slots + 1] = fn return { Disconnect = function() end } end,
    Fire = function(_, ...) for _, fn in ipairs(slots) do fn(...) end end,
  }
end

local WIRING = {
  'MgrMap.MgrVitals.DamageFilter = makePkDamageFilter()',
  'MgrMap.MgrVitals.Party = MgrMap.MgrParty',
  'MgrMap.MgrVitals.ZoneMarkers = ZoneMarkers',
}

local function assert_wiring()
  local handle = assert(io.open('server/main.lua', 'rb'), '读不到 server/main.lua')
  local source = handle:read('a')
  handle:close()
  for _, line in ipairs(WIRING) do
    assert.is_truthy(source:find(line, 1, true), 'server/main.lua 里找不到接线：' .. line)
  end
end

local function newPlayer(userId, position)
  local player = { UserId = userId, Name = 'p' .. userId, attrs = {} }
  player.Character = { Position = position or vec(0, 0, 0), Size = { x = 1, y = 2, z = 1 },
    Controller = {
      Health = 300,
      HealthChanged = signal(),
      Died = signal(),
      TakeDamage = function(self, amount)
        self.Health = math.max(0, self.Health - amount)
        self.HealthChanged:Fire()
        if self.Health == 0 then self.Died:Fire() end
      end,
    },
    SetPosition = function(self, pos) self.Position = pos end,
  }
  player.CharacterAdded, player.CharacterRemoving = signal(), signal()
  player.SetAttribute = function(self, key, value) self.attrs[key] = value end
  player.GetAttribute = function(self, key) return self.attrs[key] end
  return player
end

describe('条款 9 PK 伤害过滤', function()
  local env

  local function drain()
    for _ = 1, 200 do
      if #env.queue == 0 then return end
      table.remove(env.queue, 1)()
    end
    error('Task 队列未收敛')
  end

  local function join(userId, position)
    local player = newPlayer(userId, position)
    env.players:OnPlayerAdded(player)
    env.party:OnPlayerAdded(player)
    env.vitals:OnPlayerAdded(player)
    drain()
    return player
  end

  local function request(player, action, payload)
    payload = payload or {}
    payload.action = action
    env.re.PartyAction.OnServerEvent:Fire(player, payload)
    drain()
  end

  local function makeTeam(a, b)
    request(a, 'Invite', { targetUserId = b.UserId })
    request(b, 'Accept')
    assert.is_true(env.party:SameParty(a, b))
  end

  local function hit(source, target, category, amount)
    return env.vitals:ApplyHit(env.vitals:NewHit(source, category), target, amount or 30)
  end

  before_each(function()
    assert_wiring()
    env = { queue = {}, sent = {}, values = {}, re = {}, now = 100, game = rawget(_G, 'game'),
      vector = rawget(_G, 'Vector3'), reutil = rawget(_G, 'REUtil'), cfg = rawget(package.loaded, 'common.GameCfg') }
    _G.Vector3 = { New = vec }
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
      if name == 'World' then return { GetServerTime = function() return env.now end } end
      if name == 'Players' then return { GetPlayers = function() return {} end } end
      if name == 'RunService' then return { IsServer = function() return true end } end
    end, CreateRemoteEvent = function() return signal() end }
    local re = { GetRE = function(_, name)
      env.re[name] = env.re[name] or { OnServerEvent = signal(), OnClientEvent = signal(),
        FireClient = function() end, FireAllClients = function() end, FireServer = function() end }
      return env.re[name]
    end, CheckRECD = function() return false end }
    _G.REUtil, package.loaded['common.REUtil'] = re, re
    -- 真区域解析：鱼塘边界来自与生产同一条 ZoneMarkers 路径，不写死坐标。
    env.zones = assert(loadfile('tests/support/zone_fixtures.lua'))()
    env.cfg = env.zones.Load()
    env.party = assert(loadfile('server/Mgr/MgrParty.lua'))()
    env.vitals = assert(loadfile('server/Mgr/MgrVitals.lua'))()
    env.players = assert(loadfile('server/Mgr/MgrPlayerData.lua'))()
    env.save = assert(loadfile('server/Mgr/MgrSave.lua'))()
    env.players.Save, env.save.PlayerData = env.save, env.players
    env.party.PlayerData, env.party.Save, env.party.Vitals = env.players, env.save, env.vitals
    env.filter = assert(loadfile('server/Mgr/MgrPkFilter.lua'))()()
    -- 生产装配：过滤接缝与区域真源都经 mgr 注入，不缓存队伍归属。
    env.vitals.Party = env.party
    env.vitals.ZoneMarkers = require('common.ZoneMarkers')
    env.vitals.DamageFilter = function(hit, target, mgr) return env.filter(hit, target, mgr) end
    env.vitals.DamagePublisher = function() end
    env.vitals.Now = function() return env.now end
    env.party:Start()
    env.vitals:Start()
  end)

  after_each(function()
    if not env then return end
    _G.game, _G.Vector3, _G.REUtil = env.game, env.vector, env.reutil
    package.loaded['common.GameCfg'] = env.cfg
    env = nil
  end)

  it('9-01：全部玩家攻击经统一入口，逐个判定类别并只结算实际伤害', function()
    local attacker = join(1, vec(0, 0, 0))
    local target = join(2, vec(242, 6, 0))
    local categories = { 'weapon', 'melee', 'gun', 'explosion', 'area' }
    for _, category in ipairs(categories) do
      local ok, actual = hit(attacker, target, category, 30)
      assert.is_true(ok, category .. ' 未走统一入口')
      assert.same(30, actual, category .. ' 的实际伤害不符')
    end
    assert.same(150, 300 - target.Character.Controller.Health)
  end)

  it('9-12：同队近战、枪械、范围、爆炸全部按 0 结算', function()
    local a = join(1, vec(241, 6, 0))
    local b = join(2, vec(242, 6, 0))
    makeTeam(a, b)
    for _, category in ipairs({ 'melee', 'gun', 'area', 'explosion' }) do
      assert.is_false(hit(a, b, category, 30), category .. ' 打到了队友')
      assert.same(300, b.Character.Controller.Health)
    end
    request(a, 'Leave', {})
    assert.is_true(hit(a, b, 'melee', 30))
    assert.same(270, b.Character.Controller.Health)
  end)

  it('9-13：鱼塘区内任意两名非同队玩家免伤', function()
    local a = join(1, vec(6.26, 5.01, -0.71))
    local b = join(2, vec(5, 6, -9))
    assert.is_false(hit(a, b, 'gun', 45))
    assert.same(300, b.Character.Controller.Health)
  end)

  it('9-14：鱼塘外非同队玩家攻击扣血，同队仍免伤', function()
    local a = join(3, vec(241, 6, 0))
    local b = join(4, vec(242, 6, 0))
    assert.is_true(hit(a, b, 'melee', 20))
    assert.same(280, b.Character.Controller.Health)
    makeTeam(a, b)
    assert.is_false(hit(a, b, 'melee', 20))
    assert.same(280, b.Character.Controller.Health)
  end)

  it('9-15：在线人数不足 8 时非同队 PK 仍然扣血', function()
    local a = join(1, vec(241, 6, 0))
    local b = join(2, vec(242, 6, 0))
    assert.is_true(hit(a, b, 'gun', 12))
    assert.same(288, b.Character.Controller.Health)
    assert.is_true(hit(b, a, 'explosion', 12))
    assert.same(288, a.Character.Controller.Health)
  end)

  it('9-16：安全区挡玩家伤害但不挡鱼攻击', function()
    local a = join(1, vec(6.26, 5.01, -0.71))
    local b = join(2, vec(5, 6, -9))
    local fish = { Id = 91, Body = { UnitId = 91 }, Receiver = {}, Position = vec(0, 2, 0) }
    assert.is_false(hit(a, b, 'gun', 25))
    assert.same(300, b.Character.Controller.Health)
    assert.is_true(hit(fish, b, 'fishAttack', 25))
    assert.same(275, b.Character.Controller.Health)
  end)
end)
