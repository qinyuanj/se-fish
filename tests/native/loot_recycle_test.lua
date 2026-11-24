local GameCfg = require("common.game_cfg")
local ServerRuntime = require("server.WorldHost.ServerRuntime")
local SpokeClock = require("common.spoke_clock")
local PlayerData = require("server.Data.PlayerData")

local function signal()
  local handlers = {}
  return { Connect = function(_, fn) handlers[#handlers + 1] = fn return { Disconnect = function() end } end,
    Fire = function(_, ...) for _, fn in ipairs(handlers) do fn(...) end end }
end

local function open(cap)
  local saved = GameCfg.Loot
  local loot = {}
  for k, v in pairs(saved) do loot[k] = v end
  if cap then loot.PerZoneCap = cap end
  GameCfg.Loot = loot
  local created, events = {}, {}
  local function event(name)
    events[name] = events[name] or { clients = {}, OnServerEvent = signal(),
      FireAllClients = function(self, payload) self.clients[#self.clients + 1] = payload end,
      FireClient = function(self, _, payload) self.clients[#self.clients + 1] = payload end }
    return events[name]
  end
  local clock = SpokeClock.new(100)
  local data_of, players = {}, {}
  local runtime = ServerRuntime.new({
    clock = clock, initial_now = 100,
    remote = { GetRE = function(_, n) return event(n) end, CheckRECD = function() return false end },
    player_data = { GetDataInst = function(_, p) return data_of[p.UserId] end },
    players = function() return players end,
    create_unit = function()
      local unit = { Destroyed = false }
      function unit:Destroy() self.Destroyed = true end
      created[#created + 1] = unit
      return unit
    end,
    bait_spots = { RespawnSec = 15, Spots = {} },
  })
  runtime:start(); runtime:mark_started()
  return {
    saved = saved, runtime = runtime, events = events, created = created, clock = clock,
    add = function(_, p)
      local data = PlayerData.New(p); data:Init(); data.LoadState = "ready"; data.Player = p
      data_of[p.UserId] = data; players[#players + 1] = p
      runtime:on_player_added(p); runtime:on_save_ready(p, data)
    end,
    rows = function()
      local sent = events.LootState.clients
      return sent[#sent] and sent[#sent].list or {}
    end,
    alive = function()
      local n = 0
      for _, unit in ipairs(created) do if not unit.Destroyed then n = n + 1 end end
      return n
    end,
  }
end

local function player(id, x, z)
  local p = { UserId = id, attrs = {}, Character = { Position = { x = x or 0, y = 0, z = z or 0 } } }
  function p:SetAttribute() end
  function p:GetAttribute() end
  return p
end

describe("TestLootRecycle", function()
  before_each(function()
    GameCfg.Debug = { Enabled = false, InitialGrants = GameCfg.Debug and GameCfg.Debug.InitialGrants }
  end)
  local env
  after_each(function()
    if env then GameCfg.Loot = env.saved; env.runtime:shutdown() end
  end)

  it("test_config_has_per_zone_cap_and_flash_seconds", function()
    assert.equals(200, GameCfg.Loot.PerZoneCap)
    assert.equals(30, GameCfg.Loot.FlashBeforeRecycleSec)
  end)

  it("test_over_cap_marks_oldest_recycling_and_count_stays_visible_until_flash", function()
    env = open(3)
    local world = env.runtime:get_world()
    for i = 1, 4 do
      assert.is_true(world:place_ground_item("fishPond", { kind = "item", itemId = "carp", count = 1, x = i, y = 0, z = 0 }))
    end
    local warned = 0
    for _, row in ipairs(env.rows()) do if row.warn then warned = warned + 1 end end
    assert.equals(1, warned)
    assert.equals(4, env.alive())
    env.clock:advance(30)
    assert.equals(3, env.alive())
  end)

  it("test_fifo_order_recycles_next_oldest_not_newest", function()
    env = open(1)
    local world = env.runtime:get_world()
    world:place_ground_item("fishPond", { kind = "item", itemId = "carp", count = 1, x = 1, y = 0, z = 0 })
    world:place_ground_item("fishPond", { kind = "item", itemId = "bass", count = 1, x = 2, y = 0, z = 0 })
    env.clock:advance(30)
    local left = {}
    for _, row in ipairs(env.rows()) do left[#left + 1] = row.itemId end
    assert.same({ "bass" }, left)
  end)

  it("test_pickup_of_recycling_loot_cancels_recycle", function()
    env = open(1)
    local p = player(1, 1, 0)
    env:add(p)
    local world = env.runtime:get_world()
    world:place_ground_item("fishPond", { kind = "item", itemId = "carp", count = 1, x = 1, y = 0, z = 0 })
    world:place_ground_item("fishPond", { kind = "item", itemId = "bass", count = 1, x = 2, y = 0, z = 0 })
    local oldest
    for _, row in ipairs(env.rows()) do if row.warn then oldest = row.id end end
    p.Character.Position = { x = 1, y = 0, z = 0 }
    env.events.ItemBarAction.OnServerEvent:Fire(p, { action = "Pickup", value = oldest })
    env.clock:advance(30)
    assert.equals(1, env.alive())
  end)

  it("test_zones_are_counted_independently", function()
    env = open(1)
    local world = env.runtime:get_world()
    world:place_ground_item("fishPond", { kind = "item", itemId = "carp", count = 1, x = 1, y = 0, z = 0 })
    world:place_ground_item("shrimpPond", { kind = "item", itemId = "shrimp", count = 1, x = 2, y = 0, z = 0 })
    local warned = 0
    for _, row in ipairs(env.rows()) do if row.warn then warned = warned + 1 end end
    assert.equals(0, warned)
    assert.equals(2, env.alive())
  end)

  it("test_picked_loot_frees_zone_count", function()
    env = open(1)
    local p = player(1, 1, 0)
    env:add(p)
    local world = env.runtime:get_world()
    world:place_ground_item("fishPond", { kind = "item", itemId = "carp", count = 1, x = 1, y = 0, z = 0 })
    env.events.ItemBarAction.OnServerEvent:Fire(p, { action = "Pickup", value = env.rows()[1].id })
    world:place_ground_item("fishPond", { kind = "item", itemId = "bass", count = 1, x = 1, y = 0, z = 0 })
    local warned = 0
    for _, row in ipairs(env.rows()) do if row.warn then warned = warned + 1 end end
    assert.equals(0, warned)
  end)
end)
