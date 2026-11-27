
local GameCfg = require("common.game_cfg")
local ServerRuntime = require("server.world_host.server_runtime")

local function signal()
  local handlers = {}
  return {
    Connect = function(_, fn)
      handlers[#handlers + 1] = fn
      return { Disconnect = function() end }
    end,
    Fire = function(_, ...)
      for _, fn in ipairs({ table.unpack(handlers) }) do fn(...) end
    end,
  }
end

local function make_player(id, x, z)
  local controller = {
    Health = GameCfg.Vitals.MaxHealth,
    MaxHealth = GameCfg.Vitals.MaxHealth,
    WalkSpeed = 16,
    HealthChanged = signal(),
    Died = signal(),
  }
  function controller:TakeDamage(amount)
    self.Health = math.max(0, self.Health - amount)
    self.HealthChanged:Fire(self.Health)
    if self.Health <= 0 then self.Died:Fire() end
  end
  local player = {
    UserId = id,
    Name = "p" .. tostring(id),
    attrs = {},
    CharacterAdded = signal(),
    CharacterRemoving = signal(),
    SetAttribute = function(self, key, value) self.attrs[key] = value end,
    GetAttribute = function(self, key) return self.attrs[key] end,
    Character = {
      Controller = controller,
      Position = { x = x or 10, y = 2, z = z or -20 },
      Size = { y = 2 },
      Rotation = { GetForward = function() return { x = 0, y = 0, z = 1 } end },
    },
  }
  function controller:Lift(body)
    if body and body.OnLiftedBegin then body.OnLiftedBegin:Fire(player.Character) end
  end
  return player
end

local function make_data(player)
  return {
    Player = player,
    inited = true,
    load_state = "ready",
    data = {
      FishCoin = 0,
      Zone = "fishPond",
      weapons = {},
      containers = {
        [GameCfg.Items.ContainerId.ItemBar] = {},
        [GameCfg.Items.ContainerId.Backpack] = {},
      },
    },
    extra = {
      growth = { potions = {}, upgrades = {} },
      inventory = { selection = { held = {} } },
      survival = { health = GameCfg.Vitals.MaxHealth, hunger = GameCfg.Vitals.MaxHunger },
    },
  }
end

local function ensure_engine()
  if rawget(_G, "Quaternion") == nil then
    _G.Quaternion = { FromEulerAngles = function()
      return { GetForward = function() return { x = 0, y = 0, z = 1 } end }
    end }
  end
  if rawget(_G, "Color") == nil then
    _G.Color = { New = function(r, g, b, a) return { r = r, g = g, b = b, a = a } end }
  end
end

local function boot(overrides)
  ensure_engine()
  local units = {}
  local seq = 0
  local ai = { started = {}, stopped = {} }
  local options = {
    initial_now = 1000,
    remote = {
      get_re = function()
        return {
          OnServerEvent = signal(),
          FireClient = function() end,
          FireAllClients = function() end,
        }
      end,
      check_recd = function() return false end,
    },
    player_data = { get_data_inst = function() return nil end },
    create_unit = function(_, props)
      seq = seq + 1
      local unit = {
        UnitId = seq,
        Name = props and props.Name,
        Position = props and props.Position or { x = 10, y = 2, z = -18 },
        Rotation = { GetForward = function() return { x = 0, y = 0, z = 1 } end },
        Destroyed = false,
        Destroy = function(self) self.Destroyed = true end,
        AddNoCollisionPairWithUnit = function() end,
        OnLiftedBegin = signal(),
        OnLiftedEnd = signal(),
      }
      if props and props.EnableController then
        unit.Controller = {
          Health = 300,
          MaxHealth = 300,
          HealthChanged = signal(),
          Died = signal(),
          TakeDamage = function(self, amount)
            self.Health = math.max(0, self.Health - amount)
            self.HealthChanged:Fire(self.Health)
          end,
        }
      end
      units[#units + 1] = unit
      return unit
    end,
    ai = {
      start = function(_, fish_id)
        ai.started[#ai.started + 1] = fish_id
        return true
      end,
      stop = function(_, fish_id)
        ai.stopped[#ai.stopped + 1] = fish_id
      end,
      command = function() return true end,
    },
  }
  for key, value in pairs(overrides or {}) do options[key] = value end
  local runtime = ServerRuntime.new(options)
  runtime:start()
  runtime:mark_started()
  return runtime, units, ai
end

local function alive_units(units)
  local n = 0
  for _, unit in ipairs(units) do
    if unit.Destroyed ~= true then n = n + 1 end
  end
  return n
end

local function join(runtime, player)
  local data = make_data(player)
  runtime:on_player_added(player)
  runtime:on_save_ready(player, data)
  return runtime:get_player_tree(player.UserId)
end

describe("活鱼树宿主入口（#309）", function()
  it("举鱼期间放下、濒死、死亡或离场都会让鱼自己落地", function()
    local runtime, units = boot()
    local player = make_player(1)
    join(runtime, player)
    local ok, err = runtime:receive_landed(player, {
      fishId = "bass", mult = 1.37, x = 10, y = 2, z = -18,
    })
    assert.is_true(ok, tostring(err))
    local fish = runtime:fish_snapshot(player.UserId)[1]
    assert.equals("lifted", fish.phase)

    assert.is_true(runtime:drop_fish(player))
    fish = runtime:fish_snapshot()[1]
    assert.not_equals("lifted", fish.phase)
    assert.is_true(fish.grounded)

    local again = make_player(2, 12, -20)
    join(runtime, again)
    assert.is_true(runtime:receive_landed(again, { fishId = "bass", mult = 1, x = 12, y = 2, z = -18 }))
    runtime.life:apply_damage(again, GameCfg.Vitals.MaxHealth)
    local downed = runtime:fish_snapshot(again.UserId)[1]
    assert.not_equals("lifted", downed.phase)

    local third = make_player(3, 14, -20)
    join(runtime, third)
    assert.is_true(runtime:receive_landed(third, { fishId = "carp", mult = 1, x = 14, y = 2, z = -18 }))
    runtime:on_player_removing(third)
    runtime:step(0, 1000)
    assert.equals(0, #runtime:fish_snapshot(third.UserId))
    local found = false
    local rows = runtime:fish_snapshot()
    for _, row in ipairs(rows) do
      if row.fishId == "carp" and row.grounded then found = true end
    end
    if not found then
      local dump = {}
      for _, row in ipairs(rows) do
        dump[#dump + 1] = tostring(row.fishId) .. "/" .. tostring(row.phase) .. "/" .. tostring(row.grounded) .. "/" .. tostring(row.holderId)
      end
      assert.is_true(false, "离场鱼没有落地: " .. table.concat(dump, ","))
    end
    assert.is_true(alive_units(units) > 0)
  end)

  it("精英 180 秒、首领 300 秒到点才离场，击杀掉落进地面集合", function()
    local runtime = boot()
    local player = make_player(4)
    join(runtime, player)
    assert.is_true(runtime:receive_landed(player, { fishId = "eel", mult = 1.5, x = 10, y = 2, z = -18 }))
    assert.is_true(runtime:drop_fish(player))
    runtime:step(179, 1179)
    local elite = runtime:fish_snapshot()[1]
    assert.is_not_nil(elite)
    assert.not_equals("gone", elite.phase)
    runtime:step(1, 1180)
    local left = runtime:fish_snapshot()
    if #left > 0 then
      assert.equals("escape", left[1].phase)
      assert.is_true(runtime:damage_fish(left[1].id, left[1].max_health))
    end
    assert.equals(0, #runtime:fish_snapshot())

    local boss_player = make_player(5, 20, -20)
    join(runtime, boss_player)
    assert.is_true(runtime:receive_landed(boss_player, {
      fishId = "alligatorGar", mult = 2, x = 20, y = 2, z = -18,
    }))
    assert.is_true(runtime:drop_fish(boss_player))
    runtime:step(299, 1479)
    assert.equals(1, #runtime:fish_snapshot())
    local before = runtime:get_world():ground_snapshot().list
    local fish = runtime:fish_snapshot()[1]
    assert.is_true(runtime:damage_fish(fish.id, fish.max_health))
    local after = runtime:get_world():ground_snapshot().list
    assert.is_true(#after > #before)
    local ids = {}
    for _, row in ipairs(after) do ids[row.itemId] = true end
    assert.is_true(ids.garMeat)
    assert.is_true(ids.garHead)
    assert.equals(0, #runtime:fish_snapshot())
  end)

  it("哥斯拉按血量切三阶段，清理时拆掉预警、挂点、隔离和载体并注销 AI", function()
    local runtime, units, ai = boot()
    local player = make_player(6, 30, -20)
    join(runtime, player)
    assert.is_true(runtime:receive_landed(player, {
      fishId = "fish56Boss", mult = 1, x = 30, y = 2, z = -18,
    }))
    assert.is_true(runtime:drop_fish(player))
    local fish = runtime:fish_snapshot()[1]
    assert.equals("land", fish.bossPhase)
    assert.is_true(#ai.started >= 1)

    local max_health = fish.max_health
    assert.is_true(runtime:damage_fish(fish.id, max_health * 0.4))
    fish = runtime:fish_snapshot()[1]
    assert.equals("water", fish.bossPhase)

    assert.is_true(runtime:damage_fish(fish.id, max_health * 0.4))
    fish = runtime:fish_snapshot()[1]
    assert.equals("enraged", fish.bossPhase)

    runtime:step(300, 1300)
    local left = runtime:fish_snapshot()
    if #left > 0 then
      assert.equals("escape", left[1].phase)
      assert.is_true(runtime:damage_fish(left[1].id, left[1].health))
    end
    assert.equals(0, #runtime:fish_snapshot())
    local names = {}
    for _, unit in ipairs(units) do
      local name = tostring(unit.Name)
      if unit.Destroyed ~= true and (name:find("Fish", 1, true) or name:find("Carry", 1, true)) then
        names[#names + 1] = name
      end
    end
    assert.equals(0, #names, "残留单位 " .. table.concat(names, ","))
    assert.is_true(#ai.stopped >= 1)
    local other = make_player(7)
    local other_tree = join(runtime, other)
    assert.is_false(other_tree:is_faulted())
    assert.is_false(runtime:get_world():is_disposed())
  end)

  it("单棵活鱼树故障不影响玩家树、世界树和其他活鱼", function()
    local runtime = boot()
    local player = make_player(8)
    local tree = join(runtime, player)
    assert.is_true(runtime:receive_landed(player, { fishId = "bass", mult = 1, x = 10, y = 2, z = -18 }))
    assert.is_true(runtime:receive_landed(player, { fishId = "carp", mult = 1, x = 12, y = 2, z = -18 }))
    local rows = runtime:fish_snapshot()
    assert.equals(2, #rows)
    local doomed = runtime.fish_host.Fish[rows[1].id]
    assert.is_true(runtime:fault_fish(rows[1].id, "boom"))
    assert.is_not_nil(doomed.tree.fault, "fault_fish 须实证真实 SpokeTree 故障隔离")
    runtime:step(0, 1001)
    assert.is_false(tree:is_faulted())
    assert.is_false(runtime:get_world():is_disposed())
    local left = runtime:fish_snapshot()
    assert.equals(1, #left)
    assert.equals(rows[2].id, left[1].id)
  end)

  it("经 FishTree 直接上岸的活鱼同步发布且空闲帧不重复发空表，同时驱动 FishCarrier:Update", function()
    local broadcasts, carrier_updates = {}, 0
    local runtime = boot({
      remote = {
        get_re = function(_, name)
          return {
            OnServerEvent = signal(),
            FireClient = function() end,
            FireAllClients = function(_, payload)
              if name == "FishCombatState" then broadcasts[#broadcasts + 1] = payload end
            end,
          }
        end,
        check_recd = function() return false end,
      },
      fish_carrier = {
        update = function() carrier_updates = carrier_updates + 1 end,
      },
    })
    local player = make_player(10)
    join(runtime, player)
    runtime:step(0.1, 1000.1)
    runtime:step(0.1, 1000.2)
    assert.equals(0, #broadcasts, "无活鱼时不得每帧发空 FishCombatState")
    assert.equals(2, carrier_updates, "ServerRuntime:step 须驱动 FishCarrier:Update")

    local spawned = runtime.fish_host:spawn_landed(player, { fishId = "bass", mult = 1.2 }, { x = 10, y = 2, z = -18 })
    assert.is_not_nil(spawned)
    runtime:step(0.1, 1000.3)
    assert.equals(1, #broadcasts)
    assert.equals(1, #broadcasts[1].list)
    assert.equals(spawned.Id, broadcasts[1].list[1].id)
    assert.equals(1, #runtime:fish_snapshot())
    runtime:step(0.1, 1000.4)
    assert.equals(1, #broadcasts, "状态未变化时不重复推送")
  end)

  it("官方 AI 启动失败会记录且后续帧重试，清理仍对称注销", function()
    local attempts, logs = 0, {}
    local runtime = boot({
      logger = { error = function(...) logs[#logs + 1] = table.concat({ ... }, " ") end },
      ai = {
        start = function()
          attempts = attempts + 1
          return attempts > 1
        end,
        stop = function() end,
        command = function() return true end,
      },
    })
    local player = make_player(9)
    join(runtime, player)
    assert.is_true(runtime:receive_landed(player, { fishId = "bass", mult = 1, x = 10, y = 2, z = -18 }))
    assert.is_true(runtime:drop_fish(player))
    runtime:step(0, 1000)
    runtime:step(0.1, 1000.1)
    assert.is_true(attempts >= 2, "启动失败不得提前标记 ai_started")
    assert.is_true(#logs >= 1, "启动失败必须留下模块、操作、对象和错误日志")
    local fish = runtime:fish_snapshot()[1]
    assert.is_true(runtime:damage_fish(fish.id, fish.max_health))
    assert.equals(0, #runtime:fish_snapshot())
  end)
end)
