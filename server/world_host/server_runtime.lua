-- 服务端 Spoke 运行时总控与离场三步协议编排器（ADR-0032 §1、§2、§4 / #295）：
-- 负责：
--   1. 持有唯一 SpokeClock，接受宿主帧泵（step）驱动；
--   2. 拉起全局唯一 SharedWorldTree（7 个钓鱼区子域骨架 + 全局小队 Dock）；
--   3. 仅在存档加载就绪且服务启动后为在场玩家生成独立 Auto PlayerTree；
--   4. 编排离场三步协议：前置异步脏写 → Step 1 (session_alive=false 终镜像)
--      → Step 2 (同步 dispose 逆序拆资源与信号) → Step 3 (宿主持久化序列化 + 异步排空栅栏)；
--   5. 维护同账号重进排空栅栏（leaving.waiting），防止提前读旧档或覆盖正在落盘的数据。
-- 本模块归属 L2（server.world_host），零反向依赖存量旧债务模块；过渡接缝全部由 L1 入口以回调注入。

local GameCfg = require("common.game_cfg")
local Number = require("common.number")
local SpokeClock = require("common.spoke_clock")
local SharedWorldTree = require("server.world_host.shared_world_tree")
local PlayerTree = require("server.world_host.player_tree")
local AttrLeaf = require("server.world_host.attr_leaf")
local ModifierLeaf = require("server.world_host.modifier_leaf")
local AbilityLeaf = require("server.world_host.ability_leaf")
local PlayerWeapon = require("server.world_host.player_weapon")
local PlayerGrill = require("server.world_host.player_grill")
local PlayerShop = require("server.world_host.player_shop")
local PlayerFisherman = require("server.world_host.player_fisherman")
local PlayerLottery = require("server.world_host.player_lottery")
local PlayerBlindbox = require("server.world_host.player_blindbox")
local PlayerPlatformShop = require("server.world_host.player_platform_shop")
local SwingRegistry = require("server.swing_registry")
local PkDamageFilter = require("server.world_host.pk_damage_filter")
local FishTree = require("server.world_host.fish_tree")
local FishAiTarget = require("server.world_host.fish_ai_target")
local WorldRecords = require("server.world_host.world_records")
local PlayerGM = require("server.world_host.player_gm")
local LifeFacade = require("server.world_host.life_facade")

local ServerRuntime = {}
local current_runtime = nil

function ServerRuntime.current()
  return current_runtime
end

function ServerRuntime.set_current(rt)
  current_runtime = rt
end

local function is_object(value)
  local kind = type(value)
  return kind == "table" or kind == "userdata"
end

local function is_valid_player(player)
  if not is_object(player) then return false end
  local ok, uid = pcall(function() return player.UserId end) -- 兼容引擎 userdata 玩家
  return ok and uid ~= nil
end

local function read_character(player)
  if not is_object(player) then return nil end
  local ok, ch = pcall(function() return player.Character end) -- 兼容引擎 userdata 玩家
  return ok and ch or nil
end

local function has_method(target, name)
  return type(target) == "table" and type(target[name]) == "function"
end

local function safe_call(logger, label, fn, ...)
  if type(fn) ~= "function" then
    return nil
  end
  local ok, r1, r2 = pcall(fn, ...)
  if not ok then
    if logger and type(logger.error) == "function" then
      pcall(logger.error, logger, label .. ": " .. tostring(r1)) -- logger 异常不得中断业务回调调度
    else
      print("[ServerRuntime]", label, tostring(r1))
    end
    return nil
  end
  return r1, r2
end

local function is_ready_data(player, data)
  return type(data) == "table"
      and data.Player == player
      and data.Inited == true
      and data.LoadState == "ready"
end

---@param opts? table
function ServerRuntime.new(opts)
  opts = type(opts) == "table" and opts or {}
  local player_data = opts.player_data
  local save = opts.save
  local platform = opts.platform
  opts.player_data = player_data
  opts.save = save
  opts.platform = platform

  local initial_now = Number.is_finite_number(opts.initial_now) and opts.initial_now or 0
  local clock = opts.clock or SpokeClock.new(initial_now)
  local current_players = {}
  local active_players = {}
  local player_trees = {}
  local fish_dirty = false
  local last_fish_signature = ""
  local re_conns = {}
  local carrier_died_handler = nil
  local bound_shop_action = nil
  local fish_host = FishTree.new()
  fish_host.Clock = clock
  fish_host.AiProjection = opts.ai
  fish_host.Logger = opts.logger
  fish_host.get_player_tree = function(_, player)
    return is_valid_player(player) and player_trees[player.UserId] or nil
  end
  fish_host.on_state_changed = function()
    fish_dirty = true
  end
  fish_host.CreateUnit = opts.create_unit
  fish_host.World = opts.world_service
  fish_host.cast = opts.cast
  fish_host.Ai = opts.fish_ai
  fish_host.AiTarget = opts.fish_ai_target or FishAiTarget
  fish_host.AbilityApi = opts.ability_api
  fish_host.Ability = opts.fish_ability
  fish_host.now = function() return clock.now() end
  fish_host.Players = function()
    local list = {}
    for _, active in pairs(active_players) do list[#list + 1] = active end
    return list
  end
  local leaving_players = {}
  local ready_queue = {}

  local weapon_sessions = {}
  local grill_handles = {}
  local shop_handles = {}
  local fisherman_handles = {}
  local lottery_sessions = {}
  local blindbox_sessions = {}
  local platform_shop_sessions = {}
  local entity_modifiers = nil
  if opts.entity_modifiers then
    local em_opts = type(opts.entity_modifiers) == "table" and opts.entity_modifiers or {}
    entity_modifiers = ModifierLeaf.create_entity_store({
      modifier_api = em_opts.modifier_api,
      presets = em_opts.presets,
      now = function()
        return clock.now()
      end,
      on_dot_tick = em_opts.on_dot_tick,
      on_error = em_opts.on_error,
    })
  end

  local runtime = {
    clock = clock,
    world = nil,
    entity_modifiers = entity_modifiers,
    platform = opts.platform,
    fish_host = fish_host,
    _started = false,
  }
  if not opts.cast then
    fish_host.cast = {
      PushState = function(_, player) return runtime:push_cast_state(player) end,
      abort = function(_, player) return runtime:abort_cast(player) end,
      SetNextFish = function(_, player, fish_id) return runtime:set_next_fish(player, fish_id) end,
    }
  end

  local function player_tree_of(target)
    if not is_object(target) then return nil end
    local ok_uid, uid = pcall(function() return target.UserId end) -- 兼容引擎 userdata 玩家或角色
    if ok_uid and uid ~= nil then
      local tree = player_trees[uid]
      if tree and not tree:is_disposed() then return tree end
    end
    for _, tree in pairs(player_trees) do
      if tree and not tree:is_disposed() then
        local owner = tree.player
        if owner == target or read_character(owner) == target then
          return tree
        end
      end
    end
    return nil
  end

  local function entity_target(target)
    if not target then return nil end
    local ok_carrier, carrier = pcall(function() return target.Carrier end)
    if ok_carrier and carrier then return target end
    local carrier_host = opts.fish_carrier
    local resolved = carrier_host and carrier_host.resolve_carrier and carrier_host:resolve_carrier(target)
    return resolved or target
  end

  local modifier_service = {}
  function modifier_service:Apply(source, target, kind, seconds)
    local tree = player_tree_of(target)
    if tree then return tree:apply_modifier(kind, { duration = seconds, source = source }) end
    if entity_modifiers then return entity_modifiers:apply(source, entity_target(target), kind, seconds) end
    return false, "no-effect-owner"
  end
  function modifier_service:apply_weapon_effect(source, target, effect)
    return self:Apply(source, target, type(effect) == "table" and effect.Kind or nil)
  end
  function modifier_service:get_remaining(target, kind)
    local tree = player_tree_of(target)
    if tree then return tree:get_modifier_remaining(kind) end
    if entity_modifiers then return entity_modifiers:get_remaining(entity_target(target), kind) end
    return 0
  end
  function modifier_service:is_controlled(target)
    local tree = player_tree_of(target)
    if tree then return tree.states.is_paralyzed:now() == true end
    if entity_modifiers then return entity_modifiers:is_controlled(entity_target(target)) end
    return false
  end
  function modifier_service:get_move_multiplier(target)
    local tree = player_tree_of(target)
    if tree then return tree.memos.move_multiplier:now() end
    if entity_modifiers then return entity_modifiers:get_move_multiplier(entity_target(target)) end
    return 1
  end
  function modifier_service:Clear(target, kind)
    local tree = player_tree_of(target)
    if tree then return tree:clear_modifier(kind) end
    if entity_modifiers then return entity_modifiers:clear(entity_target(target), kind) end
    return false
  end
  function modifier_service:clear_target(target, keepWeak)
    local tree = player_tree_of(target)
    if tree then tree:clear_all_modifiers(keepWeak) return end
    if entity_modifiers then entity_modifiers:clear_target(entity_target(target)) end
  end
  function modifier_service:update()
    if entity_modifiers then entity_modifiers:step(clock.now()) end
  end

  fish_host.Quest = {
    notify = function(_, kind, owner, fact) return runtime:notify_quest(kind, owner, fact) end,
  }
  PlayerGM.configure({
    player_data = opts.player_data,
    save = opts.save,
    cast = { SetNextFish = function(_, target, fishId) return runtime:set_next_fish(target, fishId) end },
    vitals = {
      set_health = function(_, target, value) return runtime.life:set_health(target, value) end,
      set_hunger = function(_, target, value) return runtime.life:set_hunger(target, value) end,
    },
  })

  fish_host.on_killed = function(killed)
    local world = runtime.world
    if world and type(world.on_carrier_killed) == "function" then
      world:on_carrier_killed(killed)
    end
  end

  function runtime:start()
    if self.world and not self.world:is_disposed() then
      return self.world
    end
    self.world = SharedWorldTree.spawn({
      clock = clock,
      zones = opts.zones,
      logger = opts.logger,
      on_mount_zone = opts.on_mount_zone,
      on_mount_world = function(scope, world)
        if _G.REUtil then
          WorldRecords.mount(scope, world, { player_data = opts.player_data })
        end
        if type(opts.on_mount_world) == "function" then opts.on_mount_world(scope, world) end
      end,
      create_unit = opts.create_unit,
      remote = opts.remote,
      bait_spots = opts.bait_spots,
      player_data = opts.player_data,
      save = opts.save,
      interact = opts.interact,
      players_service = opts.players_service,
      session_epoch = opts.session_epoch or opts.delivery_epoch,
      lookup_tree = function(player)
        if not is_valid_player(player) then return nil end
        return player_trees[player.UserId]
      end,
    })
    local function connect_re(channel, handler)
      local remote = opts.remote
      if type(remote) ~= "table" or type(remote.get_re) ~= "function" then return end
      local ok, event = pcall(remote.get_re, remote, channel)
      if ok and event and event.OnServerEvent and type(event.OnServerEvent.Connect) == "function" then
        local conn = event.OnServerEvent:Connect(handler)
        if conn then re_conns[#re_conns + 1] = conn end
      end
    end
    if not self._ferry_bound then
      self._ferry_bound = true
      if type(opts.bind_ferry_action) == "function" then
        opts.bind_ferry_action(function(actor, payload)
          local ferry = self.world and self.world.ferry
          return ferry and ferry:Handle(actor, payload) or false
        end)
      end
    end
    if not self._party_bound then
      self._party_bound = true
      if type(opts.bind_party_action) == "function" then
        opts.bind_party_action(function(actor, payload)
          if self:is_leaving(actor and actor.UserId) then return false end
          local squad = self.world and self.world.squad
          return squad and squad:Handle(actor, payload) or false
        end)
      end
      if type(opts.bind_party_state_request) == "function" then
        opts.bind_party_state_request(function(actor)
          local squad = self.world and self.world.squad
          if squad and squad.online[actor and actor.UserId] == actor then squad:push(actor) end
        end)
      end
    end
    if not self._core_re_bound then
      self._core_re_bound = true
      local function on_survival(actor, payload, skip_cd)
        if not is_valid_player(actor) or self:is_leaving(actor.UserId) then return false end
        local tree = player_trees[actor.UserId]
        if tree and type(tree.handle_survival_action) == "function" then
          return tree:handle_survival_action(payload, skip_cd)
        end
        return false
      end
      if type(opts.bind_survival_action) == "function" then
        opts.bind_survival_action(function(actor, payload) return on_survival(actor, payload, true) end)
      else
        connect_re("SurvivalAction", function(actor, payload) on_survival(actor, payload, false) end)
      end

      local function on_special_action(actor, payload)
        if not is_valid_player(actor) or self:is_leaving(actor.UserId) then return false end
        local tree = player_trees[actor.UserId]
        if tree and type(tree.handle_special_item_action) == "function" then
          return tree:handle_special_item_action(payload)
        end
        return false
      end
      local function on_special_query(actor)
        if not is_valid_player(actor) or self:is_leaving(actor.UserId) then return false end
        local tree = player_trees[actor.UserId]
        if tree and type(tree.handle_special_item_query) == "function" then
          return tree:handle_special_item_query()
        end
        return false
      end
      if type(opts.bind_special_item_action) == "function" then
        opts.bind_special_item_action(on_special_action, on_special_query)
      else
        connect_re("SpecialItemAction", on_special_action)
        connect_re("SpecialItemStateRequest", on_special_query)
      end

      local function on_loot_request(actor, skip_cd)
        if not is_valid_player(actor) or self:is_leaving(actor.UserId) then return false end
        local world = self.world
        if world and type(world.handle_loot_request) == "function" then
          return world:handle_loot_request(actor, skip_cd)
        end
        return false
      end
      if type(opts.bind_loot_request) == "function" then
        opts.bind_loot_request(function(actor) return on_loot_request(actor, true) end)
      else
        connect_re("RequestLoot", function(actor) on_loot_request(actor, false) end)
      end

      local function on_item_bar_action(actor, payload, skip_cd)
        if not is_valid_player(actor) or self:is_leaving(actor.UserId) then return false end
        local world = self.world
        if world and type(world.handle_item_bar_action) == "function" then
          return world:handle_item_bar_action(actor, payload, skip_cd)
        end
        return false
      end
      if type(opts.bind_item_bar_action) == "function" then
        opts.bind_item_bar_action(function(actor, payload) return on_item_bar_action(actor, payload, true) end)
      elseif opts.bind_item_bar_action ~= false and not has_method(player_data, "Start") then
        connect_re("ItemBarAction", function(actor, payload) on_item_bar_action(actor, payload, false) end)
      end
    end
    if not carrier_died_handler and has_method(opts.fish_carrier, "subscribe_died") then
      carrier_died_handler = function(carrier)
        fish_host:on_carrier_died(carrier)
      end
      opts.fish_carrier:subscribe_died(carrier_died_handler)
    end
    if has_method(player_data, "Start") then safe_call(opts.logger, "player_data_start", function() player_data:Start() end) end
    if has_method(save, "Start") then safe_call(opts.logger, "save_start", function() save:Start() end) end
    if has_method(platform, "Start") then safe_call(opts.logger, "platform_start", function() platform:Start() end) end
    if has_method(opts.fish_ability, "Start") then
      safe_call(opts.logger, "fish_ability_start", function() opts.fish_ability:Start() end)
    end
    return self.world
  end

  function runtime:mark_started()
    self:start()
    self._started = true
    local queued = {}
    for user_id, entry in pairs(ready_queue) do
      queued[#queued + 1] = { user_id = user_id, entry = entry }
    end
    table.sort(queued, function(a, b)
      return tostring(a.user_id) < tostring(b.user_id)
    end)
    for _, item in ipairs(queued) do
      ready_queue[item.user_id] = nil
      self:on_save_ready(item.entry[1], item.entry[2])
    end
  end

  function runtime:get_world()
    return self.world
  end

  function runtime:get_player_tree(user_id)
    return player_trees[user_id]
  end

  function runtime:record_landing(player, event)
    if self:is_leaving(player and player.UserId) then return false, "leaving" end
    local tree = player and player_trees[player.UserId]
    local compendium = tree and tree.compendium
    if not compendium then return false, "unavailable" end
    return compendium:record_landing(player, event)
  end

  function runtime:notify_quest(kind, player, payload)
    if self:is_leaving(player and player.UserId) then return false end
    local tree = player and player_trees[player.UserId]
    local quest = tree and tree.quest
    return quest and quest:notify(kind, player, payload) or false
  end

  function runtime:push_cast_state(player)
    local tree = player and player_trees[player.UserId]
    if tree and tree.fishing and type(tree.fishing.push_state) == "function" then
      tree.fishing.push_state()
      return true
    end
    return false
  end

  function runtime:abort_cast(player)
    local tree = player and player_trees[player.UserId]
    if tree and tree.fishing and type(tree.fishing.abort) == "function" then
      return tree.fishing.abort() == true
    end
    return false
  end

  function runtime:set_next_fish(player, fish_id)
    local tree = player and player_trees[player.UserId]
    if tree and tree.fishing and type(tree.fishing.set_next_fish) == "function" then
      return tree.fishing.set_next_fish(fish_id) == true
    end
    return false
  end

  function runtime:get_entity_modifiers()
    return entity_modifiers
  end

  function runtime:is_leaving(user_id)
    return leaving_players[user_id] ~= nil
  end

  function runtime:dispatch_interact(actor, payload)
    if self:is_leaving(actor and actor.UserId) then return false end
    if type(payload) == "table" and payload.target == GameCfg.Rescue.Target then
      return self.life:rescue_action(actor, payload)
    end
    local fisherman = fisherman_handles[actor and actor.UserId]
    return fisherman and fisherman.handle(actor, payload) or false
  end

  function runtime:dispatch_shop(actor, payload)
    if self:is_leaving(actor and actor.UserId) then return false end
    local shop = shop_handles[actor and actor.UserId]
    return shop and shop.handle(actor, payload) or false
  end

  function runtime:step(dt, now)
    if not Number.is_finite_number(dt) or dt < 0 then
      return
    end
    local valid_now = now ~= nil and Number.is_finite_number(now) and now or nil
    clock:step(dt, valid_now)
    if has_method(save, "update") then safe_call(opts.logger, "save_update", function() save:update() end) end
    if has_method(platform, "update") then safe_call(opts.logger, "platform_update", function() platform:update() end) end
    if has_method(opts.fish_ability, "update") then
      safe_call(opts.logger, "fish_ability_update", function() opts.fish_ability:update(dt) end)
    end
    if has_method(opts.fish_carrier, "update") then
      safe_call(opts.logger, "fish_carrier_update", function() opts.fish_carrier:update(dt) end)
    end
    for _, weapon in pairs(weapon_sessions) do
      if type(weapon.step) == "function" then weapon:step(clock.now()) end
    end
    for _, blindbox in pairs(blindbox_sessions) do
      if type(blindbox.step) == "function" then blindbox.step() end
    end
    for _, shop in pairs(platform_shop_sessions) do
      if type(shop.step) == "function" then shop.step() end
    end
    if entity_modifiers then
      entity_modifiers:step(clock.now())
    end
    fish_host:enforce_escape_cap(nil)
    runtime:_publish_fish()
  end

  function runtime:on_player_added(player)
    if not is_valid_player(player) then
      return
    end
    local user_id = player.UserId
    local leaving = leaving_players[user_id]
    if leaving then
      leaving.waiting = player
      local ok, err = pcall(player.SetAttribute, player, "SaveState", "pending")
      if not ok then
        if opts.logger and type(opts.logger.error) == "function" then
          pcall(opts.logger.error, opts.logger, "on_player_added:SetAttribute (uid=" .. tostring(user_id) .. "): " .. tostring(err)) -- logger 异常不得中断入场排队
        else
          print("[ServerRuntime]", "on_player_added:SetAttribute", user_id, tostring(err))
        end
      end
      return
    end
    current_players[user_id] = player
    if self.world and self.world.ferry then self.world.ferry:on_player_added(player) end
    if type(opts.on_player_join_start) == "function" then
      safe_call(opts.logger, "on_player_join_start", opts.on_player_join_start, player)
    elseif has_method(player_data, "on_player_added") then
      safe_call(opts.logger, "player_data_added", function() player_data:on_player_added(player) end)
    end
  end

  function runtime:on_save_ready(player, data)
    if not is_valid_player(player) then
      return nil
    end
    local user_id = player.UserId
    if current_players[user_id] ~= player or leaving_players[user_id] then
      return nil
    end
    if type(opts.is_player_data_current) == "function" then
      local current_ok = safe_call(opts.logger, "is_player_data_current", opts.is_player_data_current, player, data)
      if not current_ok then return nil end
    elseif has_method(player_data, "on_player_added") and has_method(player_data, "get_data_inst")
        and player_data:get_data_inst(player) ~= data then
      return nil
    end
    if active_players[user_id] == player then
      return player_trees[user_id]
    end
    if not is_ready_data(player, data) then
      return nil
    end
    if not self._started then
      ready_queue[user_id] = { player, data }
      return nil
    end

    local world = self:start()
    local effects_opts = nil
    if type(opts.player_effects) == "table" or opts.modifier_leaf then
      effects_opts = {}
      if type(opts.player_effects) == "table" then
        for k, v in pairs(opts.player_effects) do
          effects_opts[k] = v
        end
      end
      if opts.modifier_leaf and effects_opts.on_mount_modifier_leaf == nil then
        local ml_opts = type(opts.modifier_leaf) == "table" and opts.modifier_leaf or nil
        effects_opts.on_mount_modifier_leaf = ModifierLeaf.make_slot_mounter(ml_opts)
      end
    end

    local mounts = {}
    local base_mounts = type(opts.player_mounts) == "table" and opts.player_mounts or nil
    if base_mounts then
      for k, v in pairs(base_mounts) do
        mounts[k] = v
      end
    end
    if opts.attr_leaf or opts.ability_leaf or base_mounts then
      local base_leaves = base_mounts and base_mounts.leaves
      if opts.attr_leaf or opts.ability_leaf then
        mounts.leaves = function(s, pt)
          if opts.attr_leaf then
            local al_opts = type(opts.attr_leaf) == "table" and opts.attr_leaf or nil
            AttrLeaf.mount(s, pt, al_opts)
          end
          if opts.ability_leaf then
            local ab_opts = type(opts.ability_leaf) == "table" and opts.ability_leaf or nil
            AbilityLeaf.mount(s, pt, ab_opts)
          end
          if type(base_leaves) == "function" then
            base_leaves(s, pt)
          end
        end
      end
    end

    local base_actions = base_mounts and base_mounts.actions
    mounts.actions = function(s, pt)
      if type(base_actions) == "function" then base_actions(s, pt) end
      local delivery_epoch = opts.delivery_epoch or tostring(world)
      local blindbox = PlayerBlindbox.mount(s, pt, {
        remote = opts.remote, save = opts.save, platform = opts.platform,
        world = world, random = opts.random, delivery_epoch = delivery_epoch,
      })
      blindbox_sessions[user_id] = blindbox
      local shop = PlayerPlatformShop.mount(s, pt, {
        remote = opts.remote, save = opts.save, platform = opts.platform,
        world = world, delivery_epoch = delivery_epoch,
      })
      platform_shop_sessions[user_id] = shop
      s:on_cleanup(function()
        if blindbox_sessions[user_id] == blindbox then blindbox_sessions[user_id] = nil end
        if platform_shop_sessions[user_id] == shop then platform_shop_sessions[user_id] = nil end
      end)
    end

    local tree_data = data
    if opts.player_data and type(opts.player_data.get_data_inst) == "function" then
      local ok, inst = pcall(opts.player_data.get_data_inst, opts.player_data, player)
      if ok and type(inst) == "table" then tree_data = inst end
    end
    local player_tree = PlayerTree.spawn({
      player = player,
      data = tree_data,
      clock = clock,
      world = world,
      logger = opts.logger,
      create_unit = opts.create_unit,
      world_service = opts.world_service,
      fish_unit = opts.fish_unit or fish_host,
      records = world and world.records,
      compendium = opts.compendium,
      quest = opts.quest,
      random = opts.random,
      on_item_bar_state = opts.on_item_bar_state,
      effects = effects_opts,
      on_leave_finalize = opts.on_leave_finalize,
      mounts = mounts,
      remote = opts.remote,
      save = opts.save,
      player_data = opts.player_data,
      platform = opts.platform,
      fish_carrier = opts.fish_carrier,
      damage_filter = runtime._damage_filter,
      damage_context = function() return runtime.life end,
      speed_writer = opts.speed_writer,
      growth_writer = opts.growth_writer,
      max_health_of = function(player) return runtime._max_health_of and runtime._max_health_of(player) end,
      on_downed = opts.on_player_downed,
      fish_units = opts.fish_units,
      lookup_tree = function(user_id)
        return player_trees[user_id]
      end,
      players = function()
        local list = {}
        for _, active in pairs(active_players) do
          list[#list + 1] = active
        end
        return list
      end,
    })
    active_players[user_id] = player
    player_trees[user_id] = player_tree
    if self.world and self.world.squad then self.world.squad:on_player_added(player) end
    SwingRegistry.set_clock(function() return clock.now() end)
    player_tree:mount_phase("alive", "weapon", function(scope)
      local weapon = PlayerWeapon.mount(scope, player_tree, {
        remote = opts.remote,
        save = opts.save,
        physics = opts.physics,
        players_service = opts.players_service,
        ability = opts.ability,
        fish_unit = opts.fish_unit,
        fish_carrier = opts.fish_carrier,
        world = opts.world_service,
        random = opts.random,
        new_hit = function(source, category)
          return runtime.life:new_hit(source, category)
        end,
        apply_hit = function(hit, target, amount)
          return runtime.life:apply_hit(hit, target, amount)
        end,
        apply_effect = function(source, target, kind)
          return modifier_service:Apply(source, target, kind)
        end,
      })
      weapon_sessions[user_id] = weapon
      scope:on_cleanup(function()
        if weapon_sessions[user_id] == weapon then weapon_sessions[user_id] = nil end
      end)
    end)
    player_tree:mount_phase("alive", "grill", function(scope)
      local grill = PlayerGrill.mount(scope, player_tree, {
        remote = opts.remote,
        save = opts.save,
        world = opts.world_service,
        create_unit = opts.create_unit,
        players = function()
          local list = {}
          for _, active in pairs(active_players) do
            list[#list + 1] = active
          end
          return list
        end,
        new_hit = function(source, category)
          return runtime.life:new_hit(source, category)
        end,
        apply_hit = function(hit, target, amount)
          return runtime.life:apply_hit(hit, target, amount)
        end,
      })
      grill_handles[user_id] = grill
      scope:on_cleanup(function()
        if grill_handles[user_id] == grill then grill_handles[user_id] = nil end
      end)
    end)
    player_tree:mount_phase("alive", "shop", function(scope)
      local shop = PlayerShop.mount(scope, player_tree, {
        remote = opts.remote,
        save = opts.save,
        quest = player_tree.quest or opts.quest,
      })
      shop_handles[user_id] = shop
      scope:on_cleanup(function()
        if shop_handles[user_id] == shop then shop_handles[user_id] = nil end
      end)
    end)
    player_tree:mount_phase("alive", "fisherman", function(scope)
      local fisherman = PlayerFisherman.mount(scope, player_tree, {
        remote = opts.remote,
        save = opts.save,
        quest = player_tree.quest or opts.quest,
      })
      fisherman_handles[user_id] = fisherman
      scope:on_cleanup(function()
        if fisherman_handles[user_id] == fisherman then fisherman_handles[user_id] = nil end
      end)
    end)
    player_tree:mount_phase("alive", "lottery", function(scope)
      local lottery = PlayerLottery.mount(scope, player_tree, {
        remote = opts.remote, save = opts.save, random = opts.random,
        in_range = opts.lottery_in_range,
      })
      lottery_sessions[user_id] = lottery
      scope:on_cleanup(function()
        if lottery_sessions[user_id] == lottery then lottery_sessions[user_id] = nil end
      end)
    end)
    if player_tree.set_damage_filter and runtime._damage_filter then
      player_tree:set_damage_filter(runtime._damage_filter())
    end

    safe_call(opts.logger, "on_player_ready", opts.on_player_ready, player, data, player_tree)
    if not runtime._weapon_bound then
      runtime._weapon_bound = true
      if type(opts.bind_weapon_action) == "function" then
        opts.bind_weapon_action(function(actor, payload)
          if runtime:is_leaving(actor and actor.UserId) then return false end
          return runtime.life:weapon_action(actor, payload)
        end)
      end
      if type(opts.register_cast_guard) == "function" then
        opts.register_cast_guard(function(unit, index)
          return runtime.life:weapon_cast_guard(unit, index)
        end)
      end
      if type(opts.bind_cast_action) == "function" then
        opts.bind_cast_action(function(actor, payload)
          if runtime:is_leaving(actor and actor.UserId) then return false end
          local player_tree = player_trees[actor and actor.UserId]
          local fishing = player_tree and player_tree.fishing
          if not fishing then return false end
          return fishing:cast(payload)
        end)
      end
      if type(opts.bind_reel_action) == "function" then
        opts.bind_reel_action(function(actor, kind, payload)
          if runtime:is_leaving(actor and actor.UserId) then return false end
          local player_tree = player_trees[actor and actor.UserId]
          local fishing = player_tree and player_tree.fishing
          if not fishing then return false end
          return fishing:reel(kind, payload)
        end)
      end
    end
    if not runtime._fisherman_bound then
      runtime._fisherman_bound = true
      if type(opts.bind_interact_action) == "function" then
        opts.bind_interact_action(function(actor, payload)
          return runtime:dispatch_interact(actor, payload)
        end)
      end
    end
    if not runtime._shop_bound then
      runtime._shop_bound = true
      if type(opts.bind_shop_action) == "function" then
        opts.bind_shop_action(function(actor, payload)
          return runtime:dispatch_shop(actor, payload)
        end)
      end
    end
    if not runtime._economy_bound then
      runtime._economy_bound = true
      if type(opts.bind_lottery_action) == "function" then
        opts.bind_lottery_action(function(actor, payload)
          if runtime:is_leaving(actor and actor.UserId) then return false end
          local lottery = lottery_sessions[actor and actor.UserId]
          if lottery and type(lottery.handle) == "function" then return lottery.handle(actor, payload) end
          return false
        end)
      end
      if type(opts.bind_blindbox_action) == "function" then
        opts.bind_blindbox_action(function(actor, payload)
          if runtime:is_leaving(actor and actor.UserId) then return false end
          local blindbox = blindbox_sessions[actor and actor.UserId]
          if blindbox and type(blindbox.handle) == "function" then return blindbox.handle(actor, payload) end
          return false
        end)
      end
    end
    if not runtime._grill_bound then
      runtime._grill_bound = true
      if type(opts.bind_grill_action) == "function" then
        opts.bind_grill_action(function(actor, payload)
          if runtime:is_leaving(actor and actor.UserId) then return false end
          local grill = grill_handles[actor and actor.UserId]
          if grill and type(grill.handle) == "function" then
            return grill.handle(actor, payload)
          end
          return false
        end)
      end
    end
    return player_tree
  end

  local function continue_removing(player, leaving)
    local user_id = player.UserId
    if leaving_players[user_id] ~= leaving or leaving.cleaned then
      return
    end

    local progress_tree = player_trees[user_id]
    if progress_tree then
      local expected, finished, collecting = 0, 0, true
      local function one_done()
        finished = finished + 1
        if not collecting and expected > 0 and finished >= expected then
          continue_removing(player, leaving)
        end
      end
      if progress_tree.compendium and progress_tree.compendium:flush_before_leave(player, one_done) then
        expected = expected + 1
      end
      if progress_tree.quest and progress_tree.quest:flush_before_leave(player, one_done) then
        expected = expected + 1
      end
      if progress_tree.story and progress_tree.story:flush_before_leave(player, one_done) then
        expected = expected + 1
      end
      collecting = false
      if expected > 0 then
        if finished < expected then return end
        if finished > expected then return end
      end
    end

    if type(opts.flush_before_leave) == "function" then
      local function resume()
        continue_removing(player, leaving)
      end
      local waiting_flush = safe_call(opts.logger, "flush_before_leave", opts.flush_before_leave, player, resume)
      if waiting_flush then
        return
      end
    end

    leaving.cleaned = true
    if runtime.world and runtime.world.squad then
      safe_call(opts.logger, "小队离场退队", function() runtime.world.squad:on_player_removing(player) end)
    end
    local was_active = active_players[user_id] == player
    if was_active then
      active_players[user_id] = nil
    end

    local player_tree = player_trees[user_id]
    if player_tree and player_tree.player == player then
      player_trees[user_id] = nil
    else
      player_tree = nil
    end

    -- 离场三步协议 Step 1：置 session_alive = false 触发离场终镜像写出与会话结算。
    if player_tree then
      player_tree:begin_leave()
    end

    -- 离场三步协议 Step 2：同步 dispose() 按逆序拆除全部在场资源与局部信号连接。
    if player_tree then
      player_tree:dispose()
    end
    runtime:_publish_fish()

    -- 清理离场玩家施加给其他玩家或活鱼/非玩家实体的持续效果，防止离线来源继续 DoT。
    for _, other_tree in pairs(player_trees) do
      if other_tree and type(other_tree.clear_modifiers_by_source) == "function" then
        other_tree:clear_modifiers_by_source(player)
      end
    end
    if entity_modifiers then
      entity_modifiers:clear_by_source(player)
    end

    -- 离场三步协议 Step 3：宿主执行离线保存序列化与异步排空栅栏。
    if type(opts.on_player_removing) == "function" then
      safe_call(opts.logger, "on_player_removing", opts.on_player_removing, player, was_active)
    else
      if has_method(player_data, "on_player_removing") then
        safe_call(opts.logger, "player_data_removing", function() player_data:on_player_removing(player) end)
      end
      if has_method(platform, "on_player_removing") then
        safe_call(opts.logger, "platform_removing", function() platform:on_player_removing(player) end)
      end
    end

    local function finish_drain()
      if leaving_players[user_id] ~= leaving then
        return
      end
      leaving_players[user_id] = nil
      current_players[user_id] = nil
      local waiting = leaving.waiting
      leaving.waiting = nil
      if waiting then
        runtime:on_player_added(waiting)
      end
    end

    if type(opts.after_idle) == "function" then
      opts.after_idle(user_id, finish_drain)
    elseif has_method(save, "after_idle") then
      save:after_idle(user_id, finish_drain)
    else
      finish_drain()
    end
  end

  function runtime:on_player_removing(player)
    if not is_valid_player(player) then
      return
    end
    local user_id = player.UserId
    local leaving = leaving_players[user_id]
    if leaving then
      if leaving.waiting == player then
        leaving.waiting = nil
      end
      return
    end
    if current_players[user_id] ~= player then
      return
    end
    leaving = { cleaned = false, waiting = nil }
    leaving_players[user_id] = leaving
    if self.world and self.world.ferry then self.world.ferry:on_player_removing(player) end
    local queued = ready_queue[user_id]
    if queued and queued[1] == player then
      ready_queue[user_id] = nil
    end
    continue_removing(player, leaving)
  end

  local function holder_tree_of(player)
    if not is_valid_player(player) then return nil end
    return player_trees[player.UserId]
  end

  local function sorted_fish_list()
    local ids = {}
    for id, fish in pairs(fish_host.Fish) do
      if type(fish) == "table" then ids[#ids + 1] = id end
    end
    table.sort(ids, function(a, b)
      if type(a) == "number" and type(b) == "number" then return a < b end
      return tostring(a) < tostring(b)
    end)
    local out = {}
    for _, id in ipairs(ids) do
      local fish = fish_host.Fish[id]
      if fish ~= nil then out[#out + 1] = fish end
    end
    return out
  end

  local function prune_faulted_fish()
    local faulted = {}
    for _, fish in pairs(fish_host.Fish) do
      if type(fish) == "table" and fish.Tree and fish.Tree.fault ~= nil then
        faulted[#faulted + 1] = fish
      end
    end
    for _, fish in ipairs(faulted) do
      fish_host:remove(fish)
    end
  end

  local function fish_row(fish)
    local species = GameCfg.Fish[fish.FishId] or {}
    local state = fish.State
    local phase = "lifted"
    if state == FishTree.State.escaping then
      phase = "escape"
    elseif state == FishTree.State.Wild then
      phase = "wild"
    elseif state ~= FishTree.State.AwaitLift and state ~= FishTree.State.Held then
      phase = "combat"
    end
    local health = fish.Carrier and fish.Carrier.Health or species.Health
    local maxHealth = species.Health or 0
    local ratio = maxHealth > 0 and (health or 0) / maxHealth or 0
    local bossPhase = nil
    if fish.FishId == "fish56Boss" then
      bossPhase = ratio > 0.6 and "land" or (ratio > 0.2 and "water" or "enraged")
    end
    local lifted = state == FishTree.State.AwaitLift or state == FishTree.State.Held
    return {
      id = fish.Id,
      fishId = fish.FishId,
      name = species.Name,
      mult = fish.Mult,
      zoneId = species.ZoneId,
      phase = phase,
      bossPhase = bossPhase,
      grounded = not lifted,
      health = health,
      maxHealth = maxHealth,
      label = fish.MoveName or (phase == "combat" and "战斗" or (phase == "escape" and "逃脱" or "举鱼")),
      warning = fish.Warning,
      holderId = fish.holder and fish.holder.UserId or nil,
      ownerId = fish.Owner and fish.Owner.UserId or nil,
    }
  end

  local function fish_signature(rows)
    if #rows == 0 then return "" end
    local parts = {}
    for i, row in ipairs(rows) do
      parts[i] = table.concat({
        tostring(row.id),
        tostring(row.phase),
        tostring(row.bossPhase),
        tostring(row.grounded),
        tostring(row.health),
        tostring(row.label),
        tostring(row.holderId),
        tostring(row.ownerId),
        tostring(row.warning),
      }, "|")
    end
    return table.concat(parts, ";")
  end

  function runtime:_publish_fish()
    prune_faulted_fish()
    local list, warnings = {}, {}
    for _, fish in ipairs(sorted_fish_list()) do
      local row = fish_row(fish)
      list[#list + 1] = row
      if type(row.warning) == "table" then
        warnings[#warnings + 1] = row.warning
      end
    end
    local sig = fish_signature(list)
    if not fish_dirty and sig == last_fish_signature then return end
    fish_dirty = false
    if sig == last_fish_signature then return end
    last_fish_signature = sig
    local remote = opts.remote
    if type(remote) ~= "table" or type(remote.get_re) ~= "function" then return end
    local event = remote:get_re("FishCombatState")
    if event and type(event.FireAllClients) == "function" then
      pcall(function() event:FireAllClients({ list = list, warnings = warnings }) end) -- 下行失败不回滚权威活鱼
    end
  end

  function runtime:lottery_action(player, payload)
    if runtime:is_leaving(player and player.UserId) then return false end
    local lottery = lottery_sessions[player and player.UserId]
    if not lottery or type(lottery.handle) ~= "function" then return false end
    return lottery.handle(player, payload)
  end

  function runtime:blindbox_action(player, payload)
    if runtime:is_leaving(player and player.UserId) then return false end
    local blindbox = blindbox_sessions[player and player.UserId]
    if not blindbox or type(blindbox.handle) ~= "function" then return false end
    return blindbox.handle(player, payload)
  end

  function runtime:lottery_state(player)
    if runtime:is_leaving(player and player.UserId) then return false end
    local lottery = lottery_sessions[player and player.UserId]
    if not lottery or type(lottery.push_state) ~= "function" then return false end
    lottery.push_state()
    return true
  end

  function runtime:blindbox_state(player)
    if runtime:is_leaving(player and player.UserId) then return false end
    local blindbox = blindbox_sessions[player and player.UserId]
    if not blindbox or type(blindbox.push_state) ~= "function" then return false end
    blindbox.push_state()
    return true
  end

  function runtime:platform_shop_action(player, payload)
    if runtime:is_leaving(player and player.UserId) then return false end
    local shop = platform_shop_sessions[player and player.UserId]
    if not shop or type(shop.handle) ~= "function" then return false end
    return shop.handle(player, payload)
  end

  function runtime:receive_landed(player, catch)
    if not is_valid_player(player) or type(catch) ~= "table" then return false, "bad" end
    if self:is_leaving(player.UserId) then return false, "leaving" end
    local holder = holder_tree_of(player)
    if holder == nil or holder:is_disposed() then return false, "no-holder" end
    local position = catch.position or catch.Position
      or { x = catch.x, y = catch.y, z = catch.z }
    local fish, err = fish_host:spawn_landed(player, {
      fishId = catch.fishId,
      mult = catch.mult,
    }, position)
    if fish == nil then return false, err end
    self:_publish_fish()
    return true, fish.Id
  end

  function runtime:drop_fish(player)
    if not is_valid_player(player) then return false end
    local dropped = fish_host:drop(player) == true
    self:_publish_fish()
    return dropped
  end

  function runtime:fish_snapshot(user_id)
    prune_faulted_fish()
    local list = {}
    for _, fish in ipairs(sorted_fish_list()) do
      local row = fish_row(fish)
      if user_id == nil or row.holderId == user_id or row.ownerId == user_id then
        list[#list + 1] = row
      end
    end
    return list
  end

  function runtime:damage_fish(id, amount)
    local fish = fish_host.Fish[id]
    if fish == nil then return false end
    local ok = fish_host:damage_fish(fish, amount)
    self:_publish_fish()
    return ok
  end

  function runtime:fault_fish(id, reason)
    local fish = fish_host.Fish[id]
    if fish == nil then return false end
    local faulted = fish_host:fault(fish, reason)
    if faulted then
      fish_host:remove(fish)
    end
    self:_publish_fish()
    return faulted
  end

  function runtime:shutdown()
    local ids = {}
    for user_id in pairs(player_trees) do
      ids[#ids + 1] = user_id
    end
    table.sort(ids, function(a, b)
      return tostring(a) < tostring(b)
    end)
    for _, user_id in ipairs(ids) do
      local pt = player_trees[user_id]
      player_trees[user_id] = nil
      if pt then
        pt:dispose()
      end
    end
    for _, fish in ipairs(sorted_fish_list()) do
      fish_host:remove(fish)
    end
    for i = #re_conns, 1, -1 do
      local conn = re_conns[i]
      re_conns[i] = nil
      if conn and type(conn.Disconnect) == "function" then
        pcall(conn.Disconnect, conn) -- 远程事件连接可能已先随宿主卸载
      end
    end
    self._core_re_bound = false
    if carrier_died_handler and has_method(opts.fish_carrier, "unsubscribe_died") then
      opts.fish_carrier:unsubscribe_died(carrier_died_handler)
      carrier_died_handler = nil
    end
    if bound_shop_action and type(platform) == "table" and platform.ShopAction == bound_shop_action then
      platform.ShopAction = nil
      bound_shop_action = nil
    end
    if self.world then
      self.world:dispose()
    end
    if entity_modifiers then
      entity_modifiers:clear_all()
    end
    current_players = {}
    active_players = {}
    leaving_players = {}
    ready_queue = {}
    fish_dirty = false
    last_fish_signature = ""
    self._started = false
    if current_runtime == self then
      current_runtime = nil
    end
  end

  local damage_filter = opts.damage_filter
  if damage_filter == nil then
    damage_filter = PkDamageFilter.make({
      party = {
        same_party = function(_, source, target)
          local squad = runtime.world and runtime.world.squad
          return squad and squad:same_party(source, target) or false
        end,
      },
      zone_markers = opts.zone_markers,
      zones = opts.zones,
    })
  end
  runtime._max_health_of = opts.max_health_of
  runtime._damage_filter = function()
    return damage_filter
  end
  runtime.life = LifeFacade.new({
    player_trees = player_trees,
    active_players = active_players,
    weapon_sessions = weapon_sessions,
    opts = opts,
    get_max_health_of = function() return runtime._max_health_of end,
    get_damage_filter = function() return damage_filter end,
    set_damage_filter = function(filter) damage_filter = filter end,
  })
  fish_host.Vitals = runtime.life

  if has_method(player_data, "on_player_added") then
    player_data.Runtime = runtime
    player_data.Save = save
    player_data.Vitals = runtime.life
    player_data.Quest = { notify = function(_, kind, owner, fact) return runtime:notify_quest(kind, owner, fact) end }
    player_data.Ability = {
      apply_growth = function(_, player)
        local tree = is_valid_player(player) and player_trees[player.UserId]
        local data = player_data:get_data_inst(player)
        if not tree or not data then return { Ok = false } end
        tree:sync_from_data(data)
        return { Ok = true }
      end,
    }
  end
  if has_method(save, "load_into") or has_method(save, "Start") then
    if has_method(player_data, "send_item_bar") then save.PlayerData = player_data end
    save.on_ready = function(player, data) runtime:on_save_ready(player, data) end
  end
  if type(platform) == "table" then
    if has_method(platform, "Start") then
      if type(save) == "table" then platform.Save = save end
      if type(player_data) == "table" then platform.PlayerData = player_data end
    end
    if platform.ShopAction == nil then
      bound_shop_action = function(actor, payload)
        return runtime:platform_shop_action(actor, payload)
      end
      platform.ShopAction = bound_shop_action
    end
  end
  if opts.fish_ability then
    opts.fish_ability.Modifier = modifier_service
    opts.fish_ability.Vitals = runtime.life
    opts.fish_ability.Ai = opts.fish_ai
    opts.fish_ability.BehaviorServices = { Vitals = runtime.life, Modifier = modifier_service, GM = PlayerGM }
  end

  return runtime
end

return ServerRuntime
