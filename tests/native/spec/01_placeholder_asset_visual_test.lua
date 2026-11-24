-- 条款 1-14、1-15（docs/acceptance/01-overview-and-scope.md）：
-- 1-14 正式美术资源按官方资产表替换显示，占位期间玩法路径照常可跑；资源交付作为生产开关单列，
--      替换只改显示、不改判定参数。
-- 1-15 占位资源版本下，七个区的鱼与七个首领在场景中都能看到、打到并放下。
-- 1-15 本身是 C 级试玩条款（状态 blocked）；本文件只取证它的**代码路径**：可见、可打、可放下
-- 三件事各自走到业务入口，不声称编辑器里已经看到。试玩结论仍归 C 级会话记录。
--
-- 只走业务入口：common/GameCfg 的应用结果、server/Mgr/MgrLoot 的地面实例入口、
-- server/Mgr/MgrFishCarrier 的生成与伤害接缝、server/Mgr/MgrFishUnit 的抓举/放下状态机；
-- data/OfficialAsset.lua 是官方资产表的独立真源（编辑器导出、只读），用来判「资源 ID 真的存在」。
-- 失败方式（先列后写）：
--   1. 占位层顺手改了判定数值：血量、攻击、速度、逃跑秒、基础重量、基础价、饵、竿级、权重或掉落；
--   2. 正式资源已配置的 Icon / Visual / 品级色被占位覆盖，或重复 Apply 把已交付的值改掉；
--   3. 占位或正式资源 ID 指向官方资产表里不存在的条目（占位 ID 打错一位，鱼就看不见）；
--   4. 七区里某条鱼或某个首领缺图标 / 分类模型 / 品级色，或世界模型解析不出 official://mesh；
--   5. 七区的鱼与首领打不动（统一伤害入口解析不到受击体，或血量不是鱼种血量）；
--   6. 放下后状态没离开「举着」、本体没回世界，或挂点没销毁。
local GameCfg = require('common.GameCfg')
local PlaceholderAssets = require('common.cfg.PlaceholderAssets')

local function signal()
  local slots = {}
  return {
    Connect = function(_, fn) slots[#slots + 1] = fn return { Disconnect = function() end } end,
    Fire = function(_, ...) for _, fn in ipairs(slots) do fn(...) end end,
  }
end

local function vec(x, y, z)
  return setmetatable({ x = x or 0, y = y or 0, z = z or 0 }, {
    __add = function(a, b) return vec(a.x + b.x, a.y + b.y, a.z + b.z) end,
  })
end

-- 显示字段白名单：占位层只能写这些键。判定字段一个都不许出现在这里。
local DISPLAY_FIELDS = { VisualColor = true, Icon = true, IconColor = true, Visual = true }

-- 官方资产表（编辑器导出、只读）做独立真源：值形如 official://image/<号>、official://mesh/<号>。
-- 导出器把重名条目注释掉了（--["鱼"] = "official://image/11164"），那些 id 在引擎里仍然有效，
-- 所以整份导出按文本扫一遍：出现在文件里的 id 才算存在，抄错一位就查不到。
local AssetIds = {}
do
  local handle = assert(io.open('data/OfficialAsset.lua', 'rb'), '读不到 data/OfficialAsset.lua')
  local text = handle:read('a')
  handle:close()
  for id in text:gmatch('official://[a-z]+/%d+') do AssetIds[id] = true end
end

local function assert_asset(id, where)
  assert.is_truthy(AssetIds[id], where .. ' 指向官方资产表里不存在的资源：' .. tostring(id))
end

local function worldMesh(species)
  return 'official://mesh/' .. tostring(species.Model)
end

-- 一个最小假世界：够 MgrFishCarrier:Spawn / MgrFishUnit:SpawnLanded 建本体、受击体与挂点。
local function newWorld()
  local env = { world = {}, units = {}, now = 100 }
  env.world.GetServerTime = function() return env.now end
  local nextId = 0
  env.world.CreateUnit = function(_, kind, values)
    nextId = nextId + 1
    local unit = { UnitId = nextId, UnitType = kind, Kinds = kind }
    for key, value in pairs(values or {}) do unit[key] = value end
    unit.OnLiftedBegin, unit.OnLiftedEnd = signal(), signal()
    unit.Destroy = function(self) self.Destroyed = true end
    unit.SetPosition = function(self, pos) self.Position = pos end
    if values and values.EnableController then
      local healthChanged, died = signal(), signal()
      unit.Controller = {
        Health = 100, MaxHealth = 100, LiftedEnabled = true,
        HealthChanged = healthChanged, Died = died,
        TakeDamage = function(self, amount)
          self.Health = math.max(0, self.Health - amount)
          healthChanged:Fire(self.Health)
          if self.Health <= 0 then died:Fire() end
        end,
      }
    end
    env.units[#env.units + 1] = unit
    return unit
  end
  return env
end

local function installWorld(env)
  local saved = { game = rawget(_G, 'game'), Vector3 = rawget(_G, 'Vector3'),
    Color = rawget(_G, 'Color'), Quaternion = rawget(_G, 'Quaternion') }
  _G.Vector3 = { New = vec }
  _G.Color = { New = function(r, g, b, a) return { r = r, g = g, b = b, a = a } end }
  _G.Quaternion = { FromEulerAngles = function() return { x = 0, y = 0, z = 0 } end }
  _G.game = { GetService = function(_, name)
    if name == 'World' then return env.world end
    if name == 'Players' then return { GetPlayers = function() return env.players or {} end } end
    if name == 'RunService' then return { IsServer = function() return true end,
      IsClient = function() return false end, Heartbeat = signal() } end
  end }
  return saved
end

local function restoreWorld(saved)
  _G.game, _G.Vector3 = saved.game, saved.Vector3
  _G.Color, _G.Quaternion = saved.Color, saved.Quaternion
end

-- 七区 → 鱼与首领：区序来自 GameCfg.Zones，首领以 GameCfg.BossChain 的 BossFish 为准。
local function zoneSpecies()
  local rows = {}
  for _, zone in ipairs(GameCfg.Zones) do
    local fish = {}
    for id, species in pairs(GameCfg.Fish) do
      if species.ZoneId == zone.Id and (species.Grade == 'normal' or species.Grade == 'rare') then
        fish[#fish + 1] = id
      end
    end
    table.sort(fish)
    local boss
    for _, chain in ipairs(GameCfg.Content.Exchanges) do
      if chain.ZoneId == zone.Id then boss = chain.BossFish end
    end
    rows[#rows + 1] = { id = zone.Id, fish = fish, boss = boss }
  end
  return rows
end

describe('条款 1-14 占位资源只替换显示', function()
  -- 合成配置做独立真源：判定数值是手写字面量，不由实现或配置再算一遍。
  local function synthetic()
    local cfg = {
      Fish = {
        probeElite = { Id = 'probeElite', Name = '探针精英', Grade = 'elite', ZoneId = 'fishPond',
          Health = 271, Attack = 33, Speed = 6, EscapeSec = 180, BaseWeight = 12.5, BasePrice = 0,
          Bait = 'worm', RodLevel = 4, DrawWeight = 17,
          Drops = { { ItemId = 'probeMeat', Count = 2 }, { ItemId = 'probeHead', Count = 1 } } },
      },
      Items = { Definitions = {
        probeMeat = { Type = '食物', Container = 'itemBar', BasePrice = 11, Stack = 3 },
        probeHead = { Type = '特殊道具', Container = 'itemBar', BasePrice = 0 },
      } },
    }
    return cfg
  end

  local JUDGMENT = { 'Health', 'Attack', 'Speed', 'EscapeSec', 'BaseWeight', 'BasePrice',
    'Bait', 'RodLevel', 'DrawWeight', 'Drops', 'Id', 'Name', 'Grade', 'ZoneId' }

  local function snapshot_numbers(cfg)
    local copy = {}
    for id, species in pairs(cfg.Fish) do
      copy[id] = {}
      for _, key in ipairs(JUDGMENT) do copy[id][key] = species[key] end
    end
    return copy
  end

  it('1-14 应用占位资源不改判定数值，新增的键只在显示白名单内', function()
    local cfg = synthetic()
    local before = snapshot_numbers(cfg)
    local drops = cfg.Fish.probeElite.Drops
    PlaceholderAssets.Apply(cfg)
    for id, species in pairs(cfg.Fish) do
      for _, key in ipairs(JUDGMENT) do
        assert.same(before[id][key], species[key], id .. ' 的判定字段 ' .. key .. ' 被占位层改了')
      end
      assert.same(drops, species.Drops, '掉落表被换成了另一份')
      for key in pairs(species) do
        assert.is_truthy(DISPLAY_FIELDS[key] or before[id][key] ~= nil,
          id .. ' 上出现了白名单外的字段：' .. tostring(key))
      end
    end
    assert.same({ 255, 130, 65, 255 }, cfg.Fish.probeElite.VisualColor, '精英品级色没有落到占位层')
    local meat = cfg.Items.Definitions.probeMeat
    assert.are.equal('official://image/13008', meat.Icon)
    assert.are.equal('official://mesh/7000557', meat.Visual.Mesh)
    assert.are.equal(11, meat.BasePrice, '物品 BasePrice 被占位层改了')
    assert.are.equal('itemBar', meat.Container, '物品 Container 被占位层改了')
    assert.are.equal(3, meat.Stack, '物品 Stack 被占位层改了')
    for key in pairs(meat) do
      assert.is_truthy(DISPLAY_FIELDS[key] or key == 'Type' or key == 'Container'
        or key == 'BasePrice' or key == 'Stack', '物品上出现了白名单外的字段：' .. tostring(key))
    end
  end)

  -- 正式资源交付时只换配置：已显式配置的图标、模型、品级色不被占位覆盖，重复 Apply 幂等。
  it('1-14 已配置的正式资源优先，重复应用占位不改写已交付的值', function()
    local cfg = synthetic()
    local meat = cfg.Items.Definitions.probeMeat
    meat.Icon, meat.IconColor = 'official://image/1', { 1, 2, 3, 255 }
    meat.Visual = { Mesh = 'official://mesh/2', Scale = { x = 1, y = 1, z = 1 } }
    cfg.Fish.probeElite.VisualColor = { 9, 9, 9, 255 }
    local before = snapshot_numbers(cfg)
    PlaceholderAssets.Apply(cfg)
    PlaceholderAssets.Apply(cfg)
    assert.are.equal('official://image/1', meat.Icon, '正式图标被占位覆盖')
    assert.same({ 1, 2, 3, 255 }, meat.IconColor)
    assert.are.equal('official://mesh/2', meat.Visual.Mesh)
    assert.same({ 9, 9, 9, 255 }, cfg.Fish.probeElite.VisualColor)
    for id, species in pairs(cfg.Fish) do
      for _, key in ipairs(JUDGMENT) do
        assert.same(before[id][key], species[key], id .. ' 的判定字段在重复应用后被改了')
      end
    end
  end)

  -- 占位与正式资源 ID 都要能在官方资产表里解析到；否则「可见」在引擎里是空的。
  it('1-14 占位与正式资源 ID 都指向官方资产表里真实存在的条目', function()
    local fishCount, itemCount = 0, 0
    for id, species in pairs(GameCfg.Fish) do
      fishCount = fishCount + 1
      assert_asset(worldMesh(species), '鱼种 ' .. id .. ' 的世界模型')
      assert.is_not_nil(species.VisualColor, id .. ' 缺品级色')
      assert.same(4, #species.VisualColor, id .. ' 的品级色不是四元色')
    end
    for id, item in pairs(GameCfg.Items.Definitions) do
      itemCount = itemCount + 1
      assert_asset(item.Icon, '物品 ' .. id .. ' 的图标')
      assert_asset(item.Visual.Mesh, '物品 ' .. id .. ' 的分类模型')
      assert.is_true(item.Visual.Scale.x > 0 and item.Visual.Scale.y > 0 and item.Visual.Scale.z > 0,
        id .. ' 的分类模型缩放不是正数')
      assert.same(4, #item.IconColor, id .. ' 的图标色不是四元色')
    end
    assert.is_true(fishCount > 0 and itemCount > 0, '配置没有装载')
  end)
end)

describe('条款 1-15 七区鱼与首领的代码路径（可见 / 可打 / 可放下）', function()
  local rows = zoneSpecies()
  local env, saved, Carrier, Unit

  before_each(function()
    env = newWorld()
    saved = installWorld(env)
    Carrier = assert(loadfile('server/WorldHost/FishCarrier.lua'))()
    package.loaded['server.WorldHost.FishCarrier'] = Carrier
    Unit = assert(loadfile('server/WorldHost/FishTree.lua'))()
    -- Start 里做的是注入 World 与开战斗通道；战斗通道不在本断言范围，只做同一份注入。
    Unit.World = env.world
    Unit.Cast = { PushState = function() end }
    Unit.Vitals = { NewHit = function(_, source, category) return { source = source, category = category } end,
      ApplyHit = function(_, _, player, amount) player.Character.Controller:TakeDamage(amount) end }
  end)

  after_each(function()
    restoreWorld(saved)
    package.loaded['server.WorldHost.FishCarrier'] = nil
    package.loaded['server.WorldHost.FishTree'] = nil
    Carrier.Carriers = {}
  end)

  it('1-15 七区都有鱼与首领，且都解析得出品级色、图标与世界模型', function()
    assert.same(7, #rows, '区数不是七个')
    for _, row in ipairs(rows) do
      assert.is_true(#row.fish > 0, row.id .. ' 没有普通或极品鱼')
      assert.is_not_nil(row.boss, row.id .. ' 没有首领')
      assert.is_not_nil(GameCfg.Fish[row.boss], row.id .. ' 的首领 ' .. tostring(row.boss) .. ' 不在鱼种表里')
      for _, id in ipairs(row.fish) do
        local species = GameCfg.Fish[id]
        assert_asset(worldMesh(species), row.id .. ' 的鱼 ' .. id .. ' 世界模型')
        for _, key in ipairs({ 'VisualColor' }) do
          assert.is_not_nil(species[key], id .. ' 缺 ' .. key)
        end
        local definition = GameCfg.Items.Definitions[id]
        assert.is_not_nil(definition, id .. ' 没有对应的物品定义（举不起来也放不下）')
        assert_asset(definition.Visual.Mesh, id .. ' 的地面模型')
      end
    end
  end)

  it('1-15 七区的鱼与首领都能经统一伤害入口打到，血量取鱼种血量', function()
    local Host = require('tests.support.life_host')
    local attacker = Host.player(7015)
    local host = Host.start({ now = 0, fish_carrier = Carrier })
    host:add(attacker)
    local vitals = host.runtime.life
    local checked = 0
    for _, row in ipairs(rows) do
      local ids = { table.unpack(row.fish) }
      ids[#ids + 1] = row.boss
      for _, id in ipairs(ids) do
        local species = GameCfg.Fish[id]
        local carrier = assert(Carrier:Spawn({ Position = vec(0, 2, 0), FishId = id,
          MaxHealth = species.Health, ModelId = species.Model, GravityEnabled = false }))
        assert.are.equal(species.Health, carrier.Controller.MaxHealth,
          id .. ' 的受击体血量不是鱼种血量')
        local before = carrier.Controller.Health
        local expected = math.min(7, species.Health)
        local ok, actual = vitals:ApplyHit(vitals:NewHit(nil, 'weapon'), carrier.Receiver, 7)
        assert.is_true(ok, id .. ' 打不动：统一入口没有结算')
        assert.same(expected, actual, id .. ' 的实际伤害不是命中值（按剩余血量夹取）')
        assert.same(before - expected, carrier.Controller.Health, id .. ' 的血量没有下降')
        checked = checked + 1
      end
    end
    assert.is_true(checked >= #rows + 1, '七区鱼与首领没有全部跑到')
    host:shutdown()
  end)

  it('1-15 钓上来的一条鱼能举起并放下：本体回世界、状态离开举着、挂点销毁', function()
    local character = { Position = vec(10, 2, -20),
      Rotation = { GetForward = function() return vec(0, 0, 1) end },
      Controller = { Lift = function() end, LiftedEnabled = true } }
    character.Controller.Lift = function(_, unit) env.lifted = unit end
    local player = { UserId = 9, Character = character, CharacterAdded = signal(), CharacterRemoving = signal() }
    env.players = { player }
    local drops = 0
    for _, row in ipairs(rows) do
      for _, id in ipairs({ row.boss, row.fish[1] }) do
        local fish = assert(Unit:SpawnLanded(player, { fishId = id, mult = 1.37 }, vec(10, 2, -18)))
        assert.same(Unit.State.AwaitLift, fish.State, id .. ' 上岸后不是待抓举')
        assert.are.equal('official://mesh/' .. tostring(GameCfg.Fish[id].Model),
          fish.Carrier.Body.RenderMeshId, id .. ' 的世界模型不是占位模型')
        assert.is_true(fish.Carrier.Body.Liftable, id .. ' 的本体不可举起')

        fish.Carrier.Body.OnLiftedBegin:Fire(character)
        assert.same(Unit.State.Held, fish.State, id .. ' 没有被举起')
        assert.same(fish, Unit:GetHeld(player))

        assert.is_true(Unit:Drop(player), id .. ' 放不下')
        -- 普通鱼与极品鱼放下后回到世界逃水；精英与首领放下后直接进入战斗/飞行，
        -- 所以这里只判「离开了举着状态」，具体去向由各自的战斗用例覆盖。
        assert.are_not.equal(Unit.State.Held, fish.State, id .. ' 放下后仍在举着状态')
        assert.is_nil(Unit:GetHeld(player), id .. ' 放下后仍记着持有')
        assert.is_nil(fish.Mount, id .. ' 放下后挂点没清空')
        assert.is_true(fish.Carrier.Body.Parent == env.world or fish.Carrier.Body.Destroyed == true,
          id .. ' 放下后本体没有回世界')
        drops = drops + 1
      end
    end
    assert.is_true(drops >= 7, '七区首领与鱼没有全部跑到放下')
  end)
end)