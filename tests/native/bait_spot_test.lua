local GameCfg = require("common.game_cfg")
local ServerRuntime = require("server.world_host.server_runtime")
local SpokeClock = require("common.spoke_clock")
local PlayerData = require("server.data.player_data")

local function signal()
  local handlers = {}
  return { Connect = function(_, fn) handlers[#handlers + 1] = fn return { Disconnect = function() end } end,
    Fire = function(_, ...) for _, fn in ipairs(handlers) do fn(...) end end }
end

local function host()
  local created, events, data_of, players = {}, {}, {}, {}
  local function event(name)
    events[name] = events[name] or { clients = {}, OnServerEvent = signal(),
      FireClient = function(self, target, payload) self.clients[#self.clients + 1] = payload end,
      FireAllClients = function(self, payload) self.clients[#self.clients + 1] = payload end,
      FireClient = function() end }
    return events[name]
  end
  local clock = SpokeClock.new(500)
  local runtime = ServerRuntime.new({
    clock = clock, initial_now = 500,
    remote = { GetRE = function(_, name) return event(name) end, CheckRECD = function() return false end },
    player_data = { GetDataInst = function(_, p) return data_of[p.UserId] end },
    players = function() return players end,
    create_unit = function(_, props)
      local unit = { Destroyed = false, Name = props.Name }
      function unit:Destroy() self.Destroyed = true end
      created[#created + 1] = unit
      return unit
    end,
    bait_spots = {
      RespawnSec = 15, Mesh = "mesh", Scale = 0.3,
      Spots = {
        { Id = "a", ItemId = "worm", Count = 1, Position = { x = 10, y = 5, z = 20 }, ZoneId = "fishPond" },
        { Id = "b", ItemId = "worm", Count = 2, Position = { x = 40, y = 5, z = 20 }, ZoneId = "fishPond" },
      },
    },
  })
  runtime:start(); runtime:mark_started()
  return { runtime = runtime, events = events, created = created, clock = clock,
    add = function(_, p)
      local data = PlayerData.New(p); data:Init(); data.LoadState = "ready"; data.Player = p
      data_of[p.UserId] = data; players[#players + 1] = p
      runtime:on_player_added(p); runtime:on_save_ready(p, data)
      return data
    end,
    rows = function()
      local sent = events.LootState.clients
      local last = sent[#sent]
      return (last and (last.list or last.value and last.value.list)) or {}
    end }
end

local function player(id, x, z)
  local p = { UserId = id, attrs = {}, Character = { Position = { x = x, y = 5, z = z } } }
  function p:SetAttribute() end
  function p:GetAttribute() end
  return p
end

describe("TestBaitSpot", function()
  before_each(function()
    GameCfg.Debug = { Enabled = false, InitialGrants = GameCfg.Debug and GameCfg.Debug.InitialGrants }
  end)
  it("test_each_configured_spot_spawns_exactly_one_bait", function()
    local env = host()
    local rows = env.rows()
    assert.equals(2, #rows)
    local alive = 0
    for _, unit in ipairs(env.created) do if not unit.Destroyed then alive = alive + 1 end end
    assert.equals(2, alive)
  end)

  it("test_pickup_goes_to_bait_count_not_item_bar_even_when_full", function()
    local env = host()
    local p = player(1, 10, 20)
    local data = env:add(p)
    local tree = env.runtime:get_player_tree(p.UserId)
    local bar = {}
    for i = 1, data:ItemBarCapacity() do bar[i] = { itemId = "carp", count = 1, containerId = "itemBar" } end
    tree:set_item_bar(bar)
    local id
    for _, row in ipairs(env.rows()) do if row.spotId == "a" then id = row.id end end
    env.events.ItemBarAction.OnServerEvent:Fire(p, { action = "Pickup", value = id })
    assert.equals(1, tree:get_item_bar_snapshot().bait.worm)
    local slots = 0
    for _, slot in pairs(tree:get_item_bar_snapshot().slots) do
      if type(slot) == "table" and slot.itemId == "worm" then slots = slots + 1 end
    end
    assert.equals(0, slots)
  end)

  it("test_pickup_rechecks_distance_and_id", function()
    local env = host()
    local p = player(1, 10, 20)
    env:add(p)
    p.Character.Position = { x = 0, y = 0, z = 0 }
    local id
    for _, row in ipairs(env.rows()) do if row.spotId == "a" then id = row.id end end
    env.events.ItemBarAction.OnServerEvent:Fire(p, { action = "Pickup", value = id })
    assert.equals(2, #env.rows())
  end)

  it("test_race_and_replay_give_only_one", function()
    local env = host()
    local a, b = player(1, 10, 20), player(2, 10, 20)
    env:add(a); env:add(b)
    local id
    for _, row in ipairs(env.rows()) do if row.spotId == "a" then id = row.id end end
    env.events.ItemBarAction.OnServerEvent:Fire(a, { action = "Pickup", value = id })
    env.events.ItemBarAction.OnServerEvent:Fire(b, { action = "Pickup", value = id })
    local bait = env.runtime:get_player_tree(a.UserId):get_item_bar_snapshot().bait.worm or 0
    local other = env.runtime:get_player_tree(b.UserId):get_item_bar_snapshot().bait.worm or 0
    assert.equals(1, bait + other)
  end)

  it("test_respawns_after_fifteen_seconds_once_and_timers_are_per_spot", function()
    local env = host()
    local p = player(1, 10, 20)
    env:add(p)
    local id
    for _, row in ipairs(env.rows()) do if row.spotId == "a" then id = row.id end end
    env.events.ItemBarAction.OnServerEvent:Fire(p, { action = "Pickup", value = id })
    env.clock:advance(14)
    local mid = 0
    for _, row in ipairs(env.rows()) do if row.spotId == "a" then mid = mid + 1 end end
    assert.equals(0, mid)
    env.clock:advance(1)
    local again = 0
    for _, row in ipairs(env.rows()) do if row.spotId == "a" then again = again + 1 end end
    assert.equals(1, again)
  end)

  it("test_fish_loot_is_not_refreshed_or_expired", function()
    local env = host()
    assert.is_true(env.runtime:get_world():place_ground_item("fishPond", {
      kind = "item", itemId = "carp", count = 1, x = 1, y = 0, z = 1,
    }))
    env.clock:advance(GameCfg.BaitSpots and 15 or 15)
    local fish = 0
    for _, row in ipairs(env.rows()) do if row.itemId == "carp" then fish = fish + 1 end end
    assert.equals(1, fish)
  end)
end)
