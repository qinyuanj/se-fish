-- 条款 9（docs/acceptance/09-multiplayer-rules.md）：PK 伤害过滤。
-- 9-01 统一入口；9-12 同队全武器免伤；9-13 鱼塘免伤；9-14 鱼塘外非同队互伤；
-- 9-15 PK 不以在线人数为条件；9-16 安全区不挡鱼攻击；9-11 离队后立即失去队友免伤。
-- 黑盒入口：server/main.lua 的 MgrMap 装配 Vitals / Party / ZoneMarkers / DamageFilter，
-- 测试只调 mgr 公开方法 NewHit / ApplyHit / PartyAction / SameParty，不直接调被过滤的 ApplyDamage。
-- 失败方式（先列后写）：
--   1. 近战、枪械、范围、爆炸里任一类别绕过统一入口，导致同队仍掉血；
--   2. 过滤器缓存队伍归属，离队后同队免伤仍生效；
--   3. 鱼塘区内非同队互伤；鱼塘外非同队被拦；区域几何缺失时全局误拒非同队互伤；
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
  'bind_party_action = function(dispatch)',
  'bind_party_state_request = function(dispatch)',
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
    env.lifeHost:add(player)
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
    env = { queue = {}, sent = {}, values = {}, re = {}, now = 100, byCharacter = {},
      game = rawget(_G, 'game'),
      vector = rawget(_G, 'Vector3'), reutil = rawget(_G, 'REUtil'), cfg = rawget(package.loaded, 'common.game_cfg') }
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
      if name == 'Players' then return { GetPlayers = function() return {} end,
        GetPlayerFromCharacter = function(_, inst) return env.byCharacter[inst] end } end
      if name == 'RunService' then return { IsServer = function() return true end } end
      -- 9-12（review #249）：枪械命中要从 MgrWeapon 真实发起。弹道解析是引擎边界，用替身
      -- 返回「打中了 env.shot 指的那名玩家」；伤害仍然只经 MgrVitals 的统一入口结算。
      if name == 'PhysicsService' then return { Raycast = function()
        local target = env.shot
        if not target then return nil end
        return { Instance = target.Character, Position = env.shotAt or { x = 0, y = 0, z = 0 } }
      end } end
    end }
    local re = { GetRE = function(_, name)
      env.re[name] = env.re[name] or { OnServerEvent = signal(), OnClientEvent = signal(),
        FireClient = function() end, FireAllClients = function() end, FireServer = function() end }
      return env.re[name]
    end, CheckRECD = function() return false end }
    _G.REUtil, package.loaded['common.re_util'] = re, re
    -- 真区域解析：鱼塘边界来自与生产同一条 ZoneMarkers 路径，不写死坐标。
    env.zones = assert(loadfile('tests/support/zone_fixtures.lua'))()
    env.cfg = env.zones.Load()
    env.party = {}
    function env.party:SameParty(a, b)
      local squad = env.lifeHost and env.lifeHost.runtime.world.squad
      return squad and squad:SameParty(a, b) or false
    end
    env.lifeHost = require('tests.support.life_host').start({ now = 0, remote = re })
    env.vitals = env.lifeHost.runtime.life
    env.players = assert(loadfile('server/player_data_host.lua'))()
    env.save = assert(loadfile('server/save_host.lua'))()
    env.players.Save, env.save.PlayerData = env.save, env.players
    env.filter = require('server.world_host.pk_damage_filter').make({
      party = env.party, zone_markers = require('common.zone_markers'), zones = env.cfg.Zones,
    })
    -- 生产装配：过滤接缝与区域真源都经 mgr 注入，不缓存队伍归属。
    env.vitals.Party = env.party
    env.vitals.ZoneMarkers = require('common.zone_markers')
    env.vitals:SetDamageFilter(function(hit, target, mgr) return env.filter(hit, target, mgr) end)
    -- 9-12（review #249）：武器管理器照 main.lua 的接线装进同一套环境（伤害仍只经统一入口）。
    -- AbilityAPI 在装载时要引擎的 RemoteEvent 全局：补替身并清模块缓存，避免复用别的用例的上下文。
    env.remoteEvent, env.abilityModule, env.swingModule =
      rawget(_G, 'RemoteEvent'), package.loaded['server.ability_api'], package.loaded['server.swing_registry']
    _G.RemoteEvent = { New = function()
      return { OnServerEvent = { Connect = function() return { Disconnect = function() end } end } }
    end }
    package.loaded['server.ability_api'], package.loaded['server.swing_registry'] = nil, nil
    env.weapon = {
      AttackGun = function(_, player, weapon_id, _, _, aim)
        local tree = env.lifeHost.runtime:get_player_tree(player.UserId)
        tree:sync_from_data({
          Player = player, Inited = true, LoadState = 'ready',
          Data = { FishCoin = 0, Zone = 'fishPond', Weapons = { [weapon_id] = 1 }, Containers = {} },
          Extra = { growth = { potions = {}, upgrades = {} }, inventory = { selection = { held = { kind = 'weapon', id = weapon_id } } }, survival = {} },
        })
        return env.lifeHost.runtime.life:WeaponAction(player, { action = 'attack', aim = aim })
      end,
    }
  end)

  after_each(function()
    if not env then return end
    _G.game, _G.Vector3, _G.REUtil = env.game, env.vector, env.reutil
    _G.RemoteEvent = env.remoteEvent
    package.loaded['server.ability_api'] = env.abilityModule
    package.loaded['server.swing_registry'] = env.swingModule
    package.loaded['common.game_cfg'] = env.cfg
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

  -- 9-12（review #249）：类别字段（melee/gun/area...）是装饰，过滤器只认「玩家来源」。
  -- 本用例不再给统一入口贴标签，而是从 MgrWeapon 真实发起一次枪击：
  -- 同队玩家被挡成 0 伤害，离队后同一把枪照常结算。
  it('9-12 枪械经 MgrWeapon 真实发起：同队命中被挡，离队后照常结算', function()
    local a = join(1, vec(241, 6, 0))
    local b = join(2, vec(242, 6, 0))
    makeTeam(a, b)
    local gun = env.cfg.Ability.Guns.item137 -- 手枪：Damage 10 / IntervalSec 1.0 / Magazine 10
    assert.is_not_nil(gun, '枪械数值表里没有 item137')
    env.shot, env.shotAt = b, vec(242, 6, 0)
    env.byCharacter[b.Character] = b
    env.weapon:AttackGun(a, 'item137', gun, {}, vec(1, 0, 0))
    assert.same(300, b.Character.Controller.Health, '同队玩家被枪械命中也不掉血')
    request(a, 'Leave', {})
    assert.is_false(env.party:SameParty(a, b))
    env.now = env.now + gun.IntervalSec + 1
    env.lifeHost.runtime.clock:advance(gun.IntervalSec + 1)
    env.weapon:AttackGun(a, 'item137', gun, {}, vec(1, 0, 0))
    assert.same(300 - gun.Damage, b.Character.Controller.Health, '离队后同一把枪照常结算')
  end)

  it('9-13：鱼塘区内任意两名非同队玩家免伤', function()
    local a = join(1, vec(6.26, 5.01, -0.71))
    local b = join(2, vec(5, 6, -9))
    assert.is_false(hit(a, b, 'gun', 45))
    assert.same(300, b.Character.Controller.Health)
  end)

  -- 失败方式：区域快照没解析出来时把全地图当成鱼塘，会误拒鱼塘外非同队玩家互伤。
  it('9-13 区域快照缺失时非同队互伤放行并留日志，同队仍免伤', function()
    local a = join(1, vec(6.26, 5.01, -0.71))
    local b = join(2, vec(5, 6, -9))
    local snapshot, scene = env.vitals.ZoneMarkers, env.cfg.Zones[1].Scene
    env.vitals.ZoneMarkers, env.cfg.Zones[1].Scene = { Zones = {} }, nil
    local printed, rawPrint = {}, print
    _G.print = function(...)
      local parts = {}
      for index = 1, select('#', ...) do parts[index] = tostring((select(index, ...))) end
      printed[#printed + 1] = table.concat(parts, ' ')
    end
    local ok, actual = hit(a, b, 'gun', 45)
    local blockedHealth = b.Character.Controller.Health
    -- 同一口径下鱼攻击不受这条兜底影响（9-16）。
    local fishHit = hit({ Id = 91, Body = { UnitId = 91 }, Receiver = {} }, b, 'fishAttack', 10)
    _G.print = rawPrint
    env.vitals.ZoneMarkers, env.cfg.Zones[1].Scene = snapshot, scene
    assert.is_true(ok, '区域未解析不能全局误拒非同队玩家互伤')
    assert.same(45, actual)
    assert.same(255, blockedHealth)
    assert.is_true(fishHit, '区域缺失不该挡住鱼对玩家的伤害')
    assert.same(245, b.Character.Controller.Health)
    a.Character.Position, b.Character.Position = vec(241, 6, 0), vec(242, 6, 0)
    makeTeam(a, b)
    assert.is_false(hit(a, b, 'gun', 20), '区域未解析仍保留同队免伤')
    assert.same(245, b.Character.Controller.Health)
    local logged = false
    for _, line in ipairs(printed) do
      if line:find('PkDamageFilter', 1, true) then logged = true end
    end
    assert.is_true(logged, '区域缺失的放行兜底要留下日志')
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
