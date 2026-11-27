-- 服务端玩家属性派生与持续效果主权模块（ADR-0032 §1、§3 / #297-A1）：
-- 挂载在 PlayerTree Stage 2（Attributes）内，负责：
--   1. 接管 weak / poison / burn / frost / paralyze 的剩余时间、层数、末次来源与 DoT 结算主权；
--   2. 按 SpokeClock 驱动计时：weak 走 1 Hz on_second（角色空窗暂停、重建保留），
--      paralyze（0.5s 亚秒）走短寿命 on_frame 仅置 is_paralyzed=true（不退出 alive 相位），
--      poison / burn / frost 仅在活跃槽位内推进 DoT 与精准到期；
--   3. 确定性派生 AttrModel / BodyScale / weapon_components（max_health、body_scale、
--      body_derived、move_multiplier、move_speed_scale、walk_speed、weapon_damage_*）；
--   4. 为 A2 的 modifier_system 叶子投影预留 on_mount_modifier_leaf 纯输出挂点。
-- 本模块归属 L2（server.world_host），零反向依赖存量旧债务模块。

local GameCfg = require("common.game_cfg")
local AttrModel = require("common.attr_model")
local BodyScale = require("common.body_scale")
local Number = require("common.number")
local Spoke = require("common.packages.spoke.api")
local SpokeRuntime = require("common.packages.spoke.runtime.spoke_runtime")

local State = Spoke.State

local PlayerEffects = {}
-- 效果行为表：拆分前都是 PlayerEffects.mount 体内的闭包，依赖统一从树上的 effects_env 读取。
local EffectsBehavior = {}

local ALL_KINDS = { "poison", "burn", "frost", "paralyze", "weak" }
local VALID_KINDS = {
  poison = true,
  burn = true,
  frost = true,
  paralyze = true,
  weak = true,
}

local function finite_positive(value)
  return Number.is_finite_number(value) and value > 0
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

local function max_stacks_of(kind)
  local cfg = GameCfg.Ability.StatusEffects and GameCfg.Ability.StatusEffects[kind]
  if cfg and finite_positive(cfg.MaxStacks) then
    return math.floor(cfg.MaxStacks)
  end
  return 1
end

local function dot_cfg_of(kind)
  local cfg = GameCfg.Ability.StatusEffects and GameCfg.Ability.StatusEffects[kind]
  if cfg and finite_positive(cfg.TickSec) and Number.is_finite_number(cfg.DamagePerStack) then
    return cfg
  end
  return nil
end

-- 效果快照：对外只读投影，不暴露内部计时相位（next_tick_at / applied_at）。
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

local function remaining_of(entry, now)
  if not entry then
    return 0
  end
  if entry.paused_remaining ~= nil then
    return math.max(0, entry.paused_remaining)
  end
  return math.max(0, entry.expires_at - now)
end

-- ===== 环境与行为表 =====

-- 建效果环境：拆分前 mount 开头的状态引导与局部变量全部收进 env，行为方法只从 effects_env 取依赖。
function EffectsBehavior.new_env(player_tree, opts)
  opts = type(opts) == "table" and opts or {}

  local states = player_tree.states

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
        and type(player_tree.data.extra) == "table"
        and type(player_tree.data.extra.growth) == "table"
        and type(player_tree.data.extra.growth.upgrades) == "table"
        and player_tree.data.extra.growth.upgrades or {}
    states.shop_upgrades = State.new("PlayerTree.shop_upgrades", raw_upgrades)
  end

  local modifier_signals = {}
  for _, kind in ipairs(ALL_KINDS) do
    modifier_signals[kind] = State.new("PlayerEffects." .. kind, nil)
  end
  player_tree.modifier_signals = modifier_signals

  local env = {
    player_tree = player_tree,
    opts = opts,
    clock = player_tree.clock,
    states = states,
    memos = player_tree.memos,
    modifier_dock = player_tree.docks.modifiers,
    modifier_signals = modifier_signals,
    active_effects = {},
    last_character = states.character:now(),
  }
  player_tree.effects_env = env
  -- 挂载时已有角色则先捕获一次基准移速，与拆分前 mount 的执行顺序一致。
  if env.last_character ~= nil then
    EffectsBehavior.capture_base_speed(player_tree, env.last_character)
  end
  return env
end

function EffectsBehavior.is_tree_disposed(self)
  local tree = self.effects_env.player_tree.tree
  return tree ~= nil and tree.is_detached == true
end

function EffectsBehavior.sync_flag(self, kind, is_active)
  local states = self.effects_env.states
  if kind == "weak" then
    states.is_weak:set(is_active)
  elseif kind == "frost" then
    states.is_frost:set(is_active)
  elseif kind == "paralyze" then
    states.is_paralyzed:set(is_active)
  end
end

function EffectsBehavior.emit_signal(self, kind)
  local env = self.effects_env
  local entry = env.active_effects[kind]
  env.modifier_signals[kind]:set(make_snapshot(entry, env.clock.now()))
end

function EffectsBehavior.clear_kind(self, kind)
  local env = self.effects_env
  local active_effects, modifier_signals = env.active_effects, env.modifier_signals
  if not VALID_KINDS[kind] then
    return false
  end
  local existing = active_effects[kind]
  if not existing then
    EffectsBehavior.sync_flag(self, kind, false)
    modifier_signals[kind]:set(nil)
    return false
  end
  active_effects[kind] = nil
  SpokeRuntime.batch(function()
    EffectsBehavior.sync_flag(self, kind, false)
    modifier_signals[kind]:set(nil)
    if not EffectsBehavior.is_tree_disposed(self) then
      env.modifier_dock:drop(kind)
    end
  end)
  return true
end

function EffectsBehavior.drain_dot(self, entry, now)
  local env = self.effects_env
  local cfg = dot_cfg_of(entry.kind)
  if not cfg or entry.paused_remaining ~= nil then
    return
  end
  while entry.next_tick_at and entry.next_tick_at <= now and entry.next_tick_at <= entry.expires_at + 1e-9 do
    if env.active_effects[entry.kind] ~= entry or EffectsBehavior.is_tree_disposed(self) then
      return
    end
    entry.next_tick_at = entry.next_tick_at + cfg.TickSec
    local damage = entry.stacks * cfg.DamagePerStack
    if type(env.opts.on_dot_tick) == "function" then
      env.opts.on_dot_tick(env.player_tree, entry.kind, damage, entry.source, entry.stacks)
    end
  end
end

function EffectsBehavior.check_advance(self, entry, now)
  local active_effects = self.effects_env.active_effects
  if active_effects[entry.kind] ~= entry then
    return
  end
  if entry.paused_remaining ~= nil then
    return
  end
  EffectsBehavior.drain_dot(self, entry, now)
  if active_effects[entry.kind] ~= entry then
    return
  end
  if now >= entry.expires_at - 1e-9 then
    EffectsBehavior.clear_kind(self, entry.kind)
  end
end

function EffectsBehavior.mount_slot(self, kind, entry)
  local env = self.effects_env
  local clock = env.clock
  env.modifier_dock:effect(kind, "ModifierSlot:" .. kind, function(es)
    if kind == "paralyze" then
      -- 亚秒级麻痹（0.5s）：仅在活跃槽位内按需订阅 on_frame，不重建 Effect，不退出 alive 相位。
      es:subscribe(clock.on_frame, function(frame)
        EffectsBehavior.check_advance(self, entry, frame.now)
      end)
    elseif kind == "weak" then
      -- 长寿命虚弱（60s）：由 1 Hz on_second 驱动。
      es:subscribe(clock.on_second, function(sec)
        EffectsBehavior.check_advance(self, entry, sec)
      end)
    else
      -- 短寿命（3s）poison / burn / frost：由 on_second 驱动整秒 DoT，并在活跃期内于 on_frame 精确对齐亚秒过期边界。
      es:subscribe(clock.on_second, function(sec)
        EffectsBehavior.check_advance(self, entry, sec)
      end)
      es:subscribe(clock.on_frame, function(frame)
        EffectsBehavior.check_advance(self, entry, frame.now)
      end)
    end

    if type(env.opts.on_mount_modifier_leaf) == "function" then
      env.opts.on_mount_modifier_leaf(es, env.player_tree, kind, entry)
    end

    es:on_cleanup(function()
      if env.active_effects[kind] == entry then
        env.active_effects[kind] = nil
        EffectsBehavior.sync_flag(self, kind, false)
        env.modifier_signals[kind]:set(nil)
      end
    end)
  end)
end

function EffectsBehavior.apply_modifier(self, kind, apply_opts)
  local env = self.effects_env
  local active_effects, states, clock = env.active_effects, env.states, env.clock
  if not VALID_KINDS[kind] or EffectsBehavior.is_tree_disposed(self) then
    return false, "invalid-modifier-kind"
  end
  apply_opts = type(apply_opts) == "table" and apply_opts or {}
  local duration = apply_opts.duration
  if duration == nil then
    duration = GameCfg.status_duration(kind)
  end
  if not finite_positive(duration) then
    return false, "invalid-duration"
  end

  local now = clock.now()
  local existing = active_effects[kind]
  if existing and existing.paused_remaining == nil and now >= existing.expires_at - 1e-9 then
    EffectsBehavior.drain_dot(self, existing, now)
    EffectsBehavior.clear_kind(self, kind)
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
      EffectsBehavior.sync_flag(self, kind, true)
      EffectsBehavior.emit_signal(self, kind)
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
    EffectsBehavior.sync_flag(self, kind, true)
    EffectsBehavior.emit_signal(self, kind)
    EffectsBehavior.mount_slot(self, kind, entry)
  end)
  return true
end

function EffectsBehavior.clear_modifier(self, kind)
  return EffectsBehavior.clear_kind(self, kind)
end

function EffectsBehavior.clear_all(self, keep_weak)
  SpokeRuntime.batch(function()
    for _, kind in ipairs(ALL_KINDS) do
      if not (keep_weak and kind == "weak") then
        EffectsBehavior.clear_kind(self, kind)
      end
    end
  end)
end

function EffectsBehavior.clear_all_modifiers(self, keep_weak)
  EffectsBehavior.clear_all(self, keep_weak)
end

function EffectsBehavior.clear_by_source(self, source)
  local env = self.effects_env
  if source == nil then
    return
  end
  SpokeRuntime.batch(function()
    for _, kind in ipairs(ALL_KINDS) do
      local entry = env.active_effects[kind]
      if entry and entry.source == source then
        EffectsBehavior.clear_kind(self, kind)
      end
    end
  end)
end

function EffectsBehavior.clear_modifiers_by_source(self, source)
  EffectsBehavior.clear_by_source(self, source)
end

function EffectsBehavior.capture_base_speed(self, character)
  local states = self.effects_env.states
  local target = character ~= nil and character or states.character:now()
  local speed = read_walk_speed(target)
  if speed ~= nil and states.base_speed:now() == nil then
    states.base_speed:set(speed)
    return speed
  end
  return states.base_speed:now()
end

function EffectsBehavior.get_modifier_remaining(self, kind)
  local env = self.effects_env
  return remaining_of(env.active_effects[kind], env.clock.now())
end

function EffectsBehavior.get_modifier_stacks(self, kind)
  local entry = self.effects_env.active_effects[kind]
  return entry and entry.stacks or 0
end

function EffectsBehavior.get_modifier_state(self, kind)
  local env = self.effects_env
  return make_snapshot(env.active_effects[kind], env.clock.now())
end

-- ===== 装配 =====

-- 挂回玩家树的方法：名字与签名沿用拆分前的接口（外部以 :method(...) 调用）。
local TREE_METHODS = {
  "apply_modifier",
  "clear_modifier",
  "clear_all_modifiers",
  "clear_modifiers_by_source",
  "get_modifier_remaining",
  "get_modifier_stacks",
  "get_modifier_state",
  "capture_base_speed",
}

-- 把行为表挂到玩家树上；依赖统一从 tree.effects_env 读取。
function EffectsBehavior.install(tree)
  for _, name in ipairs(TREE_METHODS) do
    tree[name] = EffectsBehavior[name]
  end
end

-- Spoke 作用域接线：角色桥、存档历史 weak、属性派生 memo，注册顺序与拆分前 mount 一致。
-- 角色切换窗口内的 weak 计时：无角色时冻结剩余秒数，角色回来或换人时按各自口径续算。
local function sync_weak_window(tree, weak, character, prev_character)
  local env = tree.effects_env
  local now = env.clock.now()
  if character == nil then
    if weak.paused_remaining == nil then
      weak.paused_remaining = math.max(0, weak.expires_at - now)
      weak.revision = weak.revision + 1
      EffectsBehavior.emit_signal(tree, "weak")
    end
    return
  end
  if weak.paused_remaining ~= nil then
    local rem = math.max(0, weak.paused_remaining)
    weak.paused_remaining = nil
    if rem <= 0 then
      EffectsBehavior.clear_kind(tree, "weak")
    else
      weak.duration = rem
      weak.expires_at = now + rem
      weak.revision = weak.revision + 1
      EffectsBehavior.emit_signal(tree, "weak")
    end
    return
  end
  if prev_character ~= nil then
    ---@type number
    local rem = math.max(0, weak.expires_at - now)
    if rem <= 0 then
      EffectsBehavior.clear_kind(tree, "weak")
    else
      weak.duration = rem
      weak.expires_at = now + rem
      weak.revision = weak.revision + 1
      EffectsBehavior.emit_signal(tree, "weak")
    end
  end
end

function EffectsBehavior.wire(s2, tree)
  local env = tree.effects_env
  local states, memos = env.states, env.memos
  local active_effects = env.active_effects

  -- 角色切换/重建联动：
  --   - 捕获新角色基准移速（每个角色仅捕获一次，重建时重置再捕获）；
  --   - 角色缺失空窗期间暂停 weak 计时并清除其他非持久战斗效果，角色重建后恢复 weak 计时。
  s2:reaction("CharacterEffectsBridge", function(rs)
    local character = rs:d(states.character)
    if character == env.last_character then
      return
    end
    local prev_character = env.last_character
    env.last_character = character

    SpokeRuntime.batch(function()
      -- 角色移除或更换：重置基准速待新角色捕获
      states.base_speed:set(nil)
      if character ~= nil then
        EffectsBehavior.capture_base_speed(tree, character)
      end

      -- 角色离开/重建：清理非 weak 效果；weak 在无角色空窗冻结剩余秒数，有新角色后继续倒计时。
      for _, kind in ipairs(ALL_KINDS) do
        if kind ~= "weak" and active_effects[kind] then
          EffectsBehavior.clear_kind(tree, kind)
        end
      end

      local weak = active_effects.weak
      if weak then
        sync_weak_window(tree, weak, character, prev_character)
      end
    end)
  end, { states.character })

  -- 若存档载入时带有历史 weakRemaining，初始化即纳入 PlayerTree 计时主权。
  local raw_survival = type(env.player_tree.data.extra) == "table"
      and type(env.player_tree.data.extra.survival) == "table"
      and env.player_tree.data.extra.survival or nil
  local initial_weak = raw_survival and raw_survival.weakRemaining or 0
  if finite_positive(initial_weak) then
    local clamped = math.min(GameCfg.Survival.WeakSec, initial_weak)
    EffectsBehavior.apply_modifier(tree, "weak", { duration = clamped })
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
    return AttrModel.plan({
      bodyPotions = body_potions,
      speedPotions = speed_potions,
      baseSpeed = base_speed,
      moveMultiplier = move_mult,
      hunger = hunger,
    })
  end)

  memos.max_health = s2:memo("MaxHealth", function(ms)
    return ms:d(memos.attr_plan).body.Health
  end)

  memos.body_scale = s2:memo("BodyScale", function(ms)
    return ms:d(memos.attr_plan).body.Scale
  end)

  memos.body_scale_capped = s2:memo("BodyScaleCapped", function(ms)
    return ms:d(memos.attr_plan).body.capped == true
  end)

  memos.body_derived = s2:memo("BodyDerived", function(ms)
    return BodyScale.derive(ms:d(memos.body_scale))
  end)

  memos.move_speed_scale = s2:memo("MoveSpeedScale", function(ms)
    return 1 + ms:d(memos.attr_plan).attributes.PlayerWalkSpeed.Ratio
  end)

  memos.walk_speed = s2:memo("WalkSpeed", function(ms)
    local comp = ms:d(memos.attr_plan).attributes.PlayerWalkSpeed
    return math.max(0, (comp.Base + comp.BaseExtra) * (1 + comp.Ratio) + comp.Bonus)
  end)

  memos.weapon_damage_components = s2:memo("WeaponDamageComponents", function(ms)
    local upgrades = ms:d(states.shop_upgrades) or {}
    return {
      melee = AttrModel.weapon_components("melee", upgrades.melee or 0),
      ranged = AttrModel.weapon_components("ranged", upgrades.ranged or 0),
      explosive = AttrModel.weapon_components("explosive", upgrades.explosive or 0),
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
end

-- 挂载效果模块：先建环境并装配行为表，再按拆分前的顺序接角色桥、历史 weak 与派生 memo。
---@param s2 table Stage 2 EffectBuilder
---@param player_tree table
---@param opts? table
function PlayerEffects.mount(s2, player_tree, opts)
  EffectsBehavior.new_env(player_tree, opts)
  EffectsBehavior.install(player_tree)
  EffectsBehavior.wire(s2, player_tree)
end

return PlayerEffects
