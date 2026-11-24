local GameCfg = require("common.game_cfg")

local M = {}
local World = {}
World.__index = World

local function signal()
  local handlers = {}
  local sig = { connects = 0 }
  function sig:Connect(fn)
    self.connects = self.connects + 1
    handlers[#handlers + 1] = fn
    return {
      Disconnect = function()
        for i = #handlers, 1, -1 do
          if handlers[i] == fn then
            table.remove(handlers, i)
            return
          end
        end
      end,
    }
  end
  function sig:Fire(...)
    for _, fn in ipairs({ table.unpack(handlers) }) do fn(...) end
  end
  return sig
end

local function make_player(id, character)
  local player = {
    UserId = id,
    Name = "p" .. id,
    attrs = {},
    CharacterAdded = signal(),
    CharacterRemoving = signal(),
    Character = character or {
      Position = { x = 3, y = 0, z = 5 },
      Size = { y = 2 },
      Controller = { Health = GameCfg.Vitals.MaxHealth },
    },
  }
  function player:SetAttribute(key, value) self.attrs[key] = value end
  return player
end

function M.new()
  local env = setmetatable({}, World)
  env.oldGame, env.oldRE = _G.game, _G.REUtil
  env.oldDebug = GameCfg.Debug
  env.oldPlaceholder = GameCfg.Platform.Placeholder.Enabled
  env.oldAllowPlaceholder = GameCfg.Platform.Placeholder.AllowInPublish
  env.oldGoodsIds = {}
  for key, row in pairs(GameCfg.Platform.Goods) do env.oldGoodsIds[key] = row.goodsId end
  GameCfg.Debug = { Enabled = true }
  GameCfg.Platform.Placeholder.Enabled = false

  env.values, env.queue, env.events, env.rolls = {}, {}, {}, {}
  env.recordReads, env.recordWrites = 0, 0
  env.requestSeq = {}
  env.channels, env.online_players = {}, {}
  env.archive = { completed = false, queries = {}, submissions = {} }
  env.inRange = true
  env.now = 1000
  env.goodsSignal = signal()
  local store = {
    GetAsync = function(_, key)
      if key:sub(1, 4) == "rec:" then env.recordReads = env.recordReads + 1 end
      if env.failReads or (key:sub(1, 4) == "rec:" and env.failRecordReads) then error("测试读档失败") end
      return env.values[key]
    end,
    UpdateAsync = function(_, key, transform)
      if key:sub(1, 4) == "rec:" then
        env.recordWrites = env.recordWrites + 1
        if env.recordWriteFailures and env.recordWriteFailures > 0 then
          env.recordWriteFailures = env.recordWriteFailures - 1
          error("测试纪录写入失败")
        end
      end
      if env.failWrites or (key:sub(1, 4) == "rec:" and env.failRecordWrites) then error("测试写档失败") end
      local value = transform(env.values[key])
      if value then env.values[key] = value end
      return value
    end,
    SetAsync = function(_, key, value) env.values[key] = value end,
  }
  _G.game = {
    GetService = function(_, name)
      if name == "Task" then
        return {
          Spawn = function(_, fn) env.queue[#env.queue + 1] = fn end,
          Wait = function() end,
        }
      elseif name == "DataStoreService" then
        return { GetDataStore = function() return store end }
      elseif name == "World" then
        return { GetServerTime = function() return env.now end }
      elseif name == "Players" then
        return { GetPlayers = function() return env.online_players end }
      elseif name == "ArchiveService" then
        return {
          IsAchievementCompleted = function(_, player, id)
            if env.archive.queryError then error("archive query failed") end
            env.archive.queries[#env.archive.queries + 1] = { player = player, id = id }
            return env.archive.completed
          end,
          SetAchievementProgress = function(_, player, id, value)
            if env.archive.submitError then error("archive submit failed") end
            env.archive.submissions[#env.archive.submissions + 1] = { player = player, id = id, value = value }
          end,
        }
      elseif name == "CommodityService" then
        return { ShowGoodsPurchasePanel = function() end, GoodsPurchaseCompleted = env.goodsSignal }
      end
    end,
  }
  _G.REUtil = {
    get_re = function(_, name)
      if not env.channels[name] then
        env.channels[name] = {
          FireClient = function(_, player, value)
            env.events[#env.events + 1] = { name = name, player = player, value = value }
          end,
          OnServerEvent = signal(),
        }
      end
      return env.channels[name]
    end,
    check_recd = function() return false end,
  }

  env.save = assert(loadfile("server/save_host.lua"))()
  env.players = assert(loadfile("server/player_data_host.lua"))()
  env.platform = assert(loadfile("server/platform_host.lua"))()
  env.players.Save, env.save.player_data = env.save, env.players
  env.platform.Save, env.platform.player_data = env.save, env.players
  env.platform.now = function() return env.now end

  local ServerRuntime = require("server.world_host.server_runtime")
  local SpokeClock = require("common.spoke_clock")
  env.ServerRuntime = ServerRuntime
  env.runtime = ServerRuntime.new({
    clock = SpokeClock.new(env.now),
    initial_now = env.now,
    delivery_epoch = "test-world",
    remote = _G.REUtil,
    save = env.save,
    platform = env.platform,
    player_data = env.players,
    random = function()
      if env.randomOverride then return env.randomOverride() end
      local roll = table.remove(env.rolls, 1)
      assert(roll, "测试脚本 RNG 序列耗尽")
      return roll
    end,
    lottery_in_range = function() return env.inRange end,
    create_unit = function(kind, props)
      return {
        Kind = kind,
        Name = props and props.Name,
        Position = props and props.Position,
        Destroyed = false,
        Destroy = function(unit) unit.Destroyed = true end,
      }
    end,
    bait_spots = { Enabled = false },
    on_item_bar_state = function(player, snapshot)
      _G.REUtil:get_re("ItemBarState"):FireClient(player, snapshot)
    end,
    bind_lottery_action = function(dispatch) env.lotteryDispatch = dispatch end,
    bind_blindbox_action = function(dispatch) env.blindboxDispatch = dispatch end,
  })
  env.save.on_ready = function(player, data) env.runtime:on_save_ready(player, data) end
  env.runtime:start()
  env.runtime:mark_started()
  local ground = env.runtime:get_world()
  local place_delivery = ground.place_delivery
  ground.place_delivery = function(self, key, zoneId, spec)
    if env.failDeliveries then return nil, "test-rejected" end
    return place_delivery(self, key, zoneId, spec)
  end
  ServerRuntime.set_current(env.runtime)
  env.platform:start()

  env.player = make_player(1472)
  env.online_players = { env.player }
  env.runtime:on_player_added(env.player)
  env.players:on_player_added(env.player)
  env:drain()
  env.data = env.players:get_data_inst(env.player)
  env:persist_ready()
  return env
end

function World:drain()
  while #self.queue > 0 do table.remove(self.queue, 1)() end
end

function World:tear_down()
  if self.runtime then self.runtime:shutdown() end
  if self.ServerRuntime and self.ServerRuntime.current() == self.runtime then
    self.ServerRuntime.set_current(nil)
  end
  _G.game, _G.REUtil = self.oldGame, self.oldRE
  GameCfg.Debug = self.oldDebug
  GameCfg.Platform.Placeholder.Enabled = self.oldPlaceholder
  GameCfg.Platform.Placeholder.AllowInPublish = self.oldAllowPlaceholder
  for key, row in pairs(GameCfg.Platform.Goods) do row.goodsId = self.oldGoodsIds[key] end
end

function World:add_player(id, name)
  local player = make_player(id)
  player.Name = name or player.Name
  self.online_players[#self.online_players + 1] = player
  self.runtime:on_player_added(player)
  self.players:on_player_added(player)
  self:drain()
  return player, self.players:get_data_inst(player)
end

function World:use_player(player)
  self.player = player
  self.data = self.players:get_data_inst(player)
  return self.data
end

function World:fire(name, payload, player)
  local channel = self.channels[name]
  assert(channel and channel.OnServerEvent, "宿主远程频道不存在: " .. tostring(name))
  channel.OnServerEvent:Fire(player or self.player, payload)
end

function World:saved(userId)
  return self.values[GameCfg.Save.KeyPrefix .. tostring(userId)]
end

function World:request(name, payload)
  local channel = self.channels[name]
  assert(channel and channel.OnServerEvent, "宿主远程频道不存在: " .. tostring(name))
  if (name == "CompendiumRequest" or name == "RecordsRequest") and type(payload) == "table" and payload.seq == nil then
    self.requestSeq[name] = (self.requestSeq[name] or 0) + 1
    local copy = {}
    for key, value in pairs(payload) do copy[key] = value end
    copy.seq = self.requestSeq[name]
    payload = copy
  end
  channel.OnServerEvent:Fire(self.player, payload)
  self:drain()
end

function World:landing(fishId, mult, reelSerial)
  local accepted, reason = self.runtime:record_landing(self.player, {
    fishId = fishId, mult = mult, reelSerial = reelSerial,
  })
  self:drain()
  return accepted, reason
end

function World:notify(kind, payload)
  local accepted = self.runtime:notify_quest(kind, self.player, payload)
  self:drain()
  return accepted
end

function World:advance(seconds)
  self.now = self.now + seconds
  self.runtime:step(seconds, self.now)
  self:drain()
end

function World:messages(name)
  local out = {}
  for _, event in ipairs(self.events) do
    if event.name == name then out[#out + 1] = event.value end
  end
  return out
end

function World:last_result(name)
  local rows = self:messages(name)
  return rows[#rows]
end

function World:persist_ready()
  assert(self.save:save_explicit(self.player.UserId, self.data, function(ok) assert(ok) end))
  self:drain()
  self.events = {}
end

function World:give_premium(itemId, mult, cooked)
  assert(self.data:AddItem(itemId, mult, cooked))
  return 1
end

function World:script_axes(a, b, c, weaponPick)
  self.rolls = { a, b, c }
  if weaponPick then self.rolls[4] = weaponPick end
end

function World:lottery_action(payload, shouldDrain)
  local accepted = self.lotteryDispatch and self.lotteryDispatch(self.player, payload) or false
  if shouldDrain ~= false then self:drain() end
  return accepted
end

function World:lottery_draw(slot, seq)
  return self:lottery_action({ action = "Draw", slot = slot, seq = seq })
end

function World:lottery_state()
  local accepted = self.runtime:lottery_state(self.player)
  self:drain()
  return accepted
end

function World:clear_events()
  self.events = {}
end

function World:blindbox_draw(count, seq, outcome)
  local accepted = self.blindboxDispatch and self.blindboxDispatch(self.player,
    { action = "Draw", count = count, seq = seq }) or false
  self:drain()
  if accepted and outcome then
    assert(self.platform:handle_test_action(self.player, { action = "ResolveFlow", outcome = outcome }))
    self:drain()
  end
  return accepted
end

function World:blindbox_action(payload)
  local accepted = self.blindboxDispatch and self.blindboxDispatch(self.player, payload) or false
  self:drain()
  return accepted
end

function World:blindbox_query(seq, requestId)
  return self:blindbox_action({ action = "Query", count = 1, seq = seq, requestId = requestId })
end

function World:blindbox_state()
  local accepted = self.runtime:blindbox_state(self.player)
  self:drain()
  return accepted
end

function World:platform_action(payload)
  local accepted = self.runtime:platform_shop_action(self.player, payload)
  self:drain()
  return accepted
end

function World:resolve_platform(outcome)
  if GameCfg.Platform.Placeholder.Enabled then
    assert(self.platform:resolve_placeholder(self.player, outcome))
  else
    assert(self.platform:handle_test_action(self.player, { action = "ResolveFlow", outcome = outcome }))
  end
  self:drain()
end

function World:pump()
  self.runtime:step(0, self.now)
  self:drain()
end

function World:ground_items()
  local snapshot = self.runtime:get_world():ground_snapshot()
  return snapshot and snapshot.list or {}
end

function World:reconnect()
  local old = self.player
  self.runtime:on_player_removing(old)
  self.platform:on_player_removing(old)
  self.players:on_player_removing(old)
  self:drain()
  self.player = make_player(old.UserId, old.Character)
  self.online_players = { self.player }
  self.runtime:on_player_added(self.player)
  self.players:on_player_added(self.player)
  self:drain()
  self.data = self.players:get_data_inst(self.player)
end

return M
