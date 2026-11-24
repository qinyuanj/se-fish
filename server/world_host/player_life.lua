
local GameCfg = require("common.game_cfg")
local Vitals = require("common.vitals")
local Number = require("common.number")
local Spoke = require("common.packages.spoke.api")
local SpokeRuntime = require("common.packages.spoke.runtime.spoke_runtime")

local State = Spoke.State

local PlayerLife = {}

local function finite_number(value)
  return Number.is_finite_number(value)
end

local function positive_amount(value)
  return finite_number(value) and value > 0
end

local function controller_of(player)
  local ok, controller = pcall(function()
    return player.Character and player.Character.Controller
  end)
  if ok then return controller end
  return nil
end

local function read_health(player)
  local controller = controller_of(player)
  if not controller then return nil end
  local ok, health = pcall(function() return controller.Health end)
  if ok and finite_number(health) then return health end
  return nil
end

local function is_object(value)
  local kind = type(value)
  return kind == "table" or kind == "userdata"
end

local function position_of(player)
  local ok, pos = pcall(function()
    return player.Character and player.Character.Position
  end) -- 兼容引擎 userdata 角色
  if ok and is_object(pos) then return pos end
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
  pcall(function() player:SetAttribute(key, value) end)
end

local function ceil_remaining(until_at, now)
  return math.max(0, math.ceil((until_at or now) - now))
end

function PlayerLife.mount(s3, player_tree, opts)
  opts = type(opts) == "table" and opts or {}
  local states = player_tree.states
  local memos = player_tree.memos
  local clock = player_tree.clock
  local player = player_tree.player
  local data = player_tree.data

  local survival_cfg = GameCfg.Survival
  local vitals_cfg = GameCfg.Vitals
  local rescue_cfg = GameCfg.Rescue
  local platform_api = opts.platform
  local save_api = opts.save
  local player_data = opts.player_data
  local remote = opts.remote
  local raw = {}
  local seeded = player_data and type(player_data.get_data_inst) == "function" and select(2, pcall(player_data.get_data_inst, player_data, player)) or data
  if type(seeded) == "table" and type(seeded.extra) == "table" and type(seeded.extra.survival) == "table" then
    raw = seeded.extra.survival
  end

  local now0 = clock.now()
  local downed_until = State.new("PlayerLife.downed_until", nil)
  local dead_until = State.new("PlayerLife.dead_until", nil)
  local rescue = State.new("PlayerLife.rescue", nil)
  local platform = State.new("PlayerLife.platform", nil)
  local episode = State.new("PlayerLife.episode", 0)
  local recovering = State.new("PlayerLife.recovering", false)
  local engine_death = State.new("PlayerLife.engine_death", false)
  local hit_seq = 0
  local action_seq = 0
  local damage_filter = nil
  local fish_carrier = opts.fish_carrier
  local help_index = 0
  local last_help_at = nil
  local adrenaline_flying = false
  local recover_flying = false
  local last_hunger_sec = math.floor(now0)
  local rescue_sec = math.floor(now0)
  local speed_writer = opts.speed_writer
  local growth_writer = opts.growth_writer
  local on_downed = opts.on_downed

  local current_data
  local function live_data()
    local inst = current_data()
    if type(inst) == "table" then return inst end
    return data
  end

  local function mark_table()
    local inst = live_data()
    if type(inst) ~= "table" then return nil end
    if type(inst.extra) ~= "table" then inst.extra = {} end
    if type(inst.extra.survival) ~= "table" then inst.extra.survival = {} end
    return inst.extra.survival
  end

  local function max_health()
    if type(opts.max_health_of) == "function" then
      local ok, value = pcall(opts.max_health_of, player)
      if ok and finite_number(value) and value >= 1 then return math.floor(value) end
    end
    local value = memos.max_health and memos.max_health:now() or vitals_cfg.MaxHealth
    if not finite_number(value) or value < 1 then return vitals_cfg.MaxHealth end
    return math.floor(value)
  end

  function current_data()
    if player_data and type(player_data.get_data_inst) == "function" then
      local ok, inst = pcall(player_data.get_data_inst, player_data, player)
      if ok and type(inst) == "table" then return inst end
    end
    return data
  end

  local function fire_client(name, payload)
    if not remote or type(remote.get_re) ~= "function" then return end
    local ok, event = pcall(remote.get_re, remote, name)
    if ok and event and type(event.FireClient) == "function" then
      pcall(event.FireClient, event, player, payload)
    end
  end

  local function reply(payload)
    fire_client("SurvivalResult", payload)
  end

  local function carrying_barrel(source)
    local held = vitals_cfg.HeldDamage
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

  local noticed_health
  local function set_controller_health(value)
    local controller = controller_of(player)
    if not controller then
      print("[PlayerLife] operation=SetControllerHealth", "player=" .. tostring(player.UserId), "error=no-controller")
      return false
    end
    local ok, err = pcall(function() controller.Health = value end)
    if not ok then
      print("[PlayerLife] operation=SetControllerHealth", "player=" .. tostring(player.UserId), tostring(err))
      return false
    end
    local read = read_health(player)
    noticed_health = read or value
    states.health:set(read or value)
    return true
  end

  local function write_vitals()
    local health = states.health:now()
    write_attr(player, "Health", math.max(0, math.floor(health)))
    write_attr(player, "MaxHealth", max_health())
    write_attr(player, "Hunger", states.hunger:now())
    write_attr(player, "MaxHunger", vitals_cfg.MaxHunger)
  end

  local function phase_payload()
    local phase = states.life_phase:now()
    local payload = { phase = phase }
    if phase == "downed" or phase == "rescuing" then
      payload.endsAt = downed_until:now()
    elseif phase == "dead" then
      payload.endsAt = dead_until:now()
    end
    local weak = player_tree.get_modifier_remaining and player_tree:get_modifier_remaining("weak") or 0
    if weak > 0 then payload.weakUntil = clock.now() + weak end
    local rescue_now = rescue:now()
    if phase == "rescuing" and type(rescue_now) == "table" then
      payload.rescuerUserId = rescue_now.by and rescue_now.by.UserId
      payload.rescueEndsAt = rescue_now.endAt
    end
    local pending = platform:now()
    if type(pending) == "table" then payload.platformPending = pending.mode end
    return payload
  end

  local function publish()
    local phase = states.life_phase:now()
    write_attr(player, "SurvivalPhase", phase)
    write_vitals()
    fire_client("SurvivalState", phase_payload())
    local mark = mark_table()
    if mark then
      local now = clock.now()
      local pending = platform:now()
      local paused = type(pending) == "table" and math.max(0, now - (pending.startedAt or now)) or 0
      local downed_at = downed_until:now()
      local dead_at = dead_until:now()
      mark.health = states.health:now()
      mark.hunger = states.hunger:now()
      mark.dying = phase == "downed" or phase == "rescuing"
      mark.dead = phase == "dead"
      mark.dyingRemaining = (mark.dying and downed_at) and ceil_remaining(downed_at + paused, now) or 0
      mark.deadRemaining = (mark.dead and dead_at) and ceil_remaining(dead_at + paused, now) or 0
      local weak = player_tree.get_modifier_remaining and player_tree:get_modifier_remaining("weak") or 0
      mark.weakRemaining = math.max(0, math.ceil(weak))
    end
  end

  local function apply_walk(base_override)
    if player_tree.walk_projection_rejected then return end
    local controller = controller_of(player)
    if not controller then return end
    local base = base_override
    if not finite_number(base) or base <= 0 then
      base = memos.walk_speed and memos.walk_speed:now()
    end
    if not finite_number(base) or base <= 0 then
      local ok, current = pcall(function() return controller.WalkSpeed end)
      if ok and finite_number(current) and current > 0 and not player_tree:get_modifier_remaining("weak") then
        base = current
      end
    end
    local paralyzed = states.is_paralyzed:now() == true
    local speed = base
    if finite_number(base) then
      if paralyzed then speed = 0 end
      pcall(function() controller.WalkSpeed = speed end)
    end
    if type(speed_writer) == "function" then
      pcall(speed_writer, player, speed)
    end
  end

  local function reapply_growth()
    local controller = controller_of(player)
    local before
    if controller then
      local ok, current = pcall(function() return controller.WalkSpeed end)
      if ok then before = current end
    end
    if type(growth_writer) == "function" then
      pcall(growth_writer, player)
    end
    local grown
    if controller and type(growth_writer) == "function" then
      local ok, current = pcall(function() return controller.WalkSpeed end)
      if ok and finite_number(current) and current > 0 and current ~= before then
        grown = current
      end
    end
    apply_walk(grown)
  end

  local function clear_combat_effects()
    if type(player_tree.clear_all_modifiers) == "function" then
      player_tree:clear_all_modifiers(true)
    end
  end

  local function enter_downed()
    local now = clock.now()
    SpokeRuntime.batch(function()
      episode:set(episode:now() + 1)
      rescue:set(nil)
      platform:set(nil)
      states.platform_pending:set(false)
      downed_until:set(now + survival_cfg.DownedSec)
      states.life_phase:set("downed")
      set_controller_health(1)
    end)
    clear_combat_effects()
    if type(on_downed) == "function" then
      pcall(on_downed, player)
    end
    publish()
  end

  local function enter_dead(from_engine)
    local now = clock.now()
    rescue:set(nil)
    platform:set(nil)
    states.platform_pending:set(false)
    SpokeRuntime.batch(function()
      states.life_phase:set("dead")
      downed_until:set(nil)
      dead_until:set(now + survival_cfg.DeadSec)
      engine_death:set(from_engine == true)
    end)
    clear_combat_effects()
    publish()
  end

  local function revive_to(health, min_hunger, with_weak)
    local cap = max_health()
    local next_health = math.max(1, math.min(cap, math.floor(health)))
    local hunger = states.hunger:now()
    if finite_number(min_hunger) and hunger < min_hunger then
      hunger = min_hunger
    end
    hunger = math.max(0, math.min(vitals_cfg.MaxHunger, math.floor(hunger)))
    if not set_controller_health(next_health) then return false end
    SpokeRuntime.batch(function()
      states.hunger:set(hunger)
      states.life_phase:set("alive")
      downed_until:set(nil)
      dead_until:set(nil)
      rescue:set(nil)
      platform:set(nil)
      states.platform_pending:set(false)
      recovering:set(false)
      engine_death:set(false)
    end)
    if with_weak then
      player_tree:apply_modifier("weak", { duration = survival_cfg.WeakSec })
    elseif player_tree.clear_modifier then
      player_tree:clear_modifier("weak")
    end
    reapply_growth()
    publish()
    return true
  end

  local function percent_health()
    return math.floor(max_health() * survival_cfg.ReviveHealthPercent / 100)
  end

  local function min_hunger()
    return math.floor(vitals_cfg.MaxHunger * survival_cfg.ReviveHungerPercent / 100)
  end

  local function weak_revive()
    if states.life_phase:now() ~= "dead" then return false end
    return revive_to(percent_health(), min_hunger(), true)
  end

  local function full_revive()
    local phase = states.life_phase:now()
    if phase ~= "downed" and phase ~= "rescuing" and phase ~= "dead" then return false end
    return revive_to(max_health(), min_hunger(), false)
  end

  local function rescue_success()
    if states.life_phase:now() ~= "rescuing" and states.life_phase:now() ~= "downed" then
      return false
    end
    return revive_to(percent_health(), nil, false)
  end

  local publish_notice
  local suppress_health_note = false
  local function apply_damage(amount, hit)
    local phase = states.life_phase:now()
    if phase ~= "alive" or recovering:now() then return false end
    if not positive_amount(amount) then return false end
    local before = read_health(player)
    if before == nil then before = states.health:now() end
    if not finite_number(before) then return false end
    suppress_health_note = true
    local function finish(ok, actual)
      suppress_health_note = false
      noticed_health = read_health(player)
      return ok, actual
    end
    if before - amount <= 0 then
      enter_downed()
      publish_notice(before - 1, hit)
      return finish(true, math.max(0, before - 1))
    end
    local controller = controller_of(player)
    if controller and type(controller.TakeDamage) == "function" then
      local ok = pcall(function() controller:TakeDamage(amount) end)
      if not ok then return finish(false) end
    end
    local after = read_health(player)
    if after == nil then after = before - amount end
    if after <= 0 then
      enter_downed()
      publish_notice(before - 1, hit)
      return finish(true, math.max(0, before - 1))
    end
    states.health:set(after)
    write_vitals()
    if after >= before then return finish(false) end
    publish_notice(before - after, hit)
    return finish(true, before - after)
  end

  function publish_notice(actual, hit)
    if not (remote and type(remote.get_re) == "function") or not (actual > 0) then return end
    local event = remote:get_re("DamageNotice")
    if event and type(event.FireAllClients) == "function" then
      pcall(event.FireAllClients, event, {
        amount = actual,
        category = hit and hit.category,
        targetUserId = player.UserId,
        position = player.Character and player.Character.Position,
      })
    end
  end

  local function resolve_player(target)
    if not is_object(target) then return nil end
    local ok_uid, uid = pcall(function() return target.UserId end) -- 兼容引擎 userdata 玩家与非玩家单位
    if ok_uid and uid ~= nil and opts.lookup_tree and opts.lookup_tree(uid) then
      return target
    end
    if target == player then return player end
    return nil
  end

  function player_tree:new_hit(source, category)
    hit_seq = hit_seq + 1
    local source_player = nil
    if is_object(source) then
      local ok_uid, uid = pcall(function() return source.UserId end) -- 兼容引擎 userdata 来源
      if ok_uid and uid ~= nil then source_player = source end
    end
    return {
      id = hit_seq,
      category = category,
      source = source,
      sourcePlayer = source_player,
      targets = {},
    }
  end

  function player_tree:resolve_hit_source(hit)
    return type(hit) == "table" and hit.sourcePlayer or nil
  end

  function player_tree:set_damage_filter(filter)
    damage_filter = type(filter) == "function" and filter or nil
  end

  function player_tree:apply_hit(hit, target, amount)
    if type(hit) ~= "table" or type(hit.targets) ~= "table" or type(hit.id) ~= "number" then
      return false
    end
    if not positive_amount(amount) then return false end
    if fish_carrier and type(fish_carrier.resolve_carrier) == "function" then
      local ok, carrier = pcall(fish_carrier.resolve_carrier, fish_carrier, target)
      if ok and carrier then
        local key = "carrier:" .. tostring(carrier)
        if hit.targets[key] then return false end
        if type(fish_carrier.Damage) ~= "function" then return false end
        local damaged, actual = fish_carrier:Damage(carrier, amount, hit)
        if damaged then hit.targets[key] = true end
        return damaged, actual
      end
    end
    local target_player = target
    if not (opts.lookup_tree and target and opts.lookup_tree(target.UserId)) then
      target_player = resolve_player(target) or target
    end
    if (not target_player or target_player.UserId == nil) and type(opts.players) == "function" then
      for _, candidate in ipairs(opts.players()) do
        if candidate == target or candidate.Character == target then
          target_player = candidate
          break
        end
      end
    end
    if not target_player or target_player.UserId == nil then return false end
    if hit.sourcePlayer then
      local source_tree = opts.lookup_tree and opts.lookup_tree(hit.sourcePlayer.UserId)
      if not source_tree and target_player ~= player then return false end
    end
    local tree = opts.lookup_tree and opts.lookup_tree(target_player.UserId) or nil
    if tree ~= player_tree then
      if tree and type(tree.apply_hit) == "function" then
        return tree:apply_hit(hit, target_player, amount)
      end
      return false
    end
    if damage_filter == false then damage_filter = nil end
    local filter = damage_filter
    if filter == nil and opts.damage_filter then
      local current = opts.damage_filter()
      if type(current) == "function" then filter = current end
    end
    if type(filter) == "function" then
      local context = opts.damage_context and opts.damage_context() or player_tree
      local ok, allowed = pcall(filter, hit, player, context)
      if not ok or allowed ~= true then return false end
    end
    if hit.targets[player.UserId] then return false end
    local applied, actual = apply_damage(amount, hit)
    if applied then hit.targets[player.UserId] = true end
    return applied, actual
  end

  function player_tree:request_action(kind)
    if memos.can_act:now() ~= true then return false end
    if kind ~= "attack" and kind ~= "throw" and kind ~= "reel" and kind ~= "use_item" then
      return false
    end
    return true
  end

  function player_tree:eat(item_id, cook_rate)
    if memos.can_act:now() ~= true then return false end
    local definition = type(item_id) == "string" and GameCfg.Items.Definitions[item_id]
    if type(definition) ~= "table" or type(definition.EatPercent) ~= "number" then return false end
    local rate = 1
    if finite_number(cook_rate) and cook_rate > 0 then rate = cook_rate end
    local percent = definition.EatPercent * rate
    local hunger = Vitals.restore(states.hunger:now(), vitals_cfg.MaxHunger, percent)
    states.hunger:set(hunger)
    if percent < 0 then
      local damage = math.floor(max_health() * -percent / 100)
      if damage > 0 then
        apply_damage(damage, player_tree:new_hit(player, "eat"))
      end
    else
      local health = read_health(player) or states.health:now()
      local restored = Vitals.restore(math.floor(health), max_health(), percent)
      set_controller_health(restored)
    end
    write_vitals()
    return true
  end

  function player_tree:_accept_rescue(rescuer)
    local rescuer_tree = opts.lookup_tree and rescuer and opts.lookup_tree(rescuer.UserId)
    if states.life_phase:now() ~= "downed" then return false, "not-downed" end
    if rescue:now() or platform:now() then return false, "busy" end
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
    local now = clock.now()
    local health = read_health(rescuer)
    rescue:set({
      by = rescuer,
      startedAt = now,
      endAt = now + rescue_cfg.DurationSec,
      startPos = { x = from.x, y = from.y, z = from.z },
      health = health,
    })
    states.life_phase:set("rescuing")
    publish()
    return true
  end

  function player_tree:begin_rescue(target)
    local target_tree = opts.lookup_tree and target and opts.lookup_tree(target.UserId)
    if not target_tree or type(target_tree._accept_rescue) ~= "function" then
      return false, "not-downed"
    end
    return target_tree:_accept_rescue(player)
  end

  local function cancel_rescue()
    if not rescue:now() then return false end
    rescue:set(nil)
    if states.life_phase:now() == "rescuing" then
      states.life_phase:set("downed")
      publish()
    end
    return true
  end

  function player_tree:cancel_rescue()
    return cancel_rescue()
  end

  local function update_rescue(now)
    local current = rescue:now()
    if not current then return end
    local rescuer = current.by
    local rescuer_tree = opts.lookup_tree and rescuer and opts.lookup_tree(rescuer.UserId)
    if not rescuer_tree or rescuer_tree.states.life_phase:now() ~= "alive" then
      cancel_rescue()
      return
    end
    local from, to = position_of(rescuer), position_of(player)
    if not from or not to then
      cancel_rescue()
      return
    end
    if rescue_cfg.InterruptMoveMeters and rescue_cfg.InterruptMoveMeters > 0
        and horizontal_distance(from, current.startPos) > rescue_cfg.InterruptMoveMeters then
      cancel_rescue()
      return
    end
    if rescue_cfg.InterruptOnDamage then
      local health = read_health(rescuer)
      if health and current.health and health < current.health then
        cancel_rescue()
        return
      end
    end
    if now + 1e-9 >= current.endAt then
      rescue:set(nil)
      rescue_success()
    end
  end

  local function try_recover()
    if recover_flying or not recovering:now() then return end
    local inst = current_data()
    if not inst or not save_api or type(save_api.resolve_request) ~= "function" then return end
    local operation, mode = save_api:resolve_request(player, inst, "survival:recover", episode:now() + 1)
    if mode == "replay" then
      recovering:set(false)
      return
    end
    if not operation or type(save_api.execute) ~= "function" then return end
    recover_flying = true
    local accepted = save_api:execute(player, inst, operation, function(draft)
      local mark = draft.extra and draft.extra.survival
      if type(mark) ~= "table" then return nil, "no-mark" end
      mark.dying, mark.dead = false, false
      mark.dyingRemaining, mark.deadRemaining = 0, 0
      mark.weakRemaining = survival_cfg.WeakSec
      return { ok = true }
    end, function(written)
      recover_flying = false
      if player_tree:is_disposed() then return end
      if not written then return end
      recovering:set(false)
      local live = mark_table()
      if live and live ~= inst.extra.survival and inst.extra and inst.extra.survival then
        live.dying, live.dead = false, false
        live.dyingRemaining, live.deadRemaining = 0, 0
        live.weakRemaining = survival_cfg.WeakSec
      end
      weak_revive()
    end)
    if not accepted then recover_flying = false end
  end

  local function resume_platform(pending)
    local paused = math.max(0, clock.now() - (pending.startedAt or clock.now()))
    local phase = states.life_phase:now()
    local now = clock.now()
    local function reopen(deadline)
      if not deadline then return end
      local sec = math.floor(deadline)
      if sec < rescue_sec then rescue_sec = sec end
    end
    if phase == "dead" and dead_until:now() then
      dead_until:set(dead_until:now() + paused)
      if now + 1e-9 >= dead_until:now() then weak_revive() else reopen(dead_until:now()) end
    elseif (phase == "downed" or phase == "rescuing") and downed_until:now() then
      downed_until:set(downed_until:now() + paused)
      if now + 1e-9 >= downed_until:now() then enter_dead(false) else reopen(downed_until:now()) end
    end
    publish()
  end

  local function on_action(payload)
    if type(payload) ~= "table" then return end
    local seq = payload.seq
    local function fail(reason)
      reply({ seq = seq, ok = false, action = payload.action, mode = payload.mode, reason = reason })
    end
    if payload.action == "UseAdrenaline" then
      if not finite_number(seq) or seq ~= math.floor(seq) or seq < 1 then return fail("invalid") end
      local inst = current_data()
      if states.life_phase:now() ~= "downed" or platform:now() or adrenaline_flying then
        return fail("not-downed")
      end
      if not inst or not save_api then return fail("unavailable") end
      local item_id = survival_cfg.AdrenalineItemId
      local count = type(inst.ItemCount) == "function" and inst:ItemCount(item_id) or 0
      if count < 1 then
        if platform_api and type(platform_api.shop_action) == "function" then
          pcall(platform_api.shop_action, player, { action = "OpenAdrenaline" })
        end
        return fail("no-adrenaline")
      end
      local operation, mode = save_api:resolve_request(player, inst, "survival:adrenaline", seq)
      if mode == "replay" then return fail("replay") end
      if not operation then return fail(tostring(mode)) end
      local token = episode:now()
      adrenaline_flying = true
      local accepted, why = save_api:execute(player, inst, operation, function(draft)
        if type(draft.ConsumeItem) ~= "function" or not draft:ConsumeItem(item_id) then
          return nil, "no-adrenaline"
        end
        return { ok = true, seq = seq }
      end, function(written)
        adrenaline_flying = false
        if player_tree:is_disposed() then return end
        if not written or states.life_phase:now() ~= "downed" or episode:now() ~= token then
          return fail("not-downed")
        end
        rescue_success()
        reply({ seq = seq, ok = true, action = "UseAdrenaline" })
      end)
      if not accepted then
        adrenaline_flying = false
        fail(why or "pending")
      end
      return
    end
    if payload.action == "FullRevive" then
      if not finite_number(seq) or seq ~= math.floor(seq) or seq < 1 then return fail("invalid") end
      local mode = payload.mode
      if mode ~= "ad" and mode ~= "goods" then return fail("invalid") end
      local phase = states.life_phase:now()
      if phase ~= "downed" and phase ~= "dead" then return fail("not-revivable") end
      if phase == "downed" and mode ~= "ad" then return fail("not-dead") end
      if recovering:now() then return fail("recovering") end
      if platform:now() then return fail("busy") end
      if not platform_api then return fail("unavailable") end
      local pending = {
        mode = mode,
        seq = seq,
        startedAt = clock.now(),
        episode = episode:now(),
      }
      local function on_result(outcome)
        if platform:now() ~= pending or player_tree:is_disposed() then return end
        platform:set(nil)
        states.platform_pending:set(false)
        if outcome == "success" and episode:now() == pending.episode and full_revive() then
          reply({ seq = seq, ok = true, action = "FullRevive", mode = mode })
          return
        end
        resume_platform(pending)
        reply({
          seq = seq,
          ok = false,
          action = "FullRevive",
          mode = mode,
          reason = outcome == "success" and "not-revivable" or tostring(outcome),
        })
      end
      platform:set(pending)
      states.platform_pending:set(true)
      local accepted, reason
      if mode == "ad" and type(platform_api.show_ad) == "function" then
        accepted, reason = platform_api:show_ad(player, "revive", "revive", on_result)
      elseif mode == "goods" and type(platform_api.purchase) == "function" then
        accepted, reason = platform_api:purchase(player, "reviveFull", "revive", on_result)
      end
      if not accepted then
        if platform:now() == pending then
          platform:set(nil)
          states.platform_pending:set(false)
        end
        local why = reason or "unavailable"
        local platform_cfg = GameCfg.Platform or {}
        local text = why == "not_open" and platform_cfg.NotOpenText
          or why == "unavailable" and platform_cfg.UnavailableText or nil
        return reply({ seq = seq, ok = false, action = payload.action, mode = payload.mode,
          reason = why, text = text })
      end
      publish()
      return
    end
    if payload.action == "CallHelp" then
      if states.life_phase:now() ~= "downed" then return end
      local now = clock.now()
      if last_help_at and now - last_help_at < survival_cfg.HelpCooldownSec then return end
      last_help_at = now
      help_index = (help_index % #survival_cfg.HelpCries) + 1
      if remote and type(remote.get_re) == "function" and type(opts.players) == "function" then
        local ok, event = pcall(remote.get_re, remote, "SurvivalHelp")
        local origin = position_of(player)
        if ok and event and origin then
          for _, other in ipairs(opts.players()) do
            if other ~= player and distance3(origin, position_of(other)) <= survival_cfg.HelpRadius then
              pcall(event.FireClient, event, other, {
                userId = player.UserId,
                name = player.Name,
                text = survival_cfg.HelpCries[help_index],
              })
            end
          end
        end
      end
    end
  end

  function player_tree:handle_survival_action(payload, skip_cd)
    if player_tree:is_disposed() or type(payload) ~= "table" then return false end
    if not skip_cd and remote and type(remote.check_recd) == "function"
        and remote:check_recd(player, "SurvivalAction", GameCfg.Items.ActionCooldownSec) then
      return false
    end
    on_action(payload)
    return true
  end

  local function on_second()
    if player_tree:is_disposed() or player_tree.session_alive:now() == false then return end
    local now = clock.now()
    local phase = states.life_phase:now()
    if phase ~= "alive" then last_hunger_sec = math.floor(now) end
    if platform:now() and phase ~= "alive" then return end
    if phase == "alive" and not recovering:now() then
      local sec = math.floor(now)
      if sec > last_hunger_sec then
        local elapsed = math.min(sec - last_hunger_sec, vitals_cfg.MaxCatchUpSec)
        last_hunger_sec = sec
        local hunger, damage = Vitals.advance(states.hunger:now(), elapsed, vitals_cfg)
        if hunger ~= states.hunger:now() then states.hunger:set(hunger) end
        if carrying_barrel(current_data()) then
          apply_damage(vitals_cfg.HeldDamage.DamagePerSec * elapsed, player_tree:new_hit(nil, "heldItem"))
        end
        if damage > 0 and states.life_phase:now() == "alive" then
          apply_damage(damage, player_tree:new_hit(nil, "hunger"))
        end
        write_vitals()
      end
      apply_walk()
      local health = read_health(player)
      if health and health <= 0 then enter_dead(true) end
    elseif phase == "rescuing" then
      if downed_until:now() and now + 1e-9 >= downed_until:now() then
        enter_dead(false)
      end
    elseif phase == "downed" then
      if not adrenaline_flying and downed_until:now() and now + 1e-9 >= downed_until:now() then
        enter_dead(false)
      end
    elseif phase == "dead" then
      if recovering:now() then
        try_recover()
      elseif dead_until:now() and now + 1e-9 >= dead_until:now() then
        weak_revive()
      end
    end
  end

  s3:effect("WeakSpeedWatch", function(es)
    es:d(states.is_weak)
    es:d(states.is_frost)
    es:d(states.is_paralyzed)
    apply_walk()
  end)

  s3:subscribe(clock.on_second, function(sec)
    if sec <= rescue_sec then return end
    if platform:now() and states.life_phase:now() ~= "alive" then
      rescue_sec = sec - 1
      return
    end
    rescue_sec = sec
    on_second()
  end)

  local need_frame_watch = s3:memo("NeedLifeFrameWatch", function(ms)
    local phase = ms:d(states.life_phase)
    local paused = ms:d(platform)
    return phase ~= "alive" and (phase == "rescuing" or not paused)
  end)
  s3:phase("LifeCountdownFrame", need_frame_watch, function(rs)
    rs:subscribe(clock.on_frame, function(frame)
      if player_tree:is_disposed() or player_tree.session_alive:now() == false then return end
      local now = frame and frame.now or clock.now()
      local phase = states.life_phase:now()
      if not platform:now() then
        if phase == "downed" and not adrenaline_flying and downed_until:now()
            and now + 1e-9 >= downed_until:now() then
          enter_dead(false)
          return
        end
        if phase == "dead" and not recovering:now() and dead_until:now()
            and now + 1e-9 >= dead_until:now() then
          weak_revive()
          return
        end
      end
      if phase ~= "rescuing" then return end
      local current = rescue:now()
      if not current then return end
      local rescuer = current.by
      local rescuer_tree = opts.lookup_tree and rescuer and opts.lookup_tree(rescuer.UserId)
      local from = position_of(rescuer)
      local moved = from and current.startPos
        and horizontal_distance(from, current.startPos) > (rescue_cfg.InterruptMoveMeters or 1)
      local health = read_health(rescuer)
      local hurt = rescue_cfg.InterruptOnDamage and health and current.health and health < current.health
      local rescuer_down = not rescuer_tree or rescuer_tree.states.life_phase:now() ~= "alive"
      if moved or hurt or rescuer_down or not from or not position_of(player) then
        cancel_rescue()
        return
      end
      if now + 1e-9 >= current.endAt then
        if downed_until:now() and now + 1e-9 >= downed_until:now() and not platform:now() then
          enter_dead(false)
        else
          rescue:set(nil)
          rescue_success()
        end
      end
    end)
  end)

  noticed_health = read_health(player)
  local function note_health(next_health)
    local before = noticed_health
    noticed_health = next_health
    if suppress_health_note then return end
    if not finite_number(before) or not finite_number(next_health) or next_health >= before then return end
    if states.life_phase:now() ~= "alive" then return end
    publish_notice(before - next_health)
  end
  local controller = controller_of(player)
  if controller and controller.HealthChanged and type(controller.HealthChanged.Connect) == "function" then
    local conn
    conn = controller.HealthChanged:Connect(function(next_health)
      if player_tree:is_disposed() then return end
      note_health(next_health)
    end)
    s3:on_cleanup(function()
      if conn and conn.Disconnect then pcall(conn.Disconnect, conn) end -- 角色控制器可能已随引擎卸载
    end)
  end
  if controller and controller.Died and type(controller.Died.Connect) == "function" then
    local conn
    conn = controller.Died:Connect(function()
      if player_tree:is_disposed() then return end
      if states.life_phase:now() == "alive" then enter_dead(true) end
    end)
    s3:on_cleanup(function()
      if conn and conn.Disconnect then pcall(conn.Disconnect, conn) end -- 角色控制器可能已随引擎卸载
    end)
  end

  local function finish_spawn()
    if type(player_tree.capture_base_speed) == "function" then
      player_tree:capture_base_speed(player.Character)
    end
    apply_walk()
    if (raw.dying or raw.dead) and states.life_phase:now() ~= "alive" then
      recovering:set(true)
      states.life_phase:set("dead")
      set_controller_health(1)
      publish()
      try_recover()
    elseif finite_number(raw.weakRemaining) and raw.weakRemaining > 0 and not raw.dying and not raw.dead then
      local seconds = math.min(raw.weakRemaining, survival_cfg.WeakSec)
      if player_tree:get_modifier_remaining("weak") <= 0 then
        player_tree:apply_modifier("weak", { duration = seconds })
      end
      publish()
    else
      write_vitals()
      write_attr(player, "SurvivalPhase", states.life_phase:now())
    end
    player_tree:register_leave_finalizer(function()
      publish()
      local inst = current_data()
      local mark = mark_table()
      if type(inst) == "table" and inst ~= data and type(mark) == "table" then
        if type(inst.extra) ~= "table" then inst.extra = {} end
        inst.extra.survival = mark
      end
    end)
  end

  player_tree._life_finish = finish_spawn
  action_seq = action_seq
end

return PlayerLife
