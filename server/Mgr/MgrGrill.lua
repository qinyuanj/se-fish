local GameCfg = require('common.GameCfg')
local BodyScale = require('common.BodyScale')
local GrillCurve = require('common.GrillCurve')

local Mgr = { Sessions = {}, Anchors = {} }

local ITEM_BAR = GameCfg.Items.ContainerId.ItemBar
local BACKPACK = GameCfg.Items.ContainerId.Backpack

local function cfg()
    return GameCfg.Grill
end

function Mgr:Now()
    self.World = self.World or game:GetService('World')
    return self.World:GetServerTime()
end

function Mgr:GetSession(player)
    return player and self.Sessions[player.UserId]
end

function Mgr:Reply(player, payload)
    _G.REUtil:GetRE('GrillResult'):FireClient(player, payload)
end

function Mgr:SendState(player, payload)
    _G.REUtil:GetRE('GrillState'):FireClient(player, payload)
end

function Mgr:FindAnchor(name)
    local cached = self.Anchors[name]
    if cached then return cached end
    local world = game:GetService('World')
    local ok, unit = pcall(world.FindFirstChild, world, name, true)
    if not ok then
        print('[MgrGrill] 查找场景锚点失败', name, tostring(unit))
        return nil
    end
    if unit then self.Anchors[name] = unit end
    return unit
end

local function flatDistance(a, b)
    local dx, dz = a.x - b.x, a.z - b.z
    return math.sqrt(dx * dx + dz * dz)
end

function Mgr:InRange(player)
    local character = player and player.Character
    local pos = character and character.Position
    if not pos then return nil end
    for _, point in ipairs(cfg().Points) do
        local anchor = self:FindAnchor(point.AnchorName)
        local center = anchor and anchor.Position
        if center and flatDistance(pos, center) <= BodyScale.InteractionRadius(character, cfg().Radius) + cfg().Slack then
            return point.AnchorName, anchor
        end
    end
    return nil
end

local function isToken(itemId)
    for _, chain in ipairs(GameCfg.Content.Exchanges) do
        if chain.EliteToken == itemId or chain.BossToken == itemId then return true end
    end
    return false
end

local function grillable(entry)
    if not entry or entry.count <= 0 then return false end
    local definition = GameCfg.Items.Definitions[entry.itemId]
    if not definition then return false end
    if definition.Type ~= '食物' and definition.Type ~= '极品食物' then return false end
    return GameCfg.Items.CookRate(entry) == nil
end

local function selectedEntry(data)
    local items = data.Data.Containers[ITEM_BAR]
    local slot = data.Data.SelectedSlot
    local entry = slot and items[slot]
    if entry and entry.count > 0 then return slot, entry end
end

local function place(data, itemId, mult, rate, selectSlot)
    for _, pair in ipairs({ { ITEM_BAR, data:ItemBarCapacity() }, { BACKPACK, data:BackpackCapacity() } }) do
        local items = data.Data.Containers[pair[1]]
        for index = 1, pair[2] do
            local entry = items[index]
            if not entry or entry.count <= 0 then
                items[index] = { itemId = itemId, count = 1, containerId = pair[1], mult = mult,
                    cooked = rate, saved = rate and { k = rate } or nil }
                if selectSlot and pair[1] == ITEM_BAR then data.Data.SelectedSlot = index end
                return true
            end
        end
    end
    return false
end

function Mgr:Explode(session)
    local anchor = session.anchorName and self:FindAnchor(session.anchorName)
    local center = anchor and anchor.Position
    if not center or not self.Vitals then return end
    local hit = self.Vitals:NewHit(nil, 'grillBurn')
    local ok, players = pcall(function() return game:GetService('Players'):GetPlayers() end)
    if not ok or type(players) ~= 'table' then return end
    for _, other in pairs(players) do
        local character = other.Character
        local pos = character and character.Position
        if pos and flatDistance(pos, center) <= cfg().BurnRadius then
            self.Vitals:ApplyHit(hit, other, cfg().BurnDamage)
        end
    end
end

function Mgr:SettleBurn(session)
    if session.state == 'burnt' then return false end
    session.state = 'burnt'
    local player = session.player
    if self.Sessions[player.UserId] == session then self.Sessions[player.UserId] = nil end
    self:Explode(session)
    local data = self.PlayerData and self.PlayerData:GetDataInst(player)
    if data and self.Save then
        local operation = self.Save:NextOperation(player, 'grill:burn')
        if operation then
            self.Save:Execute(player, data, operation, function(draft)
                draft.Extra.recovery.grill = nil
                return { ok = true, action = 'Burn', itemId = session.itemId }
            end, function() end)
        end
    end
    self:SendState(player, { state = 'burnt' })
    print('[MgrGrill] 烤糊', player.UserId, session.itemId)
    return true
end

function Mgr:SettleDeath(session, now)
    if session.settleFlying then return end
    local rate = session.rate
    if rate == nil then
        local elapsed = now - session.startedAt
        if GrillCurve.IsBurnt(elapsed, cfg()) then return self:SettleBurn(session) end
        rate = GrillCurve.Rate(elapsed, cfg())
    end
    local player = session.player
    local data = self.PlayerData and self.PlayerData:GetDataInst(player)
    if not data or not self.Save then return end
    local operation = self.Save:NextOperation(player, 'grill:settle')
    if not operation then return end
    session.settleFlying = true
    local accepted = self.Save:Execute(player, data, operation, function(draft)
        draft.Extra.recovery.grill = nil
        local pending = not place(draft, session.itemId, session.mult, rate) or nil
        if pending then
            draft.Extra.recovery.grill = { itemId = session.itemId, mult = session.mult, cooked = rate }
        end
        return { ok = true, action = 'Settle', itemId = session.itemId, rate = rate, pending = pending }
    end, function(written)
        if self.Sessions[player.UserId] ~= session then return end
        session.settleFlying = nil
        if not written then return end
        self.Sessions[player.UserId] = nil
        self.PlayerData:SendItemBar(player)
        self:SendState(player, { state = 'idle' })
        print('[MgrGrill] 死亡结算', player.UserId, session.itemId, 'rate=' .. tostring(rate))
    end)
    if not accepted then session.settleFlying = nil end
end

function Mgr:BeforeLeave(player)
    local session = self.Sessions[player.UserId]
    if not session or session.player ~= player then return end
    self.Sessions[player.UserId] = nil
    local data = self.PlayerData and self.PlayerData:GetDataInst(player)
    if not data then return end
    local now = self:Now()
    if session.state == 'cooking' and GrillCurve.IsBurnt(now - session.startedAt, cfg()) then
        data.Extra.recovery.grill = nil
        self:Explode(session)
        print('[MgrGrill] 离开时已烤糊', player.UserId, session.itemId)
        return
    end
    local rate = session.rate or GrillCurve.Rate(now - session.startedAt, cfg())
    if place(data, session.itemId, session.mult, rate) then
        data.Extra.recovery.grill = nil
        print('[MgrGrill] 离开结算', player.UserId, session.itemId, 'rate=' .. tostring(rate))
    else
        data.Extra.recovery.grill = { itemId = session.itemId, mult = session.mult, cooked = rate }
        print('[MgrGrill] 离开满格，转待恢复', player.UserId, session.itemId, 'rate=' .. tostring(rate))
    end
end

function Mgr:TryRecover(userId)
    local recovery = self.Recoveries and self.Recoveries[userId]
    if not recovery or recovery.flying then return end
    local player = recovery.player
    local data = self.PlayerData and self.PlayerData:GetDataInst(player)
    local pending = data and data.Extra and data.Extra.recovery and data.Extra.recovery.grill
    if type(pending) ~= 'table' or type(pending.itemId) ~= 'string' then
        self.Recoveries[userId] = nil
        return
    end
    local rate = pending.cooked
    if rate == nil then
        local elapsed = self:Now() - (type(pending.at) == 'number' and pending.at or self:Now())
        rate = GrillCurve.IsBurnt(elapsed, cfg()) and 0 or GrillCurve.Rate(elapsed, cfg())
    end
    if rate > 0 and not data:CanGrant(pending.itemId, 1) then return end
    if not self.Save then return end
    recovery.id = recovery.id or (function()
        self.RecoverSeq = (self.RecoverSeq or 0) + 1
        return self.RecoverSeq
    end)()
    local operation, mode = self.Save:ResolveRequest(player, data, 'grill:recover', recovery.id)
    if not operation then return end
    if mode == 'replay' then
        self.Recoveries[userId] = nil
        return
    end
    recovery.flying = true
    local itemId, mult = pending.itemId, pending.mult
    local accepted = self.Save:Execute(player, data, operation, function(draft)
        draft.Extra.recovery.grill = nil
        if rate > 0 and not place(draft, itemId, mult, rate) then
            draft.Extra.recovery.grill = { itemId = itemId, mult = mult, cooked = rate }
        end
        return { ok = true, action = 'Recover', itemId = itemId, rate = rate }
    end, function(written)
        local current = self.Recoveries and self.Recoveries[userId]
        if current ~= recovery then return end
        recovery.flying = nil
        if not written then return end
        self.Recoveries[userId] = nil
        self.PlayerData:SendItemBar(player)
        print('[MgrGrill] 重进恢复', userId, itemId, 'rate=' .. tostring(rate))
    end)
    if not accepted then recovery.flying = nil end
end

function Mgr:OnPlayerAdded(player)
    if not player then return end
    local data = self.PlayerData and self.PlayerData:GetDataInst(player)
    local pending = data and data.Extra and data.Extra.recovery and data.Extra.recovery.grill
    if type(pending) == 'table' then
        self.Recoveries = self.Recoveries or {}
        self.Recoveries[player.UserId] = { player = player }
        self:TryRecover(player.UserId)
    else
        self:SendState(player, { state = 'idle' })
    end
end

function Mgr:OnPlayerRemoving(player)
    if not player then return end
    self.Sessions[player.UserId] = nil
    if self.Recoveries then self.Recoveries[player.UserId] = nil end
end

local function resolve(mgr, player, data, kind, seq)
    local operation, mode = mgr.Save:ResolveRequest(player, data, kind, seq)
    if not operation then return nil, mode end
    if mode ~= 'replay' then return operation end
    mgr.Save:Execute(player, data, operation, function() return nil, 'expired' end,
        function(ok, result)
            if ok then
                result.operation = operation
                mgr:Reply(player, result)
            end
        end)
    return nil, 'replay'
end

function Mgr:RequestStart(player, seq, confirm)
    local function fail(reason)
        self:Reply(player, { seq = seq, ok = false, reason = reason })
        return false
    end
    local data = self.PlayerData and self.PlayerData:GetDataInst(player)
    if not data or not self.Save then return fail('unavailable') end
    local operation, mode = resolve(self, player, data, 'grill:start', seq)
    if not operation then
        if mode == 'replay' then return true end
        return fail(tostring(mode or 'invalid'))
    end
    if self.Vitals and not self.Vitals:CanAct(player) then return fail('not-alive') end
    if self.Sessions[player.UserId] then return fail('busy') end
    local anchorName = self:InRange(player)
    if not anchorName then return false end
    local slot, entry = selectedEntry(data)
    if not grillable(entry) then return fail('no-fish') end
    if isToken(entry.itemId) and confirm ~= true then return fail('token-warn') end
    local startedAt = self:Now()
    local itemId, mult = entry.itemId, entry.mult
    return self.Save:Execute(player, data, operation, function(draft)
        local draftSlot, draftEntry = selectedEntry(draft)
        if draftSlot ~= slot or not grillable(draftEntry) or draftEntry.itemId ~= itemId then
            return nil, 'no-fish'
        end
        draft.Data.Containers[ITEM_BAR][slot] = nil
        if draft.Data.SelectedSlot == slot then draft.Data.SelectedSlot = nil end
        local pending = draft.Extra.recovery.grill
        if type(pending) == 'table' then
            local pendingRate = pending.cooked
            if pendingRate == nil and type(pending.at) == 'number' then
                local elapsed = startedAt - pending.at
                pendingRate = GrillCurve.IsBurnt(elapsed, cfg()) and 0 or GrillCurve.Rate(elapsed, cfg())
            end
            draft.Extra.recovery.grill = nil
            if pendingRate and pendingRate > 0
                and not place(draft, pending.itemId, pending.mult, pendingRate) then
                draft.Extra.recovery.grill = { itemId = pending.itemId, mult = pending.mult,
                    cooked = pendingRate }
                return nil, 'full'
            end
        end
        draft.Extra.recovery.grill = { itemId = itemId, mult = mult, at = startedAt, anchor = anchorName }
        return { ok = true, action = 'Start', seq = seq, itemId = itemId, mult = mult,
            startedAt = startedAt }
    end, function(written, result)
        if not written then
            self:Reply(player, { seq = seq, ok = false, reason = tostring(result) })
            return
        end
        self.Sessions[player.UserId] = { player = player, itemId = itemId, mult = mult,
            startedAt = startedAt, anchorName = anchorName, state = 'cooking' }
        self.PlayerData:SendItemBar(player)
        self:Reply(player, result)
        self:SendState(player, { state = 'cooking', itemId = itemId, mult = mult,
            startedAt = startedAt })
        print('[MgrGrill] 开烤', player.UserId, itemId, mult)
    end)
end

function Mgr:RequestTakeout(player, seq)
    local function fail(reason)
        self:Reply(player, { seq = seq, ok = false, reason = reason })
        return false
    end
    local data = self.PlayerData and self.PlayerData:GetDataInst(player)
    if not data or not self.Save then return fail('unavailable') end
    local operation, mode = resolve(self, player, data, 'grill:takeout', seq)
    if not operation then
        if mode == 'replay' then return true end
        return fail(tostring(mode or 'invalid'))
    end
    local session = self.Sessions[player.UserId]
    if not session then return fail('no-session') end
    if self.Vitals and not self.Vitals:CanAct(player) then return fail('not-alive') end
    if not self:InRange(player) then return fail('out-of-range') end
    if session.state == 'cooking' then
        local elapsed = self:Now() - session.startedAt
        if GrillCurve.IsBurnt(elapsed, cfg()) then
            self:SettleBurn(session)
            return fail('burnt')
        end
        session.state = 'ready'
        session.rate = GrillCurve.Rate(elapsed, cfg())
    end
    local rate = session.rate
    return self.Save:Execute(player, data, operation, function(draft)
        draft.Extra.recovery.grill = nil
        if not place(draft, session.itemId, session.mult, rate, true) then
            draft.Extra.recovery.grill = { itemId = session.itemId, mult = session.mult, cooked = rate }
            return nil, 'full'
        end
        return { ok = true, action = 'Takeout', seq = seq, itemId = session.itemId,
            mult = session.mult, rate = rate }
    end, function(written, result)
        if self.Sessions[player.UserId] ~= session then return end
        if not written then
            self:Reply(player, { seq = seq, ok = false, reason = tostring(result) })
            return
        end
        self.Sessions[player.UserId] = nil
        self.PlayerData:SendItemBar(player)
        self:Reply(player, result)
        self:SendState(player, { state = 'idle' })
        print('[MgrGrill] 取出', player.UserId, session.itemId, 'rate=' .. tostring(rate))
    end)
end

function Mgr:Query(player, seq)
    local session = self.Sessions[player.UserId]
    if session then
        self:SendState(player, { state = session.state, itemId = session.itemId, mult = session.mult,
            startedAt = session.startedAt, rate = session.rate })
    else
        self:SendState(player, { state = 'idle' })
    end
    return true
end

function Mgr:Handle(player, payload)
    if type(payload) ~= 'table' then return false end
    local seq = payload.seq
    if type(seq) ~= 'number' or seq ~= math.floor(seq) or seq < 1 or seq > 2147483647 then
        return false
    end
    if payload.action == 'Start' then return self:RequestStart(player, seq, payload.confirm) end
    if payload.action == 'Takeout' then return self:RequestTakeout(player, seq) end
    if payload.action == 'Query' then return self:Query(player, seq) end
    return false
end

function Mgr:Update()
    local now = self:Now()
    for _, session in pairs(self.Sessions) do
        if session.state == 'cooking' then
            if self.Vitals and not self.Vitals:CanAct(session.player) then
                self:SettleDeath(session, now)
            elseif GrillCurve.IsBurnt(now - session.startedAt, cfg()) then
                self:SettleBurn(session)
            end
        end
    end
    if self.Recoveries then
        for userId in pairs(self.Recoveries) do self:TryRecover(userId) end
    end
end

function Mgr:Start()
    local ok, world = pcall(function() return game:GetService('World') end)
    if ok then self.World = world end
    _G.REUtil:GetRE('GrillAction').OnServerEvent:Connect(function(player, payload)
        if type(payload) ~= 'table' then return end
        if _G.REUtil:CheckRECD(player, 'GrillAction', GameCfg.Items.ActionCooldownSec) then return end
        self:Handle(player, payload)
    end)
end

return Mgr
