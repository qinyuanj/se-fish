local GameCfg = require('common.game_cfg')
local FishBehaviorKit = require('server.fish_behaviors.kit')

local GarBehaviors = {}

local function init(fish)
    fish.bite_aim = nil
end

local function write_linear_velocity(fish, body, operation, x, y, z)
    local ok, err = pcall(function() body.LinearVelocity = Vector3.New(x, y, z) end)
    if not ok then
        print('[FishTree] 鳄雀鳝' .. operation .. ' LinearVelocity 失败',
            'fish=' .. tostring(fish.Id), tostring(err))
    end
    return ok
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
            if not write_linear_velocity(fish, body, '追咬停速', 0, 0, 0) then
                mgr:end_bite(fish, 'cancel')
                return
            end
            if now < aim.strike_at then return end
            if FishBehaviorKit.in_head_zone(pos, fish.facing, apos, params) then
                mgr:end_bite(fish, 'bite')
                mgr:hit(fish, aim.Target, species.Attack, 'bite', '首领追咬')
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
        write_linear_velocity(fish, body, '无目标停速', 0, 0, 0)
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
        write_linear_velocity(fish, body, '追击', (ux or 0) * speed, 0, (uz or 0) * speed)
        return
    end
    if not write_linear_velocity(fish, body, '锁定前停速', 0, 0, 0) then return end
    mgr:lock_bite(fish, target, pos, tpos, now, params)
end

GarBehaviors.gar = { init = init, step = step }

return GarBehaviors
