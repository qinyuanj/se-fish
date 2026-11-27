local GameCfg = require('common.game_cfg')
local Number = require('common.number')
local BossMoves = require('common.cfg.boss_moves')

local FishBehaviorKit = {}

function FishBehaviorKit.distance_sq(pos, cp)
    if not pos or not cp then return math.huge end
    return (cp.x - pos.x) * (cp.x - pos.x) + (cp.z - pos.z) * (cp.z - pos.z)
end

function FishBehaviorKit.read_position(unit)
    local ok, pos = pcall(function() return unit.Position end)
    if ok and pos and Number.is_finite_number(pos.x) and Number.is_finite_number(pos.y)
        and Number.is_finite_number(pos.z) then
        return pos
    end
end

function FishBehaviorKit.flat_direction(x, z)
    local length = math.sqrt(x * x + z * z)
    if length < 0.01 then return nil end
    return x / length, z / length
end

function FishBehaviorKit.within_bite(pos, tpos, params)
    local dx, dz = tpos.x - pos.x, tpos.z - pos.z
    return dx * dx + dz * dz <= params.BiteRange * params.BiteRange
end

function FishBehaviorKit.in_head_zone(pos, facing, tpos, params)
    local dx, dz = tpos.x - pos.x, tpos.z - pos.z
    local d2 = dx * dx + dz * dz
    if d2 > params.BiteRange * params.BiteRange then return false end
    if d2 < 1e-4 or not facing then return true end
    local limit = math.cos(math.rad(params.HeadHalfAngleDeg or 180))
    return (dx * facing.x + dz * facing.z) / math.sqrt(d2) > limit + 1e-9
end

function FishBehaviorKit.segment_distance_sq(px, pz, ax, az, bx, bz)
    local dx, dz = bx - ax, bz - az
    local len_sq = dx * dx + dz * dz
    if len_sq <= 1e-12 then
        local ex, ez = px - ax, pz - az
        return ex * ex + ez * ez
    end
    local t = ((px - ax) * dx + (pz - az) * dz) / len_sq
    if t < 0 then t = 0 elseif t > 1 then t = 1 end
    local ex, ez = px - (ax + t * dx), pz - (az + t * dz)
    return ex * ex + ez * ez
end

function FishBehaviorKit.begin_combat_frame(fish, now)
    fish.carrier.body.LinearVelocity = Vector3.New(0, 0, 0)
    ---@type number
    local dt = math.max(0, now - (fish.combat_step_at or now))
    fish.combat_step_at = now
    return dt
end

function FishBehaviorKit.chase_step(mgr, fish, pos, tpos, dt, params, label, skip_idle, plain_id)
    if mgr.ai then
        local target = mgr:choose_target(fish, pos, params)
        if not target then mgr.ai:custom(fish); return false end
        mgr:face(fish, FishBehaviorKit.flat_direction(tpos.x - pos.x, tpos.z - pos.z))
        local previous = fish.official_roll_from
        fish.official_roll_from = { x = pos.x, y = pos.y, z = pos.z }
        fish.roll_from = previous
        mgr.ai:Chase(fish, target.Character, mgr:speed(fish), params.BiteRange, params.AggroRange)
        return previous ~= nil and (previous.x ~= pos.x or previous.z ~= pos.z)
    end
    local body = fish.carrier.body
    local fx, fz = FishBehaviorKit.flat_direction(tpos.x - pos.x, tpos.z - pos.z)
    mgr:face(fish, fx, fz, params)
    local distance = math.sqrt((tpos.x - pos.x)^2 + (tpos.z - pos.z)^2)
    local step = math.min(mgr:speed(fish) * dt, math.max(0, distance - params.BiteRange))
    if skip_idle and step <= 0 then return false end
    local moved, err = pcall(function()
        body.Position = Vector3.New(pos.x + (fx or 0) * step, pos.y, pos.z + (fz or 0) * step)
    end)
    if not moved then
        print('[FishTree] ' .. label .. '追击位移失败',
            plain_id and fish.Id or ('fish=' .. tostring(fish.Id)), tostring(err))
    end
    return moved
end

function FishBehaviorKit.advance_head_move(mgr, fish, move, now, pos, params, damage)
    local valid, tp = mgr:is_target_valid(move.Target, pos, params)
    if not valid or not FishBehaviorKit.within_bite(pos, tp, params) then
        mgr:end_move(fish, 'cancel')
        return false
    end
    if now < move.strike_at - 1e-9 then return true end
    mgr:end_move(fish, move.Name)
    if FishBehaviorKit.in_head_zone(pos, fish.facing, tp, params) then
        mgr:hit(fish, move.Target, damage, move.Name)
    end
    return true
end

function FishBehaviorKit.engage_or_chase(mgr, fish, now, pos, params, dt, name, windup, label, skip_idle)
    local target, tpos = mgr:choose_target(fish, pos, params)
    if not target then
        if mgr.ai then mgr.ai:custom(fish) end
        return false
    end
    if FishBehaviorKit.within_bite(pos, tpos, params) then
        mgr:start_move(fish, name, pos, target, tpos, now, windup, params.BiteRange)
        return false
    end
    return FishBehaviorKit.chase_step(mgr, fish, pos, tpos, dt, params, label, skip_idle)
end

function FishBehaviorKit.boss_windup(fish, move)
    local row = BossMoves.get(BossMoves.key_of(GameCfg.Fish[fish.fish_id], fish.fish_id), move) or {}
    local warning = row.Warning
    local windup = type(warning) == 'table' and warning.WindupSec or nil
    return type(windup) == 'number' and windup or 0
end

return FishBehaviorKit
