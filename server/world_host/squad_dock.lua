
local GameCfg = require("common.game_cfg")
local Number = require("common.number")
local Spoke = require("common.packages.spoke.api")

local State = Spoke.State
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
    online = {},
    NextId = 0,
    Epoch = nil,
    waiting_restore = {},
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
    return Number.is_finite_number(value) and value or 0
  end

  local function fire(player, channel, payload)
    if not player or not opts.remote or type(opts.remote.get_re) ~= "function" then return end
    local ok, err = pcall(function()
      opts.remote:get_re(channel):FireClient(player, payload)
    end)
    if not ok then log_failure("下发 " .. channel, player, err) end
  end

  function self:party_id_of(player)
    local id = player and self.PartyOf[player.UserId]
    if id and self.Parties[id] then return id end
    return nil
  end

  function self:members(player)
    local party = self.Parties[self:party_id_of(player) or 0]
    local out = {}
    if not party then return out end
    for _, user_id in ipairs(party.Members) do
      local member = self.online[user_id]
      if member then out[#out + 1] = member end
    end
    return out
  end

  function self:Count(player)
    local party = self.Parties[self:party_id_of(player) or 0]
    return party and #party.Members or 0
  end

  function self:same_party(a, b)
    local id = a and self:party_id_of(a)
    return id ~= nil and b ~= nil and self:party_id_of(b) == id
  end

  function self:data_of(player)
    local player_data = opts.player_data
    if not player_data or not player or type(player_data.get_data_inst) ~= "function" then return nil end
    local ok, data = pcall(player_data.get_data_inst, player_data, player)
    if not ok then
      log_failure("读取玩家存档 GetDataInst", player, data)
      return nil
    end
    return data
  end

  function self:session_epoch()
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

  function self:save_party_id(player, id)
    local data = self:data_of(player)
    if not data or type(data.Extra) ~= "table" then
      log_failure("写入小队归属 SavePartyId", player, "玩家存档或 Extra 不可用")
      return false, "save-failed"
    end
    if type(data.Extra.party) ~= "table" then data.Extra.party = { id = 0 } end
    local party_id = id or 0
    data.Extra.party.id = party_id
    data.Extra.party.epoch = party_id > 0 and self:session_epoch() or nil
    return true
  end

  function self:saved_party(player)
    local data = self:data_of(player)
    local party = data and data.Extra and data.Extra.party
    local id = party and party.id
    if type(id) ~= "number" or id ~= math.floor(id) or id <= 0 then return nil end
    return id, type(party.epoch) == "string" and party.epoch or nil
  end

  local function party_effect_key(id) return "Squad:" .. tostring(id) end
  local function member_effect_key(id) return "Member:" .. tostring(id) end

  function self:push(player, notice)
    fire(player, "PartyState", self:snapshot_of(player, notice))
  end

  function self:push_party(party, notice)
    if not party or party.disbanded then return end
    for _, user_id in ipairs(copy_array(party.Members)) do
      local player = self.online[user_id]
      if player then self:push(player, notice) end
    end
  end

  function self:reply(player, action, ok, reason)
    fire(player, "PartyResult", { action = action, ok = ok == true, reason = reason })
  end

  local function mount_member(party, user_id)
    if not party.member_dock or party.disbanded then return end
    local key = member_effect_key(user_id)
    party.member_dock:drop(key)
    party.member_dock:effect(key, function(s)
      s:effect("ObservePlayerTree", function(es)
        local row = { phase = "alive" }
        local ok, err = pcall(function()
          local player = self.online[user_id]
          local tree = player and opts.lookup_tree and opts.lookup_tree(player)
          if not tree or tree:is_disposed() then return end
          row.health = es:d(tree.states.health)
          row.maxHealth = tree.memos.max_health and es:d(tree.memos.max_health) or GameCfg.Vitals.MaxHealth
          row.phase = es:d(tree.states.life_phase)
        end)
        if not ok then
          log_failure("跨树读取小队成员生命", self.online[user_id], err)
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
        self:push_party(party)
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

  function self:add_member(party, player)
    if self.PartyOf[player.UserId] then return false, "already-in-party" end
    local ok, reason = self:save_party_id(player, party.Id)
    if not ok then return false, reason or "save-failed" end
    party.Members[#party.Members + 1] = player.UserId
    self.PartyOf[player.UserId] = party.Id
    mount_member(party, player.UserId)
    return true
  end

  function self:remove_member(party, player)
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

  function self:snapshot_of(player, notice)
    local snapshot = { state = "none", members = {} }
    local party_id = self:party_id_of(player)
    local party = party_id and self.Parties[party_id]
    local invite = self.Invites[player.UserId]
    if invite then
      local left = math.max(0, math.ceil(invite.expires_at - now()))
      local from = self.online[invite.FromUserId]
      snapshot.invite = {
        fromUserId = invite.FromUserId,
        fromName = from and from.Name or nil,
        expiresInSec = left,
        expiresAt = invite.expires_at,
      }
    end
    if party then
      snapshot.state = "party"
      snapshot.partyId = party.Id
      local function row(user_id)
        local member = self.online[user_id]
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

  function self:invite(player, target_user_id)
    if type(target_user_id) ~= "number" then
      self:reply(player, "Invite", false, "invalid")
      return
    end
    if self:party_id_of(player) and self:Count(player) >= cfg().MaxMembers then
      self:reply(player, "Invite", false, "full")
      return
    end
    local target = self.online[target_user_id]
    if not target then self:reply(player, "Invite", false, "offline") return end
    if self:party_id_of(target) then self:reply(player, "Invite", false, "target-in-party") return end
    local distance = flat_distance(player, target)
    if not distance or distance > cfg().InviteRange then
      self:reply(player, "Invite", false, "too-far")
      return
    end
    self.Invites[target_user_id] = { FromUserId = player.UserId, expires_at = now() + cfg().InviteTimeoutSec }
    self:reply(player, "Invite", true)
    self:push(target)
  end

  function self:accept(player, from_user_id)
    local invite = self.Invites[player.UserId]
    if not invite then self:reply(player, "Accept", false, "no-invite") return end
    if invite.expires_at <= now() then
      self.Invites[player.UserId] = nil
      self:reply(player, "Accept", false, "expired")
      self:push(player)
      return
    end
    if type(from_user_id) == "number" and invite.FromUserId ~= from_user_id then
      self:reply(player, "Accept", false, "no-invite")
      return
    end
    local from = self.online[invite.FromUserId]
    if not from then
      self.Invites[player.UserId] = nil
      self:reply(player, "Accept", false, "offline")
      self:push(player)
      return
    end
    if self:party_id_of(player) then self:reply(player, "Accept", false, "already-in-party") return end
    local party = self.Parties[self:party_id_of(from) or 0]
    if party and #party.Members >= cfg().MaxMembers then
      self:reply(player, "Accept", false, "full")
      return
    end
    local created = false
    if not party then
      party = new_party()
      created = true
    end
    local ok, reason = true, nil
    if created then ok, reason = self:add_member(party, from) end
    if ok then ok, reason = self:add_member(party, player) end
    if not ok and created and self:party_id_of(from) then
      self:remove_member(party, from)
      self:save_party_id(from, 0)
    end
    if not ok then
      self:reply(player, "Accept", false, reason or "save-failed")
      if not self:party_id_of(from) and #party.Members == 0 then
        party.disbanded = true
        self.Parties[party.Id] = nil
        world.squads:drop(party_effect_key(party.Id))
      end
      self:push(player)
      self:push(from)
      return
    end
    self.Invites[player.UserId] = nil
    self:reply(player, "Accept", true)
    self:push_party(party, "joined")
  end

  function self:decline(player)
    local invite = self.Invites[player.UserId]
    if not invite then self:reply(player, "Decline", false, "no-invite") return end
    self.Invites[player.UserId] = nil
    self:reply(player, "Decline", true)
    self:push(player)
  end

  function self:disband(party, notice, skip_user_id)
    local previous = {}
    for _, user_id in ipairs(party.Members) do
      local member = self.online[user_id]
      if member then
        local ok, reason = self:save_party_id(member, 0)
        if not ok then
          for uid, saved in pairs(previous) do
            local rollback = self.online[uid]
            if rollback then self:save_party_id(rollback, saved) end
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
      local member = self.online[user_id]
      if member then
        self.Invites[member.UserId] = nil
        self:push(member, notice or "disbanded")
      end
    end
    world.squads:drop(party_effect_key(party.Id))
    return true
  end

  function self:retry_restore(skip_user_id)
    local waiting = self.waiting_restore
    self.waiting_restore = {}
    for _, user_id in ipairs(waiting) do
      if user_id ~= skip_user_id then
        local member = self.online[user_id]
        if member and not self:party_id_of(member) then self:restore(member) end
      end
    end
  end

  function self:leave(player, reason)
    local party_id = self:party_id_of(player)
    if not party_id then
      if reason ~= "offline" then self:reply(player, "Leave", true) end
      self:push(player)
      return true
    end
    local party = self.Parties[party_id]
    local removed_index = self:remove_member(party, player)
    if reason ~= "offline" then
      local ok, why = self:save_party_id(player, 0)
      if not ok then
        restore_member(party, player, removed_index)
        self:reply(player, "Leave", false, why)
        self:push_party(party)
        return false
      end
    end
    if #party.Members < cfg().MinMembers then
      local ok, why = self:disband(party, reason == "offline" and "disbanded" or "left", reason == "offline" and player.UserId or nil)
      if not ok then
        if reason == "offline" then
          self:push_party(party)
        else
          restore_member(party, player, removed_index)
          self:save_party_id(player, party.Id)
          self:push_party(party)
        end
        if reason ~= "offline" then self:reply(player, "Leave", false, why) end
        return false
      end
    else
      self:push_party(party)
      self:retry_restore()
    end
    if reason ~= "offline" then self:reply(player, "Leave", true) end
    self:push(player, "left")
    self:retry_restore(player.UserId)
    return true
  end

  function self:handle(player, payload)
    if not is_valid_player(player) or type(payload) ~= "table" then return false end
    local action = payload.action
    if action == "Invite" then self:invite(player, payload.targetUserId)
    elseif action == "Accept" then self:accept(player, payload.fromUserId)
    elseif action == "Decline" then self:decline(player)
    elseif action == "Leave" then self:leave(player)
    else return false end
    return true
  end

  function self:update()
    local expired = {}
    for user_id, invite in pairs(self.Invites) do
      if invite.expires_at <= now() then
        expired[#expired + 1] = user_id
        self.Invites[user_id] = nil
        self:reply(self.online[user_id], "Invite", false, "expired")
      end
    end
    for _, user_id in ipairs(expired) do self:push(self.online[user_id]) end
  end

  function self:restore(player)
    local saved_id, saved_epoch = self:saved_party(player)
    if not saved_id then self:push(player) return end
    local party = self.Parties[saved_id]
    if saved_epoch ~= self:session_epoch() or not party then
      if self:save_party_id(player, 0) then self:push(player, "disbanded") end
      return
    end
    if #party.Members >= cfg().MaxMembers then
      self.waiting_restore[#self.waiting_restore + 1] = player.UserId
      self:push(player, "full")
      return
    end
    local ok = self:add_member(party, player)
    if ok then
      self:push_party(party)
      self:push(player, "restored")
    else
      self:push(player, "save-failed")
    end
  end

  function self:on_player_added(player)
    if not is_valid_player(player) then return end
    self.online[player.UserId] = player
    self:restore(player)
  end

  function self:on_player_removing(player)
    if not is_valid_player(player) then return end
    local user_id = player.UserId
    if self:party_id_of(player) then self:leave(player, "offline") end
    local invite = self.Invites[user_id]
    if invite then
      self.Invites[user_id] = nil
      local from = self.online[invite.FromUserId]
      if from then self:push(from) end
    end
    for target_id, pending in pairs(self.Invites) do
      if pending.FromUserId == user_id then
        self.Invites[target_id] = nil
        local target = self.online[target_id]
        if target then self:push(target) end
      end
    end
    self.online[user_id] = nil
  end

  world.squad = self
  world.squads:effect("SquadRuntime", function(s)
    s:subscribe(world.clock.on_second, function() self:update() end)
  end)
  return self
end

return SquadDock
