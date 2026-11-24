-- 服务端玩家属性派生与持续效果主权模块（ADR-0032 §1、§3 / #297-A1）：
-- 挂载在 PlayerTree Stage 2（Attributes）内，负责：
--   1. 接管 weak / poison / burn / frost / paralyze 的剩余时间、层数、末次来源与 DoT 结算主权；
--   2. 按 SpokeClock 驱动计时：weak 走 1 Hz on_second（角色空窗暂停、重建保留），
--      paralyze（0.5s 亚秒）走短寿命 on_frame 仅置 is_paralyzed=true（不退出 alive 相位），
--      poison / burn / frost 仅在活跃槽位内推进 DoT 与精准到期；
--   3. 确定性派生 AttrModel / BodyScale / WeaponComponents（max_health、body_scale、
--      body_derived、move_multiplier、move_speed_scale、walk_speed、weapon_damage_*）；
--   4. 为 A2 的 modifier_system 叶子投影预留 on_mount_modifier_leaf 纯输出挂点。
-- 本模块归属 L2（server.WorldHost），零反向依赖存量旧债务模块。

local GameCfg = require("common.game_cfg")
local AttrModel = require("common.attr_model")
local BodyScale = require("common.body_scale")
local Number = require("common.number")
local spoke = require("common.packages.spoke.api")
local SpokeRuntime = require("common.packages.spoke.runtime.spoke_runtime")

local State = spoke.State

local PlayerEffects = {}

local ALL_KINDS = { "poison", "burn", "frost", "paralyze", "weak" }
local VALID_KINDS = {
  poison = true,
  burn = true,
  frost = true,
  paralyze = true,
  weak = true,
}

local function finite_positive(value)
  return Number.IsFiniteNumber(value) and value > 0
end

local function read_walk_speed(character)
  if character == nil then
    return nil
  end
  local ok, speed = pcall(function()
    local controller = character.Controller
    return controller and controller.WalkSpeed
  end) -- 兼容引擎 userdata 角色在过渡期暂未挂载 Controller 或只读访问异常
  if ok and finite_positive(speed) then
    return speed
  end
  return nil
end

local function default_duration(kind)
  if kind == "weak" then
    return GameCfg.Survival.WeakSec
  end
  local cfg = GameCfg.Ability.StatusEffects and GameCfg.Ability.StatusEffects[kind]
  return cfg and cfg.DurationSec or 0
end

local function max_stacks_of(kind)
  local cfg = GameCfg.Ability.StatusEffects and GameCfg.Ability.StatusEffects[kind]
  if cfg and finite_positive(cfg.MaxStacks) then
    return math.floor(cfg.MaxStacks)
  end
  return 1
end

local function dot_cfg_of(kind)
  local cfg = GameCfg.Ability.StatusEffects and GameCfg.Ability.StatusEffects[kind]
  if cfg and finite_positive(cfg.TickSec) and Number.IsFiniteNumber(cfg.DamagePerStack) then
    return cfg
  end
  return nil
end

---@param s2 table Stage 2 EffectBuilder
---@param player_tree table
---@param opts? table
function PlayerEffects.mount(s2, player_tree, opts)
  opts = type(opts) == "table" and opts or {}

  local clock = player_tree.clock
  local states = player_tree.states
  local memos = player_tree.memos
  local modifier_dock = player_tree.docks.modifiers

  if states.character == nil then
    local ok_char, ch = pcall(function() return player_tree.player and player_tree.player.Character end) -- 兼容引擎 userdata 玩家
    states.character = State.new("PlayerTree.character", ok_char and ch or nil)
  end
  if states.base_speed == nil then
    states.base_speed = State.new("PlayerTree.base_speed", nil)
  end
  if states.is_frost == nil then
    states.is_frost = State.new("PlayerTree.is_frost", false)
  end
  if states.shop_upgrades == nil then
    local raw_upgrades = type(player_tree.data) == "table"
        and type(player_tree.data.Extra) == "table"
        and type(player_tree.data.Extra.growth) == "table"
        and type(player_tree.data.Extra.growth.upgrades) == "table"
        and player_tree.data.Extra.growth.upgrades or {}
    states.shop_upgrades = State.new("PlayerTree.shop_upgrades", raw_upgrades)
  end

  local function is_tree_disposed()
    return player_tree.tree ~= nil and player_tree.tree.is_detached == true
  end

  local active_effects = {}
  local modifier_signals = {}
  for _, kind in ipairs(ALL_KINDS) do
    modifier_signals[kind] = State.new("PlayerEffects." .. kind, nil)
  end
  player_tree.modifier_signals = modifier_signals

  local function sync_flag(kind, is_active)
    if kind == "weak" then
      states.is_weak:set(is_active)
    elseif kind == "frost" then
      states.is_frost:set(is_active)
    elseif kind == "paralyze" then
      states.is_paralyzed:set(is_active)
    end
  end

  local function make_snapshot(entry, now)
    if not entry then
      return nil
    end
    local remaining
    if entry.paused_remaining ~= nil then
      remaining = math.max(0, entry.paused_remaining)
    else
      remaining = math.max(0, entry.expires_at - now)
    end
    return {
      kind = entry.kind,
      stacks = entry.stacks,
      duration = entry.duration,
      remaining = remaining,
      expires_at = entry.expires_at,
      source = entry.source,
      paused = entry.paused_remaining ~= nil,
      revision = entry.revision,
    }
  end

  local function emit_signal(kind)
    local entry = active_effects[kind]
    modifier_signals[kind]:set(make_snapshot(entry, clock.now()))
  end

  local function remaining_of(entry, now)
    if not entry then
      return 0
    end
    if entry.paused_remaining ~= nil then
      return math.max(0, entry.paused_remaining)
    end
    return math.max(0, entry.expires_at - now)
  end

  local function clear_kind(kind)
    if not VALID_KINDS[kind] then
      return false
    end
    local existing = active_effects[kind]
    if not existing then
      sync_flag(kind, false)
      modifier_signals[kind]:set(nil)
      return false
    end
    active_effects[kind] = nil
    SpokeRuntime.batch(function()
      sync_flag(kind, false)
      modifier_signals[kind]:set(nil)
      if not is_tree_disposed() then
        modifier_dock:drop(kind)
      end
    end)
    return true
  end

  local function drain_dot(entry, now)
    local cfg = dot_cfg_of(entry.kind)
    if not cfg or entry.paused_remaining ~= nil then
      return
    end
    while entry.next_tick_at and entry.next_tick_at <= now and entry.next_tick_at <= entry.expires_at + 1e-9 do
      if active_effects[entry.kind] ~= entry or is_tree_disposed() then
        return
      end
      entry.next_tick_at = entry.next_tick_at + cfg.TickSec
      local damage = entry.stacks * cfg.DamagePerStack
      if type(opts.on_dot_tick) == "function" then
        opts.on_dot_tick(player_tree, entry.kind, damage, entry.source, entry.stacks)
      end
    end
  end

  local function check_advance(entry, now)
    if active_effects[entry.kind] ~= entry then
      return
    end
    if entry.paused_remaining ~= nil then
      return
    end
    drain_dot(entry, now)
    if active_effects[entry.kind] ~= entry then
      return
    end
    if now >= entry.expires_at - 1e-9 then
      clear_kind(entry.kind)
    end
  end

  local function mount_slot(kind, entry)
    modifier_dock:effect(kind, "ModifierSlot:" .. kind, function(es)
      if kind == "paralyze" then
        -- 亚秒级麻痹（0.5s）：仅在活跃槽位内按需订阅 on_frame，不重建 Effect，不退出 alive 相位。
        es:subscribe(clock.on_frame, function(frame)
          check_advance(entry, frame.now)
        end)
      elseif kind == "weak" then
        -- 长寿命虚弱（60s）：由 1 Hz on_second 驱动。
        es:subscribe(clock.on_second, function(sec)
          check_advance(entry, sec)
        end)
      else
        -- 短寿命（3s）poison / burn / frost：由 on_second 驱动整秒 DoT，并在活跃期内于 on_frame 精确对齐亚秒过期边界。
        es:subscribe(clock.on_second, function(sec)
          check_advance(entry, sec)
        end)
        es:subscribe(clock.on_frame, function(frame)
          check_advance(entry, frame.now)
        end)
      end

      if type(opts.on_mount_modifier_leaf) == "function" then
        opts.on_mount_modifier_leaf(es, player_tree, kind, entry)
      end

      es:on_cleanup(function()
        if active_effects[kind] == entry then
          active_effects[kind] = nil
          sync_flag(kind, false)
          modifier_signals[kind]:set(nil)
        end
      end)
    end)
  end

  local function apply_modifier(kind, apply_opts)
    if not VALID_KINDS[kind] or is_tree_disposed() then
      return false, "invalid-modifier-kind"
    end
    apply_opts = type(apply_opts) == "table" and apply_opts or {}
    local duration = apply_opts.duration
    if duration == nil then
      duration = default_duration(kind)
    end
    if not finite_positive(duration) then
      return false, "invalid-duration"
    end

    local now = clock.now()
    local existing = active_effects[kind]
    if existing and existing.paused_remaining == nil and now >= existing.expires_at - 1e-9 then
      drain_dot(existing, now)
      clear_kind(kind)
      existing = nil
    end

    local source = apply_opts.source
    local max_stacks = max_stacks_of(kind)
    local dot_cfg = dot_cfg_of(kind)

    if existing then
      -- 刷新已有效果：保留 DoT 跳伤相位（next_tick_at），更新末次来源，叠层按上限钳制。
      if max_stacks > 1 then
        existing.stacks = math.min(max_stacks, existing.stacks + 1)
      else
        existing.stacks = 1
      end
      existing.duration = duration
      existing.source = source
      existing.revision = existing.revision + 1
      if existing.paused_remaining ~= nil then
        existing.paused_remaining = duration
      else
        existing.expires_at = now + duration
      end
      SpokeRuntime.batch(function()
        sync_flag(kind, true)
        emit_signal(kind)
      end)
      return true
    end

    local paused_remaining = nil
    if kind == "weak" and apply_opts.pause_when_no_character ~= false and states.character:now() == nil then
      paused_remaining = duration
    end

    local entry = {
      kind = kind,
      stacks = 1,
      duration = duration,
      applied_at = now,
      expires_at = now + duration,
      next_tick_at = dot_cfg and (now + dot_cfg.TickSec) or nil,
      source = source,
      paused_remaining = paused_remaining,
      revision = 1,
    }
    active_effects[kind] = entry

    SpokeRuntime.batch(function()
      sync_flag(kind, true)
      emit_signal(kind)
      mount_slot(kind, entry)
    end)
    return true
  end

  local function clear_all(keep_weak)
    SpokeRuntime.batch(function()
      for _, kind in ipairs(ALL_KINDS) do
        if not (keep_weak and kind == "weak") then
          clear_kind(kind)
        end
      end
    end)
  end

  local function clear_by_source(source)
    if source == nil then
      return
    end
    SpokeRuntime.batch(function()
      for _, kind in ipairs(ALL_KINDS) do
        local entry = active_effects[kind]
        if entry and entry.source == source then
          clear_kind(kind)
        end
      end
    end)
  end

  local function capture_base_speed(character)
    local target = character ~= nil and character or states.character:now()
    local speed = read_walk_speed(target)
    if speed ~= nil and states.base_speed:now() == nil then
      states.base_speed:set(speed)
      return speed
    end
    return states.base_speed:now()
  end

  -- 角色切换/重建联动：
  --   - 捕获新角色基准移速（每个角色仅捕获一次，重建时重置再捕获）；
  --   - 角色缺失空窗期间暂停 weak 计时并清除其他非持久战斗效果，角色重建后恢复 weak 计时。
  local last_character = states.character:now()
  if last_character ~= nil then
    capture_base_speed(last_character)
  end

  s2:reaction("CharacterEffectsBridge", function(rs)
    local character = rs:d(states.character)
    if character == last_character then
      return
    end
    local prev_character = last_character
    last_character = character

    SpokeRuntime.batch(function()
      -- 角色移除或更换：重置基准速待新角色捕获
      states.base_speed:set(nil)
      if character ~= nil then
        capture_base_speed(character)
      end

      -- 角色离开/重建：清理非 weak 效果；weak 在无角色空窗冻结剩余秒数，有新角色后继续倒计时。
      for _, kind in ipairs(ALL_KINDS) do
        if kind ~= "weak" and active_effects[kind] then
          clear_kind(kind)
        end
      end

      local weak = active_effects.weak
      if weak then
        local now = clock.now()
        if character == nil then
          if weak.paused_remaining == nil then
            weak.paused_remaining = math.max(0, weak.expires_at - now)
            weak.revision = weak.revision + 1
            emit_signal("weak")
          end
        else
          if weak.paused_remaining ~= nil then
            local rem = math.max(0, weak.paused_remaining)
            weak.paused_remaining = nil
            if rem <= 0 then
              clear_kind("weak")
            else
              weak.duration = rem
              weak.expires_at = now + rem
              weak.revision = weak.revision + 1
              emit_signal("weak")
            end
          elseif prev_character ~= nil then
            local rem = math.max(0, weak.expires_at - now)
            if rem <= 0 then
              clear_kind("weak")
            else
              weak.duration = rem
              weak.expires_at = now + rem
              weak.revision = weak.revision + 1
              emit_signal("weak")
            end
          end
        end
      end
    end)
  end, { states.character })

  -- 若存档载入时带有历史 weakRemaining，初始化即纳入 PlayerTree 计时主权。
  local raw_survival = type(player_tree.data.Extra) == "table"
      and type(player_tree.data.Extra.survival) == "table"
      and player_tree.data.Extra.survival or nil
  local initial_weak = raw_survival and raw_survival.weakRemaining or 0
  if finite_positive(initial_weak) then
    local clamped = math.min(GameCfg.Survival.WeakSec, initial_weak)
    apply_modifier("weak", { duration = clamped })
  end

  -- 确定性属性派生链（严格遵守 AttrModel / BodyScale 单一公式）：
  memos.move_multiplier = s2:memo("MoveMultiplier", function(ms)
    if ms:d(states.is_paralyzed) then
      return 0
    end
    local mult = ms:d(states.is_weak) and GameCfg.Survival.WeakSpeedScale or 1
    if ms:d(states.is_frost) then
      local frost_cfg = GameCfg.Ability.StatusEffects and GameCfg.Ability.StatusEffects.frost
      local slow_pct = frost_cfg and frost_cfg.SlowPercent or 30
      mult = mult * (1 - slow_pct / 100)
    end
    return mult
  end)

  memos.attr_plan = s2:memo("AttrPlan", function(ms)
    local body_potions = ms:d(states.potion_big_count)
    local speed_potions = ms:d(states.potion_speed_count)
    local base_speed = ms:d(states.base_speed)
    local move_mult = ms:d(memos.move_multiplier)
    local hunger = ms:d(states.hunger)
    return AttrModel.Plan({
      bodyPotions = body_potions,
      speedPotions = speed_potions,
      baseSpeed = base_speed,
      moveMultiplier = move_mult,
      hunger = hunger,
    })
  end)

  memos.max_health = s2:memo("MaxHealth", function(ms)
    return ms:d(memos.attr_plan).Body.Health
  end)

  memos.body_scale = s2:memo("BodyScale", function(ms)
    return ms:d(memos.attr_plan).Body.Scale
  end)

  memos.body_scale_capped = s2:memo("BodyScaleCapped", function(ms)
    return ms:d(memos.attr_plan).Body.Capped == true
  end)

  memos.body_derived = s2:memo("BodyDerived", function(ms)
    return BodyScale.Derive(ms:d(memos.body_scale))
  end)

  memos.move_speed_scale = s2:memo("MoveSpeedScale", function(ms)
    return 1 + ms:d(memos.attr_plan).Attributes.PlayerWalkSpeed.Ratio
  end)

  memos.walk_speed = s2:memo("WalkSpeed", function(ms)
    local comp = ms:d(memos.attr_plan).Attributes.PlayerWalkSpeed
    return math.max(0, (comp.Base + comp.BaseExtra) * (1 + comp.Ratio) + comp.Bonus)
  end)

  memos.weapon_damage_components = s2:memo("WeaponDamageComponents", function(ms)
    local upgrades = ms:d(states.shop_upgrades) or {}
    return {
      melee = AttrModel.WeaponComponents("melee", upgrades.melee or 0),
      ranged = AttrModel.WeaponComponents("ranged", upgrades.ranged or 0),
      explosive = AttrModel.WeaponComponents("explosive", upgrades.explosive or 0),
    }
  end)

  memos.weapon_damage_scales = s2:memo("WeaponDamageScales", function(ms)
    local comps = ms:d(memos.weapon_damage_components)
    local function eval(c)
      return (c.Base + c.BaseExtra) * (1 + c.Ratio) + c.Bonus
    end
    return {
      melee = eval(comps.melee),
      ranged = eval(comps.ranged),
      explosive = eval(comps.explosive),
    }
  end)

  -- 暴露给外部与后续 A2 叶子层的清晰方法
  function player_tree:apply_modifier(kind, apply_opts)
    return apply_modifier(kind, apply_opts)
  end

  function player_tree:clear_modifier(kind)
    return clear_kind(kind)
  end

  function player_tree:clear_all_modifiers(keep_weak)
    clear_all(keep_weak)
  end

  function player_tree:clear_modifiers_by_source(source)
    clear_by_source(source)
  end

  function player_tree:get_modifier_remaining(kind)
    local entry = active_effects[kind]
    if not entry then
      return 0
    end
    return remaining_of(entry, clock.now())
  end

  function player_tree:get_modifier_stacks(kind)
    local entry = active_effects[kind]
    return entry and entry.stacks or 0
  end

  function player_tree:get_modifier_state(kind)
    return make_snapshot(active_effects[kind], clock.now())
  end

  function player_tree:capture_base_speed(character)
    return capture_base_speed(character)
  end
end

return PlayerEffects
