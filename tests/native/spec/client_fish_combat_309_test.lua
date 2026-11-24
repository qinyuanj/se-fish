
local Eui = require("tests.support.eui_double")
local ClientStore = require("client.Store.ClientStore")
local RootView = require("client.Views.RootView")
local FishCombatView = require("client.Views.FishCombatView")
local SpokeClock = require("common.spoke_clock")

local function mount()
  local clock = SpokeClock.new(10)
  local store, writer = ClientStore.new({ clock = clock })
  local root = Eui.Node({ Name = "UIRoot" })
  local created = {}
  local view = RootView.mount(root, store, {
    create_node = function(kind, props)
      local node = Eui.Node(props or {})
      node.UnitType = kind
      created[#created + 1] = node
      return node
    end,
    docks = {
      fish_combat = FishCombatView.bar_spec(),
      fish_warning = FishCombatView.warning_spec(),
    },
  })
  return { root = root, writer = writer, view = view, created = created }
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

describe("活鱼血条与预警投影（#309 客户端宿主）", function()
  it("战斗快照投影血条与标签，鱼消失或根销毁后零残留", function()
    local env = mount()
    assert.is_true(env.writer:ingest_event("FishCombatState", {
      list = {
        { id = "f1", fishId = "eel", name = "电鳗", health = 200, maxHealth = 300, label = "放电" },
        { id = "f2", fishId = "bass", name = "鲈鱼", health = 20, maxHealth = 20, label = "逃脱" },
      },
    }))
    assert.equals(2, alive_named(env, "FishBar_"))
    local bar = node_named(env, "FishBar_f1")
    assert.is_not_nil(bar)
    assert.equals("电鳗 200/300", bar.Text)
    local tag = node_named(env, "FishTag_f1")
    assert.is_not_nil(tag)
    assert.equals("放电", tag.Text)

    assert.is_true(env.writer:ingest_event("FishCombatState", {
      list = {
        { id = "f2", fishId = "bass", name = "鲈鱼", health = 10, maxHealth = 20, label = "逃脱" },
      },
    }))
    assert.equals(1, alive_named(env, "FishBar_"), "血条残留 " .. tostring(alive_named(env, "FishBar_")))
    local gone = node_named(env, "FishBar_f1")
    assert.is_nil(gone, "旧血条仍在 " .. tostring(gone and gone.Text))
    local kept = node_named(env, "FishBar_f2")
    assert.is_not_nil(kept, "剩余血条缺失")
    if kept.Text ~= "鲈鱼 10/20" then
      assert.is_true(false, "血条文本[" .. tostring(kept.Text) .. "]")
    end

    assert.is_true(env.writer:ingest_event("FishCombatState", { list = {} }))
    assert.equals(0, alive_named(env, "FishBar_"))
    assert.equals(0, alive_named(env, "FishTag_"))
    env.view:dispose()
  end)

  it("预警贴花随快照出现和消失，根销毁后零残留", function()
    local env = mount()
    assert.equals(0, alive_named(env, "FishWarn_"))
    assert.is_true(env.writer:ingest_event("FishCombatState", {
      list = {},
      warnings = {
        { id = "w1", fishId = "alligatorGar", kind = "bite" },
      },
    }))
    assert.equals(1, alive_named(env, "FishWarn_"))
    assert.is_not_nil(node_named(env, "FishWarn_w1"))
    assert.is_true(env.writer:ingest_event("FishCombatState", { list = {}, warnings = {} }))
    assert.equals(0, alive_named(env, "FishWarn_"))

    assert.is_true(env.writer:ingest_event("FishCombatState", {
      warnings = { { id = "w2", fishId = "fish56Boss", kind = "stomp" } },
    }))
    env.root:Destroy()
    assert.equals(0, alive_named(env, "FishWarn_"))
    assert.is_false(env.view.is_alive:now())
  end)
end)
