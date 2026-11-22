local GameCfg = require('common.GameCfg')
local BodyScale = require('common.BodyScale')

local Mgr = { LastSeq = {}, Anchors = {} }

local ITEM_BAR = GameCfg.Items.ContainerId.ItemBar

local function resolve(mgr, player, data, payload, kind)
    local requestId = payload.operation
    if requestId ~= nil and type(requestId) ~= 'table' then return nil, false end
    if requestId == nil then requestId = payload.seq end
    local operation, mode = mgr.Save:ResolveRequest(player, data, kind or 'interact:fisherman', requestId)
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
local function itemCount(data, itemId)
    return data.Data.Bait[itemId] or data:ItemCount(itemId)
end

local function fishermanPoint(shared, npc)
    local point = {}
    for key, value in pairs(shared) do point[key] = value end
    point.ZoneId, point.AnchorNames, point.Exchange, point.Chain = npc.ZoneId, npc.AnchorNames, npc.Exchange, npc.Chain
    return point
end

local function flatDistance(a, b)
    local dx, dz = a.x - b.x, a.z - b.z
    return math.sqrt(dx * dx + dz * dz)
end

local function selectedEntry(data)
    local items = data.Data.Containers[ITEM_BAR]
    local slot = data.Data.SelectedSlot
    local entry = slot and items[slot]
    if entry and entry.count > 0 then return slot, entry end
end

local function isCooked(entry)
    return GameCfg.Items.CookRate(entry) ~= nil
end

local Points = {
    fisherman = { Cfg = function() return GameCfg.Interact.Fisherman end, Actions = { Feed = 'Feed' },
        Resolve = function(mgr, player)
            local shared = GameCfg.Interact.Fisherman
            for _, npc in ipairs(GameCfg.Interact.Fishermen) do
                local probe = { AnchorNames = npc.AnchorNames, Radius = shared.Radius, Slack = shared.Slack }
                local anchor = mgr:InRange(player, probe)
                if anchor then return fishermanPoint(shared, npc), anchor end
            end
        end },
    downedPlayer = { Cfg = function() return GameCfg.Rescue end, RequestKey = 'rescue',
        Actions = { Rescue = 'RescueDowned' },
        Resolve = function(mgr, player, payload)
            local function reject(reason)
                mgr:Reply(player, { action = 'Rescue', ok = false, reason = reason,
                    seq = payload.seq, targetUserId = payload.targetUserId })
                return nil
            end
            if type(payload.targetUserId) ~= 'number' then return reject('invalid') end
            local target = mgr:ResolveDownedTarget(payload.targetUserId)
            if not target then return reject('not-downed') end
            local from = player.Character and player.Character.Position
            local to = target.Character and target.Character.Position
            if not from or not to then return reject('no-position') end
            if flatDistance(from, to) > GameCfg.Rescue.Range then return reject('too-far') end
            return GameCfg.Rescue, target
        end },
}

function Mgr:Reply(player, payload)
    _G.REUtil:GetRE('InteractResult'):FireClient(player, payload)
end

function Mgr:FindAnchor(name)
    local cached = self.Anchors[name]
    if cached then return cached end
    local world = game:GetService('World')
    local ok, unit = pcall(world.FindFirstChild, world, name, true)
    if not ok then
        print('[MgrInteract] 查找场景锚点失败', name, tostring(unit))
        return nil
    end
    if unit then self.Anchors[name] = unit end
    return unit
end

local function saleable(data, point)
    local slot, entry = selectedEntry(data)
    if entry then
        local rate = GameCfg.Items.CookRate(entry)
        local price = GameCfg.Items.SalePrice(entry.itemId, entry.mult, rate)
        if price then
            return price, function(d) d.Containers[ITEM_BAR][slot] = nil end,
                entry.itemId .. (rate and '(烤)' or '') .. ' x' .. tostring(entry.mult or 1) .. ' slot=' .. tostring(slot),
                entry.itemId, GameCfg.Fish[entry.itemId] and 'fish' or 'item'
        end
    end
    local baitId = data.Data.SelectedBait
    local price = baitId and point.BaitPrice[baitId]
    local count = baitId and data.Data.Bait[baitId]
    if price and type(count) == 'number' and count >= 1 then
        return price, function(d) d.Bait[baitId] = d.Bait[baitId] - 1 end, baitId, baitId, 'bait'
    end
end

function Mgr:InRange(player, point)
    local character = player and player.Character
    local pos = character and character.Position
    if not pos then return nil end
    local names = point.AnchorNames or { point.AnchorName }
    for _, name in ipairs(names) do
        local anchor = self:FindAnchor(name)
        local center = anchor and anchor.Position
        if center and flatDistance(pos, center) <= BodyScale.InteractionRadius(character, point.Radius) + point.Slack then return anchor end
    end
    return nil
end

function Mgr:PlayEat(anchor, point)
    if not point.EatAnimation then return end
    local okRead, play = pcall(function() return anchor.PlayAnimation end)
    if not okRead or not play then
        print('[MgrInteract] 钓鱼佬没有可播放的动画，跳过吃动作')
        return
    end
    local ok, err = pcall(play, anchor, point.EatAnimation)
    if not ok then print('[MgrInteract] 吃动作播放失败', tostring(err)) end
end

local function productOf(product)
    if type(product) ~= 'string' then return nil end
    local achievement = product:match('^achievement%.(.+)$')
    if achievement then return { achievement = achievement } end
    return { itemId = product }
end

local function exchangeable(data, point)
    local slot, entry = selectedEntry(data)
    local product = entry and not isCooked(entry) and point.Exchange and point.Exchange[entry.itemId]
    if not product then return end
    return { slot = slot, tokenId = entry.itemId, product = product }
end

local function deliver(target, exchange, product)
    local items = target.Data.Containers[ITEM_BAR]
    local kept = items[exchange.slot]
    if not kept or kept.count <= 0 or kept.itemId ~= exchange.tokenId then return false, 'nothing' end
    if product.achievement and target.Extra.achievements and target.Extra.achievements[product.achievement] then
        return false, 'already-completed'
    end
    items[exchange.slot] = nil
    if product.achievement then
        target.Extra.achievements = target.Extra.achievements or {}
        target.Extra.achievements[product.achievement] = true
    elseif not target:CanGrant(product.itemId, 1) or not target:GrantItem(product.itemId, 1) then
        items[exchange.slot] = kept
        return false, 'full'
    end
    if target.Data.SelectedSlot == exchange.slot then target.Data.SelectedSlot = nil end
    return true
end

function Mgr:Exchange(player, data, anchor, point, exchange, operation)
    if self.Save and self.Save:IsPaused(player.UserId) then
        self:Reply(player, { ok = false, reason = '临时本局暂停信物兑换，请先保存到存档' })
        return false
    end
    local product = productOf(exchange.product)
    if not product then
        print('[MgrInteract] 兑换产物无法解析', player.UserId, tostring(exchange.product))
        return false
    end
    local function replyOf(result, written)
        if not written then
            self:Reply(player, { ok = false, reason = result })
            return
        end
        self.PlayerData:SendItemBar(player)
        self:Reply(player, result)
        self:PlayEat(anchor, point)
    end
    if self.Save then
        return execute(self, player, data, operation, function(draft)
            local entry = draft.Data.Containers[ITEM_BAR][exchange.slot]
            if not entry or entry.itemId ~= exchange.tokenId then return nil, 'nothing' end
            local beforeToken, beforeProduct = itemCount(draft, exchange.tokenId), itemCount(draft, exchange.product)
            local changed, failure = deliver(draft, exchange, product)
            if not changed then return nil, failure end
            local result = { ok = true, action = 'Feed', exchange = { from = exchange.tokenId, to = exchange.product },
                coinBefore = draft.Data.FishCoin, coinAfter = draft.Data.FishCoin,
                tokenBefore = beforeToken, tokenAfter = itemCount(draft, exchange.tokenId),
                itemBefore = beforeProduct, itemAfter = itemCount(draft, exchange.product) }
            if product.achievement then result.achievement = product.achievement end
            return result
        end, function(written, result, operation)
            if written then
                print('[MgrInteract] 兑换落账', player.UserId, operation.id, exchange.tokenId, exchange.product,
                    'coinBefore=' .. result.coinBefore, 'coinAfter=' .. result.coinAfter,
                    'tokenBefore=' .. result.tokenBefore, 'tokenAfter=' .. result.tokenAfter,
                    'itemBefore=' .. result.itemBefore, 'itemAfter=' .. result.itemAfter)
            end
            replyOf(result, written)
        end)
    end
    local changed, reason = deliver(data, exchange, product)
    if not changed then
        if reason ~= 'full' then
            print('[MgrInteract] 兑换配置错误', player.UserId, exchange.tokenId, exchange.product, reason)
        end
        self:Reply(player, { ok = false, reason = reason })
        return false
    end
    data:UpdateData(function() end, true)
    print('[MgrInteract] 信物兑换', player.UserId, exchange.tokenId, '->', exchange.product)
    local result = { ok = true, action = 'Feed', exchange = { from = exchange.tokenId, to = exchange.product } }
    if product.achievement then result.achievement = product.achievement end
    replyOf(result, true)
    return true
end

function Mgr:Feed(player, data, anchor, point, seq, operation)
    local exchange = exchangeable(data, point)
    if exchange then return self:Exchange(player, data, anchor, point, exchange, operation) end
    local coins, spend, what, itemId, category = saleable(data, point)
    if not coins then
        self:Reply(player, { ok = false, reason = 'nothing' })
        return false
    end
    if self.Save then
        local selectedSlot, selectedBait = data.Data.SelectedSlot, data.Data.SelectedBait
        return execute(self, player, data, operation, function(draft)
            draft.Data.SelectedSlot, draft.Data.SelectedBait = selectedSlot, selectedBait
            local earned, consume, _, id, kind = saleable(draft, point)
            if not earned then return nil, 'nothing' end
            local beforeCoin, beforeItem = draft.Data.FishCoin, itemCount(draft, id)
            if not draft:AddCoin(earned, consume, 'feed') then return nil, 'nothing' end
            if self.Quest and self.Quest.RecordFact then
                self.Quest:RecordFact(draft, 'Feed', { itemId = id, category = kind, eventId = operation.id })
            end
            return { ok = true, action = 'Feed', coins = earned, itemId = id, category = kind,
                coinBefore = beforeCoin, coinAfter = draft.Data.FishCoin,
                itemBefore = beforeItem, itemAfter = itemCount(draft, id) }
        end, function(written, result, operation)
            if not written then self:Reply(player, { ok = false, reason = result }) return end
            print('[MgrInteract] 喂食落账', player.UserId, operation.id, result.itemId,
                'coinBefore=' .. result.coinBefore, 'coinAfter=' .. result.coinAfter,
                'itemBefore=' .. result.itemBefore, 'itemAfter=' .. result.itemAfter)
            self.PlayerData:SendItemBar(player)
            self:Reply(player, result)
            self:PlayEat(anchor, point)
            if self.Quest then self.Quest:Notify('Feed', player, { itemId = result.itemId,
                category = result.category, eventId = operation.id }) end
        end)
    end
    if not data:AddCoin(coins, spend, 'feed') then return false end
    print('[MgrInteract] 喂食', player.UserId, what, '+' .. tostring(coins), 'FishCoin=' .. tostring(data.Data.FishCoin))
    self.PlayerData:SendItemBar(player)
    self:Reply(player, { ok = true, action = 'Feed', coins = coins, itemId = itemId, category = category })
    self:PlayEat(anchor, point)
    if self.Quest then
        self.Quest:Notify('Feed', player, { itemId = itemId, category = category,
            eventId = 'feed:' .. tostring(player.UserId) .. ':' .. tostring(seq) })
    end
    return true
end

function Mgr:ResolveDownedTarget(userId)
    local survival, vitals = self.Survival, self.Vitals
    if not survival or not vitals then return nil end
    local target = survival:PlayerByUserId(userId)
    if not target then return nil end
    if survival:IsRescuing(target) then return target end
    if not vitals:IsDowned(target) then return nil end
    return target
end

function Mgr:RescueDowned(player, data, target, point, seq, operation)
    local survival = self.Survival
    if not survival then
        self:Reply(player, { action = 'Rescue', ok = false, reason = 'unavailable', seq = seq })
        return false
    end
    local can, reason = survival:CanRescue(target, player)
    if not can then
        self:Reply(player, { action = 'Rescue', ok = false, reason = reason, seq = seq,
            targetUserId = target.UserId })
        return false
    end
    if self.Save and operation then
        local started, why = survival:BeginRescue(target, player)
        local accepted = { ok = started == true, action = 'Rescue', targetUserId = target.UserId, reason = why }
        return execute(self, player, data, operation, function()
            return accepted
        end, function(written, result, op)
            if not written then
                if started then survival:CancelRescue(self.Survival:GetState(target), 'settle-failed') end
                self:Reply(player, { action = 'Rescue', ok = false, reason = tostring(result), seq = seq })
                return
            end
            result.operation = op
            print('[MgrInteract] 抢救受理', player.UserId, op.id, result.ok and 'ok' or tostring(result.reason))
            self:Reply(player, result)
        end)
    end
    local started, why = survival:BeginRescue(target, player)
    self:Reply(player, { action = 'Rescue', ok = started == true, reason = why, seq = seq,
        targetUserId = target.UserId, operation = operation })
    return started == true
end

function Mgr:Handle(player, payload)
    if type(payload) ~= 'table' then return false end
    local entry = Points[payload.target]
    local method = entry and entry.Actions[payload.action]
    local seq = payload.seq
    if not method then return false end
    if (not self.Save or payload.operation == nil)
        and (type(seq) ~= 'number' or seq ~= math.floor(seq) or seq < 1 or seq > 2147483647) then return false end
    local data = self.PlayerData and self.PlayerData:GetDataInst(player)
    if not data then return false end
    local operation
    if self.Save then
        local replayed
        operation, replayed = resolve(self, player, data, payload, entry.RequestKey)
        if not operation then return replayed end
    end
    local last = self.LastSeq[player.UserId]
    if last and seq <= last then return false end
    local point, anchor
    if entry.Resolve then
        point, anchor = entry.Resolve(self, player, payload)
    else
        point = entry.Cfg()
        anchor = self:InRange(player, point)
    end
    if not anchor then return false end
    self.LastSeq[player.UserId] = seq
    return self[method](self, player, data, anchor, point, seq, operation)
end

function Mgr:Start()
    _G.REUtil:GetRE('InteractAction').OnServerEvent:Connect(function(player, payload)
        if _G.REUtil:CheckRECD(player, 'InteractAction', GameCfg.Items.ActionCooldownSec) then return end
        self:Handle(player, payload)
    end)
end

function Mgr:OnPlayerRemoving(player)
    self.LastSeq[player.UserId] = nil
end

return Mgr
