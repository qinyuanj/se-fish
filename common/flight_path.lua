local GameCfg = require('common.game_cfg')
local Number = require('common.number')

local M = {}

local function cfg()
    return GameCfg.Ability.Flight
end

local function isBadNumber(v)
    return not Number.is_finite_number(v)
end

local function isBadPoint(p)
    return type(p) ~= 'table' or isBadNumber(p.x) or isBadNumber(p.y) or isBadNumber(p.z)
end

local function vec3_of(p)
    return { x = p.x, y = p.y, z = p.z }
end

---@param scene? table GameCfg.Zones[i].Scene
---@param flightCfg? table GameCfg.Ability.Flight
---@return table? bounds { MinX, MaxX, MinZ, MaxZ, BottomY, TopY, GroundY, CeilingY, MaxHeight }
function M.bounds_of(scene, flightCfg)
    if type(scene) ~= 'table' then return nil end
    local b = scene.Boundary
    if type(b) ~= 'table' then return nil end
    for _, key in ipairs({ 'MinX', 'MaxX', 'MinZ', 'MaxZ' }) do
        if isBadNumber(b[key]) then return nil end
    end
    flightCfg = flightCfg or cfg()
    local safe = scene.SafePoint
    local ground = (type(safe) == 'table' and not isBadNumber(safe.y)) and safe.y or 0
    local height = b.max_flight_height
    if isBadNumber(height) or height <= 0 then height = flightCfg.MaxHeight end
    local bottom = isBadNumber(b.bottom_y) and ground - 30 or b.bottom_y
    local top = isBadNumber(b.top_y) and ground + 60 or b.top_y
    return {
        MinX = b.MinX, MaxX = b.MaxX, MinZ = b.MinZ, MaxZ = b.MaxZ,
        bottom_y = bottom, top_y = top,
        ground_y = ground, ceiling_y = math.min(ground + height, top), MaxHeight = height,
    }
end

---@param bounds table
---@param flightCfg? table
---@param profile? table 鱼种飞行档案 { CruiseHeight, DiveIntervalSec, Speed, Mode, Center, Radius, DiveDamage }
---@param start? table 起始位置
---@param now number 起始时刻（World:GetServerTime()）
function M.new(bounds, flightCfg, profile, start, now)
    flightCfg = flightCfg or cfg()
    profile = profile or {}
    start = start or { x = bounds.MinX, y = bounds.ground_y + (profile.CruiseHeight or flightCfg.CruiseHeight), z = bounds.MinZ }
    now = isBadNumber(now) and 0 or now
    return {
        bounds = bounds, cfg = flightCfg, profile = profile,
        pos = vec3_of(start), last = vec3_of(start), vel = { x = 0, y = 0, z = 0 },
        Phase = 'cruise', Target = nil,
        Center = profile.Center or { x = (bounds.MinX + bounds.MaxX) / 2, z = (bounds.MinZ + bounds.MaxZ) / 2 },
        Radius = profile.Radius or 15,
        Angle = 0,
        next_dive_at = now + (profile.DiveIntervalSec or flightCfg.DiveIntervalSec),
        phase_ends_at = 0,
        stats = { frames = 0, clamps = 0, nan_recoveries = 0, drifts = 0, dives = 0, step_truncations = 0 },
        clamp_log = {},
    }
end

function M.set_target(state, target)
    state.Target = (type(target) == 'table' and not isBadPoint(target)) and vec3_of(target) or nil
end

function M.speed(state)
    return state.profile.Speed or state.cfg.Speed
end

function M.CruiseHeight(state)
    return state.profile.CruiseHeight or state.cfg.CruiseHeight
end

local function clampToBounds(state)
    local b, p = state.bounds, state.pos
    local clamped = 0
    local function clampAxis(axis, min, max)
        local v = p[axis]
        local out = v
        if v < min then out = min elseif v > max then out = max end
        if out ~= v then
            p[axis] = out
            clamped = clamped + 1
            if #state.clamp_log < 64 then
                state.clamp_log[#state.clamp_log + 1] = { axis = axis, from = v, to = out, phase = state.Phase }
            end
        end
    end
    clampAxis('x', b.MinX, b.MaxX)
    clampAxis('y', math.max(b.bottom_y, b.ground_y), math.min(b.ceiling_y, b.top_y))
    clampAxis('z', b.MinZ, b.MaxZ)
    state.stats.clamps = state.stats.clamps + clamped
    return clamped
end

local function driftLimit(state, dt)
    return M.speed(state) * state.cfg.MaxStepSec * 2 + state.cfg.DriftTolerance
end

local function updateCruise(state, dt, now, events)
    local profile, c = state.profile, state.cfg
    local cruiseY = state.bounds.ground_y + M.CruiseHeight(state)
    local speed = M.speed(state)
    local dx, dz
    if state.Target then
        dx, dz = state.Target.x - state.pos.x, state.Target.z - state.pos.z
    else
        state.Angle = state.Angle + (profile.TurnRate or 0.2) * dt
        local spot = { x = state.Center.x + math.cos(state.Angle) * state.Radius,
            z = state.Center.z + math.sin(state.Angle) * state.Radius }
        dx, dz = spot.x - state.pos.x, spot.z - state.pos.z
    end
    local length = math.sqrt(dx * dx + dz * dz)
    if length > 1e-6 then
        state.vel.x, state.vel.z = dx / length * speed, dz / length * speed
    else
        state.vel.x, state.vel.z = 0, 0
    end
    state.vel.y = (cruiseY - state.pos.y) * 2
    if state.vel.y > c.ClimbSpeed then state.vel.y = c.ClimbSpeed end
    if state.vel.y < -c.ClimbSpeed then state.vel.y = -c.ClimbSpeed end
    if state.Target and now >= state.next_dive_at then
        state.Phase = 'dive'
        state.phase_ends_at = now + (profile.DiveSec or c.DiveSec)
        state.next_dive_at = now + (profile.DiveIntervalSec or c.DiveIntervalSec)
        events.dive = true
        events.diveDamage = profile.DiveDamage or c.DiveDamage
        state.stats.dives = state.stats.dives + 1
    end
    return speed
end

local function updateDive(state, dt, now, events)
    local c = state.cfg
    local speed = state.profile.DiveSpeed or c.DiveSpeed
    local target = state.Target
    if target then
        local dx, dy, dz = target.x - state.pos.x, target.y - state.pos.y, target.z - state.pos.z
        local length = math.sqrt(dx * dx + dy * dy + dz * dz)
        if length > 1e-6 then
            state.vel.x, state.vel.y, state.vel.z = dx / length * speed, dy / length * speed, dz / length * speed
        end
    else
        state.vel.x, state.vel.z = 0, 0
        state.vel.y = -speed
    end
    local floor = state.bounds.ground_y
    if now >= state.phase_ends_at or state.pos.y <= floor + 0.01 then
        state.Phase = 'climb'
    end
    return speed
end

local function updateClimb(state, dt, now, events)
    local speed = M.speed(state)
    local cruiseY = state.bounds.ground_y + M.CruiseHeight(state)
    state.vel.x, state.vel.z = 0, 0
    state.vel.y = state.profile.ClimbSpeed or state.cfg.ClimbSpeed
    if state.pos.y >= cruiseY - 0.01 then
        state.pos.y = cruiseY
        state.Phase = 'cruise'
    end
    return speed
end

local function updateLeap(state, dt, now, events)
    local c = state.cfg
    local apex = state.profile.LeapHeight or c.LeapHeight
    local progress = 0
    if state.phase_ends_at > state.phase_started_at then
        progress = (now - state.phase_started_at) / (state.phase_ends_at - state.phase_started_at)
    end
    if progress >= 1 then
        state.Phase = 'cruise'
        state.next_dive_at = now + (state.profile.DiveIntervalSec or c.DiveIntervalSec)
        return M.speed(state)
    end
    state.pos.y = state.bounds.ground_y + apex * math.sin(math.pi * progress)
    state.vel.y = 0
    return M.speed(state)
end

---@param state table
---@param now number World:GetServerTime()
---@param dt number 帧间隔
---@return table events { nan?, drift?, clamped?, dive?, position, phase }
function M.step(state, now, dt)
    local events = { nan = false, drift = false, clamped = 0, dive = false }
    if isBadNumber(now) then now = state.last_at or 0 end
    state.last_at = now
    if isBadNumber(dt) or dt < 0 then dt = 0 end
    if dt > state.cfg.MaxStepSec then
        dt = state.cfg.MaxStepSec
        state.stats.step_truncations = state.stats.step_truncations + 1
        events.truncated = true
    end
    if isBadPoint(state.pos) or isBadPoint(state.vel) then
        state.pos = vec3_of(state.last)
        state.vel = { x = 0, y = 0, z = 0 }
        state.stats.nan_recoveries = state.stats.nan_recoveries + 1
        events.nan = true
        events.position = vec3_of(state.pos)
        events.phase = state.Phase
        return events
    end
    local dx, dy, dz = state.pos.x - state.last.x, state.pos.y - state.last.y, state.pos.z - state.last.z
    if math.sqrt(dx * dx + dy * dy + dz * dz) > driftLimit(state, dt) then
        state.pos = vec3_of(state.last)
        state.vel = { x = 0, y = 0, z = 0 }
        state.stats.drifts = state.stats.drifts + 1
        events.drift = true
        events.position = vec3_of(state.pos)
        events.phase = state.Phase
        return events
    end

    state.stats.frames = state.stats.frames + 1
    local mode = state.profile.Mode or 'fly'
    local speed
    if mode == 'leap' then
        if state.Phase == 'cruise' and now >= state.next_dive_at then
            state.Phase = 'leap'
            state.phase_started_at = now
            state.phase_ends_at = now + (state.profile.LeapSec or state.cfg.LeapSec)
            state.next_dive_at = now + (state.profile.DiveIntervalSec or state.cfg.DiveIntervalSec)
            events.dive = true
            events.diveDamage = state.profile.DiveDamage or state.cfg.DiveDamage
            state.stats.dives = state.stats.dives + 1
            speed = M.speed(state)
        elseif state.Phase == 'leap' then
            speed = updateLeap(state, dt, now, events)
            dt = 0
        else
            speed = M.speed(state)
        end
    elseif state.Phase == 'dive' then
        speed = updateDive(state, dt, now, events)
    elseif state.Phase == 'climb' then
        speed = updateClimb(state, dt, now, events)
    else
        speed = updateCruise(state, dt, now, events)
    end

    if speed then
        state.pos.x = state.pos.x + state.vel.x * dt
        state.pos.y = state.pos.y + state.vel.y * dt
        state.pos.z = state.pos.z + state.vel.z * dt
    end

    events.clamped = clampToBounds(state)
    state.last = vec3_of(state.pos)
    events.position = vec3_of(state.pos)
    events.phase = state.Phase
    return events
end

return M
