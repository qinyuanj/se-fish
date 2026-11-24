local game_cfg = require('common.game_cfg')
local body_scale = require('common.body_scale')
local M = {}
local function finite(value)
    return type(value) == 'number' and value == value and math.abs(value) < math.huge
end
local function count(value, maximum)
    return finite(value) and math.min(maximum, math.max(0, math.floor(value))) or 0
end
local function components(base, extra, ratio)
    return { Base = base, BaseExtra = extra or 0, Ratio = ratio or 0, Bonus = 0 }
end
function M.Plan(input)
    input = input or {}
    local body = body_scale.Plan(input.bodyPotions)
    local speedCfg = game_cfg.Ability.SpeedPotion
    local growth = math.min(speedCfg.MaxFactor, 1 + speedCfg.StepPercent / 100 * count(input.speedPotions, speedCfg.MaxPotions))
    local base = finite(input.baseSpeed) and input.baseSpeed > 0 and input.baseSpeed or game_cfg.Ability.MoveSpeed.Base
    local multiplier = finite(input.moveMultiplier) and math.max(0, math.min(1, input.moveMultiplier)) or 1
    local hunger = finite(input.hunger) and math.max(0, math.min(game_cfg.vitals.MaxHunger, math.floor(input.hunger))) or game_cfg.vitals.MaxHunger
    return { Body = body, Attributes = {
        PlayerMaxHealth = components(game_cfg.Ability.body_scale.HealthBase, body.Health - game_cfg.Ability.body_scale.HealthBase),
        PlayerWalkSpeed = components(base, 0, growth * multiplier - 1),
        PlayerBodyScale = components(game_cfg.Ability.body_scale.Base, body.Scale - game_cfg.Ability.body_scale.Base),
        PlayerHunger = components(hunger),
    } }
end
function M.WeaponComponents(kind, level)
    local spec = game_cfg.Shop.UpgradeKinds[kind]
    local maximum = spec and spec.MaxLevel or 0
    local scale = game_cfg.Shop.DamageScale(kind, count(level, maximum)) or 1
    return components(1, 0, scale - 1)
end
return M
