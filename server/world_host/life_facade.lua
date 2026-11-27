local EngineRead = require("common.engine_read")
local GameCfg = require("common.game_cfg")
local Number = require("common.number")

local LifeFacade = {}
-- 生命行为表：拆分前 LifeFacade.new 体内的闭包，依赖统一从 life.life_env 读取。
local LifeBehavior = {}

-- 生命门面（LifeFacade）：
-- 统一经 L3 common.engine_read 读取/校验玩家、角色、位置与控制器血量，
-- 与 ServerRuntime 共用同一引擎对象读取边界，不再保留本地静默 pcall 兜底。
-- 内部 helper 约定：
--   1. tree_of(env, player)：经 EngineRead.read_user_id 读取并校验玩家子树存活；
--   2. player_from_unit(env, unit)：在活跃玩家列表内匹配单位本体或其当前角色；
--   3. set_health(player, value)：经 EngineRead.write_health 写入并回读确认后再提交权威状态；
--   4. rescue_action(player, payload)：经 EngineRead.read_user_id 与 read_player_position 校距。
--
-- 对外门面接口（方法名、参数顺序与返回值不变；行为集中在 LifeBehavior，共享依赖在 life.life_env）：
--   get_tree / player_from_unit / life_status / is_downed / is_rescuing / player_by_user_id /
--   is_dead / can_act / can_take_damage / can_eat / eat / max_health_of / snapshot_health /
--   set_damage_filter / new_hit / resolve_hit_source / apply_hit / apply_damage / set_health /
--   set_hunger / phase / get_state / rescue_action / can_rescue / begin_rescue / cancel_rescue /
--   request_action / weapon_action / weapon_cast_guard。

--- 玩家子树：经 EngineRead.read_user_id 读取并校验存活（拆分前 new 体内的 tree_of）。
---@param env table
---@param player any
---@return table?
local function tree_of(env, player)
  local ok, uid = EngineRead.read_user_id(player, "LifeFacade.tree_of")
  if not ok then return nil end
  local tree = env.player_trees[uid]
  if tree and not tree:is_disposed() then return tree end
  return nil
end

--- 在活跃玩家列表内匹配单位本体或其当前角色（拆分前 new 体内的 player_from_unit）。
---@param env table
---@param unit any
---@return any
local function player_from_unit(env, unit)
  if not EngineRead.is_object(unit) then return nil end
  for _, player in pairs(env.active_players) do
    if player == unit then return player end
    local _, character = EngineRead.read_character(player, "LifeFacade.player_from_unit")
    if character == unit then return player end
  end
  return nil
end

--- 按 UserId 在活跃玩家列表内查找玩家，读取失败即跳过（拆分前 rescue_action 内的目标扫描段）。
---@param env table
---@param user_id any
---@param context string
---@return any
local function active_player_by_user_id(env, user_id, context)
  for _, candidate in pairs(env.active_players) do
    local ok_uid, uid = EngineRead.read_user_id(candidate, context)
    if ok_uid and uid == user_id then return candidate end
  end
  return nil
end

--- 救援结果下发（拆分前 rescue_action 体内的 reply 闭包）。
---@param env table
---@param player any
---@param result table
---@return table
local function rescue_reply(env, player, result)
  local remote = env.opts.remote
  if remote and type(remote.get_re) == "function" then
    remote:get_re("InteractResult"):FireClient(player, result)
  end
  return result
end

--- 校验救援请求载荷并取出序号；不合法返回 nil（拆分前 rescue_action 开头的校验段）。
---@param payload any
---@return number?
local function rescue_seq(payload)
  if type(payload) ~= "table" or payload.action ~= GameCfg.Rescue.Action then return nil end
  local seq = payload.seq
  if not Number.is_finite_number(seq) or seq ~= math.floor(seq) or seq < 1 or seq > 2147483647 then return nil end
  return seq
end

--- 解析救援幂等请求：数据、存档与 operation 一并返回，缺失即 nil（拆分前 rescue_action 内解析段）。
---@param env table
---@param player any
---@param payload table
---@param seq number
---@return table?
local function rescue_request(env, player, payload, seq)
  local opts = env.opts
  local data = opts.player_data and opts.player_data:get_data_inst(player)
  local save = opts.save
  if not data or not save then return nil end
  local request_id = payload.operation
  if request_id ~= nil and type(request_id) ~= "table" then return nil end
  if request_id == nil then request_id = seq end
  local operation, mode = save:resolve_request(player, data, "rescue", request_id)
  if not operation then return nil end
  return { operation = operation, mode = mode, data = data, save = save }
end

--- 解析救援目标与相位：目标缺失或相位不在可救援区间时返回 nil 与读到的目标 UserId。
---@param env table
---@param payload table
---@return table? found, any target_uid
local function rescue_target(env, payload)
  local target = active_player_by_user_id(env, payload.targetUserId, "LifeFacade.rescue_action")
  local ok_tuid, target_uid = EngineRead.read_user_id(target, "LifeFacade.rescue_action")
  local target_tree = ok_tuid and env.player_trees[target_uid]
  local phase = target_tree and target_tree.states.life_phase:now()
  if not target or not ok_tuid or (phase ~= "downed" and phase ~= "rescuing") then
    return nil, target_uid
  end
  return { target = target, uid = target_uid }
end

--- 救援距离校验：返回 ok/reason 与回包用的目标标识（no-position 用读到的 uid，too-far 用 target.UserId）。
---@param player any
---@param target any
---@param target_uid any
---@return boolean ok, string? reason, any reply_uid
local function rescue_range_ok(player, target, target_uid)
  local ok_from, from = EngineRead.read_player_position(player, "LifeFacade.rescue_action.from")
  local ok_to, to = EngineRead.read_player_position(target, "LifeFacade.rescue_action.to")
  if not ok_from or not ok_to or not from or not to then
    return false, "no-position", target_uid
  end
  local dx, dz = from.x - to.x, from.z - to.z
  if math.sqrt(dx * dx + dz * dz) > GameCfg.Rescue.Range then
    return false, "too-far", target.UserId
  end
  return true
end

-- ===== 门面方法：拆分前 life 表上的闭包，方法名、参数顺序与返回值不变 =====

function LifeBehavior.get_tree(_, player)
  return tree_of(_.life_env, player)
end

function LifeBehavior.player_from_unit(_, unit)
  return player_from_unit(_.life_env, unit)
end

function LifeBehavior.life_status(_, player)
  local tree = tree_of(_.life_env, player)
  return tree and tree.states.life_phase:now() or nil
end

function LifeBehavior.is_downed(self, player)
  local phase = self:life_status(player)
  return phase == "downed" or phase == "rescuing"
end

function LifeBehavior.is_rescuing(self, player)
  return self:life_status(player) == "rescuing"
end

function LifeBehavior.player_by_user_id(_, user_id)
  for _, player in pairs(_.life_env.active_players) do
    if user_id ~= nil and select(2, EngineRead.read_user_id(player, "LifeFacade.player_by_user_id")) == user_id then return player end
  end
  return nil
end

function LifeBehavior.is_dead(self, player)
  return self:life_status(player) == "dead"
end

function LifeBehavior.can_act(_, player)
  local tree = tree_of(_.life_env, player)
  return tree ~= nil and tree.memos.can_act:now() == true
end

function LifeBehavior.can_take_damage(self, player)
  return self:life_status(player) == "alive"
end

function LifeBehavior.can_eat(_, player, item_id)
  local tree = tree_of(_.life_env, player)
  if not tree or tree.memos.can_act:now() ~= true then return false end
  local definition = type(item_id) == "string" and GameCfg.Items.Definitions[item_id]
  return type(definition) == "table" and type(definition.EatPercent) == "number"
end

function LifeBehavior.eat(_, player, item_id, cook_rate)
  local tree = tree_of(_.life_env, player)
  if not tree then return false end
  return tree:eat(item_id, cook_rate)
end

function LifeBehavior.max_health_of(_, player)
  local env = _.life_env
  local get_max_health_of = env.get_max_health_of
  local max_health_of = get_max_health_of and get_max_health_of() or nil
  if type(max_health_of) == "function" then
    local ok, value = pcall(max_health_of, player)
    if ok and Number.is_finite_number(value) and value >= 1 then return math.floor(value) end
  end
  local tree = tree_of(env, player)
  local value = tree and tree.memos.max_health and tree.memos.max_health:now()
  if Number.is_finite_number(value) and value >= 1 then return math.floor(value) end
  return GameCfg.Vitals.MaxHealth
end

function LifeBehavior.snapshot_health(self, player)
  local tree = tree_of(self.life_env, player)
  if not tree then return nil, nil end
  return math.max(0, math.floor(tree.states.health:now())), self:max_health_of(player)
end

function LifeBehavior.set_damage_filter(_, filter)
  local env = _.life_env
  if env.set_damage_filter then env.set_damage_filter(filter) end
  for _, tree in pairs(env.player_trees) do
    if tree.set_damage_filter then tree:set_damage_filter(filter or false) end
  end
end

function LifeBehavior.new_hit(_, source, category)
  local env = _.life_env
  env.hit_seq = env.hit_seq + 1
  local source_player = tree_of(env, source) and source or player_from_unit(env, source)
  return {
    id = env.hit_seq,
    source = source,
    category = category,
    sourcePlayer = source_player,
    targets = {},
  }
end

function LifeBehavior.resolve_hit_source(_, hit)
  return type(hit) == "table" and hit.sourcePlayer or nil
end

function LifeBehavior.apply_hit(_, hit, target, amount)
  local env = _.life_env
  local player = tree_of(env, target) and target or player_from_unit(env, target)
  local tree = tree_of(env, player) or tree_of(env, hit and hit.sourcePlayer)
  if not tree then
    for _, candidate in pairs(env.player_trees) do
      if candidate and not candidate:is_disposed() then tree = candidate break end
    end
  end
  if not tree then return false end
  return tree:apply_hit(hit, target, amount)
end

function LifeBehavior.apply_damage(self, player, amount, hit)
  local ok = self:apply_hit(hit or self:new_hit(nil, "damage"), player, amount)
  return ok
end

function LifeBehavior.set_health(self, player, value)
  local tree = tree_of(self.life_env, player)
  if not tree or not Number.is_finite_number(value) then
    return false
  end
  local current = tree.states.health:now()
  if value < current then
    return self:apply_damage(player, current - value, self:new_hit(nil, "gm"))
  end
  if not EngineRead.write_health(
    player, value,
    { context = "LifeFacade.set_health", logger = self.life_env.opts.logger }
  ) then
    return false
  end
  tree.states.health:set(value)
  return true
end

function LifeBehavior.set_hunger(_, player, value)
  local tree = tree_of(_.life_env, player)
  if not tree or not Number.is_finite_number(value) then return false end
  local clamped = math.max(0, math.min(GameCfg.Vitals.MaxHunger, math.floor(value)))
  tree.states.hunger:set(clamped)
  return true
end

function LifeBehavior.phase(self, player)
  return self:life_status(player)
end

function LifeBehavior.get_state(_, player)
  local tree = tree_of(_.life_env, player)
  if not tree then return nil end
  return { player = player, phase = tree.states.life_phase:now(), tree = tree }
end

function LifeBehavior.rescue_action(self, player, payload)
  local env = self.life_env
  local seq = rescue_seq(payload)
  if not seq then return false end
  if not Number.is_finite_number(payload.targetUserId) then
    rescue_reply(env, player, { action = "Rescue", ok = false, reason = "invalid", seq = seq })
    return false
  end
  local request = rescue_request(env, player, payload, seq)
  if not request then return false end
  local operation, save, data = request.operation, request.save, request.data
  if request.mode == "replay" then
    return save:execute(player, data, operation, function() return nil, "expired" end,
      function(ok, result) if ok then result.operation = operation rescue_reply(env, player, result) end end) == true
  end
  local found, target_uid = rescue_target(env, payload)
  if not found then
    rescue_reply(env, player, {
      action = "Rescue", ok = false, reason = "not-downed", seq = seq, targetUserId = payload.targetUserId,
    })
    return false
  end
  local target = found.target
  local in_range, range_reason, reply_uid = rescue_range_ok(player, target, target_uid)
  if not in_range then
    rescue_reply(env, player, { action = "Rescue", ok = false, reason = range_reason, seq = seq, targetUserId = reply_uid })
    return false
  end
  local can, reason = self:can_rescue(target, player)
  if not can then
    rescue_reply(env, player, { action = "Rescue", ok = false, reason = reason, seq = seq, targetUserId = target.UserId })
    return false
  end
  local started, why = self:begin_rescue(target, player)
  return save:execute(player, data, operation, function() return { ok = started == true, action = "Rescue", targetUserId = target.UserId, reason = why } end, function(written, result)
    if not written then
      if started then self:cancel_rescue(self:get_state(target)) end
      rescue_reply(env, player, { action = "Rescue", ok = false, reason = tostring(result), seq = seq, targetUserId = target.UserId })
      return
    end
    result.operation = operation
    rescue_reply(env, player, result)
  end) == true
end

function LifeBehavior.can_rescue(_, target, _rescuer)
  local tree = tree_of(_.life_env, target)
  if not tree or type(tree._accept_rescue) ~= "function" then return false, "not-downed" end
  local phase = tree.states.life_phase:now()
  if phase == "rescuing" then return false, "busy" end
  if phase ~= "downed" then return false, "not-downed" end
  return true
end

function LifeBehavior.begin_rescue(_, target, rescuer)
  local rescuer_tree = tree_of(_.life_env, rescuer)
  if not rescuer_tree then return false, "no-rescuer" end
  return rescuer_tree:begin_rescue(target)
end

function LifeBehavior.cancel_rescue(_, state)
  local tree = state and tree_of(_.life_env, state.player or state)
  if not tree or type(tree.cancel_rescue) ~= "function" then return false end
  return tree:cancel_rescue() == true
end

function LifeBehavior.request_action(_, player, kind)
  local tree = tree_of(_.life_env, player)
  return tree ~= nil and tree:request_action(kind) == true
end

function LifeBehavior.weapon_action(_, player, payload)
  local tree = tree_of(_.life_env, player)
  return tree ~= nil and tree:dispatch_action("weapon", payload) == true
end

function LifeBehavior.weapon_cast_guard(_, unit, index)
  for _, tree in pairs(_.life_env.player_trees) do
    local guard = tree.weapon_cast_guard
    if type(guard) == "function" and guard(unit, index) ~= true then
      return false
    end
  end
  return true
end

--- 装配生命门面：拆分前依赖的 upvalue 集中进 life_env，方法由 LifeBehavior 逐个挂上。
---@param ctx table
---@return table
function LifeFacade.new(ctx)
  local opts = ctx.opts or {}
  ---@type table<string, any>
  local life = {
    life_env = {
      player_trees = ctx.player_trees,
      active_players = ctx.active_players,
      opts = opts,
      get_max_health_of = ctx.get_max_health_of,
      get_damage_filter = ctx.get_damage_filter,
      set_damage_filter = ctx.set_damage_filter,
      hit_seq = 0,
    },
  }
  for name, method in pairs(LifeBehavior) do
    life[name] = method
  end
  if ctx.get_damage_filter then
    life._damage_filter = ctx.get_damage_filter
  end
  return life
end

return LifeFacade
