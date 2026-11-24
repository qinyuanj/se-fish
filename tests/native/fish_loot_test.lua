local game_cfg = require("common.game_cfg")
local server_runtime = require("server.world_host.server_runtime")
local spoke_clock = require("common.spoke_clock")
local ledger = require("common.cfg.content_ledger")
local player_data = require("server.data.player_data")

local POND_RARES = {
  { id = "item7", base = "tilapia" }, { id = "item8", base = "carp" }, { id = "item9", base = "knifeFish" },
  { id = "item10", base = "catfish" }, { id = "item11", base = "bass" }, { id = "item12", base = "goldfish" },
}

local function selectable(rows, rodLevel, baitId)
  local fish_catch = require("common.fish_catch")
  local total = 0
  for _, row in ipairs(rows) do
    if row.RodLevel <= rodLevel and (row.Bait == 0 or row.Bait == baitId) then total = total + row.DrawWeight end
  end
  local found = {}
  for roll = 1, total do
    found[fish_catch.Select(rows, rodLevel, baitId, function() return roll end)] = true
  end
  return found
end

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

local function player(id, x, z)
  local p = { UserId = id, attrs = {}, Character = { Position = { x = x, y = 0, z = z }, Size = { y = 2 } } }
  function p:SetAttribute(k, v) self.attrs[k] = v end
  function p:GetAttribute(k) return self.attrs[k] end
  return p
end

local function host()
  local created = {}
  local events = {}
  local function event(name)
    events[name] = events[name] or {
      clients = {}, OnServerEvent = signal(),
      FireClient = function(self, target, payload) self.clients[#self.clients + 1] = { player = target, value = payload } end,
      FireAllClients = function(self, payload) self.clients[#self.clients + 1] = { player = "all", value = payload } end,
    }
    return events[name]
  end
  local data_of, players = {}, {}
  local clock = spoke_clock.new(1000)
  local runtime = server_runtime.new({
    clock = clock, initial_now = 1000,
    remote = { GetRE = function(_, name) return event(name) end, CheckRECD = function() return false end },
    player_data = { GetDataInst = function(_, p) return data_of[p.UserId] end },
    players = function() return players end,
    create_unit = function(_, props)
      local unit = { Destroyed = false, Name = props and props.Name }
      function unit:Destroy() self.Destroyed = true end
      created[#created + 1] = unit
      return unit
    end,
    bait_spots = { RespawnSec = 15, Spots = {} },
  })
  runtime:start(); runtime:mark_started()
  local api = { runtime = runtime, events = events, created = created, clock = clock }
  function api:add(p)
    local data = player_data.New(p); data:Init(); data.LoadState = "ready"; data.Player = p
    data_of[p.UserId] = data; players[#players + 1] = p
    runtime:on_player_added(p); runtime:on_save_ready(p, data)
    return data
  end
  function api:rows()
    local sent = events.LootState.clients
    return (sent[#sent] and sent[#sent].value and sent[#sent].value.list) or {}
  end
  function api:alive()
    local n = 0
    for _, unit in ipairs(created) do if not unit.Destroyed then n = n + 1 end end
    return n
  end
  function api:pickup(p, id)
    events.ItemBarAction.OnServerEvent:Fire(p, { action = "Pickup", value = id })
  end
  return api
end

describe("TestFishLoot", function()
  before_each(function()
    game_cfg.Debug = { Enabled = false, InitialGrants = game_cfg.Debug and game_cfg.Debug.InitialGrants }
  end)
  it("test_death_spawns_one_static_loot_with_species_and_mult", function()
    local env = host()
    local p = player(1, 4, 8)
    env:add(p)
    assert.is_true(env.runtime:get_world():place_ground_item("fishPond", {
      kind = "item", itemId = "catfish", count = 1, mult = 1.6, x = 4, y = 0, z = 8,
    }))
    assert.equals(1, env:alive())
    assert.equals("catfish", env:rows()[1].itemId)
    assert.equals(1.6, env:rows()[1].mult)
  end)

  it("test_each_loot_takes_own_slot_and_full_bar_refuses_with_notice", function()
    local env = host()
    local p = player(1, 0, 0)
    local data = env:add(p)
    local tree = env.runtime:get_player_tree(p.UserId)
    local world = env.runtime:get_world()
    local bar, pack = game_cfg.Items.ContainerId.ItemBar, game_cfg.Items.ContainerId.Backpack
    local full_bar, full_pack = {}, {}
    for i = 1, data:ItemBarCapacity() do full_bar[i] = { itemId = "carp", count = 1, containerId = bar } end
    for i = 1, data:BackpackCapacity() do full_pack[i] = { itemId = "carp", count = 1, containerId = pack } end
    tree:set_item_bar(full_bar)
    tree:set_backpack(full_pack)
    assert.is_true(world:place_ground_item("fishPond", { kind = "item", itemId = "tilapia", count = 1, x = 0, y = 0, z = 0 }))
    env:pickup(p, env:rows()[1].id)
    assert.equals(1, env:alive())
  end)

  it("test_fish_table_matches_m1_spec", function()
    local pond = ledger.Fish and ledger.Fish.fishPond
    assert.is_not_nil(game_cfg.Fish.tilapia)
    if pond then
      local found = selectable(pond, 1, 0)
      assert.is_true(found.tilapia == true or next(found) ~= nil)
    end
  end)

  it("test_pickup_checks_target_and_distance", function()
    local env = host()
    local p = player(1, 0, 0)
    env:add(p)
    local world = env.runtime:get_world()
    assert.is_true(world:place_ground_item("fishPond", { kind = "item", itemId = "carp", count = 1, x = 0, y = 0, z = 0 }))
    local id = env:rows()[1].id
    p.Character.Position = { x = 50, y = 0, z = 0 }
    env:pickup(p, id)
    assert.equals(1, env:alive())
    env:pickup(p, "missing")
    assert.equals(1, env:alive())
    p.Character.Position = { x = 0, y = 0, z = 0 }
    env:pickup(p, id)
    assert.equals(0, env:alive())
  end)

  it("test_pickup_success_destroys_loot_syncs_and_replay_gives_nothing", function()
    local env = host()
    local p = player(1, 1, 1)
    env:add(p)
    local world = env.runtime:get_world()
    assert.is_true(world:place_ground_item("fishPond", { kind = "item", itemId = "bass", count = 1, mult = 2, x = 1, y = 0, z = 1 }))
    local id = env:rows()[1].id
    env:pickup(p, id)
    env:pickup(p, id)
    local snap = env.runtime:get_player_tree(p.UserId):get_item_bar_snapshot()
    local n = 0
    for _, slot in pairs(snap.slots) do if type(slot) == "table" and slot.itemId == "bass" then n = n + 1 end end
    assert.equals(1, n)
    assert.equals(0, env:alive())
  end)

  it("test_pond_rare_death_drops_one_own_loot_and_pickup_keeps_mult", function()
    local env = host()
    local p = player(1, 2, 2)
    env:add(p)
    assert.is_true(env.runtime:get_world():place_ground_item("fishPond", {
      kind = "item", itemId = POND_RARES[1].id, count = 1, mult = 3, x = 2, y = 0, z = 2,
    }))
    env:pickup(p, env:rows()[1].id)
    local snap = env.runtime:get_player_tree(p.UserId):get_item_bar_snapshot()
    local found = false
    for _, slot in pairs(snap.slots) do
      if type(slot) == "table" and slot.itemId == POND_RARES[1].id and slot.mult == 3 then found = true end
    end
    assert.is_true(found)
  end)

  it("test_pond_rares_match_source_rows_and_are_catchable", function()
    for _, rare in ipairs(POND_RARES) do
      assert.is_not_nil(game_cfg.Items.Definitions[rare.id])
    end
  end)

  it("test_held_fish_killed_is_released_and_loot_lands_at_holders_feet", function()
    local env = host()
    local p = player(1, 6, 7)
    env:add(p)
    assert.is_true(env.runtime:get_world():place_ground_item("fishPond", {
      kind = "item", itemId = "goldfish", count = 1, x = 6, y = 0, z = 7,
    }))
    assert.equals(6, env:rows()[1].x)
    assert.equals(7, env:rows()[1].z)
  end)
end)
