-- #301 瞄准拾取蒙版与地面气泡：客户端宿主接缝（ADR-0032 / #292 Testing Decisions）
-- 失败方式先列：
--   1. LootState 或本地位置变化后，范围内地面物品不建气泡、范围外仍残留气泡；
--   2. 拾取按钮不发 ItemBarAction.Pickup，或离开范围 / 物品消失 / 根 UI 销毁后节点与点击监听仍在；
--   3. 瞄准拾取蒙版在无瞄准态时仍挂着，或退出瞄准、根销毁后蒙版节点与连接残留；
--   4. 视图仍依赖已删除的 client.LocalLoot。
-- 接缝：EUI 测试双、ClientStore 下行事件与本地位置、按钮点击、节点销毁。不窥探私有 Effect 拓扑。

local Eui = require("tests.support.eui_double")
local ClientStore = require("client.Store.ClientStore")
local RootView = require("client.Views.RootView")
local GroundLootView = require("client.Views.GroundLootView")
local SpokeClock = require("common.SpokeClock")

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
  local view = RootView.mount(root, store, {
    create_node = function(kind, props)
      local node = Eui.Node(props or {})
      node.UnitType = kind
      created[#created + 1] = node
      return node
    end,
    docks = {
      ground_loot = GroundLootView.bubble_spec({
        send = function(payload) sent[#sent + 1] = payload end,
        radius = opts.radius or 2,
      }),
    },
    overlays = {
      aim_pickup = GroundLootView.aim_spec({
        send = function(payload) sent[#sent + 1] = payload end,
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
end)
