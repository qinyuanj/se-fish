local GameCfg = require('common.game_cfg')

local LotteryDraw = {}

local function rngOf(rng)
    return type(rng) == 'function' and rng or math.random
end

local function patterns()
    return GameCfg.Lottery.Patterns
end

function LotteryDraw.RollAxis(rng)
    local list = patterns()
    local total = 0
    for _, pattern in ipairs(list) do total = total + pattern.weight end
    local roll = rngOf(rng)(total)
    if type(roll) ~= 'number' or roll ~= math.floor(roll) or roll < 1 or roll > total then return nil end
    local cursor = 0
    for _, pattern in ipairs(list) do
        cursor = cursor + pattern.weight
        if roll <= cursor then return pattern.number end
    end
    return nil
end

function LotteryDraw.RollAxes(rng)
    local source = rngOf(rng)
    local axes = {}
    for axis = 1, 3 do
        local number = LotteryDraw.RollAxis(source)
        if not number then return nil end
        axes[axis] = number
    end
    return axes
end

function LotteryDraw.Evaluate(axes)
    if type(axes) ~= 'table' then return { outcome = 'none' } end
    local a, b, c = axes[1], axes[2], axes[3]
    if a == nil or b == nil or c == nil then return { outcome = 'none' } end
    if a == b and b == c then return { outcome = 'triple', pattern = a } end
    if a == b then return { outcome = 'pair', pattern = a } end
    if b == c then return { outcome = 'pair', pattern = b } end
    if a == c then return { outcome = 'pair', pattern = a } end
    return { outcome = 'none' }
end

function LotteryDraw.ChooseWeapon(pattern, rng)
    local reward = type(pattern) == 'table' and pattern.tripleReward
    if type(reward) ~= 'table' or reward.kind ~= 'weaponChoice' then return nil end
    local keys = reward.itemKeys
    if type(keys) ~= 'table' or #keys < 1 then return nil end
    local pick = rngOf(rng)(#keys)
    if type(pick) ~= 'number' or pick ~= math.floor(pick) or pick < 1 or pick > #keys then return nil end
    return keys[pick]
end

return LotteryDraw
