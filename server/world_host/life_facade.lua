local EngineRead = require("common.engine_read")
local GameCfg = require("common.game_cfg")
local Number = require("common.number")

local LifeFacade = {}

local function read_character(player)
  local ok, ch = EngineRead.read_character(player, "LifeFacade.read_character")
  if ok then
    return ch
  end
  return nil
end

-- 生命门面（LifeFacade）：
-- 统一经 L3 common.engine_read 读取/校验玩家、角色、位置与控制器血量，
-- 与 ServerRuntime 共用同一引擎对象读取边界，不再保留本地静默 pcall 兜底。
-- 内部 helper 约定：
--   1. tree_of(player)：经 EngineRead.read_user_id 读取并校验玩家子树存活；
--   2. player_from_unit(unit)：在活跃玩家列表内匹配单位本体或其当前角色；
--   3. set_health(player, value)：经 EngineRead.write_health 写入并回读确认后再提交权威状态；
--   4. rescue_action(player, payload)：经 EngineRead.read_user_id 与 read_player_position 校距。
--
-- 对外门面接口：
--   get_tree / player_from_unit / life_status / is_downed / is_rescuing / player_by_user_id /
--   is_dead / can_act / can_take_damage / can_eat / eat / max_health_of / snapshot_health /
--   set_damage_filter / new_hit / resolve_hit_source / apply_hit / apply_damage / set_health /
--   set_hunger / phase / get_state / rescue_action / can_rescue / begin_rescue / cancel_rescue /
--   request_action / weapon_action / weapon_cast_guard。

---@param ctx table
function LifeFacade.new(ctx)
  local player_trees = ctx.player_trees
  local active_players = ctx.active_players
  local weapon_sessions = ctx.weapon_sessions
  local opts = ctx.opts or {}
  local get_max_health_of = ctx.get_max_health_of
  local get_damage_filter = ctx.get_damage_filter
  local set_damage_filter = ctx.set_damage_filter

  local hit_seq = 0
  local life = {}

  local function tree_of(player)
    local ok, uid = EngineRead.read_user_id(player, "LifeFacade.tree_of")
    if not ok then return nil end
    local tree = player_trees[uid]
    if tree and not tree:is_disposed() then return tree end
    return nil
  end

  local function player_from_unit(unit)
    if not EngineRead.is_object(unit) then return nil end
    for _, player in pairs(active_players) do
      if player == unit or read_character(player) == unit then return player end
    end
    return nil
  end

  function life:get_tree(player)
    return tree_of(player)
  end

  function life:player_from_unit(unit)
    return player_from_unit(unit)
  end

  function life:life_status(player)
    local tree = tree_of(player)
    return tree and tree.states.life_phase:now() or nil
  end

  function life:is_downed(player)
    local phase = self:life_status(player)
    return phase == "downed" or phase == "rescuing"
  end

  function life:is_rescuing(player)
    return self:life_status(player) == "rescuing"
  end

  function life:player_by_user_id(user_id)
    for _, player in pairs(active_players) do
      if user_id ~= nil and select(2, EngineRead.read_user_id(player, "LifeFacade.player_by_user_id")) == user_id then return player end
    end
    return nil
  end

  function life:is_dead(player)
    return self:life_status(player) == "dead"
  end

  function life:can_act(player)
    local tree = tree_of(player)
    return tree ~= nil and tree.memos.can_act:now() == true
  end

  function life:can_take_damage(player)
    return self:life_status(player) == "alive"
  end

  function life:can_eat(player, item_id)
    local tree = tree_of(player)
    if not tree or tree.memos.can_act:now() ~= true then return false end
    local definition = type(item_id) == "string" and GameCfg.Items.Definitions[item_id]
    return type(definition) == "table" and type(definition.EatPercent) == "number"
  end

  function life:eat(player, item_id, cook_rate)
    local tree = tree_of(player)
    if not tree then return false end
    return tree:eat(item_id, cook_rate)
  end

  function life:max_health_of(player)
    local max_health_of = get_max_health_of and get_max_health_of() or nil
    if type(max_health_of) == "function" then
      local ok, value = pcall(max_health_of, player)
      if ok and Number.is_finite_number(value) and value >= 1 then return math.floor(value) end
    end
    local tree = tree_of(player)
    local value = tree and tree.memos.max_health and tree.memos.max_health:now()
    if Number.is_finite_number(value) and value >= 1 then return math.floor(value) end
    return GameCfg.Vitals.MaxHealth
  end

  function life:snapshot_health(player)
    local tree = tree_of(player)
    if not tree then return nil, nil end
    return math.max(0, math.floor(tree.states.health:now())), self:max_health_of(player)
  end

  function life:set_damage_filter(filter)
    if set_damage_filter then set_damage_filter(filter) end
    for _, tree in pairs(player_trees) do
      if tree.set_damage_filter then tree:set_damage_filter(filter or false) end
    end
  end

  function life:new_hit(source, category)
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

  function life:resolve_hit_source(hit)
    return type(hit) == "table" and hit.sourcePlayer or nil
  end

  function life:apply_hit(hit, target, amount)
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

  function life:apply_damage(player, amount, hit)
    local ok = self:apply_hit(hit or self:new_hit(nil, "damage"), player, amount)
    return ok
  end

  function life:set_health(player, value)
    local tree = tree_of(player)
    if not tree or not Number.is_finite_number(value) then
      return false
    end
    local current = tree.states.health:now()
    if value < current then
      return self:apply_damage(player, current - value, self:new_hit(nil, "gm"))
    end
    if not EngineRead.write_health(
      player, value,
      { context = "LifeFacade.set_health", logger = opts.logger }
    ) then
      return false
    end
    tree.states.health:set(value)
    return true
  end

  function life:set_hunger(player, value)
    local tree = tree_of(player)
    if not tree or not Number.is_finite_number(value) then return false end
    local clamped = math.max(0, math.min(GameCfg.Vitals.MaxHunger, math.floor(value)))
    tree.states.hunger:set(clamped)
    return true
  end

  function life:phase(player)
    return self:life_status(player)
  end

  function life:get_state(player)
    local tree = tree_of(player)
    if not tree then return nil end
    return { player = player, phase = tree.states.life_phase:now(), tree = tree }
  end

  function life:rescue_action(player, payload)
    if type(payload) ~= "table" or payload.action ~= GameCfg.Rescue.Action then return false end
    local seq = payload.seq
    if not Number.is_finite_number(seq) or seq ~= math.floor(seq) or seq < 1 or seq > 2147483647 then return false end
    local function reply(result)
      if opts.remote and type(opts.remote.get_re) == "function" then
        opts.remote:get_re("InteractResult"):FireClient(player, result)
      end
      return result
    end
    if not Number.is_finite_number(payload.targetUserId) then
      reply({ action = "Rescue", ok = false, reason = "invalid", seq = seq })
      return false
    end
    local data, save = opts.player_data and opts.player_data:get_data_inst(player), opts.save
    if not data or not save then return false end
    local request_id = payload.operation
    if request_id ~= nil and type(request_id) ~= "table" then return false end
    if request_id == nil then request_id = seq end
    local operation, mode = save:resolve_request(player, data, "rescue", request_id)
    if not operation then return false end
    if mode == "replay" then
      return save:execute(player, data, operation, function() return nil, "expired" end,
        function(ok, result) if ok then result.operation = operation reply(result) end end) == true
    end
    local target = nil
    for _, candidate in pairs(active_players) do
      local ok_uid, uid = EngineRead.read_user_id(candidate, "LifeFacade.rescue_action")
      if ok_uid and uid == payload.targetUserId then
        target = candidate
        break
      end
    end
    local ok_tuid, target_uid = EngineRead.read_user_id(target, "LifeFacade.rescue_action")
    local target_tree = ok_tuid and player_trees[target_uid]
    local phase = target_tree and target_tree.states.life_phase:now()
    if not target or not ok_tuid or (phase ~= "downed" and phase ~= "rescuing") then
      reply({ action = "Rescue", ok = false, reason = "not-downed", seq = seq, targetUserId = payload.targetUserId })
      return false
    end
    local ok_from, from = EngineRead.read_player_position(player, "LifeFacade.rescue_action.from")
    local ok_to, to = EngineRead.read_player_position(target, "LifeFacade.rescue_action.to")
    if not ok_from or not ok_to or not from or not to then
      reply({ action = "Rescue", ok = false, reason = "no-position", seq = seq, targetUserId = target_uid })
      return false
    end
    local dx, dz = from.x - to.x, from.z - to.z
    if math.sqrt(dx * dx + dz * dz) > GameCfg.Rescue.Range then
      reply({ action = "Rescue", ok = false, reason = "too-far", seq = seq, targetUserId = target.UserId })
      return false
    end
    local can, reason = self:can_rescue(target, player)
    if not can then
      reply({ action = "Rescue", ok = false, reason = reason, seq = seq, targetUserId = target.UserId })
      return false
    end
    local started, why = self:begin_rescue(target, player)
    return save:execute(player, data, operation, function() return { ok = started == true, action = "Rescue", targetUserId = target.UserId, reason = why } end, function(written, result)
      if not written then
        if started then self:cancel_rescue(self:get_state(target)) end
        reply({ action = "Rescue", ok = false, reason = tostring(result), seq = seq, targetUserId = target.UserId })
        return
      end
      result.operation = operation
      reply(result)
    end) == true
  end

  function life:can_rescue(target, rescuer)
    local tree = tree_of(target)
    if not tree or type(tree._accept_rescue) ~= "function" then return false, "not-downed" end
    local phase = tree.states.life_phase:now()
    if phase == "rescuing" then return false, "busy" end
    if phase ~= "downed" then return false, "not-downed" end
    return true
  end

  function life:begin_rescue(target, rescuer)
    local rescuer_tree = tree_of(rescuer)
    if not rescuer_tree then return false, "no-rescuer" end
    return rescuer_tree:begin_rescue(target)
  end

  function life:cancel_rescue(state)
    local tree = state and tree_of(state.player or state)
    if not tree or type(tree.cancel_rescue) ~= "function" then return false end
    return tree:cancel_rescue() == true
  end

  function life:request_action(player, kind)
    local tree = tree_of(player)
    return tree ~= nil and tree:request_action(kind) == true
  end

  function life:weapon_action(player, payload)
    local tree = tree_of(player)
    if not tree then return false end
    local weapon = weapon_sessions[player.UserId]
    if not weapon or type(weapon.handle) ~= "function" then return false end
    return weapon:handle(payload) == true
  end

  function life:weapon_cast_guard(unit, index)
    for _, weapon in pairs(weapon_sessions) do
      if type(weapon.guard) == "function" and weapon:guard(unit, index) ~= true then
        return false
      end
    end
    return true
  end

  if get_damage_filter then
    life._damage_filter = get_damage_filter
  end

  return life
end

return LifeFacade
