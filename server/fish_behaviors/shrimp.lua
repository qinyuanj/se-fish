local FishBehaviorKit = require('server.fish_behaviors.kit')

local ShrimpBehaviors = {}

-- 初始化战斗：活跃期、特殊技时间点与连段计数。
local function variant_init(fish, now, params)
    fish.ActiveUntil = now + (params.ActiveSec or params.SpecialSec)
    fish.SpecialAt = now + (params.SpecialSec or 0)
    fish.combo = 0
end

-- 眩晕/睡眠中：清零速度；未到唤醒时间返回 nil（本帧结束）。
local function resume_from_stun(mgr, fish, now, params, dt)
    if fish.State ~= 'stunned' and fish.State ~= mgr.State.sleeping then return dt end
    fish.carrier.body.LinearVelocity = Vector3.New(0, 0, 0)
    if now < (fish.wake_at or math.huge) then return nil end
    fish.State, fish.wake_at = mgr.State.Combat, nil
    fish.ActiveUntil, fish.combo = now + (params.ActiveSec or params.SpecialSec), 0
    mgr:publish_combat(fish)
    return 0
end

-- 龙系：到点且当前无招或只剩啄时起「雨」；第二个返回值表示本帧结束。
local function refresh_special_move(combat, mgr, fish, now, pos, params)
    local move = fish.Move
    if combat ~= 'dragon' or now < fish.SpecialAt then return move, false end
    if move and move.Name ~= 'peck' then return move, false end
    fish.SpecialAt = now + params.SpecialSec
    if not mgr:start_move(fish, 'rain', pos, nil, nil, now, params.RainSec, params.RainRadius) then
        return nil, true
    end
    fish.Move.last_tick = 0
    return fish.Move, false
end

-- 雨幕：按 tick 结算范围内玩家，最后一跳后转「俯冲」。
local function run_rain(mgr, fish, now, pos, params, move)
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
end

-- 俯冲：沿抛物线落位，命中范围内玩家后自我眩晕。
local function run_dive(mgr, fish, now, params, move)
    local body = fish.carrier.body
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
end

-- 头部命中区的伤害与「尾刺」击飞。
local function strike_damage(mgr, fish, cp, params, move)
    local damage = move.Name == 'tail' and params.TailDamage
        or (move.Name == 'peck' and params.PeckDamage or params.ClawDamage)
    local applied = mgr:hit(fish, move.Target, damage, move.Name)
    if not applied or move.Name ~= 'tail' then return end
    local f = fish.facing or { x = 0, z = 1 }
    local ok, err = pcall(function()
        move.Target.Character.Position = Vector3.New(cp.x + f.x * params.KnockHorizontal,
            cp.y + params.KnockUp, cp.z + f.z * params.KnockHorizontal)
    end)
    if not ok then print('[FishTree] 尾刺击飞失败', fish.Id, tostring(err)) end
end

-- 近战招式：判定目标是否还在咬合范围，按出招时机结算；返回 true 表示本帧结束。
local function run_melee(mgr, fish, now, pos, params, move)
    local valid, cp = mgr:is_target_valid(move.Target, pos, params)
    if not valid or not FishBehaviorKit.within_bite(pos, cp, params) then
        mgr:end_move(fish, 'cancel')
        return false
    end
    if now < move.strike_at then return true end
    mgr:end_move(fish, 'strike')
    if FishBehaviorKit.in_head_zone(pos, fish.facing, cp, params) then
        strike_damage(mgr, fish, cp, params, move)
    end
    fish.combo = ((fish.combo or 0) + 1) % 3
    return false
end

-- 招式推进：rain / dive 各自收尾，近战走判定；返回 true 表示本帧结束。
local function run_move(mgr, fish, now, pos, params, move)
    fish.carrier.body.LinearVelocity = Vector3.New(0, 0, 0)
    if move.Name == 'rain' then
        run_rain(mgr, fish, now, pos, params, move)
        return true
    end
    if move.Name == 'dive' then
        run_dive(mgr, fish, now, params, move)
        return true
    end
    return run_melee(mgr, fish, now, pos, params, move)
end

-- 追击：优先交给 AI，否则按速度朝目标推进一帧。
local function chase_target(mgr, fish, pos, params, dt, target, tp)
    local body = fish.carrier.body
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
end

-- 没有招式时：无目标就停住，已贴脸就起新招，否则追过去。
local function approach_target(combat, mgr, fish, now, pos, params, dt)
    local body = fish.carrier.body
    local target, tp = mgr:choose_target(fish, pos, params)
    if not target then
        if mgr.ai then mgr.ai:custom(fish) end
        body.LinearVelocity = Vector3.New(0, 0, 0)
        return
    end
    if FishBehaviorKit.within_bite(pos, tp, params) then
        body.LinearVelocity = Vector3.New(0, 0, 0)
        local name = combat == 'dragon' and 'peck' or ((fish.combo or 0) == 2 and 'tail' or 'claw')
        mgr:start_move(fish, name, pos, target, tp, now, params.BiteCooldownSec, params.BiteRange)
        return
    end
    chase_target(mgr, fish, pos, params, dt, target, tp)
end

-- 单个虾/龙系变体的每帧推进：combat 显式传参，避免复杂度全堆在 make_variant 上。
local function variant_step(combat, mgr, fish, now, pos, params)
    ---@type number
    local dt = math.max(0, now - (fish.combat_step_at or now))
    fish.combat_step_at = now
    dt = resume_from_stun(mgr, fish, now, params, dt)
    if not dt then return end
    if combat == 'shrimp' and now >= fish.ActiveUntil then
        mgr:stun_fish(fish, now, params)
        return
    end
    local move, ended = refresh_special_move(combat, mgr, fish, now, pos, params)
    if ended then return end
    if move then
        if run_move(mgr, fish, now, pos, params, move) then return end
        dt = 0
    end
    approach_target(combat, mgr, fish, now, pos, params, dt)
end

-- 生成一个虾/龙系变体行为表：combat 由闭包捕获，两个方法转发到模块级实现。
local function make_variant(combat)
    return {
        init = variant_init,
        step = function(mgr, fish, now, pos, params)
            return variant_step(combat, mgr, fish, now, pos, params)
        end,
    }
end

ShrimpBehaviors.shrimp = make_variant('shrimp')
ShrimpBehaviors.dragon = make_variant('dragon')

return ShrimpBehaviors
