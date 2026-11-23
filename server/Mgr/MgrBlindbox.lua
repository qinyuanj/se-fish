local GameCfg = require('common.GameCfg')
local BlindboxDraw = require('common.BlindboxDraw')
local ServerRuntime = require('server.World.ServerRuntime')
local Mgr = { LastSeq = {}, Working = {}, Outcomes = {} }
local function cfg() return GameCfg.Blindbox end
local function goods(count) return count == 10 and 'blindboxTen' or 'blindboxSingle' end
local function bag(data)
    local b = data.Extra.lottery
    b.intents, b.deliveries = b.intents or {}, b.deliveries or {}
    return b
end
function Mgr:Reply(player, payload)
    if payload.seq == nil then payload.seq = self.ReplySeq and self.ReplySeq[player.UserId] end
    _G.REUtil:GetRE('BlindboxResult'):FireClient(player, payload)
end
local function prune(b)
    local keep = {}
    for key, i in pairs(b.intents) do
        local pending = false
        for _, d in pairs(b.deliveries) do if d.intent == key then pending = true end end
        if not pending and (i.state == 'settled' or i.state == 'cancelled') then
            keep[#keep+1] = {key=key, order=i.order or 0}
        end
    end
    table.sort(keep, function(a,c) return a.order < c.order end)
    for n=1, #keep-32 do b.intents[keep[n].key] = nil end
end
function Mgr:PityOf(data) return data and data.Extra.lottery.pity or 0 end
function Mgr:Settle(draft, count, key)
    local b = bag(draft)
    local before = self:PityOf(draft)
    local draws, after = BlindboxDraw.DrawMany(count, before, self.Random or math.random)
    if not draws then return nil, 'roll' end
    local grounded = 0
    for index, draw in ipairs(draws) do
        for fishId, fish in pairs(GameCfg.Fish) do
            for _, drop in ipairs(fish.Drops or {}) do
                if drop.ItemId == draw.itemKey then draft.Extra.collection.unlocked[fishId] = true end
            end
        end
        draw.landed = not draft:AddItem(draw.itemKey, 1)
        if draw.landed then
            grounded = grounded + 1
            local deliveryKey = key .. ':' .. index
            b.deliveries[deliveryKey] = { itemId = draw.itemKey, epoch = self.Loot and self.Loot.DeliveryEpoch,
                intent = key }
        end
        draw.pityBefore, draw.index = nil, nil
    end
    b.pity = after
    return { ok = true, action = 'Draw', count = count, draws = draws,
        pityBefore = before, pityAfter = after, grounded = grounded, operation = { id = key } }
end
function Mgr:Write(player, kind, transform, done)
    local id = player.UserId
    if self.Working[id] then return false, 'pending' end
    local data = self.PlayerData:GetDataInst(player)
    if not data then return false, 'pending' end
    local op, why = self.Save:NextOperation(player, kind)
    if not op then return false, why or 'pending' end
    self.Working[id] = true
    local accepted, reason = self.Save:Execute(player, data, op, transform, function(ok, result)
        self.Working[id] = nil
        done(ok, result, op)
    end)
    if not accepted then
        self.Working[id] = nil
        self:Reply(player, { ok = false, reason = reason, deliveryPending = true })
    end
    return accepted, reason
end
function Mgr:Publish(player, result, key)
    local data = self.PlayerData:GetDataInst(player)
    local pending = false
    if data then for _, d in pairs(bag(data).deliveries) do if d.intent == key then pending = true end end end
    local reply = {}
    for k, v in pairs(result) do reply[k] = v end
    result = reply
    result.deliveryPending = pending
    local intent = data and bag(data).intents[key]
    result.seq, result.requestId = intent and intent.seq, key
    if pending then result.grounded = 0 end
    self:Reply(player, result)
    self.PlayerData:SendItemBar(player)
end
function Mgr:Pump(player)
    local id = player.UserId
    if self.Working[id] then return end
    local data = self.PlayerData:GetDataInst(player)
    if not data then return end
    local b = bag(data)
    for key, intent in pairs(b.intents) do
        local outcome = self.Outcomes[key]
        if outcome then
            self:Write(player, 'blindbox:paid', function(draft)
                bag(draft).intents[key].state = outcome == 'success' and 'paid' or 'cancelled'
                prune(bag(draft))
                return { ok = true }
            end, function(ok)
                if ok then self.Outcomes[key] = nil; self:Pump(player) end
            end)
            return
        elseif intent.state == 'paid' then
            self:Write(player, 'blindbox', function(draft)
                local result, reason = self:Settle(draft, intent.count, key)
                if not result then return nil, reason end
                local i = bag(draft).intents[key]
                i.state, i.result = 'settled', result
                prune(bag(draft))
                return result
            end, function(ok, result, op)
                if not ok then self:Reply(player, { ok = false, reason = result, deliveryPending = true }); return end
                self:Publish(player, result, key)
                self:Pump(player)
            end)
            return
        end
    end
    for key, delivery in pairs(b.deliveries) do
        local origin = player.Character and player.Character.Position
        if not origin then return end
        local loot = self.Loot
        if type(loot) == 'table' and delivery.epoch ~= nil and delivery.epoch ~= loot.DeliveryEpoch then
            return
        end
        local runtime = ServerRuntime.current and ServerRuntime.current()
        local world = runtime and runtime:get_world()
        if not world or type(world.place_delivery) ~= 'function' then return end
        if type(loot) == 'table' and type(loot.SpawnDelivery) == 'function' then
            local allowed, reason = loot:SpawnDelivery(key, delivery.itemId, 1, nil, origin)
            if not allowed then
                print('[MgrBlindbox] 待交付保留', id, key, tostring(reason))
                return
            end
        end
        local ok, spawned = pcall(world.place_delivery, world, key, 'fishPond', {
            kind = 'item', itemId = delivery.itemId, count = 1,
            x = origin.x, y = origin.y, z = origin.z + 2 })
        if not ok or not spawned then
            print('[MgrBlindbox] 待交付保留', id, key, tostring(spawned))
            return
        end
        if type(loot) == 'table' and type(loot.SpawnItem) == 'function' and loot._recorded ~= key then
            loot._recorded = key
            loot:SpawnItem(delivery.itemId, 1, nil, { x = origin.x, y = origin.y, z = origin.z + 2 })
        end
        self:Write(player, 'blindbox:delivery', function(draft)
            bag(draft).deliveries[key] = nil
            return { ok = true }
        end, function(written)
            if written then
                local current = self.PlayerData:GetDataInst(player)
                local intent = current and bag(current).intents[delivery.intent]
                if intent and intent.result then self:Publish(player, intent.result, delivery.intent) end
                self:Pump(player)
            end
        end)
        return
    end
end
function Mgr:Handle(player, payload)
    if type(payload) ~= 'table' or (payload.action ~= 'Draw' and payload.action ~= 'Query') then return false end
    local count, seq = payload.count, payload.seq
    if (count ~= 1 and count ~= 10) or type(seq) ~= 'number' or seq ~= math.floor(seq)
        or seq < 1 or seq > 2147483647 then return false end
    local data = self.PlayerData and self.PlayerData:GetDataInst(player)
    if not data or not self.Save or not self.Platform then return false end
    local session = self.Save.Sessions[player.UserId]
    self.ReplySeq = self.ReplySeq or {}
    self.ReplySeq[player.UserId] = seq
    local key = payload.action == 'Query' and payload.requestId or nil
    key = key or session.Token .. ':blindbox:' .. seq
    local existing = bag(data).intents[key]
    if existing then
        if existing.result then
            existing.result.recovered = true
            self:Publish(player, existing.result, key)
            self:Pump(player)
            return true
        end
        local reason = existing.state == 'cancelled' and 'cancel'
            or (existing.token ~= session.Token and existing.state == 'awaiting' and not self.Outcomes[key] and 'unknown') or 'pending'
        self:Reply(player, { ok = false, reason = reason, requestId=key, seq=seq, deliveryPending = reason ~= 'cancel' })
        self:Pump(player)
        return true
    end
    if payload.action == 'Query' then
        self:Reply(player, {ok=false, reason='expired', seq=seq}); return true
    end
    local available, unavailable = self.Platform:CanPurchase(player, goods(count))
    if not available then self:Reply(player, {ok=false, reason=unavailable}); return true end
    for pendingKey, intent in pairs(bag(data).intents) do
        if intent.state == 'awaiting' or intent.state == 'paid' then
            self:Reply(player, {ok=false, reason=intent.token ~= session.Token and intent.state == 'awaiting'
                and not self.Outcomes[pendingKey] and 'unknown' or 'busy', requestId=pendingKey, originalSeq=intent.seq,
                deliveryPending=true}); return true
        end
    end
    local b = bag(data)
    if b.seqToken == session.Token and seq <= (b.highSeq or 0) then
        self:Reply(player, {ok=false, reason='expired'}); return true
    end
    if self.Platform:HasFlow(player) or self.Working[player.UserId] then
        self:Reply(player, { ok = false, reason = 'busy' }); return true
    end
    if self.LastSeq[player.UserId] and seq <= self.LastSeq[player.UserId] then return false end
    self.LastSeq[player.UserId] = seq
    local accepted, why = self:Write(player, 'blindbox:intent', function(draft)
        local b = bag(draft)
        b.order = (b.order or 0) + 1
        b.seqToken, b.highSeq = session.Token, seq
        b.intents[key] = { state = 'awaiting', count = count, token=session.Token, seq=seq, order=b.order }
        return { ok = true }
    end, function(written, reason)
        if not written then self:Reply(player, { ok = false, reason = reason }); return end
        local opened, failure = self.Platform:Purchase(player, goods(count), 'blindbox', function(outcome)
            self.Outcomes[key] = outcome
            if outcome ~= 'success' then self:Reply(player, { ok = false, reason = outcome, seq=seq, requestId=key }) end
            self:Pump(player)
        end)
        if not opened then
            self.Outcomes[key] = failure or 'unavailable'
            self:Reply(player, { ok = false, reason = failure or 'unavailable', seq=seq, requestId=key })
            self:Pump(player)
        end
    end)
    if not accepted then self:Reply(player, { ok = false, reason = why or 'pending' }) end
    return true
end
function Mgr:PushState(player)
    local data = self.PlayerData:GetDataInst(player)
    if data then
        local recovery
        for key, i in pairs(bag(data).intents) do
            if i.state == 'awaiting' or i.state == 'paid' then
                recovery={requestId=key, seq=i.seq, reason=i.state == 'awaiting' and
                    not self.Outcomes[key] and not self.Platform:HasFlow(player) and 'unknown' or 'pending'}
                break
            end
        end
        self:Reply(player, { ok = true, action = 'State', recovery=recovery,
            pity = self:PityOf(data), guaranteeAt = cfg().Pity.afterMisses + 1 })
    end
end
function Mgr:OnPlayerAdded(player) self:PushState(player); self:Pump(player) end
function Mgr:Update()
    for _, session in pairs(self.Save.Sessions) do
        if session.Player then self:Pump(session.Player) end
    end
end
function Mgr:Start()
    _G.REUtil:GetRE('BlindboxAction').OnServerEvent:Connect(function(player, payload)
        if not _G.REUtil:CheckRECD(player, 'BlindboxAction', cfg().ActionCooldownSec) then self:Handle(player, payload) end
    end)
    _G.REUtil:GetRE('BlindboxStateRequest').OnServerEvent:Connect(function(player) self:PushState(player) end)
end
function Mgr:OnPlayerRemoving(player) self.LastSeq[player.UserId], self.Working[player.UserId] = nil, nil end
return Mgr
