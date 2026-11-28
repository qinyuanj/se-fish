local EngineRead = require("common.engine_read")
local GameCfg = require("common.game_cfg")
local Vitals = require("common.vitals")
local Number = require("common.number")
local Spoke = require("common.packages.spoke.api")
local SpokeRuntime = require("common.packages.spoke.runtime.spoke_runtime")

local State = Spoke.State

local PlayerLife = {}
-- 生命行为表：拆分前都是 PlayerLife.mount 体内的闭包，依赖统一从树上的 life_env 读取。
local LifeBehavior = {}

local function finite_number(value)
  return Number.is_finite_number(value)
end

local function positive_amount(value)
  return finite_number(value) and value > 0
end

local function controller_of(player)
  local ok, controller = EngineRead.read_controller(player, "PlayerLife.controller_of")
  if ok then
    return controller
  end
  return nil
end

local function read_health(player)
  local ok, health = EngineRead.read_health(player, "PlayerLife.read_health")
  if ok then
    return health
  end
  return nil
end

local function position_of(player)
  local ok, pos = EngineRead.read_player_position(player, "PlayerLife.position_of")
  if ok then return pos end
  return nil
end

local function horizontal_distance(a, b)
  if not a or not b or not finite_number(a.x) or not finite_number(b.x) then
    return math.huge
  end
  local dx, dz = a.x - b.x, (a.z or 0) - (b.z or 0)
  return math.sqrt(dx * dx + dz * dz)
end

local function distance3(a, b)
  if not a or not b then return math.huge end
  local dx = (a.x or 0) - (b.x or 0)
  local dy = (a.y or 0) - (b.y or 0)
  local dz = (a.z or 0) - (b.z or 0)
  return math.sqrt(dx * dx + dy * dy + dz * dz)
end

local function write_attr(player, key, value)
  return EngineRead.write_attribute(player, key, value, "PlayerLife.write_attr")
end

local function ceil_remaining(until_at, now)
  return math.max(0, math.ceil((until_at or now) - now))
end

-- 建环境：拆分前 mount 开头的一批局部量（配置、注入服务、Spoke 状态与计数器）。
function LifeBehavior.new_env(player_tree, opts)
  opts = type(opts) == "table" and opts or {}
  local env = {
    tree = player_tree,
    player = player_tree.player,
    states = player_tree.states,
    memos = player_tree.memos,
    clock = player_tree.clock,
    data = player_tree.data,
    opts = opts,
    survival_cfg = GameCfg.Survival,
    vitals_cfg = GameCfg.Vitals,
    rescue_cfg = GameCfg.Rescue,
    platform_api = opts.platform,
    save_api = opts.save,
    player_data = opts.player_data,
    remote = opts.remote,
    fish_carrier = opts.fish_carrier,
    speed_writer = opts.speed_writer,
    growth_writer = opts.growth_writer,
    on_downed = opts.on_downed,
    raw = {},
    hit_seq = 0,
    help_index = 0,
    last_help_at = nil,
    adrenaline_flying = false,
    recover_flying = false,
    noticed_health = nil,
    suppress_health_note = false,
    damage_filter = nil,
  }
  local seeded = env.data
  if env.player_data and type(env.player_data.get_data_inst) == "function" then
    local ok_seed, inst_seed = pcall(env.player_data.get_data_inst, env.player_data, env.player)
    if ok_seed then seeded = inst_seed
    else print("[PlayerLife] operation=init_seeded", "player=" .. tostring(env.player.UserId), tostring(inst_seed)); seeded = nil end
  end
  if type(seeded) == "table" and type(seeded.extra) == "table" and type(seeded.extra.survival) == "table" then
    env.raw = seeded.extra.survival
  end
  local now0 = env.clock.now()
  env.downed_until = State.new("PlayerLife.downed_until", nil)
  env.dead_until = State.new("PlayerLife.dead_until", nil)
  env.rescue = State.new("PlayerLife.rescue", nil)
  env.platform = State.new("PlayerLife.platform", nil)
  env.episode = State.new("PlayerLife.episode", 0)
  env.recovering = State.new("PlayerLife.recovering", false)
  env.engine_death = State.new("PlayerLife.engine_death", false)
  env.last_hunger_sec = math.floor(now0)
  env.rescue_sec = math.floor(now0)
  return env
end

-- ===== 存档数据读取 =====

function LifeBehavior.read_current_data(self)
  local env = self.life_env
  local player_data = env.player_data
  if player_data and type(player_data.get_data_inst) == "function" then
    local ok, inst = pcall(player_data.get_data_inst, player_data, env.player)
    if not ok then print("[PlayerLife] operation=current_data", "player=" .. tostring(env.player.UserId), tostring(inst)); return nil, false end
    if type(inst) == "table" then return inst, true end
    return nil, true
  end
  return env.data, true
end

function LifeBehavior.live_data(self)
  local env = self.life_env
  local inst, ok = LifeBehavior.read_current_data(self)
  if not ok then return nil end
  if type(inst) == "table" then return inst end
  if env.player_data and type(env.player_data.get_data_inst) == "function" then return nil end
  return env.data
end

function LifeBehavior.mark_table(self)
  local inst = LifeBehavior.live_data(self)
  if type(inst) ~= "table" then return nil end
  if type(inst.extra) ~= "table" then inst.extra = {} end
  if type(inst.extra.survival) ~= "table" then inst.extra.survival = {} end
  return inst.extra.survival
end

function LifeBehavior.current_data(self)
  local inst = LifeBehavior.read_current_data(self)
  return inst
end

function LifeBehavior.max_health(self)
  local env = self.life_env
  local opts, memos, vitals_cfg = env.opts, env.memos, env.vitals_cfg
  if type(opts.max_health_of) == "function" then
    local ok, value = pcall(opts.max_health_of, env.player)
    if not ok then
      print("[PlayerLife] operation=max_health", "player=" .. tostring(env.player.UserId), tostring(value))
      return nil
    end
    if finite_number(value) and value >= 1 then return math.floor(value) end
  end
  local value = memos.max_health and memos.max_health:now() or vitals_cfg.MaxHealth
  if not finite_number(value) or value < 1 then return vitals_cfg.MaxHealth end
  return math.floor(value)
end

-- ===== 下行消息与状态镜像 =====

function LifeBehavior.fire_client(self, name, payload)
  local env = self.life_env
  local ok, _, reason = EngineRead.fire_client(env.remote, name, env.player, payload, "PlayerLife.fire_client"); if not ok then print("[PlayerLife] 下行消息发送失败", env.player and env.player.UserId, tostring(name), tostring(reason)); return false, reason end; return true
end

function LifeBehavior.reply(self, payload)
  LifeBehavior.fire_client(self, "SurvivalResult", payload)
end

function LifeBehavior.write_vitals(self)
  local env = self.life_env
  local states, vitals_cfg, player = env.states, env.vitals_cfg, env.player
  local health = states.health:now()
  write_attr(player, "Health", math.max(0, math.floor(health)))
  local mh = LifeBehavior.max_health(self)
  if mh ~= nil then write_attr(player, "MaxHealth", mh) end
  write_attr(player, "Hunger", states.hunger:now())
  write_attr(player, "MaxHunger", vitals_cfg.MaxHunger)
end

function LifeBehavior.phase_payload(self)
  local env = self.life_env
  local states, clock, tree = env.states, env.clock, env.tree
  local phase = states.life_phase:now()
  local payload = { phase = phase }
  if phase == "downed" or phase == "rescuing" then
    payload.endsAt = env.downed_until:now()
  elseif phase == "dead" then
    payload.endsAt = env.dead_until:now()
  end
  local weak = tree.get_modifier_remaining and tree:get_modifier_remaining("weak") or 0
  if weak > 0 then payload.weakUntil = clock.now() + weak end
  local rescue_now = env.rescue:now()
  if phase == "rescuing" and type(rescue_now) == "table" then
    payload.rescuerUserId = rescue_now.by and rescue_now.by.UserId
    payload.rescueEndsAt = rescue_now.endAt
  end
  local pending = env.platform:now()
  if type(pending) == "table" then payload.platformPending = pending.mode end
  return payload
end

function LifeBehavior.publish(self)
  local env = self.life_env
  local states, clock, tree, player = env.states, env.clock, env.tree, env.player
  local phase = states.life_phase:now()
  write_attr(player, "SurvivalPhase", phase)
  LifeBehavior.write_vitals(self)
  LifeBehavior.fire_client(self, "SurvivalState", LifeBehavior.phase_payload(self))
  local mark = LifeBehavior.mark_table(self)
  if mark then
    local now = clock.now()
    local pending = env.platform:now()
    local paused = type(pending) == "table" and math.max(0.0, now - (pending.startedAt or now)) or 0.0
    local downed_at = env.downed_until:now()
    local dead_at = env.dead_until:now()
    mark.health = states.health:now()
    mark.hunger = states.hunger:now()
    mark.dying = phase == "downed" or phase == "rescuing"
    mark.dead = phase == "dead"
    mark.dyingRemaining = (mark.dying and downed_at) and ceil_remaining(downed_at + paused, now) or 0
    mark.deadRemaining = (mark.dead and dead_at) and ceil_remaining(dead_at + paused, now) or 0
    local weak = tree.get_modifier_remaining and tree:get_modifier_remaining("weak") or 0
    mark.weakRemaining = math.max(0, math.ceil(weak))
  end
end

function LifeBehavior.carrying_barrel(self, source)
  local held = self.life_env.vitals_cfg.HeldDamage
  if not held then return false end
  local containers = source and source.data and source.data.containers
  if type(containers) ~= "table" then return false end
  local ids = GameCfg.Items.ContainerId
  for _, id in ipairs({ ids.ItemBar, ids.Backpack }) do
    local container = containers[id]
    if type(container) == "table" then
      for _, entry in pairs(container) do
        if type(entry) == "table" and entry.itemId == held.ItemId and (entry.count or 0) > 0 then
          return true
        end
      end
    end
  end
  return false
end

function LifeBehavior.set_controller_health(self, value)
  local env = self.life_env
  if not EngineRead.write_health(env.player, value, "PlayerLife.set_controller_health") then return false end
  local ok_r, read = EngineRead.read_health(env.player, "PlayerLife.set_controller_health.verify")
  if not ok_r then return false end
  env.noticed_health = read
  env.states.health:set(read)
  return true
end

-- ===== 移速与成长 =====

-- 移速基线：先取入参或记忆值，为空再读控制器当前值（受虚弱限制）。
function LifeBehavior.walk_base(self, base_override, controller)
  local env = self.life_env
  local base = base_override
  if not finite_number(base) or base <= 0 then base = env.memos.walk_speed and env.memos.walk_speed:now() end
  if finite_number(base) and base > 0 then return base end
  local ok, current, reason_read = EngineRead.read_field(controller, "WalkSpeed", "PlayerLife.apply_walk")
  if not ok and reason_read ~= "missing" then print("[PlayerLife] apply_walk 读取移速失败", env.player and env.player.UserId, tostring(reason_read)); return nil, reason_read end
  if ok and finite_number(current) and current > 0 and not env.tree:get_modifier_remaining("weak") then return current end
  return base
end

function LifeBehavior.apply_walk(self, base_override)
  local env = self.life_env
  local tree, player, states = env.tree, env.player, env.states
  if tree.walk_projection_rejected then return false, "rejected" end
  local ok_ctrl, controller, reason_ctrl = EngineRead.read_controller(player, "PlayerLife.apply_walk")
  if not ok_ctrl or not controller then if reason_ctrl ~= "missing" then print("[PlayerLife] apply_walk 读取控制器失败", player and player.UserId, tostring(reason_ctrl)) end; return false, reason_ctrl or "missing" end
  local base, read_err = LifeBehavior.walk_base(self, base_override, controller)
  if read_err then return false, read_err end
  local paralyzed, speed, failed_err = states.is_paralyzed:now() == true, base, nil
  if finite_number(base) then
    if paralyzed then speed = 0 end
    local ok_w, _, reason_w = EngineRead.write_field(controller, "WalkSpeed", speed, "PlayerLife.apply_walk")
    if not ok_w then failed_err = reason_w or "write_error"; print("[PlayerLife] apply_walk 写入移速失败", player and player.UserId, "speed=" .. tostring(speed), tostring(failed_err)) end
  end
  if type(env.speed_writer) == "function" then
    local ok_sw, res_sw = pcall(env.speed_writer, player, speed)
    if not ok_sw or res_sw == false then local err = not ok_sw and tostring(res_sw) or "returned-false"; print("[PlayerLife] apply_walk speed_writer 失败", player and player.UserId, "speed=" .. tostring(speed), err); failed_err = failed_err or err end
  end
  if failed_err then return false, failed_err end; return true
end

function LifeBehavior.run_growth_writer(self)
  local env = self.life_env
  local player, growth_writer = env.player, env.growth_writer
  if type(growth_writer) ~= "function" then return nil end
  local ok_gw, res_gw = pcall(growth_writer, player)
  if ok_gw and res_gw ~= false and not (type(res_gw) == "table" and res_gw.Ok == false) then return nil end
  local err = LifeBehavior.growth_error_text(ok_gw, res_gw)
  print("[PlayerLife] reapply_growth growth_writer 失败", player and player.UserId, err)
  return err
end

function LifeBehavior.growth_error_text(ok_gw, res_gw)
  if not ok_gw then return tostring(res_gw) end
  if type(res_gw) == "table" then return tostring(res_gw.Error or "returned-false") end
  return "returned-false"
end

function LifeBehavior.read_speed_before(self, ok_ctrl, controller)
  if not (ok_ctrl and controller) then return nil end
  local ok, current, reason_b = EngineRead.read_field(controller, "WalkSpeed", "PlayerLife.reapply_growth.before")
  if ok then return current end
  local player = self.life_env.player
  if reason_b ~= "missing" then print("[PlayerLife] reapply_growth 读取原移速失败", player and player.UserId, tostring(reason_b)) end
  return nil
end

function LifeBehavior.read_speed_after(self, controller, before)
  local ok, current, reason_a = EngineRead.read_field(controller, "WalkSpeed", "PlayerLife.reapply_growth.after")
  if not ok then
    local player = self.life_env.player
    if reason_a ~= "missing" then print("[PlayerLife] reapply_growth 读取成长后移速失败", player and player.UserId, tostring(reason_a)) end
    return nil
  end
  if finite_number(current) and current > 0 and current ~= before then return current end
  return nil
end

function LifeBehavior.reapply_growth(self)
  local env = self.life_env
  local player, growth_writer = env.player, env.growth_writer
  local ok_ctrl, controller, reason_ctrl = EngineRead.read_controller(player, "PlayerLife.reapply_growth")
  if not ok_ctrl and reason_ctrl ~= "missing" then print("[PlayerLife] reapply_growth 读取控制器失败", player and player.UserId, tostring(reason_ctrl)) end
  local before = LifeBehavior.read_speed_before(self, ok_ctrl, controller)
  local growth_err = LifeBehavior.run_growth_writer(self)
  local grown
  if not growth_err and ok_ctrl and controller and type(growth_writer) == "function" then
    grown = LifeBehavior.read_speed_after(self, controller, before)
  end
  local walk_ok, walk_err = LifeBehavior.apply_walk(self, grown); if growth_err then return false, growth_err end; if not walk_ok then return false, walk_err end; return true
end

-- ===== 相位推进 =====

function LifeBehavior.clear_combat_effects(self)
  local tree = self.life_env.tree
  if type(tree.clear_all_modifiers) == "function" then
    tree:clear_all_modifiers(true)
  end
end

function LifeBehavior.enter_downed(self)
  local env = self.life_env
  local states, survival_cfg = env.states, env.survival_cfg
  local now = env.clock.now()
  if not LifeBehavior.set_controller_health(self, 1) then
    return false
  end
  SpokeRuntime.batch(function()
    env.episode:set(env.episode:now() + 1)
    env.rescue:set(nil)
    env.platform:set(nil)
    states.platform_pending:set(false)
    env.downed_until:set(now + survival_cfg.DownedSec)
    states.life_phase:set("downed")
  end)
  LifeBehavior.clear_combat_effects(self)
  if type(env.on_downed) == "function" then
    local ok_d, err_d = pcall(env.on_downed, env.player); if not ok_d then print("[PlayerLife] on_downed 回调失败", env.player and env.player.UserId, tostring(err_d)) end
  end
  LifeBehavior.publish(self)
  return true
end

function LifeBehavior.enter_dead(self, from_engine)
  local env = self.life_env
  local states, survival_cfg = env.states, env.survival_cfg
  local now = env.clock.now()
  env.rescue:set(nil)
  env.platform:set(nil)
  states.platform_pending:set(false)
  SpokeRuntime.batch(function()
    states.life_phase:set("dead")
    env.downed_until:set(nil)
    env.dead_until:set(now + survival_cfg.DeadSec)
    env.engine_death:set(from_engine == true)
  end)
  LifeBehavior.clear_combat_effects(self)
  LifeBehavior.publish(self)
end

function LifeBehavior.revive_to(self, health, min_hunger, with_weak)
  local env = self.life_env
  local states, vitals_cfg, survival_cfg, tree, player = env.states, env.vitals_cfg, env.survival_cfg, env.tree, env.player
  local cap = LifeBehavior.max_health(self)
  if not cap or not finite_number(health) then return false end
  local next_health = math.max(1, math.min(cap, math.floor(health)))
  local hunger = states.hunger:now()
  if finite_number(min_hunger) and hunger < min_hunger then
    hunger = min_hunger
  end
  hunger = math.max(0, math.min(vitals_cfg.MaxHunger, math.floor(hunger)))
  if not LifeBehavior.set_controller_health(self, next_health) then return false end
  SpokeRuntime.batch(function()
    states.hunger:set(hunger)
    states.life_phase:set("alive")
    env.downed_until:set(nil)
    env.dead_until:set(nil)
    env.rescue:set(nil)
    env.platform:set(nil)
    states.platform_pending:set(false)
    env.recovering:set(false)
    env.engine_death:set(false)
  end)
  if with_weak then
    tree:apply_modifier("weak", { duration = survival_cfg.WeakSec })
  elseif tree.clear_modifier then
    tree:clear_modifier("weak")
  end
  local ok_growth, growth_err = LifeBehavior.reapply_growth(self); if not ok_growth then print("[PlayerLife] revive_to 重算成长或移速失败", player and player.UserId, tostring(growth_err)) end
  LifeBehavior.publish(self)
  return true
end

function LifeBehavior.percent_health(self)
  local cap = LifeBehavior.max_health(self)
  if not cap then return nil end
  return math.floor(cap * self.life_env.survival_cfg.ReviveHealthPercent / 100)
end

function LifeBehavior.min_hunger(self)
  local env = self.life_env
  return math.floor(env.vitals_cfg.MaxHunger * env.survival_cfg.ReviveHungerPercent / 100)
end

function LifeBehavior.weak_revive(self)
  if self.life_env.states.life_phase:now() ~= "dead" then return false end
  return LifeBehavior.revive_to(self, LifeBehavior.percent_health(self), LifeBehavior.min_hunger(self), true)
end

function LifeBehavior.full_revive(self)
  local phase = self.life_env.states.life_phase:now()
  if phase ~= "downed" and phase ~= "rescuing" and phase ~= "dead" then return false end
  return LifeBehavior.revive_to(self, LifeBehavior.max_health(self), LifeBehavior.min_hunger(self), false)
end

function LifeBehavior.rescue_success(self)
  local states = self.life_env.states
  if states.life_phase:now() ~= "rescuing" and states.life_phase:now() ~= "downed" then
    return false
  end
  return LifeBehavior.revive_to(self, LifeBehavior.percent_health(self), nil, false)
end

function LifeBehavior.publish_notice(self, actual, hit)
  local env = self.life_env
  local player, remote = env.player, env.remote
  if not (actual > 0) then return false, "non-positive" end
  local _, uid = EngineRead.read_user_id(player, "PlayerLife.publish_notice")
  local ok_ev, event, reason_ev = EngineRead.call_method(remote, "get_re", "PlayerLife.publish_notice", "DamageNotice")
  if not ok_ev or not event then print("[PlayerLife] DamageNotice 通道获取失败", uid, tostring(reason_ev or "missing")); return false, reason_ev or "missing" end
  local ok_pos, pos = EngineRead.read_player_position(player, "PlayerLife.publish_notice")
  local ok_send, _, reason_send = EngineRead.call_method(event, "FireAllClients", "PlayerLife.publish_notice", {
    amount = actual, category = hit and hit.category, targetUserId = uid, position = ok_pos and pos or nil,
  })
  if not ok_send then print("[PlayerLife] DamageNotice 广播失败", uid, tostring(reason_send)); return false, reason_send end; return true
end

function LifeBehavior.apply_damage(self, amount, hit)
  local env = self.life_env
  local states, player = env.states, env.player
  local phase = states.life_phase:now()
  if phase ~= "alive" or env.recovering:now() or not positive_amount(amount) then return false end
  local ok_before, before = EngineRead.read_health(player, "PlayerLife.apply_damage.before")
  if not ok_before or not before or not finite_number(before) then return false end
  ---@cast before number
  env.suppress_health_note = true
  local function finish(ok, actual)
    env.suppress_health_note = false
    local ok_h, h = EngineRead.read_health(player, "PlayerLife.apply_damage.finish")
    if ok_h then env.noticed_health = h end
    return ok, actual
  end
  if before - amount <= 0 then
    if not LifeBehavior.enter_downed(self) then return finish(false) end
    LifeBehavior.publish_notice(self, before - 1, hit)
    return finish(true, math.max(0, before - 1))
  end
  local ok_ctrl, controller = EngineRead.read_controller(player, "PlayerLife.apply_damage")
  if not ok_ctrl or not controller or type(controller.TakeDamage) ~= "function" then return finish(false) end
  if not EngineRead.call_method(controller, "TakeDamage", "PlayerLife.apply_damage.TakeDamage", amount) then return finish(false) end
  local ok_after, after = EngineRead.read_health(player, "PlayerLife.apply_damage.after")
  if not ok_after or not after or not finite_number(after) then return finish(false) end
  ---@cast after number
  if after <= 0 then
    if not LifeBehavior.enter_downed(self) then return finish(false) end
    LifeBehavior.publish_notice(self, before - 1, hit); return finish(true, math.max(0, before - 1))
  end
  states.health:set(after)
  LifeBehavior.write_vitals(self)
  if after >= before then return finish(false) end
  LifeBehavior.publish_notice(self, before - after, hit)
  return finish(true, before - after)
end

-- ===== 命中与伤害接线 =====

function LifeBehavior.resolve_player(self, target)
  local env = self.life_env
  local ok_uid, uid = EngineRead.read_user_id(target, "PlayerLife.resolve_player")
  if ok_uid and uid ~= nil and env.opts.lookup_tree and env.opts.lookup_tree(uid) then
    return target
  end
  if target == env.player then return env.player end
  return nil
end

function LifeBehavior.new_hit(self, source, category)
  local env = self.life_env
  env.hit_seq = env.hit_seq + 1
  local source_player = nil
  local ok_uid, uid = EngineRead.read_user_id(source, "PlayerLife.new_hit")
  if ok_uid and uid ~= nil then
    source_player = source
  end
  return {
    id = env.hit_seq,
    category = category,
    source = source,
    sourcePlayer = source_player,
    targets = {},
  }
end

function LifeBehavior.resolve_hit_source(_, hit)
  return type(hit) == "table" and hit.sourcePlayer or nil
end

function LifeBehavior.set_damage_filter(self, filter)
  self.life_env.damage_filter = type(filter) == "function" and filter or nil
end

function LifeBehavior.resolve_hit_target(self, hit, target)
  local env = self.life_env
  local opts, player = env.opts, env.player
  local target_player = target
  local ok_tuid, tuid = EngineRead.read_user_id(target, "PlayerLife.apply_hit")
  if not (opts.lookup_tree and ok_tuid and opts.lookup_tree(tuid)) then target_player = LifeBehavior.resolve_player(self, target) or target end
  local ok_tpuid, tpuid = EngineRead.read_user_id(target_player, "PlayerLife.apply_hit")
  if not ok_tpuid and type(opts.players) == "function" then
    for _, candidate in ipairs(opts.players()) do
      local ok_cch, cch = EngineRead.read_character(candidate, "PlayerLife.apply_hit")
      if candidate == target or (ok_cch and cch == target) then
        target_player = candidate
        ok_tpuid, tpuid = EngineRead.read_user_id(target_player, "PlayerLife.apply_hit")
        break
      end
    end
  end
  if not target_player or not ok_tpuid then return nil end
  if hit.sourcePlayer then
    local ok_suid, suid = EngineRead.read_user_id(hit.sourcePlayer, "PlayerLife.apply_hit")
    if not (ok_suid and opts.lookup_tree and opts.lookup_tree(suid)) and target_player ~= player then return nil end
  end
  local tree = opts.lookup_tree and opts.lookup_tree(tpuid) or nil
  return target_player, tree
end

-- 载具（被鱼抱起等）承伤：命中交给载具结算，handled 表示已由该分支处理。
function LifeBehavior.carrier_damage(self, hit, target, amount)
  local fish_carrier = self.life_env.fish_carrier
  if not (fish_carrier and type(fish_carrier.resolve_carrier) == "function") then return false end
  local ok, carrier = pcall(fish_carrier.resolve_carrier, fish_carrier, target)
  if not ok or not carrier then return false end
  local key = "carrier:" .. tostring(carrier)
  if hit.targets[key] then return true, false end
  if type(fish_carrier.Damage) ~= "function" then return true, false end
  local damaged, actual = fish_carrier:Damage(carrier, amount, hit)
  if damaged then hit.targets[key] = true end
  return true, damaged, actual
end

-- 伤害过滤：没有生效过滤器时视为放行。
function LifeBehavior.damage_allowed(self, hit)
  local env = self.life_env
  local opts = env.opts
  if env.damage_filter == false then env.damage_filter = nil end
  local filter = env.damage_filter
  if filter == nil and opts.damage_filter then
    local current = opts.damage_filter()
    if type(current) == "function" then filter = current end
  end
  if type(filter) ~= "function" then return true end
  local context = opts.damage_context and opts.damage_context() or self
  local ok, allowed = pcall(filter, hit, env.player, context)
  if not ok or allowed ~= true then return false end
  return true
end

function LifeBehavior.apply_hit(self, hit, target, amount)
  local player = self.life_env.player
  if type(hit) ~= "table" or type(hit.targets) ~= "table" or type(hit.id) ~= "number" then return false end
  if not positive_amount(amount) then return false end
  local handled, damaged, carrier_actual = LifeBehavior.carrier_damage(self, hit, target, amount)
  if handled then return damaged, carrier_actual end
  local target_player, tree = LifeBehavior.resolve_hit_target(self, hit, target)
  if not target_player then return false end
  if tree ~= self then
    if tree and type(tree.apply_hit) == "function" then
      return tree:apply_hit(hit, target_player, amount)
    end
    return false
  end
  if not LifeBehavior.damage_allowed(self, hit) then return false end
  if hit.targets[player.UserId] then return false end
  local applied, actual = LifeBehavior.apply_damage(self, amount, hit)
  if applied then hit.targets[player.UserId] = true end
  return applied, actual
end

function LifeBehavior.request_action(self, kind)
  if self.life_env.memos.can_act:now() ~= true then return false end
  if kind ~= "attack" and kind ~= "throw" and kind ~= "reel" and kind ~= "use_item" then
    return false
  end
  return true
end

function LifeBehavior.eat(self, item_id, cook_rate)
  local env = self.life_env
  local states, vitals_cfg, player = env.states, env.vitals_cfg, env.player
  if env.memos.can_act:now() ~= true then return false end
  local definition = type(item_id) == "string" and GameCfg.Items.Definitions[item_id]
  if type(definition) ~= "table" or type(definition.EatPercent) ~= "number" then return false end
  local cap = LifeBehavior.max_health(self)
  if not cap then return false end
  local rate = 1
  if finite_number(cook_rate) and cook_rate > 0 then rate = cook_rate end
  local percent = definition.EatPercent * rate
  if percent < 0 then
    local damage = math.floor(cap * -percent / 100)
    if damage > 0 and not LifeBehavior.apply_damage(self, damage, self:new_hit(player, "eat")) then return false end
  else
    local ok_h, health = EngineRead.read_health(player, "PlayerLife.eat")
    if not ok_h or not health then return false end
    if not LifeBehavior.set_controller_health(self, Vitals.restore(math.floor(health), cap, percent)) then return false end
  end
  local hunger = Vitals.restore(states.hunger:now(), vitals_cfg.MaxHunger, percent)
  states.hunger:set(hunger)
  LifeBehavior.write_vitals(self)
  return true
end

-- ===== 抢救 =====

function LifeBehavior._accept_rescue(self, rescuer)
  local env = self.life_env
  local opts, states, rescue_cfg, player = env.opts, env.states, env.rescue_cfg, env.player
  local ok_ruid, ruid = EngineRead.read_user_id(rescuer, "PlayerLife._accept_rescue")
  local rescuer_tree = opts.lookup_tree and ok_ruid and opts.lookup_tree(ruid)
  if states.life_phase:now() ~= "downed" then return false, "not-downed" end
  if env.rescue:now() or env.platform:now() then return false, "busy" end
  if not rescuer_tree then return false, "no-rescuer" end
  if rescuer_tree.states.life_phase:now() ~= "alive" then
    return false, "rescuer-downed"
  end
  if rescuer_tree.memos and rescuer_tree.memos.can_act and rescuer_tree.memos.can_act:now() ~= true then
    return false, "rescuer-cannot-act"
  end
  local from, to = position_of(rescuer), position_of(player)
  if not from or not to then return false, "no-position" end
  if horizontal_distance(from, to) > rescue_cfg.Range then return false, "too-far" end
  local now, health = env.clock.now(), read_health(rescuer)
  env.rescue:set({
    by = rescuer,
    startedAt = now,
    endAt = now + rescue_cfg.DurationSec,
    startPos = { x = from.x, y = from.y, z = from.z },
    health = health,
  })
  states.life_phase:set("rescuing")
  LifeBehavior.publish(self)
  return true
end

function LifeBehavior.begin_rescue(self, target)
  local env = self.life_env
  local ok_tuid, tuid = EngineRead.read_user_id(target,
    "PlayerLife.begin_rescue")
  local target_tree = env.opts.lookup_tree and ok_tuid and env.opts.lookup_tree(tuid)
  if not target_tree or type(target_tree._accept_rescue) ~= "function" then return false, "not-downed" end
  return target_tree:_accept_rescue(env.player)
end

function LifeBehavior.cancel_rescue(self)
  local env = self.life_env
  if not env.rescue:now() then return false end
  env.rescue:set(nil)
  if env.states.life_phase:now() == "rescuing" then
    env.states.life_phase:set("downed")
    LifeBehavior.publish(self)
  end
  return true
end

-- ===== 重登恢复与平台复活 =====

function LifeBehavior.try_recover(self)
  local env = self.life_env
  local player, save_api, survival_cfg = env.player, env.save_api, env.survival_cfg
  if env.recover_flying or not env.recovering:now() then return end
  local inst = LifeBehavior.current_data(self)
  if not inst or not save_api or type(save_api.resolve_request) ~= "function" then return end
  local operation, mode = save_api:resolve_request(player, inst, "survival:recover", env.episode:now() + 1)
  if mode == "replay" then
    env.recovering:set(false)
    return
  end
  if not operation or type(save_api.execute) ~= "function" then return end
  env.recover_flying = true
  local accepted = save_api:execute(player, inst, operation, function(draft)
    local mark = draft.extra and draft.extra.survival
    if type(mark) ~= "table" then return nil, "no-mark" end
    mark.dying, mark.dead = false, false
    mark.dyingRemaining, mark.deadRemaining = 0, 0
    mark.weakRemaining = survival_cfg.WeakSec
    return { ok = true }
  end, function(written)
    env.recover_flying = false
    if env.tree:is_disposed() then return end
    if not written then return end
    env.recovering:set(false)
    local live = LifeBehavior.mark_table(self)
    if live and live ~= inst.extra.survival and inst.extra and inst.extra.survival then
      live.dying, live.dead = false, false
      live.dyingRemaining, live.deadRemaining = 0, 0
      live.weakRemaining = survival_cfg.WeakSec
    end
    self:_weak_revive()
  end)
  if not accepted then env.recover_flying = false end
end

function LifeBehavior.reopen_rescue_sec(self, deadline)
  if not deadline then return end
  local sec = math.floor(deadline)
  local env = self.life_env
  if sec < env.rescue_sec then env.rescue_sec = sec end
end

function LifeBehavior.resume_platform(self, pending)
  local env = self.life_env
  local paused = math.max(0, env.clock.now() - (pending.startedAt or env.clock.now()))
  local phase = env.states.life_phase:now()
  local now = env.clock.now()
  if phase == "dead" and env.dead_until:now() then
    env.dead_until:set(env.dead_until:now() + paused)
    if now + 1e-9 >= env.dead_until:now() then self:_weak_revive() else LifeBehavior.reopen_rescue_sec(self, env.dead_until:now()) end
  elseif (phase == "downed" or phase == "rescuing") and env.downed_until:now() then
    env.downed_until:set(env.downed_until:now() + paused)
    if now + 1e-9 >= env.downed_until:now() then LifeBehavior.enter_dead(self, false) else LifeBehavior.reopen_rescue_sec(self, env.downed_until:now()) end
  end
  LifeBehavior.publish(self)
end

-- ===== 生存动作分发 =====

function LifeBehavior.on_action(self, payload)
  if type(payload) ~= "table" then return end
  local seq = payload.seq
  local function fail(reason)
    LifeBehavior.reply(self, { seq = seq, ok = false, action = payload.action, mode = payload.mode, reason = reason })
  end
  if payload.action == "UseAdrenaline" then
    return LifeBehavior.on_use_adrenaline(self, payload, seq, fail)
  end
  if payload.action == "FullRevive" then
    return LifeBehavior.on_full_revive(self, payload, seq, fail)
  end
  if payload.action == "CallHelp" then
    return LifeBehavior.on_call_help(self, payload)
  end
end

function LifeBehavior.open_adrenaline_shop(self)
  local env = self.life_env
  local platform_api = env.platform_api
  if platform_api and type(platform_api.shop_action) == "function" then
    local ok_shop, err_shop = pcall(platform_api.shop_action, env.player, { action = "OpenAdrenaline" }); if not ok_shop then print("[PlayerLife] OpenAdrenaline 回调失败", env.player and env.player.UserId, tostring(err_shop)) end
  end
end

function LifeBehavior.adrenaline_written(self, written, seq, token, fail)
  local env = self.life_env
  env.adrenaline_flying = false
  if env.tree:is_disposed() then return end
  if not written or env.states.life_phase:now() ~= "downed" or env.episode:now() ~= token then
    return fail("not-downed")
  end
  LifeBehavior.rescue_success(self)
  LifeBehavior.reply(self, { seq = seq, ok = true, action = "UseAdrenaline" })
end

function LifeBehavior.on_use_adrenaline(self, _payload, seq, fail)
  local env = self.life_env
  local states, platform, save_api, survival_cfg = env.states, env.platform, env.save_api, env.survival_cfg
  if not finite_number(seq) or seq ~= math.floor(seq) or seq < 1 then return fail("invalid") end
  local inst = LifeBehavior.current_data(self)
  if states.life_phase:now() ~= "downed" or platform:now() or env.adrenaline_flying then
    return fail("not-downed")
  end
  if not inst or not save_api then return fail("unavailable") end
  local item_id = survival_cfg.AdrenalineItemId
  local count = type(inst.ItemCount) == "function" and inst:ItemCount(item_id) or 0
  if count < 1 then
    LifeBehavior.open_adrenaline_shop(self)
    return fail("no-adrenaline")
  end
  local operation, mode = save_api:resolve_request(env.player, inst, "survival:adrenaline", seq)
  if mode == "replay" then return fail("replay") end
  if not operation then return fail(tostring(mode)) end
  local token = env.episode:now()
  env.adrenaline_flying = true
  local accepted, why = save_api:execute(env.player, inst, operation, function(draft)
    if type(draft.ConsumeItem) ~= "function" or not draft:ConsumeItem(item_id) then
      return nil, "no-adrenaline"
    end
    return { ok = true, seq = seq }
  end, function(written)
    LifeBehavior.adrenaline_written(self, written, seq, token, fail)
  end)
  if not accepted then
    env.adrenaline_flying = false
    fail(why or "pending")
  end
end

function LifeBehavior.full_revive_mode(self, payload, seq, fail)
  local env = self.life_env
  if not finite_number(seq) or seq ~= math.floor(seq) or seq < 1 then return fail("invalid") end
  local mode = payload.mode
  if mode ~= "ad" and mode ~= "goods" then return fail("invalid") end
  local phase = env.states.life_phase:now()
  if phase ~= "downed" and phase ~= "dead" then return fail("not-revivable") end
  if phase == "downed" and mode ~= "ad" then return fail("not-dead") end
  if env.recovering:now() then return fail("recovering") end
  if env.platform:now() then return fail("busy") end
  if not env.platform_api then return fail("unavailable") end
  return mode
end

function LifeBehavior.request_platform_revive(self, mode, on_result)
  local env = self.life_env
  local platform_api = env.platform_api
  local accepted, reason
  if mode == "ad" and type(platform_api.show_ad) == "function" then
    accepted, reason = platform_api:show_ad(env.player, "revive", "revive", on_result)
  elseif mode == "goods" and type(platform_api.purchase) == "function" then
    accepted, reason = platform_api:purchase(env.player, "reviveFull", "revive", on_result)
  end
  return accepted, reason
end

function LifeBehavior.full_revive_result(self, pending, outcome)
  local env = self.life_env
  local platform = env.platform
  if platform:now() ~= pending or env.tree:is_disposed() then return end
  platform:set(nil)
  env.states.platform_pending:set(false)
  if outcome == "success" and env.episode:now() == pending.episode and LifeBehavior.full_revive(self) then
    LifeBehavior.reply(self, { seq = pending.seq, ok = true, action = "FullRevive", mode = pending.mode })
    return
  end
  LifeBehavior.resume_platform(self, pending)
  LifeBehavior.reply(self, {
    seq = pending.seq,
    ok = false,
    action = "FullRevive",
    mode = pending.mode,
    reason = outcome == "success" and "not-revivable" or tostring(outcome),
  })
end

function LifeBehavior.reject_full_revive(self, payload, pending, reason)
  local env = self.life_env
  if env.platform:now() == pending then
    env.platform:set(nil)
    env.states.platform_pending:set(false)
  end
  local why = reason or "unavailable"
  local platform_cfg = GameCfg.Platform or {}
  local text = why == "not_open" and platform_cfg.NotOpenText
    or why == "unavailable" and platform_cfg.UnavailableText or nil
  LifeBehavior.reply(self, { seq = payload.seq, ok = false, action = payload.action, mode = payload.mode,
    reason = why, text = text })
end

function LifeBehavior.on_full_revive(self, payload, seq, fail)
  local env = self.life_env
  local mode = LifeBehavior.full_revive_mode(self, payload, seq, fail)
  if not mode then return end
  local pending = {
    mode = mode,
    seq = seq,
    startedAt = env.clock.now(),
    episode = env.episode:now(),
  }
  env.platform:set(pending)
  env.states.platform_pending:set(true)
  local accepted, reason = LifeBehavior.request_platform_revive(self, mode, function(outcome)
    LifeBehavior.full_revive_result(self, pending, outcome)
  end)
  if not accepted then
    LifeBehavior.reject_full_revive(self, payload, pending, reason)
    return
  end
  LifeBehavior.publish(self)
end

function LifeBehavior.broadcast_help(self, event, origin)
  local env = self.life_env
  local survival_cfg, player, opts = env.survival_cfg, env.player, env.opts
  local _, uid = EngineRead.read_user_id(player, "PlayerLife.CallHelp")
  local _, pname = EngineRead.read_field(player, "Name", "PlayerLife.CallHelp")
  for _, other in ipairs(opts.players()) do
    if other ~= player and distance3(origin, position_of(other)) <= survival_cfg.HelpRadius then
      local ok_send, _, reason_send = EngineRead.call_method(event, "FireClient", "PlayerLife.CallHelp", other, { userId = uid, name = pname, text = survival_cfg.HelpCries[env.help_index] })
      if not ok_send then print("[PlayerLife] SurvivalHelp 下发失败", uid, other and other.UserId, tostring(reason_send)) end
    end
  end
end

function LifeBehavior.on_call_help(self, _payload)
  local env = self.life_env
  local states, clock, survival_cfg, player = env.states, env.clock, env.survival_cfg, env.player
  if states.life_phase:now() ~= "downed" then return end
  local now = clock.now()
  if env.last_help_at and now - env.last_help_at < survival_cfg.HelpCooldownSec then return end
  env.last_help_at = now
  env.help_index = (env.help_index % #survival_cfg.HelpCries) + 1
  if type(env.opts.players) ~= "function" then return end
  local ok, event, reason_ev = EngineRead.call_method(env.remote, "get_re", "PlayerLife.CallHelp", "SurvivalHelp")
  local origin = position_of(player)
  if not ok or not event then
    print("[PlayerLife] SurvivalHelp 通道获取失败", player and player.UserId, tostring(reason_ev or "missing"))
    return
  end
  if not origin then return end
  LifeBehavior.broadcast_help(self, event, origin)
end

function LifeBehavior.handle_survival_action(self, payload, skip_cd)
  local env = self.life_env
  if env.tree:is_disposed() or type(payload) ~= "table" then return false end
  if not skip_cd and env.remote and type(env.remote.check_recd) == "function"
      and env.remote:check_recd(env.player, "SurvivalAction", GameCfg.Items.ActionCooldownSec) then
    return false
  end
  LifeBehavior.on_action(self, payload)
  return true
end

-- ===== 秒与帧驱动 =====

function LifeBehavior.advance_alive_second(self, now)
  local env = self.life_env
  local states, vitals_cfg, tree = env.states, env.vitals_cfg, env.tree
  local sec = math.floor(now)
  if sec > env.last_hunger_sec then
    local elapsed = math.min(sec - env.last_hunger_sec, vitals_cfg.MaxCatchUpSec)
    env.last_hunger_sec = sec
    local hunger, damage = Vitals.advance(states.hunger:now(), elapsed, vitals_cfg)
    if hunger ~= states.hunger:now() then states.hunger:set(hunger) end
    if LifeBehavior.carrying_barrel(self, LifeBehavior.current_data(self)) then
      LifeBehavior.apply_damage(self, vitals_cfg.HeldDamage.DamagePerSec * elapsed, tree:new_hit(nil, "heldItem"))
    end
    if damage > 0 and states.life_phase:now() == "alive" then
      LifeBehavior.apply_damage(self, damage, tree:new_hit(nil, "hunger"))
    end
    LifeBehavior.write_vitals(self)
  end
  LifeBehavior.apply_walk(self)
  local health = read_health(env.player)
  if health and health <= 0 then LifeBehavior.enter_dead(self, true) end
end

function LifeBehavior.second_countdown(self, now, phase)
  local env = self.life_env
  if phase == "rescuing" then
    if env.downed_until:now() and now + 1e-9 >= env.downed_until:now() then
      LifeBehavior.enter_dead(self, false)
    end
  elseif phase == "downed" then
    if not env.adrenaline_flying and env.downed_until:now() and now + 1e-9 >= env.downed_until:now() then
      LifeBehavior.enter_dead(self, false)
    end
  elseif phase == "dead" then
    if env.recovering:now() then
      LifeBehavior.try_recover(self)
    elseif env.dead_until:now() and now + 1e-9 >= env.dead_until:now() then
      self:_weak_revive()
    end
  end
end

function LifeBehavior.on_second(self)
  local env = self.life_env
  if env.tree:is_disposed() or env.tree.session_alive:now() == false then return end
  local now = env.clock.now()
  local phase = env.states.life_phase:now()
  if phase ~= "alive" then env.last_hunger_sec = math.floor(now) end
  if env.platform:now() and phase ~= "alive" then return end
  if phase ~= "alive" then
    LifeBehavior.second_countdown(self, now, phase)
    return
  end
  if not env.recovering:now() then LifeBehavior.advance_alive_second(self, now) end
end

function LifeBehavior.on_second_tick(self, sec)
  local env = self.life_env
  if sec <= env.rescue_sec then return end
  if env.platform:now() and env.states.life_phase:now() ~= "alive" then
    env.rescue_sec = sec - 1
    return
  end
  env.rescue_sec = sec
  LifeBehavior.on_second(self)
end

function LifeBehavior.need_frame_watch(self, ms)
  local env = self.life_env
  local phase = ms:d(env.states.life_phase)
  local paused = ms:d(env.platform)
  return phase ~= "alive" and (phase == "rescuing" or not paused)
end

function LifeBehavior.frame_countdown(self, now, phase)
  local env = self.life_env
  if env.platform:now() then return false end
  local downed_until = env.downed_until:now()
  if phase == "downed" and not env.adrenaline_flying and downed_until
      and now + 1e-9 >= downed_until then
    LifeBehavior.enter_dead(self, false)
    return true
  end
  local dead_until = env.dead_until:now()
  if phase == "dead" and not env.recovering:now() and dead_until
      and now + 1e-9 >= dead_until then
    self:_weak_revive()
    return true
  end
  return false
end

function LifeBehavior.frame_rescue(self, now)
  local env = self.life_env
  local opts, rescue_cfg, player = env.opts, env.rescue_cfg, env.player
  local current = env.rescue:now()
  if not current then return end
  local rescuer = current.by
  local ok_ruid, ruid = EngineRead.read_user_id(rescuer, "PlayerLife.LifeCountdownFrame")
  local rescuer_tree = opts.lookup_tree and ok_ruid and opts.lookup_tree(ruid)
  local from = position_of(rescuer)
  local moved = from and current.startPos and horizontal_distance(from, current.startPos) > (rescue_cfg.InterruptMoveMeters or 1)
  local health = read_health(rescuer)
  local hurt = rescue_cfg.InterruptOnDamage and health and current.health and health < current.health
  local rescuer_down = not rescuer_tree or rescuer_tree.states.life_phase:now() ~= "alive"
  if moved or hurt or rescuer_down or not from or not position_of(player) then
    LifeBehavior.cancel_rescue(self)
    return
  end
  if now + 1e-9 >= current.endAt then
    local downed_until = env.downed_until:now()
    if downed_until and now + 1e-9 >= downed_until and not env.platform:now() then
      LifeBehavior.enter_dead(self, false)
    else
      env.rescue:set(nil)
      LifeBehavior.rescue_success(self)
    end
  end
end

function LifeBehavior.on_life_frame(self, frame)
  local env = self.life_env
  if env.tree:is_disposed() or env.tree.session_alive:now() == false then return end
  local now = frame and frame.now or env.clock.now()
  local phase = env.states.life_phase:now()
  if LifeBehavior.frame_countdown(self, now, phase) then return end
  if phase ~= "rescuing" then return end
  LifeBehavior.frame_rescue(self, now)
end

-- ===== 生命事件接线与一次性收尾 =====

function LifeBehavior.note_health(self, next_health)
  local env = self.life_env
  local before = env.noticed_health
  env.noticed_health = next_health
  if env.suppress_health_note then return end
  if not finite_number(before) or not finite_number(next_health) or next_health >= before then return end
  if env.states.life_phase:now() ~= "alive" then return end
  LifeBehavior.publish_notice(self, before - next_health)
end

function LifeBehavior.on_health_changed(self, next_health)
  local env = self.life_env
  if env.tree:is_disposed() then return end
  LifeBehavior.note_health(self, next_health)
end

function LifeBehavior.on_died(self)
  local env = self.life_env
  if env.tree:is_disposed() then return end
  if env.states.life_phase:now() == "alive" then LifeBehavior.enter_dead(self, true) end
end

function LifeBehavior.finish_spawn(self)
  local env = self.life_env
  local states, survival_cfg, tree, player = env.states, env.survival_cfg, env.tree, env.player
  local raw = env.raw
  if type(tree.capture_base_speed) == "function" then
    local ok_ch, ch = EngineRead.read_character(player, "PlayerLife.finish_spawn")
    tree:capture_base_speed(ok_ch and ch or nil)
  end
  LifeBehavior.apply_walk(self)
  if (raw.dying or raw.dead) and states.life_phase:now() ~= "alive" then
    env.recovering:set(true)
    states.life_phase:set("dead")
    LifeBehavior.set_controller_health(self, 1)
    LifeBehavior.publish(self)
    LifeBehavior.try_recover(self)
  elseif finite_number(raw.weakRemaining) and raw.weakRemaining > 0 and not raw.dying and not raw.dead then
    local seconds = math.min(raw.weakRemaining, survival_cfg.WeakSec)
    if tree:get_modifier_remaining("weak") <= 0 then
      tree:apply_modifier("weak", { duration = seconds })
    end
    LifeBehavior.publish(self)
  else
    LifeBehavior.write_vitals(self)
    write_attr(player, "SurvivalPhase", states.life_phase:now())
  end
  tree:register_leave_finalizer(function()
    LifeBehavior.publish(self)
    local inst = LifeBehavior.current_data(self)
    local mark = LifeBehavior.mark_table(self)
    if type(inst) == "table" and inst ~= env.data and type(mark) == "table" then
      if type(inst.extra) ~= "table" then inst.extra = {} end
      inst.extra.survival = mark
    end
  end)
end

-- ===== 装配 =====

-- 挂回玩家树的方法：名字与签名沿用拆分前的接口（外部以 :method(...) 调用）。
local TREE_METHODS = {
  "new_hit",
  "resolve_hit_source",
  "set_damage_filter",
  "apply_hit",
  "request_action",
  "eat",
  "_accept_rescue",
  "begin_rescue",
  "cancel_rescue",
  "handle_survival_action",
  "apply_walk",
  "reapply_growth",
}

-- 把行为表挂到玩家树上；依赖统一从 tree.life_env 读取。
function LifeBehavior.install(tree, env)
  tree.life_env = env
  for _, name in ipairs(TREE_METHODS) do
    tree[name] = LifeBehavior[name]
  end
  tree._weak_revive = LifeBehavior.weak_revive
  tree._life_finish = function()
    LifeBehavior.finish_spawn(tree)
  end
end

-- Spoke 作用域接线：注册顺序与拆分前 mount 内的 s3:effect / subscribe / memo / phase 一致。
function LifeBehavior.wire_spoke(s3, tree)
  local env = tree.life_env
  local states = env.states
  s3:effect("WeakSpeedWatch", function(es)
    es:d(states.is_weak)
    es:d(states.is_frost)
    es:d(states.is_paralyzed)
    LifeBehavior.apply_walk(tree)
  end)

  s3:subscribe(env.clock.on_second, function(sec)
    LifeBehavior.on_second_tick(tree, sec)
  end)

  local need_frame_watch = s3:memo("NeedLifeFrameWatch", function(ms)
    return LifeBehavior.need_frame_watch(tree, ms)
  end)
  s3:phase("LifeCountdownFrame", need_frame_watch, function(rs)
    rs:subscribe(env.clock.on_frame, function(frame)
      LifeBehavior.on_life_frame(tree, frame)
    end)
  end)
end

-- 引擎事件接线：健康变更与死亡信号，清理函数归 Spoke 作用域。
function LifeBehavior.wire_controller(s3, tree)
  local env = tree.life_env
  env.noticed_health = read_health(env.player)
  local controller = controller_of(env.player)
  if controller and controller.HealthChanged and type(controller.HealthChanged.Connect) == "function" then
    local conn
    conn = controller.HealthChanged:Connect(function(next_health)
      LifeBehavior.on_health_changed(tree, next_health)
    end)
    s3:on_cleanup(function()
      EngineRead.disconnect(conn, "PlayerLife.HealthChanged.cleanup")
    end)
  end
  if controller and controller.Died and type(controller.Died.Connect) == "function" then
    local conn
    conn = controller.Died:Connect(function()
      LifeBehavior.on_died(tree)
    end)
    s3:on_cleanup(function()
      EngineRead.disconnect(conn, "PlayerLife.Died.cleanup")
    end)
  end
end

-- 挂载生命模块：先建环境并装配行为表，再按拆分前的顺序接线。
function PlayerLife.mount(s3, player_tree, opts)
  local env = LifeBehavior.new_env(player_tree, opts)
  LifeBehavior.install(player_tree, env)
  LifeBehavior.wire_spoke(s3, player_tree)
  LifeBehavior.wire_controller(s3, player_tree)
end

return PlayerLife
