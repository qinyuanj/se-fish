
local GameCfg = require("common.game_cfg")
local FishCatch = require("common.fish_catch")
local MathWaterJudge = require("common.math_water_judge")
local Number = require("common.number")
local RateLimit = require("common.rate_limit")
local ReelProgress = require("common.reel_progress")
local State = require("common.packages.spoke.api").State

local FishingPhase = {}

local function finite(value)
  return Number.IsFiniteNumber(value)
end

local function now_of(tree)
  return tree.clock.now()
end

local function character_of(tree)
  local ok, character = pcall(function()
    return tree.states.character:now() or tree.player.Character
  end)
  if ok then return character end
  return nil
end

local function selected_rod(tree, payload)
  local slot = tree.states.selected_slot:now()
  local items = tree.states.item_bar:now() or {}
  local entry = type(slot) == "number" and items[slot] or nil
  local definition = entry and (entry.count or 0) >= 1 and GameCfg.Items.Definitions[entry.itemId]
  if not definition or type(definition.Level) ~= "number" then return nil end
  if type(payload) ~= "table" or payload.slot ~= slot or payload.itemId ~= entry.itemId then
    return nil
  end
  return slot, entry, definition
end

local function water_zone(x, z)
  local zones = GameCfg.Water and GameCfg.Water.Zones or {}
  for _, candidate in ipairs(zones) do
    if MathWaterJudge.InZone(candidate, { x = x, y = candidate.SurfaceY, z = z }) then
      return candidate
    end
  end
  return nil
end

local function cast_landing(character)
  local origin = character and character.Position
  local rotation = character and character.Rotation
  if not origin or not rotation or type(rotation.GetForward) ~= "function" then return nil end
  local forward = rotation:GetForward()
  if not forward or not finite(forward.x) or not finite(forward.z) then return nil end
  local length = math.sqrt(forward.x * forward.x + forward.z * forward.z)
  if length < 0.01 then return nil end
  local x = origin.x + GameCfg.Casting.Distance * forward.x / length
  local z = origin.z + GameCfg.Casting.Distance * forward.z / length
  local zone = water_zone(x, z)
  return { x = x, y = zone and zone.SurfaceY or origin.y, z = z }, zone
end

local function hook_position(session)
  local landing = session and session.landing
  if not landing then return nil end
  local species = session.fishId and GameCfg.Fish[session.fishId]
  local source = species and species.CatchSource or "water"
  local lift = source == "air" and GameCfg.Casting.AirSourceHeight or 0
  return { x = landing.x, y = landing.y + lift, z = landing.z }
end

local function copy_holding(info)
  if type(info) ~= "table" then return nil end
  return info
end

function FishingPhase.mount(scope, tree, opts)
  opts = type(opts) == "table" and opts or {}
  local player = tree.player
  local remote = opts.remote
  local fish_unit = opts.fish_unit
  local compendium = opts.compendium
  local quest = opts.quest
  local random_fn = opts.random or math.random
  local world = opts.world
  local create_unit = opts.create_unit
  local line_unit = nil
  local session = nil
  local reel = nil
  local next_cast_id = 0
  local next_reel_id = 0
  local next_fish = nil
  local next_fish_serial = 0
  local cleaned = false
  local active_frame = State.new("FishingPhase.active_frame", false)

  local function create_line(cast_id, landing)
    local maker = create_unit
    if type(maker) ~= "function" and world and type(world.CreateUnit) == "function" then
      maker = function(kind, props) return world:CreateUnit(kind, props) end
    end
    if line_unit or type(maker) ~= "function" or not landing then return end
    local ok, unit = pcall(maker, "LinkEffectUnit", {
      Name = "CastLine_" .. tostring(cast_id),
      EffectId = GameCfg.Casting.LineEffect,
      Position = { x = landing.x, y = landing.y, z = landing.z },
    })
    if ok and unit then
      line_unit = unit
    else
      print("[FishingPhase] 创建钓线失败", player.UserId, tostring(unit))
    end
  end

  local function destroy_line()
    local unit = line_unit
    line_unit = nil
    if unit and type(unit.Destroy) == "function" then
      local ok, err = pcall(unit.Destroy, unit)
      if not ok then print("[FishingPhase] 销毁钓线失败", player.UserId, tostring(err)) end
    end
  end

  local function fire_cast(payload)
    if not remote or type(remote.GetRE) ~= "function" then return end
    local ok, event = pcall(remote.GetRE, remote, "CastState")
    if ok and event and type(event.FireClient) == "function" then
      event:FireClient(player, payload)
    end
  end

  local function fire_reel(payload)
    if not remote or type(remote.GetRE) ~= "function" then return end
    local ok, event = pcall(remote.GetRE, remote, "ReelInRE")
    if ok and event and type(event.FireClient) == "function" then
      event:FireClient(player, payload)
    end
  end

  local function holding_info()
    if fish_unit and type(fish_unit.HeldInfo) == "function" then
      local ok, info = pcall(fish_unit.HeldInfo, fish_unit, player)
      if ok then return copy_holding(info) end
    end
    return nil
  end

  local function publish(reason)
    if cleaned then return end
    if not session then
      fire_cast({ phase = "idle", holding = holding_info(), result = reason and { reason = reason } or nil })
      return
    end
    local species = session.fishId and GameCfg.Fish[session.fishId]
    fire_cast({
      phase = session.phase,
      castId = session.castId,
      landing = session.landing,
      zoneId = session.zoneId,
      fishId = session.fishId,
      catchSource = species and species.CatchSource or "water",
      hookPosition = hook_position(session),
      mult = session.mult,
      reelSession = session.reelSession,
      holding = holding_info(),
      result = reason and { reason = reason } or nil,
    })
  end

  local function clear_session(reason, notify)
    session = nil
    reel = nil
    active_frame:set(false)
    destroy_line()
    if notify ~= false then publish(reason) end
  end

  local function consume_bait()
    local data = tree.data
    if type(data) ~= "table" or type(data.ConsumeSelectedBait) ~= "function" then
      return false, nil
    end
    local ok, success, bait_id = pcall(data.ConsumeSelectedBait, data)
    if not ok then
      print("[FishingPhase] 消耗鱼饵失败", player.UserId, tostring(success))
      return false, nil
    end
    if tree.sync_from_data then tree:sync_from_data(data) end
    return success == true, bait_id
  end

  local function can_cast()
    if tree.memos and tree.memos.can_act and tree.memos.can_act:now() ~= true then
      return false, "cannotAct"
    end
    if fish_unit and type(fish_unit.CanCast) == "function" and fish_unit:CanCast(player) ~= true then
      return false, "holding"
    end
    return true
  end

  local function begin_cast(payload)
    if session then
      publish()
      fire_cast({ phase = session.phase, castId = session.castId, result = { reason = "alreadyCasting" } })
      return false
    end
    local allowed, deny = can_cast()
    if not allowed then
      publish(deny)
      return false
    end
    if tree.sync_from_data then tree:sync_from_data(tree.data) end
    local slot, entry, definition = selected_rod(tree, payload)
    if not entry then
      publish("invalidRod")
      return false
    end
    local character = character_of(tree)
    if not character then
      publish("unavailable")
      return false
    end
    local ok, landing, zone = pcall(cast_landing, character)
    if not ok then
      print("[FishingPhase] 计算落点失败", player.UserId, tostring(landing))
      publish("unavailable")
      return false
    end
    if not landing or not zone then
      fire_cast({
        phase = "idle",
        result = { reason = landing and "invalidLanding" or "unavailable", landing = landing },
        holding = holding_info(),
      })
      return false
    end
    if remote and type(remote.CheckRECD) == "function"
      and remote:CheckRECD(player, "CastAction", GameCfg.Casting.ActionCooldownSec) then
      publish("cooldown")
      return false
    end
    local bait_ok, bait_id = consume_bait()
    if not bait_ok then
      publish("baitUnavailable")
      return false
    end
    next_cast_id = next_cast_id + 1
    session = {
      castId = next_cast_id,
      phase = "cast",
      landing = landing,
      zoneId = zone.Id,
      baitId = bait_id,
      slot = slot,
      rodLevel = definition.Level or 1,
      hookAt = now_of(tree) + GameCfg.Casting.HookDelaySec,
    }
    active_frame:set(true)
    create_line(session.castId, landing)
    publish()
    if quest and type(quest.Notify) == "function" then
      quest:Notify("CastWater", player, {
        itemId = bait_id,
        eventId = "cast:" .. tostring(player.UserId) .. ":" .. tostring(session.castId),
      })
    end
    return true
  end

  local function hook_now()
    if not session or session.phase ~= "cast" then return end
    if now_of(tree) < session.hookAt then return end
    local boss = session.baitId and GameCfg.Casting.BossBait and GameCfg.Casting.BossBait[session.baitId]
    local forced = GameCfg.Debug and GameCfg.Debug.Enabled and next_fish or nil
    local fish_id = forced and forced.fishId or boss
    if not fish_id then
      fish_id = FishCatch.Select(
        GameCfg.Casting.Zones[session.zoneId],
        session.rodLevel,
        session.baitId,
        random_fn
      )
    end
    if not fish_id then
      clear_session("noFish")
      return
    end
    next_reel_id = next_reel_id + 1
    session.phase = "hooked"
    session.fishId = fish_id
    session.forcedFishSerial = forced and forced.serial or nil
    session.mult = FishCatch.Multiplier(random_fn)
    session.reelSerial = next_reel_id
    session.reelSession = tostring(next_reel_id) .. ":" .. tostring(player.UserId)
    local receiver = RateLimit.NewReceiver({
      WindowSec = GameCfg.HighFreqInput.WindowSec,
      MaxCount = GameCfg.HighFreqInput.MaxCount,
    })
    receiver:SetSession(session.reelSession)
    reel = {
      id = session.reelSession,
      receiver = receiver,
      progress = ReelProgress.New(now_of(tree), GameCfg.ReelIn),
      lastReport = now_of(tree),
    }
    fire_reel({
      action = "started",
      session = reel.id,
      progress = reel.progress.Progress,
    })
    publish()
  end

  local function finish_reel(outcome, notify)
    if not session or not reel or session.phase ~= "hooked" then return end
    local current = session
    local current_reel = reel
    current_reel.receiver:EndSession()
    reel = nil
    if outcome == "landed" then
      current.phase = "landed"
      current.idleAt = now_of(tree) + GameCfg.Casting.LandedHoldSec
      destroy_line()
      land_fish(current)
      if notify ~= false then
        publish()
        fire_reel({ action = outcome, session = current_reel.id, progress = current_reel.progress.Progress })
      end
      return
    end
    current.phase = "unhooked"
    if notify ~= false then
      publish()
      fire_reel({ action = outcome or "unhooked", session = current_reel.id, progress = current_reel.progress.Progress })
    end
    clear_session()
  end

  function land_fish(current)
    if compendium and type(compendium.RecordLanding) == "function" then
      local ok, recorded, reason = pcall(compendium.RecordLanding, compendium, player, {
        fishId = current.fishId, mult = current.mult, reelSerial = current.reelSerial,
      })
      if not ok then
        print("[FishingPhase] 图鉴入账失败", player.UserId, tostring(recorded))
      elseif not recorded and reason ~= "replay" then
        print("[FishingPhase] 图鉴未入账", player.UserId, current.fishId, tostring(reason))
      end
    end
    local character = character_of(tree)
    local origin = character and character.Position
    local rotation = character and character.Rotation
    if origin and rotation and type(rotation.GetForward) == "function" and fish_unit
      and type(fish_unit.SpawnLanded) == "function" then
      local forward = rotation:GetForward()
      local length = forward and math.sqrt(forward.x * forward.x + forward.z * forward.z) or 0
      local dx, dz = 0, 0
      if length >= 0.01 then
        dx = GameCfg.Casting.LandingOffset * forward.x / length
        dz = GameCfg.Casting.LandingOffset * forward.z / length
      end
      local position = {
        x = origin.x + dx,
        y = origin.y + GameCfg.Casting.LandingHeight,
        z = origin.z + dz,
      }
      local ok, fish, err = pcall(fish_unit.SpawnLanded, fish_unit, player, {
        fishId = current.fishId, mult = current.mult,
      }, position)
      if not ok then
        print("[FishingPhase] 上岸生成活鱼失败", player.UserId, tostring(fish))
      elseif not fish then
        print("[FishingPhase] 上岸生成活鱼失败", player.UserId, current.fishId, tostring(err))
      end
    end
    if quest and type(quest.Notify) == "function" then
      quest:Notify("Land", player, {
        itemId = current.fishId,
        eventId = "reel:" .. tostring(current.reelSession),
      })
    end
  end

  local function accept_clicks(payload)
    if not reel or not session or session.phase ~= "hooked" then return false end
    if type(payload) ~= "table" or payload.s ~= reel.id then return false end
    if type(tree.request_action) == "function" and tree:request_action("reel") ~= true then
      return false
    end
    if tree.states and tree.states.is_paralyzed and tree.states.is_paralyzed:now() == true then
      return false
    end
    if tree.states and tree.states.life_phase and tree.states.life_phase:now() ~= "alive" then
      return false
    end
    local now = now_of(tree)
    local result = reel.receiver:Accept(now, payload)
    if result.Status ~= RateLimit.Result.Ok then return false end
    local grace_deadline = reel.progress.ZeroAt and reel.progress.ZeroAt + GameCfg.ReelIn.GraceSec
    if grace_deadline and now > grace_deadline then
      local expired = reel.progress:Advance(now)
      if expired then
        finish_reel(expired, true)
        return true
      end
    end
    local whole = math.floor(now)
    if (reel.decayedAt or math.floor(reel.progress.Time)) < whole then
      local from = reel.decayedAt or math.floor(reel.progress.Time)
      reel.decayedAt = whole
      local decayed = reel.progress:Advance(from + (whole - from))
      if decayed then
        finish_reel(decayed, true)
        return true
      end
    end
    local outcome = reel.progress:Advance(now, result.Accepted, 0)
    if outcome then
      finish_reel(outcome, true)
    else
      fire_reel({
        action = "progress",
        session = reel.id,
        progress = reel.progress.Progress,
        accepted = result.Accepted,
        q = payload.q,
      })
    end
    return true
  end

  local function close_reel(payload)
    if not reel or type(payload) ~= "table" or payload.session ~= reel.id then return false end
    reel.progress:Advance(now_of(tree))
    finish_reel(reel and reel.progress and reel.progress.Result or "unhooked", true)
    return true
  end

  local function reel_back()
    if not session then return false end
    if session.phase ~= "cast" and session.phase ~= "unhooked" then return false end
    if remote and type(remote.CheckRECD) == "function"
      and remote:CheckRECD(player, "CastAction", GameCfg.Casting.ActionCooldownSec) then
      return false
    end
    clear_session()
    return true
  end

  local function drop_held()
    if not fish_unit or type(fish_unit.Drop) ~= "function" then return false end
    if remote and type(remote.CheckRECD) == "function"
      and remote:CheckRECD(player, "CastAction", GameCfg.Casting.ActionCooldownSec) then
      return false
    end
    fish_unit:Drop(player)
    return true
  end

  local function tick()
    if cleaned or not session then return end
    if session.phase == "cast" then
      hook_now()
      return
    end
    if session.phase == "landed" and session.idleAt and now_of(tree) >= session.idleAt then
      clear_session()
      return
    end
    if not reel or session.phase ~= "hooked" then return end
    local now = now_of(tree)
    local whole = math.floor(now)
    if (reel.decayedAt or math.floor(reel.progress.Time)) < whole then
      local from = reel.decayedAt or math.floor(reel.progress.Time)
      reel.decayedAt = whole
      local outcome = reel.progress:Advance(from + (whole - from))
      if outcome then
        finish_reel(outcome, true)
        return
      end
      reel.lastReport = now
      fire_reel({
        action = "progress",
        session = reel.id,
        progress = reel.progress.Progress,
        accepted = 0,
      })
    end
    if reel and session and session.phase == "hooked" and reel.progress.ZeroAt
      and now > reel.progress.ZeroAt + GameCfg.ReelIn.GraceSec then
      local outcome = reel.progress:Advance(now)
      if outcome then finish_reel(outcome, true) end
    end
  end

  scope:subscribe(tree.clock.on_second, tick)
  scope:phase("FishingActiveFrame", active_frame, function(fs)
    fs:subscribe(tree.clock.on_frame, tick)
  end)
  if tree.states and tree.states.life_phase and type(tree.states.life_phase.subscribe) == "function" then
    scope:subscribe(tree.states.life_phase, function()
      local phase_name = tree.states.life_phase:now()
      if phase_name ~= "alive" and session and (session.phase == "hooked" or session.phase == "cast") then
        if reel then
          finish_reel("unhooked", true)
        else
          session.phase = "unhooked"
          publish()
        end
      end
    end)
  end

  scope:on_cleanup(function()
    if reel then
      reel.receiver:EndSession()
      reel = nil
    end
    local had = session
    session = nil
    next_fish = nil
    active_frame:set(false)
    destroy_line()
    if had then publish() end
    cleaned = true
  end)

  local function push_state()
    if not cleaned then publish() end
  end

  local function abort()
    if cleaned or not session then return false end
    clear_session()
    return true
  end

  local function set_next_fish(fish_id)
    if cleaned then return false end
    next_fish_serial = next_fish_serial + 1
    next_fish = { fishId = fish_id, serial = next_fish_serial }
    if session and session.phase == "hooked" then
      session.fishId = fish_id
      session.forcedFishSerial = next_fish.serial
      publish()
    end
    return true
  end

  return {
    push_state = push_state,
    abort = abort,
    set_next_fish = set_next_fish,
    cast = function(_, payload)
      if cleaned then return false end
      if type(payload) ~= "table" then return false end
      if payload.action == "Reel" then return reel_back() end
      if payload.action == "Drop" then return drop_held() end
      if payload.action == "Request" then
        publish()
        return true
      end
      if payload.action ~= "Cast" then return false end
      return begin_cast(payload)
    end,
    reel = function(_, kind, payload)
      if cleaned then return false end
      if kind == "close" then return close_reel(payload) end
      return accept_clicks(payload)
    end,
  }
end

return FishingPhase
