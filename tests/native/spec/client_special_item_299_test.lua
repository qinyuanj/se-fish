
local Eui = require("tests.support.eui_double")
local ClientStore = require("client.Store.ClientStore")
local RootView = require("client.Views.RootView")
local MainHudActionButtonsView = require("client.Views.MainHudActionButtonsView")

describe("特殊道具统一视图宿主接缝（#299）", function()
  local saved_vector, saved_color

  before_each(function()
    saved_vector = rawget(_G, "Vector2")
    saved_color = rawget(_G, "Color")
    _G.Vector2 = { New = function(x, y) return { x = x, y = y } end }
    _G.Color = { New = function(...) return { ... } end }
  end)

  after_each(function()
    _G.Vector2 = saved_vector
    _G.Color = saved_color
  end)

  it("风神之翼与哥斯拉状态下动作键切换，失败回执提示冷却，销毁后不再提示", function()
    local store, writer = ClientStore.new({ initial_now = 100 })
    local notices = {}
    local nodes = {}
    local root = Eui.Node({ Name = "UIRoot" })
    local view = RootView.mount(root, store, {
      create_node = function(kind, props)
        local node = Eui.Node({
          Kind = kind,
          Name = props.Name,
          Parent = props.Parent,
          Visible = props.Visible,
          Text = props.Text,
          TouchEnabled = props.TouchEnabled,
        })
        if kind == "EUIButton" then
          node.OnClicked = Eui.Signal()
          node.OnTouchBegan = Eui.Signal()
          node.OnTouchEnded = Eui.Signal()
        end
        nodes[node.Name] = node
        return node
      end,
      hud = { MainHudActionButtonsView.spec() },
      services = {
        notify = function(text)
          notices[#notices + 1] = text
        end,
        resolution = { x = 1920, y = 1080 },
      },
    })
    assert.is_nil(view.root.fault)

    writer:ingest_event("ItemBarState", {
      slotCount = 4,
      selectedSlot = 1,
      slots = { [1] = { itemId = "item169", count = 1 } },
    })
    writer:ingest_event("SpecialItemState", { effect = "wings", airborne = false, breathRemaining = 0 })
    assert.equals("长按飞行", nodes.BtnItemActionLabel.Text)

    writer:ingest_event("SpecialItemState", { effect = "godzilla", breathRemaining = 0 })
    assert.equals("原子吐息", nodes.BtnItemActionLabel.Text)
    writer:ingest_event("SpecialItemResult", { ok = false, action = "breath", reason = "cooldown" })
    assert.same({ "原子吐息冷却中" }, notices)

    root:Destroy()
    writer:ingest_event("SpecialItemResult", { ok = false, action = "breath", reason = "cooldown" })
    assert.same({ "原子吐息冷却中" }, notices)
  end)
end)
