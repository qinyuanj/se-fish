-- #310 客户端烧烤视图宿主接缝（ADR-0032 / #292 Testing Decisions）
-- 失败方式先列：
--   1. 收到 cooking 不显示两位小数倍率与已烤秒数，或时钟推进后读数不跟着变；
--   2. 取出不上行 GrillAction，烤糊不提示「你的鱼烤糊了！」；
--   3. 会话结束、玩家离场或根节点销毁后面板、按钮与监听残留。
-- 接缝：EUI 测试双、ClientStore.grill、按钮上行、根节点销毁。不窥探私有 Effect 拓扑。

local GameCfg = require("common.GameCfg")
local ClientStore = require("client.Store.ClientStore")
local RootView = require("client.Views.RootView")
local GrillView = require("client.Views.GrillView")
local Eui = require("tests.support.eui_double")

local function mount(store, sent)
  local root = Eui.Node({ Name = "UIRoot" })
  local view = RootView.mount(root, store, {
    hud = { GrillView.spec() },
    services = {
      send_grill = function(payload) sent[#sent + 1] = payload end,
      now = function() return store.clock.now() end,
    },
    create_node = function(kind, props)
      return Eui.Node({
        Kind = kind,
        Name = props and props.Name,
        Parent = props and props.Parent,
        Visible = props and props.Visible ~= false,
        Text = props and (props.Text or props.ButtonText) or "",
        Position = props and props.Position,
        Size = props and props.Size,
        TouchEnabled = kind == "EUIButton",
      })
    end,
  })
  return root, view
end

local function child(root, name)
  return root:FindFirstChild(name, true)
end

describe("客户端烧烤视图宿主接缝（#310）", function()
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

  it("烤制中显示两位小数倍率，取出上行，结束后零残留", function()
    local store, writer = ClientStore.new({ initial_now = 1000 })
    local sent = {}
    local root = mount(store, sent)
    assert.is_nil(child(root, "GrillPanel"))

    writer:ingest_event("GrillState", {
      state = "cooking",
      itemId = "carp",
      mult = 1.5,
      startedAt = 1000,
    })
    local panel = child(root, "GrillPanel")
    local rate = child(root, "GrillRate")
    local time = child(root, "GrillTime")
    assert.is_not_nil(panel)
    assert.is_true(panel.Visible)
    assert.equals("倍率 1.00", rate.Text)
    assert.equals("已烤 0.00 秒", time.Text)

    writer:advance_clock(1)
    assert.equals("倍率 1.25", rate.Text)
    assert.equals("已烤 1.00 秒", time.Text)

    local takeout = child(root, "GrillTakeout")
    assert.is_true(Eui.Click(takeout))
    assert.same({ action = "Takeout" }, sent[#sent])

    writer:ingest_event("GrillState", { state = "burnt" })
    assert.is_nil(child(root, "GrillPanel"))
    assert.equals(0, takeout.OnClicked:Count())

    writer:ingest_event("GrillState", {
      state = "cooking",
      itemId = "carp",
      startedAt = 1001,
    })
    panel = child(root, "GrillPanel")
    takeout = child(root, "GrillTakeout")
    assert.is_not_nil(panel)
    root:Destroy()
    assert.is_true(panel.Destroyed)
    assert.equals(0, takeout.OnClicked:Count())
    writer:ingest_event("GrillState", { state = "cooking", itemId = "carp", startedAt = 1000 })
    assert.is_nil(child(root, "GrillPanel"))
  end)

  it("烤糊提示使用配置文案", function()
    local store, writer = ClientStore.new({ initial_now = 1000 })
    local notices = {}
    local root = Eui.Node({ Name = "UIRoot" })
    RootView.mount(root, store, {
      hud = { GrillView.spec() },
      services = {
        send_grill = function() end,
        notify = function(text) notices[#notices + 1] = text end,
        now = function() return store.clock.now() end,
      },
      create_node = function(kind, props)
        return Eui.Node({
          Kind = kind,
          Name = props and props.Name,
          Parent = props and props.Parent,
          Visible = true,
          Text = props and (props.Text or "") or "",
          TouchEnabled = kind == "EUIButton",
        })
      end,
    })
    writer:ingest_event("GrillState", { state = "burnt" })
    assert.equals(GameCfg.Grill.BurntText, notices[#notices])
  end)
end)
