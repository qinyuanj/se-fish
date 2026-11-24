local PlayerData = require("server.data.player_data")
local ServerRuntime = require("server.world_host.server_runtime")
local SpokeClock = require("common.spoke_clock")

local M = {}

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

function M.signal()
  return signal()
end

function M.player(id, x, z)
  local controller = {
    Health = 300, MaxHealth = 300, WalkSpeed = 16,
    HealthChanged = signal(), Died = signal(), OnReborn = signal(),
    damages = {}, diedCount = 0, reborns = 0,
  }
  function controller:TakeDamage(amount)
    self.damages[#self.damages + 1] = amount
    self.Health = math.max(0, self.Health - amount)
    self.HealthChanged:Fire(self.Health)
    if self.Health <= 0 then
      self.diedCount = self.diedCount + 1
      self.Died:Fire()
    end
  end
  function controller:Reborn()
    self.reborns = self.reborns + 1
    self.Health = self.MaxHealth
    self.OnReborn:Fire()
  end
  local player = {
    UserId = id, Name = "p" .. tostring(id), attrs = {},
    CharacterAdded = signal(), CharacterRemoving = signal(),
    Character = {
      Controller = controller,
      Position = { x = x or 0, y = 0, z = z or 0 },
      Size = { y = 2 },
    },
  }
  function player:SetAttribute(key, value) self.attrs[key] = value end
  function player:GetAttribute(key) return self.attrs[key] end
  return player
end

function M.start(opts)
  opts = type(opts) == "table" and opts or {}
  local now = opts.now or 100
  local clock = opts.clock or SpokeClock.new(now)
  local players = {}
  local data_of = {}
  local events = {}
  local function event(name)
    events[name] = events[name] or {
      clients = {},
      OnServerEvent = signal(),
      FireClient = function(self, target, payload)
        self.clients[#self.clients + 1] = { player = target, value = payload }
      end,
      FireAllClients = function(self, payload)
        self.clients[#self.clients + 1] = { player = "all", value = payload }
      end,
    }
    return events[name]
  end
  local remote = opts.remote or {
    GetRE = function(_, name) return event(name) end,
    CheckRECD = function() return false end,
  }
  local runtime = ServerRuntime.new({
    clock = clock,
    initial_now = now,
    remote = remote,
    player_data = opts.player_data or { GetDataInst = function(_, player) return data_of[player.UserId] end },
    save = opts.save,
    platform = opts.platform,
    fish_carrier = opts.fish_carrier,
    speed_writer = opts.speed_writer,
    growth_writer = opts.growth_writer,
    on_player_downed = opts.on_player_downed,
    max_health_of = opts.max_health_of,
    players = function() return players end,
    damage_filter = opts.damage_filter or function() return true end,
    bait_spots = opts.bait_spots or { Enabled = false },
    session_epoch = opts.session_epoch,
    zones = opts.zones,
    zone_markers = opts.zone_markers,
    bind_interact_action = opts.bind_interact_action,
    bind_party_action = opts.bind_party_action or function(dispatch)
      remote:GetRE("PartyAction").OnServerEvent:Connect(function(player, payload) dispatch(player, payload) end)
    end,
    bind_party_state_request = opts.bind_party_state_request or function(dispatch)
      remote:GetRE("PartyStateRequest").OnServerEvent:Connect(function(player) dispatch(player) end)
    end,
  })
  runtime:start()
  runtime:mark_started()
  local host = { runtime = runtime, clock = clock, events = events, remote = remote }
  function host:add(player, data)
    if type(player.SetAttribute) ~= "function" then
      player.attrs = player.attrs or {}
      function player:SetAttribute(key, value) self.attrs[key] = value end
      function player:GetAttribute(key) return self.attrs[key] end
    end
    data = data or PlayerData.New(player)
    if not data.Inited then data:Init() end
    data.LoadState = "ready"
    data.Player = player
    data_of[player.UserId] = data
    players[#players + 1] = player
    runtime:on_player_added(player)
    runtime:on_save_ready(player, data)
    return data
  end
  function host:advance(seconds)
    if type(opts.before_advance) == "function" then opts.before_advance() end
    clock:advance(seconds)
    return self
  end
  function host:tree(player)
    return runtime:get_player_tree(player.UserId)
  end
  function host:remove(player)
    runtime:on_player_removing(player)
    data_of[player.UserId] = nil
    for index, candidate in ipairs(players) do
      if candidate == player then table.remove(players, index) break end
    end
  end
  function host:phase(player, name)
    local tree = runtime:get_player_tree(player.UserId)
    if tree then tree.states.life_phase:set(name) end
    return tree
  end
  function host:shutdown()
    runtime:shutdown()
  end
  return host
end

return M
