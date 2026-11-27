local FishBehaviorKit = require('server.fish_behaviors.kit')

local SharkBehaviors = {}

local function step(mgr, fish, now, pos, params)
    local dt = FishBehaviorKit.begin_combat_frame(fish, now)
    local move = fish.Move
    if move then
        if move.Name == 'jump' then
            mgr:advance_jump(fish, now, pos, params)
            return
        end
        if FishBehaviorKit.advance_head_move(mgr, fish, move, now, pos, params, params.SweepDamage) then return end
    end
    if now >= (fish.JumpAt or math.huge) then
        mgr:start_jump(fish, now, pos, params)
        return
    end
    if not FishBehaviorKit.engage_or_chase(mgr, fish, now, pos, params, dt,
        'sweep', params.SweepCooldownSec, '三头鲨', true) then
        return
    end
    local actual = FishBehaviorKit.read_position(fish.carrier.body)
    pos = (mgr.ai and fish.roll_from) or pos
    if not actual or not pos or (actual.x == pos.x and actual.z == pos.z) then return end
    local slot = math.floor(now)
    if fish.roll_slot ~= slot then fish.roll_slot, fish.roll_hits = slot, {} end
    for _, player in ipairs(mgr:players()) do
        local valid, cp = mgr:is_target_valid(player, actual, params)
        if valid and not fish.roll_hits[player]
            and FishBehaviorKit.segment_distance_sq(cp.x, cp.z, pos.x, pos.z, actual.x, actual.z) <= params.BiteRange^2 then
            fish.roll_hits[player] = true
            mgr:hit(fish, player, params.RollDamage, 'roll')
        end
    end
end

SharkBehaviors.shark = { init = FishBehaviorKit.init_jump_cycle, step = step }

return SharkBehaviors
