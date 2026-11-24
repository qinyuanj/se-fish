-- #310 客户端烧烤视图宿主接缝（ADR-0032 / #292 Testing Decisions）
-- 失败方式先列：
--   1. 收到 cooking 不显示两位小数倍率与已烤秒数，或时钟推进后读数不跟着变；
--   2. 场景气泡不按距离建拆，点击不上行带正整数 seq 的 Start/Takeout/Query，或信物二次确认失效；
--   3. GrillResult 取出/满包/无鱼/烤糊提示缺失，或烤糊重复提示；
--   4. 会话结束、玩家离场或根节点销毁后面板、按钮与监听残留。
-- 接缝：EUI 测试双、ClientStore.grill/position/on_server_event、按钮上行、根节点销毁。不窥探私有 Effect 拓扑。

local GameCfg = require("common.GameCfg")
local ClientStore = require("client.Store.ClientStore")
local RootView = require("client.Views.RootView")
local GrillView = require("client.Views.GrillView")
local Eui = require("tests.support.eui_double")

local function mount(store, opts)
  opts = opts or {}
  local sent = opts.sent or {}
  local notices = opts.notices or {}
  local shared = GrillView.new_shared()
  local root = Eui.Node({ Name = "UIRoot" })
  local view = RootView.mount(root, store, {
    hud = { GrillView.spec({ shared = shared }) },
    docks = opts.anchors and {
      grill = GrillView.bubble_spec({ shared = shared, anchors = opts.anchors }),
    } or nil,
    services = {
      send_grill = function(payload) sent[#sent + 1] = payload end,
      notify = function(text) notices[#notices + 1] = text end,
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
  return root, view, sent, notices
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

  it("烤制中显示两位小数倍率且原地刷新，取出携带正整数 seq，结束后零残留", function()
    local store, writer = ClientStore.new({ initial_now = 1000 })
    local root, _, sent = mount(store)
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
    assert.equals(panel, child(root, "GrillPanel"))
    assert.equals("倍率 1.25", rate.Text)
    assert.equals("已烤 1.00 秒", time.Text)

    local takeout = child(root, "GrillTakeout")
    assert.is_true(Eui.Click(takeout))
    assert.same({ action = "Takeout", seq = 1 }, sent[#sent])

    assert.is_true(Eui.Click(takeout))
    assert.same({ action = "Takeout", seq = 2 }, sent[#sent])

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

  it("场景气泡触发投入、信物二次确认、关闭重开与 GrillResult 提示", function()
    local store, writer = ClientStore.new({ initial_now = 1000 })
    local root, _, sent, notices = mount(store, {
      anchors = {
        { index = 1, name = "Z1_Grill", position = { x = 10, y = 0, z = 10 } },
      },
    })
    writer:update_spatial({ x = 50, y = 0, z = 50 }, {})
    assert.is_nil(child(root, "BtnGrill1"))

    writer:update_spatial({ x = 10, y = 0, z = 10 }, {})
    local bubble = child(root, "BtnGrill1")
    assert.is_not_nil(bubble)

    -- 首次投入发送 Start + 正整数 seq
    assert.is_true(Eui.Click(bubble))
    assert.same({ action = "Start", seq = 1 }, sent[#sent])

    -- 收到信物警告后 5 秒内再点自动带 confirm = true
    writer:ingest_event("GrillResult", { ok = false, reason = "token-warn" })
    assert.equals(GameCfg.Grill.TokenWarnText, notices[#notices])
    writer:advance_clock(2)
    assert.is_true(Eui.Click(bubble))
    assert.same({ action = "Start", seq = 2, confirm = true }, sent[#sent])

    -- 烤制中点击关闭仅隐藏面板，再点气泡发 Query 并重新展开
    writer:ingest_event("GrillState", { state = "cooking", itemId = "carp", startedAt = 1002 })
    assert.is_not_nil(child(root, "GrillPanel"))
    assert.is_true(Eui.Click(child(root, "GrillClose")))
    assert.is_nil(child(root, "GrillPanel"))
    assert.is_true(Eui.Click(bubble))
    assert.same({ action = "Query", seq = 3 }, sent[#sent])
    assert.is_not_nil(child(root, "GrillPanel"))

    -- GrillResult 取出成功与失败原因提示
    writer:ingest_event("GrillResult", { ok = true, action = "Takeout", itemId = "carp", rate = 1.5 })
    assert.matches("1.50", notices[#notices], 1, true)
    writer:ingest_event("GrillResult", { ok = false, reason = "no-fish" })
    assert.equals(GameCfg.Grill.NoFishText, notices[#notices])
    writer:ingest_event("GrillResult", { ok = false, reason = "full" })
    assert.equals(GameCfg.Grill.FullText, notices[#notices])

    -- 离开范围销毁气泡并断开连接
    writer:update_spatial({ x = 50, y = 0, z = 50 }, {})
    assert.is_nil(child(root, "BtnGrill1"))
    assert.equals(0, bubble.OnClicked:Count())
    root:Destroy()
  end)

  it("烤糊提示使用配置文案且不重复弹两次", function()
    local store, writer = ClientStore.new({ initial_now = 1000 })
    local _, _, _, notices = mount(store)
    writer:ingest_event("GrillState", { state = "burnt" })
    writer:ingest_event("GrillResult", { ok = false, reason = "burnt" })
    assert.equals(1, #notices)
    assert.equals(GameCfg.Grill.BurntText, notices[1])
  end)
end)
