local GameCfg = require("common.game_cfg")
local ServerRuntime = require("server.world_host.server_runtime")
local SpokeClock = require("common.spoke_clock")
local PlayerData = require("server.data.player_data")

local function signal()
  local handlers = {}
  return { Connect = function(_, fn) handlers[#handlers + 1] = fn return { Disconnect = function() end } end,
    Fire = function(_, ...) for _, fn in ipairs(handlers) do fn(...) end end }
end

local function open()
  local events, created, data_of, players = {}, {}, {}, {}
  local function event(name)
    events[name] = events[name] or { clients = {}, OnServerEvent = signal(),
      FireAllClients = function(self, payload) self.clients[#self.clients + 1] = payload end,
      FireClient = function(self, _, payload) self.clients[#self.clients + 1] = payload end }
    return events[name]
  end
  local clock = SpokeClock.new(20)
  local runtime = ServerRuntime.new({
    clock = clock, initial_now = 20,
    remote = { get_re = function(_, n) return event(n) end, check_recd = function() return false end },
    player_data = { get_data_inst = function(_, p) return data_of[p.UserId] end },
    players = function() return players end,
    create_unit = function()
      local unit = { Destroyed = false }
      function unit:Destroy() self.Destroyed = true end
      created[#created + 1] = unit
      return unit
    end,
    bait_spots = { RespawnSec = 15, Spots = {} },
  })
  runtime:start(); runtime:mark_started(); ServerRuntime.set_current(runtime)
  local api = { runtime = runtime, events = events, created = created }
  function api:add(id, x, z)
    local p = { UserId = id, attrs = {}, Character = { Position = { x = x or 0, y = 0, z = z or 0 } } }
    function p:SetAttribute(k, v) self.attrs[k] = v end
    function p:GetAttribute(k) return self.attrs[k] end
    local data = PlayerData.new(p); data:Init(); data.load_state = "ready"; data.Player = p
    data_of[id] = data; players[#players + 1] = p
    runtime:on_player_added(p); runtime:on_save_ready(p, data)
    return p, data
  end
  function api:rows()
    local sent = events.LootState.clients
    return sent[#sent] and sent[#sent].list or {}
  end
  function api:alive()
    local n = 0
    for _, unit in ipairs(created) do if not unit.Destroyed then n = n + 1 end end
    return n
  end
  function api:drop(p, index)
    events.ItemBarAction.OnServerEvent:Fire(p, { action = "Drop", container = "itemBar", index = index or 1 })
  end
  function api:pickup(p, id)
    events.ItemBarAction.OnServerEvent:Fire(p, { action = "Pickup", value = id })
  end
  function api:close()
    runtime:shutdown()
    if ServerRuntime.current and ServerRuntime.current() == runtime then ServerRuntime.set_current(nil) end
  end
  return api
end

describe("共享掉落的地面侧", function()
  before_each(function()
    GameCfg.Debug = { Enabled = false, InitialGrants = GameCfg.Debug and GameCfg.Debug.InitialGrants }
  end)
  it("test_operate_discard_moves_one_item_to_ground", function()
    local env = open()
    local p = env:add(1, 3, 4)
    local tree = env.runtime:get_player_tree(1)
    tree:set_item_bar({ [1] = { itemId = "carp", count = 1, containerId = "itemBar", mult = 1.37 } })
    tree:set_zone("fishPond")
    env:drop(p, 1)
    assert.equals(1, env:alive())
    assert.is_nil(tree:get_item_bar_snapshot().slots[1])
    assert.equals("carp", env:rows()[1].itemId)
    assert.equals(1.37, env:rows()[1].mult)
    env:close()
  end)

  it("test_duplicate_discard_pickup_and_race_never_duplicate", function()
    local env = open()
    local a = env:add(1, 1, 1)
    env:add(2, 1, 1)
    env.runtime:get_player_tree(1):set_zone("fishPond")
    env.runtime:get_player_tree(1):set_item_bar({ [1] = { itemId = "carp", count = 1, containerId = "itemBar" } })
    env:drop(a, 1)
    env:drop(a, 1)
    assert.equals(1, env:alive())
    local id = env:rows()[1].id
    env:pickup(a, id)
    env:pickup(env.runtime.life:player_by_user_id(2), id)
    local held, other = 0, 0
    for _, slot in pairs(env.runtime:get_player_tree(1):get_item_bar_snapshot().slots) do
      if type(slot) == "table" and slot.itemId == "carp" then held = held + 1 end
    end
    for _, slot in pairs(env.runtime:get_player_tree(2):get_item_bar_snapshot().slots) do
      if type(slot) == "table" and slot.itemId == "carp" then other = other + 1 end
    end
    assert.equals(1, held + other)
    assert.equals(0, env:alive())
    env:close()
  end)

  it("test_full_inventory_keeps_loot_on_ground", function()
    local env = open()
    local p, data = env:add(1, 0, 0)
    local tree = env.runtime:get_player_tree(1)
    local full, pack = {}, {}
    for i = 1, data:ItemBarCapacity() do full[i] = { itemId = "bass", count = 1, containerId = "itemBar" } end
    for i = 1, data:BackpackCapacity() do pack[i] = { itemId = "bass", count = 1, containerId = "backpack" } end
    tree:set_item_bar(full)
    tree:set_backpack(pack)
    assert.is_true(env.runtime:get_world():place_ground_item("fishPond", { kind = "item", itemId = "carp", count = 1, x = 0, y = 0, z = 0 }))
    env:pickup(p, env:rows()[1].id)
    assert.equals(1, env:alive())
    env:close()
  end)

  it("test_pickup_restores_mult_and_cooked_state", function()
    local env = open()
    local p = env:add(1, 2, 2)
    assert.is_true(env.runtime:get_world():place_ground_item("fishPond", {
      kind = "item", itemId = "carp", count = 1, mult = 1.37, cooked = 2, x = 2, y = 0, z = 2,
    }))
    env:pickup(p, env:rows()[1].id)
    local slot = env.runtime:get_player_tree(1):get_item_bar_snapshot().slots[1]
    assert.equals("carp", slot.itemId)
    assert.equals(1.37, slot.mult)
    assert.equals(2, slot.cooked)
    env:close()
  end)

  it("test_pickup_returns_bait_to_bait_count", function()
    local env = open()
    local p = env:add(1, 1, 1)
    env.runtime:get_world():place_ground_item("fishPond", { kind = "bait", itemId = "worm", count = 2, x = 1, y = 0, z = 1 })
    env:pickup(p, env:rows()[1].id)
    assert.equals(2, env.runtime:get_player_tree(1):get_item_bar_snapshot().bait.worm)
    env:close()
  end)

  it("test_spawn_failure_never_deducts", function()
    local env = open()
    local p = env:add(1, 1, 1)
    local tree = env.runtime:get_player_tree(1)
    tree:set_item_bar({ [1] = { itemId = "carp", count = 1, containerId = "itemBar" } })
    tree.states.life_phase:set("dead")
    env:drop(p, 1)
    assert.equals("carp", tree:get_item_bar_snapshot().slots[1].itemId)
    assert.equals(0, env:alive())
    env:close()
  end)

  it("test_snapshot_carries_warning_flag", function()
    local saved = GameCfg.Loot
    local loot = {}
    for k, v in pairs(saved) do loot[k] = v end
    loot.PerZoneCap = 1
    GameCfg.Loot = loot
    local env = open()
    local world = env.runtime:get_world()
    world:place_ground_item("fishPond", { kind = "item", itemId = "carp", count = 1, x = 1, y = 0, z = 0 })
    world:place_ground_item("fishPond", { kind = "item", itemId = "bass", count = 1, x = 2, y = 0, z = 0 })
    local warned = 0
    for _, row in ipairs(env:rows()) do if row.warn then warned = warned + 1 end end
    assert.equals(1, warned)
    GameCfg.Loot = saved
    env:close()
  end)
end)
