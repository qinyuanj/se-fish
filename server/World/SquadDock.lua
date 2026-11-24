-- 全局小队动态集合（ADR-0032 / #314）。
-- SharedWorldTree 持有唯一 SquadDock；每个小队子域以 Dock 维护成员，直接只读观察
-- 各成员 PlayerTree 的 health / max_health / life_phase，不依赖玩家侧命令式回调。
-- PartyAction / PartyState 是既有协议名；权威归属、邀请、恢复与回滚均只在这里判定。

local GameCfg = require("common.GameCfg")
local Number = require("common.Number")
local spoke = require("common.packages.spoke.api")

local State = spoke.State
local SquadDock = {}

local function cfg() return GameCfg.Party end

local function is_object(value)
  local kind = type(value)
  return kind == "table" or kind == "userdata"
end

local function is_valid_player(player)
  return is_object(player) and player.UserId ~= nil
end

local function flat_distance(a, b)
  local ac, bc = a and a.Character, b and b.Character
  local ap, bp = ac and ac.Position, bc and bc.Position
  if not is_object(ap) or not is_object(bp) then return nil end
  local dx, dz = (ap.x or 0) - (bp.x or 0), (ap.z or 0) - (bp.z or 0)
  return math.sqrt(dx * dx + dz * dz)
end

local function copy_array(values)
  local out = {}
  for i, value in ipairs(values or {}) do out[i] = value end
  return out
end

function SquadDock.mount(world, opts)
  opts = type(opts) == "table" and opts or {}
  local self = {
    world = world,
    Parties = {},
    PartyOf = {},
    Invites = {},
    Online = {},
    NextId = 0,
    Epoch = nil,
    WaitingRestore = {},
  }

  local function log_failure(operation, player, err)
    local message = "[SquadDock] " .. tostring(operation) .. " 失败 (uid="
      .. tostring(player and player.UserId) .. "): " .. tostring(err)
    local logger = opts.logger
    if logger and type(logger.error) == "function" then
      pcall(logger.error, logger, message)
    else
      print(message)
    end
  end

  local function now()
    local value = world.clock.now()
    return Number.IsFiniteNumber(value) and value or 0
  end

  local function fire(player, channel, payload)
    if not player or not opts.remote or type(opts.remote.GetRE) ~= "function" then return end
    local ok, err = pcall(function()
      opts.remote:GetRE(channel):FireClient(player, payload)
    end)
    if not ok then log_failure("下发 " .. channel, player, err) end
  end

  function self:PartyIdOf(player)
    local id = player and self.PartyOf[player.UserId]
    if id and self.Parties[id] then return id end
    return nil
  end

  function self:Members(player)
    local party = self.Parties[self:PartyIdOf(player) or 0]
    local out = {}
    if not party then return out end
    for _, user_id in ipairs(party.Members) do
      local member = self.Online[user_id]
      if member then out[#out + 1] = member end
    end
    return out
  end

  function self:Count(player)
    local party = self.Parties[self:PartyIdOf(player) or 0]
    return party and #party.Members or 0
  end

  function self:SameParty(a, b)
    local id = a and self:PartyIdOf(a)
    return id ~= nil and b ~= nil and self:PartyIdOf(b) == id
  end

  function self:DataOf(player)
    local player_data = opts.player_data
    if not player_data or not player or type(player_data.GetDataInst) ~= "function" then return nil end
    local ok, data = pcall(player_data.GetDataInst, player_data, player)
    if not ok then
      log_failure("读取玩家存档 GetDataInst", player, data)
      return nil
    end
    return data
  end

  function self:SessionEpoch()
    if not self.Epoch then
      if type(opts.session_epoch) == "function" then
        local ok, value = pcall(opts.session_epoch)
        if ok and value ~= nil then self.Epoch = tostring(value) end
      elseif opts.session_epoch ~= nil then
        self.Epoch = tostring(opts.session_epoch)
      end
      self.Epoch = self.Epoch or (tostring(now()) .. ":" .. tostring({}))
    end
    return self.Epoch
  end

  function self:SavePartyId(player, id)
    local data = self:DataOf(player)
    if not data or type(data.Extra) ~= "table" then
      log_failure("写入小队归属 SavePartyId", player, "玩家存档或 Extra 不可用")
      return false, "save-failed"
    end
    if type(data.Extra.party) ~= "table" then data.Extra.party = { id = 0 } end
    local party_id = id or 0
    data.Extra.party.id = party_id
    data.Extra.party.epoch = party_id > 0 and self:SessionEpoch() or nil
    return true
  end

  function self:SavedParty(player)
    local data = self:DataOf(player)
    local party = data and data.Extra and data.Extra.party
    local id = party and party.id
    if type(id) ~= "number" or id ~= math.floor(id) or id <= 0 then return nil end
    return id, type(party.epoch) == "string" and party.epoch or nil
  end

  local function party_effect_key(id) return "Squad:" .. tostring(id) end
  local function member_effect_key(id) return "Member:" .. tostring(id) end

  function self:Push(player, notice)
    fire(player, "PartyState", self:SnapshotOf(player, notice))
  end

  function self:PushParty(party, notice)
    if not party or party.disbanded then return end
    for _, user_id in ipairs(copy_array(party.Members)) do
      local player = self.Online[user_id]
      if player then self:Push(player, notice) end
    end
  end

  function self:Reply(player, action, ok, reason)
    fire(player, "PartyResult", { action = action, ok = ok == true, reason = reason })
  end

  -- 每名成员一个只读观察 Effect；成员信号在同一 Spoke 批次变化时，revision 只触发一次下发。
  local function mount_member(party, user_id)
    if not party.member_dock or party.disbanded then return end
    local key = member_effect_key(user_id)
    party.member_dock:drop(key)
    party.member_dock:effect(key, function(s)
      s:effect("ObservePlayerTree", function(es)
        local row = { phase = "alive" }
        local ok, err = pcall(function()
          local player = self.Online[user_id]
          local tree = player and opts.lookup_tree and opts.lookup_tree(player)
          if not tree or tree:is_disposed() then return end
          row.health = es:d(tree.states.health)
          row.maxHealth = tree.memos.max_health and es:d(tree.memos.max_health) or GameCfg.Vitals.MaxHealth
          row.phase = es:d(tree.states.life_phase)
        end)
        if not ok then
          log_failure("跨树读取小队成员生命", self.Online[user_id], err)
          row = { phase = "alive" }
        end
        party.rows[user_id] = row
        if not party.disbanded then party.revision:set(party.revision:now() + 1) end
      end)
      s:on_cleanup(function()
        party.rows[user_id] = nil
        if not party.disbanded then party.revision:set(party.revision:now() + 1) end
      end)
    end)
  end

  local function mount_party(party)
    world.squads:effect(party_effect_key(party.Id), function(s)
      party.member_dock = s:dock("SquadMembers")
      s:reaction("MergedPartyState", function()
        self:PushParty(party)
      end, { party.revision })
      for _, user_id in ipairs(party.Members) do mount_member(party, user_id) end
      s:on_cleanup(function()
        party.member_dock = nil
        party.rows = {}
      end)
    end)
  end

  local function new_party()
    self.NextId = self.NextId + 1
    local party = { Id = self.NextId, Members = {}, rows = {}, revision = State.new("SquadDock.revision", 0) }
    self.Parties[party.Id] = party
    mount_party(party)
    return party
  end

  function self:AddMember(party, player)
    if self.PartyOf[player.UserId] then return false, "already-in-party" end
    local ok, reason = self:SavePartyId(player, party.Id)
    if not ok then return false, reason or "save-failed" end
    party.Members[#party.Members + 1] = player.UserId
    self.PartyOf[player.UserId] = party.Id
    mount_member(party, player.UserId)
    return true
  end

  function self:RemoveMember(party, player)
    local removed_index
    for index, user_id in ipairs(party.Members) do
      if user_id == player.UserId then
        table.remove(party.Members, index)
        removed_index = index
        break
      end
    end
    self.PartyOf[player.UserId] = nil
    if party.member_dock then party.member_dock:drop(member_effect_key(player.UserId)) end
    party.rows[player.UserId] = nil
    return removed_index
  end

  local function restore_member(party, player, index)
    table.insert(party.Members, math.min(index or (#party.Members + 1), #party.Members + 1), player.UserId)
    self.PartyOf[player.UserId] = party.Id
    mount_member(party, player.UserId)
  end

  function self:SnapshotOf(player, notice)
    local snapshot = { state = "none", members = {} }
    local party_id = self:PartyIdOf(player)
    local party = party_id and self.Parties[party_id]
    local invite = self.Invites[player.UserId]
    if invite then
      local left = math.max(0, math.ceil(invite.ExpiresAt - now()))
      local from = self.Online[invite.FromUserId]
      snapshot.invite = {
        fromUserId = invite.FromUserId,
        fromName = from and from.Name or nil,
        expiresInSec = left,
        expiresAt = invite.ExpiresAt,
      }
    end
    if party then
      snapshot.state = "party"
      snapshot.partyId = party.Id
      local function row(user_id)
        local member = self.Online[user_id]
        if not member then return nil end
        local health = party.rows[user_id] or {}
        return {
          userId = user_id, name = member.Name or tostring(user_id),
          health = health.health, maxHealth = health.maxHealth,
          phase = health.phase or "alive", self = user_id == player.UserId,
        }
      end
      local mine = row(player.UserId)
      if mine then snapshot.members[#snapshot.members + 1] = mine end
      for _, user_id in ipairs(party.Members) do
        if user_id ~= player.UserId then
          local other = row(user_id)
          if other then snapshot.members[#snapshot.members + 1] = other end
        end
      end
    end
    if notice then snapshot.notice = notice end
    return snapshot
  end

  function self:Invite(player, target_user_id)
    if type(target_user_id) ~= "number" then
      self:Reply(player, "Invite", false, "invalid")
      return
    end
    if self:PartyIdOf(player) and self:Count(player) >= cfg().MaxMembers then
      self:Reply(player, "Invite", false, "full")
      return
    end
    local target = self.Online[target_user_id]
    if not target then self:Reply(player, "Invite", false, "offline") return end
    if self:PartyIdOf(target) then self:Reply(player, "Invite", false, "target-in-party") return end
    local distance = flat_distance(player, target)
    if not distance or distance > cfg().InviteRange then
      self:Reply(player, "Invite", false, "too-far")
      return
    end
    self.Invites[target_user_id] = { FromUserId = player.UserId, ExpiresAt = now() + cfg().InviteTimeoutSec }
    self:Reply(player, "Invite", true)
    self:Push(target)
  end

  function self:Accept(player, from_user_id)
    local invite = self.Invites[player.UserId]
    if not invite then self:Reply(player, "Accept", false, "no-invite") return end
    if invite.ExpiresAt <= now() then
      self.Invites[player.UserId] = nil
      self:Reply(player, "Accept", false, "expired")
      self:Push(player)
      return
    end
    if type(from_user_id) == "number" and invite.FromUserId ~= from_user_id then
      self:Reply(player, "Accept", false, "no-invite")
      return
    end
    local from = self.Online[invite.FromUserId]
    if not from then
      self.Invites[player.UserId] = nil
      self:Reply(player, "Accept", false, "offline")
      self:Push(player)
      return
    end
    if self:PartyIdOf(player) then self:Reply(player, "Accept", false, "already-in-party") return end
    local party = self.Parties[self:PartyIdOf(from) or 0]
    if party and #party.Members >= cfg().MaxMembers then
      self:Reply(player, "Accept", false, "full")
      return
    end
    local created = false
    if not party then
      party = new_party()
      created = true
    end
    local ok, reason = true, nil
    if created then ok, reason = self:AddMember(party, from) end
    if ok then ok, reason = self:AddMember(party, player) end
    if not ok and created and self:PartyIdOf(from) then
      self:RemoveMember(party, from)
      self:SavePartyId(from, 0)
    end
    if not ok then
      self:Reply(player, "Accept", false, reason or "save-failed")
      if not self:PartyIdOf(from) and #party.Members == 0 then
        party.disbanded = true
        self.Parties[party.Id] = nil
        world.squads:drop(party_effect_key(party.Id))
      end
      self:Push(player)
      self:Push(from)
      return
    end
    self.Invites[player.UserId] = nil
    self:Reply(player, "Accept", true)
    self:PushParty(party, "joined")
  end

  function self:Decline(player)
    local invite = self.Invites[player.UserId]
    if not invite then self:Reply(player, "Decline", false, "no-invite") return end
    self.Invites[player.UserId] = nil
    self:Reply(player, "Decline", true)
    self:Push(player)
  end

  function self:Disband(party, notice, skip_user_id)
    local previous = {}
    for _, user_id in ipairs(party.Members) do
      local member = self.Online[user_id]
      if member then
        local ok, reason = self:SavePartyId(member, 0)
        if not ok then
          for uid, saved in pairs(previous) do
            local rollback = self.Online[uid]
            if rollback then self:SavePartyId(rollback, saved) end
          end
          return false, reason or "save-failed"
        end
        previous[user_id] = party.Id
      end
    end
    party.disbanded = true
    self.Parties[party.Id] = nil
    for _, user_id in ipairs(party.Members) do
      if user_id ~= skip_user_id then self.PartyOf[user_id] = nil end
      local member = self.Online[user_id]
      if member then
        self.Invites[member.UserId] = nil
        self:Push(member, notice or "disbanded")
      end
    end
    world.squads:drop(party_effect_key(party.Id))
    return true
  end

  function self:RetryRestore(skip_user_id)
    local waiting = self.WaitingRestore
    self.WaitingRestore = {}
    for _, user_id in ipairs(waiting) do
      if user_id ~= skip_user_id then
        local member = self.Online[user_id]
        if member and not self:PartyIdOf(member) then self:Restore(member) end
      end
    end
  end

  function self:Leave(player, reason)
    local party_id = self:PartyIdOf(player)
    if not party_id then
      if reason ~= "offline" then self:Reply(player, "Leave", true) end
      self:Push(player)
      return true
    end
    local party = self.Parties[party_id]
    local removed_index = self:RemoveMember(party, player)
    if reason ~= "offline" then
      local ok, why = self:SavePartyId(player, 0)
      if not ok then
        restore_member(party, player, removed_index)
        self:Reply(player, "Leave", false, why)
        self:PushParty(party)
        return false
      end
    end
    if #party.Members < cfg().MinMembers then
      local ok, why = self:Disband(party, reason == "offline" and "disbanded" or "left", reason == "offline" and player.UserId or nil)
      if not ok then
        if reason == "offline" then
          -- 引擎离场不可回滚；只阻止解散清档提交，剩余成员仍看到最新在线名单。
          self:PushParty(party)
        else
          restore_member(party, player, removed_index)
          self:SavePartyId(player, party.Id)
          self:PushParty(party)
        end
        if reason ~= "offline" then self:Reply(player, "Leave", false, why) end
        return false
      end
    else
      self:PushParty(party)
      self:RetryRestore()
    end
    if reason ~= "offline" then self:Reply(player, "Leave", true) end
    self:Push(player, "left")
    self:RetryRestore(player.UserId)
    return true
  end

  function self:Handle(player, payload)
    if not is_valid_player(player) or type(payload) ~= "table" then return false end
    local action = payload.action
    if action == "Invite" then self:Invite(player, payload.targetUserId)
    elseif action == "Accept" then self:Accept(player, payload.fromUserId)
    elseif action == "Decline" then self:Decline(player)
    elseif action == "Leave" then self:Leave(player)
    else return false end
    return true
  end

  function self:Update()
    local expired = {}
    for user_id, invite in pairs(self.Invites) do
      if invite.ExpiresAt <= now() then
        expired[#expired + 1] = user_id
        self.Invites[user_id] = nil
        self:Reply(self.Online[user_id], "Invite", false, "expired")
      end
    end
    for _, user_id in ipairs(expired) do self:Push(self.Online[user_id]) end
  end

  function self:Restore(player)
    local saved_id, saved_epoch = self:SavedParty(player)
    if not saved_id then self:Push(player) return end
    local party = self.Parties[saved_id]
    if saved_epoch ~= self:SessionEpoch() or not party then
      if self:SavePartyId(player, 0) then self:Push(player, "disbanded") end
      return
    end
    if #party.Members >= cfg().MaxMembers then
      self.WaitingRestore[#self.WaitingRestore + 1] = player.UserId
      self:Push(player, "full")
      return
    end
    local ok = self:AddMember(party, player)
    if ok then
      self:PushParty(party)
      self:Push(player, "restored")
    else
      self:Push(player, "save-failed")
    end
  end

  function self:OnPlayerAdded(player)
    if not is_valid_player(player) then return end
    self.Online[player.UserId] = player
    self:Restore(player)
  end

  function self:OnPlayerRemoving(player)
    if not is_valid_player(player) then return end
    local user_id = player.UserId
    if self:PartyIdOf(player) then self:Leave(player, "offline") end
    local invite = self.Invites[user_id]
    if invite then
      self.Invites[user_id] = nil
      local from = self.Online[invite.FromUserId]
      if from then self:Push(from) end
    end
    for target_id, pending in pairs(self.Invites) do
      if pending.FromUserId == user_id then
        self.Invites[target_id] = nil
        local target = self.Online[target_id]
        if target then self:Push(target) end
      end
    end
    self.Online[user_id] = nil
  end

  world.squad = self
  world.squads:effect("SquadRuntime", function(s)
    s:subscribe(world.clock.on_second, function() self:Update() end)
  end)
  return self
end

return SquadDock
