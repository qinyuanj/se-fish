
local GameCfg = require("common.GameCfg")
local ServerRuntime = require("server.WorldHost.ServerRuntime")
local SwingRegistry = require("server.SwingRegistry")

local function signal()
  local handlers = {}
  return {
    Connect = function(_, fn)
      handlers[#handlers + 1] = fn
      return { Disconnect = function()
        for i, h in ipairs(handlers) do
          if h == fn then table.remove(handlers, i) return end
        end
      end }
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
  return {
    UserId = id,
    Name = "p" .. tostring(id),
    attrs = {},
    CharacterAdded = signal(),
    CharacterRemoving = signal(),
    SetAttribute = function(self, key, value) self.attrs[key] = value end,
    GetAttribute = function(self, key) return self.attrs[key] end,
    Character = {
      Controller = controller,
      Position = { x = x or 0, y = 2, z = z or 0 },
      Size = { y = 2 },
      Rotation = { GetForward = function() return { x = 0, y = 0, z = 1 } end },
    },
  }
end

local function make_data(player, overrides)
  overrides = overrides or {}
  return {
    Player = player,
    Inited = true,
    LoadState = "ready",
    Data = {
      FishCoin = 0,
      Zone = "fishPond",
      Weapons = overrides.weapons or {},
      Containers = {
        [GameCfg.Items.ContainerId.ItemBar] = {},
        [GameCfg.Items.ContainerId.Backpack] = {},
      },
    },
    Extra = {
      growth = { potions = {}, upgrades = overrides.upgrades or {} },
      inventory = { selection = { held = overrides.held or {} } },
      survival = { health = GameCfg.Vitals.MaxHealth, hunger = GameCfg.Vitals.MaxHunger },
    },
    MagazineSize = function(self, base)
      return GameCfg.Shop.MagazineSize(base, self.Extra.growth.upgrades.magazine or 0)
    end,
  }
end

local function last_result(events, player)
  local sent = events.WeaponResult and events.WeaponResult.clients or {}
  local found
  for _, row in ipairs(sent) do
    if row.player == player then found = row.value end
  end
  return found
end

local function hold(runtime, player, data, weapon_id)
  data.Extra.inventory.selection.held = { kind = "weapon", id = weapon_id }
  runtime:get_player_tree(player.UserId):sync_from_data(data)
end

describe("武器攻击换弹与 PK 过滤宿主接缝（#300）", function()
  local runtime, events, player, other, data, casts, rays, ray_hit

  local function squad_action(actor, payload)
    events.PartyAction.OnServerEvent:Fire(actor, payload)
  end

  local function make_squad()
    squad_action(player, { action = "Invite", targetUserId = other.UserId })
    squad_action(other, { action = "Accept" })
  end

  local function boot(overrides, other_overrides)
    events = {}
    local re = {
      GetRE = function(_, name)
        events[name] = events[name] or {
          clients = {},
          OnServerEvent = signal(),
          FireClient = function(self, target, payload)
            self.clients[#self.clients + 1] = { player = target, value = payload }
          end,
          FireAllClients = function(self, payload)
            self.clients[#self.clients + 1] = { player = "all", value = payload }
          end,
        }
        return events[name]
      end,
      CheckRECD = function() return false end,
    }
    re:GetRE("WeaponAction")
    re:GetRE("WeaponResult")
    re:GetRE("PartyAction")
    player = make_player(1, overrides and overrides.px or 0, overrides and overrides.pz or 0)
    other = make_player(2, other_overrides and other_overrides.px or 4, other_overrides and other_overrides.pz or 0)
    data = make_data(player, overrides)
    local other_data = make_data(other, other_overrides)
    casts, rays, ray_hit = {}, {}, nil
    runtime = ServerRuntime.new({
      initial_now = 1000,
      remote = re,
      player_data = {
        GetDataInst = function(_, target)
          if target == player then return data end
          if target == other then return other_data end
        end,
      },
      physics = {
        Raycast = function(self, origin, direction)
          if direction == nil then origin, direction = self, origin end
          rays[#rays + 1] = { origin = origin, direction = direction }
          return ray_hit
        end,
      },
      players_service = {
        GetPlayers = function() return { player, other } end,
        GetPlayerFromCharacter = function(_, character)
          if character == player.Character then return player end
          if character == other.Character then return other end
          return nil
        end,
      },
      ability = {
        CastAbility = function(unit, index)
          casts[#casts + 1] = { unit = unit, index = index }
          return true
        end,
        MeleeIndex = function()
          for _, entry in ipairs(GameCfg.Ability.InitialAbilities or {}) do
            if entry.AnchorBehavior == "melee_hit" then return entry.Index end
          end
          return 0
        end,
      },
      zone_markers = require("common.ZoneMarkers"),
      bind_party_action = function(dispatch)
        events.PartyAction.OnServerEvent:Connect(function(actor, payload) dispatch(actor, payload) end)
      end,
      bind_weapon_action = function(dispatch)
        events.WeaponAction.OnServerEvent:Connect(function(actor, payload)
          dispatch(actor, payload)
        end)
      end,
    })
    runtime:start()
    runtime:mark_started()
    runtime:on_player_added(player)
    runtime:on_save_ready(player, data)
    runtime:on_player_added(other)
    runtime:on_save_ready(other, other_data)
  end

  local function attack(aim)
    events.WeaponAction.OnServerEvent:Fire(player, { action = "attack", aim = aim })
    return last_result(events, player)
  end

  after_each(function()
    if runtime then runtime:shutdown() end
    runtime = nil
    SwingRegistry.ClearSwing(1)
    SwingRegistry.ClearSwing(2)
  end)

  it("存活未麻痹时可近战，冷却与切武器各自计时，麻痹与离场拒绝并清登记", function()
    boot({ weapons = { item136 = 1, item135 = 1 }, held = { kind = "weapon", id = "item136" } })
    local first = attack()
    assert.is_true(first and first.ok)
    assert.same(GameCfg.Ability.MeleeWeapons.item136.Damage, first.damage)
    assert.is_not_nil(SwingRegistry.PeekSwing(player.UserId))
    assert.same(1, #casts)

    assert.same("cooldown", attack().reason)
    assert.same(1, #casts)

    hold(runtime, player, data, "item135")
    runtime.clock:advance(0.5)
    assert.is_true(attack().ok)
    assert.same(2, #casts)
    assert.same(GameCfg.Ability.MeleeWeapons.item135.Damage, SwingRegistry.PeekSwing(player.UserId).damage)

    runtime:get_player_tree(player.UserId):apply_modifier("paralyze", { duration = 0.5 })
    runtime.clock:step(0)
    assert.same("cannot-act", attack().reason)
    assert.is_nil(SwingRegistry.PeekSwing(player.UserId))

    runtime.clock:advance(1)
    assert.is_true(attack().ok)
    runtime:on_player_removing(player)
    assert.is_nil(SwingRegistry.PeekSwing(player.UserId))
  end)

  it("枪械按弹匣扣弹，空匣自动换弹两秒，切武器不能绕过未完成换弹", function()
    boot({ weapons = { item137 = 1, item141 = 1 }, held = { kind = "weapon", id = "item137" } })
    for _ = 1, 10 do
      runtime.clock:advance(1)
      assert.is_true(attack({ x = 0, y = 0, z = 1 }).ok)
    end
    assert.same(0, last_result(events, player).ammo)
    runtime.clock:advance(1)
    local empty = attack({ x = 0, y = 0, z = 1 })
    assert.same("empty", empty.reason)
    assert.is_true(empty.autoReload)
    assert.same("reloading", attack({ x = 0, y = 0, z = 1 }).reason)

    hold(runtime, player, data, "item141")
    runtime.clock:advance(1.5)
    assert.is_true(attack({ x = 0, y = 0, z = 1 }).ok)
    hold(runtime, player, data, "item137")
    assert.same("reloading", attack({ x = 0, y = 0, z = 1 }).reason)
    runtime.clock:advance(2)
    local refilled = attack({ x = 0, y = 0, z = 1 })
    assert.is_true(refilled.ok)
    assert.same(9, refilled.ammo)
  end)

  it("权威弹道从胸口发出，墙挡住伪造目标，非法瞄准不扣弹", function()
    boot({ px = 241, pz = 0, weapons = { item141 = 1 }, held = { kind = "weapon", id = "item141" } }, { px = 242, pz = 0 })
    attack({ x = 0, y = 30, z = 40 })
    assert.near(player.Character.Position.x, rays[1].origin.x, 1e-6)
    assert.near(player.Character.Position.y + 1, rays[1].origin.y, 1e-6)
    assert.near(player.Character.Position.z, rays[1].origin.z, 1e-6)
    assert.near(GameCfg.Ability.GunShared.Range * 0.6, rays[1].direction.y, 1e-6)
    assert.near(GameCfg.Ability.GunShared.Range * 0.8, rays[1].direction.z, 1e-6)

    runtime.clock:advance(2)
    ray_hit = { Instance = { UnitId = 9 }, Position = { x = 0, y = 4, z = 2 } }
    attack({ x = 0, y = 0, z = 1 })
    assert.same(GameCfg.Vitals.MaxHealth, other.Character.Controller.Health)
    local ammo = last_result(events, player).ammo

    for _, bad in ipairs({ {}, { x = 0, y = 0, z = 0 }, { x = 0, y = 0 / 0, z = 1 }, { x = 0, y = math.huge, z = 1 } }) do
      runtime.clock:advance(2)
      assert.same("bad-aim", attack(bad).reason)
    end
    runtime.clock:advance(2)
    assert.same(ammo - 1, attack({ x = 0, y = 0, z = 1 }).ammo)
  end)

  it("霰弹一壳结算五次，火箭直伤与溅射不双算也不炸自己", function()
    boot({ px = 241, pz = 0, weapons = { item138 = 1 }, held = { kind = "weapon", id = "item138" } }, { px = 242, pz = 0 })
    ray_hit = { Instance = other.Character, Position = { x = 0, y = 2, z = 5 } }
    attack({ x = 0, y = 0, z = 1 })
    assert.same(GameCfg.Vitals.MaxHealth - 20 * 5, other.Character.Controller.Health)
    assert.same(1, last_result(events, player).ammo)

    hold(runtime, player, data, nil)
    data.Data.Weapons.item142 = 1
    hold(runtime, player, data, "item142")
    other.Character.Controller.Health = GameCfg.Vitals.MaxHealth
    other.Character.Position = { x = 0, y = 2, z = 4 }
    ray_hit = { Instance = other.Character, Position = { x = 0, y = 2, z = 4 } }
    runtime.clock:advance(2)
    other.Character.Controller.Health = 800
    runtime:get_player_tree(other.UserId).states.health:set(800)
    attack({ x = 0, y = 0, z = 1 })
    assert.same(300, other.Character.Controller.Health)
    assert.same(GameCfg.Vitals.MaxHealth, player.Character.Controller.Health)
    assert.same(0, last_result(events, player).ammo)
  end)

  it("鱼塘内非同队免伤，鱼塘外与离队后扣血，鱼攻击不被安全区挡住", function()
    boot({ px = 6.26, pz = -0.71 }, { px = 5, pz = -9 })
    local life = runtime.life
    assert.is_false(life:ApplyHit(life:NewHit(player, "gun"), other, 45))
    assert.same(GameCfg.Vitals.MaxHealth, other.Character.Controller.Health)

    player.Character.Position = { x = 241, y = 6, z = 0 }
    other.Character.Position = { x = 242, y = 6, z = 0 }
    assert.is_true(life:ApplyHit(life:NewHit(player, "gun"), other, 20))
    assert.same(GameCfg.Vitals.MaxHealth - 20, other.Character.Controller.Health)

    make_squad()
    assert.is_false(life:ApplyHit(life:NewHit(player, "melee"), other, 20))
    squad_action(player, { action = "Leave" })
    assert.is_true(life:ApplyHit(life:NewHit(player, "melee"), other, 20))

    local fish = { Id = 91 }
    local before = other.Character.Controller.Health
    assert.is_true(life:ApplyHit(life:NewHit(fish, "fishAttack"), other, 10))
    assert.same(before - 10, other.Character.Controller.Health)
  end)

  it("命中才挂持续效果，被拒不挂，到期后注销", function()
    boot({
      px = 241, pz = 0,
      weapons = { item164 = 1 },
      held = { kind = "weapon", id = "item164" },
    }, { px = 242, pz = 0 })
    ray_hit = { Instance = other.Character, Position = { x = 242, y = 2, z = 0 } }
    make_squad()
    attack({ x = 1, y = 0, z = 0 })
    local target = runtime:get_player_tree(other.UserId)
    assert.same(0, target:get_modifier_remaining("paralyze"))

    squad_action(player, { action = "Leave" })
    runtime.clock:advance(1)
    attack({ x = 1, y = 0, z = 0 })
    assert.is_true(target:get_modifier_remaining("paralyze") > 0)
    runtime.clock:advance(1)
    assert.same(0, target:get_modifier_remaining("paralyze"))
  end)
end)
