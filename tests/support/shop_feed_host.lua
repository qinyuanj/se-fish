local GameCfg = require("common.game_cfg")
local ServerRuntime = require("server.WorldHost.ServerRuntime")
local SpokeClock = require("common.spoke_clock")

local Host = {}

local function signal()
  local slots = {}
  return {
    Connect = function(_, fn)
      slots[#slots + 1] = fn
      return { Disconnect = function() end }
    end,
    Fire = function(_, ...)
      for _, fn in ipairs(slots) do fn(...) end
    end,
  }
end

local function anchor(name, position)
  return {
    Name = name,
    Position = position or { x = 0, y = 0, z = 0 },
    PlayAnimation = function(self, id)
      self.plays = self.plays or {}
      self.plays[#self.plays + 1] = id
    end,
  }
end

function Host.start(options)
  options = type(options) == "table" and options or {}
  local host = {
    queue = {}, values = {}, results = {}, snapshots = {}, sync_counts = {}, seq = {}, anchors = {},
    saved = {
      game = rawget(_G, "game"),
      REUtil = rawget(_G, "REUtil"),
      reutil = package.loaded["common.re_util"],
      debug = GameCfg.Debug,
    },
  }
  GameCfg.Debug = { Enabled = false }
  for index, stand in ipairs(GameCfg.Shop.Stands) do
    host.anchors[stand.AnchorName] = anchor(stand.AnchorName,
      options.positions and options.positions[stand.AnchorName] or { x = (index - 1) * 1000, y = 0, z = 0 })
  end
  for index, npc in ipairs(GameCfg.Interact.Fishermen) do
    for _, name in ipairs(npc.AnchorNames) do
      host.anchors[name] = anchor(name,
        options.positions and options.positions[name] or { x = 10000 + (index - 1) * 1000, y = 0, z = 0 })
    end
  end
  host.clock = options.clock or SpokeClock.new(options.now or 100)
  host.now = host.clock.now()
  local events = {}
  local function event(name)
    if not events[name] then
      events[name] = {
        OnServerEvent = signal(),
        FireClient = function(_, player, payload)
          host.results[player.UserId] = host.results[player.UserId] or {}
          local list = host.results[player.UserId]
          list[name] = list[name] or {}
          list[name][#list[name] + 1] = payload
        end,
        FireAllClients = function() end,
      }
    end
    return events[name]
  end
  host.events = events
  host.remote = {
    GetRE = function(_, name) return event(name) end,
    CheckRECD = function() return false end,
  }
  package.loaded["common.re_util"] = host.remote
  _G.REUtil = host.remote
  _G.game = {
    GetService = function(_, name)
      if name == "Task" then
        return {
          Spawn = function(_, fn) host.queue[#host.queue + 1] = fn end,
          Wait = function() end,
        }
      end
      if name == "DataStoreService" then
        return { GetDataStore = function() return {
          GetAsync = function(_, key) return host.values[key] end,
          SetAsync = function(_, key, value) host.values[key] = value end,
          UpdateAsync = function(_, key, transform)
            local value = transform(host.values[key])
            if value ~= nil then host.values[key] = value end
            return value
          end,
        } end }
      end
      if name == "World" then return {
        GetServerTime = function() return host.now end,
        FindFirstChild = function(_, name) return host.anchors[name] end,
      } end
      if name == "Players" then return { GetPlayers = function() return host.players or {} end } end
      error("未声明的服务 " .. tostring(name), 2)
    end,
  }

  package.loaded["server.Data.PlayerData"] = nil
  host.save = assert(loadfile("server/SaveHost.lua"))()
  host.player_data = assert(loadfile("server/PlayerDataHost.lua"))()
  host.save.PlayerData = host.player_data
  host.player_data.Save = host.save
  host.runtime = ServerRuntime.new({
    clock = host.clock,
    remote = host.remote,
    on_item_bar_state = function(player, snapshot)
      host.snapshots[player.UserId] = snapshot
      host.sync_counts = host.sync_counts or {}
      host.sync_counts[player.UserId] = (host.sync_counts[player.UserId] or 0) + 1
    end,
    save = host.save,
    player_data = host.player_data,
    quest = options.quest,
    players = function() return host.players or {} end,
    players_service = _G.game:GetService("Players"),
    world_service = _G.game:GetService("World"),
    bind_shop_action = function(dispatch)
      event("ShopAction").OnServerEvent:Connect(function(player, payload) dispatch(player, payload) end)
    end,
    bind_interact_action = function(dispatch)
      event("InteractAction").OnServerEvent:Connect(function(player, payload) dispatch(player, payload) end)
    end,
  })
  host.runtime:start()
  host.runtime:mark_started()

  function host:drain()
    for _ = 1, 500 do
      if #self.queue == 0 then return end
      table.remove(self.queue, 1)()
    end
    error("Task 队列未收敛")
  end

  function host:join(user_id, anchor_name, before_ready)
    local controller = {
      Health = GameCfg.Vitals.MaxHealth,
      MaxHealth = GameCfg.Vitals.MaxHealth,
      WalkSpeed = 16,
      HealthChanged = signal(),
      Died = signal(),
      OnReborn = signal(),
    }
    function controller:TakeDamage(amount)
      self.Health = math.max(0, self.Health - amount)
      self.HealthChanged:Fire(self.Health)
      if self.Health <= 0 then self.Died:Fire() end
    end
    local position = { x = 0, y = 0, z = 0 }
    if anchor_name and self.anchors[anchor_name] then
      local p = self.anchors[anchor_name].Position
      position = { x = p.x, y = p.y, z = p.z }
    end
    local player = {
      UserId = user_id,
      Name = "host-" .. tostring(user_id),
      CharacterAdded = signal(),
      CharacterRemoving = signal(),
      Character = {
        Position = position,
        Size = { y = 2 },
        Controller = controller,
      },
      SetAttribute = function(self, key, value)
        self.attrs = self.attrs or {}
        self.attrs[key] = value
      end,
      GetAttribute = function(self, key) return self.attrs and self.attrs[key] end,
    }
    self.results[user_id] = { ShopResult = {}, InteractResult = {} }
    self.players = self.players or {}
    self.players[#self.players + 1] = player
    self.player_data:OnPlayerAdded(player)
    self:drain()
    local data = assert(self.player_data:GetDataInst(player))
    if before_ready then before_ready(data) end
    self.runtime:on_player_added(player)
    self.runtime:on_save_ready(player, data)
    self:drain()
    return player, data
  end

  function host:leave(player)
    self.runtime:on_player_removing(player)
    self.player_data:OnPlayerRemoving(player)
    self:drain()
    for index, candidate in ipairs(self.players or {}) do
      if candidate == player then table.remove(self.players, index) break end
    end
  end

  function host:rejoin(player)
    self.player_data:OnPlayerAdded(player)
    self:drain()
    local data = assert(self.player_data:GetDataInst(player))
    self.players = self.players or {}
    self.players[#self.players + 1] = player
    self.results[player.UserId] = { ShopResult = {}, InteractResult = {} }
    self.runtime:on_player_added(player)
    self.runtime:on_save_ready(player, data)
    self:drain()
    return data
  end

  function host:send(player, channel, payload)
    local result_channel = channel == "ShopAction" and "ShopResult" or "InteractResult"
    local before = self.results[player.UserId] and self.results[player.UserId][result_channel]
    local count = before and #before or 0
    event(channel).OnServerEvent:Fire(player, payload)
    self:drain()
    local list = self.results[player.UserId] and self.results[player.UserId][result_channel]
    local size = list and #list or 0
    return size > count and list[size] or nil, size, count
  end

  function host:act(player, channel, payload)
    self.seq[player.UserId] = (self.seq[player.UserId] or 0) + 1
    if payload.seq == nil then payload.seq = self.seq[player.UserId] end
    return self:send(player, channel, payload)
  end

  function host:last(player, channel)
    local list = self.results[player.UserId] and self.results[player.UserId][channel]
    return list and list[#list] or nil
  end

  function host:shutdown()
    self.runtime:shutdown()
    _G.game = self.saved.game
    _G.REUtil = self.saved.REUtil
    package.loaded["common.re_util"] = self.saved.reutil
    GameCfg.Debug = self.saved.debug
  end

  return host
end

return Host
