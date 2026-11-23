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
  local leaving_players = {}
  local ready_queue = {}

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
    _started = false,
  }

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
      lookup_tree = function(player)
        if type(player) ~= "table" then return nil end
        return player_trees[player.UserId]
      end,
    })
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

  function runtime:get_entity_modifiers()
    return entity_modifiers
  end

  function runtime:is_leaving(user_id)
    return leaving_players[user_id] ~= nil
  end

  function runtime:step(dt, now)
    if not Number.IsFiniteNumber(dt) or dt < 0 then
      return
    end
    local valid_now = now ~= nil and Number.IsFiniteNumber(now) and now or nil
    clock:step(dt, valid_now)
    if entity_modifiers then
      entity_modifiers:step(clock.now())
    end
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

    local mounts = nil
    local base_mounts = type(opts.player_mounts) == "table" and opts.player_mounts or nil
    if base_mounts or opts.attr_leaf or opts.ability_leaf then
      mounts = {}
      if base_mounts then
        for k, v in pairs(base_mounts) do
          mounts[k] = v
        end
      end
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
    if player_tree.set_damage_filter and runtime._damage_filter then
      player_tree:set_damage_filter(runtime._damage_filter())
    end

    safe_call(opts.logger, "on_player_ready", opts.on_player_ready, player, data, player_tree)
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
    local queued = ready_queue[user_id]
    if queued and queued[1] == player then
      ready_queue[user_id] = nil
    end
    continue_removing(player, leaving)
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
  local damage_filter = nil
  runtime._max_health_of = opts.max_health_of
  runtime.life = {}
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
    return self:ApplyHit(hit or self:NewHit(nil, "damage"), player, amount)
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

  runtime._damage_filter = function()
    return damage_filter
  end

  return runtime
end

return ServerRuntime
