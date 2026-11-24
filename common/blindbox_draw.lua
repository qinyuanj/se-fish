local GameCfg = require('common.game_cfg')

local BlindboxDraw = {}

local function rngOf(rng)
    return type(rng) == 'function' and rng or math.random
end

local function entries()
    return GameCfg.Blindbox.Entries
end

local function pityCfg()
    return GameCfg.Blindbox.Pity
end

local function totalWeight()
    local total = 0
    for _, entry in ipairs(entries()) do total = total + entry.weight end
    return total
end

local function validRoll(roll, limit)
    return type(roll) == 'number' and roll == math.floor(roll) and roll >= 1 and roll <= limit
end

local function rollWeighted(source)
    local list, total = entries(), totalWeight()
    local roll = source(total)
    if not validRoll(roll, total) then return nil end
    local cursor = 0
    for index, entry in ipairs(list) do
        cursor = cursor + entry.weight
        if roll <= cursor then return index, entry end
    end
    return nil
end

local function rollGuaranteed(source)
    local keys = pityCfg().prizeItemKeys
    local pick = source(#keys)
    if not validRoll(pick, #keys) then return nil end
    local wanted = keys[pick]
    for index, entry in ipairs(entries()) do
        if entry.itemKey == wanted then return index, entry end
    end
    return nil
end

function BlindboxDraw.Draw(pity, rng)
    if type(pity) ~= 'number' or pity ~= math.floor(pity) or pity < 0 then return nil end
    local source = rngOf(rng)
    local guaranteed = pity >= pityCfg().afterMisses
    local index, entry
    if guaranteed then index, entry = rollGuaranteed(source)
    else index, entry = rollWeighted(source) end
    if not index then return nil end
    local jackpot = entry.jackpot == true
    return {
        index = index,
        itemKey = entry.itemKey,
        itemName = entry.itemName,
        basePrice = entry.basePrice,
        multiplier = 1,
        jackpot = jackpot,
        guaranteed = guaranteed,
        pityBefore = pity,
        pityAfter = jackpot and 0 or pity + 1,
    }
end

function BlindboxDraw.DrawMany(count, pity, rng)
    if type(count) ~= 'number' or count ~= math.floor(count) or count < 1 or count > 10 then
        return nil
    end
    if type(pity) ~= 'number' or pity ~= math.floor(pity) or pity < 0 then return nil end
    local source = rngOf(rng)
    local draws = {}
    local current = pity
    for index = 1, count do
        local draw = BlindboxDraw.Draw(current, source)
        if not draw then return nil end
        draws[index] = draw
        current = draw.pityAfter
    end
    return draws, current
end

return BlindboxDraw
