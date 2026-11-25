-- 服务端 modifier_system 官方包单向输出叶子投影层（ADR-0032 §3 / #297-A2）：
--   1. 订阅 PlayerEffects 暴露的槽位/效果信号单向调用 AddModifier（强制 removeMode = 0），
--      禁用包内 DurationFinish / ModifierLoss 业务计时驱动，所有计时与层数主权归 PlayerEffects + SpokeClock；
--   2. 在同作用域 s:on_cleanup 中对称调用 RemoveModifier，角色重建与树销毁零残留；
--   3. 提供独立轻量的活鱼 / 非玩家实体效果施加与清理辅助接口（create_entity_store），
--      同样遵循 removeMode = 0 与业务时钟主权，供淘汰 MgrModifier 时无缝承接活鱼受击。
-- 本模块归属 L2（server.world_host），零反向依赖存量旧债务模块。

local GameCfg = require("common.game_cfg")
local Number = require("common.number")

local ModifierLeaf = {}

local ALL_KINDS = { "poison", "burn", "frost", "paralyze", "weak" }
local VALID_KINDS = {
  poison = true,
  burn = true,
  frost = true,
  paralyze = true,
  weak = true,
}

local function is_object(value)
  local kind = type(value)
  return kind == "table" or kind == "userdata"
end

local function default_modifier_api()
  return require("server.packages.modifier_system.api")
end

local function report_error(opts, tag, msg)
  if type(opts.on_error) == "function" then
    opts.on_error(tag .. ": " .. tostring(msg))
  else
    print("[ModifierLeaf]", tag, tostring(msg))
  end
end

local function resolve_source_unit(source)
  if not is_object(source) then
    return nil
  end
  local ok, ch = pcall(function() return source.Character end) -- 兼容引擎 userdata 玩家对象读取 Character
  if ok and is_object(ch) then
    return ch
  end
  return source
end

local function preset_for(kind, opts)
  local presets = (type(opts) == "table" and opts.presets) or GameCfg.Ability.ModifierPresets or {}
  local preset = presets[kind]
  if type(preset) ~= "string" or preset == "" then
    return nil
  end
  return preset
end

--- 构造单向传给 modifier_system.AddModifier 的配置表（强制 removeMode = 0）。
---@param kind string
---@param duration number
---@param source any
---@return table
function ModifierLeaf.build_add_config(kind, duration, source)
  local cfg = GameCfg.Ability.StatusEffects and GameCfg.Ability.StatusEffects[kind]
  local max_stacks = (cfg and Number.is_finite_number(cfg.MaxStacks) and cfg.MaxStacks > 0)
      and math.floor(cfg.MaxStacks) or 1
  local stack_count_mode = max_stacks > 1 and 2 or 0
  return {
    duration = duration,
    stackable = true,
    maxStackCount = max_stacks,
    stackCountStep = 1,
    stackCountMode = stack_count_mode,
    stackDurationMode = 1,
    sameSourceStack = false,
    removeMode = 0, -- 强制禁用引擎死亡信号私自清理效果（ADR-0032 / #177）
    source = resolve_source_unit(source),
    attrConfigs = {},
    obtainPerformanceList = {},
    lostPerformanceList = {},
  }
end

local function is_add_ok(modifier_api, result)
  local enum = modifier_api.Enums and modifier_api.Enums.CreateResult
  if type(enum) == "table" then
    return result == enum.Added or result == enum.Reobtained
  end
  return result == "Added" or result == "Reobtained" or result == true
end

local function safe_remove_entity(modifier_api, entity)
  if entity == nil then
    return
  end
  pcall(modifier_api.RemoveModifier, entity) -- 角色或载体已销毁时官方包实体可能已失效
end

--- 单向向目标拥有者施加一次效果并返回官方包效果实体（不挂接包内事件监听）。
---@param modifier_api table
---@param owner any
---@param kind string
---@param duration number
---@param source any
---@param opts? table
---@return any entity, string|nil err
function ModifierLeaf.push_modifier(modifier_api, owner, kind, duration, source, opts)
  if not is_object(owner) then
    return nil, "no-owner"
  end
  local preset = preset_for(kind, opts)
  if not preset then
    return nil, "modifier-preset-missing:" .. tostring(kind)
  end
  if not Number.is_finite_number(duration) or duration <= 0 then
    return nil, "invalid-duration"
  end
  local add_cfg = ModifierLeaf.build_add_config(kind, duration, source)
  local ok_add, result = pcall(modifier_api.AddModifier, owner, preset, add_cfg)
  if not ok_add then
    return nil, tostring(result)
  end
  if not is_add_ok(modifier_api, result) then
    return nil, tostring(result)
  end
  local ok_get, list = pcall(modifier_api.GetUnitModifiers, owner, preset)
  local entity = ok_get and type(list) == "table" and list[1] or nil
  if not entity then
    return nil, "modifier-instance-missing"
  end
  return entity, nil
end

--- 将单个效果槽位投影到 modifier_system 官方包（供 PlayerEffects.mount 的 on_mount_modifier_leaf 调用）。
---@param es table EffectBuilder
---@param player_tree table
---@param kind string
---@param _entry? table
---@param opts? { modifier_api?: table, presets?: table, on_error?: fun(msg: string) }
function ModifierLeaf.mount_slot(es, player_tree, kind, _entry, opts)
  if not VALID_KINDS[kind] then
    return
  end
  opts = type(opts) == "table" and opts or {}
  local modifier_api = opts.modifier_api or default_modifier_api()
  local char_sig = player_tree.states and player_tree.states.character
  local mod_sig = player_tree.modifier_signals and player_tree.modifier_signals[kind]
  if not char_sig or not mod_sig then
    return
  end

  local active_memo = es:memo("ModifierLeafActive:" .. kind, function(ms)
    local snap = ms:d(mod_sig)
    return type(snap) == "table" and not snap.paused and (snap.remaining or 0) > 0
  end)

  return es:effect("Leaf:ModifierSink:" .. kind, function(ls)
    local character = ls:d(char_sig)
    local is_active = ls:d(active_memo)
    if not is_object(character) or not is_active then
      return
    end

    local snap = mod_sig:now()
    if type(snap) ~= "table" or snap.paused then
      return
    end

    local duration = Number.is_finite_number(snap.remaining) and snap.remaining > 0
        and snap.remaining or snap.duration
    local entity, err = ModifierLeaf.push_modifier(modifier_api, character, kind, duration, snap.source, opts)
    if not entity then
      report_error(opts, "AddModifier(" .. kind .. ")", err)
      return
    end

    local applied_revision = snap.revision
    ls:on_cleanup(function()
      safe_remove_entity(modifier_api, entity)
      entity = nil
    end)

    -- 同一角色与活跃周期内叠层/刷新：仅单向同步刷新官方包实体，不重走清理-重建导致层数闪烁。
    ls:reaction("SyncModifierSink:" .. kind, function(rs)
      local next_snap = rs:d(mod_sig)
      if type(next_snap) ~= "table" or next_snap.paused or next_snap.revision == applied_revision then
        return
      end
      applied_revision = next_snap.revision
      local next_dur = Number.is_finite_number(next_snap.remaining) and next_snap.remaining > 0
          and next_snap.remaining or next_snap.duration
      local updated, update_err = ModifierLeaf.push_modifier(
        modifier_api,
        character,
        kind,
        next_dur,
        next_snap.source,
        opts
      )
      if updated then
        entity = updated
      else
        report_error(opts, "RefreshModifier(" .. kind .. ")", update_err)
      end
    end, { mod_sig })
  end)
end

--- 返回可直接注入 PlayerEffects.mount({ on_mount_modifier_leaf = ... }) 的挂点回调。
---@param opts? { modifier_api?: table, presets?: table, on_error?: fun(msg: string) }
---@return fun(es: table, player_tree: table, kind: string, entry: table)
function ModifierLeaf.make_slot_mounter(opts)
  return function(es, player_tree, kind, entry)
    return ModifierLeaf.mount_slot(es, player_tree, kind, entry, opts)
  end
end

--- 一次性为全部 5 类持续效果挂载叶子投影（当调用方未走 on_mount_modifier_leaf 时使用）。
---@param s table EffectBuilder
---@param player_tree table
---@param opts? { modifier_api?: table, presets?: table, on_error?: fun(msg: string) }
function ModifierLeaf.mount(s, player_tree, opts)
  for _, kind in ipairs(ALL_KINDS) do
    ModifierLeaf.mount_slot(s, player_tree, kind, nil, opts)
  end
end

-- ============================================================================
-- 独立轻量的活鱼 / 非玩家实体效果施加与清理辅助接口（供 A3 淘汰 MgrModifier 时承接）
-- ============================================================================

local function resolve_entity_owner(target, allow_dead)
  if not is_object(target) then
    return nil, nil, nil
  end
  local ok_carrier, carrier = pcall(function() return target.carrier end) -- 兼容引擎 userdata 直接作为非玩家目标
  if ok_carrier and is_object(carrier) then
    local ok_dead, dead = pcall(function() return carrier.dead end) -- 兼容只读载体字段
    if not allow_dead and ok_dead and dead then
      return nil, nil, carrier
    end
    local owner = carrier.receiver or carrier.body
    return carrier, owner, carrier
  end
  return target, target, nil
end

local function default_duration_for(kind)
  if kind == "weak" then
    return GameCfg.Survival.WeakSec
  end
  local cfg = GameCfg.Ability.StatusEffects and GameCfg.Ability.StatusEffects[kind]
  return cfg and cfg.DurationSec or 0
end

local function max_stacks_for(kind)
  local cfg = GameCfg.Ability.StatusEffects and GameCfg.Ability.StatusEffects[kind]
  if cfg and Number.is_finite_number(cfg.MaxStacks) and cfg.MaxStacks > 0 then
    return math.floor(cfg.MaxStacks)
  end
  return 1
end

local function dot_cfg_for(kind)
  local cfg = GameCfg.Ability.StatusEffects and GameCfg.Ability.StatusEffects[kind]
  if cfg and Number.is_finite_number(cfg.TickSec) and cfg.TickSec > 0 and Number.is_finite_number(cfg.DamagePerStack) then
    return cfg
  end
  return nil
end

--- 创建独立轻量的非玩家实体（活鱼等）效果存储与单向叶子投影器。
---@param opts? table { modifier_api?: table, presets?: table, now?: function, on_dot_tick?: function, on_error?: function }
function ModifierLeaf.create_entity_store(opts)
  opts = type(opts) == "table" and opts or {}
  local modifier_api = opts.modifier_api or default_modifier_api()
  if type(opts.now) ~= "function" then
    error("[ModifierLeaf] create_entity_store 需要注入有效的 now 时钟函数", 2)
  end
  local get_now = opts.now

  local records = {}
  local store = {}

  local function remove_entry_kind(record, kind)
    local st = record.effects[kind]
    if not st then
      return false
    end
    record.effects[kind] = nil
    safe_remove_entity(modifier_api, st.entity)
    if next(record.effects) == nil and records[record.key] == record then
      records[record.key] = nil
    end
    return true
  end

  local function drain_entry_dot(record, kind, st, now)
    local cfg = dot_cfg_for(kind)
    if not cfg then
      return
    end
    while st.next_tick_at and st.next_tick_at <= now and st.next_tick_at <= st.expires_at + 1e-9 do
      if record.carrier and record.carrier.dead then
        return
      end
      if records[record.key] ~= record or record.effects[kind] ~= st then
        return
      end
      st.next_tick_at = st.next_tick_at + cfg.TickSec
      if type(opts.on_dot_tick) == "function" then
        opts.on_dot_tick(record.target, kind, st.stacks * cfg.DamagePerStack, st.source, st.stacks)
      end
    end
  end

  function store:apply(source, target, kind, duration_override)
    if not VALID_KINDS[kind] then
      return false, "invalid-modifier-kind"
    end
    local key, owner, carrier = resolve_entity_owner(target)
    if not key or not is_object(owner) then
      return false, "no-effect-owner"
    end
    local duration = duration_override ~= nil and duration_override or default_duration_for(kind)
    if not Number.is_finite_number(duration) or duration <= 0 then
      return false, "invalid-duration"
    end

    local record = records[key]
    if record and record.owner ~= owner then
      self:clear_target(target)
      record = nil
    end
    if not record then
      record = { key = key, target = target, owner = owner, carrier = carrier, effects = {} }
      records[key] = record
    end

    local now = get_now()
    local existing = record.effects[kind]
    if existing and now >= existing.expires_at - 1e-9 then
      drain_entry_dot(record, kind, existing, now)
      remove_entry_kind(record, kind)
      existing = nil
      if records[key] == nil then
        records[key] = record
      end
    end

    local entity, err = ModifierLeaf.push_modifier(modifier_api, owner, kind, duration, source, opts)
    if not entity then
      if next(record.effects) == nil then
        records[key] = nil
      end
      report_error(opts, "EntityAddModifier(" .. kind .. ")", err)
      return false, err
    end

    local max_stacks = max_stacks_for(kind)
    local dot_cfg = dot_cfg_for(kind)
    if existing then
      existing.entity = entity
      existing.source = source
      existing.stacks = max_stacks > 1 and math.min(max_stacks, existing.stacks + 1) or 1
      existing.expires_at = now + duration
    else
      record.effects[kind] = {
        entity = entity,
        source = source,
        stacks = 1,
        expires_at = now + duration,
        next_tick_at = dot_cfg and (now + dot_cfg.TickSec) or nil,
      }
    end
    return true, nil
  end

  function store:apply_weapon_effect(source, target, effect)
    return self:apply(source, target, type(effect) == "table" and effect.Kind or nil)
  end

  function store:step(now_override)
    local now = now_override ~= nil and now_override or get_now()
    local snapshot = {}
    for _, record in pairs(records) do
      snapshot[#snapshot + 1] = record
    end
    for _, record in ipairs(snapshot) do
      if records[record.key] == record then
        if record.carrier and record.carrier.dead then
          self:clear_target(record.target)
        else
          for _, kind in ipairs(ALL_KINDS) do
            local st = record.effects[kind]
            if st then
              drain_entry_dot(record, kind, st, now)
              if records[record.key] == record and record.effects[kind] == st and now >= st.expires_at - 1e-9 then
                remove_entry_kind(record, kind)
              end
            end
          end
        end
      end
    end
  end

  function store:get_remaining(target, kind)
    local key = resolve_entity_owner(target)
    local record = key and records[key]
    local st = record and record.effects[kind]
    if not st then
      return 0
    end
    return math.max(0, st.expires_at - get_now())
  end

  function store:is_controlled(target)
    return self:get_remaining(target, "paralyze") > 0
  end

  function store:get_move_multiplier(target)
    if self:is_controlled(target) then
      return 0
    end
    local mult = self:get_remaining(target, "weak") > 0 and GameCfg.Survival.WeakSpeedScale or 1
    if self:get_remaining(target, "frost") > 0 then
      local frost_cfg = GameCfg.Ability.StatusEffects and GameCfg.Ability.StatusEffects.frost
      local slow_pct = frost_cfg and frost_cfg.SlowPercent or 30
      mult = mult * (1 - slow_pct / 100)
    end
    return mult
  end

  function store:clear(target, kind)
    local key = resolve_entity_owner(target, true)
    local record = key and records[key]
    if not record then
      return false
    end
    return remove_entry_kind(record, kind)
  end

  function store:clear_target(target)
    local key = resolve_entity_owner(target, true)
    local record = key and records[key]
    if not record then
      return
    end
    for _, kind in ipairs(ALL_KINDS) do
      remove_entry_kind(record, kind)
    end
    records[key] = nil
  end

  function store:clear_by_source(source)
    if source == nil then
      return
    end
    local snapshot = {}
    for _, record in pairs(records) do
      snapshot[#snapshot + 1] = record
    end
    for _, record in ipairs(snapshot) do
      if records[record.key] == record then
        for _, kind in ipairs(ALL_KINDS) do
          local st = record.effects[kind]
          if st and st.source == source then
            remove_entry_kind(record, kind)
          end
        end
      end
    end
  end

  function store:clear_all()
    local snapshot = {}
    for _, record in pairs(records) do
      snapshot[#snapshot + 1] = record
    end
    for _, record in ipairs(snapshot) do
      for _, kind in ipairs(ALL_KINDS) do
        remove_entry_kind(record, kind)
      end
      records[record.key] = nil
    end
  end

  return store
end

return ModifierLeaf
