
local Eui = require("tests.support.eui_double")
local ClientStore = require("client.store.client_store")
local RootView = require("client.views.root_view")
local GroundLootView = require("client.views.ground_loot_view")
local SpokeClock = require("common.spoke_clock")

local function row(id, x, z, warn)
  return { id = id, kind = "item", itemId = "tilapia", x = x, y = 0, z = z, warn = warn == true }
end

local function mount(opts)
  opts = opts or {}
  local clock = SpokeClock.new(10)
  local store, writer = ClientStore.new({ clock = clock })
  local root = Eui.Node({ Name = "UIRoot" })
  local created = {}
  local sent = {}
  local notices = {}
  local view = RootView.mount(root, store, {
    services = {
      set_overlay = function(id, active) writer:set_overlay(id, active) end,
      notify = function(text) notices[#notices + 1] = text end,
    },
    create_node = function(kind, props)
      local node = Eui.Node(props or {})
      node.UnitType = kind
      created[#created + 1] = node
      return node
    end,
    hud = opts.with_toggle and {
      GroundLootView.aim_toggle_spec({ radius = opts.radius or 2 }),
    } or nil,
    docks = {
      ground_loot = GroundLootView.bubble_spec({
        send = function(payload) sent[#sent + 1] = payload end,
        radius = opts.radius or 2,
      }),
    },
    overlays = {
      aim_pickup = GroundLootView.aim_spec({
        send = function(payload) sent[#sent + 1] = payload end,
        on_pick = opts.on_pick,
        radius = opts.radius or 2,
      }),
    },
  })
  return {
    root = root,
    store = store,
    writer = writer,
    view = view,
    created = created,
    sent = sent,
    notices = notices,
    clock = clock,
  }
end

local function alive_named(env, prefix)
  local n = 0
  for _, node in ipairs(env.created) do
    if not node.Destroyed and type(node.Name) == "string" and node.Name:find(prefix, 1, true) == 1 then
      n = n + 1
    end
  end
  return n
end

local function node_named(env, name)
  for _, node in ipairs(env.created) do
    if not node.Destroyed and node.Name == name then return node end
  end
end

describe("地面气泡与瞄准拾取（#301 客户端宿主）", function()
  it("范围内建气泡，离开范围或物品消失后零残留，点击只发拾取", function()
    local env = mount()
    assert.is_true(env.writer:ingest_event("LootState", { list = { row("loot-1", 1, 1), row("loot-2", 40, 40) } }))
    env.writer:update_spatial({ x = 1, y = 0, z = 1 }, {})
    assert.equals(1, alive_named(env, "BtnPickup_"))
    local btn = node_named(env, "BtnPickup_loot-1")
    assert.is_not_nil(btn)
    assert.is_true(Eui.Click(btn))
    assert.same({ { action = "Pickup", value = "loot-1" } }, env.sent)

    env.writer:update_spatial({ x = 30, y = 0, z = 30 }, {})
    assert.equals(0, alive_named(env, "BtnPickup_"))
    assert.equals(0, btn.OnClicked:Count())

    env.writer:update_spatial({ x = 40, y = 0, z = 40 }, {})
    assert.equals(1, alive_named(env, "BtnPickup_"))
    assert.is_true(env.writer:ingest_event("LootState", { list = {} }))
    assert.equals(0, alive_named(env, "BtnPickup_"))
    env.view:dispose()
    assert.equals(0, alive_named(env, "BtnPickup_"))
  end)

  it("瞄准蒙版只在瞄准态存在，退出或销毁根后零残留", function()
    local env = mount()
    assert.equals(0, alive_named(env, "AimPickup"))
    env.writer:set_overlay("aim_pickup", true)
    assert.equals(1, alive_named(env, "AimPickup"))
    env.writer:set_overlay("aim_pickup", false)
    assert.equals(0, alive_named(env, "AimPickup"))
    env.writer:set_overlay("aim_pickup", true)
    env.root:Destroy()
    assert.equals(0, alive_named(env, "AimPickup"))
    assert.is_false(env.view.is_alive:now())
  end)

  it("瞄准拾取按钮打通蒙版开关、最近物品拾取回调、离场关闭与满包提示", function()
    local env = mount({ with_toggle = true })
    assert.is_nil(node_named(env, "BtnAimPickup"))
    env.writer:ingest_event("LootState", { list = { row("far", 1.8, 0), row("near", 0.5, 0) } })
    env.writer:update_spatial({ x = 0, y = 0, z = 0 }, {})

    local toggle = node_named(env, "BtnAimPickup")
    assert.is_not_nil(toggle)
    assert.is_true(Eui.Click(toggle))
    local mask = node_named(env, "AimPickupMask")
    assert.is_not_nil(mask)

    assert.is_true(Eui.Click(mask))
    assert.same({ { action = "Pickup", value = "near" } }, env.sent)
    assert.is_nil(node_named(env, "AimPickupMask"))

    assert.is_true(Eui.Click(toggle))
    assert.is_not_nil(node_named(env, "AimPickupMask"))
    env.writer:update_spatial({ x = 50, y = 0, z = 50 }, {})
    assert.is_nil(node_named(env, "AimPickupMask"))
    assert.is_nil(node_named(env, "BtnAimPickup"))

    env.writer:ingest_event("LootResult", { ok = false, reason = "full" })
    assert.same({ "背包已满" }, env.notices)
    env.view:dispose()
  end)
end)
