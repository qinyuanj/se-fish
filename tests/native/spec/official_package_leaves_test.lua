-- #297-A2 契约测试：服务端官方包单向输出叶子投影层（AttrLeaf / ModifierLeaf / AbilityLeaf）。
-- 失败方式先列：
--   1. AttrLeaf 未拒绝地图 Min/Max 钳制配置，或销毁了外部已有 AttrUnit，或角色重建/树销毁泄漏新建 AttrUnit；
--   2. AttrLeaf 未同步写入 7 个属性键四分量，或未投影 SetScale / CameraDistance / InteractRange / BodyScaleCapped / WalkSpeed；
--   3. ModifierLeaf 未强制传 removeMode = 0，或依赖包内事件驱动业务计时，或槽位退出/角色重建/树销毁未对称 RemoveModifier；
--   4. ModifierLeaf 活鱼辅助接口在目标死亡/来源离场/到期后未清理官方包实体或未正确返回减速/麻痹状态；
--   5. AbilityLeaf 在角色更换/树销毁时未停止技能并销毁管理器，或延迟就绪重试在角色销毁后仍泄漏执行；
--   6. AbilityLeaf 未按 PlayerTree.memos.can_act 拦截施法，或无法兼容真机 userdata（newproxy）对象。

local GameCfg = require("common.game_cfg")
local BodyScale = require("common.body_scale")
local SpokeClock = require("common.spoke_clock")
local SpokeRuntime = require("common.packages.spoke.runtime.spoke_runtime")
local PlayerTree = require("server.world_host.player_tree")
local PlayerEffects = require("server.world_host.player_effects")
local AttrLeaf = require("server.world_host.attr_leaf")
local ModifierLeaf = require("server.world_host.modifier_leaf")
local AbilityLeaf = require("server.world_host.ability_leaf")

local function make_ready_data(player, overrides)
  overrides = overrides or {}
  return {
    Player = player,
    Inited = true,
    LoadState = "ready",
    Data = {
      FishCoin = overrides.coin or 0,
      Zone = overrides.zone or "fishPond",
      SelectedSlot = overrides.selected_slot,
    },
    Extra = {
      growth = {
        potions = {
          item168 = overrides.body_potions or 0,
          item167 = overrides.speed_potions or 0,
        },
        upgrades = overrides.upgrades or {},
      },
      survival = {
        health = overrides.health or GameCfg.Vitals.MaxHealth,
        hunger = overrides.hunger or GameCfg.Vitals.MaxHunger,
        dying = false,
        dead = false,
        weakRemaining = overrides.weak_remaining or 0,
      },
    },
  }
end

-- 构造独立沙盒加载真实 attr_rule 官方包，仅提供最小 Unit/World 引擎替身。
local function make_real_attr_sandbox()
  local all, cache = {}, {}
  local world = {}
  local function unit(kind, parent)
    local u = {
      Parent = parent,
      attrs = {},
      Controller = kind == "Character" and { WalkSpeed = 7, MaxHealth = 100, Health = 100 } or nil,
    }
    function u:GetAttribute(k) return self.attrs[k] end
    function u:SetAttribute(k, v) self.attrs[k] = v end
    function u:IsA(k) return k == kind end
    function u:GetChildren()
      local out = {}
      for _, v in ipairs(all) do
        if v.Parent == self and not v.destroyed then out[#out + 1] = v end
      end
      return out
    end
    function u:FindFirstChildOfClass(k)
      if k == "PresetLink" and kind == "Script" then
        return { GetAttribute = function() return "AttrUnit" end }
      end
    end
    function u:Destroy() self.Parent = nil; self.destroyed = true end
    function u:SetScale(v) self.scale = v.x end
    all[#all + 1] = u
    return u
  end
  function world:CreateAsset() return { unit("Script", world) } end
  local env = setmetatable({
    game = { GetService = function() return world end },
    Vector3 = { New = function(x, y, z) return { x = x, y = y, z = z } end },
  }, { __index = _G })
  env.require = function(name)
    if cache[name] then return cache[name] end
    cache[name] = assert(loadfile(name:gsub("%.", "/") .. ".lua", "t", env))()
    return cache[name]
  end
  local attr_api = env.require("server.packages.attr_rule.api")
  return attr_api, unit, world
end

-- 构造独立沙盒加载真实 modifier_system 官方包，记录每次 AddModifier 入参。
local function make_real_modifier_sandbox()
  local e = { now = 100, units = {}, timers = {}, add_calls = {} }
  local function signal()
    local tokens = {}
    return {
      Connect = function(_, fn)
        local token = { fn = fn, active = true }
        tokens[#tokens + 1] = token
        return { Disconnect = function() token.active = false end }
      end,
      Fire = function(_, ...)
        for _, token in ipairs(tokens) do
          if token.active then token.fn(...) end
        end
      end,
    }
  end
  function e.unit(name)
    local u = { Name = name, UnitId = #e.units + 1, attrs = {}, Destroying = signal() }
    e.units[#e.units + 1] = u
    function u:GetAttribute(k) return self.attrs[k] end
    function u:SetAttribute(k, v) self.attrs[k] = v end
    function u:get_component() return nil end
    function u:IsA(kind) return kind == "BindableEvent" and name == "BindableEvent" end
    function u:GetChildren()
      local out = {}
      for _, child in ipairs(e.units) do
        if child.Parent == self and not child.destroyed then out[#out + 1] = child end
      end
      return out
    end
    function u:FindFirstChild(child_name)
      for _, child in ipairs(self:GetChildren()) do
        if child.Name == child_name then return child end
      end
    end
    function u:Destroy()
      if self.destroyed then return end
      self.destroyed = true
      self.Destroying:Fire()
      for _, child in ipairs(self:GetChildren()) do child:Destroy() end
    end
    local ev = signal()
    function u:Connect(fn) return ev:Connect(fn) end
    function u:Fire(...) ev:Fire(...) end
    return u
  end
  local world = {
    GetServerTime = function() return e.now end,
    CreateAsset = function(_, key)
      local u = e.unit(key)
      -- 模拟 #177 新版预设壳默认 RemoveMode = 1（击败后清除），验证叶子层强制覆盖 removeMode = 0。
      u:SetAttribute("RemoveMode", 1)
      return { u }
    end,
  }
  local timer_service = {
    CreateTimer = function(_, _, duration, _, callback)
      local t = { due = e.now + duration, callback = callback }
      function t:Cancel() self.cancelled = true end
      e.timers[#e.timers + 1] = t
      return t
    end,
  }
  local mock_game = {
    GetService = function(_, name)
      if name == "World" then return world end
      if name == "TimerService" then return timer_service end
      if name == "RunService" then return { IsServer = function() return true end } end
      return {}
    end,
    CreateUnit = function(_, _, props)
      local u = e.unit("BindableEvent")
      u.Name = props.Name
      return u
    end,
  }
  local mock_remote = {
    New = function()
      return { OnServerEvent = signal(), FireAllClients = function() end }
    end,
  }
  local cache = {}
  local env = setmetatable({ game = mock_game, RemoteEvent = mock_remote }, { __index = _G })
  env.require = function(name)
    if name:find("modifier_system", 1, true) then
      if not cache[name] then
        cache[name] = assert(loadfile(name:gsub("%.", "/") .. ".lua", "t", env))()
      end
      return cache[name]
    end
    return require(name)
  end
  local raw_api = env.require("server.packages.modifier_system.api")
  local wrapped_api = setmetatable({
    AddModifier = function(owner, preset, add_cfg)
      e.add_calls[#e.add_calls + 1] = { owner = owner, preset = preset, cfg = add_cfg }
      return raw_api.AddModifier(owner, preset, add_cfg)
    end,
  }, { __index = raw_api })
  return wrapped_api, raw_api, e
end

-- 构造带 __index / __newindex 的只读代理模拟真机 userdata 行为。
local function make_userdata_proxy(backing)
  if type(newproxy) == "function" then
    local proxy = newproxy(true)
    local mt = getmetatable(proxy)
    mt.__index = function(_, k)
      local v = backing[k]
      if type(v) == "function" then
        return function(_, ...) return v(backing, ...) end
      end
      return v
    end
    mt.__newindex = function(_, k, v) backing[k] = v end
    return proxy
  end
  return setmetatable({}, {
    __index = function(_, k)
      local v = backing[k]
      if type(v) == "function" then
        return function(_, ...) return v(backing, ...) end
      end
      return v
    end,
    __newindex = function(_, k, v) backing[k] = v end,
  })
end

describe("AttrLeaf：attr_rule 官方包单向叶子投影", function()
  local saved_vec3

  before_each(function()
    saved_vec3 = rawget(_G, "Vector3")
    _G.Vector3 = { New = function(x, y, z) return { x = x, y = y, z = z } end }
  end)

  after_each(function()
    _G.Vector3 = saved_vec3
    saved_vec3 = nil
  end)

  it("单向写入七个属性键四分量与角色表现，并在角色重建与树销毁时仅销毁新建 AttrUnit", function()
    local attr_api, make_unit, world = make_real_attr_sandbox()
    local clock = SpokeClock.new(100)
    local char1 = make_unit("Character", world)
    char1.Controller.WalkSpeed = 8
    local player = { UserId = 9101, Character = char1 }
    local errors = {}

    local pt = PlayerTree.spawn({
      player = player,
      data = make_ready_data(player, {
        body_potions = 2,
        speed_potions = 3,
        upgrades = { melee = 2, ranged = 1, explosive = 3 },
        hunger = 210,
      }),
      clock = clock,
      mounts = {
        attributes = function(s2, tree)
          PlayerEffects.mount(s2, tree)
          AttrLeaf.mount(s2, tree, {
            attr_api = attr_api,
            on_error = function(msg) errors[#errors + 1] = msg end,
          })
        end,
      },
    })

    assert.same({}, errors)
    local unit1 = attr_api.Funcs.GetAttrUnit(char1)
    assert.is_not_nil(unit1)
    assert.near(1.4, attr_api.Funcs.GetAttr(char1, "PlayerBodyScale"), 1e-9)
    assert.equals(420, attr_api.Funcs.GetAttr(char1, "PlayerMaxHealth"))
    assert.near(8 * 1.3, attr_api.Funcs.GetAttr(char1, "PlayerWalkSpeed"), 1e-9)
    assert.equals(210, attr_api.Funcs.GetAttr(char1, "PlayerHunger"))
    assert.near(GameCfg.Shop.damage_scale("melee", 2), attr_api.Funcs.GetAttr(char1, "PlayerWeaponDamage_melee"), 1e-9)
    assert.near(GameCfg.Shop.damage_scale("ranged", 1), attr_api.Funcs.GetAttr(char1, "PlayerWeaponDamage_ranged"), 1e-9)
    assert.near(GameCfg.Shop.damage_scale("explosive", 3), attr_api.Funcs.GetAttr(char1, "PlayerWeaponDamage_explosive"), 1e-9)

    assert.near(1.4, char1.scale, 1e-9)
    assert.near(BodyScale.derive(1.4).CameraDistance, char1.attrs.CameraDistance, 1e-9)
    assert.near(BodyScale.derive(1.4).InteractRange, char1.attrs.InteractRange, 1e-9)
    assert.is_false(char1.attrs.BodyScaleCapped)
    assert.near(8 * 1.3, char1.Controller.WalkSpeed, 1e-9)

    -- 施加麻痹后移速实时投影归零；药水变化不重复销毁 AttrUnit
    pt:apply_modifier("paralyze")
    assert.equals(0, char1.Controller.WalkSpeed)
    assert.is_nil(unit1.destroyed)

    -- 角色重建为已有外部 AttrUnit 的 char2：销毁本方新建的 unit1，但保留外部 existing_unit
    local char2 = make_unit("Character", world)
    char2.Controller.WalkSpeed = 10
    local external_unit = attr_api.Funcs.EnsureAttrUnit(char2)
    pt.states.character:set(char2)
    assert.is_true(unit1.destroyed)
    assert.equals(external_unit, attr_api.Funcs.GetAttrUnit(char2))
    assert.near(10 * 1.3, char2.Controller.WalkSpeed, 1e-9)

    -- 树销毁：不销毁外部预置的 external_unit
    pt:dispose()
    assert.is_nil(external_unit.destroyed)

    -- 再次验证本方新建的 AttrUnit 在树销毁时被对称销毁
    local char3 = make_unit("Character", world)
    local player3 = { UserId = 9102, Character = char3 }
    local pt3 = PlayerTree.spawn({
      player = player3,
      data = make_ready_data(player3),
      clock = clock,
      mounts = {
        attributes = function(s2, tree)
          PlayerEffects.mount(s2, tree)
          AttrLeaf.mount(s2, tree, { attr_api = attr_api })
        end,
      },
    })
    local owned_unit = attr_api.Funcs.GetAttrUnit(char3)
    assert.is_not_nil(owned_unit)
    pt3:dispose()
    assert.is_true(owned_unit.destroyed)
  end)

  it("校验 GetAttrConfig 拒绝地图 Min/Max 钳制配置并上报错误", function()
    local attr_api, make_unit, world = make_real_attr_sandbox()
    local clamped_api = setmetatable({
      Funcs = setmetatable({
        GetAttrConfig = function(key)
          if key == "PlayerWalkSpeed" then
            return { Min = 0, Max = 10 }
          end
          return nil
        end,
      }, { __index = attr_api.Funcs }),
    }, { __index = attr_api })

    local clock = SpokeClock.new(100)
    local char1 = make_unit("Character", world)
    char1.Controller.WalkSpeed = 7
    local player = { UserId = 9103, Character = char1 }
    local errors = {}

    local pt = PlayerTree.spawn({
      player = player,
      data = make_ready_data(player, { speed_potions = 5 }),
      clock = clock,
      mounts = {
        attributes = function(s2, tree)
          PlayerEffects.mount(s2, tree)
          AttrLeaf.mount(s2, tree, {
            attr_api = clamped_api,
            on_error = function(msg) errors[#errors + 1] = msg end,
          })
        end,
      },
    })

    assert.is_true(#errors >= 1)
    assert.matches("业务属性键不允许地图钳制配置", errors[1], nil, true)
    -- 被拒绝的移速不被改写，其余合法属性（体型/血量）仍正常投影
    assert.equals(7, char1.Controller.WalkSpeed)
    assert.equals(300, attr_api.Funcs.GetAttr(char1, "PlayerMaxHealth"))

    pt:dispose()
  end)
end)

describe("ModifierLeaf：modifier_system 单向叶子投影与活鱼辅助接口", function()
  it("强制传 removeMode=0、叠层刷新与角色重建/到期/树销毁对称 RemoveModifier 零残留", function()
    local mod_api, raw_api, env = make_real_modifier_sandbox()
    local clock = SpokeClock.new(100)
    local char1 = env.unit("char1")
    local died_callbacks = {}
    char1.Died = {
      Connect = function(_, fn)
        died_callbacks[#died_callbacks + 1] = fn
        return { Disconnect = function() end }
      end,
    }
    local player = { UserId = 9201, Character = char1 }
    local presets = {
      poison = "test:poison",
      burn = "test:burn",
      frost = "test:frost",
      paralyze = "test:paralyze",
      weak = "test:weak",
    }

    local pt = PlayerTree.spawn({
      player = player,
      data = make_ready_data(player, { weak_remaining = 20 }),
      clock = clock,
      mounts = {
        attributes = function(s2, tree)
          PlayerEffects.mount(s2, tree, {
            on_mount_modifier_leaf = ModifierLeaf.make_slot_mounter({
              modifier_api = mod_api,
              presets = presets,
            }),
          })
        end,
      },
    })

    -- 初始 weak 已投影到官方包且强制 removeMode = 0
    assert.equals(1, #env.add_calls)
    assert.equals(0, env.add_calls[1].cfg.removeMode)
    assert.equals(1, #raw_api.GetUnitModifiers(char1, presets.weak))

    -- 触发引擎角色死亡信号：因 removeMode=0 不私自清除效果
    for _, fn in ipairs(died_callbacks) do fn() end
    assert.equals(1, #raw_api.GetUnitModifiers(char1, presets.weak))

    -- 施加 poison 两层：同作用域刷新不闪烁，官方包层数达 2，仍强制 removeMode = 0
    local src = { UserId = 9999, Character = env.unit("src") }
    assert.is_true(pt:apply_modifier("poison", { source = src }))
    assert.is_true(pt:apply_modifier("poison", { source = src }))
    assert.equals(0, env.add_calls[#env.add_calls].cfg.removeMode)
    local poison_entity = raw_api.GetUnitModifiers(char1, presets.poison)[1]
    assert.is_not_nil(poison_entity)
    assert.equals(2, poison_entity:GetAttribute("CurrCount"))

    -- 角色空窗：旧角色上全部官方包实体被 on_cleanup 对称 RemoveModifier
    pt.states.character:set(nil)
    assert.equals(0, #raw_api.GetUnitModifiers(char1))

    -- 角色重建：新角色恢复 weak（剩余约 20s），非持久 poison 不恢复
    local char2 = env.unit("char2")
    pt.states.character:set(char2)
    assert.equals(1, #raw_api.GetUnitModifiers(char2, presets.weak))
    assert.equals(0, #raw_api.GetUnitModifiers(char2, presets.poison))

    -- 树销毁：新角色上的 weak 被对称 RemoveModifier，零残留
    pt:dispose()
    assert.equals(0, #raw_api.GetUnitModifiers(char2))
  end)

  it("活鱼/非玩家实体辅助接口遵循 removeMode=0、业务时钟驱动 DoT/到期并在载体死亡或清理时零残留", function()
    local mod_api, raw_api, env = make_real_modifier_sandbox()
    local now = 200
    local dots = {}
    local presets = {
      poison = "test:poison",
      burn = "test:burn",
      frost = "test:frost",
      paralyze = "test:paralyze",
      weak = "test:weak",
    }
    local store = ModifierLeaf.create_entity_store({
      modifier_api = mod_api,
      presets = presets,
      now = function() return now end,
      on_dot_tick = function(target, kind, damage, source, stacks)
        dots[#dots + 1] = { target = target, kind = kind, damage = damage, source = source, stacks = stacks }
      end,
    })

    local receiver = env.unit("fish_receiver")
    local fish = { Id = "fish_1", Carrier = { Receiver = receiver, Dead = false } }
    local attacker = { UserId = 888, Character = env.unit("attacker") }

    assert.is_true(store:apply_weapon_effect(attacker, fish, { Kind = "frost" }))
    assert.is_true(store:apply_weapon_effect(attacker, fish, { Kind = "poison" }))
    assert.is_true(store:apply_weapon_effect(attacker, fish, { Kind = "poison" }))
    assert.equals(0, env.add_calls[#env.add_calls].cfg.removeMode)
    assert.near(0.7, store:get_move_multiplier(fish), 1e-9)
    assert.equals(2, #raw_api.GetUnitModifiers(receiver))

    -- 推进 1 秒产生 2 层毒伤（2 点）
    now = 201
    store:step(now)
    assert.equals(1, #dots)
    assert.equals(2, dots[1].damage)

    -- 施加麻痹后移速归零且 is_controlled = true
    assert.is_true(store:apply(attacker, fish, "paralyze"))
    assert.is_true(store:is_controlled(fish))
    assert.equals(0, store:get_move_multiplier(fish))

    -- 载体死亡后 step 自动清除全部官方包实体
    fish.Carrier.Dead = true
    now = 201.2
    store:step(now)
    assert.equals(0, #raw_api.GetUnitModifiers(receiver))
    assert.is_false(store:is_controlled(fish))
    assert.equals(1, store:get_move_multiplier(fish))
  end)
end)

describe("AbilityLeaf：ability_system 单向叶子投影、can_act 门控与 userdata 兼容", function()
  local saved_vec3

  before_each(function()
    saved_vec3 = rawget(_G, "Vector3")
    _G.Vector3 = { New = function(x, y, z) return { x = x, y = y, z = z } end }
  end)

  after_each(function()
    _G.Vector3 = saved_vec3
    saved_vec3 = nil
  end)

  it("挂载能力管理器并装配 InitialAbilities（含延迟就绪重试）、can_act 拦截施法，角色更换与树销毁对称停止并销毁", function()
    local clock = SpokeClock.new(100)
    local created_managers = {}
    local created_anchors = {}
    local attached_anchors = {}
    local stopped_calls = {}
    local cast_calls = {}
    local add_attempts = 0
    local ready_after = 2

    local function make_ability_api()
      return {
        AddAbility = function(character, asset_id, index)
          add_attempts = add_attempts + 1
          if add_attempts < ready_after then
            return nil
          end
          local script = {
            Character = character,
            AssetId = asset_id,
            Index = index,
            attrs = {},
          }
          function script:SetAttribute(k, v) self.attrs[k] = v end
          function script:GetAttribute(k) return self.attrs[k] end
          return script
        end,
        StopAbility = function(character, index)
          stopped_calls[#stopped_calls + 1] = { character = character, index = index }
          return true
        end,
        CastAbility = function(character, index)
          cast_calls[#cast_calls + 1] = { character = character, index = index }
          return true
        end,
      }
    end

    local function create_asset(preset)
      local obj = {
        Preset = preset,
        attrs = {},
        destroyed = false,
      }
      function obj:SetAttribute(k, v) self.attrs[k] = v end
      function obj:Destroy() self.destroyed = true; self.Parent = nil end
      if preset == GameCfg.Ability.ManagerPreset then
        created_managers[#created_managers + 1] = obj
      else
        created_anchors[#created_anchors + 1] = obj
      end
      return { obj }
    end

    local active_guard = nil
    local char1_backing = { Name = "Char1", GetChildren = function() return {} end }
    local char1 = make_userdata_proxy(char1_backing)
    local player_backing = { UserId = 9301, Character = char1 }
    local player = make_userdata_proxy(player_backing)
    local ability_api = make_ability_api()

    local pt = PlayerTree.spawn({
      player = player,
      data = make_ready_data(player),
      clock = clock,
      mounts = {
        attributes = function(s2, tree)
          PlayerEffects.mount(s2, tree)
        end,
        actions = function(s4, tree)
          AbilityLeaf.mount(s4, tree, {
            ability_api = ability_api,
            create_asset = create_asset,
            attach_anchor = function(anchor, behavior)
              attached_anchors[#attached_anchors + 1] = { anchor = anchor, behavior = behavior }
              return true
            end,
            register_cast_guard = function(guard)
              active_guard = guard
              return function() active_guard = nil end
            end,
            retry_interval = 0.1,
            retry_count = 5,
          })
        end,
      },
    })

    -- 首帧已创建管理器并挂在 char1 下；第 1 次 AddAbility 未就绪，挂起重试
    assert.equals(1, #created_managers)
    assert.equals(char1, created_managers[1].Parent)
    assert.equals(0, #created_anchors)
    assert.is_not_nil(active_guard)

    -- 推进 0.1s 后重试装配成功：写 CdTime/CastTime 并挂载锚点与属性
    clock:advance(0.1)
    assert.equals(1, #created_anchors)
    assert.equals(1, #attached_anchors)
    assert.equals("melee_hit", attached_anchors[1].behavior)
    assert.equals(25.0, created_anchors[1].attrs.ABILITY_ANOSTATE_BULLET_DAMAGE)

    -- can_act 门控：正常可施法，麻痹与濒死时均被拦截
    assert.is_true(active_guard(char1, 0))
    assert.is_true(AbilityLeaf.cast_ability(pt, 0, nil, nil, nil, { ability_api = ability_api }))
    assert.equals(1, #cast_calls)

    pt:apply_modifier("paralyze")
    assert.is_false(active_guard(char1, 0))
    assert.is_false(active_guard(player, 0))
    local cast_ok, cast_err = AbilityLeaf.cast_ability(pt, 0, nil, nil, nil, { ability_api = ability_api })
    assert.is_false(cast_ok)
    assert.equals("cannot-act", cast_err)
    assert.equals(1, #cast_calls)

    -- 麻痹结束恢复可施法
    clock:advance(0.5)
    assert.is_true(active_guard(char1, 0))

    -- 角色更换：旧技能停止、旧管理器销毁，为新角色重新装配
    local char2 = make_userdata_proxy({ Name = "Char2", GetChildren = function() return {} end })
    pt.states.character:set(char2)
    assert.equals(1, #stopped_calls)
    assert.equals(char1, stopped_calls[1].character)
    assert.is_true(created_managers[1].destroyed)
    assert.equals(2, #created_managers)
    assert.equals(char2, created_managers[2].Parent)

    -- 树销毁：停止新角色技能、销毁新管理器、反注册施法守卫
    pt:dispose()
    assert.equals(2, #stopped_calls)
    assert.equals(char2, stopped_calls[2].character)
    assert.is_true(created_managers[2].destroyed)
    assert.is_nil(active_guard)
    assert.is_false(AbilityLeaf.can_act_for(pt))
  end)
end)
