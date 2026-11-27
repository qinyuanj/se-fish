
local EngineRead = require("common.engine_read")
local GameCfg = require("common.game_cfg")
local FishCatch = require("common.fish_catch")
local MathWaterJudge = require("common.math_water_judge")
local Number = require("common.number")
local RateLimit = require("common.rate_limit")
local ReelProgress = require("common.reel_progress")
local State = require("common.packages.spoke.api").State

local FishingPhase = {}
-- 钓竿阶段行为表：拆分前都是 FishingPhase.mount 体内的闭包，方法名、参数顺序与返回值不变，
-- 调用方照旧 handle:method(...)。句柄持阶段状态（session / active_reel / 计数器等），
-- 依赖统一从 handle.fishing_env 读取，字段名沿用拆分前的局部变量名。
local FishingBehavior = {}

local function finite(value)
  return Number.is_finite_number(value)
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
    if MathWaterJudge.in_zone(candidate, { x = x, y = candidate.SurfaceY, z = z }) then
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

-- ===== 钓线与下发 =====

function FishingBehavior.create_line(self, cast_id, landing)
  local env = self.fishing_env
  local maker = env.create_unit
  if type(maker) ~= "function" and env.world and type(env.world.CreateUnit) == "function" then
    maker = function(kind, props) return env.world:CreateUnit(kind, props) end
  end
  if self.line_unit or type(maker) ~= "function" or not landing then return end
  local ok, unit = pcall(maker, "LinkEffectUnit", {
    Name = "CastLine_" .. tostring(cast_id),
    EffectId = GameCfg.Casting.LineEffect,
    Position = Vector3.New(landing.x, landing.y, landing.z),
  })
  if ok and unit then
    self.line_unit = unit
  else
    print("[FishingPhase] 创建钓线失败", env.player.UserId, tostring(unit))
  end
end

function FishingBehavior.destroy_line(self)
  local env = self.fishing_env
  local unit = self.line_unit
  self.line_unit = nil
  if unit and type(unit.Destroy) == "function" then
    local ok, err = pcall(unit.Destroy, unit)
    if not ok then print("[FishingPhase] 销毁钓线失败", env.player.UserId, tostring(err)) end
  end
end

-- 下行推送统一走 EngineRead.fire_client（取 RE 事件 + pcall），两个通道只差频道名。
local function fire_on(channel, tag)
  return function(self, payload)
    local env = self.fishing_env
    EngineRead.fire_client(env.remote, channel, env.player, payload, tag)
  end
end

FishingBehavior.fire_cast = fire_on("CastState", "FishingBehavior.fire_cast")
FishingBehavior.fire_reel = fire_on("ReelInRE", "FishingBehavior.fire_reel")

function FishingBehavior.holding_info(self)
  local env = self.fishing_env
  local fish_unit = env.fish_unit
  if fish_unit and type(fish_unit.held_info) == "function" then
    local ok, info = pcall(fish_unit.held_info, fish_unit, env.player)
    if ok then return copy_holding(info) end
  end
  return nil
end

function FishingBehavior.publish(self, reason)
  if self.cleaned then return end
  local session = self.session
  if not session then
    self:fire_cast({ phase = "idle", holding = self:holding_info(), result = reason and { reason = reason } or nil })
    return
  end
  local species = session.fishId and GameCfg.Fish[session.fishId]
  self:fire_cast({
    phase = session.phase,
    castId = session.castId,
    landing = session.landing,
    zoneId = session.zoneId,
    fishId = session.fishId,
    catchSource = species and species.CatchSource or "water",
    hookPosition = hook_position(session),
    mult = session.mult,
    reelSession = session.reelSession,
    holding = self:holding_info(),
    result = reason and { reason = reason } or nil,
  })
end

-- ===== 抛竿与收线 =====

function FishingBehavior.clear_session(self, reason, notify)
  self.session = nil
  self.active_reel = nil
  self.active_frame:set(false)
  self:destroy_line()
  if notify ~= false then self:publish(reason) end
end

function FishingBehavior.consume_bait(self)
  local env = self.fishing_env
  local tree = env.tree
  local data = tree.data
  if type(data) ~= "table" or type(data.ConsumeSelectedBait) ~= "function" then
    return false, nil
  end
  local ok, success, bait_id = pcall(data.ConsumeSelectedBait, data)
  if not ok then
    print("[FishingPhase] 消耗鱼饵失败", env.player.UserId, tostring(success))
    return false, nil
  end
  if tree.sync_from_data then tree:sync_from_data(data) end
  return success == true, bait_id
end

function FishingBehavior.can_cast(self)
  local env = self.fishing_env
  local tree = env.tree
  local fish_unit = env.fish_unit
  if tree.memos and tree.memos.can_act and tree.memos.can_act:now() ~= true then
    return false, "cannotAct"
  end
  if fish_unit and type(fish_unit.can_cast) == "function" and fish_unit:can_cast(env.player) ~= true then
    return false, "holding"
  end
  return true
end

function FishingBehavior.begin_cast(self, payload)
  local env = self.fishing_env
  local tree = env.tree
  local remote = env.remote
  if self.session then
    self:publish()
    self:fire_cast({ phase = self.session.phase, castId = self.session.castId, result = { reason = "alreadyCasting" } })
    return false
  end
  local allowed, deny = self:can_cast()
  if not allowed then
    self:publish(deny)
    return false
  end
  if tree.sync_from_data then tree:sync_from_data(tree.data) end
  local slot, entry, definition = selected_rod(tree, payload)
  if not entry then
    self:publish("invalidRod")
    return false
  end
  local character = character_of(tree)
  if not character then
    self:publish("unavailable")
    return false
  end
  local ok, landing, zone = pcall(cast_landing, character)
  if not ok then
    print("[FishingPhase] 计算落点失败", env.player.UserId, tostring(landing))
    self:publish("unavailable")
    return false
  end
  if not landing or not zone then
    self:fire_cast({
      phase = "idle",
      result = { reason = landing and "invalidLanding" or "unavailable", landing = landing },
      holding = self:holding_info(),
    })
    return false
  end
  if remote and type(remote.check_recd) == "function"
    and remote:check_recd(env.player, "CastAction", GameCfg.Casting.ActionCooldownSec) then
    self:publish("cooldown")
    return false
  end
  local bait_ok, bait_id = self:consume_bait()
  if not bait_ok then
    self:publish("baitUnavailable")
    return false
  end
  self.next_cast_id = self.next_cast_id + 1
  self.session = {
    castId = self.next_cast_id,
    phase = "cast",
    landing = landing,
    zoneId = zone.Id,
    baitId = bait_id,
    slot = slot,
    rodLevel = definition.Level or 1,
    hookAt = now_of(tree) + GameCfg.Casting.HookDelaySec,
  }
  self.active_frame:set(true)
  self:create_line(self.session.castId, landing)
  self:publish()
  local quest = env.quest
  if quest and type(quest.notify) == "function" then
    quest:notify("CastWater", env.player, {
      itemId = bait_id,
      eventId = "cast:" .. tostring(env.player.UserId) .. ":" .. tostring(self.session.castId),
    })
  end
  return true
end

function FishingBehavior.hook_now(self)
  local env = self.fishing_env
  local tree = env.tree
  local session = self.session
  if not session or session.phase ~= "cast" then return end
  if now_of(tree) < session.hookAt then return end
  local boss = session.baitId and GameCfg.Casting.BossBait and GameCfg.Casting.BossBait[session.baitId]
  local forced = GameCfg.Debug and GameCfg.Debug.Enabled and self.next_fish or nil
  local fish_id = forced and forced.fishId or boss
  if not fish_id then
    fish_id = FishCatch.select(
      GameCfg.Casting.Zones[session.zoneId],
      session.rodLevel,
      session.baitId,
      env.random_fn
    )
  end
  if not fish_id then
    self:clear_session("noFish")
    return
  end
  self.next_reel_id = self.next_reel_id + 1
  session.phase = "hooked"
  session.fishId = fish_id
  session.forcedFishSerial = forced and forced.serial or nil
  session.mult = FishCatch.Multiplier(env.random_fn)
  session.reelSerial = self.next_reel_id
  session.reelSession = tostring(self.next_reel_id) .. ":" .. tostring(env.player.UserId)
  local receiver = RateLimit.new_receiver({
    WindowSec = GameCfg.HighFreqInput.WindowSec,
    MaxCount = GameCfg.HighFreqInput.MaxCount,
  })
  receiver:set_session(session.reelSession)
  self.active_reel = {
    id = session.reelSession,
    receiver = receiver,
    progress = ReelProgress.new(now_of(tree), GameCfg.ReelIn),
    lastReport = now_of(tree),
  }
  self:fire_reel({
    action = "started",
    session = self.active_reel.id,
    progress = self.active_reel.progress.Progress,
  })
  self:publish()
end

function FishingBehavior.finish_reel(self, outcome, notify)
  local env = self.fishing_env
  local tree = env.tree
  if not self.session or not self.active_reel or self.session.phase ~= "hooked" then return end
  local current = self.session
  local current_reel = self.active_reel
  current_reel.receiver:end_session()
  self.active_reel = nil
  if outcome == "landed" then
    current.phase = "landed"
    current.idleAt = now_of(tree) + GameCfg.Casting.LandedHoldSec
    self:destroy_line()
    self:land_fish(current)
    if notify ~= false then
      self:publish()
      self:fire_reel({ action = outcome, session = current_reel.id, progress = current_reel.progress.Progress })
    end
    return
  end
  current.phase = "unhooked"
  if notify ~= false then
    self:publish()
    self:fire_reel({ action = outcome or "unhooked", session = current_reel.id, progress = current_reel.progress.Progress })
  end
  self:clear_session()
end

function FishingBehavior.land_fish(self, current)
  local env = self.fishing_env
  local tree = env.tree
  local player = env.player
  local compendium = env.compendium
  local fish_unit = env.fish_unit
  if compendium and type(compendium.record_landing) == "function" then
    local ok, recorded, reason = pcall(compendium.record_landing, compendium, player, {
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
    and type(fish_unit.spawn_landed) == "function" then
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
    local ok, fish, err = pcall(fish_unit.spawn_landed, fish_unit, player, {
      fishId = current.fishId, mult = current.mult,
    }, position)
    if not ok then
      print("[FishingPhase] 上岸生成活鱼失败", player.UserId, tostring(fish))
    elseif not fish then
      print("[FishingPhase] 上岸生成活鱼失败", player.UserId, current.fishId, tostring(err))
    end
  end
  local quest = env.quest
  if quest and type(quest.notify) == "function" then
    quest:notify("Land", player, {
      itemId = current.fishId,
      eventId = "reel:" .. tostring(current.reelSession),
    })
  end
end

function FishingBehavior.advance_whole_second_decay(self, active_reel, now)
  local whole = math.floor(now)
  local from = active_reel.decayedAt or math.floor(active_reel.progress.Time)
  if from >= whole then return false, nil end
  active_reel.decayedAt = whole
  local decay_outcome = active_reel.progress:advance(whole)
  if decay_outcome then
    self:finish_reel(decay_outcome, true)
    return true, decay_outcome
  end
  return true, nil
end

function FishingBehavior.accept_clicks(self, payload)
  local env = self.fishing_env
  local tree = env.tree
  local reel = self.active_reel
  if not reel or not self.session or self.session.phase ~= "hooked" then return false end
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
  local result = reel.receiver:accept(now, payload)
  if result.Status ~= RateLimit.Result.Ok then return false end
  local grace_deadline = reel.progress.zero_at and reel.progress.zero_at + GameCfg.ReelIn.GraceSec
  if grace_deadline and now > grace_deadline then
    local expired = reel.progress:advance(now)
    if expired then
      self:finish_reel(expired, true)
      return true
    end
  end
  local _, decayed = self:advance_whole_second_decay(reel, now)
  if decayed then return true end
  local outcome = reel.progress:advance(now, result.accepted, 0)
  if outcome then
    self:finish_reel(outcome, true)
  else
    self:fire_reel({
      action = "progress",
      session = reel.id,
      progress = reel.progress.Progress,
      accepted = result.accepted,
      q = payload.q,
    })
  end
  return true
end

function FishingBehavior.close_reel(self, payload)
  local env = self.fishing_env
  local reel = self.active_reel
  if not reel or type(payload) ~= "table" or payload.session ~= reel.id then return false end
  reel.progress:advance(now_of(env.tree))
  self:finish_reel(reel and reel.progress and reel.progress.Result or "unhooked", true)
  return true
end

function FishingBehavior.reel_back(self)
  local env = self.fishing_env
  local session = self.session
  if not session then return false end
  if session.phase ~= "cast" and session.phase ~= "unhooked" then return false end
  if env.remote and type(env.remote.check_recd) == "function"
    and env.remote:check_recd(env.player, "CastAction", GameCfg.Casting.ActionCooldownSec) then
    return false
  end
  self:clear_session()
  return true
end

function FishingBehavior.drop_held(self)
  local env = self.fishing_env
  local fish_unit = env.fish_unit
  if not fish_unit or type(fish_unit.drop) ~= "function" then return false end
  if env.remote and type(env.remote.check_recd) == "function"
    and env.remote:check_recd(env.player, "CastAction", GameCfg.Casting.ActionCooldownSec) then
    return false
  end
  fish_unit:drop(env.player)
  return true
end

-- ===== 帧驱动与生命周期 =====

function FishingBehavior.tick(self)
  local env = self.fishing_env
  local tree = env.tree
  if self.cleaned or not self.session then return end
  if self.session.phase == "cast" then
    self:hook_now()
    return
  end
  if self.session.phase == "landed" and self.session.idleAt and now_of(tree) >= self.session.idleAt then
    self:clear_session()
    return
  end
  if not self.active_reel or self.session.phase ~= "hooked" then return end
  local now = now_of(tree)
  local stepped, decay_outcome = self:advance_whole_second_decay(self.active_reel, now)
  if decay_outcome then return end
  if stepped then
    self.active_reel.lastReport = now
    self:fire_reel({
      action = "progress",
      session = self.active_reel.id,
      progress = self.active_reel.progress.Progress,
      accepted = 0,
    })
  end

  if self.active_reel and self.session and self.session.phase == "hooked" and self.active_reel.progress.zero_at
    and now > self.active_reel.progress.zero_at + GameCfg.ReelIn.GraceSec then
    local outcome = self.active_reel.progress:advance(now)
    if outcome then self:finish_reel(outcome, true) end
  end
end

function FishingBehavior.on_life_phase(self)
  local env = self.fishing_env
  local phase_name = env.tree.states.life_phase:now()
  if phase_name ~= "alive" and self.session and (self.session.phase == "hooked" or self.session.phase == "cast") then
    if self.active_reel then
      self:finish_reel("unhooked", true)
    else
      self.session.phase = "unhooked"
      self:publish()
    end
  end
end

function FishingBehavior.cleanup(self)
  if self.active_reel then
    self.active_reel.receiver:end_session()
    self.active_reel = nil
  end
  local had = self.session
  self.session = nil
  self.next_fish = nil
  self.active_frame:set(false)
  self:destroy_line()
  if had then self:publish() end
  self.cleaned = true
end

-- ===== 对外入口 =====

function FishingBehavior.push_state(self)
  if not self.cleaned then self:publish() end
end

function FishingBehavior.abort(self)
  if self.cleaned or not self.session then return false end
  self:clear_session()
  return true
end

function FishingBehavior.set_next_fish(self, fish_id)
  if self.cleaned then return false end
  self.next_fish_serial = self.next_fish_serial + 1
  self.next_fish = { fishId = fish_id, serial = self.next_fish_serial }
  if self.session and self.session.phase == "hooked" then
    self.session.fishId = fish_id
    self.session.forcedFishSerial = self.next_fish.serial
    self:publish()
  end
  return true
end

function FishingBehavior.cast(self, payload)
  if self.cleaned then return false end
  if type(payload) ~= "table" then return false end
  if payload.action == "Reel" then return self:reel_back() end
  if payload.action == "Drop" then return self:drop_held() end
  if payload.action == "Request" then
    self:publish()
    return true
  end
  if payload.action ~= "Cast" then return false end
  return self:begin_cast(payload)
end

function FishingBehavior.reel(self, kind, payload)
  if self.cleaned then return false end
  if kind == "close" then return self:close_reel(payload) end
  return self:accept_clicks(payload)
end

-- Spoke 作用域接线：注册顺序与拆分前 mount 内的 subscribe / phase / on_cleanup 一致。
local function wire_scope(self)
  local env = self.fishing_env
  local tree, scope = env.tree, env.scope
  scope:subscribe(tree.clock.on_second, function() self:tick() end)
  scope:phase("FishingActiveFrame", self.active_frame, function(fs)
    fs:subscribe(tree.clock.on_frame, function() self:tick() end)
  end)
  if tree.states and tree.states.life_phase and type(tree.states.life_phase.subscribe) == "function" then
    scope:subscribe(tree.states.life_phase, function() self:on_life_phase() end)
  end
  scope:on_cleanup(function() self:cleanup() end)
end

--- 组装钓竿阶段句柄：状态字段留在句柄上，依赖装进 handle.fishing_env，方法由 FishingBehavior 提供。
--- 对外方法名、参数顺序与返回值沿用拆分前的返回表，调用方照旧 handle:method(...)。
function FishingPhase.mount(scope, tree, opts)
  opts = type(opts) == "table" and opts or {}
  local handle = {
    line_unit = nil,
    session = nil,
    active_reel = nil,
    next_cast_id = 0,
    next_reel_id = 0,
    next_fish = nil,
    next_fish_serial = 0,
    cleaned = false,
    active_frame = State.new("FishingPhase.active_frame", false),
  }
  handle.fishing_env = {
    scope = scope,
    tree = tree,
    player = tree.player,
    remote = opts.remote,
    fish_unit = opts.fish_unit,
    compendium = opts.compendium,
    quest = opts.quest,
    random_fn = opts.random or math.random,
    world = opts.world,
    create_unit = opts.create_unit,
  }
  for name, method in pairs(FishingBehavior) do
    handle[name] = method
  end
  wire_scope(handle)
  return handle
end

return FishingPhase
