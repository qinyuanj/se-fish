-- 服务端 Spoke 运行时总控与离场三步协议编排器（ADR-0032 §1、§2、§4 / #295）：
-- 负责：
--   1. 持有唯一 SpokeClock，接受宿主帧泵（step）驱动；
--   2. 拉起全局唯一 SharedWorldTree（7 个钓鱼区子域骨架 + 全局小队 Dock）；
--   3. 仅在存档加载就绪且服务启动后为在场玩家生成独立 Auto PlayerTree；
--   4. 编排离场三步协议：前置异步脏写 → Step 1 (session_alive=false 终镜像)
--      → Step 2 (同步 dispose 逆序拆资源与信号) → Step 3 (宿主持久化序列化 + 异步排空栅栏)；
--   5. 维护同账号重进排空栅栏（leaving.waiting），防止提前读旧档或覆盖正在落盘的数据。
-- 本模块归属 L2（server.World），零反向依赖存量旧债务模块；过渡接缝全部由 L1 入口以回调注入。

local GameCfg = require("common.GameCfg")
local Number = require("common.Number")
local SpokeClock = require("common.SpokeClock")
local SharedWorldTree = require("server.World.SharedWorldTree")
local PlayerTree = require("server.World.PlayerTree")
local AttrLeaf = require("server.World.AttrLeaf")
local ModifierLeaf = require("server.World.ModifierLeaf")
local AbilityLeaf = require("server.World.AbilityLeaf")
local PlayerWeapon = require("server.World.PlayerWeapon")
local PlayerGrill = require("server.World.PlayerGrill")
local PlayerShop = require("server.World.PlayerShop")
local PlayerFisherman = require("server.World.PlayerFisherman")
local PlayerLottery = require("server.World.PlayerLottery")
local PlayerBlindbox = require("server.World.PlayerBlindbox")
local PlayerPlatformShop = require("server.World.PlayerPlatformShop")
local SwingRegistry = require("server.SwingRegistry")
local PkDamageFilter = require("server.World.PkDamageFilter")
local FishTree = require("server.World.FishTree")
local FishAiTarget = require("server.World.FishAiTarget")

local ServerRuntime = {}
local current_runtime = nil

function ServerRuntime.current()
  return current_runtime
end

function ServerRuntime.set_current(rt)
  current_runtime = rt
end

local function is_valid_player(player)
  local kind = type(player)
  return (kind == "table" or kind == "userdata") and player.UserId ~= nil
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

  local initial_now = Number.IsFiniteNumber(opts.initial_now) and opts.initial_now or 0
  local clock = opts.clock or SpokeClock.new(initial_now)
  local current_players = {}
  local active_players = {}
  local player_trees = {}
  local fish_trees = {}
  local fish_order = {}
  local next_fish_id = 0
  local fish_host = FishTree.new()
  local ai_started = {}
  fish_host.CreateUnit = opts.create_unit
  fish_host.World = opts.world_service
  fish_host.Quest = opts.quest
  fish_host.Cast = opts.cast
  fish_host.Ai = opts.fish_ai
  fish_host.AiTarget = opts.fish_ai_target or FishAiTarget
  fish_host.AbilityApi = opts.ability_api
  fish_host.Ability = opts.fish_ability
  fish_host.Now = function() return clock.now() end
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

  fish_host.OnKilled = function(killed)
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
      on_mount_world = opts.on_mount_world,
      create_unit = opts.create_unit,
      remote = opts.remote,
      bait_spots = opts.bait_spots,
      player_data = opts.player_data,
      save = opts.save,
      interact = opts.interact,
      players_service = opts.players_service,
      session_epoch = opts.session_epoch or opts.delivery_epoch,
      lookup_tree = function(player)
        if type(player) ~= "table" then return nil end
        return player_trees[player.UserId]
      end,
    })
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
          if squad and squad.Online[actor and actor.UserId] == actor then squad:Push(actor) end
        end)
      end
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

  -- 服务端真机探针与 RE 绑定共用的公开命令入口；不暴露会话内部句柄。
  function runtime:dispatch_interact(actor, payload)
    if self:is_leaving(actor and actor.UserId) then return false end
    if type(payload) == "table" and payload.target == GameCfg.Rescue.Target then
      return self.life:RescueAction(actor, payload)
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
    if not Number.IsFiniteNumber(dt) or dt < 0 then
      return
    end
    local valid_now = now ~= nil and Number.IsFiniteNumber(now) and now or nil
    clock:step(dt, valid_now)
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
    fish_host:Update()
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
    if self.world and self.world.ferry then self.world.ferry:OnPlayerAdded(player) end
    safe_call(opts.logger, "on_player_join_start", opts.on_player_join_start, player)
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
      if not current_ok then
        return nil
      end
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

    -- 支付与待交付恢复属于整个玩家会话，不随 alive 相位中断；抽奖会话则在 alive 内单独挂载。
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
    if opts.player_data and type(opts.player_data.GetDataInst) == "function" then
      local ok, inst = pcall(opts.player_data.GetDataInst, opts.player_data, player)
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
    if self.world and self.world.squad then self.world.squad:OnPlayerAdded(player) end
    SwingRegistry.SetClock(function() return clock.now() end)
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
          return runtime.life:NewHit(source, category)
        end,
        apply_hit = function(hit, target, amount)
          return runtime.life:ApplyHit(hit, target, amount)
        end,
        apply_effect = function(source, target, kind)
          local target_tree = player_trees[target and target.UserId]
          if target_tree and type(target_tree.apply_modifier) == "function" then
            return target_tree:apply_modifier(kind, { source = source })
          end
          if entity_modifiers then
            return entity_modifiers:apply(source, target, kind)
          end
          return false
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
          return runtime.life:NewHit(source, category)
        end,
        apply_hit = function(hit, target, amount)
          return runtime.life:ApplyHit(hit, target, amount)
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
        quest = opts.quest,
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
        quest = opts.quest,
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
          return runtime.life:WeaponAction(actor, payload)
        end)
      end
      if type(opts.register_cast_guard) == "function" then
        opts.register_cast_guard(function(unit, index)
          return runtime.life:WeaponCastGuard(unit, index)
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
      safe_call(opts.logger, "小队离场退队", function() runtime.world.squad:OnPlayerRemoving(player) end)
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
    safe_call(opts.logger, "on_player_removing", opts.on_player_removing, player, was_active)

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
    if self.world and self.world.ferry then self.world.ferry:OnPlayerRemoving(player) end
    fish_host:OnPlayerRemoving(player)
    self:_publish_fish()
    local queued = ready_queue[user_id]
    if queued and queued[1] == player then
      ready_queue[user_id] = nil
    end
    continue_removing(player, leaving)
  end

  local function holder_tree_of(player)
    if type(player) ~= "table" then return nil end
    return player_trees[player.UserId]
  end

  local function drop_fish_record(id)
    local fish = fish_trees[id]
    if fish == nil then return end
    fish_trees[id] = nil
    for index, value in ipairs(fish_order) do
      if value == id then table.remove(fish_order, index) break end
    end
    if ai_started[id] then
      ai_started[id] = nil
      if opts.ai and type(opts.ai.stop) == "function" then pcall(opts.ai.stop, opts.ai, id) end
    end
    if fish_host.Fish[fish.Id] == fish then fish_host:Remove(fish) end
  end

  local function fish_row(fish)
    local species = GameCfg.Fish[fish.FishId] or {}
    local state = fish.State
    local phase = "lifted"
    if state == FishTree.State.Escaping then
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
      holderId = fish.Holder and fish.Holder.UserId or nil,
      ownerId = fish.Owner and fish.Owner.UserId or nil,
    }
  end

  function runtime:_publish_fish()
    local list, warnings, gone = {}, {}, {}
    for _, id in ipairs(fish_order) do
      local fish = fish_trees[id]
      if fish ~= nil then
        if fish_host.Fish[fish.Id] ~= fish then
          gone[#gone + 1] = id
        else
          local row = fish_row(fish)
          if opts.ai and (row.phase == "combat" or row.phase == "escape") and not ai_started[id] then
            ai_started[id] = true
            if type(opts.ai.start) == "function" then pcall(opts.ai.start, opts.ai, id) end
          end
          list[#list + 1] = row
          if type(row.warning) == "table" then
            warnings[#warnings + 1] = row.warning
          end
        end
      end
    end
    for _, id in ipairs(gone) do drop_fish_record(id) end
    local remote = opts.remote
    if type(remote) ~= "table" or type(remote.GetRE) ~= "function" then return end
    local event = remote:GetRE("FishCombatState")
    if event and type(event.FireAllClients) == "function" then
      pcall(function() event:FireAllClients({ list = list, warnings = warnings }) end) -- 下行失败不回滚权威活鱼
    end
  end

  local function release_fish_for(player)
    if not is_valid_player(player) then return end
    local held = fish_host:GetHeld(player)
    if held then fish_host:Release(held, "life") end
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
    local fish, err = fish_host:SpawnLanded(player, {
      fishId = catch.fishId,
      mult = catch.mult,
    }, position)
    if fish == nil then return false, err end
    next_fish_id = next_fish_id + 1
    local id = fish.Id
    fish_trees[id] = fish
    fish_order[#fish_order + 1] = id
    self:_publish_fish()
    return true, id
  end

  function runtime:drop_fish(player)
    if not is_valid_player(player) then return false end
    local dropped = fish_host:Drop(player) == true
    self:_publish_fish()
    return dropped
  end

  function runtime:fish_snapshot(user_id)
    local list = {}
    for _, id in ipairs(fish_order) do
      local fish = fish_trees[id]
      if fish and fish_host.Fish[fish.Id] == fish then
        local row = fish_row(fish)
        if user_id == nil or row.holderId == user_id or row.ownerId == user_id then
          list[#list + 1] = row
        end
      end
    end
    return list
  end

  function runtime:damage_fish(id, amount)
    local fish = fish_trees[id]
    if fish == nil then return false end
    local ok = fish_host:DamageFish(fish, amount)
    self:_publish_fish()
    return ok
  end

  function runtime:fault_fish(id, reason)
    local fish = fish_trees[id]
    if fish == nil then return false end
    fish.Fault = reason or "fish"
    drop_fish_record(id)
    self:_publish_fish()
    return true
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
    local fish_ids = {}
    for id in pairs(fish_trees) do fish_ids[#fish_ids + 1] = id end
    for _, id in ipairs(fish_ids) do drop_fish_record(id) end
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
    self._started = false
    if current_runtime == self then
      current_runtime = nil
    end
  end

  local hit_seq = 0
  local damage_filter = opts.damage_filter
  if damage_filter == nil then
    damage_filter = PkDamageFilter.make({
      party = {
        SameParty = function(_, source, target)
          local squad = runtime.world and runtime.world.squad
          return squad and squad:SameParty(source, target) or false
        end,
      },
      zone_markers = opts.zone_markers,
      zones = opts.zones,
    })
  end
  runtime._max_health_of = opts.max_health_of
  runtime.life = {}
  fish_host.Vitals = runtime.life
  local life = runtime.life

  local function tree_of(player)
    if type(player) ~= "table" or player.UserId == nil then return nil end
    local tree = player_trees[player.UserId]
    if tree and not tree:is_disposed() then return tree end
    return nil
  end

  local function player_from_unit(unit)
    if type(unit) ~= "table" then return nil end
    for _, player in pairs(active_players) do
      if player == unit or player.Character == unit then return player end
    end
    return nil
  end

  function life:GetTree(player)
    return tree_of(player)
  end

  function life:PlayerFromUnit(unit)
    return player_from_unit(unit)
  end

  function life:LifeStatus(player)
    local tree = tree_of(player)
    return tree and tree.states.life_phase:now() or nil
  end

  function life:IsDowned(player)
    local phase = self:LifeStatus(player)
    return phase == "downed" or phase == "rescuing"
  end

  function life:IsRescuing(player)
    return self:LifeStatus(player) == "rescuing"
  end

  function life:PlayerByUserId(user_id)
    for _, player in pairs(active_players) do
      if player.UserId == user_id then return player end
    end
    return nil
  end

  function life:IsDead(player)
    return self:LifeStatus(player) == "dead"
  end

  function life:CanAct(player)
    local tree = tree_of(player)
    return tree ~= nil and tree.memos.can_act:now() == true
  end

  function life:CanTakeDamage(player)
    return self:LifeStatus(player) == "alive"
  end

  function life:CanEat(player, item_id)
    local tree = tree_of(player)
    if not tree or tree.memos.can_act:now() ~= true then return false end
    local definition = type(item_id) == "string" and GameCfg.Items.Definitions[item_id]
    return type(definition) == "table" and type(definition.EatPercent) == "number"
  end

  function life:Eat(player, item_id, cook_rate)
    local tree = tree_of(player)
    if not tree then return false end
    return tree:eat(item_id, cook_rate)
  end

  function life:MaxHealthOf(player)
    if type(runtime._max_health_of) == "function" then
      local ok, value = pcall(runtime._max_health_of, player)
      if ok and Number.IsFiniteNumber(value) and value >= 1 then return math.floor(value) end
    end
    local tree = tree_of(player)
    local value = tree and tree.memos.max_health and tree.memos.max_health:now()
    if Number.IsFiniteNumber(value) and value >= 1 then return math.floor(value) end
    return GameCfg.Vitals.MaxHealth
  end

  function life:SnapshotHealth(player)
    local tree = tree_of(player)
    if not tree then return nil, nil end
    return math.max(0, math.floor(tree.states.health:now())), self:MaxHealthOf(player)
  end

  function life:SetDamageFilter(filter)
    damage_filter = filter
    for _, tree in pairs(player_trees) do
      if tree.set_damage_filter then tree:set_damage_filter(filter or false) end
    end
  end

  function life:NewHit(source, category)
    hit_seq = hit_seq + 1
    local source_player = tree_of(source) and source or player_from_unit(source)
    return {
      id = hit_seq,
      source = source,
      category = category,
      sourcePlayer = source_player,
      targets = {},
    }
  end

  function life:ResolveHitSource(hit)
    return type(hit) == "table" and hit.sourcePlayer or nil
  end

  function life:ApplyHit(hit, target, amount)
    local player = tree_of(target) and target or player_from_unit(target)
    local tree = tree_of(player) or tree_of(hit and hit.sourcePlayer)
    if not tree then
      for _, candidate in pairs(player_trees) do
        if candidate and not candidate:is_disposed() then tree = candidate break end
      end
    end
    if not tree then return false end
    return tree:apply_hit(hit, target, amount)
  end

  function life:ApplyDamage(player, amount, hit)
    local ok = self:ApplyHit(hit or self:NewHit(nil, "damage"), player, amount)
    local tree = tree_of(player)
    if tree and tree.states.life_phase:now() ~= "alive" then
      release_fish_for(player)
      runtime:_publish_fish()
    end
    return ok
  end

  function life:SetHealth(player, value)
    local tree = tree_of(player)
    if not tree or not Number.IsFiniteNumber(value) then return false end
    local current = tree.states.health:now()
    if value < current then
      return self:ApplyDamage(player, current - value, self:NewHit(nil, "gm"))
    end
    local controller = player.Character and player.Character.Controller
    if controller then pcall(function() controller.Health = value end) end
    tree.states.health:set(value)
    return true
  end

  function life:SetHunger(player, value)
    local tree = tree_of(player)
    if not tree or not Number.IsFiniteNumber(value) then return false end
    local clamped = math.max(0, math.min(GameCfg.Vitals.MaxHunger, math.floor(value)))
    tree.states.hunger:set(clamped)
    return true
  end

  function life:Phase(player)
    return self:LifeStatus(player)
  end

  function life:GetState(player)
    local tree = tree_of(player)
    if not tree then return nil end
    return { player = player, phase = tree.states.life_phase:now(), tree = tree }
  end

  function life:RescueAction(player, payload)
    if type(payload) ~= "table" or payload.action ~= GameCfg.Rescue.Action then return false end
    local seq = payload.seq
    if type(seq) ~= "number" or seq ~= math.floor(seq) or seq < 1 or seq > 2147483647 then return false end
    local function reply(result)
      if opts.remote and type(opts.remote.GetRE) == "function" then
        opts.remote:GetRE("InteractResult"):FireClient(player, result)
      end
      return result
    end
    if type(payload.targetUserId) ~= "number" then
      reply({ action = "Rescue", ok = false, reason = "invalid", seq = seq })
      return false
    end
    local data = opts.player_data and opts.player_data:GetDataInst(player)
    local save = opts.save
    if not data or not save then return false end
    local request_id = payload.operation
    if request_id ~= nil and type(request_id) ~= "table" then return false end
    if request_id == nil then request_id = seq end
    local operation, mode = save:ResolveRequest(player, data, "rescue", request_id)
    if not operation then return false end
    if mode == "replay" then
      return save:Execute(player, data, operation, function() return nil, "expired" end,
        function(ok, result)
          if ok then result.operation = operation reply(result) end
        end) == true
    end
    local target = nil
    for _, candidate in pairs(active_players) do
      if candidate.UserId == payload.targetUserId then target = candidate break end
    end
    local target_tree = target and player_trees[target.UserId]
    local phase = target_tree and target_tree.states.life_phase:now()
    if not target or (phase ~= "downed" and phase ~= "rescuing") then
      reply({ action = "Rescue", ok = false, reason = "not-downed", seq = seq, targetUserId = payload.targetUserId })
      return false
    end
    local from = player.Character and player.Character.Position
    local to = target.Character and target.Character.Position
    if not from or not to then
      reply({ action = "Rescue", ok = false, reason = "no-position", seq = seq, targetUserId = target.UserId })
      return false
    end
    local dx, dz = from.x - to.x, from.z - to.z
    if math.sqrt(dx * dx + dz * dz) > GameCfg.Rescue.Range then
      reply({ action = "Rescue", ok = false, reason = "too-far", seq = seq, targetUserId = target.UserId })
      return false
    end
    local can, reason = self:CanRescue(target, player)
    if not can then
      reply({ action = "Rescue", ok = false, reason = reason, seq = seq, targetUserId = target.UserId })
      return false
    end
    local started, why = self:BeginRescue(target, player)
    return save:Execute(player, data, operation, function()
      return { ok = started == true, action = "Rescue", targetUserId = target.UserId, reason = why }
    end, function(written, result)
      if not written then
        if started then self:CancelRescue(self:GetState(target)) end
        reply({ action = "Rescue", ok = false, reason = tostring(result), seq = seq, targetUserId = target.UserId })
        return
      end
      result.operation = operation
      reply(result)
    end) == true
  end

  function life:CanRescue(target, rescuer)
    local tree = tree_of(target)
    if not tree or type(tree._accept_rescue) ~= "function" then return false, "not-downed" end
    local phase = tree.states.life_phase:now()
    if phase == "rescuing" then return false, "busy" end
    if phase ~= "downed" then return false, "not-downed" end
    return true
  end

  function life:BeginRescue(target, rescuer)
    local rescuer_tree = tree_of(rescuer)
    if not rescuer_tree then return false, "no-rescuer" end
    return rescuer_tree:begin_rescue(target)
  end

  function life:CancelRescue(state)
    local tree = state and tree_of(state.player or state)
    if not tree or type(tree.cancel_rescue) ~= "function" then return false end
    return tree:cancel_rescue() == true
  end

  function life:RequestAction(player, kind)
    local tree = tree_of(player)
    return tree ~= nil and tree:request_action(kind) == true
  end

  function life:WeaponAction(player, payload)
    local tree = tree_of(player)
    if not tree then return false end
    local weapon = weapon_sessions[player.UserId]
    if not weapon or type(weapon.handle) ~= "function" then return false end
    return weapon:handle(payload) == true
  end

  function life:WeaponCastGuard(unit, index)
    for _, weapon in pairs(weapon_sessions) do
      if type(weapon.guard) == "function" and weapon:guard(unit, index) ~= true then
        return false
      end
    end
    return true
  end

  runtime._damage_filter = function()
    return damage_filter
  end

  return runtime
end

return ServerRuntime
