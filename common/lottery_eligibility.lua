local GameCfg = require('common.game_cfg')

local LotteryEligibility = {}

LotteryEligibility.PremiumType = '极品食物'

local function cookedState(entry)
    local cooked = entry.cooked
    if cooked ~= nil and (type(cooked) ~= 'number' or cooked ~= cooked or cooked <= 0 or cooked >= math.huge) then
        return nil
    end
    local saved = entry.saved
    if saved ~= nil and type(saved) ~= 'table' then return nil end
    local flag = saved and saved[GameCfg.Items.CookedFlag]
    if flag ~= nil and type(flag) ~= 'boolean' then return nil end
    return cooked ~= nil or flag == true
end

function LotteryEligibility.check(entry)
    if type(entry) ~= 'table' or type(entry.itemId) ~= 'string' then return false, 'malformed' end
    if entry.count ~= nil and entry.count ~= 1 then return false, 'malformed' end
    local mult = entry.mult
    if mult ~= nil and (type(mult) ~= 'number' or mult ~= mult or mult < 1 or mult > 2) then
        return false, 'malformed'
    end
    local cooked = cookedState(entry)
    if cooked == nil then return false, 'malformed' end
    local definition = GameCfg.Items.Definitions[entry.itemId]
    if not definition then return false, 'bad-item' end
    if definition.Type ~= LotteryEligibility.PremiumType then return false, 'not-premium' end
    if cooked then return false, 'cooked' end
    return true
end

return LotteryEligibility
