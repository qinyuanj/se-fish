
local GameCfg = require("common.game_cfg")
local ServerRuntime = require("server.world_host.server_runtime")
local SpokeClock = require("common.spoke_clock")
local SpokeRuntime = require("common.packages.spoke.runtime.spoke_runtime")

local ZONE_ID = "fishPond"
local BAIT_ID = "worm"
local ITEM_ID = "tilapia"

local function signal()
  local handlers = {}
  return {
    Connect = function(_, fn)
      handlers[#handlers + 1] = fn
      return {
        Disconnect = function()
          for i, h in ipairs(handlers) do
            if h == fn then table.remove(handlers, i) return end
          end
        end,
      }
    end,
    Fire = function(_, ...)
      for _, fn in ipairs({ table.unpack(handlers) }) do fn(...) end
    end,
  }
end

local function make_player(id, x, z)
  local player = {
    UserId = id,
    Name = "p" .. tostring(id),
    attrs = {},
    Character = {
      Position = { x = x or 0, y = 0, z = z or 0 },
      Size = { y = 2 },
    },
  }
  function player:SetAttribute(key, value) self.attrs[key] = value end
  function player:GetAttribute(key) return self.attrs[key] end
  return player
end

local function host(opts)
  opts = opts or {}
  local created = {}
  local next_unit = 0
  local function create_unit(unit_type, props)
    next_unit = next_unit + 1
    local unit = {
      Id = next_unit,
      UnitType = unit_type,
      Destroyed = false,
      ModelVisible = true,
    }
    if type(props) == "table" then
      for k, v in pairs(props) do unit[k] = v end
    end
    function unit:Destroy()
      self.Destroyed = true
    end
    created[#created + 1] = unit
    return unit
  end

  local now = opts.now or 1000
  local clock = SpokeClock.new(now)
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

  local PlayerData = require("server.data.player_data")
  local runtime = ServerRuntime.new({
    clock = clock,
    initial_now = now,
    remote = {
      get_re = function(_, name) return event(name) end,
      check_recd = function() return false end,
    },
    player_data = { get_data_inst = function(_, player) return data_of[player.UserId] end },
    players = function() return players end,
    create_unit = opts.create_unit or create_unit,
    zones = opts.zones,
    bait_spots = opts.bait_spots,
  })
  runtime:start()
  runtime:mark_started()

  local api = {
    runtime = runtime,
    clock = clock,
    events = events,
    created = created,
  }

  function api:add(player, data)
    data = data or PlayerData.new(player)
    if not data.Inited then data:Init() end
    data.LoadState = "ready"
    data.Player = player
    data_of[player.UserId] = data
    players[#players + 1] = player
    runtime:on_player_added(player)
    runtime:on_save_ready(player, data)
    return data
  end

  function api:advance(seconds)
    clock:advance(seconds)
  end

  function api:loot_state()
    local sent = events.LootState and events.LootState.clients or {}
    return sent[#sent] and sent[#sent].value or nil
  end

  function api:alive_units()
    local n = 0
    for _, unit in ipairs(created) do
      if not unit.Destroyed then n = n + 1 end
    end
    return n
  end

  function api:shutdown()
    runtime:shutdown()
  end

  return api
end

local function count_rows(snapshot, zone_id)
  local n = 0
  local list = type(snapshot) == "table" and (snapshot.list or snapshot) or {}
  if type(list) ~= "table" then return 0 end
  for _, row in pairs(list) do
    if type(row) == "table" and (zone_id == nil or row.zoneId == zone_id or row.zone == zone_id) then
      n = n + 1
    end
  end
  return n
end

local function find_row(snapshot, id)
  local list = type(snapshot) == "table" and (snapshot.list or snapshot) or {}
  for _, row in pairs(list) do
    if type(row) == "table" and (row.id == id or row.Id == id) then return row end
  end
end

local function fire_pickup(env, player, id)
  env.events.ItemBarAction.OnServerEvent:Fire(player, { action = "Pickup", value = id })
end

local function fire_drop(env, player, payload)
  env.events.ItemBarAction.OnServerEvent:Fire(player, payload)
end

describe("钓鱼区地面物品与鱼饵刷新（#301 服务端宿主）", function()
  local saved_loot, saved_spots, saved_debug

  before_each(function()
    saved_loot = GameCfg.Loot
    saved_spots = GameCfg.BaitSpots
    saved_debug = GameCfg.Debug
    local loot = {}
    for k, v in pairs(saved_loot) do loot[k] = v end
    GameCfg.Loot = loot
    GameCfg.Debug = { Enabled = false, InitialGrants = saved_debug and saved_debug.InitialGrants }
  end)

  after_each(function()
    GameCfg.Loot = saved_loot
    GameCfg.BaitSpots = saved_spots
    GameCfg.Debug = saved_debug
  end)

  it("单区超过 200 件时最早的一件进入 30 秒闪烁并到期销毁", function()
    local env = host({
      bait_spots = { RespawnSec = 15, Mesh = "mesh", Scale = 0.3, Spots = {} },
    })
    local player = make_player(1, 0, 0)
    local data = env:add(player)
    local tree = env.runtime:get_player_tree(player.UserId)
    assert.is_not_nil(tree)

    local world = env.runtime:get_world()
    assert.is_not_nil(world.place_ground_item)
    for i = 1, GameCfg.Loot.PerZoneCap do
      local ok = world:place_ground_item(ZONE_ID, {
        kind = "item", itemId = ITEM_ID, count = 1, x = i, y = 0, z = 0,
      })
      assert.is_true(ok)
    end
    assert.equals(GameCfg.Loot.PerZoneCap, count_rows(env:loot_state(), ZONE_ID))
    assert.equals(GameCfg.Loot.PerZoneCap, env:alive_units())

    assert.is_true(world:place_ground_item(ZONE_ID, {
      kind = "item", itemId = ITEM_ID, count = 1, x = 999, y = 0, z = 0,
    }))
    local flashing = env:loot_state()
    assert.equals(GameCfg.Loot.PerZoneCap + 1, count_rows(flashing, ZONE_ID))
    local warned = 0
    for _, row in pairs(flashing.list or flashing) do
      if type(row) == "table" and row.warn == true then warned = warned + 1 end
    end
    assert.equals(1, warned)

    env:advance(GameCfg.Loot.FlashBeforeRecycleSec - 1)
    assert.equals(GameCfg.Loot.PerZoneCap + 1, env:alive_units())
    env:advance(1)
    assert.equals(GameCfg.Loot.PerZoneCap, env:alive_units())
    assert.equals(GameCfg.Loot.PerZoneCap, count_rows(env:loot_state(), ZONE_ID))
    env:shutdown()
    assert.equals(0, env:alive_units())
  end)

  it("鱼饵点 15 秒补一份且不堆叠，销毁世界后单位归零", function()
    local env = host({
      bait_spots = {
        RespawnSec = 15, Mesh = "mesh", Scale = 0.3,
        Spots = {
          { Id = "a", ItemId = BAIT_ID, Count = 1, Position = { x = 3, y = 0, z = 4 }, ZoneId = ZONE_ID },
          { Id = "b", ItemId = BAIT_ID, Count = 2, Position = { x = 8, y = 0, z = 4 }, ZoneId = ZONE_ID },
        },
      },
    })
    env:advance(0)
    local first = env:loot_state()
    assert.equals(2, count_rows(first))
    assert.equals(2, env:alive_units())
    env:advance(14)
    assert.equals(2, env:alive_units())
    local player = make_player(7, 3, 4)
    env:add(player)
    local bait_id
    for _, row in pairs((env:loot_state() or {}).list or env:loot_state() or {}) do
      if type(row) == "table" and (row.spotId == "a" or row.SpotId == "a") then
        bait_id = row.id or row.Id
      end
    end
    assert.is_not_nil(bait_id)
    fire_pickup(env, player, bait_id)
    assert.equals(1, env:alive_units())
    env:advance(15)
    assert.equals(2, env:alive_units())
    local again = 0
    for _, row in pairs((env:loot_state() or {}).list or env:loot_state() or {}) do
      if type(row) == "table" and (row.spotId == "a" or row.SpotId == "a") then again = again + 1 end
    end
    assert.equals(1, again)
    env:shutdown()
    assert.equals(0, env:alive_units())
  end)

  it("容量不足、已被拾取或不可行动时拾取与丢弃都不改状态", function()
    local env = host({
      bait_spots = { RespawnSec = 15, Mesh = "mesh", Scale = 0.3, Spots = {} },
    })
    local player = make_player(3, 1, 1)
    local data = env:add(player)
    local tree = env.runtime:get_player_tree(player.UserId)
    local world = env.runtime:get_world()
    local placed = world:place_ground_item(ZONE_ID, {
      kind = "item", itemId = ITEM_ID, count = 1, mult = 2, x = 1, y = 0, z = 1,
    })
    assert.is_true(placed)
    local loot_id = (function()
      for _, row in pairs((env:loot_state() or {}).list or env:loot_state()) do
        if type(row) == "table" then return row.id or row.Id end
      end
    end)()

    tree.states.life_phase:set("downed")
    fire_pickup(env, player, loot_id)
    assert.equals(1, env:alive_units())
    assert.equals(0, #(data:GetItemBarSnapshot().slots))

    tree.states.life_phase:set("alive")
    local bar = GameCfg.Items.ContainerId.ItemBar
    local pack = GameCfg.Items.ContainerId.Backpack
    local full_bar, full_pack = {}, {}
    for i = 1, data:ItemBarCapacity() do
      full_bar[i] = { itemId = ITEM_ID, count = 1, containerId = bar }
    end
    for i = 1, data:BackpackCapacity() do
      full_pack[i] = { itemId = ITEM_ID, count = 1, containerId = pack }
    end
    tree:set_item_bar(full_bar)
    tree:set_backpack(full_pack)
    fire_pickup(env, player, loot_id)
    assert.equals(1, env:alive_units())

    tree:set_item_bar({})
    tree:set_backpack({})
    local other = make_player(4, 1, 1)
    env:add(other)
    fire_pickup(env, other, loot_id)
    assert.equals(0, env:alive_units())
    fire_pickup(env, player, loot_id)
    local snap = player and env.runtime:get_player_tree(player.UserId):get_item_bar_snapshot()
    local held = 0
    for _, slot in pairs(snap.slots or {}) do
      if type(slot) == "table" and slot.itemId == ITEM_ID then held = held + (slot.count or 0) end
    end
    assert.equals(0, held)

    tree:set_item_bar({ [1] = { itemId = ITEM_ID, count = 1, containerId = bar, mult = 3 } })
    tree.states.life_phase:set("dead")
    local before_units = env:alive_units()
    fire_drop(env, player, { action = "Drop", container = bar, index = 1 })
    assert.equals(before_units, env:alive_units())
    local after = tree:get_item_bar_snapshot()
    assert.equals(ITEM_ID, after.slots[1] and after.slots[1].itemId)
    env:shutdown()
  end)

  it("拾取与丢弃在单次 batch 内同时改库存和地面并只合并推送一次", function()
    local env = host({
      bait_spots = { RespawnSec = 15, Mesh = "mesh", Scale = 0.3, Spots = {} },
    })
    local player = make_player(9, 2, 2)
    env:add(player)
    local tree = env.runtime:get_player_tree(player.UserId)
    local world = env.runtime:get_world()
    assert.is_true(world:place_ground_item(ZONE_ID, {
      kind = "item", itemId = ITEM_ID, count = 1, mult = 4, x = 2, y = 0, z = 2,
    }))
    local loot_id
    for _, row in pairs((env:loot_state() or {}).list or env:loot_state()) do
      if type(row) == "table" then loot_id = row.id or row.Id end
    end
    local loot_before = #env.events.LootState.clients
    local bar_before = #(env.events.ItemBarState and env.events.ItemBarState.clients or {})
    local batches = 0
    local original = SpokeRuntime.batch
    SpokeRuntime.batch = function(fn)
      batches = batches + 1
      return original(fn)
    end
    local ok_call, err_call = pcall(function()
      fire_pickup(env, player, loot_id)
    end)
    SpokeRuntime.batch = original
    assert.is_true(ok_call, tostring(err_call))
    assert.is_true(batches >= 1)
    assert.equals(0, env:alive_units())
    local snap = tree:get_item_bar_snapshot()
    local found = false
    for _, slot in pairs(snap.slots or {}) do
      if type(slot) == "table" and slot.itemId == ITEM_ID and slot.mult == 4 then found = true end
    end
    assert.is_true(found)
    assert.is_true(#env.events.LootState.clients >= loot_before)
    assert.is_true(#(env.events.ItemBarState and env.events.ItemBarState.clients or {}) >= bar_before)

    local bar = GameCfg.Items.ContainerId.ItemBar
    loot_before = #env.events.LootState.clients
    batches = 0
    SpokeRuntime.batch = function(fn)
      batches = batches + 1
      return original(fn)
    end
    ok_call, err_call = pcall(function()
      fire_drop(env, player, { action = "Drop", container = bar, index = 1 })
    end)
    SpokeRuntime.batch = original
    assert.is_true(ok_call, tostring(err_call))
    assert.is_true(batches >= 1)
    assert.equals(1, env:alive_units())
    local dropped = tree:get_item_bar_snapshot()
    assert.is_nil(dropped.slots[1])
    local row = find_row(env:loot_state(), nil)
    assert.is_not_nil(find_row(env:loot_state(), (function()
      for _, candidate in pairs((env:loot_state() or {}).list or env:loot_state()) do
        if type(candidate) == "table" then return candidate.id or candidate.Id end
      end
    end)()))
    assert.equals(loot_before + 1, #env.events.LootState.clients)
    env:shutdown()
    assert.equals(0, env:alive_units())
    assert.is_nil(row and row._unused)
  end)

  it("SharedWorldTree 销毁后 RequestLoot 与 ItemBarAction 连接全部断开", function()
    local env = host()
    local player = make_player(10, 0, 0)
    env:add(player)
    env.events.RequestLoot.OnServerEvent:Fire(player)
    local before = #env.events.LootState.clients
    env:shutdown()
    env.events.RequestLoot.OnServerEvent:Fire(player)
    env.events.ItemBarAction.OnServerEvent:Fire(player, { action = "Pickup", value = "1" })
    assert.equals(before, #env.events.LootState.clients)
  end)
end)
