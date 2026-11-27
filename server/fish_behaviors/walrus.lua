local FishBehaviorKit = require('server.fish_behaviors.kit')

local WalrusBehaviors = {}

local function init(fish, now, params)
    fish.ChargeAt = now + params.ChargeSec
end

local function advance_charge(mgr, fish, now, pos, params)
    local body = fish.carrier.body
    local move = fish.Move
    if now < move.windup_at - 1e-9 then
        local valid = mgr:is_target_valid(move.Target, pos, params)
        if not valid then mgr:end_move(fish, 'cancel') end
        return
    end
    if not move.dash_from then
        move.dash_from = { x = pos.x, y = pos.y, z = pos.z }
    end
    local facing = fish.facing or { x = 0, z = 1 }
    local progress = math.min(params.ChargeDistance, (now - move.windup_at) * params.ChargeSpeed)
    local moved, err = pcall(function()
        body.Position = Vector3.New(
            move.dash_from.x + facing.x * progress, pos.y,
            move.dash_from.z + facing.z * progress)
    end)
    if not moved then
        print('[FishTree] 海象突击位移失败', 'fish=' .. tostring(fish.Id), tostring(err))
        mgr:end_move(fish, 'cancel')
        return
    end
    local actual = FishBehaviorKit.read_position(body)
    if actual then
        for _, player in ipairs(mgr:players()) do
            if not move.hits[player] then
                local valid, cp = mgr:is_target_valid(player, actual, params)
                if valid and FishBehaviorKit.segment_distance_sq(cp.x, cp.z,
                        move.dash_from.x, move.dash_from.z, actual.x, actual.z)
                    <= params.ChargeContactRange * params.ChargeContactRange then
                    move.hits[player] = true
                    mgr:hit(fish, player, params.ChargeDamage, 'charge')
                end
            end
        end
    end
    if now >= move.strike_at - 1e-9 then
        mgr:end_move(fish, 'charge-end')
    end
end

local function step(mgr, fish, now, pos, params)
    local dt = FishBehaviorKit.begin_combat_frame(fish, now)
    local move = fish.Move
    if move then
        if move.Name == 'swing' then
            if FishBehaviorKit.advance_head_move(mgr, fish, move, now, pos, params, params.SwingDamage) then return end
        elseif move.Name == 'charge' then
            advance_charge(mgr, fish, now, pos, params)
            return
        else
            return
        end
    end
    if now >= (fish.ChargeAt or math.huge) then
        local target, tp = mgr:choose_target(fish, pos, params)
        if not target then
            if mgr.ai then mgr.ai:custom(fish) end
            return
        end
        fish.ChargeAt = now + params.ChargeSec
        if not mgr:start_move(fish, 'charge', pos, target, tp, now,
            params.ChargeWindupSec + params.ChargeDistance / params.ChargeSpeed,
            params.ChargeDistance) then return end
        fish.Move.windup_at = now + params.ChargeWindupSec
        fish.Move.hits = {}
        return
    end
    FishBehaviorKit.engage_or_chase(mgr, fish, now, pos, params, dt, 'swing', params.SwingCooldownSec, '海象')
end

WalrusBehaviors.walrus = { init = init, step = step }

return WalrusBehaviors
