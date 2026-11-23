-- #312 抽奖机、盲盒与地图商店服务端宿主测试双。
-- 只替换引擎、DataStore 与时钟；业务请求全部经 ServerRuntime 上行分发，回包经 RemoteEvent 观察。
local GameCfg = require("common.GameCfg")

local M = {}
local World = {}
World.__index = World

local function signal()
  local handlers = {}
  return {
    Connect = function(_, fn)
      handlers[#handlers + 1] = fn
      return { Disconnect = function() end }
    end,
    Fire = function(_, ...)
      for _, fn in ipairs(handlers) do fn(...) end
    end,
  }
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
    GetRE = function(_, name)
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
    CheckRECD = function() return false end,
  }

  env.save = assert(loadfile("server/Mgr/MgrSave.lua"))()
  env.players = assert(loadfile("server/Mgr/MgrPlayerData.lua"))()
  env.platform = assert(loadfile("server/Mgr/MgrPlatform.lua"))()
  env.players.Save, env.save.PlayerData = env.save, env.players
  env.platform.Save, env.platform.PlayerData = env.save, env.players
  env.platform.Now = function() return env.now end

  local ServerRuntime = require("server.World.ServerRuntime")
  local SpokeClock = require("common.SpokeClock")
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
    bind_lottery_action = function(dispatch) env.lotteryDispatch = dispatch end,
    bind_blindbox_action = function(dispatch) env.blindboxDispatch = dispatch end,
  })
  env.save.OnReady = function(player, data) env.runtime:on_save_ready(player, data) end
  env.runtime:start()
  env.runtime:mark_started()
  local ground = env.runtime:get_world()
  local place_delivery = ground.place_delivery
  ground.place_delivery = function(self, key, zoneId, spec)
    if env.failDeliveries then return nil, "test-rejected" end
    return place_delivery(self, key, zoneId, spec)
  end
  ServerRuntime.set_current(env.runtime)
  env.platform:Start()

  env.player = make_player(1472)
  env.online_players = { env.player }
  env.runtime:on_player_added(env.player)
  env.players:OnPlayerAdded(env.player)
  env:drain()
  env.data = env.players:GetDataInst(env.player)
  env:persistReady()
  return env
end

function World:drain()
  while #self.queue > 0 do table.remove(self.queue, 1)() end
end

function World:tearDown()
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

function World:addPlayer(id, name)
  local player = make_player(id)
  player.Name = name or player.Name
  self.online_players[#self.online_players + 1] = player
  self.runtime:on_player_added(player)
  self.players:OnPlayerAdded(player)
  self:drain()
  return player, self.players:GetDataInst(player)
end

function World:usePlayer(player)
  self.player = player
  self.data = self.players:GetDataInst(player)
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

function World:lastResult(name)
  local rows = self:messages(name)
  return rows[#rows]
end

function World:persistReady()
  assert(self.save:SaveExplicit(self.player.UserId, self.data, function(ok) assert(ok) end))
  self:drain()
  self.events = {}
end

function World:givePremium(itemId, mult, cooked)
  assert(self.data:AddItem(itemId, mult, cooked))
  return 1
end

function World:scriptAxes(a, b, c, weaponPick)
  self.rolls = { a, b, c }
  if weaponPick then self.rolls[4] = weaponPick end
end

function World:lotteryAction(payload, shouldDrain)
  local accepted = self.lotteryDispatch and self.lotteryDispatch(self.player, payload) or false
  if shouldDrain ~= false then self:drain() end
  return accepted
end

function World:lotteryDraw(slot, seq)
  return self:lotteryAction({ action = "Draw", slot = slot, seq = seq })
end

function World:lotteryState()
  local accepted = self.runtime:lottery_state(self.player)
  self:drain()
  return accepted
end

function World:clearEvents()
  self.events = {}
end

function World:blindboxDraw(count, seq, outcome)
  local accepted = self.blindboxDispatch and self.blindboxDispatch(self.player,
    { action = "Draw", count = count, seq = seq }) or false
  self:drain()
  if accepted and outcome then
    assert(self.platform:HandleTestAction(self.player, { action = "ResolveFlow", outcome = outcome }))
    self:drain()
  end
  return accepted
end

function World:blindboxAction(payload)
  local accepted = self.blindboxDispatch and self.blindboxDispatch(self.player, payload) or false
  self:drain()
  return accepted
end

function World:blindboxQuery(seq, requestId)
  return self:blindboxAction({ action = "Query", count = 1, seq = seq, requestId = requestId })
end

function World:blindboxState()
  local accepted = self.runtime:blindbox_state(self.player)
  self:drain()
  return accepted
end

function World:platformAction(payload)
  local accepted = self.runtime:platform_shop_action(self.player, payload)
  self:drain()
  return accepted
end

function World:resolvePlatform(outcome)
  if GameCfg.Platform.Placeholder.Enabled then
    assert(self.platform:ResolvePlaceholder(self.player, outcome))
  else
    assert(self.platform:HandleTestAction(self.player, { action = "ResolveFlow", outcome = outcome }))
  end
  self:drain()
end

function World:pump()
  self.runtime:step(0, self.now)
  self:drain()
end

function World:groundItems()
  local snapshot = self.runtime:get_world():ground_snapshot()
  return snapshot and snapshot.list or {}
end

function World:reconnect()
  local old = self.player
  self.runtime:on_player_removing(old)
  self.platform:OnPlayerRemoving(old)
  self.players:OnPlayerRemoving(old)
  self:drain()
  self.player = make_player(old.UserId, old.Character)
  self.online_players = { self.player }
  self.runtime:on_player_added(self.player)
  self.players:OnPlayerAdded(self.player)
  self:drain()
  self.data = self.players:GetDataInst(self.player)
end

return M
