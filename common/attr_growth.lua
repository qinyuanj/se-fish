local Model = require('common.attr_model')
local GameCfg = require('common.game_cfg')
local M = {}
function M.speed_factor(potions)
    return 1 + Model.plan({ speedPotions = potions }).attributes.PlayerWalkSpeed.Ratio
end
function M.effective_speed(base, potions, mods)
    mods = mods or {}
    local multiplier = mods.paralyzed and 0.0 or 1.0
    if mods.weak then multiplier = multiplier * GameCfg.Survival.WeakSpeedScale end
    if mods.frost then multiplier = multiplier * (1 - GameCfg.Ability.StatusEffects.frost.SlowPercent / 100) end
    local component = Model.plan({ baseSpeed = base, speedPotions = potions, moveMultiplier = multiplier }).attributes.PlayerWalkSpeed
    return component.Base * (1 + component.Ratio)
end
function M.max_health(potions)
    return Model.plan({ bodyPotions = potions }).body.Health
end
return M
