local EngineRead = require("common.engine_read")
local GameCfg = require("common.game_cfg")
local Number = require("common.number")
local Spoke = require("common.packages.spoke.api")
local SpokeRuntime = require("common.packages.spoke.runtime.spoke_runtime")

local LambdaEpoch = Spoke.LambdaEpoch
local Effect = Spoke.Effect
local State = Spoke.State

local FerryRoute = {}

local function is_valid_player(player)
  return EngineRead.is_object(player) and player.UserId ~= nil
end

local function mark_arrival(draft, zone)
  local arrived = draft.extra.travel.arrived
  arrived[zone] = (arrived[zone] or 0) + 1
end

-- 摆渡句柄：状态字段留在句柄上，外部依赖装进 ferry_env；方法名沿用拆分前的 handle 方法名。
---@class FerryHandle: table<string, any>

---@type FerryHandle
local FerryBehavior = {}
local Actions = { Board = "board", Return = "return_back" }

local function log(...)
  print("[FerryRoute]", ...)
end

local function event(env, name)
  local remote = env.remote
  if not EngineRead.is_object(remote) or type(remote.get_re) ~= "function" then log("远程通道服务不可用", tostring(name), "missing-remote"); return nil, "missing-remote" end
  local ok, value, reason = EngineRead.call_method(remote, "get_re", "FerryRoute.event:" .. tostring(name), name)
  if not ok then log("获取远程通道失败", tostring(name), tostring(reason)); return nil, reason or "read_error" end; if not EngineRead.is_object(value) then log("远程通道缺失", tostring(name), "missing-channel"); return nil, "missing-channel" end; return value, nil
end

local function data_of(env, player)
  local player_data = env.player_data
  local uid = is_valid_player(player) and player.UserId or nil
  if not player_data or type(player_data.get_data_inst) ~= "function" then log("玩家数据服务不可用", uid, "missing-player-data"); return nil, "missing-player-data" end
  local ok, data = pcall(player_data.get_data_inst, player_data, player); if not ok then log("读取玩家数据失败", uid, tostring(data)); return nil, tostring(data) end; if data ~= nil and type(data) ~= "table" then log("玩家数据格式异常", uid, type(data)); return nil, "invalid-player-data" end; return data, nil
end

local function is_paused(env, user_id)
  local save = env.save
  return save ~= nil and type(save.is_paused) == "function" and save:is_paused(user_id) or false
end

local function sync_tree(env, player, data)
  local lookup_tree = env.lookup_tree
  if type(lookup_tree) ~= "function" then return end
  local tree = lookup_tree(player)
  if tree and type(tree.sync_from_data) == "function" then
    local ok, err = pcall(tree.sync_from_data, tree, data)
    if not ok then log("同步玩家树失败", player and player.UserId, tostring(err)) end
  end
end

local function sync_recovery_watch(env)
  local active = next(env.recovery_watch_users) ~= nil
  if env.recovery_watch_active:now() ~= active then
    env.recovery_watch_active:set(active)
  end
end

function FerryBehavior.reply(self, player, payload)
  local channel, err = event(self.ferry_env, "FerryResult"); if not channel then return false, err end
  local ok, _, reason = EngineRead.call_method(channel, "FireClient", "FerryRoute.reply", player, payload); if not ok then log("FerryResult 下发失败", player and player.UserId, tostring(reason)); return false, reason end; return true
end

function FerryBehavior.broadcast(self, payload)
  local channel, err = event(self.ferry_env, "FerryState"); if not channel then return false, err end
  local ok, _, reason = EngineRead.call_method(channel, "FireAllClients", "FerryRoute.broadcast", payload); if not ok then log("FerryState 广播失败", tostring(reason)); return false, reason end; return true
end

function FerryBehavior.fail(self, player, action, reason)
  log("请求拒绝", player and player.UserId, action, tostring(reason))
  self:reply(player, { ok = false, action = action, reason = reason })
  return false
end

function FerryBehavior.online_players(self)
  local env = self.ferry_env
  local opts = env.opts
  if type(opts.online_players) == "function" then
    local ok, list = pcall(opts.online_players); if ok and type(list) == "table" then return list, nil end
    local err = ok and ("invalid-list:" .. type(list)) or tostring(list); log("读取在线玩家失败", "opts.online_players", err); return nil, err
  end
  local players_service = env.players_service
  if not EngineRead.is_object(players_service) or type(players_service.GetPlayers) ~= "function" then log("读取在线玩家失败", "Players", "missing-service"); return nil, "missing-service" end
  local ok, list, reason = EngineRead.call_method(players_service, "GetPlayers", "FerryRoute.online_players"); if not ok then log("读取在线玩家失败", "Players.GetPlayers", tostring(reason)); return nil, reason or "read_error" end; if type(list) ~= "table" then log("读取在线玩家失败", "Players.GetPlayers", "invalid-list:" .. type(list)); return nil, "invalid-list" end; return list, nil
end

function FerryBehavior.teleport(self, player, dest)
  local lookup_tree = self.ferry_env.lookup_tree
  local character = player and player.Character
  if not character then
    log("传送失败", player and player.UserId, "角色缺失")
    return false
  end
  local tree
  if type(lookup_tree) == "function" then
    local tree_ok, found = pcall(lookup_tree, player)
    if not tree_ok then
      log("传送中止：查询玩家树失败", player.UserId, tostring(found))
      return false
    end
    tree = found
  end
  if type(tree) == "table" and type(tree.suspend_special_item) == "function" then
    local suspend_ok, suspend_result = pcall(tree.suspend_special_item, tree)
    if not suspend_ok or suspend_result == false then
      log("传送中止：特殊道具挂起失败", player.UserId,
        suspend_ok and "returned-false" or tostring(suspend_result))
      return false
    end
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

function FerryBehavior.settle(self, player, data, kind, transform, done, operation)
  local save = self.ferry_env.save
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

function FerryBehavior.pending_flight(self, route_id)
  return self.board_pending[route_id] or self.flights[route_id]
end

function FerryBehavior.finish_travel(self, player, data, record, delivered, reason, done)
  local env = self.ferry_env
  return self:settle(player, data, delivered and "ferry:confirm" or "ferry:refund", function(draft)
    local pending = draft.extra.recovery.ferry
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
    draft.extra.recovery.ferry = nil
    local result = { ok = delivered, action = record.action, route_id = record.route_id,
      price = record.price, operation = record.identity, reason = not delivered and reason or nil }
    local finals = {}
    for _, prior in ipairs(draft.save_meta.operations) do
      local kept = draft.extra.recovery.ferryFinal and draft.extra.recovery.ferryFinal[prior.id]
      if kept then finals[prior.id] = kept end
    end
    finals[record.operation] = result
    draft.extra.recovery.ferryFinal = finals
    return result
  end, function(ok, result)
    if ok then sync_tree(env, player, data) end
    done(ok, result)
  end)
end

function FerryBehavior.board(self, player, data, route, operation)
  local env = self.ferry_env
  local save, interact, world = env.save, env.interact, env.world
  local point = route.Outbound
  if self:pending_flight(route.Id) then return self:fail(player, "Board", "sailing") end
  if not interact or not interact:in_range(player, point) then return self:fail(player, "Board", "range") end
  local session = save.sessions[player.UserId]
  local flight = { player = player, operation = operation.id, route_id = route.Id }
  self.board_pending[route.Id] = flight
  local accepted, reason = self:settle(player, data, "ferry:board", function(draft)
    if not draft:ConsumeItem(point.Ticket) then return nil, "ticket" end
    draft.extra.recovery.ferry = { operation = operation.id, identity = operation, action = "Board",
      route_id = route.Id, ticket = point.Ticket, zone = point.Zone, state = "pending" }
    return { ok = true, action = "Board", route_id = route.Id, seconds = point.CountdownSec,
      operation = operation }
  end, function(ok, result)
    if self.board_pending[route.Id] ~= flight
        or not save:is_current(player.UserId, session, data) then return end
    self.board_pending[route.Id] = nil
    if not ok then self:fail(player, "Board", result) return end
    SpokeRuntime.batch(function()
      sync_tree(env, player, data)
      self.flights[route.Id] = { player = player, operation = operation.id, route_id = route.Id,
        depart_at = world.clock.now() + point.CountdownSec }
      env.route_states[route.Id]:set({ phase = "countdown", route_id = route.Id,
        operation = operation.id, seconds = point.CountdownSec })
      if env.route_sailing[route.Id] then env.route_sailing[route.Id]:set(true) end
    end)
    self:broadcast({ phase = "countdown", route_id = route.Id, operation = operation.id,
      seconds = point.CountdownSec })
    self:reply(player, result)
  end, operation)
  if not accepted and self.board_pending[route.Id] == flight then
    self.board_pending[route.Id] = nil
    return self:fail(player, "Board", reason or "save")
  end
  return accepted
end

function FerryBehavior.return_back(self, player, data, route, operation)
  local env = self.ferry_env
  local interact = env.interact
  local point = route.Return
  if not interact or not interact:in_range(player, point) then return self:fail(player, "Return", "range") end
  local record = { operation = operation.id, identity = operation, action = "Return", route_id = route.Id,
    price = point.Price, state = "pending", zone = point.Zone }
  self.return_pending[player.UserId] = record
  local outcome
  local accepted, reason = self:settle(player, data, "ferry:return", function(draft)
    if not draft:SpendCoin(point.Price, nil, "ferry:return") then return nil, "coin" end
    draft.extra.recovery.ferry = record
    return { ok = true, action = "Return", route_id = route.Id, price = point.Price, operation = operation }
  end, function(ok, result)
    ---@type table?
    local pending = self.return_pending[player.UserId]
    if pending ~= record then return end
    if not ok then
      self.return_pending[player.UserId] = nil
      outcome = false
      self:fail(player, "Return", result)
      return
    end
    sync_tree(env, player, data)
    local delivered = self:teleport(player, point.destination)
    outcome = delivered
    self:finish_travel(player, data, record, delivered, "teleport", function(written, final)
      ---@type table?
      local current_pending = self.return_pending[player.UserId]
      if current_pending ~= record then return end
      self.return_pending[player.UserId] = nil
      if written then self:reply(player, final) else self:fail(player, "Return", final) end
    end)
  end, operation)
  if not accepted and outcome == nil then
    self.return_pending[player.UserId] = nil
    return self:fail(player, "Return", reason or "save")
  end
  return accepted and outcome ~= false
end

function FerryBehavior.recover(self, player, data)
  local record = data and data.extra and data.extra.recovery and data.extra.recovery.ferry
  if not record then return false end
  local flight = record.route_id and self:pending_flight(record.route_id)
  if flight and flight.player == player and flight.operation == record.operation then return true end
  if self.recoveries[player.UserId] then return true end
  self.recoveries[player.UserId] = player
  local accepted = self:finish_travel(player, data, record, false, "interrupted", function(ok, result)
    if self.recoveries[player.UserId] == player then self.recoveries[player.UserId] = nil end
    if ok then self:reply(player, result) end
  end)
  if not accepted then self.recoveries[player.UserId] = nil end
  return true
end

--- 取消航班：读取存档后按失败原因退票，并广播取消。
---@param self table 航线句柄
---@param env table 摆渡环境
---@param route table 航线配置
---@param flight table 当前航班
---@param reason string 取消原因，同时作为退票原因
---@param log_label string 读取存档失败时的日志前缀
local function cancel_flight(self, env, route, flight, reason, log_label)
  local data, data_err = data_of(env, flight.player)
  if data_err then
    log(log_label, route.Id, flight.player and flight.player.UserId, tostring(data_err))
  end
  local record = data and data.extra and data.extra.recovery and data.extra.recovery.ferry
  if record then
    self:finish_travel(flight.player, data, record, false, reason, function(ok, result)
      if ok then self:reply(flight.player, result) end
    end)
  end
  self:broadcast({ phase = "cancelled", route_id = route.Id, operation = flight.operation, reason = reason })
end

--- 逐个在线玩家结算登船：传送、付款人退票与乘船操作。
---@param self table 航线句柄
---@param env table 摆渡环境
---@param route table 航线配置
---@param point table 出航锚点配置
---@param center table 出航锚点位置
---@param flight table 当前航班
---@param players table 在线玩家列表
---@return number 本次送达人数
local function board_players(self, env, route, point, center, flight, players)
  local payer, delivered_count = flight.player, 0
  for _, player in ipairs(players) do
    if env.left_players[player.UserId] ~= player then
      local data, data_err = data_of(env, player)
      local pos = player.Character and player.Character.Position
      local aboard = pos and Number.flat_distance(pos, center) <= point.BoatRange
      if not data_err and data and data.inited and not is_paused(env, player.UserId) then
        local delivered = aboard and self:teleport(player, point.destination)
        if delivered then delivered_count = delivered_count + 1 end
        if player == payer and data.extra.recovery.ferry then
          local record = data.extra.recovery.ferry; if delivered then record.zone = point.Zone end
          local reason = not delivered and (aboard and "teleport" or "not_aboard") or nil
          self:finish_travel(player, data, record, delivered, reason, function(ok, result)
            if ok then self:reply(player, result) end
          end)
        elseif delivered then
          self:settle(player, data, "ferry:ride", function(draft)
            draft:SetZone(point.Zone); mark_arrival(draft, point.Zone)
            return { ok = true, action = "Board", route_id = route.Id }
          end, function(ok, result) if ok then sync_tree(env, player, data); self:reply(player, result) end end)
        end
      end
    end
  end
  return delivered_count
end

function FerryBehavior.depart(self, route, flight)
  local env = self.ferry_env
  local interact = env.interact
  local point = route.Outbound
  local anchor = interact and interact:find_anchor(point.AnchorName)
  local center = anchor and anchor.Position
  if not center then
    log("找不到摆渡锚点，本次航班取消并退票", route.Id, point.AnchorName)
    cancel_flight(self, env, route, flight, "anchor", "取消航班退票读取数据失败")
    return
  end
  local players, players_err = self:online_players()
  if not players then
    log("发船中止：在线玩家读取失败，取消航班并尝试退票", route.Id, tostring(players_err))
    cancel_flight(self, env, route, flight, "service_error", "发船取消退票读取数据失败")
    return false, players_err
  end
  if board_players(self, env, route, point, center, flight, players) == 0 then
    self:broadcast({ phase = "cancelled", route_id = route.Id, operation = flight.operation, reason = "empty" })
  else
    self:broadcast({ phase = "departed", route_id = route.Id, operation = flight.operation })
  end
end

function FerryBehavior.update_recoveries(self)
  local env = self.ferry_env
  if self.disposed then return false, "disposed" end
  local players, players_err = self:online_players()
  if not players then return false, players_err end
  local first_err ---@type string?
  for _, player in ipairs(players) do
    if is_valid_player(player) and env.left_players[player.UserId] ~= player then
      local data, data_err = data_of(env, player)
      if data_err then first_err = first_err or data_err
      elseif data and data.inited and not is_paused(env, player.UserId) then
        self:recover(player, data)
        if env.recovery_watch_users[player.UserId] and not (data.extra and data.extra.recovery and data.extra.recovery.ferry) and not self.recoveries[player.UserId] then env.recovery_watch_users[player.UserId] = nil end
      end
    end
  end
  sync_recovery_watch(env); if first_err then return false, first_err end; return true
end

function FerryBehavior.step_route(self, route)
  local env = self.ferry_env
  if self.disposed then return end
  local flight = self.flights[route.Id]
  local state = env.route_states[route.Id]
  local sailing = env.route_sailing[route.Id]
  if not flight then
    if sailing and sailing:now() then sailing:set(false) end
    return
  end
  local now = env.world.clock.now()
  if now >= flight.depart_at then
    self.flights[route.Id] = nil
    SpokeRuntime.batch(function()
      if state then state:set({ phase = "idle", route_id = route.Id }) end
      if sailing then sailing:set(false) end
    end)
    self:depart(route, flight)
  elseif state then
    ---@type number
    local seconds = math.max(0, flight.depart_at - now)
    local current = state:now()
    if math.ceil(seconds) ~= math.ceil(current.seconds or 0) then
      state:set({ phase = "countdown", route_id = route.Id, operation = flight.operation, seconds = seconds })
    end
  end
end

function FerryBehavior.update(self)
  if self.disposed then return end
  self:update_recoveries()
  for _, route in ipairs(GameCfg.Ferry.Routes) do
    self:step_route(route)
  end
end

function FerryBehavior.on_player_added(self, player)
  local env = self.ferry_env
  if not is_valid_player(player) then return false, "invalid-player" end
  env.left_players[player.UserId] = nil
  local now, channel, ch_err = env.world.clock.now(), nil, nil
  for _, route in ipairs(GameCfg.Ferry.Routes) do
    local flight = self.flights[route.Id]
    if flight and flight.depart_at and now < flight.depart_at then
      if channel == nil and ch_err == nil then channel, ch_err = event(env, "FerryState") end
      if channel then
        local ok_send, _, reason_send = EngineRead.call_method(channel, "FireClient", "FerryRoute.on_player_added", player, { phase = "countdown", route_id = route.Id, operation = flight.operation, seconds = flight.depart_at - now })
        if not ok_send then log("入场同步航班倒计时失败", player.UserId, route.Id, tostring(reason_send)) end
      end
    end
  end
  local data, data_err = data_of(env, player); if data_err then return false, data_err end
  if data and data.inited and not is_paused(env, player.UserId) then
    self:recover(player, data)
    if env.recovery_watch_users[player.UserId] and not (data.extra and data.extra.recovery and data.extra.recovery.ferry) and not self.recoveries[player.UserId] then
      env.recovery_watch_users[player.UserId] = nil; sync_recovery_watch(env)
    end
  end
  return true
end

function FerryBehavior:on_player_removing(player)
  local env = self.ferry_env
  if not is_valid_player(player) then return end
  local interrupted = false
  env.left_players[player.UserId] = player
  self.last_seq[player.UserId] = nil
  self.recoveries[player.UserId] = nil
  if self.return_pending[player.UserId] then
    interrupted = true
    self.return_pending[player.UserId] = nil
  end
  for route_id, flight in pairs(self.board_pending) do
    if flight.player == player then
      interrupted = true
      self.board_pending[route_id] = nil
    end
  end
  for route_id, flight in pairs(self.flights) do
    if flight.player == player then
      interrupted = true
      self.flights[route_id] = nil
      SpokeRuntime.batch(function()
        if env.route_states[route_id] then env.route_states[route_id]:set({ phase = "idle", route_id = route_id }) end
        if env.route_sailing[route_id] then env.route_sailing[route_id]:set(false) end
      end)
      self:broadcast({ phase = "cancelled", route_id = route_id, operation = flight.operation,
        reason = "payer_left" })
    end
  end
  if interrupted then
    env.recovery_watch_users[player.UserId] = true
    sync_recovery_watch(env)
  end
end

--- 存档不可用时的拒绝：保留 fail 的返回值给调用方。
---@param self table 航线句柄
---@param player table 玩家
---@param payload table 请求载荷
---@return boolean
local function replay_save_unavailable(self, player, payload)
  return self:fail(player, payload.action, "save")
end

--- 重放请求：按已落盘的操作回包，仍在航班上则退回挂起态。
---@param self table 航线句柄
---@param player table 玩家
---@param data table 玩家数据
---@param kind string 操作类型
---@param operation table 已落盘操作
---@param payload table 请求载荷
---@param route table 航线配置
---@return boolean, any
local function handle_replay(self, player, data, kind, operation, payload, route)
  if payload.requestId == nil then return false end
  local flight = self:pending_flight(route.Id)
  local active = flight and flight.player == player and flight.operation == operation.id
  if data.extra.recovery.ferry and not active then
    self:recover(player, data)
    local final = data.extra.recovery.ferryFinal and data.extra.recovery.ferryFinal[operation.id]
    if final then self:reply(player, final) return true end
    return self:fail(player, payload.action, "pending")
  end
  return self:settle(player, data, kind, function() return nil, "replay" end, function(ok, result)
    if ok then
      local final = data.extra.recovery.ferryFinal and data.extra.recovery.ferryFinal[operation.id]
      self:reply(player, final or result)
    else
      self:fail(player, payload.action, result)
    end
  end, operation)
end

--- 仍持有恢复记录时先恢复再拒绝，避免重复提交。
---@param self table 航线句柄
---@param player table 玩家
---@param data table 玩家数据
---@param action string 请求动作名
---@return boolean, any 是否已处理、拒绝结果
local function recover_pending(self, player, data, action)
  if not data.extra.recovery.ferry then return false end
  self:recover(player, data)
  return true, self:fail(player, action, "pending")
end

function FerryBehavior.handle(self, player, payload)
  local env = self.ferry_env
  local save = env.save
  if self.disposed or not is_valid_player(player) or type(payload) ~= "table" then return false end
  local method = Actions[payload.action]
  local seq = payload.seq
  if not method or type(seq) ~= "number" or seq ~= math.floor(seq) then return false end
  local route = GameCfg.Ferry.route(payload.route_id)
  if not route then return self:fail(player, payload.action, "route") end
  local data, data_err = data_of(env, player)
  if data_err then self:fail(player, payload.action, "data_error"); return false, data_err elseif not data then return false end
  if not save or type(save.resolve_request) ~= "function" or not data.inited or is_paused(env, player.UserId) then
    return replay_save_unavailable(self, player, payload)
  end
  local kind = payload.action == "Board" and "ferry:board" or "ferry:return"
  local operation, status = save:resolve_request(player, data, kind, payload.requestId or seq)
  if not operation then return self:fail(player, payload.action, status) end
  if status == "replay" then
    return handle_replay(self, player, data, kind, operation, payload, route)
  end
  local last = self.last_seq[player.UserId]
  if last and seq <= last then return false end
  self.last_seq[player.UserId] = seq
  local pending, fail_result = recover_pending(self, player, data, payload.action)
  if pending then return fail_result end
  return self[method](self, player, data, route, operation)
end

--- 按区挂载每条航线的状态与 Effect；清理时归还航线状态并标记句柄停用。
local function mount_route_effects(handle, world)
  local env = handle.ferry_env
  for index, route in ipairs(GameCfg.Ferry.Routes) do
    local zone = world.zones[route.FromZoneId]
    if zone and zone.ferry_routes then
      zone.ferry_routes:call(route.Id, LambdaEpoch.new("FerryRoute:" .. route.Id, function(scope)
        local state = State.new("FerryRoute." .. route.Id, { phase = "idle", route_id = route.Id })
        local sailing = State.new("FerryRoute.sailing." .. route.Id, false)
        env.route_states[route.Id] = state
        env.route_sailing[route.Id] = sailing
        scope:call(Effect.new("FerryClock:" .. route.Id, function(es)
          if index == 1 then
            es:subscribe(world.clock.on_second, function() handle:update_recoveries() end)
            es:phase("FerryRecoveryWatch", env.recovery_watch_active, function(ps)
              ps:subscribe(world.clock.on_frame, function() handle:update_recoveries() end)
            end)
          end
          es:phase("FerrySailing:" .. route.Id, sailing, function(ps)
            ps:subscribe(world.clock.on_frame, function() handle:step_route(route) end)
          end)
        end))
        scope:on_cleanup(function()
          env.route_states[route.Id] = nil
          env.route_sailing[route.Id] = nil
          if index == 1 then
            handle.disposed = true
            handle.last_seq = {}
            env.recovery_watch_users = {}
          end
          local flight = handle.flights[route.Id]
          if flight then handle.flights[route.Id] = nil end
          handle.board_pending[route.Id] = nil
        end)
      end))
    end
  end
end

--- 组装摆渡句柄：状态字段留在句柄上，依赖装进 handle.ferry_env，方法由 FerryBehavior 提供。
--- 对外方法名、参数顺序与返回值沿用拆分前的 handle 方法，调用方照旧用 :method(...)。
function FerryRoute.mount(world, opts)
  opts = type(opts) == "table" and opts or {}
  local handle = {
    last_seq = {},
    recoveries = {},
    return_pending = {},
    flights = {},
    board_pending = {},
    disposed = false,
  }
  handle.ferry_env = {
    world = world,
    opts = opts,
    remote = opts.remote,
    player_data = opts.player_data,
    save = opts.save,
    interact = opts.interact,
    players_service = opts.players_service,
    lookup_tree = opts.lookup_tree,
    route_states = {},
    route_sailing = {},
    left_players = setmetatable({}, { __mode = "v" }),
    recovery_watch_users = {},
    recovery_watch_active = State.new("FerryRoute.recovery_watch", false),
  }
  for name, method in pairs(FerryBehavior) do
    handle[name] = method
  end
  mount_route_effects(handle, world)
  world.ferry = handle
  return handle
end

return FerryRoute
