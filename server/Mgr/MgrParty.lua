-- §9 多人规则（#253 小队）：小队归属、名单与人数是只由服务端维护的权威状态。
-- 客户端只能表达意图（邀请谁、接受、拒绝、离队）：请求里的 partyId / members / owner 一律不读，
-- 归属与名单只由本管理器判定，写进玩家存档的 extra.party.id，重连时按它恢复或给出明确的解散结果。
-- 邀请 2 米、10 秒未处理按拒绝、3 人上限、离线自动离队、少于 2 人解散、主动离队立即生效。
-- 伤害入口一行不动：队友免伤的证据归 PK/抢救子单，这里只提供 SameParty 接缝给后续判定用。
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

-- 邀请距离按场景平面距离（与摆渡 BoatRange、近战判定同一口径），高度差不算进 2 米。
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

-- 名单按加入顺序；只返回在线成员（离线成员在 OnPlayerRemoving 时已经离队）。
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

-- 队友判定的唯一接缝：免伤等规则从这里取结论，不自己维护第二份归属。
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

-- 服务端会话纪元：本轮开服发的队伍号都带它。与 MgrLoot.DeliveryEpoch 同口径
-- （开服时刻 + 随机数），只用来分辨「号码是不是这一轮发的」，不是鉴权秘密。
function Mgr:SessionEpoch()
    if not self.Epoch then
        local ok, value = pcall(function() return game:GetService('World'):GetServerTime() end)
        if not ok then logFailure('创建队伍会话纪元 GetServerTime', nil, value) end
        self.Epoch = tostring(ok and value or 0) .. ':' .. tostring(math.random())
    end
    return self.Epoch
end

-- 归属写进存档的持久字段；落账交给 MgrSave 的自动存档与离场快照，这里只改权威值。
-- 队伍号旁同时记纪元：NextId 每轮开服从 0 自增，只凭裸号码会把旧档玩家恢复进陌生队伍。
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

-- 存档里的队伍归属：号码 + 写入时的会话纪元（旧档没有纪元，返回 nil）。
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
    -- 先写归属再提交内存成员关系；写档失败时这名玩家从未占队名额。
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

-- 快照就是界面与本单断言的唯一读面：无队伍 state='none'，有队伍带上每名在线成员的血量。
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

-- 邀请：2 米内、双方队伍都有空位、目标还没有队伍。邀请只记在服务端，客户端拿不到可写的名额。
function Mgr:Invite(player, targetUserId)
    if type(targetUserId) ~= 'number' or targetUserId ~= math.floor(targetUserId)
        or targetUserId <= 0 or targetUserId == player.UserId then
        return false, 'invalid-target'
    end
    local target = self.Online[targetUserId]
    if not target then return false, 'offline' end
    -- 目标已在别的队伍里时拒绝邀请（不隐式替他换队，见 docs/to-questionnaire 的待决题）。
    if self:PartyIdOf(target) then return false, 'target-in-party' end
    if self:Count(player) >= cfg().MaxMembers then return false, 'full' end
    local mine, theirs = positionOf(player), positionOf(target)
    if not mine or not theirs then return false, 'no-position' end
    if flatDistance(mine, theirs) > cfg().InviteRange then return false, 'too-far' end
    -- 同一目标只留最新一条待处理邀请：旧邀请随新邀请作废，避免两条邀请各记一个名额。
    local at = now()
    self.Invites[targetUserId] = { From = player.UserId, At = at, ExpiresAt = at + cfg().InviteTimeoutSec }
    self:Push(target)
    return true
end

-- 接受：只认服务端记下的那条邀请；客户端自报的 fromUserId 只用来核对，不参与选队。
function Mgr:Accept(player, fromUserId)
    local invite = self.Invites[player.UserId]
    if not invite then return false, 'no-invite' end
    -- 拒绝收场只有一件事：清掉这条待处理邀请、推一次状态、把原因回给调用方。
    local function drop(reason)
        self.Invites[player.UserId] = nil
        self:Push(player)
        return false, reason
    end
    -- 到期判定与 Update 的清扫同一口径：不等 Update 的同一帧窗口里到点的邀请也不放行。
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
            -- 新队是两名成员的一次提交：第二人失败时，邀请人的内存与存档归属都回滚。
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
    -- 先清完全部存档归属再提交内存解散；中途失败时恢复此前已清的值，成员关系不动。
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
    -- #249：解散也走一次满员等待的重试——等着的那批人的原队已经不在，
    -- 让他们当场拿到「原队已散」的明确结果，归属落回无队伍，而不是把悬空归属留到下次重连。
    self:RetryRestore(skipUserId)
    return true
end

-- reason = 'offline' 时保留存档里的归属，重连才有「恢复原队伍」；主动离队立即落回无队伍。
-- #249：离队会空出位置，末尾统一重试一次「满员等待」的玩家（见 RetryRestore，条款 9-22）。
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
        -- Disband 末尾自己会重试一次满员等待，这里不再重复
        local ok, saveReason = self:Disband(party, 'disbanded', player.UserId)
        if not ok then
            -- 主动离队可完整回滚；离线玩家仍须移除，不能用内存队伍阻止引擎离场。
            if reason ~= 'offline' then
                restoreMember(self, party, player, removedIndex)
                local restored, restoreReason = self:SavePartyId(player, party.Id)
                if not restored then logFailure('回滚主动离队成员', player, restoreReason or '存档不可用') end
            end
            -- 主动分支推送回滚后的完整名单；离线分支推送移除离线者后的剩余名单，共用一次。
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

-- 血量不是入队时的一次性快照：周期读取 Vitals，变化时向整队推送，未变化不广播。
-- 这是 Vitals 自身 HealthChanged 属性同步之外的队伍 HUD 通道，伤害、治疗与复活都走同一读面。
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

-- 超时结算：过期邀请按拒绝处理，双方界面都收到状态刷新，之后再接受不生效。
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

-- 重连恢复：存档里的小队号还在、纪元是本轮的、那支队伍也还在（有队友在线、未满）就回到原队伍；
-- 号码对不上本轮纪元（上一轮开服的号）或队伍已经不在（离线自动离队后解散了）就把归属落回无队伍，
-- 并明确告诉玩家解散结果；队伍还在但满员给 'full'，与「原队已散」区分。
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
        -- 原队伍还在、只是满了：保留归属，等下一次空位——Leave / Disband 末尾的 RetryRestore
        -- 会替这名玩家重试（9-22）；回执与文案与解散分开。
        return 'full'
    end
    local ok = self:SavePartyId(player, 0)
    if not ok then return 'save-failed' end
    return 'disbanded'
end

-- #249 满员等待的重试时机（review：原注释写「下次有位置再谈恢复」却没有后续时机）：
-- 有存档归属、当前无队伍、且在线的玩家，在 Leave / Disband 空出位置（或队伍消失）之后各自重试一次。
-- skipUserId 排除正在离场的那名玩家：OnPlayerRemoving 里 Online 还没清，不能把他又恢复回队伍。
-- 重试仍失败（原队已散）时 Restore 自己把归属落回无队伍；满员仍返回 'full'，等下一次空位。
function Mgr:RetryRestore(skipUserId)
    local waiting = {}
    for userId, player in pairs(self.Online) do
        if userId ~= skipUserId and player and player.UserId == userId and not self.PartyOf[userId]
            and self:SavedParty(player) then
            waiting[#waiting + 1] = player
        end
    end
    -- pairs 无序：按 UserId 排序，恢复顺序与回执顺序可复现
    table.sort(waiting, function(a, b) return a.UserId < b.UserId end)
    local restored = 0
    for _, player in ipairs(waiting) do
        local result = self:Restore(player)
        if result == 'restored' then
            restored = restored + 1 -- Restore 内部已 PushParty(party, 'restored')
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
        -- 与其它交互同口径的限频：连点不会把服务端判定跑成批处理。
        if _G.REUtil.CheckRECD and _G.REUtil:CheckRECD(player, 'PartyAction', cfg().ActionCooldownSec) then return end
        self:Handle(player, payload)
    end)
    bind('PartyStateRequest', function(player)
        if _G.REUtil.CheckRECD and _G.REUtil:CheckRECD(player, 'PartyStateRequest', cfg().StateCooldownSec) then return end
        self:Push(player)
    end)
end

return Mgr
