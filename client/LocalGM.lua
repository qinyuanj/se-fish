local REUtil = require('common.REUtil')

local LocalGM = {}

local function notice(msg)
    print('[LocalGM]', msg)
    if _G.LocalMsgNotice then _G.LocalMsgNotice(msg) end
end

function LocalGM:Send(payload)
    REUtil:GetRE('GMAction'):FireServer(payload)
end

function LocalGM:Start()
    _G.GM = {
        Coin = function(amount, target) self:Send({ action = 'Coin', amount = amount, target = target }) end,
        Item = function(itemId, count, target)
            self:Send({ action = 'Item', itemId = itemId, count = count or 1, target = target })
        end,
        SetHealth = function(value, target) self:Send({ action = 'SetHealth', value = value, target = target }) end,
        SetHunger = function(value, target) self:Send({ action = 'SetHunger', value = value, target = target }) end,
        NextFish = function(fishId, target) self:Send({ action = 'NextFish', fishId = fishId, target = target }) end,
    }
    REUtil:GetRE('GMResult').OnClientEvent:Connect(function(result)
        if type(result) ~= 'table' then return end
        notice('GM ' .. tostring(result.action) .. (result.ok and ' 成功' or ' 被拒')
            .. ' 目标 ' .. tostring(result.target))
    end)
end

return LocalGM
