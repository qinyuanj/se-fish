local GameCfg = require("common.game_cfg")
local ServerRuntime = require("server.WorldHost.ServerRuntime")
local SpokeClock = require("common.spoke_clock")
local PlayerData = require("server.Data.PlayerData")

local function signal()
  local handlers = {}
  return { Connect = function(_, fn) handlers[#handlers + 1] = fn return { Disconnect = function() end } end,
    Fire = function(_, ...) for _, fn in ipairs(handlers) do fn(...) end end }
end

describe("TestEelLoot", function()
  before_each(function()
    GameCfg.Debug = { Enabled = false, InitialGrants = GameCfg.Debug and GameCfg.Debug.InitialGrants }
  end)
  it("test_eel_drops_three_items_and_another_player_can_pick_them", function()
    local events, created, data_of, players = {}, {}, {}, {}
    local function event(name)
      events[name] = events[name] or { clients = {}, OnServerEvent = signal(),
        FireAllClients = function(self, payload) self.clients[#self.clients + 1] = payload end,
        FireClient = function() end }
      return events[name]
    end
    local clock = SpokeClock.new(10)
    local runtime = ServerRuntime.new({
      clock = clock, initial_now = 10,
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
    local world = runtime:get_world()
    for i = 1, 3 do
      assert.is_true(world:place_ground_item("fishPond", {
        kind = "item", itemId = i == 3 and "eelHead" or "eelMeat", count = 1, x = i, y = 0, z = 0,
      }))
    end
    local other = { UserId = 2, attrs = {}, Character = { Position = { x = 2, y = 0, z = 0 } } }
    function other:SetAttribute() end
    function other:GetAttribute() end
    local data = PlayerData.New(other); data:Init(); data.LoadState = "ready"; data.Player = other
    data_of[2] = data; players[1] = other
    runtime:on_player_added(other); runtime:on_save_ready(other, data)
    local rows = events.LootState.clients[#events.LootState.clients].list
    events.ItemBarAction.OnServerEvent:Fire(other, { action = "Pickup", value = rows[2].id })
    local snap = runtime:get_player_tree(2):get_item_bar_snapshot()
    local held = 0
    for _, slot in pairs(snap.slots) do if type(slot) == "table" then held = held + 1 end end
    assert.equals(1, held)
    local alive = 0
    for _, unit in ipairs(created) do if not unit.Destroyed then alive = alive + 1 end end
    assert.equals(2, alive)
    runtime:shutdown()
  end)
end)
