local model = require('common.attr_model')
local game_cfg = require('common.game_cfg')
local M = {}
function M.SpeedFactor(potions)
    return 1 + model.Plan({ speedPotions = potions }).Attributes.PlayerWalkSpeed.Ratio
end
function M.EffectiveSpeed(base, potions, mods)
    mods = mods or {}
    local multiplier = mods.paralyzed and 0 or 1
    if mods.weak then multiplier = multiplier * game_cfg.Survival.WeakSpeedScale end
    if mods.frost then multiplier = multiplier * (1 - game_cfg.Ability.StatusEffects.frost.SlowPercent / 100) end
    local component = model.Plan({ baseSpeed = base, speedPotions = potions, moveMultiplier = multiplier }).Attributes.PlayerWalkSpeed
    return component.Base * (1 + component.Ratio)
end
function M.MaxHealth(potions)
    return model.Plan({ bodyPotions = potions }).Body.Health
end
return M
