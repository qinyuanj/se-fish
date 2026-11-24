
local GameCfg = require("common.game_cfg")
local Spoke = require("common.packages.spoke.api")
local SpokeRuntime = require("common.packages.spoke.runtime.spoke_runtime")

local LambdaEpoch = Spoke.LambdaEpoch
local Effect = Spoke.Effect
local State = Spoke.State

local FerryRoute = {}

local function is_object(value)
  local kind = type(value)
  return kind == "table" or kind == "userdata"
end

local function is_valid_player(player)
  return is_object(player) and player.UserId ~= nil
end

local function flat_distance(a, b)
  local dx, dz = a.x - b.x, a.z - b.z
  return math.sqrt(dx * dx + dz * dz)
end

local function mark_arrival(draft, zone)
  local arrived = draft.Extra.travel.arrived
  arrived[zone] = (arrived[zone] or 0) + 1
end

function FerryRoute.mount(world, opts)
  opts = type(opts) == "table" and opts or {}
  local remote = opts.remote
  local player_data = opts.player_data
  local save = opts.save
  local interact = opts.interact
  local players_service = opts.players_service
  local lookup_tree = opts.lookup_tree
  local handle = {
    LastSeq = {},
    Recoveries = {},
    ReturnPending = {},
    Flights = {},
    BoardPending = {},
    disposed = false,
  }
  local route_states = {}
  local route_sailing = {}
  local left_players = setmetatable({}, { __mode = "v" })
  local recovery_watch_users = {}
  local recovery_watch_active = State.new("FerryRoute.recovery_watch", false)

  local function log(...)
    print("[FerryRoute]", ...)
  end

  local function event(name)
    if not is_object(remote) or type(remote.get_re) ~= "function" then return nil end
    local ok, value = pcall(remote.get_re, remote, name)
    return ok and value or nil
  end

  function handle:reply(player, payload)
    local channel = event("FerryResult")
    if channel and type(channel.FireClient) == "function" then channel:FireClient(player, payload) end
  end

  function handle:broadcast(payload)
    local channel = event("FerryState")
    if channel and type(channel.FireAllClients) == "function" then channel:FireAllClients(payload) end
  end

  function handle:Fail(player, action, reason)
    log("请求拒绝", player and player.UserId, action, tostring(reason))
    self:reply(player, { ok = false, action = action, reason = reason })
    return false
  end

  function handle:online_players()
    if type(opts.online_players) == "function" then return opts.online_players() end
    if players_service and type(players_service.GetPlayers) == "function" then
      local ok, list = pcall(players_service.GetPlayers, players_service)
      if ok and type(list) == "table" then return list end
    end
    return {}
  end

  local function data_of(player)
    if not player_data or type(player_data.get_data_inst) ~= "function" then return nil end
    local ok, data = pcall(player_data.get_data_inst, player_data, player)
    return ok and data or nil
  end

  local function is_paused(user_id)
    return save ~= nil and type(save.is_paused) == "function" and save:is_paused(user_id) or false
  end

  local function sync_tree(player, data)
    if type(lookup_tree) ~= "function" then return end
    local tree = lookup_tree(player)
    if tree and type(tree.sync_from_data) == "function" then
      local ok, err = pcall(tree.sync_from_data, tree, data)
      if not ok then log("同步玩家树失败", player and player.UserId, tostring(err)) end
    end
  end

  function handle:teleport(player, dest)
    local character = player and player.Character
    if not character then
      log("传送失败", player and player.UserId, "角色缺失")
      return false
    end
    local tree = type(lookup_tree) == "function" and lookup_tree(player) or nil
    if tree and type(tree.suspend_special_item) == "function" then
      local ok, err = pcall(tree.suspend_special_item, tree)
      if not ok then log("特殊道具挂起失败", player.UserId, tostring(err)) end
    end
    local ok, err = pcall(function()
      local pos = Vector3.New(dest.x, dest.y, dest.z)
      if character.SetPosition then
        character:SetPosition(pos)
      else
        character.Position = pos
      end
    end)
    if not ok then log("传送失败", player.UserId, tostring(err)) end
    return ok
  end

  function handle:settle(player, data, kind, transform, done, operation)
    if not save or type(save.next_operation) ~= "function" or type(save.execute) ~= "function" then
      return false, "save"
    end
    operation = operation or save:next_operation(player, kind)
    if not operation then return false, "save" end
    local outcome
    local accepted, reason = save:execute(player, data, operation, transform, function(ok, result)
      outcome = ok
      if not ok then log("结算失败", player.UserId, operation.id, kind, tostring(result)) end
      done(ok, result)
    end)
    if not accepted then log("结算未接纳", player.UserId, operation.id, kind, tostring(reason)) end
    return accepted and outcome ~= false, reason
  end

  function handle:pending_flight(route_id)
    return self.BoardPending[route_id] or self.Flights[route_id]
  end

  function handle:finish_travel(player, data, record, delivered, reason, done)
    return self:settle(player, data, delivered and "ferry:confirm" or "ferry:refund", function(draft)
      local pending = draft.Extra.recovery.ferry
      if not pending or pending.operation ~= record.operation then return nil, "recovery" end
      if delivered then
        if record.zone then
          draft:SetZone(record.zone)
          mark_arrival(draft, record.zone)
        end
      elseif record.action == "Board" then
        if not draft:AddItem(record.ticket) then return nil, "full" end
      elseif not draft:AddCoin(record.price, nil, "ferry:return:refund") then
        return nil, "coin"
      end
      draft.Extra.recovery.ferry = nil
      local result = { ok = delivered, action = record.action, routeId = record.routeId,
        price = record.price, operation = record.identity, reason = not delivered and reason or nil }
      local finals = {}
      for _, prior in ipairs(draft.SaveMeta.operations) do
        local kept = draft.Extra.recovery.ferryFinal and draft.Extra.recovery.ferryFinal[prior.id]
        if kept then finals[prior.id] = kept end
      end
      finals[record.operation] = result
      draft.Extra.recovery.ferryFinal = finals
      return result
    end, function(ok, result)
      if ok then sync_tree(player, data) end
      done(ok, result)
    end)
  end

  function handle:board(player, data, route, operation)
    local point = route.Outbound
    if self:pending_flight(route.Id) then return self:Fail(player, "Board", "sailing") end
    if not interact or not interact:in_range(player, point) then return self:Fail(player, "Board", "range") end
    local session = save.Sessions[player.UserId]
    local flight = { player = player, operation = operation.id, routeId = route.Id }
    self.BoardPending[route.Id] = flight
    local accepted, reason = self:settle(player, data, "ferry:board", function(draft)
      if not draft:ConsumeItem(point.Ticket) then return nil, "ticket" end
      draft.Extra.recovery.ferry = { operation = operation.id, identity = operation, action = "Board",
        routeId = route.Id, ticket = point.Ticket, zone = point.Zone, state = "pending" }
      return { ok = true, action = "Board", routeId = route.Id, seconds = point.CountdownSec,
        operation = operation }
    end, function(ok, result)
      if self.BoardPending[route.Id] ~= flight
          or not save:is_current(player.UserId, session, data) then return end
      self.BoardPending[route.Id] = nil
      if not ok then self:Fail(player, "Board", result) return end
      SpokeRuntime.batch(function()
        sync_tree(player, data)
        self.Flights[route.Id] = { player = player, operation = operation.id, routeId = route.Id,
          DepartAt = world.clock.now() + point.CountdownSec }
        route_states[route.Id]:set({ phase = "countdown", routeId = route.Id,
          operation = operation.id, seconds = point.CountdownSec })
        if route_sailing[route.Id] then route_sailing[route.Id]:set(true) end
      end)
      self:broadcast({ phase = "countdown", routeId = route.Id, operation = operation.id,
        seconds = point.CountdownSec })
      self:reply(player, result)
    end, operation)
    if not accepted and self.BoardPending[route.Id] == flight then
      self.BoardPending[route.Id] = nil
      return self:Fail(player, "Board", reason or "save")
    end
    return accepted
  end

  function handle:return_back(player, data, route, operation)
    local point = route.Return
    if not interact or not interact:in_range(player, point) then return self:Fail(player, "Return", "range") end
    local record = { operation = operation.id, identity = operation, action = "Return", routeId = route.Id,
      price = point.Price, state = "pending", zone = point.Zone }
    self.ReturnPending[player.UserId] = record
    local outcome
    local accepted, reason = self:settle(player, data, "ferry:return", function(draft)
      if not draft:SpendCoin(point.Price, nil, "ferry:return") then return nil, "coin" end
      draft.Extra.recovery.ferry = record
      return { ok = true, action = "Return", routeId = route.Id, price = point.Price, operation = operation }
    end, function(ok, result)
      if self.ReturnPending[player.UserId] ~= record then return end
      if not ok then
        self.ReturnPending[player.UserId] = nil
        outcome = false
        self:Fail(player, "Return", result)
        return
      end
      sync_tree(player, data)
      local delivered = self:teleport(player, point.Destination)
      outcome = delivered
      self:finish_travel(player, data, record, delivered, "teleport", function(written, final)
        if self.ReturnPending[player.UserId] ~= record then return end
        self.ReturnPending[player.UserId] = nil
        if written then self:reply(player, final) else self:Fail(player, "Return", final) end
      end)
    end, operation)
    if not accepted and outcome == nil then
      self.ReturnPending[player.UserId] = nil
      return self:Fail(player, "Return", reason or "save")
    end
    return accepted and outcome ~= false
  end

  function handle:recover(player, data)
    local record = data and data.Extra and data.Extra.recovery and data.Extra.recovery.ferry
    if not record then return false end
    local flight = record.routeId and self:pending_flight(record.routeId)
    if flight and flight.player == player and flight.operation == record.operation then return true end
    if self.Recoveries[player.UserId] then return true end
    self.Recoveries[player.UserId] = player
    local accepted = self:finish_travel(player, data, record, false, "interrupted", function(ok, result)
      if self.Recoveries[player.UserId] == player then self.Recoveries[player.UserId] = nil end
      if ok then self:reply(player, result) end
    end)
    if not accepted then self.Recoveries[player.UserId] = nil end
    return true
  end

  function handle:depart(route, flight)
    local point = route.Outbound
    local anchor = interact and interact:find_anchor(point.AnchorName)
    local center = anchor and anchor.Position
    if not center then
      log("找不到摆渡锚点，本次航班取消并退票", route.Id, point.AnchorName)
      local data = data_of(flight.player)
      local record = data and data.Extra.recovery.ferry
      if record then
        self:finish_travel(flight.player, data, record, false, "anchor", function(ok, result)
          if ok then self:reply(flight.player, result) end
        end)
      end
      self:broadcast({ phase = "cancelled", routeId = route.Id, operation = flight.operation, reason = "anchor" })
      return
    end
    local payer = flight.player
    local delivered_count = 0
    for _, player in ipairs(self:online_players()) do
      if left_players[player.UserId] ~= player then
        local data = data_of(player)
        local pos = player.Character and player.Character.Position
        local aboard = pos and flat_distance(pos, center) <= point.BoatRange
        if data and data.Inited and not is_paused(player.UserId) then
          local delivered = aboard and self:teleport(player, point.Destination)
          if delivered then delivered_count = delivered_count + 1 end
          if player == payer and data.Extra.recovery.ferry then
            local record = data.Extra.recovery.ferry
            if delivered then record.zone = point.Zone end
            local reason = not delivered and (aboard and "teleport" or "not_aboard") or nil
            self:finish_travel(player, data, record, delivered, reason, function(ok, result)
              if ok then self:reply(player, result) end
            end)
          elseif delivered then
            self:settle(player, data, "ferry:ride", function(draft)
              draft:SetZone(point.Zone)
              mark_arrival(draft, point.Zone)
              return { ok = true, action = "Board", routeId = route.Id }
            end, function(ok, result)
              if ok then
                sync_tree(player, data)
                self:reply(player, result)
              end
            end)
          end
        end
      end
    end
    if delivered_count == 0 then
      self:broadcast({ phase = "cancelled", routeId = route.Id, operation = flight.operation, reason = "empty" })
    else
      self:broadcast({ phase = "departed", routeId = route.Id, operation = flight.operation })
    end
  end

  local function sync_recovery_watch()
    local active = next(recovery_watch_users) ~= nil
    if recovery_watch_active:now() ~= active then
      recovery_watch_active:set(active)
    end
  end

  function handle:update_recoveries()
    if self.disposed then return end
    for _, player in ipairs(self:online_players()) do
      if is_valid_player(player) and left_players[player.UserId] ~= player then
        local data = data_of(player)
        if data and data.Inited and not is_paused(player.UserId) then
          self:recover(player, data)
          if recovery_watch_users[player.UserId]
              and not (data.Extra and data.Extra.recovery and data.Extra.recovery.ferry)
              and not self.Recoveries[player.UserId] then
            recovery_watch_users[player.UserId] = nil
          end
        end
      end
    end
    sync_recovery_watch()
  end

  function handle:step_route(route)
    if self.disposed then return end
    local flight = self.Flights[route.Id]
    local state = route_states[route.Id]
    local sailing = route_sailing[route.Id]
    if not flight then
      if sailing and sailing:now() then sailing:set(false) end
      return
    end
    local now = world.clock.now()
    if now >= flight.DepartAt then
      self.Flights[route.Id] = nil
      SpokeRuntime.batch(function()
        if state then state:set({ phase = "idle", routeId = route.Id }) end
        if sailing then sailing:set(false) end
      end)
      self:depart(route, flight)
    elseif state then
      local seconds = math.max(0, flight.DepartAt - now)
      local current = state:now()
      if math.ceil(seconds) ~= math.ceil(current.seconds or 0) then
        state:set({ phase = "countdown", routeId = route.Id, operation = flight.operation, seconds = seconds })
      end
    end
  end

  function handle:update()
    if self.disposed then return end
    self:update_recoveries()
    for _, route in ipairs(GameCfg.Ferry.Routes) do
      self:step_route(route)
    end
  end

  function handle:on_player_added(player)
    if not is_valid_player(player) then return end
    left_players[player.UserId] = nil
    local now = world.clock.now()
    local channel = event("FerryState")
    for _, route in ipairs(GameCfg.Ferry.Routes) do
      local flight = self.Flights[route.Id]
      if flight and flight.DepartAt and now < flight.DepartAt and channel and channel.FireClient then
        channel:FireClient(player, { phase = "countdown", routeId = route.Id, operation = flight.operation,
          seconds = flight.DepartAt - now })
      end
    end
    local data = data_of(player)
    if data and data.Inited and not is_paused(player.UserId) then
      self:recover(player, data)
      if recovery_watch_users[player.UserId]
          and not (data.Extra and data.Extra.recovery and data.Extra.recovery.ferry)
          and not self.Recoveries[player.UserId] then
        recovery_watch_users[player.UserId] = nil
        sync_recovery_watch()
      end
    end
  end

  function handle:on_player_removing(player)
    if not is_valid_player(player) then return end
    local interrupted = false
    left_players[player.UserId] = player
    self.LastSeq[player.UserId] = nil
    self.Recoveries[player.UserId] = nil
    if self.ReturnPending[player.UserId] then
      interrupted = true
      self.ReturnPending[player.UserId] = nil
    end
    for route_id, flight in pairs(self.BoardPending) do
      if flight.player == player then
        interrupted = true
        self.BoardPending[route_id] = nil
      end
    end
    for route_id, flight in pairs(self.Flights) do
      if flight.player == player then
        interrupted = true
        self.Flights[route_id] = nil
        SpokeRuntime.batch(function()
          if route_states[route_id] then route_states[route_id]:set({ phase = "idle", routeId = route_id }) end
          if route_sailing[route_id] then route_sailing[route_id]:set(false) end
        end)
        self:broadcast({ phase = "cancelled", routeId = route_id, operation = flight.operation,
          reason = "payer_left" })
      end
    end
    if interrupted then
      recovery_watch_users[player.UserId] = true
      sync_recovery_watch()
    end
  end

  local Actions = { board = "Board", Return = "ReturnBack" }
  function handle:Handle(player, payload)
    if self.disposed or not is_valid_player(player) or type(payload) ~= "table" then return false end
    local method = Actions[payload.action]
    local seq = payload.seq
    if not method or type(seq) ~= "number" or seq ~= math.floor(seq) then return false end
    local route = GameCfg.Ferry.route(payload.routeId)
    if not route then return self:Fail(player, payload.action, "route") end
    local data = data_of(player)
    if not data then return false end
    if not save or type(save.resolve_request) ~= "function" or not data.Inited or is_paused(player.UserId) then
      return self:Fail(player, payload.action, "save")
    end
    local kind = payload.action == "Board" and "ferry:board" or "ferry:return"
    local operation, status = save:resolve_request(player, data, kind, payload.requestId or seq)
    if not operation then return self:Fail(player, payload.action, status) end
    if status == "replay" then
      if payload.requestId == nil then return false end
      local flight = self:pending_flight(route.Id)
      local active = flight and flight.player == player and flight.operation == operation.id
      if data.Extra.recovery.ferry and not active then
        self:recover(player, data)
        local final = data.Extra.recovery.ferryFinal and data.Extra.recovery.ferryFinal[operation.id]
        if final then self:reply(player, final) return true end
        return self:Fail(player, payload.action, "pending")
      end
      return self:settle(player, data, kind, function() return nil, "replay" end, function(ok, result)
        if ok then
          local final = data.Extra.recovery.ferryFinal and data.Extra.recovery.ferryFinal[operation.id]
          self:reply(player, final or result)
        else
          self:Fail(player, payload.action, result)
        end
      end, operation)
    end
    local last = self.LastSeq[player.UserId]
    if last and seq <= last then return false end
    self.LastSeq[player.UserId] = seq
    if data.Extra.recovery.ferry then
      self:recover(player, data)
      return self:Fail(player, payload.action, "pending")
    end
    return self[method](self, player, data, route, operation)
  end

  for index, route in ipairs(GameCfg.Ferry.Routes) do
    local zone = world.zones[route.FromZoneId]
    if zone and zone.ferry_routes then
      zone.ferry_routes:call(route.Id, LambdaEpoch.new("FerryRoute:" .. route.Id, function(scope)
        local state = State.new("FerryRoute." .. route.Id, { phase = "idle", routeId = route.Id })
        local sailing = State.new("FerryRoute.sailing." .. route.Id, false)
        route_states[route.Id] = state
        route_sailing[route.Id] = sailing
        scope:call(Effect.new("FerryClock:" .. route.Id, function(es)
          if index == 1 then
            es:subscribe(world.clock.on_second, function() handle:update_recoveries() end)
            es:phase("FerryRecoveryWatch", recovery_watch_active, function(ps)
              ps:subscribe(world.clock.on_frame, function() handle:update_recoveries() end)
            end)
          end
          es:phase("FerrySailing:" .. route.Id, sailing, function(ps)
            ps:subscribe(world.clock.on_frame, function() handle:step_route(route) end)
          end)
        end))
        scope:on_cleanup(function()
          route_states[route.Id] = nil
          route_sailing[route.Id] = nil
          if index == 1 then
            handle.disposed = true
            handle.LastSeq = {}
            recovery_watch_users = {}
          end
          local flight = handle.Flights[route.Id]
          if flight then handle.Flights[route.Id] = nil end
          handle.BoardPending[route.Id] = nil
        end)
      end))
    end
  end

  world.ferry = handle
  return handle
end

return FerryRoute
