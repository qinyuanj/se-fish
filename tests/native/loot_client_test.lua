local eui = require("tests.support.eui_double")
local client_store = require("client.store.client_store")
local root_view = require("client.views.root_view")
local ground_loot_view = require("client.views.ground_loot_view")
local spoke_clock = require("common.spoke_clock")
local game_cfg = require("common.game_cfg")

local function mount()
  local store, writer = client_store.new({ clock = spoke_clock.new(1) })
  local root = eui.Node({ Name = "UIRoot" })
  local created, sent = {}, {}
  root_view.mount(root, store, {
    create_node = function(kind, props)
      local node = eui.Node(props or {})
      node.UnitType = kind
      created[#created + 1] = node
      return node
    end,
    docks = { ground_loot = ground_loot_view.bubble_spec({
      send = function(payload) sent[#sent + 1] = payload end,
      radius = game_cfg.Loot.PickupRadius,
    }) },
  })
  return { writer = writer, created = created, sent = sent }
end

local function alive(env)
  local n = 0
  for _, node in ipairs(env.created) do
    if not node.Destroyed and type(node.Name) == "string" and node.Name:find("BtnPickup_", 1, true) == 1 then n = n + 1 end
  end
  return n
end

describe("地面拾取气泡", function()
  it("test_click_sends_pickup_request_for_that_loot", function()
    local env = mount()
    env.writer:ingest_event("LootState", { list = { { id = 7, kind = "item", itemId = "carp", x = 0, y = 0, z = 0 } } })
    env.writer:update_spatial({ x = 0, y = 0, z = 0 }, {})
    local btn
    for _, node in ipairs(env.created) do if node.Name == "BtnPickup_7" then btn = node end end
    assert.is_true(eui.Click(btn))
    assert.same({ { action = "Pickup", value = 7 } }, env.sent)
  end)

  it("test_missing_loot_clears_its_bubble", function()
    local env = mount()
    env.writer:ingest_event("LootState", { list = { { id = 7, x = 0, y = 0, z = 0 } } })
    env.writer:update_spatial({ x = 0, y = 0, z = 0 }, {})
    assert.equals(1, alive(env))
    env.writer:ingest_event("LootState", { list = {} })
    assert.equals(0, alive(env))
  end)

  it("test_plain_loot_stays_in_range_and_hides_outside", function()
    local env = mount()
    env.writer:ingest_event("LootState", { list = { { id = 1, x = 0, y = 0, z = 0 } } })
    env.writer:update_spatial({ x = 0, y = 0, z = 0 }, {})
    assert.equals(1, alive(env))
    env.writer:update_spatial({ x = game_cfg.Loot.PickupRadius + 1, y = 0, z = 0 }, {})
    assert.equals(0, alive(env))
    env.writer:update_spatial({ x = 1, y = 0, z = 0 }, {})
    assert.equals(1, alive(env))
  end)
end)
