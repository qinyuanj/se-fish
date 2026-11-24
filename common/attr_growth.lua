local Model = require('common.attr_model')
local GameCfg = require('common.game_cfg')
local M = {}
function M.SpeedFactor(potions)
    return 1 + Model.Plan({ speedPotions = potions }).Attributes.PlayerWalkSpeed.Ratio
end
function M.EffectiveSpeed(base, potions, mods)
    mods = mods or {}
    local multiplier = mods.paralyzed and 0 or 1
    if mods.weak then multiplier = multiplier * GameCfg.Survival.WeakSpeedScale end
    if mods.frost then multiplier = multiplier * (1 - GameCfg.Ability.StatusEffects.frost.SlowPercent / 100) end
    local component = Model.Plan({ baseSpeed = base, speedPotions = potions, moveMultiplier = multiplier }).Attributes.PlayerWalkSpeed
    return component.Base * (1 + component.Ratio)
end
function M.MaxHealth(potions)
    return Model.Plan({ bodyPotions = potions }).Body.Health
end
return M
