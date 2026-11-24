
local GameCfg = require("common.game_cfg")
local ClientStore = require("client.store.client_store")
local RootView = require("client.views.root_view")
local SurvivalOverlayView = require("client.views.survival_overlay_view")
local Eui = require("tests.support.eui_double")

local function mount(store, sent)
  local root = Eui.Node({ Name = "UIRoot" })
  local view = RootView.mount(root, store, {
    overlays = { survival = SurvivalOverlayView.spec() },
    services = {
      send_survival = function(payload)
        sent[#sent + 1] = payload
      end,
      now = function()
        return store.clock.now()
      end,
      notify = function(text)
        sent[#sent + 1] = { notice = text }
      end,
      get_device_resolution = function()
        return { x = 1920, y = 1080 }
      end,
    },
    create_node = function(kind, props)
      return Eui.Node({
        Kind = kind,
        Name = props and props.Name,
        Parent = props and props.Parent,
        Visible = props and props.Visible,
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

describe("客户端生存蒙版宿主接缝（#298）", function()
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

  it("濒死、死亡与平台挂起按旧蒙版名与显隐矩阵建拆，按钮上行 SurvivalAction", function()
    local store, writer = ClientStore.new({ initial_now = 100 })
    local sent = {}
    local root = mount(store, sent)
    writer:ingest_event("SurvivalState", {
      phase = "downed",
      endsAt = 115,
    })
    local banner = child(root, "SurvivalBanner")
    local title = child(root, "SurvivalTitle")
    local adrenaline = child(root, "SurvivalAdrenaline")
    local ad = child(root, "SurvivalAdRevive")
    local paid = child(root, "SurvivalPaidRevive")
    local weak = child(root, "SurvivalWeak")
    assert.is_not_nil(banner)
    assert.is_not_nil(title)
    assert.is_true(banner.Visible)
    assert.is_true(title.Visible)
    assert.is_true(adrenaline.Visible)
    assert.is_true(ad.Visible)
    assert.is_false(paid.Visible)
    assert.is_false(weak.Visible)
    assert.equals(GameCfg.Survival.DownedTitle .. "（" .. "15" .. " 秒）", title.Text)
    assert.equals(330, ad.Position.x)

    assert.is_true(Eui.Click(adrenaline))
    assert.same({ action = "UseAdrenaline", seq = 1 }, sent[#sent])
    assert.is_true(Eui.Click(ad))
    assert.same({ action = "FullRevive", mode = "ad", seq = 2 }, sent[#sent])

    writer:ingest_event("SurvivalState", {
      phase = "downed",
      endsAt = 115,
      platformPending = "ad",
    })
    assert.equals(GameCfg.Survival.PlatformWaitText, title.Text)
    assert.is_false(adrenaline.Visible)
    assert.is_false(ad.Visible)

    writer:ingest_event("SurvivalState", { phase = "dead", endsAt = 130 })
    assert.is_true(paid.Visible)
    assert.is_true(adrenaline and adrenaline.Visible == false)
    assert.is_true(ad.Visible)
    assert.equals(10, ad.Position.x)
    assert.equals(330, paid.Position.x)
    assert.equals(GameCfg.Survival.DeadTitle .. "（" .. "30" .. " 秒）", title.Text)
    assert.equals(GameCfg.Survival.CallHelpText, sent[#sent].notice)
    assert.is_true(Eui.Click(paid))
    assert.same({ action = "FullRevive", mode = "goods", seq = 3 }, sent[#sent])

    writer:step_clock(1)
    assert.equals(GameCfg.Survival.DeadTitle .. "（" .. "29" .. " 秒）", title.Text)

    writer:ingest_event("SurvivalState", { phase = "alive", weakUntil = store.clock.now() + 60 })
    assert.is_nil(child(root, "SurvivalBanner"))
    assert.is_not_nil(child(root, "SurvivalWeak"))
    assert.is_true(child(root, "SurvivalWeak").Visible)
    assert.equals(GameCfg.Survival.WeakText .. "（" .. "60" .. " 秒）", child(root, "SurvivalWeak").Text)

    writer:ingest_event("SurvivalState", { phase = "alive" })
    assert.is_nil(child(root, "SurvivalWeak"))
    local clicks = adrenaline.OnClicked and adrenaline.OnClicked.Count and adrenaline.OnClicked:Count() or 0
    assert.equals(0, clicks)
  end)

  it("虚弱倒计时随 clock.second 超时后自动卸载覆盖相位并销毁节点", function()
    local store, writer = ClientStore.new({ initial_now = 100 })
    local sent = {}
    local root = mount(store, sent)
    writer:ingest_event("SurvivalState", { phase = "alive", weakUntil = 103 })
    local weak = child(root, "SurvivalWeak")
    assert.is_not_nil(weak)
    assert.equals(GameCfg.Survival.WeakText .. "（3 秒）", weak.Text)

    writer:advance_clock(2)
    assert.is_not_nil(child(root, "SurvivalWeak"))
    assert.equals(GameCfg.Survival.WeakText .. "（1 秒）", weak.Text)

    writer:advance_clock(1)
    assert.is_true(weak.Destroyed)
    assert.is_nil(child(root, "SurvivalWeak"))
    root:Destroy()
  end)

  it("根节点销毁后蒙版子节点与点击连接零残留", function()
    local store, writer = ClientStore.new({ initial_now = 100 })
    local sent = {}
    local root = mount(store, sent)
    writer:ingest_event("SurvivalState", { phase = "downed", endsAt = 115 })
    local adrenaline = child(root, "SurvivalAdrenaline")
    assert.is_not_nil(adrenaline)
    root:Destroy()
    assert.is_true(adrenaline.Destroyed)
    assert.equals(0, adrenaline.OnClicked:Count())
    writer:ingest_event("SurvivalState", { phase = "dead", endsAt = 140 })
    assert.is_nil(child(root, "SurvivalBanner"))
  end)
end)
