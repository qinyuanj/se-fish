
local game_cfg = require("common.game_cfg")
local flight_path = require("common.flight_path")
local number = require("common.number")
local special_item = require("common.special_item")
local State = require("common.packages.spoke.api").State

local special_item_phase = {}

local CLEANUP_RETRY_SEC = 1
local CLEANUP_RETRIES = 5

local function cfg()
  return game_cfg.Ability.special_item
end

local function breath_cfg()
  return cfg().Godzilla.Breath
end

local function finite(value)
  return number.IsFiniteNumber(value)
end

local function zone_scene(zone_id)
  for _, zone in ipairs(game_cfg.Zones or {}) do
    if zone.Id == zone_id then return zone.Scene end
  end
end

local function flat_forward(rotation)
  local ok, forward = pcall(function()
    return rotation and rotation.GetForward and rotation:GetForward()
  end)
  local fx = ok and forward and forward.x or 0
  local fz = ok and forward and forward.z or 1
  local len = math.sqrt(fx * fx + fz * fz)
  if len < 1e-6 then return { x = 0, z = 1 } end
  return { x = fx / len, z = fz / len }
end

local function is_object(value)
  local kind = type(value)
  return kind == "table" or kind == "userdata"
end

local function in_corridor(origin, forward, pos, breath)
  if not is_object(pos) or not finite(pos.x) or not finite(pos.y) or not finite(pos.z) then
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
  local ok, pos = pcall(function() return character and character.Position end) -- 兼容引擎 userdata 角色
  if ok and is_object(pos) and finite(pos.x) and finite(pos.y) and finite(pos.z) then
    return pos
  end
end

local function write_position(character, x, y, z)
  pcall(function()
    character.Position = Vector3.New(x, y, z)
  end)
end

local function selected_item_id(item_bar, selected_slot)
  if type(selected_slot) ~= "number" or type(item_bar) ~= "table" then return nil end
  local entry = item_bar[selected_slot]
  if type(entry) ~= "table" or (entry.count or 0) <= 0 then return nil end
  return entry.itemId
end

function special_item_phase.mount(ps, player_tree, opts)
  opts = type(opts) == "table" and opts or {}
  local states = player_tree.states
  local memos = player_tree.memos
  local clock = player_tree.clock
  local player = player_tree.player
  local remote = opts.remote
  local create_unit = opts.create_unit
  local fish_units = opts.fish_units
  local fish_carrier = opts.fish_carrier
  local online_players = opts.players

  local effect = nil
  local holding = false
  local airborne = false
  local flight_y = nil
  local flight_ground_y = nil
  local gravity_off = false
  local gravity_character = nil
  local wing_bind_id = nil
  local skin_applied = false
  local appearance = nil
  local placeholder_mount = nil
  local placeholder_model = nil
  local breath = nil
  local suspended = false
  local suspended_item = nil
  local seen_zone = nil
  local published_breath = nil
  local failures = {}
  local restoring = false
  local selected_phase = State.new("special_item_phase.selected", nil)
  local cleanup_active = State.new("special_item_phase.cleanup_active", false)
  local cleanup_character = nil

  local function now()
    return clock.now()
  end

  local function character_of()
    return cleanup_character or states.character:now() or player.Character
  end

  local function log_failure(key, object, err)
    if not failures[key] then
      print("[special_item_phase] 引擎操作失败", key, tostring(object), tostring(err))
    end
  end

  local function engine_call(key, object, fn)
    local failure = failures[key]
    if failure and now() < failure.next_at then return false end
    local ok, result = pcall(fn)
    if ok and result ~= false then
      failures[key] = nil
      return true, result
    end
    log_failure(key, object, result)
    failures[key] = { next_at = now() + CLEANUP_RETRY_SEC }
    return false
  end

  local function fire_client(name, payload)
    if not remote or type(remote.GetRE) ~= "function" then return end
    local ok, event = pcall(remote.GetRE, remote, name)
    if ok and event and type(event.FireClient) == "function" then
      pcall(event.FireClient, event, player, payload)
    end
  end

  local function reply(payload)
    fire_client("SpecialItemResult", payload)
  end

  local function fail(action, reason)
    print("[special_item_phase] 请求拒绝", player.UserId, action, tostring(reason))
    reply({ ok = false, action = action, reason = reason })
    return false
  end

  local breath_ready_at = nil
  local function anchor_breath(stored)
    if type(breath_ready_at) == "number" then return end
    if type(stored) ~= "number" or stored <= 0 then return end
    breath_ready_at = now() + stored
  end
  local function stored_breath_remaining()
    local mark = states.cooldowns:now()
    local stored = type(mark) == "table" and mark.godzillaBreath or nil
    if type(stored) ~= "number" or stored <= 0 then return 0 end
    return stored
  end
  local function breath_remaining()
    local ready = breath_ready_at
    if type(ready) ~= "number" then
      anchor_breath(stored_breath_remaining())
      ready = breath_ready_at
    end
    if type(ready) ~= "number" then return 0 end
    return special_item.CooldownRemaining(ready - breath_cfg().CooldownSec, now(), breath_cfg().CooldownSec)
  end

  local function publish()
    local remaining = breath_remaining()
    published_breath = math.ceil(remaining - 1e-9)
    fire_client("SpecialItemState", {
      effect = restoring and nil or effect,
      airborne = airborne,
      breathRemaining = remaining,
    })
  end

  local function write_cooldown(remaining)
    breath_ready_at = now() + remaining
    local mark = states.cooldowns:now()
    local next_mark = {}
    if type(mark) == "table" then
      for key, value in pairs(mark) do next_mark[key] = value end
    end
    next_mark.godzillaBreath = remaining
    states.cooldowns:set(next_mark)
  end

  local function set_gravity(enabled)
    local character = gravity_character or character_of()
    local ok = engine_call("gravity", character, function()
      local controller = character and character.Controller
      if not controller then error("no-controller") end
      controller.GravityEnabled = enabled
      return true
    end)
    if ok then
      gravity_off = not enabled
      gravity_character = not enabled and character or nil
    end
    return ok
  end

  local function destroy_unit(key, unit)
    if not unit then return true end
    return engine_call(key, unit, function()
      unit:Destroy()
      return true
    end)
  end

  local function restore()
    holding = false
    airborne = false
    flight_y = nil
    flight_ground_y = nil
    breath = nil
    local character = character_of()
    local current_appearance = appearance or (character and character.EggyAppearance)
    if placeholder_model then
      if destroy_unit("placeholderDestroy", placeholder_model) then placeholder_model = nil end
    end
    if placeholder_mount and not placeholder_model then
      if destroy_unit("placeholderUnmount", placeholder_mount) then placeholder_mount = nil end
    end
    if wing_bind_id and current_appearance then
      local bind_id = wing_bind_id
      if engine_call("unbind", current_appearance, function()
        return current_appearance:UnbindAppearance(bind_id)
      end) then
        wing_bind_id = nil
      end
    end
    if skin_applied and current_appearance then
      if engine_call("reset", current_appearance, function()
        current_appearance:ResetAppearance()
        return true
      end) then
        skin_applied = false
      end
    end
    if gravity_off then set_gravity(true) end
    if wing_bind_id or skin_applied or gravity_off or placeholder_mount or placeholder_model then
      restoring = true
      cleanup_active:set(true)
      return false
    end
    restoring = false
    cleanup_active:set(false)
    effect = nil
    appearance = nil
    return true
  end

  local function apply_effect(desired)
    local character = character_of()
    local current_appearance = character and character.EggyAppearance
    if desired == "wings" and cfg().Wings.AppearanceAssetId then
      local wings = cfg().Wings
      local ok, bind_id = engine_call("bind", current_appearance, function()
        return current_appearance:BindAppearance(
          wings.AppearanceAssetId,
          Enums.SkeletalSocketType[wings.Socket],
          Vector3.New(wings.Offset.x, wings.Offset.y, wings.Offset.z),
          Quaternion.Identity(),
          Vector3.New(1, 1, 1))
      end)
      if not ok or type(bind_id) ~= "number" then return false end
      wing_bind_id = bind_id
      appearance = current_appearance
    elseif desired == "godzilla" and cfg().Godzilla.AppearanceAssetId then
      if not engine_call("skin", current_appearance, function()
        current_appearance:SetAppearanceByAssetId(cfg().Godzilla.AppearanceAssetId)
        return true
      end) then
        return false
      end
      skin_applied = true
      appearance = current_appearance
    else
      local visual = game_cfg.placeholder_assets and game_cfg.placeholder_assets.Special
        and game_cfg.placeholder_assets.Special[desired]
      if visual and type(create_unit) == "function" then
        local ok, mount = engine_call("placeholderMount", character, function()
          return create_unit("SkeletalSocketMount", {
            Name = "SpecialPlaceholderMount_" .. tostring(player.UserId),
            Parent = character,
            SocketName = visual.Socket,
            SocketOffset = Vector3.New(visual.Offset.x, visual.Offset.y, visual.Offset.z),
          })
        end)
        if not ok or not mount then return false end
        local model_ok, model = engine_call("placeholderModel", mount, function()
          return create_unit("WorldUnit", {
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
          if destroy_unit("placeholderUnmount", mount) then
            placeholder_mount = nil
          else
            placeholder_mount = mount
          end
          return false
        end
        placeholder_mount = mount
        placeholder_model = model
      end
    end
    effect = desired
    restoring = false
    cleanup_active:set(false)
    return true
  end

  local function current_selection()
    local record = player_tree.data
    local data_part = type(record) == "table" and record.data or nil
    if type(data_part) == "table" then
      local containers = type(data_part.Containers) == "table" and data_part.Containers or {}
      return selected_item_id(containers[game_cfg.Items.ContainerId.ItemBar], data_part.SelectedSlot)
    end
    return selected_item_id(states.item_bar:now(), states.selected_slot:now())
  end

  local function desired_effect()
    if (player_tree.tree and player_tree.tree.is_detached == true) or player_tree.session_alive:now() == false then return nil end
    if memos.is_alive:now() ~= true then return nil end
    local selected = current_selection()
    if suspended and selected ~= suspended_item then
      suspended = false
      suspended_item = nil
    end
    if suspended then return nil end
    return special_item.Desired(selected)
  end

  local function reconcile()
    local desired = desired_effect()
    if desired == effect and not restoring then return end
    if not restore() then
      publish()
      return
    end
    if desired and character_of() then apply_effect(desired) end
    publish()
  end

  local function update_flight(dt)
    if effect ~= "wings" or restoring then return end
    local character = character_of()
    local pos = read_position(character)
    if not pos then return end
    local wings = cfg().Wings
    if airborne and not holding and flight_y and pos.y > flight_y + wings.LandEpsilon then
      airborne = false
    end
    if not holding and not airborne then
      if gravity_off then set_gravity(true) end
      flight_y = nil
      flight_ground_y = nil
      publish()
      return
    end
    local scene = zone_scene(states.zone_id:now())
    local bounds = scene and flight_path.BoundsOf(scene, game_cfg.Ability.Flight)
    if not bounds then return end
    if not flight_ground_y then flight_ground_y = pos.y end
    bounds.GroundY = flight_ground_y
    bounds.CeilingY = math.min(bounds.CeilingY, flight_ground_y + bounds.MaxHeight)
    if not set_gravity(false) then return end
    local y, next_airborne = special_item.StepFlightY(wings, {
      Y = flight_y or pos.y,
      Airborne = airborne,
    }, holding, dt, bounds)
    local x, z = special_item.ClampXZ(bounds, pos.x, pos.z)
    write_position(character, x, y, z)
    flight_y = y
    airborne = next_airborne
    if not airborne then
      set_gravity(true)
      flight_y = nil
      flight_ground_y = nil
    end
    publish()
  end

  local function breath_targets()
    local targets = {}
    if type(online_players) == "function" then
      local ok, list = pcall(online_players)
      if ok and type(list) == "table" then
        for _, other in ipairs(list) do
          if other ~= player then
            local pos = read_position(other.Character)
            if pos then
              targets[#targets + 1] = {
                key = "player:" .. tostring(other.UserId),
                pos = pos,
                apply = function(amount)
                  if type(player_tree.apply_hit) == "function" then
                    player_tree:apply_hit(player_tree:new_hit(player, "specialBreath"), other, amount)
                  end
                end,
              }
            end
          end
        end
      end
    end
    local fish = fish_units
    if type(fish) == "function" then
      local ok, list = pcall(fish)
      fish = ok and list or nil
    end
    if type(fish) ~= "table" and player_tree.fish_units then fish = player_tree.fish_units end
    if type(fish) == "table" then
      for _, entry in pairs(fish) do
        local carrier = entry and (entry.Carrier or entry)
        local body = carrier and carrier.Body
        local pos = body and read_position(body) or read_position(carrier)
        if carrier and not carrier.Dead and pos then
          targets[#targets + 1] = {
            key = "fish:" .. tostring(entry.Id or carrier.Id or "unknown"),
            pos = pos,
            apply = function(amount)
              local hit = player_tree:new_hit(player, "specialBreath")
              if type(player_tree.apply_hit) == "function" then
                local applied = player_tree:apply_hit(hit, carrier, amount)
                if applied then return end
              end
              if fish_carrier and type(fish_carrier.Damage) == "function" then
                fish_carrier:Damage(carrier, amount, hit)
              end
            end,
          }
        end
      end
    end
    return targets
  end

  local function update_breath(current)
    if not breath then return end
    local bc = breath_cfg()
    local plan = breath.ledger.Plan
    while breath.tick <= #plan and current + 1e-9 >= breath.cast_at + (breath.tick - 1) * bc.TickSec do
      local tick = breath.tick
      for _, target in ipairs(breath_targets()) do
        if in_corridor(breath.origin, breath.forward, target.pos, bc) then
          local amount = special_item.BreathHit(breath.ledger, target.key, tick)
          if amount then target.apply(amount) end
        end
      end
      breath.tick = tick + 1
    end
    if current + 1e-9 >= breath.cast_at + bc.DurationSec then
      breath = nil
      publish()
    end
  end

  local function mirror_cooldown()
    if type(breath_ready_at) ~= "number" then return end
    local remaining = breath_remaining()
    local mark = states.cooldowns:now()
    local stored = type(mark) == "table" and mark.godzillaBreath or 0
    if math.abs((stored or 0) - remaining) >= 0.05 then
      local next_mark = {}
      if type(mark) == "table" then
        for key, value in pairs(mark) do next_mark[key] = value end
      end
      next_mark.godzillaBreath = remaining
      states.cooldowns:set(next_mark)
    end
    local shown = math.ceil(remaining - 1e-9)
    if shown ~= published_breath then publish() end
  end

  local function cast_breath()
    if restoring or effect ~= "godzilla" then return fail("breath", "not-godzilla") end
    if memos.can_act:now() ~= true then return fail("breath", "not-alive") end
    local pos = read_position(character_of())
    if not pos then return fail("breath", "no-character") end
    local bc = breath_cfg()
    if breath_remaining() > 0 then return fail("breath", "cooldown") end
    local current = now()
    write_cooldown(bc.CooldownSec)
    breath = {
      cast_at = current,
      tick = 1,
      ledger = special_item.NewBreathLedger(bc),
      origin = { x = pos.x, y = pos.y, z = pos.z },
      forward = flat_forward(character_of().Rotation),
    }
    reply({ ok = true, action = "breath", endsAt = current + bc.DurationSec })
    publish()
    return true
  end

  local function on_action(sender, payload)
    if sender ~= player or (player_tree.tree and player_tree.tree.is_detached == true) then return end
    if player_tree.session_alive:now() == false then return end
    if type(payload) ~= "table" then return end
    reconcile()
    if payload.action == "fly" then
      local release = payload.holding ~= true
      if not release and remote and type(remote.CheckRECD) == "function" then
        local limited = remote:CheckRECD(player, "SpecialItemAction", cfg().ReLimitSec)
        if limited then return end
      end
      if restoring or effect ~= "wings" or memos.can_act:now() ~= true then
        holding = false
        return fail("fly", "not-wings")
      end
      holding = payload.holding == true
      return true
    end
    if payload.action == "breath" then
      if remote and type(remote.CheckRECD) == "function" then
        local limited = remote:CheckRECD(player, "SpecialItemAction", cfg().ReLimitSec)
        if limited then return end
      end
      return cast_breath()
    end
  end

  local function on_query(sender)
    if sender ~= player or (player_tree.tree and player_tree.tree.is_detached == true) or player_tree.session_alive:now() == false then
      return false
    end
    if remote and type(remote.CheckRECD) == "function" then
      if remote:CheckRECD(player, "SpecialItemStateRequest", cfg().ReLimitSec) then return false end
    end
    publish()
    return true
  end

  local mounted = true
  function player_tree:handle_special_item_action(payload)
    if not mounted then return false end
    return on_action(player, payload)
  end
  function player_tree:handle_special_item_query()
    if not mounted then return false end
    return on_query(player)
  end
  ps:on_cleanup(function()
    mounted = false
  end)

  local retries = 0
  local retry_after = 0
  ps:effect("SpecialItemDrive", function(es)
    es:d(states.item_bar)
    es:d(states.selected_slot)
    es:d(states.character)
    local zone_id = es:d(states.zone_id)
    es:d(memos.is_alive)
    if seen_zone == nil then seen_zone = zone_id end
    if zone_id ~= seen_zone then
      seen_zone = zone_id
      if effect ~= nil or holding or airborne or gravity_off then
        suspended = true
        suspended_item = current_selection()
        holding = false
        airborne = false
        flight_y = nil
        flight_ground_y = nil
      end
    end
    local desired = desired_effect()
    if selected_phase:now() ~= desired then
      selected_phase:set(desired)
    else
      reconcile()
    end
  end)

  local function retry_cleanup(current)
    if current + 1e-9 >= retry_after and retries < CLEANUP_RETRIES then
      retries = retries + 1
      retry_after = current + CLEANUP_RETRY_SEC
      for key, failure in pairs(failures) do
        if failure.next_at and failure.next_at <= current + 1e-9 then failures[key] = nil end
      end
      reconcile()
    end
    mirror_cooldown()
  end

  local wings_selected = ps:memo("WingsSelected", function(ms)
    return ms:d(selected_phase) == "wings"
  end)
  local godzilla_selected = ps:memo("GodzillaSelected", function(ms)
    return ms:d(selected_phase) == "godzilla"
  end)
  local cleanup_selected = ps:memo("SpecialCleanupSelected", function(ms)
    return ms:d(selected_phase) == nil and ms:d(cleanup_active)
  end)

  ps:phase("WingsPhase", wings_selected, function(wings)
    reconcile()
    wings:subscribe(clock.on_frame, function(frame)
      if player_tree.session_alive:now() == false then return end
      local current = frame and frame.now or now()
      if restoring then retry_cleanup(current) return end
      retries = 0
      reconcile()
      mirror_cooldown()
      local step = frame and frame.dt or 0
      while step > 1e-9 do
        local slice = math.min(step, cfg().Wings.MaxStepSec)
        update_flight(slice)
        step = step - slice
      end
    end)
    wings:on_cleanup(function() restore() publish() end)
  end)

  ps:phase("GodzillaPhase", godzilla_selected, function(godzilla)
    reconcile()
    godzilla:subscribe(clock.on_frame, function(frame)
      if player_tree.session_alive:now() == false then return end
      local current = frame and frame.now or now()
      if restoring then retry_cleanup(current) return end
      retries = 0
      reconcile()
      mirror_cooldown()
      update_breath(current)
    end)
    godzilla:on_cleanup(function() restore() publish() end)
  end)

  ps:phase("CleanupPhase", cleanup_selected, function(cleanup)
    cleanup:subscribe(clock.on_frame, function(frame)
      retry_cleanup(frame and frame.now or now())
    end)
  end)

  ps:on_cleanup(function()
    cleanup_character = character_of()
    for _ = 1, CLEANUP_RETRIES do
      if restore() then break end
    end
    publish()
  end)

  anchor_breath(stored_breath_remaining())
  local leave_finalizer = function()
    local remaining = breath_remaining()
    if type(player_tree.data) == "table" then
      if type(player_tree.data.Extra) ~= "table" then player_tree.data.Extra = {} end
      if type(player_tree.data.Extra.cooldowns) ~= "table" then
        player_tree.data.Extra.cooldowns = {}
      end
      player_tree.data.Extra.cooldowns.godzillaBreath = remaining
    end
  end
  if type(player_tree.register_leave_finalizer) == "function" then
    player_tree:register_leave_finalizer(leave_finalizer)
  else
    player_tree._pending_leave_finalizers = player_tree._pending_leave_finalizers or {}
    player_tree._pending_leave_finalizers[#player_tree._pending_leave_finalizers + 1] = leave_finalizer
  end

  function player_tree:suspend_special_item()
    suspended = true
    suspended_item = current_selection()
    holding = false
    airborne = false
    flight_y = nil
    flight_ground_y = nil
    reconcile()
  end

  function player_tree:special_item_effect()
    if restoring or player_tree.session_alive:now() == false then return nil end
    return effect
  end

  reconcile()
  publish()
end

return special_item_phase
