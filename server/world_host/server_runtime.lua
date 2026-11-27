-- 服务端 Spoke 运行时总控与离场三步协议编排器（ADR-0032 §1、§2、§4 / #295）：
-- 负责：
--   1. 持有唯一 SpokeClock，接受宿主帧泵（step）驱动；
--   2. 拉起全局唯一 SharedWorldTree（7 个钓鱼区子域骨架 + 全局小队 Dock）；
--   3. 仅在存档加载就绪且服务启动后为在场玩家生成独立 Auto PlayerTree；
--   4. 编排离场三步协议：前置异步脏写 → Step 1 (session_alive=false 终镜像)
--      → Step 2 (同步 dispose 逆序拆资源与信号) → Step 3 (宿主持久化序列化 + 异步排空栅栏)；
--   5. 维护同账号重进排空栅栏（leaving.waiting），防止提前读旧档或覆盖正在落盘的数据。
-- 本模块归属 L2（server.world_host），零反向依赖存量旧债务模块；迁移过渡回调全部由 L1 入口注入。
-- new 只做归一化与装配；行为方法集中在模块级 RuntimeBehavior（方法名与签名不变），共享依赖经 runtime.runtime_env 读取。

local EngineRead = require("common.engine_read")
local GameCfg = require("common.game_cfg")
local Number = require("common.number")
local SpokeClock = require("common.spoke_clock")
local SharedWorldTree = require("server.world_host.shared_world_tree")
local PlayerTree = require("server.world_host.player_tree")
local AttrLeaf = require("server.world_host.attr_leaf")
local ModifierLeaf = require("server.world_host.modifier_leaf")
local AbilityLeaf = require("server.world_host.ability_leaf")
local SwingRegistry = require("server.swing_registry")
local PkDamageFilter = require("server.world_host.pk_damage_filter")
local FishTree = require("server.world_host.fish_tree")
local FishAiTarget = require("server.world_host.fish_ai_target")
local WorldRecords = require("server.world_host.world_records")
local PlayerGM = require("server.world_host.player_gm")
local LifeFacade = require("server.world_host.life_facade")

local ServerRuntime = {}
local RuntimeBehavior = {}
local RuntimeInternal = {}
local current_runtime = nil

-- 玩家树转发方法的生成器：除交互（含救援分支）外，动作与状态查询都是
-- 「离场拦截 → 取玩家树 → dispatch_action」的同形样板，只有动作名不同；payload 缺省为 nil。
local function forward_action(action)
  return function(self, player, payload)
    if self:is_leaving(player and player.UserId) then return false end
    local tree = self.runtime_env.player_trees[player and player.UserId]
    return tree and tree:dispatch_action(action, payload) or false
  end
end

function ServerRuntime.current()
  return current_runtime
end

function ServerRuntime.set_current(rt)
  current_runtime = rt
end

-- 统一经 EngineRead 判定玩家有效性，区分缺失、销毁与读取异常。
local function is_valid_player(player)
  return EngineRead.is_valid_player(player, "ServerRuntime.is_valid_player")
end

-- 统一经 EngineRead 读取玩家当前角色对象。
local function read_character(player)
  local ok, ch = EngineRead.read_character(player, "ServerRuntime.read_character")
  if ok then
    return ch
  end
  return nil
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
      and data.inited == true
      and data.load_state == "ready"
end

-- ===== 拆分前 ServerRuntime.new 体内的闭包：模块级行为表与内部辅助 =====
-- RuntimeBehavior 是 runtime 的方法表，方法名、参数顺序与返回值与拆分前完全一致；
-- 调用方照旧 `runtime:method(...)`，首个参数就是 runtime 本身。
-- RuntimeInternal 只在本模块内部调用（不挂到 runtime 上），对外方法面不变。
-- 拆分前从 new 的 upvalue 读取的依赖统一放进 runtime.runtime_env，字段名沿用拆分前的局部变量名。

--- 解析效果归属的玩家树：先按 UserId，再按玩家或角色对象回退匹配。
---@param env table 运行时环境
---@param target table 效果目标
---@return table? 玩家树
local function modifier_player_tree(env, target)
  if not EngineRead.is_object(target) then return nil end
  local ok_uid, uid = EngineRead.read_user_id(target, { context = "ServerRuntime.player_tree_of", logger = env.opts.logger })
  if ok_uid and uid ~= nil then
    local found = env.player_trees[uid]
    if type(found) == "table" and not found:is_disposed() then return found end
  end
  for _, candidate in pairs(env.player_trees) do
    if candidate and not candidate:is_disposed() then
      if candidate.player == target or read_character(candidate.player) == target then
        return candidate
      end
    end
  end
  return nil
end

--- 非玩家实体先解到载体身上，效果落在载体上。
---@param env table 运行时环境
---@param target table 效果目标
---@return table? 载体或原目标
local function modifier_entity_target(env, target)
  if not target then return nil end
  local ok_carrier, carrier = EngineRead.read_field(target, "carrier", {
    context = "ServerRuntime.entity_target",
    logger = env.opts.logger,
  })
  if ok_carrier and carrier then return target end
  local carrier_host = env.opts.fish_carrier
  local resolved = carrier_host and carrier_host.resolve_carrier and carrier_host:resolve_carrier(target)
  return resolved or target
end

--- 施加效果：玩家树优先，其次非玩家实体。
---@param env table 运行时环境
---@param source any 效果来源
---@param target table 效果目标
---@param kind string 效果类型
---@param seconds number 持续时长
local function modifier_apply(env, source, target, kind, seconds)
  local tree = modifier_player_tree(env, target)
  if tree then return tree:apply_modifier(kind, { duration = seconds, source = source }) end
  if env.entity_modifiers then return env.entity_modifiers:apply(source, modifier_entity_target(env, target), kind, seconds) end
  return false, "no-effect-owner"
end

--- 剩余时长：玩家树优先，其次非玩家实体。
---@param env table 运行时环境
---@param target table 效果目标
---@param kind string 效果类型
local function modifier_get_remaining(env, target, kind)
  local tree = modifier_player_tree(env, target)
  if tree then return tree:get_modifier_remaining(kind) end
  if env.entity_modifiers then return env.entity_modifiers:get_remaining(modifier_entity_target(env, target), kind) end
  return 0
end

--- 是否被控制：玩家树优先，其次非玩家实体。
---@param env table 运行时环境
---@param target table 效果目标
local function modifier_is_controlled(env, target)
  local tree = modifier_player_tree(env, target)
  if tree then return tree.states.is_paralyzed:now() == true end
  if env.entity_modifiers then return env.entity_modifiers:is_controlled(modifier_entity_target(env, target)) end
  return false
end

--- 移速倍率：玩家树优先，其次非玩家实体。
---@param env table 运行时环境
---@param target table 效果目标
local function modifier_move_multiplier(env, target)
  local tree = modifier_player_tree(env, target)
  if tree then return tree.memos.move_multiplier:now() end
  if env.entity_modifiers then return env.entity_modifiers:get_move_multiplier(modifier_entity_target(env, target)) end
  return 1
end

--- 清除某类效果：玩家树优先，其次非玩家实体。
---@param env table 运行时环境
---@param target table 效果目标
---@param kind string 效果类型
local function modifier_clear(env, target, kind)
  local tree = modifier_player_tree(env, target)
  if tree then return tree:clear_modifier(kind) end
  if env.entity_modifiers then return env.entity_modifiers:clear(modifier_entity_target(env, target), kind) end
  return false
end

--- 清除目标身上的全部效果：玩家树优先，其次非玩家实体。
---@param env table 运行时环境
---@param target table 效果目标
---@param keepWeak boolean? 是否保留弱效果
local function modifier_clear_target(env, target, keepWeak)
  local tree = modifier_player_tree(env, target)
  if tree then tree:clear_all_modifiers(keepWeak) return end
  if env.entity_modifiers then env.entity_modifiers:clear_target(modifier_entity_target(env, target)) end
end

--- 状态服务：玩家实体与活鱼/非玩家实体的效果归属解析，方法名与签名沿用拆分前的 modifier_service。
---@param env table
---@return table
local function build_modifier_service(env)
  local service = {}
  service.apply = function(_, source, target, kind, seconds)
    return modifier_apply(env, source, target, kind, seconds)
  end
  function service:apply_weapon_effect(source, target, effect)
    return self:apply(source, target, type(effect) == "table" and effect.Kind or nil)
  end
  service.get_remaining = function(_, target, kind) return modifier_get_remaining(env, target, kind) end
  service.is_controlled = function(_, target) return modifier_is_controlled(env, target) end
  service.get_move_multiplier = function(_, target) return modifier_move_multiplier(env, target) end
  service.clear = function(_, target, kind) return modifier_clear(env, target, kind) end
  service.clear_target = function(_, target, keepWeak) return modifier_clear_target(env, target, keepWeak) end
  service.update = function(_)
    if env.entity_modifiers then env.entity_modifiers:step(env.clock.now()) end
  end
  return service
end

--- 实体状态存储：宿主未开启时不建（拆分前 new 体内的 entity_modifiers 装配）。
---@param opts table
---@param clock table
---@return table?
local function build_entity_store(opts, clock)
  if not opts.entity_modifiers then return nil end
  local em_opts = type(opts.entity_modifiers) == "table" and opts.entity_modifiers or {}
  return ModifierLeaf.create_entity_store({
    modifier_api = em_opts.modifier_api,
    presets = em_opts.presets,
    now = function()
      return clock.now()
    end,
    on_dot_tick = em_opts.on_dot_tick,
    on_error = em_opts.on_error,
  })
end

--- 鱼宿主：注入时钟、投影、日志与玩家查询钩子；钩子经 env 读取运行期状态，不直接捕获 runtime。
---@param env table
---@return table
local function build_fish_host(env)
  local opts = env.opts
  ---@type table<string, any>
  local fish_host = FishTree.new({ clock = env.clock })
  -- clock 已在构造期显式注入
  fish_host.ai_projection = opts.ai
  fish_host.logger = opts.logger
  fish_host.get_player_tree = function(_, player)
    return is_valid_player(player) and env.player_trees[player.UserId] or nil
  end
  fish_host.on_state_changed = function()
    env.fish_dirty = true
  end
  fish_host.CreateUnit = opts.create_unit
  fish_host.World = opts.world_service
  fish_host.cast = opts.cast
  fish_host.ai = opts.fish_ai
  fish_host.AiTarget = opts.fish_ai_target or FishAiTarget
  fish_host.ability_api = opts.ability_api
  fish_host.Ability = opts.fish_ability
  fish_host.now = function() return env.clock.now() end
  fish_host.players = function()
    local list = {}
    for _, active in pairs(env.active_players) do list[#list + 1] = active end
    return list
  end
  return fish_host
end

--- 装配期共享依赖：拆分前 new 体内的全部 upvalue，按原名存放，行为不变。
---@param opts table
---@return table
local function build_env(opts)
  local initial_now = Number.is_finite_number(opts.initial_now) and opts.initial_now or 0
  local env = {
    opts = opts,
    clock = opts.clock or SpokeClock.new(initial_now),
    player_data = opts.player_data,
    save = opts.save,
    platform = opts.platform,
    current_players = {},
    active_players = {},
    player_trees = {},
    leaving_players = {},
    ready_queue = {},
    re_conns = {},
    fish_dirty = false,
    last_fish_signature = "",
    carrier_died_handler = nil,
    bound_shop_action = nil,
    entity_modifiers = nil,
    fish_host = nil,
    modifier_service = nil,
  }
  env.entity_modifiers = build_entity_store(opts, env.clock)
  env.fish_host = build_fish_host(env)
  env.modifier_service = build_modifier_service(env)
  return env
end

--- 拉起全局唯一的 SharedWorldTree 并返回（拆分前 new 体内 start 的 spawn 段）。
---@param self table
---@return table
function RuntimeInternal.spawn_world(self)
  local env = self.runtime_env
  local opts = env.opts
  return SharedWorldTree.spawn({
    clock = env.clock,
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
      return env.player_trees[player.UserId]
    end,
  })
end

--- 连接一个服务端 RemoteEvent 并保存句柄供 shutdown 断开；宿主未提供 remote 时跳过。
---@param self table
---@param channel string
---@param handler function
function RuntimeInternal.connect_re(self, channel, handler)
  local env = self.runtime_env
  local opts = env.opts
  local remote = opts.remote
  if type(remote) ~= "table" or type(remote.get_re) ~= "function" then return end
  local ok, event = EngineRead.call_method(remote, "get_re", { context = "ServerRuntime.connect_re:" .. tostring(channel), logger = opts.logger }, channel)
  if ok and event and event.OnServerEvent and type(event.OnServerEvent.Connect) == "function" then
    local conn = event.OnServerEvent:Connect(handler)
    if conn then env.re_conns[#env.re_conns + 1] = conn end
  end
end

--- 摆渡动作绑定（每局只绑一次）。
---@param self table
function RuntimeInternal.bind_ferry(self)
  local env = self.runtime_env
  if self._ferry_bound then return end
  self._ferry_bound = true
  local opts = env.opts
  if type(opts.bind_ferry_action) ~= "function" then return end
  opts.bind_ferry_action(function(actor, payload)
    local ferry = self.world and self.world.ferry
    return ferry and ferry:handle(actor, payload) or false
  end)
end

--- 小队动作与小队状态请求绑定（每局只绑一次）。
---@param self table
function RuntimeInternal.bind_party(self)
  local env = self.runtime_env
  if self._party_bound then return end
  self._party_bound = true
  local opts = env.opts
  if type(opts.bind_party_action) == "function" then
    opts.bind_party_action(function(actor, payload)
      if self:is_leaving(actor and actor.UserId) then return false end
      local squad = self.world and self.world.squad
      return squad and squad:handle(actor, payload) or false
    end)
  end
  if type(opts.bind_party_state_request) == "function" then
    opts.bind_party_state_request(function(actor)
      local squad = self.world and self.world.squad
      if squad and squad.online[actor and actor.UserId] == actor then squad:push(actor) end
    end)
  end
end

--- 核心请求通道绑定：生存、特殊道具、拾取、道具栏（每局只绑一次）。
---@param self table
function RuntimeInternal.bind_core_actions(self)
  if self._core_re_bound then return end
  self._core_re_bound = true
  RuntimeInternal.bind_survival_action(self)
  RuntimeInternal.bind_special_item_action(self)
  RuntimeInternal.bind_loot_request(self)
  RuntimeInternal.bind_item_bar_action(self)
end

--- 生存动作：宿主注入绑定优先，否则连 RemoteEvent。
---@param self table
function RuntimeInternal.bind_survival_action(self)
  local env = self.runtime_env
  local opts = env.opts
  local function on_survival(actor, payload, skip_cd)
    if not is_valid_player(actor) or self:is_leaving(actor.UserId) then return false end
    local tree = env.player_trees[actor.UserId]
    if tree and type(tree.handle_survival_action) == "function" then
      return tree:handle_survival_action(payload, skip_cd)
    end
    return false
  end
  if type(opts.bind_survival_action) == "function" then
    opts.bind_survival_action(function(actor, payload) return on_survival(actor, payload, true) end)
  else
    RuntimeInternal.connect_re(self, "SurvivalAction", function(actor, payload) on_survival(actor, payload, false) end)
  end
end

--- 特殊道具动作与状态查询。
---@param self table
function RuntimeInternal.bind_special_item_action(self)
  local env = self.runtime_env
  local opts = env.opts
  local function on_special_action(actor, payload)
    if not is_valid_player(actor) or self:is_leaving(actor.UserId) then return false end
    local tree = env.player_trees[actor.UserId]
    if tree and type(tree.handle_special_item_action) == "function" then
      return tree:handle_special_item_action(payload)
    end
    return false
  end
  local function on_special_query(actor)
    if not is_valid_player(actor) or self:is_leaving(actor.UserId) then return false end
    local tree = env.player_trees[actor.UserId]
    if tree and type(tree.handle_special_item_query) == "function" then
      return tree:handle_special_item_query()
    end
    return false
  end
  if type(opts.bind_special_item_action) == "function" then
    opts.bind_special_item_action(on_special_action, on_special_query)
  else
    RuntimeInternal.connect_re(self, "SpecialItemAction", on_special_action)
    RuntimeInternal.connect_re(self, "SpecialItemStateRequest", on_special_query)
  end
end

--- 拾取请求。
---@param self table
function RuntimeInternal.bind_loot_request(self)
  local env = self.runtime_env
  local opts = env.opts
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
    RuntimeInternal.connect_re(self, "RequestLoot", function(actor) on_loot_request(actor, false) end)
  end
end

--- 道具栏动作：宿主注入绑定优先，玩家数据自带 start 时不再连 RemoteEvent。
---@param self table
function RuntimeInternal.bind_item_bar_action(self)
  local env = self.runtime_env
  local opts = env.opts
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
  elseif opts.bind_item_bar_action ~= false and not has_method(env.player_data, "start") then
    RuntimeInternal.connect_re(self, "ItemBarAction", function(actor, payload) on_item_bar_action(actor, payload, false) end)
  end
end

--- 鱼载体死亡订阅（每局只订一次，句柄留到 shutdown 退订）。
---@param self table
function RuntimeInternal.bind_carrier_died(self)
  local env = self.runtime_env
  local opts = env.opts
  if env.carrier_died_handler or not has_method(opts.fish_carrier, "subscribe_died") then return end
  env.carrier_died_handler = function(carrier)
    env.fish_host:on_carrier_died(carrier)
  end
  opts.fish_carrier:subscribe_died(env.carrier_died_handler)
end

--- 启动各个宿主持久化/平台/鱼能力服务（逐个经 safe_call 隔离）。
---@param self table
function RuntimeInternal.start_host_services(self)
  local env = self.runtime_env
  local opts = env.opts
  if has_method(env.player_data, "start") then safe_call(opts.logger, "player_data_start", function() env.player_data:start() end) end
  if has_method(env.save, "start") then safe_call(opts.logger, "save_start", function() env.save:start() end) end
  if has_method(env.platform, "start") then safe_call(opts.logger, "platform_start", function() env.platform:start() end) end
  if has_method(opts.fish_ability, "start") then
    safe_call(opts.logger, "fish_ability_start", function() opts.fish_ability:start() end)
  end
end

--- 启动世界、绑定宿主动作通道、启动各宿主服务；重复调用返回同一个 world。
---@param self table
---@return table
function RuntimeBehavior.start(self)
  if self.world and not self.world:is_disposed() then
    return self.world
  end
  self.world = RuntimeInternal.spawn_world(self)
  RuntimeInternal.bind_ferry(self)
  RuntimeInternal.bind_party(self)
  RuntimeInternal.bind_core_actions(self)
  RuntimeInternal.bind_carrier_died(self)
  RuntimeInternal.start_host_services(self)
  return self.world
end

--- 标记启动完成，并按 UserId 顺序补放启动前积压的就绪存档。
---@param self table
function RuntimeBehavior.mark_started(self)
  local env = self.runtime_env
  self:start()
  self._started = true
  local queued = {}
  for user_id, entry in pairs(env.ready_queue) do
    queued[#queued + 1] = { user_id = user_id, entry = entry }
  end
  table.sort(queued, function(a, b)
    return tostring(a.user_id) < tostring(b.user_id)
  end)
  for _, item in ipairs(queued) do
    env.ready_queue[item.user_id] = nil
    self:on_save_ready(item.entry[1], item.entry[2])
  end
end

---@param self table
---@return table?
function RuntimeBehavior.get_world(self)
  return self.world
end

---@param self table
---@param user_id any
---@return table?
function RuntimeBehavior.get_player_tree(self, user_id)
  return self.runtime_env.player_trees[user_id]
end

--- 记录一次上鱼事件，交图鉴结算。
---@param self table
---@param player any
---@param event any
function RuntimeBehavior.record_landing(self, player, event)
  if self:is_leaving(player and player.UserId) then return false, "leaving" end
  local tree = player and self.runtime_env.player_trees[player.UserId]
  local compendium = tree and tree.compendium
  if not compendium then return false, "unavailable" end
  return compendium:record_landing(player, event)
end

--- 任务事实通知。
---@param self table
---@param kind string
---@param player any
---@param payload any
function RuntimeBehavior.notify_quest(self, kind, player, payload)
  if self:is_leaving(player and player.UserId) then return false end
  local tree = player and self.runtime_env.player_trees[player.UserId]
  local quest = tree and tree.quest
  return quest and quest:notify(kind, player, payload) or false
end

---@param self table
---@param player any
---@return boolean
function RuntimeBehavior.push_cast_state(self, player)
  local tree = player and self.runtime_env.player_trees[player.UserId]
  if tree and tree.fishing and type(tree.fishing.push_state) == "function" then
    tree.fishing:push_state()
    return true
  end
  return false
end

---@param self table
---@param player any
---@return boolean
function RuntimeBehavior.abort_cast(self, player)
  local tree = player and self.runtime_env.player_trees[player.UserId]
  if tree and tree.fishing and type(tree.fishing.abort) == "function" then
    return tree.fishing:abort() == true
  end
  return false
end

---@param self table
---@param player any
---@param fish_id any
---@return boolean
function RuntimeBehavior.set_next_fish(self, player, fish_id)
  local tree = player and self.runtime_env.player_trees[player.UserId]
  if tree and tree.fishing and type(tree.fishing.set_next_fish) == "function" then
    return tree.fishing:set_next_fish(fish_id) == true
  end
  return false
end

---@param self table
---@return table?
function RuntimeBehavior.get_entity_modifiers(self)
  return self.runtime_env.entity_modifiers
end

---@param self table
---@param user_id any
---@return boolean
function RuntimeBehavior.is_leaving(self, user_id)
  return self.runtime_env.leaving_players[user_id] ~= nil
end

--- 交互动作：救援目标转生命门面，其余交玩家树的分发器。
---@param self table
---@param actor any
---@param payload any
function RuntimeBehavior.dispatch_interact(self, actor, payload)
  if self:is_leaving(actor and actor.UserId) then return false end
  if type(payload) == "table" and payload.target == GameCfg.Rescue.Target then
    return self.life:rescue_action(actor, payload)
  end
  local tree = self.runtime_env.player_trees[actor and actor.UserId]
  return tree and tree:dispatch_action("interact", payload) or false
end

---@type fun(self: table, actor: any, payload: any): any
RuntimeBehavior.dispatch_shop = forward_action("shop")

--- 帧泵入口：推进时钟与各宿主 update，再推一次鱼战斗状态。
---@param self table
---@param dt number
---@param now number?
function RuntimeBehavior.step(self, dt, now)
  local env = self.runtime_env
  local opts = env.opts
  if not Number.is_finite_number(dt) or dt < 0 then
    return
  end
  local valid_now = now ~= nil and Number.is_finite_number(now) and now or nil
  env.clock:step(dt, valid_now)
  if has_method(env.save, "update") then safe_call(opts.logger, "save_update", function() env.save:update() end) end
  if has_method(env.platform, "update") then safe_call(opts.logger, "platform_update", function() env.platform:update() end) end
  if has_method(opts.fish_ability, "update") then
    safe_call(opts.logger, "fish_ability_update", function() opts.fish_ability:update(dt) end)
  end
  if has_method(opts.fish_carrier, "update") then
    safe_call(opts.logger, "fish_carrier_update", function() opts.fish_carrier:update(dt) end)
  end
  if env.entity_modifiers then
    env.entity_modifiers:step(env.clock.now())
  end
  env.fish_host:enforce_escape_cap(nil)
  self:_publish_fish()
end

--- 玩家入场：离场栅栏中的玩家只登记等待，其余进入在场表并联手宿主。
---@param self table
---@param player any
function RuntimeBehavior.on_player_added(self, player)
  local env = self.runtime_env
  if not is_valid_player(player) then
    return
  end
  local user_id = player.UserId
  local leaving = env.leaving_players[user_id]
  if leaving then
    leaving.waiting = player
    EngineRead.write_attribute(
      player, "SaveState",
      "pending",
      {
        context = "ServerRuntime.on_player_added (uid=" .. tostring(user_id) .. ")",
        logger = env.opts.logger,
      }
    )
    return
  end
  env.current_players[user_id] = player
  if self.world and self.world.ferry then self.world.ferry:on_player_added(player) end
  if type(env.opts.on_player_join_start) == "function" then
    safe_call(env.opts.logger, "on_player_join_start", env.opts.on_player_join_start, player)
  elseif has_method(env.player_data, "on_player_added") then
    safe_call(env.opts.logger, "player_data_added", function() env.player_data:on_player_added(player) end)
  end
end

--- 存档就绪：前置校验 → 积压或就绪队列 → 建 PlayerTree 并挂玩家态绑定。
---@param self table
---@param player any
---@param data any
---@return table?
function RuntimeBehavior.on_save_ready(self, player, data)
  local env = self.runtime_env
  if not is_valid_player(player) then
    return nil
  end
  local user_id = player.UserId
  if not RuntimeInternal.accept_ready_data(env, player, data) then
    return nil
  end
  if env.active_players[user_id] == player then
    return env.player_trees[user_id]
  end
  if not is_ready_data(player, data) then
    return nil
  end
  if not self._started then
    env.ready_queue[user_id] = { player, data }
    return nil
  end

  local world = self:start()
  local effects_opts = RuntimeInternal.build_effects_opts(env.opts)
  local mounts = RuntimeInternal.build_mounts(env.opts)
  return RuntimeInternal.spawn_player_tree(self, player, data, world, effects_opts, mounts)
end

--- 玩家离场入口：登记离场栅栏并发起三步协议。
---@param self table
---@param player any
function RuntimeBehavior.on_player_removing(self, player)
  local env = self.runtime_env
  if not is_valid_player(player) then
    return
  end
  local user_id = player.UserId
  local existing = env.leaving_players[user_id]
  if existing then
    if existing.waiting == player then
      existing.waiting = nil
    end
    return
  end
  if env.current_players[user_id] ~= player then
    return
  end
  ---@type LeavingEntry
  local leaving = { cleaned = false, waiting = nil }
  env.leaving_players[user_id] = leaving
  if self.world and self.world.ferry then self.world.ferry:on_player_removing(player) end
  local queued = env.ready_queue[user_id]
  if queued and queued[1] == player then
    env.ready_queue[user_id] = nil
  end
  RuntimeInternal.continue_removing(self, player, leaving)
end

--- 把鱼战斗状态推给客户端；签名未变化时跳过发送。
---@param self table
---@return boolean
function RuntimeBehavior._publish_fish(self)
  local env = self.runtime_env
  local opts = env.opts
  RuntimeInternal.prune_faulted_fish(env)
  local list, warnings = {}, {}
  for _, fish in ipairs(RuntimeInternal.sorted_fish_list(env)) do
    local row = RuntimeInternal.fish_row(fish)
    list[#list + 1] = row
    if type(row.warning) == "table" then warnings[#warnings + 1] = row.warning end
  end
  local sig = RuntimeInternal.fish_signature(list)
  if not env.fish_dirty and sig == env.last_fish_signature then return true end
  if sig == env.last_fish_signature then env.fish_dirty = false; return true end
  local ctx = { context = "ServerRuntime._publish_fish", logger = opts.logger }
  local ok_ev, event, reason_ev = EngineRead.call_method(opts.remote, "get_re", ctx, "FishCombatState")
  if not ok_ev or not event then
    env.fish_dirty = true
    RuntimeInternal.report_error(env, "[ServerRuntime] _publish_fish 获取通道失败", tostring(reason_ev or "missing"))
    return false
  end
  local ok_send, _, reason_send = EngineRead.call_method(event, "FireAllClients", ctx, { list = list, warnings = warnings })
  if not ok_send then
    env.fish_dirty = true
    RuntimeInternal.report_error(env, "[ServerRuntime] _publish_fish 发送失败", tostring(reason_send))
    return false
  end
  env.fish_dirty = false; env.last_fish_signature = sig; return true
end

---@type fun(self: table, player: any, payload: any): any
RuntimeBehavior.lottery_action = forward_action("lottery")

---@type fun(self: table, player: any, payload: any): any
RuntimeBehavior.blindbox_action = forward_action("blindbox")

---@type fun(self: table, player: any): any
RuntimeBehavior.lottery_state = forward_action("lottery_state")

---@type fun(self: table, player: any): any
RuntimeBehavior.blindbox_state = forward_action("blindbox_state")

---@type fun(self: table, player: any, payload: any): any
RuntimeBehavior.platform_shop_action = forward_action("platform_shop")

--- 客户端上报上鱼：落成落水鱼并入鱼宿主。
---@param self table
---@param player any
---@param catch any
function RuntimeBehavior.receive_landed(self, player, catch)
  local env = self.runtime_env
  if not is_valid_player(player) or type(catch) ~= "table" then return false, "bad" end
  if self:is_leaving(player.UserId) then return false, "leaving" end
  local holder = RuntimeInternal.holder_tree_of(env, player)
  if holder == nil or holder:is_disposed() then return false, "no-holder" end
  local position = catch.position or catch.Position
    or { x = catch.x, y = catch.y, z = catch.z }
  local fish, err = env.fish_host:spawn_landed(player, {
    fishId = catch.fishId,
    mult = catch.mult,
  }, position)
  if fish == nil then return false, err end
  self:_publish_fish()
  return true, fish.Id
end

---@param self table
---@param player any
---@return boolean
function RuntimeBehavior.drop_fish(self, player)
  local env = self.runtime_env
  if not is_valid_player(player) then return false end
  local dropped = env.fish_host:drop(player) == true
  self:_publish_fish()
  return dropped
end

---@param self table
---@param user_id any
---@return table
function RuntimeBehavior.fish_snapshot(self, user_id)
  local env = self.runtime_env
  RuntimeInternal.prune_faulted_fish(env)
  local list = {}
  for _, fish in ipairs(RuntimeInternal.sorted_fish_list(env)) do
    local row = RuntimeInternal.fish_row(fish)
    if user_id == nil or row.holderId == user_id or row.ownerId == user_id then
      list[#list + 1] = row
    end
  end
  return list
end

---@param self table
---@param id any
---@param amount number
---@return boolean, any
function RuntimeBehavior.damage_fish(self, id, amount)
  local env = self.runtime_env
  local fish = env.fish_host.Fish[id]
  if fish == nil then return false, "not-found" end
  local ok, err = env.fish_host:damage_fish(fish, amount)
  if ok then self:_publish_fish() end
  return ok, err
end

---@param self table
---@param id any
---@param reason any
---@return boolean
function RuntimeBehavior.fault_fish(self, id, reason)
  local env = self.runtime_env
  local fish = env.fish_host.Fish[id]
  if fish == nil then return false end
  local faulted = env.fish_host:fault(fish, reason)
  if faulted then
    env.fish_host:remove(fish)
  end
  self:_publish_fish()
  return faulted
end

--- 收摊：按逆序拆玩家树、鱼、信号句柄与宿主服务，再复位共享状态。
---@param self table
function RuntimeBehavior.shutdown(self)
  local env = self.runtime_env
  RuntimeInternal.dispose_players(env)
  for _, fish in ipairs(RuntimeInternal.sorted_fish_list(env)) do
    env.fish_host:remove(fish)
  end
  RuntimeInternal.dispose_connections(self)
  RuntimeInternal.release_bound_handlers(self)
  if self.world then
    self.world:dispose()
  end
  RuntimeInternal.reset_state(self)
  if current_runtime == self then
    current_runtime = nil
  end
end

--- 存档就绪前置校验：必须是在场当前玩家、且仍是该玩家当前代次的数据。
---@param env table
---@param player any
---@param data any
---@return boolean
function RuntimeInternal.accept_ready_data(env, player, data)
  local user_id = player.UserId
  if env.current_players[user_id] ~= player or env.leaving_players[user_id] then return false end
  local opts = env.opts
  if type(opts.is_player_data_current) == "function" then
    if not safe_call(opts.logger, "is_player_data_current", opts.is_player_data_current, player, data) then
      return false
    end
    return true
  end
  if has_method(env.player_data, "on_player_added") and has_method(env.player_data, "get_data_inst")
      and env.player_data:get_data_inst(player) ~= data then
    return false
  end
  return true
end

--- 玩家树的效果挂载参数：宿主效果表 + 槽位修饰叶挂载器。
---@param opts table
---@return table?
function RuntimeInternal.build_effects_opts(opts)
  if type(opts.player_effects) ~= "table" and not opts.modifier_leaf then return nil end
  local effects_opts = {}
  if type(opts.player_effects) == "table" then
    for k, v in pairs(opts.player_effects) do
      effects_opts[k] = v
    end
  end
  if opts.modifier_leaf and effects_opts.on_mount_modifier_leaf == nil then
    local ml_opts = type(opts.modifier_leaf) == "table" and opts.modifier_leaf or nil
    effects_opts.on_mount_modifier_leaf = ModifierLeaf.make_slot_mounter(ml_opts)
  end
  return effects_opts
end

--- 玩家树的属性叶/能力叶挂载表：在宿主基底之上串接本层叶。
---@param opts table
---@return table
function RuntimeInternal.build_mounts(opts)
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
  return mounts
end

--- 取玩家树上绑定的存档实例，取不到时退回原始 data。
---@param opts table
---@param player any
---@param data any
---@return table
function RuntimeInternal.resolve_tree_data(opts, player, data)
  local tree_data = data
  if opts.player_data and type(opts.player_data.get_data_inst) == "function" then
    local ok, inst = pcall(opts.player_data.get_data_inst, opts.player_data, player)
    if ok and type(inst) == "table" then tree_data = inst end
  end
  return tree_data
end

--- 为就绪玩家建 PlayerTree，登记在场表并挂全部玩家态动作绑定。
---@param self table
---@param player any
---@param data any
---@param world table
---@param effects_opts table?
---@param mounts table
---@return table
function RuntimeInternal.spawn_player_tree(self, player, data, world, effects_opts, mounts)
  local env = self.runtime_env
  local opts = env.opts
  local user_id = player.UserId
  local tree_data = RuntimeInternal.resolve_tree_data(opts, player, data)
  local player_tree = PlayerTree.spawn({
    player = player,
    data = tree_data,
    clock = env.clock,
    world = world,
    logger = opts.logger,
    create_unit = opts.create_unit,
    world_service = opts.world_service,
    fish_unit = opts.fish_unit or env.fish_host,
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
    delivery_epoch = opts.delivery_epoch,
    physics = opts.physics,
    weapon_fish_unit = opts.fish_unit,
    players_service = opts.players_service,
    ability = opts.ability,
    lottery_in_range = opts.lottery_in_range,
    new_hit = function(source, category) return self.life:new_hit(source, category) end,
    apply_hit = function(hit, target, amount) return self.life:apply_hit(hit, target, amount) end,
    apply_effect = function(source, target, kind) return env.modifier_service:apply(source, target, kind) end,
    damage_filter = self._damage_filter,
    damage_context = function() return self.life end,
    speed_writer = opts.speed_writer,
    growth_writer = opts.growth_writer,
    max_health_of = function(target_player) return self._max_health_of and self._max_health_of(target_player) end,
    on_downed = opts.on_player_downed,
    fish_units = opts.fish_units,
    lookup_tree = function(target_user_id)
      return env.player_trees[target_user_id]
    end,
    players = function()
      local list = {}
      for _, active in pairs(env.active_players) do
        list[#list + 1] = active
      end
      return list
    end,
  })
  env.active_players[user_id] = player
  env.player_trees[user_id] = player_tree
  if self.world and self.world.squad then self.world.squad:on_player_added(player) end
  SwingRegistry.set_clock(function() return env.clock.now() end)
  if player_tree.set_damage_filter and self._damage_filter then
    player_tree:set_damage_filter(self._damage_filter())
  end

  safe_call(opts.logger, "on_player_ready", opts.on_player_ready, player, data, player_tree)
  RuntimeInternal.bind_weapon_actions(self)
  RuntimeInternal.bind_interact_action(self)
  RuntimeInternal.bind_shop_action(self)
  RuntimeInternal.bind_economy_actions(self)
  RuntimeInternal.bind_grill_action(self)
  return player_tree
end

--- 武器/施法/收线动作与施法守卫绑定（每局只绑一次）。
---@param self table
function RuntimeInternal.bind_weapon_actions(self)
  local env = self.runtime_env
  local opts = env.opts
  if self._weapon_bound then return end
  self._weapon_bound = true
  if type(opts.bind_weapon_action) == "function" then
    opts.bind_weapon_action(function(actor, payload)
      if self:is_leaving(actor and actor.UserId) then return false end
      return self.life:weapon_action(actor, payload)
    end)
  end
  if type(opts.register_cast_guard) == "function" then
    opts.register_cast_guard(function(unit, index)
      return self.life:weapon_cast_guard(unit, index)
    end)
  end
  if type(opts.bind_cast_action) == "function" then
    opts.bind_cast_action(function(actor, payload)
      if self:is_leaving(actor and actor.UserId) then return false end
      local cast_tree = env.player_trees[actor and actor.UserId]
      local fishing = cast_tree and cast_tree.fishing
      if not fishing then return false end
      return fishing:cast(payload)
    end)
  end
  if type(opts.bind_reel_action) == "function" then
    opts.bind_reel_action(function(actor, kind, payload)
      if self:is_leaving(actor and actor.UserId) then return false end
      local reel_tree = env.player_trees[actor and actor.UserId]
      local fishing = reel_tree and reel_tree.fishing
      if not fishing then return false end
      return fishing:reel(kind, payload)
    end)
  end
end

--- 交互动作绑定（每局只绑一次）。
---@param self table
function RuntimeInternal.bind_interact_action(self)
  if self._fisherman_bound then return end
  self._fisherman_bound = true
  local opts = self.runtime_env.opts
  if type(opts.bind_interact_action) ~= "function" then return end
  opts.bind_interact_action(function(actor, payload)
    return self:dispatch_interact(actor, payload)
  end)
end

--- 商店动作绑定（每局只绑一次）。
---@param self table
function RuntimeInternal.bind_shop_action(self)
  if self._shop_bound then return end
  self._shop_bound = true
  local opts = self.runtime_env.opts
  if type(opts.bind_shop_action) ~= "function" then return end
  opts.bind_shop_action(function(actor, payload)
    return self:dispatch_shop(actor, payload)
  end)
end

--- 抽奖与盲盒动作绑定（每局只绑一次）。
---@param self table
function RuntimeInternal.bind_economy_actions(self)
  if self._economy_bound then return end
  self._economy_bound = true
  local opts = self.runtime_env.opts
  if type(opts.bind_lottery_action) == "function" then
    opts.bind_lottery_action(function(actor, payload)
      return self:lottery_action(actor, payload)
    end)
  end
  if type(opts.bind_blindbox_action) == "function" then
    opts.bind_blindbox_action(function(actor, payload)
      return self:blindbox_action(actor, payload)
    end)
  end
end

--- 烧烤动作绑定（每局只绑一次）。
---@param self table
function RuntimeInternal.bind_grill_action(self)
  if self._grill_bound then return end
  self._grill_bound = true
  local env = self.runtime_env
  local opts = env.opts
  if type(opts.bind_grill_action) ~= "function" then return end
  opts.bind_grill_action(function(actor, payload)
    if self:is_leaving(actor and actor.UserId) then return false end
    local tree = env.player_trees[actor and actor.UserId]
    return tree and tree:dispatch_action("grill", payload) or false
  end)
end

--- 离场栅栏条目：cleaned 表示 Step 1/2 已完成，waiting 是排空期间等待同账号重进的玩家。
---@class LeavingEntry
---@field cleaned boolean
---@field waiting any

--- 离场三步协议的驱动：脏写前置 → 终镜像与 dispose → 宿主持久化与排空栅栏。
---@param self table
---@param player any
---@param leaving LeavingEntry
function RuntimeInternal.continue_removing(self, player, leaving)
  local env = self.runtime_env
  local user_id = player.UserId
  if env.leaving_players[user_id] ~= leaving or leaving.cleaned then
    return
  end
  if RuntimeInternal.flush_before_leave(self, player, leaving) then return end
  local opts = env.opts
  if type(opts.flush_before_leave) == "function" then
    local waiting_flush = safe_call(opts.logger, "flush_before_leave", opts.flush_before_leave, player,
      function() RuntimeInternal.continue_removing(self, player, leaving) end)
    if waiting_flush then
      return
    end
  end

  leaving.cleaned = true
  local was_active = RuntimeInternal.dispose_leaving_tree(self, player, user_id)
  RuntimeInternal.handoff_leaving(self, player, leaving, user_id, was_active)
end

--- 前置异步脏写：图鉴/任务/剧情各自落盘，未完成时返回 true 表示继续等待。
---@param self table
---@param player any
---@param leaving LeavingEntry
---@return boolean
function RuntimeInternal.flush_before_leave(self, player, leaving)
  local progress_tree = self.runtime_env.player_trees[player.UserId]
  if not progress_tree then return false end
  local expected, finished, collecting = 0, 0, true
  local function one_done()
    finished = finished + 1
    if not collecting and expected > 0 and finished >= expected then
      RuntimeInternal.continue_removing(self, player, leaving)
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
    if finished < expected then return true end
    if finished > expected then return true end
  end
  return false
end

--- 离场 Step 1/2：终镜像 + 逆序 dispose，并清理该玩家施加的持续效果；返回其是否在场。
---@param self table
---@param player any
---@param user_id any
---@return boolean
function RuntimeInternal.dispose_leaving_tree(self, player, user_id)
  local env = self.runtime_env
  local opts = env.opts
  if self.world and self.world.squad then
    safe_call(opts.logger, "小队离场退队", function() self.world.squad:on_player_removing(player) end)
  end
  local was_active = env.active_players[user_id] == player
  if was_active then
    env.active_players[user_id] = nil
  end

  local player_tree = env.player_trees[user_id]
  if player_tree and player_tree.player == player then
    env.player_trees[user_id] = nil
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
  self:_publish_fish()

  -- 清理离场玩家施加给其他玩家或活鱼/非玩家实体的持续效果，防止离线来源继续 DoT。
  for _, other_tree in pairs(env.player_trees) do
    if other_tree and type(other_tree.clear_modifiers_by_source) == "function" then
      other_tree:clear_modifiers_by_source(player)
    end
  end
  if env.entity_modifiers then
    env.entity_modifiers:clear_by_source(player)
  end
  return was_active
end

--- 离场 Step 3：宿主持久化回调 + 异步排空栅栏，等落盘完成再放同账号重进。
---@param self table
---@param player any
---@param leaving LeavingEntry
---@param user_id any
---@param was_active boolean
function RuntimeInternal.handoff_leaving(self, player, leaving, user_id, was_active)
  local env = self.runtime_env
  local opts = env.opts
  if type(opts.on_player_removing) == "function" then
    safe_call(opts.logger, "on_player_removing", opts.on_player_removing, player, was_active)
  else
    if has_method(env.player_data, "on_player_removing") then
      safe_call(opts.logger, "player_data_removing", function() env.player_data:on_player_removing(player) end)
    end
    if has_method(env.platform, "on_player_removing") then
      safe_call(opts.logger, "platform_removing", function() env.platform:on_player_removing(player) end)
    end
  end

  local function finish_drain()
    if env.leaving_players[user_id] ~= leaving then
      return
    end
    env.leaving_players[user_id] = nil
    env.current_players[user_id] = nil
    local waiting = leaving.waiting
    leaving.waiting = nil
    if waiting then
      self:on_player_added(waiting)
    end
  end

  if type(opts.after_idle) == "function" then
    opts.after_idle(user_id, finish_drain)
  elseif has_method(env.save, "after_idle") then
    env.save:after_idle(user_id, finish_drain)
  else
    finish_drain()
  end
end

---@param env table
---@param player any
---@return table?
function RuntimeInternal.holder_tree_of(env, player)
  if not is_valid_player(player) then return nil end
  return env.player_trees[player.UserId]
end

--- 按 id 排序的活鱼列表，保证下发顺序稳定。
---@param env table
---@return table
function RuntimeInternal.sorted_fish_list(env)
  local ids = {}
  for id, fish in pairs(env.fish_host.Fish) do
    if type(fish) == "table" then ids[#ids + 1] = id end
  end
  table.sort(ids, function(a, b)
    if type(a) == "number" and type(b) == "number" then return a < b end
    return tostring(a) < tostring(b)
  end)
  local out = {}
  for _, id in ipairs(ids) do
    local fish = env.fish_host.Fish[id]
    if fish ~= nil then out[#out + 1] = fish end
  end
  return out
end

--- 移除已置 fault 的鱼，避免它们留在快照里。
---@param env table
function RuntimeInternal.prune_faulted_fish(env)
  local faulted = {}
  for _, fish in pairs(env.fish_host.Fish) do
    if type(fish) == "table" and fish.tree and fish.tree.fault ~= nil then
      faulted[#faulted + 1] = fish
    end
  end
  for _, fish in ipairs(faulted) do
    env.fish_host:remove(fish)
  end
end

--- 单条鱼的下发行，字段名与拆分前一致。
---@param fish table
---@return table
function RuntimeInternal.fish_row(fish)
  local species = GameCfg.Fish[fish.fish_id] or {}
  local state = fish.State
  local phase = "lifted"
  if state == FishTree.State.escaping then
    phase = "escape"
  elseif state == FishTree.State.wild then
    phase = "wild"
  elseif state ~= FishTree.State.await_lift and state ~= FishTree.State.held then
    phase = "combat"
  end
  local health = fish.carrier and fish.carrier.Health or species.Health
  local max_health = species.Health or 0
  local ratio = max_health > 0 and (health or 0) / max_health or 0
  local bossPhase = nil
  if fish.fish_id == "fish56Boss" then
    bossPhase = ratio > 0.6 and "land" or (ratio > 0.2 and "water" or "enraged")
  end
  local lifted = state == FishTree.State.await_lift or state == FishTree.State.held
  return {
    id = fish.Id,
    fishId = fish.fish_id,
    name = species.Name,
    mult = fish.mult,
    zoneId = species.ZoneId,
    phase = phase,
    bossPhase = bossPhase,
    grounded = not lifted,
    health = health,
    max_health = max_health,
    label = fish.MoveName or (phase == "combat" and "战斗" or (phase == "escape" and "逃脱" or "举鱼")),
    warning = fish.Warning,
    holderId = fish.holder and fish.holder.UserId or nil,
    ownerId = fish.Owner and fish.Owner.UserId or nil,
  }
end

--- 快照签名：内容相同就不再重复下发。
---@param rows table
---@return string
function RuntimeInternal.fish_signature(rows)
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

--- 上报发布失败：有 logger 走 logger.error，否则退回 print（文本与拆分前一致）。
---@param env table
---@param label string
---@param text string
function RuntimeInternal.report_error(env, label, text)
  local logger = env.opts.logger
  if logger and type(logger.error) == "function" then
    pcall(logger.error, logger, label .. ": " .. text)
  else
    print(label, text)
  end
end

--- 按 id 顺序 dispose 全部玩家树。
---@param env table
function RuntimeInternal.dispose_players(env)
  local ids = {}
  for user_id in pairs(env.player_trees) do
    ids[#ids + 1] = user_id
  end
  table.sort(ids, function(a, b)
    return tostring(a) < tostring(b)
  end)
  for _, user_id in ipairs(ids) do
    local pt = env.player_trees[user_id]
    env.player_trees[user_id] = nil
    if pt then
      pt:dispose()
    end
  end
end

--- 逆序断开所有 RemoteEvent 连接，并复位核心通道绑定标记。
---@param self table
function RuntimeInternal.dispose_connections(self)
  local env = self.runtime_env
  for i = #env.re_conns, 1, -1 do
    local conn = env.re_conns[i]
    env.re_conns[i] = nil
    if conn ~= nil then
      EngineRead.disconnect(conn, { context = "ServerRuntime.shutdown", logger = env.opts.logger })
    end
  end
  self._core_re_bound = false
end

--- 退订鱼载体死亡、摘掉平台商店动作句柄。
---@param self table
function RuntimeInternal.release_bound_handlers(self)
  local env = self.runtime_env
  local opts = env.opts
  if env.carrier_died_handler and has_method(opts.fish_carrier, "unsubscribe_died") then
    opts.fish_carrier:unsubscribe_died(env.carrier_died_handler)
    env.carrier_died_handler = nil
  end
  if env.bound_shop_action and type(env.platform) == "table" and env.platform.shop_action == env.bound_shop_action then
    env.platform.shop_action = nil
    env.bound_shop_action = nil
  end
end

--- 复位共享状态：清空实体效果与全部玩家表，供同实例重新启动。
---@param self table
function RuntimeInternal.reset_state(self)
  local env = self.runtime_env
  if env.entity_modifiers then
    env.entity_modifiers:clear_all()
  end
  env.current_players = {}
  env.active_players = {}
  env.leaving_players = {}
  env.ready_queue = {}
  env.fish_dirty = false
  env.last_fish_signature = ""
  self._started = false
end

-- ===== 装配：runtime 表、宿主协作钩子与服务接线 =====

--- 鱼宿主与 GM 的协作钩子（拆分前 new 体内的 Quest / PlayerGM / on_killed 装配）。
---@param runtime table
---@param env table
local function wire_hooks(runtime, env)
  local opts = env.opts
  env.fish_host.Quest = {
    notify = function(_, kind, owner, fact) return runtime:notify_quest(kind, owner, fact) end,
  }
  PlayerGM.configure({
    player_data = opts.player_data,
    save = opts.save,
    cast = { set_next_fish = function(_, target, fishId) return runtime:set_next_fish(target, fishId) end },
    vitals = {
      set_health = function(_, target, value) return runtime.life:set_health(target, value) end,
      set_hunger = function(_, target, value) return runtime.life:set_hunger(target, value) end,
    },
  })
  env.fish_host.on_killed = function(killed)
    local world = runtime.world
    if world and type(world.on_carrier_killed) == "function" then
      world:on_carrier_killed(killed)
    end
  end
end

--- 玩家数据宿主回指 runtime、存档与生命门面，并挂成长同步。
---@param runtime table
---@param env table
local function wire_player_data(runtime, env)
  local player_data = env.player_data
  if not has_method(player_data, "on_player_added") then return end
  player_data.runtime = runtime
  player_data.Save = env.save
  player_data.Vitals = runtime.life
  player_data.Quest = { notify = function(_, kind, owner, fact) return runtime:notify_quest(kind, owner, fact) end }
  player_data.Ability = {
    apply_growth = function(_, player)
      local tree = is_valid_player(player) and env.player_trees[player.UserId]
      local data = player_data:get_data_inst(player)
      if not tree or not data then return { Ok = false } end
      tree:sync_from_data(data)
      return { Ok = true }
    end,
  }
end

--- 存档宿主就绪回调接回 on_save_ready。
---@param runtime table
---@param env table
local function wire_save(runtime, env)
  local save = env.save
  if not (has_method(save, "load_into") or has_method(save, "start")) then return end
  if has_method(env.player_data, "send_item_bar") then save.player_data = env.player_data end
  save.on_ready = function(player, data) runtime:on_save_ready(player, data) end
end

--- 平台宿主：挂存档与玩家数据，并暴露平台商店动作句柄（shutdown 时摘掉）。
---@param runtime table
---@param env table
local function wire_platform(runtime, env)
  local platform = env.platform
  if type(platform) ~= "table" then return end
  if has_method(platform, "start") then
    if type(env.save) == "table" then platform.Save = env.save end
    if type(env.player_data) == "table" then platform.player_data = env.player_data end
  end
  if platform.shop_action == nil then
    env.bound_shop_action = function(actor, payload)
      return runtime:platform_shop_action(actor, payload)
    end
    platform.shop_action = env.bound_shop_action
  end
end

--- 鱼能力宿主：状态服务、生命门面与行为服务表。
---@param runtime table
---@param env table
local function wire_fish_ability(runtime, env)
  local opts = env.opts
  if not opts.fish_ability then return end
  local modifier_service = env.modifier_service
  opts.fish_ability.Modifier = modifier_service
  opts.fish_ability.Vitals = runtime.life
  opts.fish_ability.ai = opts.fish_ai
  opts.fish_ability.behavior_services = {
    Vitals = runtime.life,
    Modifier = modifier_service,
    GM = PlayerGM,
    FishCarrier = opts.fish_carrier,
  }
end

--- 尾部服务接线（拆分前 new 体内的伤害过滤、生命门面与宿主挂载），顺序与拆分前一致。
---@param runtime table
---@param env table
local function wire_services(runtime, env)
  local opts = env.opts
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
    player_trees = env.player_trees,
    active_players = env.active_players,
    opts = opts,
    get_max_health_of = function() return runtime._max_health_of end,
    get_damage_filter = function() return damage_filter end,
    set_damage_filter = function(filter) damage_filter = filter end,
  })
  env.fish_host.Vitals = runtime.life
  wire_player_data(runtime, env)
  wire_save(runtime, env)
  wire_platform(runtime, env)
  wire_fish_ability(runtime, env)
end

--- 装配 runtime 表：字段名与拆分前一致，方法由 RuntimeBehavior 逐个挂上（对外方法面不变）。
--- 拆分前写作 function runtime:damage_fish(id, amount)、function runtime:receive_landed(player, catch)
--- 这类方法，现分别由 RuntimeBehavior.damage_fish / RuntimeBehavior.receive_landed 承载，
--- 挂载后 `runtime:damage_fish(...)` 的调用形式、参数顺序与返回值与拆分前完全一致。
---@param env table
---@return table
local function build_runtime(env)
  local opts = env.opts
  ---@type table<string, any>
  local runtime = {
    clock = env.clock,
    world = nil,
    entity_modifiers = env.entity_modifiers,
    platform = opts.platform,
    fish_host = env.fish_host,
    runtime_env = env,
    _started = false,
  }
  for name, method in pairs(RuntimeBehavior) do
    runtime[name] = method
  end
  if not opts.cast then
    env.fish_host.cast = {
      PushState = function(_, player) return runtime:push_cast_state(player) end,
      abort = function(_, player) return runtime:abort_cast(player) end,
      set_next_fish = function(_, player, fish_id) return runtime:set_next_fish(player, fish_id) end,
    }
  end
  return runtime
end

--- 装配一个新的服务端运行时；本函数只做归一化与装配，行为在 RuntimeBehavior。
---@param opts? table
function ServerRuntime.new(opts)
  opts = type(opts) == "table" and opts or {}

  local env = build_env(opts)
  local runtime = build_runtime(env)
  wire_hooks(runtime, env)
  wire_services(runtime, env)
  return runtime
end

return ServerRuntime
