-- #297-A3 服务端主入口切换、官方包叶子装配与旧壳淘汰收口契约测试（ADR-0032）：
-- 失败方式先列：
--   1. ServerRuntime 未正确透传并装配 AttrLeaf / ModifierLeaf / AbilityLeaf / HeldRodLeaf / entity_modifiers；
--   2. 玩家角色切换或离场后，CharacterAdded/CharacterRemoving 连接、AttrUnit、Modifier 实体、能力管理器或左手持竿残留；
--   3. 离场玩家对活鱼或其他玩家施加的 DoT 未在离场时清理，导致离线来源继续扣血；
--   4. server/main.lua 未移除旧 MgrAttr / MgrModifier 或未将 MgrPlayerData 同步接线至 PlayerTree。

local GameCfg = require("common.game_cfg")
local SpokeRuntime = require("common.packages.spoke.runtime.spoke_runtime")
local ServerRuntime = require("server.world_host.server_runtime")

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
    inited = true,
    load_state = "ready",
    Data = {
      FishCoin = overrides.coin or 0,
      Zone = "fishPond",
      upgrade_level = 0,
      containers = {
        itemBar = overrides.item_bar or { [1] = { itemId = rod_id, count = 1 } },
        backpack = {},
      },
      Bait = {},
      weapons = {},
      selected_slot = overrides.selected_slot,
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
  local saved_vec3, saved_color

  before_each(function()
    saved_vec3 = rawget(_G, "Vector3")
    saved_color = rawget(_G, "Color")
    _G.Vector3 = { New = function(x, y, z) return { x = x, y = y, z = z } end }
    _G.Color = { New = function(...) return { ... } end }
  end)

  after_each(function()
    _G.Vector3 = saved_vec3
    _G.Color = saved_color
    saved_vec3, saved_color = nil, nil
  end)

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
      bait_spots = { Enabled = false },
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
    local fish = { Id = 77, carrier = { receiver = fish_body, dead = false } }
    local em = rt:get_entity_modifiers()
    assert.is_true(em:apply(p1, fish, "poison"))
    rt:step(1.0, 101.5)
    assert.equals(1, #dot_hits)
    assert.are.equal(fish, dot_hits[1].target)

    -- sync_from_data(d1) 不得触发反向 mirror_stage1_to_data 覆写替换 d1 内部子表引用
    local ref_item_bar = d1.Data.containers.itemBar
    local ref_bait = d1.Data.Bait
    local ref_weapons = d1.Data.weapons
    local ref_held = d1.Extra.inventory.selection.held
    local ref_potions = d1.Extra.growth.potions
    local ref_upgrades = d1.Extra.growth.upgrades
    local ref_cooldowns = d1.Extra.cooldowns
    d1.Data.FishCoin = 321
    d1.Extra.growth.potions.item168 = 3
    assert.is_true(pt1:sync_from_data(d1))
    assert.equals(321, pt1.states.coin:now())
    assert.equals(480, pt1.memos.max_health:now())
    assert.are.equal(ref_item_bar, d1.Data.containers.itemBar)
    assert.are.equal(ref_bait, d1.Data.Bait)
    assert.are.equal(ref_weapons, d1.Data.weapons)
    assert.are.equal(ref_held, d1.Extra.inventory.selection.held)
    assert.are.equal(ref_potions, d1.Extra.growth.potions)
    assert.are.equal(ref_upgrades, d1.Extra.growth.upgrades)
    assert.are.equal(ref_cooldowns, d1.Extra.cooldowns)

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

  describe("真实加载 server/main.lua 端到端接线验证", function()
    local saved
    local runtime

    before_each(function()
      saved = {
        game = rawget(_G, "game"),
        REUtil = rawget(_G, "REUtil"),
        reutil = package.loaded["common.re_util"],
        MgrUtil = rawget(_G, "MgrUtil"),
        Vector3 = rawget(_G, "Vector3"),
        Color = rawget(_G, "Color"),
        RemoteEvent = rawget(_G, "RemoteEvent"),
        Debug = GameCfg.Debug,
        slot = GameCfg.Save.QaSlot,
      }
      GameCfg.Debug = { Enabled = true, InitialGrants = saved.Debug.InitialGrants }
      GameCfg.Save.QaSlot = ""
      runtime = nil
    end)

    after_each(function()
      if runtime and runtime.shutdown then
        runtime:shutdown()
      end
      _G.game = saved.game
      _G.REUtil = saved.REUtil
      package.loaded["common.re_util"] = saved.reutil
      _G.MgrUtil = saved.MgrUtil
      _G.Vector3 = saved.Vector3
      _G.Color = saved.Color
      _G.RemoteEvent = saved.RemoteEvent
      GameCfg.Debug = saved.Debug
      GameCfg.Save.QaSlot = saved.slot
      saved = nil
      runtime = nil
    end)

    it("真实运行 server/main.lua：ServerRuntime.current 就绪、PlayerDataHost 驱动持竿、AttrBridge/ModifierBridge 含麻痹与活鱼 DoT 端到端生效", function()
      local now = 200
      local tasks, values, created_units, errors, mgrs = {}, {}, {}, {}, {}
      local players_list = {}
      local players_service = {
        PlayerAdded = make_signal(),
        PlayerRemoving = make_signal(),
        GetPlayers = function() return players_list end,
        GetPlayerFromCharacter = function(_, unit)
          for _, p in ipairs(players_list) do
            if p.Character == unit then return p end
          end
          return nil
        end,
      }
      local heartbeat = make_signal()
      local store = {
        GetAsync = function(_, key) return values[key] end,
        UpdateAsync = function(_, key, transform)
          local value = transform(values[key])
          if value then values[key] = value end
          return value
        end,
      }

      _G.RemoteEvent = { New = function()
        return { OnServerEvent = make_signal(), OnClientEvent = make_signal(),
          FireServer = function() end, FireClient = function() end, FireAllClients = function() end }
      end }
      _G.Vector3 = { New = function(x, y, z) return { x = x, y = y, z = z } end }
      _G.Color = { New = function(...) return { ... } end }
      _G.game = {
        BindToClose = function() end,
        GetService = function(_, name)
          if name == "Task" then
            return {
              Spawn = function(_, fn) tasks[#tasks + 1] = fn end,
              Wait = function() end,
            }
          end
          if name == "Players" then return players_service end
          if name == "RunService" then return { Heartbeat = heartbeat, IsServer = function() return true end, IsClient = function() return false end } end
          if name == "World" then
            return {
              GetServerTime = function() return now end,
              CreateUnit = function(_, kind, props)
                local u = { Kind = kind, Parent = props.Parent, Destroyed = false }
                function u:Destroy() self.Destroyed = true end
                created_units[#created_units + 1] = u
                return u
              end,
              CreateAsset = function(_, preset)
                local u = { Preset = preset, Destroyed = false, attrs = {} }
                function u:Destroy() self.Destroyed = true end
                function u:SetAttribute(k, v) self.attrs[k] = v end
                function u:GetAttribute(k) return self.attrs[k] end
                function u:FindFirstChild() return nil end
                return { u }
              end,
            }
          end
          if name == "DataStoreService" then return { GetDataStore = function() return store end } end
          return {}
        end,
      }
      local re_map = {}
      local item_bar_pushes = {}
      local remote_util = {
        check_recd = function() return false end,
        get_re = function(_, name)
          if not re_map[name] then
            re_map[name] = {
              OnServerEvent = make_signal(),
              FireClient = function(_, target_player, payload)
                if name == "ItemBarState" then
                  item_bar_pushes[#item_bar_pushes + 1] = { player = target_player, payload = payload }
                end
              end,
            }
          end
          return re_map[name]
        end,
      }

      local attr_units, attr_values = {}, {}
      local attr_api_stub = {
        Enums = { AttrComponentType = { Base = 1, BaseExtra = 2, Ratio = 3, Bonus = 4 } },
        Funcs = {
          GetAttrConfig = function() return nil end,
          GetAttrUnit = function(ch) return attr_units[ch] end,
          EnsureAttrUnit = function(ch)
            if not attr_units[ch] then
              local u = { destroyed = false }
              function u:Destroy() self.destroyed = true; attr_units[ch] = nil end
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
      local modifier_api_stub = {
        Enums = { CreateResult = { Added = "Added", Reobtained = "Reobtained" } },
        AddModifier = function(owner, preset, cfg)
          assert.equals(0, cfg.removeMode)
          active_mods[owner] = active_mods[owner] or {}
          local ent = active_mods[owner][preset] or { owner = owner, preset = preset }
          active_mods[owner][preset] = ent
          return "Added"
        end,
        GetUnitModifiers = function(owner, preset)
          local ent = active_mods[owner] and active_mods[owner][preset]
          return ent and { ent } or {}
        end,
        RemoveModifier = function(ent)
          if active_mods[ent.owner] and active_mods[ent.owner][ent.preset] == ent then
            active_mods[ent.owner][ent.preset] = nil
          end
        end,
      }
      local ability_api_stub = {
        AddAbility = function() return { SetAttribute = function() end } end,
        StopAbility = function() end,
        CastAbility = function() return true end,
      }

      local sandbox
      sandbox = setmetatable({
        RemoteEvent = { New = function()
          return { OnServerEvent = make_signal(), OnClientEvent = make_signal(),
            FireServer = function() end, FireClient = function() end, FireAllClients = function() end }
        end },
        print = function(...)
          local parts = { ... }
          if parts[1] == "[server.main]" then
            errors[#errors + 1] = parts
          end
        end,
        require = function(path)
          if path == "common.re_util" then return remote_util end
          if path == "server.MgrUtil" then return { Start = function() end } end
          if path == "common.zone_markers" then return { start = function() end } end
          if path == "server.packages.attr_rule.api" then return attr_api_stub end
          if path == "server.packages.modifier_system.api" then return modifier_api_stub end
          if path == "server.packages.ability_system.api" then return ability_api_stub end
          if path == "server.ability_api" then
            if not mgrs._AbilityAPI then
              mgrs._AbilityAPI = assert(loadfile("server/ability_api.lua", "t", sandbox))()
            end
            return mgrs._AbilityAPI
          end
          if path == "server.save_host" or path == "server.player_data_host" or path == "server.fish_ability" then
            local name = path:match("([%w_]+)$")
            if not mgrs[name] then mgrs[name] = assert(loadfile(path:gsub("%.", "/") .. ".lua", "t", sandbox))() end
            return mgrs[name]
          end
          if path == "server.platform_host" then return {} end
          return require(path)
        end,
      }, { __index = _G })


      _G.REUtil = remote_util
      package.loaded["common.re_util"] = remote_util
      runtime = assert(loadfile("server/main.lua", "t", sandbox))()
      assert.are.equal(runtime, ServerRuntime.current())
      assert.is_not_nil(runtime:get_entity_modifiers())

      local function drain()
        local steps = 0
        while #tasks > 0 do
          steps = steps + 1
          assert(steps < 100, "异步任务未收敛")
          table.remove(tasks, 1)()
        end
        assert.same({}, errors)
      end

      local c = { Health = 300, MaxHealth = 300, WalkSpeed = 7, HealthChanged = make_signal(), Died = make_signal(), OnReborn = make_signal() }
      local ch = { Name = "MainHero", attrs = {}, scale = 1, Controller = c }
      function ch:GetAttribute(k) return self.attrs[k] end
      function ch:SetAttribute(k, v) self.attrs[k] = v end
      function ch:SetScale(v) self.scale = v.x end
      function ch:GetChildren() return {} end
      local p = { UserId = 9101, attrs = {}, Character = ch, CharacterAdded = make_signal(), CharacterRemoving = make_signal() }
      function p:SetAttribute(k, v) self.attrs[k] = v end
      players_list[1] = p

      players_service.PlayerAdded:Fire(p)
      drain()

      local pt = runtime:get_player_tree(9101)
      assert.is_not_nil(pt)
      assert.is_true(#p.CharacterAdded.handlers >= 1)
      -- 存档就绪首推经 PlayerTree 树底 on_item_bar_state 严格下发 1 次（无双发）
      assert.equals(1, #item_bar_pushes)
      assert.are.equal(p, item_bar_pushes[1].player)
      local bait_unit_count = #created_units
      assert.equals(#GameCfg.BaitSpots.Spots, bait_unit_count)
      assert.equals(1, #re_map.ItemBarAction.OnServerEvent.handlers)
      assert.is_function(runtime.platform.shop_action)

      re_map.ItemBarAction.OnServerEvent:Fire(p, { action = "SelectSlot", value = 1 })
      assert.equals(2, #item_bar_pushes)
      assert.equals(1, item_bar_pushes[2].payload.selectedSlot)
      assert.equals(bait_unit_count + 2, #created_units)
      local rod_mount = created_units[bait_unit_count + 1]
      local rod_model = created_units[bait_unit_count + 2]
      assert.is_false(rod_mount.Destroyed)
      assert.is_false(rod_model.Destroyed)

      -- RequestItemBar 主动拉取经 PlayerTree 强制推送 1 次
      re_map.RequestItemBar.OnServerEvent:Fire(p)
      assert.equals(3, #item_bar_pushes)
      assert.equals(1, item_bar_pushes[3].payload.selectedSlot)

      local before_batch_pushes = #item_bar_pushes
      local data = mgrs.player_data_host:get_data_inst(p)
      SpokeRuntime.batch(function()
        pt:set_coin(888)
        pt:set_upgrade_level(1)
        data.Data.FishCoin = 888
        data.Data.upgrade_level = 1
        data.Data.selected_slot = nil
        mgrs.player_data_host:sync_player_tree(p)
        data.Data.FishCoin = 999
        mgrs.player_data_host:sync_player_tree(p)
      end)
      assert.equals(before_batch_pushes + 1, #item_bar_pushes)
      assert.equals(999, item_bar_pushes[#item_bar_pushes].payload.coin)
      assert.equals(1, item_bar_pushes[#item_bar_pushes].payload.upgradeLevel)
      assert.is_nil(item_bar_pushes[#item_bar_pushes].payload.selectedSlot)
      -- 重新选回鱼竿格以维持后续测试预期
      re_map.ItemBarAction.OnServerEvent:Fire(p, { action = "SelectSlot", value = 1 })

      data.Extra.growth.potions.item168 = 2
      data.Extra.growth.potions.item167 = 5
      assert.is_true(mgrs.fish_ability:apply_growth(p).Ok)
      assert.equals(420, runtime.life:max_health_of(p))
      assert.near(1.4, ch.scale, 1e-9)
      assert.near(10.5, c.WalkSpeed, 1e-9)

      assert.is_true(mgrs.fish_ability.Modifier:apply_weapon_effect(p, ch, { Kind = "paralyze" }))
      assert.is_false(runtime.life:can_act(p))
      assert.equals(0, c.WalkSpeed)
      now = now + 0.5
      heartbeat:Fire(0.5)
      assert.is_true(runtime.life:can_act(p))
      assert.near(10.5, c.WalkSpeed, 1e-9)

      -- ModifierBridge：活鱼挂毒经 Heartbeat 推进触发 MgrVitals:apply_hit DoT
      local dot_hits = {}
      local orig_apply_hit = runtime.life.apply_hit
      runtime.life.apply_hit = function(self, hit, target, amount)
        dot_hits[#dot_hits + 1] = { target = target, amount = amount, category = hit.category }
        return true
      end
      local fish_body = make_character("MainFish", 5)
      local fish = { Id = 88, carrier = { receiver = fish_body, dead = false } }
      assert.is_true(runtime:get_entity_modifiers():apply_weapon_effect(p, fish, { Kind = "poison" }))
      now = now + 1.0
      heartbeat:Fire(1.0)
      assert.equals(1, #dot_hits)
      assert.are.equal(fish, dot_hits[1].target)
      assert.equals("dot", dot_hits[1].category)
      runtime.life.apply_hit = orig_apply_hit

      -- 离场后：连接断开、左手持竿销毁、活鱼毒效果按来源清理
      players_service.PlayerRemoving:Fire(p)
      drain()
      assert.is_nil(runtime:get_player_tree(9101))
      assert.equals(0, #p.CharacterAdded.handlers)
      assert.is_true(rod_mount.Destroyed)
      assert.is_true(rod_model.Destroyed)
      assert.equals(0, mgrs.fish_ability.Modifier:get_remaining(fish, "poison"))
    end)
  end)
end)
