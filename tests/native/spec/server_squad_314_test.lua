
local GameCfg = require("common.game_cfg")
local ServerRuntime = require("server.world_host.server_runtime")

local function signal()
  local handlers = {}
  return {
    Connect = function(_, fn)
      handlers[#handlers + 1] = fn
      return { Disconnect = function()
        for i, h in ipairs(handlers) do
          if h == fn then table.remove(handlers, i) return end
        end
      end }
    end,
    Fire = function(_, ...)
      for _, fn in ipairs({ table.unpack(handlers) }) do fn(...) end
    end,
  }
end

local function make_player(id, x, z)
  local controller = {
    Health = GameCfg.Vitals.MaxHealth, MaxHealth = GameCfg.Vitals.MaxHealth, WalkSpeed = 16,
    HealthChanged = signal(), Died = signal(), OnReborn = signal(),
  }
  function controller:TakeDamage(amount)
    self.Health = math.max(0, self.Health - amount)
    self.HealthChanged:Fire(self.Health)
    if self.Health <= 0 then self.Died:Fire() end
  end
  function controller:Reborn() self.Health = self.MaxHealth self.OnReborn:Fire() end
  local player = {
    UserId = id, Name = "玩家" .. tostring(id), attrs = {}, CharacterAdded = signal(),
    Character = { Controller = controller, Position = { x = x or 100, y = 0, z = z or 0 }, Size = { y = 2 } },
  }
  function player:SetAttribute(key, value) self.attrs[key] = value end
  function player:GetAttribute(key) return self.attrs[key] end
  return player
end

local function make_data(player, saved_party)
  return {
    Player = player, Inited = true, LoadState = "ready",
    Data = { FishCoin = 0, Zone = "shrimpPond", Containers = {} },
    Extra = {
      growth = { potions = {}, upgrades = {} },
      survival = { health = GameCfg.Vitals.MaxHealth, hunger = GameCfg.Vitals.MaxHunger },
      party = saved_party,
    },
  }
end

local function make_save()
  local seq = 0
  return {
    ResolveRequest = function(_, player, _, kind, request_id)
      if type(request_id) ~= "number" then return nil end
      seq = seq + 1
      return { id = tostring(player.UserId) .. ":" .. seq, sequence = seq, kind = kind,
        requestKey = kind .. ":" .. tostring(request_id) }, "new"
    end,
    Execute = function(_, _, _, _, transform, done)
      local ok, result, reason = pcall(transform)
      if not ok or type(result) ~= "table" then done(false, ok and reason or tostring(result))
      else done(true, result) end
      return true
    end,
  }
end

local function boot(ids, options)
  options = options or {}
  local ctx = { players = {}, data = {}, events = {}, printed = {} }
  local function event(name)
    ctx.events[name] = ctx.events[name] or {
      clients = {}, OnServerEvent = signal(),
      FireClient = function(self, player, payload)
        self.clients[#self.clients + 1] = { player = player, value = payload }
      end,
      FireAllClients = function(self, payload)
        self.clients[#self.clients + 1] = { player = "all", value = payload }
      end,
    }
    return ctx.events[name]
  end
  local re = { GetRE = function(_, name) return event(name) end, CheckRECD = function() return false end }
  ctx.re = re
  for _, id in ipairs(ids or { 1, 2 }) do
    local player = make_player(id, 100 + id, 0)
    ctx.players[id] = player
    ctx.data[id] = make_data(player, options.saved and options.saved[id] or nil)
  end
  ctx.runtime = ServerRuntime.new({
    initial_now = 100, remote = re,
    player_data = { GetDataInst = function(_, player)
      if ctx.fail_read == player.UserId then error(ctx.fail_reason or "party-save-unavailable") end
      return ctx.data[player.UserId]
    end },
    save = make_save(), bait_spots = { Enabled = false },
    session_epoch = options.session_epoch or "session-314",
    logger = { error = function(_, message) ctx.printed[#ctx.printed + 1] = message end },
    bind_party_action = function(dispatch)
      event("PartyAction").OnServerEvent:Connect(function(player, payload) dispatch(player, payload) end)
    end,
    bind_party_state_request = function(dispatch)
      event("PartyStateRequest").OnServerEvent:Connect(function(player) dispatch(player) end)
    end,
    bind_interact_action = function(dispatch)
      event("InteractAction").OnServerEvent:Connect(function(player, payload) dispatch(player, payload) end)
    end,
  })
  ctx.runtime:start()
  ctx.runtime:mark_started()
  function ctx:join(id)
    local player = self.players[id]
    self.runtime:on_player_added(player)
    return self.runtime:on_save_ready(player, self.data[id])
  end
  function ctx:join_all() for _, id in ipairs(ids or { 1, 2 }) do self:join(id) end end
  function ctx:action(id, action, fields)
    local payload = { action = action }
    for key, value in pairs(fields or {}) do payload[key] = value end
    self.events.PartyAction.OnServerEvent:Fire(self.players[id], payload)
  end
  function ctx:make_party(a, b)
    self:action(a, "Invite", { targetUserId = b })
    self:action(b, "Accept", { fromUserId = a })
  end
  function ctx:state(id)
    local found
    for _, row in ipairs(self.events.PartyState and self.events.PartyState.clients or {}) do
      if row.player == self.players[id] then found = row.value end
    end
    return found
  end
  function ctx:result(id)
    local found
    for _, row in ipairs(self.events.PartyResult and self.events.PartyResult.clients or {}) do
      if row.player == self.players[id] then found = row.value end
    end
    return found
  end
  function ctx:member(id, member_id)
    local state = self:state(id)
    for _, row in ipairs(state and state.members or {}) do
      if row.userId == member_id then return row end
    end
    return nil
  end
  function ctx:hit(source, target, amount)
    return self.runtime.life:ApplyHit(self.runtime.life:NewHit(source, "melee"), target, amount)
  end
  function ctx:close() if self.runtime then self.runtime:shutdown() end self.runtime = nil end
  ctx:join_all()
  return ctx
end

local function party_id(ctx, id)
  local state = ctx:state(id)
  return state and state.state == "party" and state.partyId or nil
end

describe("全局小队服务端宿主接缝（#314）", function()
  local ctx
  after_each(function() if ctx then ctx:close() ctx = nil end end)

  it("9-06/9-19 三人上限与拒绝邀请都由服务端权威判定", function()
    ctx = boot({ 1, 2, 3, 4 })
    ctx:make_party(1, 2)
    ctx:make_party(1, 3)
    assert.equals("party", ctx:state(3).state)
    ctx:action(1, "Invite", { targetUserId = 4 })
    assert.is_false(ctx:result(1).ok)
    assert.equals("full", ctx:result(1).reason)
    assert.equals("none", ctx:state(4).state)
    ctx:action(4, "Accept", { fromUserId = 1, partyId = party_id(ctx, 1), members = { 1, 2, 3, 4 } })
    assert.is_false(ctx:result(4).ok)
    assert.equals("none", ctx:state(4).state)
  end)

  it("9-02 客户端载荷不能替别人离队或改写小队名单", function()
    ctx = boot({ 1, 2, 3 })
    ctx:make_party(1, 2)
    local id = party_id(ctx, 1)
    ctx:action(2, "Invite", { targetUserId = 3, partyId = id, members = { 2, 3 } })
    ctx:action(3, "Accept", { fromUserId = 2, partyId = id, members = { 2, 3 } })
    assert.equals(id, party_id(ctx, 3))
    ctx:action(2, "Leave", { targetUserId = 1, partyId = 999, members = {} })
    assert.is_nil(party_id(ctx, 2))
    assert.equals(id, party_id(ctx, 1))
    assert.equals(id, party_id(ctx, 3))
  end)

  it("9-07 只有两米内能邀请，超距不建立待处理邀请", function()
    ctx = boot({ 1, 2 })
    ctx.players[2].Character.Position.x = 104
    ctx:action(1, "Invite", { targetUserId = 2 })
    assert.is_false(ctx:result(1).ok)
    assert.equals("too-far", ctx:result(1).reason)
    assert.is_nil(ctx:state(2).invite)
    ctx.players[2].Character.Position.x = 101
    ctx:action(1, "Invite", { targetUserId = 2 })
    assert.equals(1, ctx:state(2).invite.fromUserId)
  end)

  it("9-08 邀请十秒到期后接受无效，拒绝立即清除", function()
    ctx = boot({ 1, 2 })
    ctx:action(1, "Invite", { targetUserId = 2 })
    ctx.runtime:step(9.5, 109.5)
    assert.is_not_nil(ctx:state(2).invite)
    ctx.runtime:step(0.5, 110)
    assert.is_nil(ctx:state(2).invite)
    ctx:action(2, "Accept")
    assert.is_false(ctx:result(2).ok)
    assert.equals("none", ctx:state(2).state)
    ctx:action(1, "Invite", { targetUserId = 2 })
    ctx:action(2, "Decline")
    assert.is_nil(ctx:state(2).invite)
    assert.is_nil(party_id(ctx, 2))
  end)

  it("9-09/9-10/9-11 主动与离线退队即时生效，同队 PK 免伤直接读取新关系", function()
    ctx = boot({ 1, 2, 3 })
    ctx:make_party(1, 2)
    ctx:make_party(1, 3)
    assert.is_false(ctx:hit(ctx.players[1], ctx.players[2], 20))
    assert.equals(GameCfg.Vitals.MaxHealth, ctx.players[2].Character.Controller.Health)
    ctx:action(2, "Leave")
    assert.is_true(ctx:hit(ctx.players[1], ctx.players[2], 20))
    assert.equals(GameCfg.Vitals.MaxHealth - 20, ctx.players[2].Character.Controller.Health)
    assert.equals("party", ctx:state(1).state)
    ctx.runtime:on_player_removing(ctx.players[3])
    assert.equals("none", ctx:state(1).state)
    assert.equals(0, ctx.data[1].Extra.party.id)
  end)

  it("9-20 小队子域自动汇总血量与濒死相位，并沿用两秒抢救", function()
    ctx = boot({ 1, 2 })
    ctx:make_party(1, 2)
    assert.is_true(ctx:hit(nil, ctx.players[2], 20))
    assert.equals(GameCfg.Vitals.MaxHealth - 20, ctx:member(1, 2).health)
    assert.equals("alive", ctx:member(1, 2).phase)
    assert.is_true(ctx:hit(nil, ctx.players[2], 999))
    assert.equals(1, ctx:member(1, 2).health)
    assert.equals("downed", ctx:member(1, 2).phase)
    ctx.events.InteractAction.OnServerEvent:Fire(ctx.players[1], {
      target = GameCfg.Rescue.Target, action = GameCfg.Rescue.Action, targetUserId = 2, seq = 1,
    })
    assert.equals("rescuing", ctx:member(1, 2).phase)
    ctx.runtime:step(2.01, 102.01)
    assert.equals("alive", ctx:member(1, 2).phase)
    assert.equals(math.floor(GameCfg.Vitals.MaxHealth * GameCfg.Survival.ReviveHealthPercent / 100),
      ctx:member(1, 2).health)
  end)

  it("单名成员树拆除不妨碍其余成员继续收到自己的实时快照", function()
    ctx = boot({ 1, 2 })
    ctx:make_party(1, 2)
    ctx.runtime:get_player_tree(2):dispose()
    assert.is_true(ctx:hit(nil, ctx.players[1], 15))
    assert.equals(GameCfg.Vitals.MaxHealth - 15, ctx:member(1, 1).health)
    assert.is_false(ctx.runtime.world:is_faulted())
    assert.equals("party", ctx:state(1).state)
  end)

  it("9-22 离线保留归属，重连恢复原队；不足两人解散后明确清档", function()
    ctx = boot({ 1, 2, 3 })
    ctx:make_party(1, 2)
    ctx:make_party(1, 3)
    local id = party_id(ctx, 1)
    assert.equals(id, ctx.data[3].Extra.party.id)
    assert.equals("session-314", ctx.data[3].Extra.party.epoch)
    ctx.runtime:on_player_removing(ctx.players[3])
    local back = make_player(3, 103, 0)
    ctx.players[3] = back
    ctx.data[3].Player = back
    ctx:join(3)
    assert.equals(id, party_id(ctx, 3))
    assert.equals("restored", ctx:state(3).notice)
    ctx.runtime:on_player_removing(ctx.players[2])
    ctx.runtime:on_player_removing(ctx.players[1])
    assert.equals("none", ctx:state(3).state)
    local again = make_player(2, 102, 0)
    ctx.players[2] = again
    ctx.data[2].Player = again
    ctx:join(2)
    assert.equals("disbanded", ctx:state(2).notice)
    assert.equals(0, ctx.data[2].Extra.party.id)
  end)

  it("9-22 原队满员返回 full，空位出现后自动恢复", function()
    ctx = boot({ 1, 2, 3, 4 })
    ctx:make_party(1, 2)
    ctx:make_party(1, 3)
    local id = party_id(ctx, 1)
    ctx.runtime:on_player_removing(ctx.players[3])
    ctx.players[4].Character.Position.x = 102
    ctx:make_party(1, 4)
    local back = make_player(3, 103, 0)
    ctx.players[3] = back
    ctx.data[3].Player = back
    ctx:join(3)
    assert.equals("full", ctx:state(3).notice)
    assert.equals(id, ctx.data[3].Extra.party.id)
    ctx:action(2, "Leave")
    assert.equals(id, party_id(ctx, 3))
    assert.equals("restored", ctx:state(3).notice)
  end)

  it("9-22 跨会话相同小队号不能恢复进陌生小队", function()
    ctx = boot({ 1, 2 }, { session_epoch = "session-old" })
    ctx:make_party(1, 2)
    local saved_id = party_id(ctx, 1)
    local saved = { id = saved_id, epoch = "session-old" }
    ctx:close()
    ctx = boot({ 3, 4, 1 }, { session_epoch = "session-new", saved = { [1] = saved } })
    ctx:make_party(3, 4)
    assert.equals(saved_id, party_id(ctx, 3))
    assert.equals("disbanded", ctx:state(1).notice)
    assert.equals(0, ctx.data[1].Extra.party.id)
    assert.equals(saved_id, party_id(ctx, 3))
  end)

  it("9-22 入队与离队清档失败完整回滚，修复后可重试并记录原因", function()
    ctx = boot({ 1, 2 })
    ctx:action(1, "Invite", { targetUserId = 2 })
    ctx.fail_read = 2
    ctx:action(2, "Accept")
    ctx.fail_read = nil
    assert.is_false(ctx:result(2).ok)
    assert.equals("save-failed", ctx:result(2).reason)
    assert.is_nil(party_id(ctx, 1))
    assert.is_nil(party_id(ctx, 2))
    assert.equals(0, ctx.data[1].Extra.party.id)
    local logged = table.concat(ctx.printed, "\n")
    assert.is_truthy(logged:find("SquadDock", 1, true))
    assert.is_truthy(logged:find("party%-save%-unavailable"))
    ctx:action(1, "Invite", { targetUserId = 2 })
    ctx:make_party(1, 2)
    local id = party_id(ctx, 1)
    ctx.fail_read = 1
    ctx:action(2, "Leave")
    ctx.fail_read = nil
    assert.is_false(ctx:result(2).ok)
    assert.equals(id, party_id(ctx, 1))
    assert.equals(id, party_id(ctx, 2))
    assert.equals(id, ctx.data[2].Extra.party.id)
    ctx:action(2, "Leave")
    assert.is_true(ctx:result(2).ok)
    assert.is_nil(party_id(ctx, 1))
    assert.is_nil(party_id(ctx, 2))
  end)

  it("9-09 离线解散清档失败仍刷新剩余成员快照，不保留离线者", function()
    ctx = boot({ 1, 2 })
    ctx:make_party(1, 2)
    local id = party_id(ctx, 1)
    ctx.fail_read = 1
    ctx.runtime:on_player_removing(ctx.players[2])
    ctx.fail_read = nil
    assert.equals("party", ctx:state(1).state)
    assert.equals(id, party_id(ctx, 1))
    assert.equals(1, #ctx:state(1).members)
    assert.equals(1, ctx:state(1).members[1].userId)
  end)

  it("兼容 SE 引擎 userdata 玩家与 userdata Position 完成入队、邀请、建队与离场", function()
    local SharedWorldTree = require("server.world_host.shared_world_tree")
    local SpokeClock = require("common.spoke_clock")
    local clock = SpokeClock.new(100)
    local events = {}
    local function channel(name)
      events[name] = events[name] or {
        clients = {},
        FireClient = function(self, player, payload)
          self.clients[#self.clients + 1] = { player = player, value = payload }
        end,
      }
      return events[name]
    end
    local p1 = make_player(701, 100, 0)
    local p2 = make_player(702, 101, 0)
    local datas = {
      [701] = make_data(p1),
      [702] = make_data(p2),
    }
    local world = SharedWorldTree.spawn({
      clock = clock,
      remote = { GetRE = function(_, name) return channel(name) end },
      player_data = { GetDataInst = function(_, player) return datas[player.UserId] end },
      session_epoch = "userdata-squad-test",
    })
    local userdata_objects = {
      [p1] = true,
      [p2] = true,
      [p1.Character.Position] = true,
      [p2.Character.Position] = true,
    }
    local real_type = _G.type
    local ok, err = pcall(function()
      _G.type = function(value)
        if userdata_objects[value] then return "userdata" end
        return real_type(value)
      end
      world.squad:OnPlayerAdded(p1)
      world.squad:OnPlayerAdded(p2)
      assert.is_true(world.squad:Handle(p1, { action = "Invite", targetUserId = 702 }))
      assert.is_true(world.squad:Handle(p2, { action = "Accept", fromUserId = 701 }))
      assert.is_true(world.squad:SameParty(p1, p2))
      assert.equals(2, world.squad:Count(p1))
      world.squad:OnPlayerRemoving(p2)
      assert.is_false(world.squad:SameParty(p1, p2))
      assert.equals(0, world.squad:Count(p1))
    end)
    _G.type = real_type
    world:dispose()
    if not ok then error(err, 0) end
  end)
end)
