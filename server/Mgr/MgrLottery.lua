local GameCfg = require('common.GameCfg')
local Eligibility = require('common.LotteryEligibility')
local Draw = require('common.LotteryDraw')

local Mgr = { LastSeq = {} }

local ITEM_BAR = GameCfg.Items.ContainerId.ItemBar

local function copy(value)
    if type(value) ~= 'table' then return value end
    local out = {}
    for k, v in pairs(value) do out[k] = copy(v) end
    return out
end

local function resolve(mgr, player, data, payload)
    local requestId = payload.operation
    if requestId ~= nil and type(requestId) ~= 'table' then return nil, false end
    if requestId == nil then requestId = payload.seq end
    local operation, mode = mgr.Save:ResolveRequest(player, data, 'lottery', requestId)
    if not operation then return nil, false end
    if mode ~= 'replay' then return operation end
    local accepted = mgr.Save:Execute(player, data, operation, function() return nil, 'expired' end,
        function(ok, result)
            if ok then result.operation = operation mgr:Reply(player, result) end
        end)
    return nil, accepted
end

local function execute(mgr, player, data, operation, transform, done)
    if not operation then return false end
    return mgr.Save:Execute(player, data, operation, transform, function(ok, result)
        if ok then result.operation = operation end
        done(ok, result, operation)
    end)
end

function Mgr:Reply(player, payload)
    _G.REUtil:GetRE('LotteryResult'):FireClient(player, payload)
end

function Mgr:MachinePoint()
    local cfg = GameCfg.Lottery
    return { AnchorNames = cfg.MachineAnchors(), Radius = cfg.Radius, Slack = cfg.Slack }
end

function Mgr:Settle(target, slot)
    if type(slot) ~= 'number' or slot ~= math.floor(slot)
        or slot < 1 or slot > target:ItemBarCapacity() then return nil, 'slot' end
    local items = target.Data.Containers[ITEM_BAR]
    local entry = items[slot]
    if not entry or entry.count <= 0 then return nil, 'slot' end
    local eligible, reason = Eligibility.Check(entry)
    if not eligible then return nil, reason end
    local price = GameCfg.Items.SalePrice(entry.itemId, entry.mult)
    if not price or price < 1 then return nil, 'bad-item' end
    local axes = Draw.RollAxes(self.Random)
    if not axes then return nil, 'roll' end
    local outcome = Draw.Evaluate(axes)
    local definition = GameCfg.Items.Definitions[entry.itemId]
    local result = { ok = true, action = 'Draw', slot = slot, itemId = entry.itemId,
        itemName = definition and definition.Name or entry.itemId, betValue = price,
        axes = axes, outcome = outcome.outcome, coinBefore = target.Data.FishCoin }
    items[slot] = nil
    if outcome.outcome == 'pair' then
        local pattern = GameCfg.Lottery.Patterns[outcome.pattern]
        local coins = price * pattern.pairMultiplier
        target:AddCoin(coins, nil, 'lottery:pair')
        result.coins, result.multiplier, result.patternName = coins, pattern.pairMultiplier, pattern.name
    elseif outcome.outcome == 'triple' then
        local pattern = GameCfg.Lottery.Patterns[outcome.pattern]
        local reward = pattern.tripleReward
        if reward.kind == 'weaponChoice' then
            local itemId = Draw.ChooseWeapon(pattern, self.Random)
            if not itemId then
                items[slot] = entry
                return nil, 'roll'
            end
            target:GrantWeapon(itemId, 1)
            local prizeDef = GameCfg.Items.Definitions[itemId]
            result.prize = { kind = 'weapon', itemId = itemId,
                name = prizeDef and prizeDef.Name or itemId }
        else
            items[slot] = { itemId = reward.itemKey, count = 1, containerId = ITEM_BAR }
            result.prize = { kind = 'item', itemId = reward.itemKey, name = reward.itemName }
        end
        result.patternName = pattern.name
    end
    result.coinAfter = target.Data.FishCoin
    return result
end

function Mgr:Draw(player, data, slot, operation)
    if not self.Interact:InRange(player, self:MachinePoint()) then
        self:Reply(player, { ok = false, reason = 'range' })
        return false
    end
    local items = data.Data.Containers[ITEM_BAR]
    local entry = type(slot) == 'number' and slot == math.floor(slot)
        and slot >= 1 and slot <= data:ItemBarCapacity() and items[slot]
    if not entry or entry.count <= 0 then
        self:Reply(player, { ok = false, reason = 'slot' })
        return false
    end
    local eligible, reason = Eligibility.Check(entry)
    if not eligible then
        self:Reply(player, { ok = false, reason = reason })
        return false
    end
    if self.Save then
        return execute(self, player, data, operation, function(draft)
            return self:Settle(draft, slot)
        end, function(written, result, op)
            if not written then self:Reply(player, { ok = false, reason = result }) return end
            print('[MgrLottery] 抽奖落账', player.UserId, op.id, result.itemId,
                'betValue=' .. result.betValue, 'axes=' .. table.concat(result.axes, '/'),
                result.outcome, 'coinBefore=' .. result.coinBefore, 'coinAfter=' .. result.coinAfter,
                result.prize and (result.prize.kind .. ':' .. result.prize.itemId) or '')
            self.PlayerData:SendItemBar(player)
            self:Reply(player, result)
        end)
    end
    local result, failure = self:Settle(data, slot)
    if not result then
        self:Reply(player, { ok = false, reason = failure })
        return false
    end
    data:UpdateData(function() end, true)
    print('[MgrLottery] 抽奖', player.UserId, result.itemId, 'betValue=' .. result.betValue,
        result.outcome, 'FishCoin=' .. tostring(data.Data.FishCoin))
    self.PlayerData:SendItemBar(player)
    self:Reply(player, result)
    return true
end

function Mgr:Handle(player, payload)
    if type(payload) ~= 'table' or payload.action ~= 'Draw' then return false end
    local seq = payload.seq
    if (not self.Save or payload.operation == nil)
        and (type(seq) ~= 'number' or seq ~= math.floor(seq) or seq < 1 or seq > 2147483647) then
        return false
    end
    local data = self.PlayerData and self.PlayerData:GetDataInst(player)
    if not data then return false end
    local operation
    if self.Save then
        local replayed
        operation, replayed = resolve(self, player, data, payload)
        if not operation then return replayed end
    end
    local last = self.LastSeq[player.UserId]
    if last and seq and seq <= last then return false end
    local slot = payload.slot
    if type(slot) ~= 'number' or slot ~= math.floor(slot) then return false end
    self.LastSeq[player.UserId] = seq
    return self:Draw(player, data, slot, operation)
end

function Mgr:PushRecovered(player)
    local data = self.PlayerData and self.PlayerData:GetDataInst(player)
    local meta = data and data.SaveMeta
    local operations = meta and meta.operations
    local last = operations and operations[#operations]
    if not last or last.kind ~= 'lottery' or last.sequence ~= meta.sequence
        or type(last.result) ~= 'table' or not last.result.ok then return end
    local result = copy(last.result)
    result.recovered = true
    result.operation = { id = last.id, sequence = last.sequence, kind = last.kind,
        requestKey = last.requestKey }
    self:Reply(player, result)
end

function Mgr:OnPlayerAdded(player)
    self:PushRecovered(player)
end

function Mgr:Start()
    _G.REUtil:GetRE('LotteryAction').OnServerEvent:Connect(function(player, payload)
        if _G.REUtil:CheckRECD(player, 'LotteryAction', GameCfg.Lottery.ActionCooldownSec) then return end
        self:Handle(player, payload)
    end)
    _G.REUtil:GetRE('LotteryStateRequest').OnServerEvent:Connect(function(player)
        self:PushRecovered(player)
    end)
end

function Mgr:OnPlayerRemoving(player)
    self.LastSeq[player.UserId] = nil
end

return Mgr
