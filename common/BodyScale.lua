local GameCfg = require('common.GameCfg')

local M = {}

local function cfg()
    return GameCfg.Ability.BodyScale
end

local function isBadNumber(v)
    return type(v) ~= 'number' or v ~= v or v == math.huge or v == -math.huge
end

local function potionCount(potions, maxPotions)
    if isBadNumber(potions) or potions < 0 then return 0 end
    local whole = math.floor(potions)
    if whole > maxPotions then return maxPotions end
    return whole
end

---@param potions any 变大药水个数（非法值按 0 处理）
---@return table { Scale, Health, Potions, Capped, MaxScale, MaxHealth }
function M.Plan(potions)
    local c = cfg()
    local stepsByScale = math.floor((c.Max - c.Base) / c.Step + 1e-9)
    local maxPotions = math.min(c.MaxPotions, stepsByScale)
    local count = potionCount(potions, maxPotions)
    local scale = c.Base + c.Step * count
    if scale > c.Max then scale = c.Max end
    local health = c.HealthBase + c.HealthBase * c.HealthStepPercent / 100 * count
    if health > c.HealthMax then health = c.HealthMax end
    return {
        Scale = scale, Health = health, Potions = count,
        Capped = count >= maxPotions,
        MaxScale = c.Max, MaxHealth = c.HealthMax,
    }
end

---@param scale any
---@return number
function M.Sanitize(scale)
    local c = cfg()
    if isBadNumber(scale) or scale <= 0 then return c.Base end
    if scale < c.Base then return c.Base end
    if scale > c.Max then return c.Max end
    return scale
end

local function positiveOrZero(v)
    if isBadNumber(v) or v < 0 then return 0 end
    return v
end

---@param base? table { CapsuleHeight, CameraDistance, InteractRange, SocketOffset={x,y,z} }
---@return table { Scale, CapsuleHeight, CameraDistance, InteractRange, SocketOffset? }
function M.Derive(scale, base)
    local c = cfg()
    base = base or c
    local factor = M.Sanitize(scale)
    local derived = {
        Scale = factor,
        CapsuleHeight = positiveOrZero(base.CapsuleHeight) * factor,
        CameraDistance = positiveOrZero(base.CameraDistance) * factor,
        InteractRange = positiveOrZero(base.InteractRange) * factor,
    }
    local offset = base.SocketOffset
    if type(offset) == 'table' then
        derived.SocketOffset = {
            x = positiveOrZero(offset.x) * factor,
            y = positiveOrZero(offset.y) * factor,
            z = positiveOrZero(offset.z) * factor,
        }
    end
    return derived
end

function M.InteractionRadius(character, baseRadius)
    if not character or not character.GetAttribute then return baseRadius end
    local range = character:GetAttribute('InteractRange')
    if isBadNumber(range) or range <= 0 or cfg().InteractRange <= 0 then return baseRadius end
    return baseRadius * M.Sanitize(range / cfg().InteractRange)
end
return M
