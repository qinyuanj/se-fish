local EngineRead = require("common.engine_read")
local GameCfg = require("common.game_cfg")
local FlightPath = require("common.flight_path")
local Number = require("common.number")
local SpecialItem = require("common.special_item")
local State = require("common.packages.spoke.api").State

local SpecialItemPhase = {}
-- 特殊道具阶段行为表：拆分前都是 SpecialItemPhase.mount 体内的闭包，方法名、参数顺序与返回值不变。
-- 对外四个入口由 install 挂到玩家树上，调用方照旧 player_tree:method(...)；
-- 其余内部方法只在模块内以 SpecialItemBehavior.xxx(self, ...) 调用，不占树面。
-- 拆分前 mount 体内的状态与依赖统一放进 player_tree.special_item_env，字段名沿用拆分前的局部变量名。
local SpecialItemBehavior = {}

local CLEANUP_RETRY_SEC = 1
local CLEANUP_RETRIES = 5

local function cfg()
  return GameCfg.Ability.SpecialItem
end

local function breath_cfg()
  return cfg().Godzilla.Breath
end

local function finite(value)
  return Number.is_finite_number(value)
end

local function now_of(env)
  return env.clock.now()
end

local function flat_forward(rotation, user_id)
  if not EngineRead.is_object(rotation) then
    print("[SpecialItemPhase] 角色旋转读取失败", tostring(user_id), "no-rotation")
    return nil
  end
  local ok_fwd, forward, fwd_reason = EngineRead.call_method(
    rotation, "GetForward", "SpecialItemPhase.flat_forward"
  )
  if not ok_fwd then
    print(
      "[SpecialItemPhase] 角色朝向读取失败",
      tostring(user_id),
      tostring(fwd_reason)
    )
    return nil
  end
  local ok_v, vec, vec_reason = EngineRead.read_vec3(
    forward, "SpecialItemPhase.flat_forward")
  if not ok_v or not vec then
    print("[SpecialItemPhase] 角色朝向读取失败", tostring(user_id), tostring(vec_reason))
    return nil
  end
  local fx, fz = vec.x, vec.z
  local len = math.sqrt(fx * fx + fz * fz)
  if not finite(len) or len < 1e-6 then
    print(
      "[SpecialItemPhase] 角色水平朝向无效",
      tostring(user_id),
      "zero-flat-forward"
    )
    return nil
  end
  return { x = fx / len, z = fz / len }
end

local function in_corridor(origin, forward, pos, breath)
  if not EngineRead.is_object(pos) or not finite(pos.x) or not finite(pos.y) or not finite(pos.z) then
    return false
  end
  local dx, dz = pos.x - origin.x, pos.z - origin.z
  local along = dx * forward.x + dz * forward.z
  if along < 0 or along > breath.Range then return false end
  local perp = math.abs(dx * forward.z - dz * forward.x)
  if perp > breath.Width then return false end
  if math.abs(pos.y - origin.y) > breath.Width then return false end
  return true
end

local function read_position(character)
  local ok, pos = EngineRead.read_position(character, "SpecialItemPhase.read_position")
  if ok then
    return pos
  end
  return nil
end

local function write_position(character, x, y, z)
  local ok_vec, pos_vec = EngineRead.new_vector3(x, y, z, "SpecialItemPhase.write_position")
  if not ok_vec then
    return false
  end
  return EngineRead.write_field(character, "Position", pos_vec, "SpecialItemPhase.write_position")
end

local function selected_item_id(item_bar, selected_slot)
  if type(selected_slot) ~= "number" or type(item_bar) ~= "table" then return nil end
  local entry = item_bar[selected_slot]
  if type(entry) ~= "table" or (entry.count or 0) <= 0 then return nil end
  return entry.itemId
end

-- ===== 引擎调用与下发 =====

function SpecialItemBehavior.character_of(self)
  local env = self.special_item_env
  local ch = env.cleanup_character or env.states.character:now()
  if ch then return ch end
  local ok, current = EngineRead.read_character(env.player, "SpecialItemPhase.character_of")
  return ok and current or nil
end

function SpecialItemBehavior.log_failure(self, key, object, err)
  local env = self.special_item_env
  if not env.failures[key] then
    print("[SpecialItemPhase] 引擎操作失败", key, tostring(object), tostring(err))
  end
end

function SpecialItemBehavior.engine_call(self, key, object, fn)
  local env = self.special_item_env
  local failure = env.failures[key]
  if failure and now_of(env) < failure.next_at then return false end
  local ok, result = pcall(fn)
  if ok and result ~= false then
    env.failures[key] = nil
    return true, result
  end
  SpecialItemBehavior.log_failure(self, key, object, result)
  env.failures[key] = { next_at = now_of(env) + CLEANUP_RETRY_SEC }
  return false
end

function SpecialItemBehavior.fire_client(self, name, payload)
  local env = self.special_item_env
  EngineRead.fire_client(
    env.remote, name,
    env.player, payload,
    "SpecialItemPhase.fire_client"
  )
end

function SpecialItemBehavior.reply(self, payload)
  SpecialItemBehavior.fire_client(self, "SpecialItemResult", payload)
end

function SpecialItemBehavior.fail(self, action, reason)
  local env = self.special_item_env
  print("[SpecialItemPhase] 请求拒绝", env.player.UserId, action, tostring(reason))
  SpecialItemBehavior.reply(self, { ok = false, action = action, reason = reason })
  return false
end

-- ===== 龙息冷却 =====

function SpecialItemBehavior.anchor_breath(self, stored)
  local env = self.special_item_env
  if type(env.breath_ready_at) == "number" then return end
  if type(stored) ~= "number" or stored <= 0 then return end
  env.breath_ready_at = now_of(env) + stored
end

function SpecialItemBehavior.stored_breath_remaining(self)
  local env = self.special_item_env
  local mark = env.states.cooldowns:now()
  local stored = type(mark) == "table" and mark.godzillaBreath or nil
  if type(stored) ~= "number" or stored <= 0 then return 0 end
  return stored
end

function SpecialItemBehavior.breath_remaining(self)
  local env = self.special_item_env
  local ready = env.breath_ready_at
  if type(ready) ~= "number" then
    SpecialItemBehavior.anchor_breath(self, SpecialItemBehavior.stored_breath_remaining(self))
    ready = env.breath_ready_at
  end
  if type(ready) ~= "number" then return 0 end
  return SpecialItem.cooldown_remaining(ready - breath_cfg().CooldownSec, now_of(env), breath_cfg().CooldownSec)
end

function SpecialItemBehavior.publish(self)
  local env = self.special_item_env
  local remaining = SpecialItemBehavior.breath_remaining(self)
  env.published_breath = math.ceil(remaining - 1e-9)
  SpecialItemBehavior.fire_client(self, "SpecialItemState", {
    effect = env.restoring and nil or env.effect,
    airborne = env.airborne,
    breathRemaining = remaining,
  })
end

function SpecialItemBehavior.write_cooldown(self, remaining)
  local env = self.special_item_env
  env.breath_ready_at = now_of(env) + remaining
  local mark = env.states.cooldowns:now()
  local next_mark = {}
  if type(mark) == "table" then
    for key, value in pairs(mark) do next_mark[key] = value end
  end
  next_mark.godzillaBreath = remaining
  env.states.cooldowns:set(next_mark)
end

function SpecialItemBehavior.mirror_cooldown(self)
  local env = self.special_item_env
  if type(env.breath_ready_at) ~= "number" then return end
  local remaining = SpecialItemBehavior.breath_remaining(self)
  local mark = env.states.cooldowns:now()
  local stored = type(mark) == "table" and mark.godzillaBreath or 0
  if math.abs((stored or 0) - remaining) >= 0.05 then
    local next_mark = {}
    if type(mark) == "table" then
      for key, value in pairs(mark) do next_mark[key] = value end
    end
    next_mark.godzillaBreath = remaining
    env.states.cooldowns:set(next_mark)
  end
  local shown = math.ceil(remaining - 1e-9)
  if shown ~= env.published_breath then SpecialItemBehavior.publish(self) end
end

-- ===== 外观与重力 =====

function SpecialItemBehavior.set_gravity(self, enabled)
  local env = self.special_item_env
  local character = env.gravity_character or SpecialItemBehavior.character_of(self)
  local ok = SpecialItemBehavior.engine_call(self, "gravity", character, function()
    local controller = character and character.Controller
    if not controller then error("no-controller") end
    controller.GravityEnabled = enabled
    return true
  end)
  if ok then
    env.gravity_off = not enabled
    env.gravity_character = not enabled and character or nil
  end
  return ok
end

function SpecialItemBehavior.destroy_unit(self, key, unit)
  if not unit then return true end
  return SpecialItemBehavior.engine_call(self, key, unit, function()
    unit:Destroy()
    return true
  end)
end

function SpecialItemBehavior.restore(self)
  local env = self.special_item_env
  env.holding = false
  env.airborne = false
  env.flight_y = nil
  env.flight_ground_y = nil
  env.breath = nil
  local character = SpecialItemBehavior.character_of(self)
  local current_appearance = env.appearance or (character and character.EggyAppearance)
  if env.placeholder_model then
    if SpecialItemBehavior.destroy_unit(self, "placeholderDestroy", env.placeholder_model) then env.placeholder_model = nil end
  end
  if env.placeholder_mount and not env.placeholder_model then
    if SpecialItemBehavior.destroy_unit(self, "placeholderUnmount", env.placeholder_mount) then env.placeholder_mount = nil end
  end
  if env.wing_bind_id and current_appearance then
    local bind_id = env.wing_bind_id
    if SpecialItemBehavior.engine_call(self, "unbind", current_appearance, function()
      return current_appearance:UnbindAppearance(bind_id)
    end) then
      env.wing_bind_id = nil
    end
  end
  if env.skin_applied and current_appearance then
    if SpecialItemBehavior.engine_call(self, "reset", current_appearance, function()
      current_appearance:ResetAppearance()
      return true
    end) then
      env.skin_applied = false
    end
  end
  if env.gravity_off then SpecialItemBehavior.set_gravity(self, true) end
  if env.wing_bind_id or env.skin_applied or env.gravity_off or env.placeholder_mount or env.placeholder_model then
    env.restoring = true
    env.cleanup_active:set(true)
    return false
  end
  env.restoring = false
  env.cleanup_active:set(false)
  env.effect = nil
  env.appearance = nil
  return true
end

function SpecialItemBehavior.apply_effect(self, desired)
  local env = self.special_item_env
  local character = SpecialItemBehavior.character_of(self)
  local current_appearance = character and character.EggyAppearance
  if desired == "wings" and cfg().Wings.AppearanceAssetId then
    local wings = cfg().Wings
    local ok, bind_id = SpecialItemBehavior.engine_call(self, "bind", current_appearance, function()
      return current_appearance:BindAppearance(
        wings.AppearanceAssetId,
        Enums.SkeletalSocketType[wings.Socket],
        Vector3.New(wings.Offset.x, wings.Offset.y, wings.Offset.z),
        Quaternion.Identity(),
        Vector3.New(1, 1, 1))
    end)
    if not ok or type(bind_id) ~= "number" then return false end
    env.wing_bind_id = bind_id
    env.appearance = current_appearance
  elseif desired == "godzilla" and cfg().Godzilla.AppearanceAssetId then
    if not SpecialItemBehavior.engine_call(self, "skin", current_appearance, function()
      current_appearance:SetAppearanceByAssetId(cfg().Godzilla.AppearanceAssetId)
      return true
    end) then
      return false
    end
    env.skin_applied = true
    env.appearance = current_appearance
  else
    local visual = GameCfg.PlaceholderAssets and GameCfg.PlaceholderAssets.Special
      and GameCfg.PlaceholderAssets.Special[desired]
    if visual and type(env.create_unit) == "function" then
      local ok, mount = SpecialItemBehavior.engine_call(self, "placeholderMount", character, function()
        return env.create_unit("SkeletalSocketMount", {
          Name = "SpecialPlaceholderMount_" .. tostring(env.player.UserId),
          Parent = character,
          SocketName = visual.Socket,
          SocketOffset = Vector3.New(visual.Offset.x, visual.Offset.y, visual.Offset.z),
        })
      end)
      if not ok or not mount then return false end
      local model_ok, model = SpecialItemBehavior.engine_call(self, "placeholderModel", mount, function()
        return env.create_unit("WorldUnit", {
          Name = "SpecialPlaceholder_" .. desired,
          Parent = mount,
          RenderMeshId = visual.Mesh,
          Scale = Vector3.New(visual.Scale.x, visual.Scale.y, visual.Scale.z),
          PhysicsActive = false,
          CanCollide = false,
          CanTouch = false,
          CanTrigger = false,
          CanQuery = false,
        })
      end)
      if not model_ok or not model then
        if SpecialItemBehavior.destroy_unit(self, "placeholderUnmount", mount) then
          env.placeholder_mount = nil
        else
          env.placeholder_mount = mount
        end
        return false
      end
      env.placeholder_mount = mount
      env.placeholder_model = model
    end
  end
  env.effect = desired
  env.restoring = false
  env.cleanup_active:set(false)
  return true
end

-- ===== 选择与对账 =====

function SpecialItemBehavior.current_selection(self)
  local env = self.special_item_env
  local record = self.data
  local data_part = type(record) == "table" and record.data or nil
  if type(data_part) == "table" then
    local containers = type(data_part.containers) == "table" and data_part.containers or {}
    return selected_item_id(containers[GameCfg.Items.ContainerId.ItemBar], data_part.selected_slot)
  end
  return selected_item_id(env.states.item_bar:now(), env.states.selected_slot:now())
end

function SpecialItemBehavior.desired_effect(self)
  local env = self.special_item_env
  if (self.tree and self.tree.is_detached == true) or self.session_alive:now() == false then return nil end
  if env.memos.is_alive:now() ~= true then return nil end
  local selected = SpecialItemBehavior.current_selection(self)
  if env.suspended and selected ~= env.suspended_item then
    env.suspended = false
    env.suspended_item = nil
  end
  if env.suspended then return nil end
  return SpecialItem.desired(selected)
end

function SpecialItemBehavior.reconcile(self)
  local env = self.special_item_env
  local desired = SpecialItemBehavior.desired_effect(self)
  if desired == env.effect and not env.restoring then return end
  if not SpecialItemBehavior.restore(self) then
    SpecialItemBehavior.publish(self)
    return
  end
  if desired and SpecialItemBehavior.character_of(self) then
    SpecialItemBehavior.apply_effect(self, desired)
  end
  SpecialItemBehavior.publish(self)
end

-- ===== 飞行与龙息驱动 =====

function SpecialItemBehavior.update_flight(self, dt)
  local env = self.special_item_env
  if env.effect ~= "wings" or env.restoring then return end
  local character = SpecialItemBehavior.character_of(self)
  local pos = read_position(character)
  if not pos then return end
  local wings = cfg().Wings
  if env.airborne and not env.holding and env.flight_y and pos.y > env.flight_y + wings.LandEpsilon then
    env.airborne = false
  end
  if not env.holding and not env.airborne then
    if env.gravity_off then SpecialItemBehavior.set_gravity(self, true) end
    env.flight_y = nil
    env.flight_ground_y = nil
    SpecialItemBehavior.publish(self)
    return
  end
  local scene = GameCfg.zone_scene(env.states.zone_id:now())
  local bounds = scene and FlightPath.bounds_of(scene, GameCfg.Ability.Flight)
  if not bounds then return end
  if not env.flight_ground_y then env.flight_ground_y = pos.y end
  bounds.ground_y = env.flight_ground_y
  bounds.ceiling_y = math.min(bounds.ceiling_y, env.flight_ground_y + bounds.MaxHeight)
  if not SpecialItemBehavior.set_gravity(self, false) then return end
  local y, next_airborne = SpecialItem.step_flight_y(wings, {
    Y = env.flight_y or pos.y,
    airborne = env.airborne,
  }, env.holding, dt, bounds)
  local x, z = SpecialItem.clamp_xz(bounds, pos.x, pos.z)
  if not write_position(character, x, y, z) then return end
  env.flight_y = y
  env.airborne = next_airborne
  if not env.airborne then
    SpecialItemBehavior.set_gravity(self, true)
    env.flight_y = nil
    env.flight_ground_y = nil
  end
  SpecialItemBehavior.publish(self)
end

--- 玩家目标：在线玩家中除自己以外、位置可读的那些。
---@param self table 特殊道具句柄
---@param env table 特殊道具环境
---@param player table 施放者
---@return table[] 目标列表
local function breath_player_targets(self, env, player)
  local targets = {}
  local online_players = env.online_players
  if type(online_players) == "function" then
    local ok, list = pcall(online_players)
    if ok and type(list) == "table" then
      for _, other in ipairs(list) do
        if other ~= player then
          local ok_pos, pos = EngineRead.read_player_position(other, "SpecialItemPhase.breath_targets")
          local ok_uid, other_uid = EngineRead.read_user_id(other, "SpecialItemPhase.breath_targets")
          if ok_pos and pos then
            targets[#targets + 1] = {
              key = "player:" .. tostring(ok_uid and other_uid or nil),
              pos = pos,
              apply = function(amount)
                if type(self.apply_hit) == "function" then
                  self:apply_hit(self:new_hit(player, "specialBreath"), other, amount)
                end
              end,
            }
          end
        end
      end
    end
  end
  return targets
end

--- 活鱼表：优先读环境回调，其次读句柄缓存。
---@param self table 特殊道具句柄
---@param env table 特殊道具环境
---@return table? 活鱼表
local function breath_fish_list(self, env)
  local fish = env.fish_units
  if type(fish) == "function" then
    local ok, list = pcall(fish)
    fish = ok and list or nil
  end
  if type(fish) ~= "table" and self.fish_units then return self.fish_units end
  return fish
end

--- 鱼目标：按载体位置把活鱼追加进目标表。
---@param self table 特殊道具句柄
---@param env table 特殊道具环境
---@param player table 施放者
---@param fish table? 活鱼表
---@param targets table[] 目标列表
local function append_breath_fish(self, env, player, fish, targets)
  if type(fish) ~= "table" then return end
  for _, entry in pairs(fish) do
    local carrier = entry and (entry.carrier or entry)
    local body = carrier and carrier.body
    local pos = body and read_position(body) or read_position(carrier)
    if carrier and not carrier.dead and pos then
      targets[#targets + 1] = {
        key = "fish:" .. tostring(entry.Id or carrier.Id or "unknown"),
        pos = pos,
        apply = function(amount)
          local hit = self:new_hit(player, "specialBreath")
          if type(self.apply_hit) == "function" and self:apply_hit(hit, carrier, amount) then return end
          local fish_carrier = env.fish_carrier
          if fish_carrier and type(fish_carrier.Damage) == "function" then
            fish_carrier:Damage(carrier, amount, hit)
          end
        end,
      }
    end
  end
end

function SpecialItemBehavior.breath_targets(self)
  local env = self.special_item_env
  local player = env.player
  local targets = breath_player_targets(self, env, player)
  append_breath_fish(self, env, player, breath_fish_list(self, env), targets)
  return targets
end

function SpecialItemBehavior.update_breath(self, current)
  local env = self.special_item_env
  if not env.breath then return end
  local bc = breath_cfg()
  local plan = env.breath.ledger.plan
  while env.breath.tick <= #plan and current + 1e-9 >= env.breath.cast_at + (env.breath.tick - 1) * bc.TickSec do
    local tick = env.breath.tick
    for _, target in ipairs(SpecialItemBehavior.breath_targets(self)) do
      if in_corridor(env.breath.origin, env.breath.forward, target.pos, bc) then
        local amount = SpecialItem.breath_hit(env.breath.ledger, target.key, tick)
        if amount then target.apply(amount) end
      end
    end
    env.breath.tick = tick + 1
  end
  if current + 1e-9 >= env.breath.cast_at + bc.DurationSec then
    env.breath = nil
    SpecialItemBehavior.publish(self)
  end
end

function SpecialItemBehavior.cast_breath(self)
  local env = self.special_item_env
  local player = env.player
  if env.restoring or env.effect ~= "godzilla" then return SpecialItemBehavior.fail(self, "breath", "not-godzilla") end
  if env.memos.can_act:now() ~= true then return SpecialItemBehavior.fail(self, "breath", "not-alive") end
  local character = SpecialItemBehavior.character_of(self)
  local pos = read_position(character)
  if not pos then return SpecialItemBehavior.fail(self, "breath", "no-character") end
  local bc = breath_cfg()
  if SpecialItemBehavior.breath_remaining(self) > 0 then return SpecialItemBehavior.fail(self, "breath", "cooldown") end
  local rot_ok, rotation, rot_reason = EngineRead.read_field(
    character, "Rotation", "SpecialItemPhase.cast_breath"
  )
  if not rot_ok then
    print("[SpecialItemPhase] 角色旋转读取失败", tostring(player and player.UserId), tostring(rot_reason))
    return SpecialItemBehavior.fail(self, "breath", "no-forward")
  end
  local forward = flat_forward(rotation, player and player.UserId)
  if not forward then return SpecialItemBehavior.fail(self, "breath", "no-forward") end
  local current = now_of(env)
  SpecialItemBehavior.write_cooldown(self, bc.CooldownSec)
  env.breath = {
    cast_at = current,
    tick = 1,
    ledger = SpecialItem.new_breath_ledger(bc),
    origin = { x = pos.x, y = pos.y, z = pos.z },
    forward = forward,
  }
  SpecialItemBehavior.reply(self, { ok = true, action = "breath", endsAt = current + bc.DurationSec })
  SpecialItemBehavior.publish(self)
  return true
end

-- ===== 请求入口 =====

function SpecialItemBehavior.on_action(self, sender, payload)
  local env = self.special_item_env
  local player = env.player
  if sender ~= player or (self.tree and self.tree.is_detached == true) then return end
  if self.session_alive:now() == false then return end
  if type(payload) ~= "table" then return end
  SpecialItemBehavior.reconcile(self)
  if payload.action == "fly" then
    local release = payload.holding ~= true
    if not release and env.remote and type(env.remote.check_recd) == "function" then
      local limited = env.remote:check_recd(player, "SpecialItemAction", cfg().ReLimitSec)
      if limited then return end
    end
    if env.restoring or env.effect ~= "wings" or env.memos.can_act:now() ~= true then
      env.holding = false
      return SpecialItemBehavior.fail(self, "fly", "not-wings")
    end
    env.holding = payload.holding == true
    return true
  end
  if payload.action == "breath" then
    if env.remote and type(env.remote.check_recd) == "function" then
      local limited = env.remote:check_recd(player, "SpecialItemAction", cfg().ReLimitSec)
      if limited then return end
    end
    return SpecialItemBehavior.cast_breath(self)
  end
end

function SpecialItemBehavior.on_query(self, sender)
  local env = self.special_item_env
  local player = env.player
  if sender ~= player or (self.tree and self.tree.is_detached == true) or self.session_alive:now() == false then
    return false
  end
  if env.remote and type(env.remote.check_recd) == "function" then
    if env.remote:check_recd(player, "SpecialItemStateRequest", cfg().ReLimitSec) then return false end
  end
  SpecialItemBehavior.publish(self)
  return true
end

-- ===== Spoke 驱动与清理 =====

function SpecialItemBehavior.drive(self, es)
  local env = self.special_item_env
  es:d(env.states.item_bar)
  es:d(env.states.selected_slot)
  es:d(env.states.character)
  local zone_id = es:d(env.states.zone_id)
  es:d(env.memos.is_alive)
  if env.seen_zone == nil then env.seen_zone = zone_id end
  if zone_id ~= env.seen_zone then
    env.seen_zone = zone_id
    if env.effect ~= nil or env.holding or env.airborne or env.gravity_off then
      env.suspended = true
      env.suspended_item = SpecialItemBehavior.current_selection(self)
      env.holding = false
      env.airborne = false
      env.flight_y = nil
      env.flight_ground_y = nil
    end
  end
  local desired = SpecialItemBehavior.desired_effect(self)
  if env.selected_phase:now() ~= desired then
    env.selected_phase:set(desired)
  else
    SpecialItemBehavior.reconcile(self)
  end
end

function SpecialItemBehavior.fly_frame(self, frame)
  local env = self.special_item_env
  if self.session_alive:now() == false then return end
  local current = frame and frame.now or now_of(env)
  if env.restoring then SpecialItemBehavior.retry_cleanup(self, current) return end
  env.retries = 0
  SpecialItemBehavior.reconcile(self)
  SpecialItemBehavior.mirror_cooldown(self)
  local step = frame and frame.dt or 0
  while step > 1e-9 do
    local slice = math.min(step, cfg().Wings.MaxStepSec)
    SpecialItemBehavior.update_flight(self, slice)
    step = step - slice
  end
end

function SpecialItemBehavior.breath_frame(self, frame)
  local env = self.special_item_env
  if self.session_alive:now() == false then return end
  local current = frame and frame.now or now_of(env)
  if env.restoring then SpecialItemBehavior.retry_cleanup(self, current) return end
  env.retries = 0
  SpecialItemBehavior.reconcile(self)
  SpecialItemBehavior.mirror_cooldown(self)
  SpecialItemBehavior.update_breath(self, current)
end

function SpecialItemBehavior.retry_cleanup(self, current)
  local env = self.special_item_env
  if current + 1e-9 >= env.retry_after and env.retries < CLEANUP_RETRIES then
    env.retries = env.retries + 1
    env.retry_after = current + CLEANUP_RETRY_SEC
    for key, failure in pairs(env.failures) do
      if failure.next_at and failure.next_at <= current + 1e-9 then env.failures[key] = nil end
    end
    SpecialItemBehavior.reconcile(self)
  end
  SpecialItemBehavior.mirror_cooldown(self)
end

-- 作用域收尾：先记下角色再重试还原，最后补一次快照。
function SpecialItemBehavior.special_release(self)
  local env = self.special_item_env
  env.cleanup_character = SpecialItemBehavior.character_of(self)
  for _ = 1, CLEANUP_RETRIES do
    if SpecialItemBehavior.restore(self) then break end
  end
  SpecialItemBehavior.publish(self)
end

-- 离场终镜像：把龙息剩余冷却写进玩家存档副本。
function SpecialItemBehavior.write_leave_breath(self)
  local remaining = SpecialItemBehavior.breath_remaining(self)
  if type(self.data) == "table" then
    if type(self.data.extra) ~= "table" then self.data.extra = {} end
    if type(self.data.extra.cooldowns) ~= "table" then
      self.data.extra.cooldowns = {}
    end
    self.data.extra.cooldowns.godzillaBreath = remaining
  end
end

-- ===== 对外入口（install 挂到玩家树上） =====

function SpecialItemBehavior.handle_special_item_action(self, payload)
  local env = self.special_item_env
  if not env.mounted then return false end
  return SpecialItemBehavior.on_action(self, env.player, payload)
end

function SpecialItemBehavior.handle_special_item_query(self)
  local env = self.special_item_env
  if not env.mounted then return false end
  return SpecialItemBehavior.on_query(self, env.player)
end

function SpecialItemBehavior.suspend_special_item(self)
  local env = self.special_item_env
  env.suspended = true
  env.suspended_item = SpecialItemBehavior.current_selection(self)
  env.holding = false
  env.airborne = false
  env.flight_y = nil
  env.flight_ground_y = nil
  SpecialItemBehavior.reconcile(self)
  return not env.restoring
end

function SpecialItemBehavior.special_item_effect(self)
  local env = self.special_item_env
  if env.restoring or self.session_alive:now() == false then return nil end
  return env.effect
end

-- 对外方法面：挂到玩家树上的四个入口，其余内部方法只在模块内调用。
local TREE_METHODS = {
  "handle_special_item_action",
  "handle_special_item_query",
  "suspend_special_item",
  "special_item_effect",
}

--- 建环境：拆分前 mount 开头的状态量与注入依赖，字段名沿用拆分前的局部变量名。
---@param player_tree table
---@param opts table
---@return table
local function build_env(player_tree, opts)
  return {
    player = player_tree.player,
    states = player_tree.states,
    memos = player_tree.memos,
    clock = player_tree.clock,
    remote = opts.remote,
    create_unit = opts.create_unit,
    fish_units = opts.fish_units,
    fish_carrier = opts.fish_carrier,
    online_players = opts.players,
    effect = nil,
    holding = false,
    airborne = false,
    flight_y = nil,
    flight_ground_y = nil,
    gravity_off = false,
    gravity_character = nil,
    wing_bind_id = nil,
    skin_applied = false,
    appearance = nil,
    placeholder_mount = nil,
    placeholder_model = nil,
    breath = nil,
    suspended = false,
    suspended_item = nil,
    seen_zone = nil,
    published_breath = nil,
    failures = {},
    restoring = false,
    selected_phase = State.new("SpecialItemPhase.selected", nil),
    cleanup_active = State.new("SpecialItemPhase.cleanup_active", false),
    cleanup_character = nil,
    breath_ready_at = nil,
    retries = 0,
    retry_after = 0,
    mounted = true,
  }
end

--- 把行为表挂到玩家树上；状态与依赖统一从 player_tree.special_item_env 读取。
function SpecialItemBehavior.install(player_tree, env)
  player_tree.special_item_env = env
  for _, name in ipairs(TREE_METHODS) do
    player_tree[name] = SpecialItemBehavior[name]
  end
end

-- Spoke 作用域接线：注册顺序与拆分前 mount 内的 on_cleanup / effect / memo / phase 一致。
function SpecialItemBehavior.wire(ps, self)
  local env = self.special_item_env
  local clock = env.clock
  ps:on_cleanup(function()
    env.mounted = false
  end)

  ps:effect("SpecialItemDrive", function(es)
    SpecialItemBehavior.drive(self, es)
  end)

  local wings_selected = ps:memo("WingsSelected", function(ms)
    return ms:d(env.selected_phase) == "wings"
  end)
  local godzilla_selected = ps:memo("GodzillaSelected", function(ms)
    return ms:d(env.selected_phase) == "godzilla"
  end)
  local cleanup_selected = ps:memo("SpecialCleanupSelected", function(ms)
    return ms:d(env.selected_phase) == nil and ms:d(env.cleanup_active)
  end)

  ps:phase("WingsPhase", wings_selected, function(wings)
    SpecialItemBehavior.reconcile(self)
    wings:subscribe(clock.on_frame, function(frame)
      SpecialItemBehavior.fly_frame(self, frame)
    end)
    wings:on_cleanup(function()
      SpecialItemBehavior.restore(self)
      SpecialItemBehavior.publish(self)
    end)
  end)

  ps:phase("GodzillaPhase", godzilla_selected, function(godzilla)
    SpecialItemBehavior.reconcile(self)
    godzilla:subscribe(clock.on_frame, function(frame)
      SpecialItemBehavior.breath_frame(self, frame)
    end)
    godzilla:on_cleanup(function()
      SpecialItemBehavior.restore(self)
      SpecialItemBehavior.publish(self)
    end)
  end)

  ps:phase("CleanupPhase", cleanup_selected, function(cleanup)
    cleanup:subscribe(clock.on_frame, function(frame)
      SpecialItemBehavior.retry_cleanup(self, frame and frame.now or now_of(env))
    end)
  end)

  ps:on_cleanup(function()
    SpecialItemBehavior.special_release(self)
  end)
end

--- 挂载特殊道具阶段：先建环境并装配行为表，再按拆分前的顺序接线、登记离场终镜像并落首帧快照。
function SpecialItemPhase.mount(ps, player_tree, opts)
  opts = type(opts) == "table" and opts or {}
  local env = build_env(player_tree, opts)
  SpecialItemBehavior.install(player_tree, env)
  SpecialItemBehavior.wire(ps, player_tree)

  SpecialItemBehavior.anchor_breath(player_tree, SpecialItemBehavior.stored_breath_remaining(player_tree))
  local leave_finalizer = function()
    SpecialItemBehavior.write_leave_breath(player_tree)
  end
  if type(player_tree.register_leave_finalizer) == "function" then
    player_tree:register_leave_finalizer(leave_finalizer)
  else
    player_tree._pending_leave_finalizers = player_tree._pending_leave_finalizers or {}
    player_tree._pending_leave_finalizers[#player_tree._pending_leave_finalizers + 1] = leave_finalizer
  end

  SpecialItemBehavior.reconcile(player_tree)
  SpecialItemBehavior.publish(player_tree)
end

return SpecialItemPhase
