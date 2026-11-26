local GameCfg = require('common.game_cfg')
local FishBehaviorKit = require('server.fish_behaviors.kit')

local CrabBehaviors = {}

local function reset_rhythm(fish, now, params)
    if params.ActiveSec then fish.ActiveUntil = now + params.ActiveSec end
    fish.JabAt = -1
    fish.PinchAt = -1
    fish.SpecialAt = now + (params.SpinSec or 0)
    fish.ChargeAt = now + (params.ChargeSec or 0)
end

local function init(fish, now, params)
    reset_rhythm(fish, now, params)
end

local function step_king_crab(mgr, fish, now, pos, params)
    local body = fish.carrier.body
    if fish.State == 'stunned' then
        body.LinearVelocity = Vector3.New(0, 0, 0)
        if now < (fish.wake_at or math.huge) then return end
        fish.State, fish.wake_at = mgr.State.Combat, nil
        -- 唤醒使用原始配置；普通 step 继续使用宿主合并 BossMoves 后的参数。
        local original_params = GameCfg.FishCombat and GameCfg.FishCombat.kingCrab
        ---@cast original_params table?
        if original_params then reset_rhythm(fish, now, original_params) end
        mgr:publish_combat(fish)
    end
    if now >= (fish.ActiveUntil or math.huge) then
        mgr:stun_fish(fish, now, params)
        return
    end

    local dt = FishBehaviorKit.begin_combat_frame(fish, now)
    local move = fish.Move
    if move then
        if move.Name ~= 'jab' then return end
        local elapsed = now - move.at
        local windup = FishBehaviorKit.boss_windup(fish, 'jab')
        ---@type number
        local slot = elapsed <= windup and -1 or math.min(params.JabsPerSide * 2 - 1,
            math.floor((elapsed - windup) / params.JabStepSec + 1e-9) - 1)
        if slot > (move.last_slot or -1) then
            move.last_slot = slot
            local target, tp = mgr:is_target_valid(move.Target, pos, params)
            if target and FishBehaviorKit.within_bite(pos, tp, params)
                and FishBehaviorKit.in_head_zone(pos, fish.facing, tp, params) then
                mgr:hit(fish, move.Target, params.JabDamage, 'jab')
            end
        end
        if now < move.strike_at - 1e-9 then return end
        mgr:end_move(fish, 'jab-end')
        return
    end
    local target, tp = mgr:choose_target(fish, pos, params)
    if not target then
        if mgr.ai then mgr.ai:custom(fish) end
        return
    end
    if now < (fish.JabAt or 0) then return end
    if not FishBehaviorKit.within_bite(pos, tp, params) then
        FishBehaviorKit.chase_step(mgr, fish, pos, tp, dt, params, '帝王蟹', nil, true)
        return
    end
    fish.JabAt = now + params.JabIntervalSec
    mgr:start_move(fish, 'jab', pos, target, tp, now,
        FishBehaviorKit.boss_windup(fish, 'jab') + params.JabStepSec * params.JabsPerSide * 2, params.BiteRange)
end

local function step_crab_boss(mgr, fish, now, pos, params)
    local dt = FishBehaviorKit.begin_combat_frame(fish, now)
    local move = fish.Move
    if move then
        if move.Name == 'pinch' then
            local elapsed = now - move.at
            local windup = FishBehaviorKit.boss_windup(fish, 'pinch')
            local strike = elapsed <= windup and 0 or math.min(params.PinchStrikes,
                math.floor((elapsed - windup) / params.PinchStepSec + 1e-9))
            if strike > (move.last_strike or 0) and strike >= 1 then
                move.last_strike = strike
                local target, tp = mgr:is_target_valid(move.Target, pos, params)
                if target and FishBehaviorKit.within_bite(pos, tp, params)
                    and FishBehaviorKit.in_head_zone(pos, fish.facing, tp, params) then
                    mgr:hit(fish, move.Target, params.PinchDamage, 'pinch')
                end
            end
            if now < move.strike_at - 1e-9 then return end
            mgr:end_move(fish, 'pinch-end')
            return
        elseif move.Name == 'charge' then
            if not move.hit_done and now >= move.at + FishBehaviorKit.boss_windup(fish, 'charge') then
                local target, tp = mgr:choose_target(fish, pos, params)
                if target and tp and (tp.x - pos.x)^2 + (tp.z - pos.z)^2 <= params.ChargeRange^2 then
                    move.hit_done = true
                    mgr:hit(fish, target, params.ChargeDamage, 'charge')
                end
            end
            if now < move.strike_at - 1e-9 then return end
            mgr:end_move(fish, 'charge-end')
            return
        elseif move.Name == 'spin' then
            local tick = math.min(params.SpinDurationSec,
                math.max(0, math.floor(now - move.at)))
            if tick > (move.last_tick or 0) then
                move.last_tick = tick
                for _, player in ipairs(mgr:players()) do
                    local valid, cp = mgr:is_target_valid(player, move.Center)
                    if valid and (cp.x - pos.x)^2 + (cp.z - pos.z)^2 <= params.SpinRadius^2 then
                        mgr:hit(fish, player, params.SpinDamage, 'spin')
                    end
                end
            end
            if now < move.strike_at - 1e-9 then return end
            mgr:end_move(fish, 'spin-end')
            return
        end
        return
    end
    local target, tp = mgr:choose_target(fish, pos, params)
    if not target then
        if mgr.ai then mgr.ai:custom(fish) end
        return
    end
    if now >= (fish.SpecialAt or math.huge) then
        fish.SpecialAt = now + params.SpinSec
        mgr:start_move(fish, 'spin', pos, target, tp, now, params.SpinDurationSec, params.SpinRadius)
        return
    end
    if now >= (fish.ChargeAt or math.huge) then
        fish.ChargeAt = now + params.ChargeSec
        mgr:start_move(fish, 'charge', pos, target, tp, now, params.ChargeWindowSec, params.ChargeRange)
        return
    end
    if now >= (fish.PinchAt or 0) and FishBehaviorKit.within_bite(pos, tp, params) then
        fish.PinchAt = now + params.PinchCooldownSec
        mgr:start_move(fish, 'pinch', pos, target, tp, now,
            FishBehaviorKit.boss_windup(fish, 'pinch') + params.PinchStepSec * params.PinchStrikes, params.BiteRange)
        return
    end
    if not FishBehaviorKit.within_bite(pos, tp, params) then
        FishBehaviorKit.chase_step(mgr, fish, pos, tp, dt, params, '蟹老板', nil, true)
    end
end

CrabBehaviors.kingCrab = { init = init, step = step_king_crab }
CrabBehaviors.crabBoss = { init = init, step = step_crab_boss }

return CrabBehaviors
