local FishBehaviorKit = require('server.fish_behaviors.kit')

local SwordfishBehaviors = {}

local function init(fish, now, combat)
    fish.JumpAt = now + combat.JumpIntervalSec
    fish.roll_slot = -1
end

local function step(mgr, fish, now, pos, params)
    local dt = FishBehaviorKit.begin_combat_frame(fish, now)
    local move = fish.Move
    if move then
        if move.Name == 'jump' then
            mgr:advance_jump(fish, now, pos, params)
            return
        end
        if FishBehaviorKit.advance_head_move(mgr, fish, move, now, pos, params, params.SwingDamage) then return end
    end
    if now >= (fish.JumpAt or math.huge) then
        mgr:start_jump(fish, now, pos, params)
        return
    end
    FishBehaviorKit.engage_or_chase(mgr, fish, now, pos, params, dt, 'swing', params.SwingCooldownSec, '剑鱼')
end

SwordfishBehaviors.swordfish = { init = init, step = step }

return SwordfishBehaviors
