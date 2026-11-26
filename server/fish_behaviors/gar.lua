local GameCfg = require('common.game_cfg')
local FishBehaviorKit = require('server.fish_behaviors.kit')

local GarBehaviors = {}

local function init(fish)
    fish.bite_aim = nil
end

local function step(mgr, fish, now, pos, params)
    local species = GameCfg.Fish[fish.fish_id]
    local body = fish.carrier.body
    local aim = fish.bite_aim
    if aim then
        local valid, apos = mgr:is_target_valid(aim.Target, pos, params)
        if not valid or not FishBehaviorKit.within_bite(pos, apos, params) then
            mgr:end_bite(fish, 'cancel')
        else
            pcall(function() body.LinearVelocity = Vector3.New(0, 0, 0) end)
            if now < aim.strike_at then return end
            if FishBehaviorKit.in_head_zone(pos, fish.facing, apos, params) then
                mgr:end_bite(fish, 'bite')
                local hit = mgr.Vitals:new_hit(fish, 'fishAttack')
                mgr.Vitals:apply_hit(hit, aim.Target, species.Attack)
                print('[FishTree] 首领追咬', fish.fish_id, species.Attack, 'fish=' .. tostring(fish.Id))
            else
                mgr:end_bite(fish, 'miss')
                print('[FishTree] 首领咬空（绕后）', fish.fish_id, 'target=' .. tostring(aim.Target.UserId),
                    'fish=' .. tostring(fish.Id))
            end
        end
    end
    local target, tpos = mgr:choose_target(fish, pos, params)
    if not target then
        if mgr.ai then mgr.ai:custom(fish) end
        pcall(function() body.LinearVelocity = Vector3.New(0, 0, 0) end)
        return
    end
    if not FishBehaviorKit.within_bite(pos, tpos, params) then
        local ux, uz = FishBehaviorKit.flat_direction(tpos.x - pos.x, tpos.z - pos.z)
        local speed = mgr:speed(fish)
        mgr:face(fish, ux, uz, params)
        if mgr.ai then
            mgr.ai:Chase(fish, target.Character, speed, params.BiteRange, params.AggroRange)
            return
        end
        pcall(function() body.LinearVelocity = Vector3.New((ux or 0) * speed, 0, (uz or 0) * speed) end)
        return
    end
    pcall(function() body.LinearVelocity = Vector3.New(0, 0, 0) end)
    mgr:lock_bite(fish, target, pos, tpos, now, params)
end

GarBehaviors.gar = { init = init, step = step }

return GarBehaviors
