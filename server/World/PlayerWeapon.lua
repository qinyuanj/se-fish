-- 玩家武器会话（#300 / ADR-0032 §2）：挂在存活相位内的换弹与主动攻击。
-- 近战仍登记一次性挥砍，由既有命中盒消费；枪械、溅射与爆炸只经生命公开入口结算。
-- 本模块不持有生命、队伍或区域状态，宿主注入时钟、物理、玩家列表与效果施加。

local GameCfg = require("common.GameCfg")
local Number = require("common.Number")
local MathWaterJudge = require("common.MathWaterJudge")
local SwingRegistry = require("server.SwingRegistry")
local State = require("common.packages.spoke.api").State

local PlayerWeapon = {}

local ATTACK_ANIM_FILTER = 30
local ATTACK_ANIM_PRIORITY = 2
local THROW_VISUAL_MESH = 57450

local function ability()
  return GameCfg.Ability
end

local function finite(value)
  return Number.IsFiniteNumber(value)
end

local function vec(x, y, z)
  if Vector3 then return Vector3.New(x, y, z) end
  return { x = x, y = y, z = z }
end

local function distance2d(a, b)
  local dx, dz = (a.x or 0) - (b.x or 0), (a.z or 0) - (b.z or 0)
  return math.sqrt(dx * dx + dz * dz)
end

local function reply(remote, player, payload)
  if remote and type(remote.GetRE) == "function" then
    local ok, event = pcall(remote.GetRE, remote, "WeaponResult")
    if ok and event and type(event.FireClient) == "function" then
      pcall(event.FireClient, event, player, payload)
    end
  end
  return payload
end

local function fail(remote, player, action, reason, extra)
  print("[PlayerWeapon] 拒绝", player and player.UserId, tostring(action), reason)
  local payload = { ok = false, action = action, reason = reason }
  if type(extra) == "table" then
    for key, value in pairs(extra) do payload[key] = value end
  end
  return reply(remote, player, payload)
end

local function equipped_weapon(tree)
  local held = tree.states.held and tree.states.held:now() or nil
  local weapons = tree.states.weapons and tree.states.weapons:now() or {}
  if type(held) == "table" and held.kind == "weapon" and (weapons[held.id] or 0) > 0 then
    return held.id
  end
  local selected = tree.states.selected_weapon and tree.states.selected_weapon:now() or nil
  if selected and (weapons[selected] or 0) > 0 then return selected end
  return nil
end

local function magazine_size(data, base)
  if data and type(data.MagazineSize) == "function" then
    local ok, size = pcall(data.MagazineSize, data, base)
    if ok and finite(size) then return size end
  end
  return base
end

local function damage_scale(tree, kind)
  local scales = tree.memos.weapon_damage_scales and tree.memos.weapon_damage_scales:now() or nil
  local scale = scales and scales[kind] or 1
  if not finite(scale) or scale <= 0 then return 1 end
  return scale
end

local function character_of(player)
  local ok, character = pcall(function() return player and player.Character end)
  if ok then return character end
  return nil
end

local function forward_of(character)
  local fx, fy, fz = 0, 0, 1
  if character then
    pcall(function()
      local forward = character.Rotation:GetForward()
      fx, fy, fz = forward.x or 0, forward.y or 0, forward.z or 1
    end)
  end
  return fx, fy, fz
end

local function play_anim(tracks, player, anim)
  local character = character_of(player)
  if not (anim and character and character.Animator) then return false end
  local ok, err = pcall(function()
    local by_character = tracks[character]
    if not by_character then
      by_character = {}
      tracks[character] = by_character
    end
    local track = by_character[anim]
    if not track then
      track = character.Animator:LoadAnimation(anim)
      track.FilterType = ATTACK_ANIM_FILTER
      track.Looped = false
      local priority_ok, priority_err = pcall(function() track.Priority = ATTACK_ANIM_PRIORITY end)
      if not priority_ok then
        print("[PlayerWeapon] 出手动作优先级设置失败，按默认优先级播", tostring(anim), tostring(priority_err))
      end
      by_character[anim] = track
    end
    track:Play(0.05, 1, 1)
  end)
  if not ok then
    print("[PlayerWeapon] 出手动作播放失败", player.UserId, tostring(anim), tostring(err))
  end
  return ok
end

local function normalize_aim(aim)
  if aim == nil then return nil, true end
  if type(aim) ~= "table" or not finite(aim.x) or not finite(aim.y) or not finite(aim.z) then
    return nil, false
  end
  local length = math.sqrt(aim.x * aim.x + aim.y * aim.y + aim.z * aim.z)
  if not finite(length) or length < 1e-6 then return nil, false end
  return { x = aim.x / length, y = aim.y / length, z = aim.z / length }, true
end

local function service(name, injected)
  if injected ~= nil then return injected end
  local ok, value = pcall(function() return game:GetService(name) end)
  if ok then return value end
  return nil
end

local function melee_index(opts)
  if opts.ability and type(opts.ability.MeleeIndex) == "function" then
    return opts.ability.MeleeIndex()
  end
  for _, entry in ipairs(ability().InitialAbilities or {}) do
    if entry.AnchorBehavior == "melee_hit" then return entry.Index end
  end
  return nil
end

local function cast_melee(opts, player)
  local index = melee_index(opts)
  local character = character_of(player)
  if index == nil or not character then return false end
  local caster = opts.ability and opts.ability.CastAbility
  if type(caster) ~= "function" then return false end
  local ok, cast = pcall(caster, character, index)
  if not ok then
    print("[PlayerWeapon] 挥砍施法失败", player.UserId, tostring(cast))
    return false
  end
  return cast == true
end

local function apply_effect(opts, source, target, effect)
  if type(effect) ~= "table" or type(effect.Kind) ~= "string" then return end
  if type(opts.apply_effect) == "function" then
    local ok, err = pcall(opts.apply_effect, source, target, effect.Kind)
    if not ok then print("[PlayerWeapon] 武器特效应用失败", tostring(err)) end
  end
end

local function radial_damage(opts, center, radius, amount, hit, skip)
  if not hit or not center or type(opts.apply_hit) ~= "function" then return 0 end
  local damaged = 0
  local players = opts.players_service or service("Players", nil)
  local list = {}
  if players and type(players.GetPlayers) == "function" then
    local ok, got = pcall(players.GetPlayers, players)
    if ok and type(got) == "table" then list = got end
  end
  for _, target in ipairs(list) do
    local skipped = false
    if type(skip) == "table" and skip[1] ~= nil then
      for _, entry in ipairs(skip) do
        if entry == target then skipped = true break end
      end
    else
      skipped = target == skip
    end
    if not skipped then
      local pos = character_of(target) and character_of(target).Position
      local dist = pos and distance2d(center, pos) or -1
      if pos and dist <= radius then
        local applied = opts.apply_hit(hit, target, amount) == true
        if applied then damaged = damaged + 1 end
      end
    end
  end
  local fish = opts.fish_unit
  if fish and type(fish.Fish) == "table" then
    for _, entry in pairs(fish.Fish) do
      local body = entry.Carrier and entry.Carrier.Body
      local pos = body and body.Position
      if pos and distance2d(center, pos) <= radius then
        if opts.apply_hit(hit, entry.Carrier, amount) == true then damaged = damaged + 1 end
      end
    end
  end
  return damaged
end

local function gun_hit(opts, player, aim)
  local character = character_of(player)
  local pos = character and character.Position
  if not pos then return nil, nil end
  local fx, fy, fz = forward_of(character)
  if aim then fx, fy, fz = aim.x, aim.y, aim.z end
  local range = ability().GunShared.Range or 30
  local origin = { x = pos.x, y = pos.y + 1, z = pos.z }
  local end_pos = { x = origin.x + fx * range, y = origin.y + fy * range, z = origin.z + fz * range }
  local physics = service("PhysicsService", opts.physics)
  if not physics or type(physics.Raycast) ~= "function" then return nil, end_pos end
  local params = nil
  if RaycastParams then
    local ok, created = pcall(RaycastParams.New)
    if ok and created then
      created.FilterDescendantsInstances = { character }
      params = created
    end
  end
  local ray_origin, ray_dir = vec(origin.x, origin.y, origin.z), vec(fx * range, fy * range, fz * range)
  local ok, hit = pcall(function()
    return physics:Raycast(ray_origin, ray_dir, params)
  end)
  if (not ok or hit == nil) and physics.Raycast then
    ok, hit = pcall(physics.Raycast, ray_origin, ray_dir, params)
  end
  if not ok or (type(hit) ~= "table" and type(hit) ~= "userdata") or not hit.Instance then return nil, end_pos end
  local hit_pos = hit.Position or end_pos
  local players = service("Players", opts.players_service)
  local target = players and type(players.GetPlayerFromCharacter) == "function"
    and players:GetPlayerFromCharacter(hit.Instance) or nil
  if target then return target, hit_pos end
  if opts.fish_carrier and type(opts.fish_carrier.ResolveCarrier) == "function" then
    local carrier = opts.fish_carrier:ResolveCarrier(hit.Instance)
    if carrier then return carrier, hit_pos end
  end
  return nil, hit_pos
end

local function water_zone_at(x, z)
  for _, zone in ipairs(GameCfg.Water.Zones or {}) do
    if MathWaterJudge.InZone(zone, { x = x, y = zone.SurfaceY, z = z }) then return zone end
  end
  return nil
end

local function resolve_landing(player, target)
  local character = character_of(player)
  local pos = character and character.Position
  local throw_cfg = ability().Throw
  local tx, ty, tz
  if type(target) == "table" and finite(target.x) and finite(target.y) and finite(target.z) then
    tx, ty, tz = target.x, target.y, target.z
  else
    local fx, _, fz = forward_of(character)
    local len = math.sqrt(fx * fx + fz * fz)
    if len > 0.001 then fx, fz = fx / len, fz / len end
    tx = (pos and pos.x or 0) + fx * throw_cfg.Range
    ty = pos and pos.y or 0
    tz = (pos and pos.z or 0) + fz * throw_cfg.Range
  end
  if pos then
    local dx, dz = tx - pos.x, tz - pos.z
    local dist = math.sqrt(dx * dx + dz * dz)
    if dist > throw_cfg.Range then
      local scale = throw_cfg.Range / dist
      tx, tz = pos.x + dx * scale, pos.z + dz * scale
    end
  end
  local zone = water_zone_at(tx, tz)
  if zone then ty = zone.SurfaceY end
  return { x = tx, y = ty, z = tz }, zone
end

local function blast_candidates(rows)
  local out = {}
  local rod = ability().Throw.FishRodLevel
  for _, row in ipairs(rows or {}) do
    local species = row.Id and GameCfg.Fish[row.Id]
    if species and row.RodLevel == rod and species.Grade == "normal" then
      out[#out + 1] = { id = row.Id, weight = row.DrawWeight or 1 }
    end
  end
  return out
end

local function pick_blast_fish(candidates, random)
  local total = 0
  for _, candidate in ipairs(candidates) do total = total + (candidate.weight or 1) end
  if total <= 0 then return nil end
  local roll = (random or math.random)() * total
  for _, candidate in ipairs(candidates) do
    roll = roll - (candidate.weight or 1)
    if roll <= 0 then return candidate.id end
  end
  local last = candidates[#candidates]
  return last and last.id or nil
end

local function spawn_blast_fish(opts, zone, landing, player)
  if not opts.fish_unit or type(opts.fish_unit.SpawnBlastFish) ~= "function" then return 0 end
  local rows = GameCfg.Casting and GameCfg.Casting.Zones and GameCfg.Casting.Zones[zone.Id]
  local candidates = blast_candidates(rows)
  if #candidates == 0 then
    print("[PlayerWeapon] 爆炸落水但该水区没有 1 级普通鱼保底", zone.Id)
    return 0
  end
  local throw_cfg = ability().Throw
  local random = opts.random or math.random
  local count = random(throw_cfg.FishMin, throw_cfg.FishMax)
  for _ = 1, count do
    local fish_id = pick_blast_fish(candidates, random)
    local angle = random() * math.pi * 2
    local radius = 0.5 + random() * 1.5
    opts.fish_unit:SpawnBlastFish(fish_id, 1, {
      x = landing.x + math.cos(angle) * radius,
      y = zone.SurfaceY,
      z = landing.z + math.sin(angle) * radius,
    }, player)
  end
  return count
end

local function detonate(session, flight)
  local explosive = ability().Explosives[flight.item_id]
  if not explosive or not flight.landing then return 0 end
  local tree = session.tree
  local scale = damage_scale(tree, "explosive")
  local damage = explosive.Damage * scale
  if flight.zone then
    local ok, err = pcall(spawn_blast_fish, session.opts, flight.zone, flight.landing, flight.player)
    if ok then
      print("[PlayerWeapon] 爆炸落水", flight.zone.Id, flight.item_id, "保底鱼=" .. tostring(err))
    else
      print("[PlayerWeapon] 爆炸落水保底鱼失败", flight.zone.Id, flight.item_id, tostring(err))
    end
  end
  local hit = session.opts.new_hit and session.opts.new_hit(flight.player, "explosive") or nil
  local damaged = radial_damage(session.opts, flight.landing, ability().Throw.ExplosionRadius,
    damage, hit, flight.player)
  print("[PlayerWeapon] 爆炸", flight.item_id, flight.zone and "water" or "land",
    "damage=" .. tostring(damage), "命中=" .. tostring(damaged))
  return damaged
end

local function flight_position(flight, t)
  local from, to = flight.from, flight.landing
  if not from then return { x = to.x, y = to.y, z = to.z } end
  local arc = ability().Throw.ArcHeight or 3
  return {
    x = from.x + (to.x - from.x) * t,
    y = from.y + (to.y - from.y) * t + math.sin(t * math.pi) * arc,
    z = from.z + (to.z - from.z) * t,
  }
end

local function step_flights(session, now)
  for index = #session.flying, 1, -1 do
    local flight = session.flying[index]
    local t = (now - flight.start_at) / (flight.flight_sec or 0.8)
    if t >= 1 then
      table.remove(session.flying, index)
      if flight.visual then
        local destroyed, err = pcall(function() flight.visual:Destroy() end)
        if not destroyed then
          print("[PlayerWeapon] 视觉销毁失败", flight.player and flight.player.UserId,
            flight.item_id, tostring(err))
        end
      end
      detonate(session, flight)
    elseif flight.visual then
      pcall(function() flight.visual.Position = flight_position(flight, math.max(0, t)) end) -- 视觉位姿失败不影响结算
    end
  end
  if #session.flying == 0 and session.has_flights then
    session.has_flights:set(false)
  end
end

local function create_visual(session, player, flight)
  session.throw_seq = session.throw_seq + 1
  local world = service("World", session.opts.world)
  if not world or type(world.CreateUnit) ~= "function" then return nil end
  local ok, visual = pcall(world.CreateUnit, world, "TriggerUnit", {
    Name = "ThrowProjectile_" .. tostring(player.UserId) .. "_" .. tostring(session.throw_seq),
    PhysicsMeshId = THROW_VISUAL_MESH,
    Position = flight_position(flight, 0),
    Scale = vec(1, 1, 1),
  })
  if ok and visual then return visual end
  print("[PlayerWeapon] 投掷物视觉创建失败（不影响结算）", tostring(visual))
  return nil
end

local function launch(session, player, item_id, target)
  local landing, zone = resolve_landing(player, target)
  local character = character_of(player)
  local flight = {
    player = player,
    item_id = item_id,
    from = character and character.Position or nil,
    landing = landing,
    zone = zone,
    start_at = session.now(),
    flight_sec = ability().Throw.FlightSec or 0.8,
  }
  flight.visual = create_visual(session, player, flight)
  session.flying[#session.flying + 1] = flight
  if session.has_flights then session.has_flights:set(true) end
  play_anim(session.tracks, player, ability().Throw.Anim)
  print("[PlayerWeapon] 投掷", player.UserId, item_id, zone and ("落水 " .. zone.Id) or "落地")
  return flight
end

local function mag_of(session, weapon_id, size)
  local mag = session.mags[weapon_id]
  if not mag then
    mag = { ammo = size, reload_until = nil }
    session.mags[weapon_id] = mag
  end
  return mag
end

local function refresh_mag(mag, size, now)
  if mag.reload_until and now >= mag.reload_until then
    mag.reload_until = nil
    mag.ammo = size
  end
end

local function clear_reload(session, weapon_id)
  if weapon_id == nil then
    for _, mag in pairs(session.mags) do mag.reload_until = nil end
    return
  end
  local mag = session.mags[weapon_id]
  if mag then mag.reload_until = nil end
end

local function attack_melee(session, player, weapon_id)
  local cfg = weapon_id and ability().MeleeWeapons[weapon_id] or ability().Unarmed
  if not cfg then return fail(session.remote, player, "attack", "bad-weapon", { weapon = weapon_id }) end
  local now = session.now()
  local key = weapon_id or "unarmed"
  if now - (session.melee_at[key] or 0) < cfg.IntervalSec then
    return fail(session.remote, player, "attack", "cooldown", { weapon = weapon_id })
  end
  local scale = weapon_id and damage_scale(session.tree, "melee") or 1
  local damage = cfg.Damage * scale
  if not SwingRegistry.StageSwing(player.UserId, { damage = damage, range = cfg.Range, effect = cfg.Effect }) then
    return fail(session.remote, player, "attack", "swing-unavailable", { weapon = weapon_id })
  end
  session.melee_at[key] = now
  if not cast_melee(session.opts, player) then
    SwingRegistry.ClearSwing(player.UserId)
    return fail(session.remote, player, "attack", "cast-failed", { weapon = weapon_id })
  end
  play_anim(session.tracks, player, cfg.Anim)
  print("[PlayerWeapon] 挥砍发起", player.UserId, tostring(weapon_id or "unarmed"),
    "damage=" .. tostring(damage), "range=" .. tostring(cfg.Range))
  return reply(session.remote, player, {
    ok = true, action = "attack", weapon = weapon_id, damage = damage, range = cfg.Range,
  })
end

local function attack_gun(session, player, weapon_id, cfg, aim)
  local now = session.now()
  local size = magazine_size(session.tree.data, cfg.Magazine)
  local mag = mag_of(session, weapon_id, size)
  refresh_mag(mag, size, now)
  if mag.reload_until then
    return fail(session.remote, player, "attack", "reloading", { weapon = weapon_id, ammo = mag.ammo })
  end
  if now - (session.fire_at[weapon_id] or 0) < cfg.IntervalSec then
    return fail(session.remote, player, "attack", "cooldown", { weapon = weapon_id })
  end
  if mag.ammo <= 0 then
    mag.reload_until = now + ability().GunShared.ReloadSec
    print("[PlayerWeapon] 空匣自动换弹", player.UserId, weapon_id)
    return fail(session.remote, player, "attack", "empty", { weapon = weapon_id, autoReload = true })
  end
  mag.ammo = mag.ammo - 1
  session.fire_at[weapon_id] = now
  play_anim(session.tracks, player, cfg.Anim)
  local scale = damage_scale(session.tree, "ranged")
  local target, hit_pos = gun_hit(session.opts, player, aim)
  local pellets = cfg.Pellets or 1
  local damage = cfg.Damage * scale
  if target then
    local applied = false
    for _ = 1, pellets do
      local hit = session.opts.new_hit(player, "weapon")
      local result = session.opts.apply_hit(hit, target, damage)
      applied = result == true or applied
    end
    if applied then apply_effect(session.opts, player, target, cfg.Effect) end
    print("[PlayerWeapon] 枪击命中", player.UserId, weapon_id, "ammo=" .. tostring(mag.ammo))
  else
    print("[PlayerWeapon] 枪击未命中", player.UserId, weapon_id, "ammo=" .. tostring(mag.ammo))
  end
  if cfg.Splash and hit_pos then
    local splash_hit = session.opts.new_hit(player, "weapon")
    local skipped = { player }
    if target then skipped[#skipped + 1] = target end
    radial_damage(session.opts, hit_pos, cfg.Splash.Radius, cfg.Splash.Damage * scale,
      splash_hit, skipped)
  end
  return reply(session.remote, player, { ok = true, action = "attack", weapon = weapon_id, ammo = mag.ammo })
end

local function selected_explosive(tree)
  local snapshot = tree.get_item_bar_snapshot and tree:get_item_bar_snapshot() or nil
  local slot = snapshot and snapshot.selectedSlot
  local entry = slot and snapshot.slots and snapshot.slots[slot]
  local definition = entry and GameCfg.Items.Definitions[entry.itemId]
  if definition and definition.Type == "爆炸物" then
    return { slot = slot, item_id = entry.itemId }
  end
  return nil
end

local function consume_throwable(session, player, slot, item_id, payload)
  local save = session.opts.save
  local data = session.tree.data
  if not save then
    local container = data.Data and data.Data.Containers and data.Data.Containers[GameCfg.Items.ContainerId.ItemBar]
    local entry = container and container[slot]
    if not entry or (entry.count or 0) <= 0 or entry.itemId ~= item_id then
      return fail(session.remote, player, "throw", "empty", { slot = slot })
    end
    if entry.count > 1 then entry.count = entry.count - 1 else container[slot] = nil end
    launch(session, player, item_id, payload.target)
    return reply(session.remote, player, { ok = true, action = "throw", itemId = item_id, slot = slot })
  end
  if type(save.ResolveRequest) ~= "function" or type(save.Execute) ~= "function" then
    return fail(session.remote, player, "throw", "unavailable")
  end
  local request_id = payload.operation
  if request_id ~= nil and type(request_id) ~= "table" then
    return fail(session.remote, player, "throw", "bad-operation")
  end
  if request_id == nil then request_id = payload.seq end
  local operation, mode = save:ResolveRequest(player, data, "throw", request_id)
  if not operation then
    if mode == "replay" then return true end
    return fail(session.remote, player, "throw", "unavailable")
  end
  if mode == "replay" then
    return save:Execute(player, data, operation, function() return nil, "expired" end, function(ok, result)
      if ok then
        result.operation = operation
        reply(session.remote, player, result)
      end
    end) == true
  end
  return save:Execute(player, data, operation, function(draft)
    local container = draft.Data.Containers[GameCfg.Items.ContainerId.ItemBar]
    local entry = container and container[slot]
    if not entry or (entry.count or 0) <= 0 or entry.itemId ~= item_id then return nil, "empty" end
    if type(draft.UpdateData) == "function" then
      draft:UpdateData(function(stored)
        local current = stored.Containers[GameCfg.Items.ContainerId.ItemBar][slot]
        if current and current.count > 1 then current.count = current.count - 1
        else stored.Containers[GameCfg.Items.ContainerId.ItemBar][slot] = nil end
      end, true)
    end
    return { ok = true, action = "throw", itemId = item_id, slot = slot }
  end, function(written, result)
    if not written then
      fail(session.remote, player, "throw", result, { slot = slot })
      return
    end
    result.operation = operation
    reply(session.remote, player, result)
    launch(session, player, item_id, payload.target)
  end) == true
end

local function on_action(session, player, payload)
  if type(payload) ~= "table" then return false end
  if payload.action == "attack" then
    local aim, aim_ok = normalize_aim(payload.aim)
    if not aim_ok then
      fail(session.remote, player, "attack", "bad-aim")
      return false
    end
    if session.tree.memos.can_act:now() ~= true then
      SwingRegistry.ClearSwing(player.UserId)
      fail(session.remote, player, "attack", "cannot-act")
      return true
    end
    if not character_of(player) then
      fail(session.remote, player, "attack", "unavailable")
      return true
    end
    local weapon_id = equipped_weapon(session.tree)
    local guns, melee = ability().Guns, ability().MeleeWeapons
    if weapon_id and guns[weapon_id] then
      attack_gun(session, player, weapon_id, guns[weapon_id], aim)
    elseif weapon_id and melee[weapon_id] then
      attack_melee(session, player, weapon_id)
    else
      if weapon_id then print("[PlayerWeapon] 武器未配置攻击数值，回落空手", player.UserId, weapon_id) end
      attack_melee(session, player, nil)
    end
    return true
  end
  if payload.action == "reload" then
    if session.tree.memos.can_act:now() ~= true then
      fail(session.remote, player, "reload", "cannot-act")
      return true
    end
    local weapon_id = equipped_weapon(session.tree)
    local cfg = weapon_id and ability().Guns[weapon_id]
    if not cfg then return fail(session.remote, player, "reload", "not-a-gun", { weapon = weapon_id }) and true end
    local now = session.now()
    local size = magazine_size(session.tree.data, cfg.Magazine)
    local mag = mag_of(session, weapon_id, size)
    refresh_mag(mag, size, now)
    if mag.reload_until then return fail(session.remote, player, "reload", "reloading", { weapon = weapon_id }) and true end
    if mag.ammo >= size then return fail(session.remote, player, "reload", "mag-full", { weapon = weapon_id }) and true end
    mag.reload_until = now + ability().GunShared.ReloadSec
    print("[PlayerWeapon] 手动换弹", player.UserId, weapon_id)
    reply(session.remote, player, {
      ok = true, action = "reload", weapon = weapon_id, reloadSec = ability().GunShared.ReloadSec,
    })
    return true
  end
  if payload.action == "throw" then
    if session.tree.memos.can_act:now() ~= true then
      fail(session.remote, player, "throw", "cannot-act")
      return true
    end
    local slot = payload.slot
    if not finite(slot) or slot ~= math.floor(slot) or slot < 1 then
      fail(session.remote, player, "throw", "bad-slot")
      return true
    end
    local selected = selected_explosive(session.tree)
    if not selected or selected.slot ~= slot then
      fail(session.remote, player, "throw", "bad-throwable", { slot = slot })
      return true
    end
    local target = payload.target
    if target ~= nil and (type(target) ~= "table" or not finite(target.x) or not finite(target.y) or not finite(target.z)) then
      fail(session.remote, player, "throw", "bad-target")
      return true
    end
    consume_throwable(session, player, slot, selected.item_id, payload)
    return true
  end
  return false
end

function PlayerWeapon.mount(scope, tree, opts)
  opts = type(opts) == "table" and opts or {}
  local player = tree.player
  local has_flights = State.new("PlayerWeapon.has_flights", false)
  local session = {
    tree = tree,
    opts = opts,
    remote = opts.remote,
    now = function() return tree.clock.now() end,
    melee_at = {},
    fire_at = {},
    mags = {},
    flying = {},
    has_flights = has_flights,
    tracks = setmetatable({}, { __mode = "k" }),
    throw_seq = 0,
    equipped = equipped_weapon(tree),
  }

  -- 仅在投掷物飞行期间按需订阅 on_frame，空闲时零每帧订阅。
  scope:phase("ThrowFlightPhase", has_flights, function(fs)
    fs:subscribe(tree.clock.on_frame, function()
      step_flights(session, session.now())
    end)
  end)

  scope:effect("WeaponEquipWatch", function(es)
    es:d(tree.states.held)
    es:d(tree.states.selected_weapon)
    es:d(tree.states.weapons)
    local weapon_id = equipped_weapon(tree)
    if session.equipped ~= weapon_id then
      SwingRegistry.ClearSwing(player.UserId)
    end
    session.equipped = weapon_id
  end)

  scope:on_cleanup(function()
    clear_reload(session)
    SwingRegistry.ClearSwing(player.UserId)
    session.cleaned = true
    for index = #session.flying, 1, -1 do
      local flight = session.flying[index]
      if flight.visual then
        local destroyed, err = pcall(function() flight.visual:Destroy() end)
        if not destroyed then
          print("[PlayerWeapon] 清理阶段投掷物视觉销毁失败", player.UserId, flight.item_id, tostring(err))
        end
      end
      session.flying[index] = nil
    end
    has_flights:set(false)
  end)

  return {
    handle = function(_, payload) return on_action(session, player, payload) end,
    guard = function(_, unit, index)
      if index ~= melee_index(opts) then return true end
      local owner = nil
      local players = service("Players", opts.players_service)
      if players and type(players.GetPlayerFromCharacter) == "function" then
        owner = players:GetPlayerFromCharacter(unit)
      end
      if owner == nil and character_of(player) == unit then owner = player end
      if owner == nil then return true end
      return SwingRegistry.PeekSwing(owner.UserId) ~= nil
    end,
  }
end

return PlayerWeapon
