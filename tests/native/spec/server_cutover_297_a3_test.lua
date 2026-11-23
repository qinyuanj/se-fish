-- #297-A3 服务端主入口切换、官方包叶子装配与旧壳淘汰收口契约测试（ADR-0032）：
-- 失败方式先列：
--   1. ServerRuntime 未正确透传并装配 AttrLeaf / ModifierLeaf / AbilityLeaf / HeldRodLeaf / entity_modifiers；
--   2. 玩家角色切换或离场后，CharacterAdded/CharacterRemoving 连接、AttrUnit、Modifier 实体、能力管理器或左手持竿残留；
--   3. 离场玩家对活鱼或其他玩家施加的 DoT 未在离场时清理，导致离线来源继续扣血；
--   4. server/main.lua 未移除旧 MgrAttr / MgrModifier 或未将 MgrPlayerData 同步接线至 PlayerTree。

local GameCfg = require("common.GameCfg")
local ServerRuntime = require("server.World.ServerRuntime")

local function make_signal()
  local handlers = {}
  return {
    handlers = handlers,
    Connect = function(self, fn)
      self.handlers[#self.handlers + 1] = fn
      local active = true
      return {
        Disconnect = function()
          if not active then return end
          active = false
          for i, h in ipairs(self.handlers) do
            if h == fn then
              table.remove(self.handlers, i)
              return
            end
          end
        end,
      }
    end,
    Fire = function(self, ...)
      for _, fn in ipairs({ table.unpack(self.handlers) }) do
        fn(...)
      end
    end,
  }
end

local function find_rod_item_id()
  for id, def in pairs(GameCfg.Items.Definitions) do
    if def.Type == "鱼竿" and def.Visual and def.Visual.Socket then
      return id
    end
  end
  error("GameCfg.Items.Definitions 中未找到带 Visual.Socket 的鱼竿")
end

local function make_ready_data(player, overrides)
  overrides = overrides or {}
  local rod_id = find_rod_item_id()
  return {
    Player = player,
    Inited = true,
    LoadState = "ready",
    Data = {
      FishCoin = overrides.coin or 0,
      Zone = "fishPond",
      UpgradeLevel = 0,
      Containers = {
        itemBar = overrides.item_bar or { [1] = { itemId = rod_id, count = 1 } },
        backpack = {},
      },
      Bait = {},
      Weapons = {},
      SelectedSlot = overrides.selected_slot,
    },
    Extra = {
      inventory = {
        weapons = {},
        selection = { held = {} },
      },
      growth = {
        potions = {
          item168 = overrides.body_potions or 0,
          item167 = overrides.speed_potions or 0,
        },
        upgrades = overrides.upgrades or {},
      },
      survival = {},
      cooldowns = {},
    },
  }
end

local function make_character(name, walk_speed)
  local ch = {
    Name = name,
    attrs = {},
    scale = 1,
    Controller = { WalkSpeed = walk_speed or 7, Health = 300, MaxHealth = 300 },
  }
  function ch:GetAttribute(k) return self.attrs[k] end
  function ch:SetAttribute(k, v) self.attrs[k] = v end
  function ch:SetScale(v) self.scale = v.x end
  function ch:GetChildren() return {} end
  return ch
end

describe("#297-A3 服务端 Spoke 收口：ServerRuntime 叶子装配与活鱼效果存储", function()
  it("统一装配 AttrLeaf / ModifierLeaf / AbilityLeaf / HeldRodLeaf 与 entity_modifiers，离场后全量零残留", function()
    local attr_units, attr_values = {}, {}
    local attr_api = {
      Enums = { AttrComponentType = { Base = 1, BaseExtra = 2, Ratio = 3, Bonus = 4 } },
      Funcs = {
        GetAttrConfig = function() return nil end,
        GetAttrUnit = function(ch) return attr_units[ch] end,
        EnsureAttrUnit = function(ch)
          if not attr_units[ch] then
            local u = { destroyed = false }
            function u:Destroy()
              self.destroyed = true
              if attr_units[ch] == self then attr_units[ch] = nil end
            end
            attr_units[ch] = u
          end
          return attr_units[ch]
        end,
        SetAttrComponent = function(ch, key, comp, val)
          attr_values[ch] = attr_values[ch] or {}
          attr_values[ch][key] = attr_values[ch][key] or { 0, 0, 0, 0 }
          attr_values[ch][key][comp] = val
          return true
        end,
        GetAttr = function(ch, key)
          local c = attr_values[ch] and attr_values[ch][key] or { 0, 0, 0, 0 }
          return (c[1] + c[2]) * (1 + c[3]) + c[4]
        end,
      },
    }

    local active_mods = {}
    local modifier_api = {
      Enums = { CreateResult = { Added = "Added", Reobtained = "Reobtained" } },
      AddModifier = function(owner, preset, cfg)
        assert.equals(0, cfg.removeMode, "叶子投影必须强制 removeMode=0")
        active_mods[owner] = active_mods[owner] or {}
        local ent = active_mods[owner][preset] or { owner = owner, preset = preset, removed = false }
        ent.duration = cfg.duration
        active_mods[owner][preset] = ent
        return "Added"
      end,
      GetUnitModifiers = function(owner, preset)
        local ent = active_mods[owner] and active_mods[owner][preset]
        return ent and { ent } or {}
      end,
      RemoveModifier = function(ent)
        ent.removed = true
        if active_mods[ent.owner] and active_mods[ent.owner][ent.preset] == ent then
          active_mods[ent.owner][ent.preset] = nil
        end
      end,
    }

    local created_managers, stopped_abilities, registered_guards = {}, {}, {}
    local ability_api = {
      AddAbility = function()
        return { SetAttribute = function() end }
      end,
      StopAbility = function(ch, idx)
        stopped_abilities[#stopped_abilities + 1] = { ch = ch, idx = idx }
      end,
    }

    local created_units, dot_hits = {}, {}
    local rt = ServerRuntime.new({
      initial_now = 100,
      create_unit = function(kind, props)
        local u = { Kind = kind, Parent = props.Parent, Destroyed = false }
        function u:Destroy() self.Destroyed = true end
        created_units[#created_units + 1] = u
        return u
      end,
      player_effects = {
        on_dot_tick = function(pt, kind, damage, source)
          dot_hits[#dot_hits + 1] = { target = pt.player, kind = kind, damage = damage, source = source }
        end,
      },
      attr_leaf = { attr_api = attr_api },
      modifier_leaf = {
        modifier_api = modifier_api,
        presets = { poison = "p:poison", burn = "p:burn", frost = "p:frost", paralyze = "p:paralyze", weak = "p:weak" },
      },
      ability_leaf = {
        ability_api = ability_api,
        create_asset = function(preset)
          local m = { preset = preset, destroyed = false }
          function m:Destroy() self.destroyed = true end
          created_managers[#created_managers + 1] = m
          return { m }
        end,
        initial_abilities = { { AssetId = "test:melee", Index = 1, CdSec = 0.5, CastSec = 0.2 } },
        register_cast_guard = function(guard)
          registered_guards[guard] = true
          return function() registered_guards[guard] = nil end
        end,
      },
      entity_modifiers = {
        modifier_api = modifier_api,
        presets = { poison = "p:poison", burn = "p:burn", frost = "p:frost", paralyze = "p:paralyze", weak = "p:weak" },
        on_dot_tick = function(target, kind, damage, source)
          dot_hits[#dot_hits + 1] = { target = target, kind = kind, damage = damage, source = source }
        end,
      },
    })
    rt:start()
    rt:mark_started()

    local ch1 = make_character("Hero1", 8)
    local p1 = { UserId = 9001, Character = ch1, CharacterAdded = make_signal(), CharacterRemoving = make_signal() }
    local d1 = make_ready_data(p1, { body_potions = 2, speed_potions = 5, selected_slot = 1 })

    rt:on_player_added(p1)
    local pt1 = rt:on_save_ready(p1, d1)
    assert.is_not_nil(pt1)
    assert.equals(1, #p1.CharacterAdded.handlers)
    assert.equals(1, #p1.CharacterRemoving.handlers)

    -- AttrLeaf 投影：体型 1.4、血量上限 420、移速 8 * 1.5 = 12
    assert.near(1.4, ch1.scale, 1e-9)
    assert.near(12, ch1.Controller.WalkSpeed, 1e-9)
    assert.is_not_nil(attr_units[ch1])

    -- HeldRodLeaf 投影：选中鱼竿格创建挂点 + 模型
    assert.equals(2, #created_units)
    assert.is_false(created_units[1].Destroyed)
    assert.is_false(created_units[2].Destroyed)

    -- AbilityLeaf 投影：挂载管理器并注册 can_act 施法守卫
    assert.equals(1, #created_managers)
    local guard_fn = next(registered_guards)
    assert.is_not_nil(guard_fn)
    assert.is_true(guard_fn(ch1))

    -- ModifierLeaf 投影：施加麻痹阻塞施法与移速，0.5s 后恢复
    assert.is_true(pt1:apply_modifier("paralyze"))
    assert.is_false(guard_fn(ch1))
    assert.equals(0, ch1.Controller.WalkSpeed)
    rt:step(0.5, 100.5)
    assert.is_true(guard_fn(ch1))
    assert.near(12, ch1.Controller.WalkSpeed, 1e-9)

    -- 活鱼 entity_modifiers：挂毒跳伤 + 玩家离场自动清源
    local fish_body = make_character("FishBody", 5)
    local fish = { Id = 77, Carrier = { Receiver = fish_body, Dead = false } }
    local em = rt:get_entity_modifiers()
    assert.is_true(em:apply(p1, fish, "poison"))
    rt:step(1.0, 101.5)
    assert.equals(1, #dot_hits)
    assert.are.equal(fish, dot_hits[1].target)

    -- 玩家离场：三步协议拆除全部资源、连接、能力守卫，并清理其对活鱼施加的毒
    rt:on_player_removing(p1)
    assert.is_nil(rt:get_player_tree(9001))
    assert.equals(0, #p1.CharacterAdded.handlers)
    assert.equals(0, #p1.CharacterRemoving.handlers)
    assert.is_true(created_units[1].Destroyed)
    assert.is_true(created_units[2].Destroyed)
    assert.is_true(created_managers[1].destroyed)
    assert.equals(1, #stopped_abilities)
    assert.is_nil(next(registered_guards))
    assert.is_nil(attr_units[ch1])
    assert.equals(0, em:get_remaining(fish, "poison"))

    -- 离场后继续推进时间不再产生 DoT
    rt:step(2.0, 103.5)
    assert.equals(1, #dot_hits)

    rt:shutdown()
  end)

  it("server/main.lua 已彻底淘汰 MgrAttr 与 MgrModifier 并接通 Spoke 桥接与同步回调", function()
    local handle = assert(io.open("server/main.lua", "rb"))
    local src = handle:read("*a")
    handle:close()
    assert.is_nil(src:find("server.Mgr.MgrAttr", 1, true))
    assert.is_nil(src:find("server.Mgr.MgrModifier", 1, true))
    assert.is_truthy(src:find("AttrLeaf", 1, true))
    assert.is_truthy(src:find("MgrMap.MgrPlayerData.OnSyncPlayerTree", 1, true))
    assert.is_truthy(src:find("entity_modifiers", 1, true))
  end)
end)
