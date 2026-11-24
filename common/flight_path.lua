local GameCfg = require('common.game_cfg')
local Number = require('common.number')

local M = {}

local function cfg()
    return GameCfg.Ability.Flight
end

local function isBadNumber(v)
    return not Number.IsFiniteNumber(v)
end

local function isBadPoint(p)
    return type(p) ~= 'table' or isBadNumber(p.x) or isBadNumber(p.y) or isBadNumber(p.z)
end

local function copy(p)
    return { x = p.x, y = p.y, z = p.z }
end

---@param scene? table GameCfg.Zones[i].Scene
---@param flightCfg? table GameCfg.Ability.Flight
---@return table? bounds { MinX, MaxX, MinZ, MaxZ, BottomY, TopY, GroundY, CeilingY, MaxHeight }
function M.BoundsOf(scene, flightCfg)
    if type(scene) ~= 'table' then return nil end
    local b = scene.Boundary
    if type(b) ~= 'table' then return nil end
    for _, key in ipairs({ 'MinX', 'MaxX', 'MinZ', 'MaxZ' }) do
        if isBadNumber(b[key]) then return nil end
    end
    flightCfg = flightCfg or cfg()
    local safe = scene.SafePoint
    local ground = (type(safe) == 'table' and not isBadNumber(safe.y)) and safe.y or 0
    local height = b.MaxFlightHeight
    if isBadNumber(height) or height <= 0 then height = flightCfg.MaxHeight end
    local bottom = isBadNumber(b.BottomY) and ground - 30 or b.BottomY
    local top = isBadNumber(b.TopY) and ground + 60 or b.TopY
    return {
        MinX = b.MinX, MaxX = b.MaxX, MinZ = b.MinZ, MaxZ = b.MaxZ,
        BottomY = bottom, TopY = top,
        GroundY = ground, CeilingY = math.min(ground + height, top), MaxHeight = height,
    }
end

---@param bounds table
---@param flightCfg? table
---@param profile? table 鱼种飞行档案 { CruiseHeight, DiveIntervalSec, Speed, Mode, Center, Radius, DiveDamage }
---@param start? table 起始位置
---@param now number 起始时刻（World:GetServerTime()）
function M.New(bounds, flightCfg, profile, start, now)
    flightCfg = flightCfg or cfg()
    profile = profile or {}
    start = start or { x = bounds.MinX, y = bounds.GroundY + (profile.CruiseHeight or flightCfg.CruiseHeight), z = bounds.MinZ }
    now = isBadNumber(now) and 0 or now
    return {
        Bounds = bounds, Cfg = flightCfg, Profile = profile,
        Pos = copy(start), Last = copy(start), Vel = { x = 0, y = 0, z = 0 },
        Phase = 'cruise', Target = nil,
        Center = profile.Center or { x = (bounds.MinX + bounds.MaxX) / 2, z = (bounds.MinZ + bounds.MaxZ) / 2 },
        Radius = profile.Radius or 15,
        Angle = 0,
        NextDiveAt = now + (profile.DiveIntervalSec or flightCfg.DiveIntervalSec),
        PhaseEndsAt = 0,
        Stats = { Frames = 0, Clamps = 0, NanRecoveries = 0, Drifts = 0, Dives = 0, StepTruncations = 0 },
        ClampLog = {},
    }
end

function M.SetTarget(state, target)
    state.Target = (type(target) == 'table' and not isBadPoint(target)) and copy(target) or nil
end

function M.Speed(state)
    return state.Profile.Speed or state.Cfg.Speed
end

function M.CruiseHeight(state)
    return state.Profile.CruiseHeight or state.Cfg.CruiseHeight
end

local function clampToBounds(state)
    local b, p = state.Bounds, state.Pos
    local clamped = 0
    local function clampAxis(axis, min, max)
        local v = p[axis]
        local out = v
        if v < min then out = min elseif v > max then out = max end
        if out ~= v then
            p[axis] = out
            clamped = clamped + 1
            if #state.ClampLog < 64 then
                state.ClampLog[#state.ClampLog + 1] = { axis = axis, from = v, to = out, phase = state.Phase }
            end
        end
    end
    clampAxis('x', b.MinX, b.MaxX)
    clampAxis('y', math.max(b.BottomY, b.GroundY), math.min(b.CeilingY, b.TopY))
    clampAxis('z', b.MinZ, b.MaxZ)
    state.Stats.Clamps = state.Stats.Clamps + clamped
    return clamped
end

local function driftLimit(state, dt)
    return M.Speed(state) * state.Cfg.MaxStepSec * 2 + state.Cfg.DriftTolerance
end

local function updateCruise(state, dt, now, events)
    local profile, c = state.Profile, state.Cfg
    local cruiseY = state.Bounds.GroundY + M.CruiseHeight(state)
    local speed = M.Speed(state)
    local dx, dz
    if state.Target then
        dx, dz = state.Target.x - state.Pos.x, state.Target.z - state.Pos.z
    else
        state.Angle = state.Angle + (profile.TurnRate or 0.2) * dt
        local spot = { x = state.Center.x + math.cos(state.Angle) * state.Radius,
            z = state.Center.z + math.sin(state.Angle) * state.Radius }
        dx, dz = spot.x - state.Pos.x, spot.z - state.Pos.z
    end
    local length = math.sqrt(dx * dx + dz * dz)
    if length > 1e-6 then
        state.Vel.x, state.Vel.z = dx / length * speed, dz / length * speed
    else
        state.Vel.x, state.Vel.z = 0, 0
    end
    state.Vel.y = (cruiseY - state.Pos.y) * 2
    if state.Vel.y > c.ClimbSpeed then state.Vel.y = c.ClimbSpeed end
    if state.Vel.y < -c.ClimbSpeed then state.Vel.y = -c.ClimbSpeed end
    if state.Target and now >= state.NextDiveAt then
        state.Phase = 'dive'
        state.PhaseEndsAt = now + (profile.DiveSec or c.DiveSec)
        state.NextDiveAt = now + (profile.DiveIntervalSec or c.DiveIntervalSec)
        events.dive = true
        events.diveDamage = profile.DiveDamage or c.DiveDamage
        state.Stats.Dives = state.Stats.Dives + 1
    end
    return speed
end

local function updateDive(state, dt, now, events)
    local c = state.Cfg
    local speed = state.Profile.DiveSpeed or c.DiveSpeed
    local target = state.Target
    if target then
        local dx, dy, dz = target.x - state.Pos.x, target.y - state.Pos.y, target.z - state.Pos.z
        local length = math.sqrt(dx * dx + dy * dy + dz * dz)
        if length > 1e-6 then
            state.Vel.x, state.Vel.y, state.Vel.z = dx / length * speed, dy / length * speed, dz / length * speed
        end
    else
        state.Vel.x, state.Vel.z = 0, 0
        state.Vel.y = -speed
    end
    local floor = state.Bounds.GroundY
    if now >= state.PhaseEndsAt or state.Pos.y <= floor + 0.01 then
        state.Phase = 'climb'
    end
    return speed
end

local function updateClimb(state, dt, now, events)
    local speed = M.Speed(state)
    local cruiseY = state.Bounds.GroundY + M.CruiseHeight(state)
    state.Vel.x, state.Vel.z = 0, 0
    state.Vel.y = state.Profile.ClimbSpeed or state.Cfg.ClimbSpeed
    if state.Pos.y >= cruiseY - 0.01 then
        state.Pos.y = cruiseY
        state.Phase = 'cruise'
    end
    return speed
end

local function updateLeap(state, dt, now, events)
    local c = state.Cfg
    local apex = state.Profile.LeapHeight or c.LeapHeight
    local progress = 0
    if state.PhaseEndsAt > state.PhaseStartedAt then
        progress = (now - state.PhaseStartedAt) / (state.PhaseEndsAt - state.PhaseStartedAt)
    end
    if progress >= 1 then
        state.Phase = 'cruise'
        state.NextDiveAt = now + (state.Profile.DiveIntervalSec or c.DiveIntervalSec)
        return M.Speed(state)
    end
    state.Pos.y = state.Bounds.GroundY + apex * math.sin(math.pi * progress)
    state.Vel.y = 0
    return M.Speed(state)
end

---@param state table
---@param now number World:GetServerTime()
---@param dt number 帧间隔
---@return table events { nan?, drift?, clamped?, dive?, position, phase }
function M.Step(state, now, dt)
    local events = { nan = false, drift = false, clamped = 0, dive = false }
    if isBadNumber(now) then now = state.LastAt or 0 end
    state.LastAt = now
    if isBadNumber(dt) or dt < 0 then dt = 0 end
    if dt > state.Cfg.MaxStepSec then
        dt = state.Cfg.MaxStepSec
        state.Stats.StepTruncations = state.Stats.StepTruncations + 1
        events.truncated = true
    end
    if isBadPoint(state.Pos) or isBadPoint(state.Vel) then
        state.Pos = copy(state.Last)
        state.Vel = { x = 0, y = 0, z = 0 }
        state.Stats.NanRecoveries = state.Stats.NanRecoveries + 1
        events.nan = true
        events.position = copy(state.Pos)
        events.phase = state.Phase
        return events
    end
    local dx, dy, dz = state.Pos.x - state.Last.x, state.Pos.y - state.Last.y, state.Pos.z - state.Last.z
    if math.sqrt(dx * dx + dy * dy + dz * dz) > driftLimit(state, dt) then
        state.Pos = copy(state.Last)
        state.Vel = { x = 0, y = 0, z = 0 }
        state.Stats.Drifts = state.Stats.Drifts + 1
        events.drift = true
        events.position = copy(state.Pos)
        events.phase = state.Phase
        return events
    end

    state.Stats.Frames = state.Stats.Frames + 1
    local mode = state.Profile.Mode or 'fly'
    local speed
    if mode == 'leap' then
        if state.Phase == 'cruise' and now >= state.NextDiveAt then
            state.Phase = 'leap'
            state.PhaseStartedAt = now
            state.PhaseEndsAt = now + (state.Profile.LeapSec or state.Cfg.LeapSec)
            state.NextDiveAt = now + (state.Profile.DiveIntervalSec or state.Cfg.DiveIntervalSec)
            events.dive = true
            events.diveDamage = state.Profile.DiveDamage or state.Cfg.DiveDamage
            state.Stats.Dives = state.Stats.Dives + 1
            speed = M.Speed(state)
        elseif state.Phase == 'leap' then
            speed = updateLeap(state, dt, now, events)
            dt = 0
        else
            speed = M.Speed(state)
        end
    elseif state.Phase == 'dive' then
        speed = updateDive(state, dt, now, events)
    elseif state.Phase == 'climb' then
        speed = updateClimb(state, dt, now, events)
    else
        speed = updateCruise(state, dt, now, events)
    end

    if speed then
        state.Pos.x = state.Pos.x + state.Vel.x * dt
        state.Pos.y = state.Pos.y + state.Vel.y * dt
        state.Pos.z = state.Pos.z + state.Vel.z * dt
    end

    events.clamped = clampToBounds(state)
    state.Last = copy(state.Pos)
    events.position = copy(state.Pos)
    events.phase = state.Phase
    return events
end

return M
