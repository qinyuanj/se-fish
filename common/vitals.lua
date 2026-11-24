local Vitals = {}

function Vitals.advance(hunger, seconds, cfg)
    seconds = math.min(math.max(0, math.floor(seconds or 0)), cfg.MaxCatchUpSec or seconds)
    local damage = 0
    for _ = 1, seconds do
        if hunger > 0 then
            hunger = math.max(0, hunger - cfg.HungerPerSec)
        else
            damage = damage + cfg.StarveDamagePerSec
        end
    end
    return hunger, damage
end

function Vitals.restore(value, max, percent)
    return math.min(max, value + math.floor(max * percent / 100))
end

return Vitals
