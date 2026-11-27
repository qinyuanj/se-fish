local FishBehaviorKit = require('server.fish_behaviors.kit')

local ShrimpBehaviors = {}

local function make_variant(combat)
    local function init(fish, now, params)
        fish.ActiveUntil = now + (params.ActiveSec or params.SpecialSec)
        fish.SpecialAt = now + (params.SpecialSec or 0)
        fish.combo = 0
    end

    local function step(mgr, fish, now, pos, params)
        local body = fish.carrier.body
        ---@type number
        local dt = math.max(0, now - (fish.combat_step_at or now))
        fish.combat_step_at = now
        if fish.State == 'stunned' or fish.State == mgr.State.sleeping then
            body.LinearVelocity = Vector3.New(0, 0, 0)
            if now < (fish.wake_at or math.huge) then return end
            fish.State, fish.wake_at = mgr.State.Combat, nil
            fish.ActiveUntil, fish.combo = now + (params.ActiveSec or params.SpecialSec), 0
            dt = 0
            mgr:publish_combat(fish)
        end
        if combat == 'shrimp' and now >= fish.ActiveUntil then
            mgr:stun_fish(fish, now, params)
            return
        end
        local move = fish.Move
        if combat == 'dragon' and now >= fish.SpecialAt and (not move or move.Name == 'peck') then
            fish.SpecialAt = now + params.SpecialSec
            if not mgr:start_move(fish, 'rain', pos, nil, nil, now, params.RainSec, params.RainRadius) then return end
            fish.Move.last_tick = 0
            move = fish.Move
        end
        if move then
            dt = 0
            body.LinearVelocity = Vector3.New(0, 0, 0)
            if move.Name == 'rain' then
                local tick = math.min(params.RainSec, math.floor(now - move.at))
                if tick > move.last_tick then
                    move.last_tick = tick
                    for _, player in ipairs(mgr:players()) do
                        local valid, cp = mgr:is_target_valid(player, move.Center)
                        if valid and (cp.x - move.Center.x)^2 + (cp.z - move.Center.z)^2 <= params.RainRadius^2 then
                            mgr:hit(fish, player, params.RainDamage, 'rain')
                        end
                    end
                end
                if now < move.strike_at then return end
                mgr:end_move(fish, 'rain-end')
                local target, tp = mgr:choose_target(fish, pos, params)
                mgr:start_move(fish, 'dive', pos, target, tp, now, params.DiveSec, params.DiveRadius)
                return
            elseif move.Name == 'dive' then
                ---@type number
                local progress = math.min(1, math.max(0, (now - move.at) / params.DiveSec))
                local dest = move.destination or move.Center
                body.Position = Vector3.New(move.Center.x + (dest.x - move.Center.x) * progress,
                    move.Center.y + math.sin(progress * math.pi) * params.DiveHeight,
                    move.Center.z + (dest.z - move.Center.z) * progress)
                if now < move.strike_at then return end
                mgr:end_move(fish, 'dive-end')
                for _, player in ipairs(mgr:players()) do
                    local valid, cp = mgr:is_target_valid(player, dest)
                    if valid and (cp.x - dest.x)^2 + (cp.z - dest.z)^2 <= params.DiveRadius^2 then
                        mgr:hit(fish, player, params.DiveDamage, 'dive')
                    end
                end
                mgr:stun_fish(fish, now, params)
                return
            end
            local valid, cp = mgr:is_target_valid(move.Target, pos, params)
            if not valid or not FishBehaviorKit.within_bite(pos, cp, params) then
                mgr:end_move(fish, 'cancel')
            elseif now < move.strike_at then return
            else
                mgr:end_move(fish, 'strike')
                if FishBehaviorKit.in_head_zone(pos, fish.facing, cp, params) then
                    local damage = move.Name == 'tail' and params.TailDamage
                        or (move.Name == 'peck' and params.PeckDamage or params.ClawDamage)
                    local applied = mgr:hit(fish, move.Target, damage, move.Name)
                    if applied and move.Name == 'tail' then
                        local f = fish.facing or { x = 0, z = 1 }
                        local ok, err = pcall(function()
                            move.Target.Character.Position = Vector3.New(cp.x + f.x * params.KnockHorizontal,
                                cp.y + params.KnockUp, cp.z + f.z * params.KnockHorizontal)
                        end)
                        if not ok then print('[FishTree] 尾刺击飞失败', fish.Id, tostring(err)) end
                    end
                end
                fish.combo = ((fish.combo or 0) + 1) % 3
            end
        end
        local target, tp = mgr:choose_target(fish, pos, params)
        if not target then
            if mgr.ai then mgr.ai:custom(fish) end
            body.LinearVelocity = Vector3.New(0, 0, 0)
            return
        end
        if not FishBehaviorKit.within_bite(pos, tp, params) then
            local fx, fz = FishBehaviorKit.flat_direction(tp.x - pos.x, tp.z - pos.z)
            mgr:face(fish, fx, fz, params)
            if mgr.ai then
                mgr.ai:Chase(fish, target.Character, mgr:speed(fish), params.BiteRange, params.AggroRange)
                return
            end
            local distance = math.sqrt((tp.x - pos.x)^2 + (tp.z - pos.z)^2)
            ---@type number
            local step_distance = math.min(mgr:speed(fish) * dt, math.max(0, distance - params.BiteRange))
            body.LinearVelocity = Vector3.New(0, 0, 0)
            local moved, err = pcall(function()
                body.Position = Vector3.New(pos.x + (fx or 0) * step_distance, pos.y, pos.z + (fz or 0) * step_distance)
            end)
            if not moved then print('[FishTree] 虾池追击位移失败', fish.Id, tostring(err)) end
            return
        end
        body.LinearVelocity = Vector3.New(0, 0, 0)
        local name = combat == 'dragon' and 'peck' or ((fish.combo or 0) == 2 and 'tail' or 'claw')
        mgr:start_move(fish, name, pos, target, tp, now, params.BiteCooldownSec, params.BiteRange)
    end

    return { init = init, step = step }
end

ShrimpBehaviors.shrimp = make_variant('shrimp')
ShrimpBehaviors.dragon = make_variant('dragon')

return ShrimpBehaviors
