local GameCfg = require('common.GameCfg')

local Mgr = { Parties = {}, PartyOf = {}, Invites = {}, Online = {}, HealthCache = {}, NextId = 0, Epoch = nil }

local function cfg() return GameCfg.Party end

local function logFailure(operation, player, err)
    local userId = type(player) == 'table' and player.UserId or player
    print('[MgrParty]', operation, 'userId=' .. tostring(userId), tostring(err))
end

local function now()
    local ok, value = pcall(function() return game:GetService('World'):GetServerTime() end)
    if not ok then
        logFailure('读取服务器时间 GetServerTime', nil, value)
        return 0
    end
    return tonumber(value) or 0
end

local function re(name) return _G.REUtil:GetRE(name) end

local function flatDistance(a, b)
    if not a or not b then return nil end
    local dx, dz = a.x - b.x, a.z - b.z
    return math.sqrt(dx * dx + dz * dz)
end

local function positionOf(player)
    local character = player and player.Character
    if not character then return nil end
    local ok, pos = pcall(function() return character.Position end)
    if not ok then
        logFailure('读取角色位置 Position', player, pos)
        return nil
    end
    if pos and type(pos.x) == 'number' and type(pos.z) == 'number' then return pos end
end

function Mgr:PartyIdOf(player)
    local id = player and self.PartyOf[player.UserId]
    if id and self.Parties[id] then return id end
end

function Mgr:Members(player)
    local party = self.Parties[self:PartyIdOf(player) or 0]
    if not party then return {} end
    local out = {}
    for _, userId in ipairs(party.Members) do
        local member = self.Online[userId]
        if member then out[#out + 1] = member end
    end
    return out
end

function Mgr:Count(player)
    local party = self.Parties[self:PartyIdOf(player) or 0]
    return party and #party.Members or 0
end

function Mgr:SameParty(a, b)
    local id = a and self:PartyIdOf(a)
    return id ~= nil and b ~= nil and self:PartyIdOf(b) == id
end

function Mgr:DataOf(player)
    local PlayerData = self.PlayerData
    if not PlayerData or not player then return nil end
    local ok, data = pcall(PlayerData.GetDataInst, PlayerData, player)
    if not ok then
        logFailure('读取玩家存档 GetDataInst', player, data)
        return nil
    end
    return data
end

function Mgr:SessionEpoch()
    if not self.Epoch then
        local ok, value = pcall(function() return game:GetService('World'):GetServerTime() end)
        if not ok then logFailure('创建队伍会话纪元 GetServerTime', nil, value) end
        self.Epoch = tostring(ok and value or 0) .. ':' .. tostring(math.random())
    end
    return self.Epoch
end

function Mgr:SavePartyId(player, id)
    local data = self:DataOf(player)
    if not data or type(data.Extra) ~= 'table' then
        logFailure('写入队伍归属 SavePartyId', player, '玩家存档或 Extra 不可用')
        return false, 'save-failed'
    end
    if type(data.Extra.party) ~= 'table' then data.Extra.party = { id = 0 } end
    local partyId = id or 0
    data.Extra.party.id = partyId
    data.Extra.party.epoch = partyId > 0 and self:SessionEpoch() or nil
    return true
end

function Mgr:SavedParty(player)
    local data = self:DataOf(player)
    local party = data and data.Extra and data.Extra.party
    local id = party and party.id
    if type(id) ~= 'number' or id ~= math.floor(id) or id <= 0 then return nil end
    return id, type(party.epoch) == 'string' and party.epoch or nil
end

local function newParty(self)
    self.NextId = self.NextId + 1
    local party = { Id = self.NextId, Members = {} }
    self.Parties[party.Id] = party
    return party
end

function Mgr:AddMember(party, player)
    if self.PartyOf[player.UserId] then return false, 'already-in-party' end
    local ok, reason = self:SavePartyId(player, party.Id)
    if not ok then return false, reason or 'save-failed' end
    party.Members[#party.Members + 1] = player.UserId
    self.PartyOf[player.UserId] = party.Id
    return true
end

function Mgr:RemoveMember(party, player)
    local removedIndex
    for index, userId in ipairs(party.Members) do
        if userId == player.UserId then
            table.remove(party.Members, index)
            removedIndex = index
            break
        end
    end
    self.PartyOf[player.UserId] = nil
    self.HealthCache[player.UserId] = nil
    return removedIndex ~= nil, removedIndex
end

local function restoreMember(self, party, player, index)
    table.insert(party.Members, index or (#party.Members + 1), player.UserId)
    self.PartyOf[player.UserId] = party.Id
end

local function healthRows(self, member)
    local health, maxHealth
    if self.Vitals and type(self.Vitals.SnapshotHealth) == 'function' then
        local ok, value, maxValue = pcall(self.Vitals.SnapshotHealth, self.Vitals, member)
        if ok then health, maxHealth = value, maxValue
        else logFailure('读取队伍血量 SnapshotHealth', member, value) end
    end
    return health, maxHealth
end

function Mgr:SnapshotOf(player, notice)
    local snapshot = { state = 'none', members = {} }
    local invite = self.Invites[player.UserId]
    if invite then
        local from = self.Online[invite.From]
        snapshot.invite = { fromUserId = invite.From, fromName = from and from.Name or nil,
            expiresInSec = math.max(0, math.ceil(invite.ExpiresAt - now())) }
    end
    local party = self.Parties[self:PartyIdOf(player) or 0]
    if party then
        snapshot.state, snapshot.partyId = 'party', party.Id
        local function row(userId)
            local member = self.Online[userId]
            if not member then return nil end
            local health, maxHealth = healthRows(self, member)
            self.HealthCache[userId] = { health = health, maxHealth = maxHealth }
            return { userId = userId, name = member.Name, health = health, maxHealth = maxHealth,
                self = userId == player.UserId }
        end
        local mine = row(player.UserId)
        if mine then snapshot.members[#snapshot.members + 1] = mine end
        for _, userId in ipairs(party.Members) do
            if userId ~= player.UserId then
                local other = row(userId)
                if other then snapshot.members[#snapshot.members + 1] = other end
            end
        end
    end
    if notice then snapshot.notice = notice end
    return snapshot
end

function Mgr:Push(player, notice)
    if not player or not player.UserId then return end
    local ok, err = pcall(function() re('PartyState'):FireClient(player, self:SnapshotOf(player, notice)) end)
    if not ok then print('[MgrParty] 状态下发失败', player.UserId, tostring(err)) end
end

function Mgr:PushParty(party, notice)
    for _, userId in ipairs(party.Members) do self:Push(self.Online[userId], notice) end
end

function Mgr:Reply(player, action, ok, reason)
    local sent, err = pcall(function()
        re('PartyResult'):FireClient(player, { action = action, ok = ok, reason = reason })
    end)
    if not sent then print('[MgrParty] 回执下发失败', tostring(player and player.UserId), tostring(action), tostring(err)) end
    return ok, reason
end

function Mgr:Invite(player, targetUserId)
    if type(targetUserId) ~= 'number' or targetUserId ~= math.floor(targetUserId)
        or targetUserId <= 0 or targetUserId == player.UserId then
        return false, 'invalid-target'
    end
    local target = self.Online[targetUserId]
    if not target then return false, 'offline' end
    if self:PartyIdOf(target) then return false, 'target-in-party' end
    if self:Count(player) >= cfg().MaxMembers then return false, 'full' end
    local mine, theirs = positionOf(player), positionOf(target)
    if not mine or not theirs then return false, 'no-position' end
    if flatDistance(mine, theirs) > cfg().InviteRange then return false, 'too-far' end
    local at = now()
    self.Invites[targetUserId] = { From = player.UserId, At = at, ExpiresAt = at + cfg().InviteTimeoutSec }
    self:Push(target)
    return true
end

function Mgr:Accept(player, fromUserId)
    local invite = self.Invites[player.UserId]
    if not invite then return false, 'no-invite' end
    local function drop(reason)
        self.Invites[player.UserId] = nil
        self:Push(player)
        return false, reason
    end
    if now() >= invite.ExpiresAt then return drop('expired') end
    if fromUserId ~= nil and fromUserId ~= invite.From then return false, 'stale' end
    local inviter = self.Online[invite.From]
    if not inviter then return drop('inviter-offline') end
    local party = self.Parties[self:PartyIdOf(inviter) or 0]
    if party and #party.Members >= cfg().MaxMembers then return drop('full') end
    if self:PartyIdOf(player) then return drop('already-in-party') end
    self.Invites[player.UserId] = nil
    local created = not party
    if created then
        party = newParty(self)
        local ok, reason = self:AddMember(party, inviter)
        if not ok then
            self.Parties[party.Id] = nil
            self:Push(player)
            return false, reason
        end
    end
    local ok, reason = self:AddMember(party, player)
    if not ok then
        if created then
            self:RemoveMember(party, inviter)
            self.Parties[party.Id] = nil
            local restored, restoreReason = self:SavePartyId(inviter, 0)
            if not restored then logFailure('回滚新建队伍邀请人', inviter, restoreReason or '存档不可用') end
            self:Push(inviter)
        end
        self:Push(player)
        return false, reason
    end
    self:PushParty(party, 'joined')
    return true
end

function Mgr:Decline(player)
    if not self.Invites[player.UserId] then return false, 'no-invite' end
    self.Invites[player.UserId] = nil
    self:Push(player)
    return true
end

function Mgr:Disband(party, notice, skipUserId)
    local saved = {}
    for _, userId in ipairs(party.Members) do
        local member = self.Online[userId]
        local ok, reason = self:SavePartyId(member, 0)
        if not ok then
            for _, savedUserId in ipairs(saved) do
                local savedPlayer = self.Online[savedUserId]
                local restored, restoreReason = self:SavePartyId(savedPlayer, party.Id)
                if not restored then logFailure('回滚解散队伍归属', savedUserId, restoreReason or '存档不可用') end
            end
            return false, reason or 'save-failed'
        end
        saved[#saved + 1] = userId
    end
    local members = party.Members
    party.Members = {}
    self.Parties[party.Id] = nil
    for _, userId in ipairs(members) do
        local member = self.Online[userId]
        self.PartyOf[userId] = nil
        self.HealthCache[userId] = nil
        self:Push(member, notice)
    end
    self:RetryRestore(skipUserId)
    return true
end

function Mgr:Leave(player, reason)
    local party = self.Parties[self:PartyIdOf(player) or 0]
    if not party then
        self.PartyOf[player.UserId] = nil
        return false, 'not-in-party'
    end
    if reason ~= 'offline' then
        local ok, saveReason = self:SavePartyId(player, 0)
        if not ok then return false, saveReason end
    end
    local _, removedIndex = self:RemoveMember(party, player)
    local notice = reason == 'offline' and nil or 'left'
    if #party.Members < cfg().MinMembers then
        local ok, saveReason = self:Disband(party, 'disbanded', player.UserId)
        if not ok then
            if reason ~= 'offline' then
                restoreMember(self, party, player, removedIndex)
                local restored, restoreReason = self:SavePartyId(player, party.Id)
                if not restored then logFailure('回滚主动离队成员', player, restoreReason or '存档不可用') end
            end
            self:PushParty(party)
            return false, saveReason
        end
        self:Push(player, notice)
        return true, 'disbanded'
    end
    self:Push(player, notice)
    self:PushParty(party)
    self:RetryRestore(player.UserId)
    return true
end

function Mgr:Handle(player, payload)
    if not player or not player.UserId then return false, 'invalid-player' end
    if not self.Online[player.UserId] then return false, 'not-ready' end
    if type(payload) ~= 'table' then return self:Reply(player, nil, false, 'invalid') end
    local action = payload.action
    local ok, reason
    if action == 'Invite' then ok, reason = self:Invite(player, payload.targetUserId)
    elseif action == 'Accept' then ok, reason = self:Accept(player, payload.fromUserId)
    elseif action == 'Decline' then ok, reason = self:Decline(player)
    elseif action == 'Leave' then ok, reason = self:Leave(player, 'self')
    else return self:Reply(player, action, false, 'unknown-action') end
    return self:Reply(player, action, ok, reason)
end

function Mgr:SyncHealth(time)
    if self.NextHealthSyncAt and time < self.NextHealthSyncAt then return end
    self.NextHealthSyncAt = time + cfg().HealthSyncIntervalSec
    local dirty = {}
    for partyId, party in pairs(self.Parties) do
        for _, userId in ipairs(party.Members) do
            local member = self.Online[userId]
            if member then
                local health, maxHealth = healthRows(self, member)
                local previous = self.HealthCache[userId]
                if not previous or previous.health ~= health or previous.maxHealth ~= maxHealth then
                    self.HealthCache[userId] = { health = health, maxHealth = maxHealth }
                    dirty[partyId] = party
                end
            end
        end
    end
    for _, party in pairs(dirty) do self:PushParty(party) end
end

function Mgr:Update()
    local time = now()
    local expired = {}
    for targetUserId, invite in pairs(self.Invites) do
        if time >= invite.ExpiresAt then expired[#expired + 1] = targetUserId end
    end
    for _, targetUserId in ipairs(expired) do
        local invite = self.Invites[targetUserId]
        self.Invites[targetUserId] = nil
        local target = self.Online[targetUserId]
        if target then self:Push(target) end
        local from = invite and self.Online[invite.From]
        if from then self:Push(from) end
    end
    self:SyncHealth(time)
end

function Mgr:Restore(player)
    local saved, epoch = self:SavedParty(player)
    if not saved then return nil end
    if self:PartyIdOf(player) then return nil end
    local party = self.Parties[saved]
    if party and epoch == self:SessionEpoch() then
        if #party.Members < cfg().MaxMembers then
            local ok = self:AddMember(party, player)
            if not ok then return 'save-failed' end
            self:PushParty(party, 'restored')
            return 'restored'
        end
        return 'full'
    end
    local ok = self:SavePartyId(player, 0)
    if not ok then return 'save-failed' end
    return 'disbanded'
end

function Mgr:RetryRestore(skipUserId)
    local waiting = {}
    for userId, player in pairs(self.Online) do
        if userId ~= skipUserId and player and player.UserId == userId and not self.PartyOf[userId]
            and self:SavedParty(player) then
            waiting[#waiting + 1] = player
        end
    end
    table.sort(waiting, function(a, b) return a.UserId < b.UserId end)
    local restored = 0
    for _, player in ipairs(waiting) do
        local result = self:Restore(player)
        if result == 'restored' then
            restored = restored + 1
        elseif result == 'disbanded' or result == 'save-failed' then
            self:Push(player, result)
        end
    end
    return restored
end

function Mgr:OnPlayerAdded(player)
    if not player or not player.UserId then return end
    self.Online[player.UserId] = player
    local notice = self:Restore(player)
    if notice == 'disbanded' or notice == 'full' or notice == 'save-failed' then self:Push(player, notice)
    elseif not notice then self:Push(player) end
end

function Mgr:OnPlayerRemoving(player)
    if not player or not player.UserId then return end
    if self:PartyIdOf(player) then self:Leave(player, 'offline') end
    self.PartyOf[player.UserId] = nil
    self.Invites[player.UserId] = nil
    for targetUserId, invite in pairs(self.Invites) do
        if invite.From == player.UserId then
            self.Invites[targetUserId] = nil
            self:Push(self.Online[targetUserId])
        end
    end
    self.Online[player.UserId] = nil
end

function Mgr:Start()
    self.Connections = self.Connections or {}
    local function bind(name, handler)
        self.Connections[#self.Connections + 1] = re(name).OnServerEvent:Connect(handler)
    end
    bind('PartyAction', function(player, payload)
        if _G.REUtil.CheckRECD and _G.REUtil:CheckRECD(player, 'PartyAction', cfg().ActionCooldownSec) then return end
        self:Handle(player, payload)
    end)
    bind('PartyStateRequest', function(player)
        if _G.REUtil.CheckRECD and _G.REUtil:CheckRECD(player, 'PartyStateRequest', cfg().StateCooldownSec) then return end
        self:Push(player)
    end)
end

return Mgr
