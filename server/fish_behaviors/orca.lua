local BossMoves = require('common.cfg.boss_moves')
local FishBehaviorKit = require('server.fish_behaviors.kit')

local OrcaBehaviors = {}

local function init(fish, now, combat_params, species)
    local params = BossMoves.combat_params(combat_params, BossMoves.key_of(species, fish.fish_id))
    fish.JumpAt = now + params.JumpIntervalSec
    fish.RoarAt = now + params.RoarSec
    fish.TailAt = now + params.TailSec
    fish.ClawAt = -1
end

local function step(mgr, fish, now, pos, params)
    local dt = FishBehaviorKit.begin_combat_frame(fish, now)
    local move = fish.Move
    if move then
        if move.Name == 'jump' then
            mgr:advance_jump(fish, now, pos, params)
            return
        end
        if now < move.strike_at - 1e-9 then
            local valid = mgr:is_target_valid(move.Target, pos, params)
            if not valid then mgr:end_move(fish, 'cancel') end
            return
        end
        if move.Name == 'claw' then
            mgr:end_move(fish, 'claw')
            local valid, tp = mgr:is_target_valid(move.Target, pos, params)
            if valid and FishBehaviorKit.within_bite(pos, tp, params)
                and FishBehaviorKit.in_head_zone(pos, fish.facing, tp, params) then
                mgr:hit(fish, move.Target, params.ClawDamage, 'claw')
            end
            return
        end
        if move.Name == 'roar' then
            mgr:end_move(fish, 'roar')
            local valid, tp = mgr:is_target_valid(move.Target, pos, params)
            if valid and (tp.x - pos.x)^2 + (tp.z - pos.z)^2 <= params.RoarRange * params.RoarRange then
                mgr:hit(fish, move.Target, params.RoarDamage, 'roar')
            end
            return
        end
        if move.Name == 'tail' then
            mgr:end_move(fish, 'tail')
            local facing = fish.facing or { x = 0, z = 1 }
            for _, player in ipairs(mgr:players()) do
                local valid, cp = mgr:is_target_valid(player, pos, params)
                if valid and (cp.x - pos.x)^2 + (cp.z - pos.z)^2 <= params.TailRadius * params.TailRadius then
                    local dx, dz = cp.x - pos.x, cp.z - pos.z
                    if dx * facing.x + dz * facing.z < 0 then
                        mgr:hit(fish, player, params.TailDamage, 'tail')
                    end
                end
            end
            return
        end
        return
    end
    if now >= (fish.JumpAt or math.huge) then
        mgr:start_jump(fish, now, pos, params)
        return
    end
    local target, tp = mgr:choose_target(fish, pos, params)
    if not target then
        if mgr.ai then mgr.ai:custom(fish) end
        return
    end
    if now >= (fish.RoarAt or math.huge) then
        fish.RoarAt = now + params.RoarSec
        mgr:start_move(fish, 'roar', pos, target, tp, now, params.RoarWindupSec, params.RoarRange, 'circle')
        return
    end
    if now >= (fish.TailAt or math.huge) then
        fish.TailAt = now + params.TailSec
        mgr:start_move(fish, 'tail', pos, target, tp, now, params.TailWindupSec, params.TailRadius, 'circle')
        return
    end
    if now >= (fish.ClawAt or 0) and FishBehaviorKit.within_bite(pos, tp, params) then
        fish.ClawAt = now + params.ClawCooldownSec
        mgr:start_move(fish, 'claw', pos, target, tp, now, params.ClawWindupSec, params.BiteRange)
        return
    end
    if not FishBehaviorKit.within_bite(pos, tp, params) then
        FishBehaviorKit.chase_step(mgr, fish, pos, tp, dt, params, '虎鲸')
    end
end

OrcaBehaviors.orca = {
    init = init,
    step = step,
}

return OrcaBehaviors
