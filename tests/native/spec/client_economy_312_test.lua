local ClientStore = require("client.store.client_store")
local RootView = require("client.views.root_view")
local LotteryView = require("client.views.lottery_view")
local BlindboxView = require("client.views.blindbox_view")
local PlatformShopView = require("client.views.platform_shop_view")
local Eui = require("tests.support.eui_double")

local function child(root, name)
  return root:FindFirstChild(name, true)
end

describe("客户端抽奖机、盲盒与地图商店模态弹窗（#312）", function()
  local root, store, writer, view, sent, oldVector, oldColor

  before_each(function()
    oldVector, oldColor = rawget(_G, "Vector2"), rawget(_G, "Color")
    _G.Vector2 = { New = function(x, y) return { x = x, y = y } end }
    _G.Color = { New = function(...) return { ... } end }
    sent = { lottery = {}, blindbox = {}, platform = {} }
    store, writer = ClientStore.new()
    root = Eui.Node({ Name = "UIRoot" })
    view = RootView.mount(root, store, {
      services = {
        open_modal = function(id, payload) writer:open_modal(id, payload) end,
        close_modal = function(id) writer:close_modal(id) end,
        send_lottery = function(payload) table.insert(sent.lottery, payload) end,
        send_blindbox = function(payload) table.insert(sent.blindbox, payload) end,
        send_platform = function(payload) table.insert(sent.platform, payload) end,
      },
      hud = { BlindboxView.entry_spec(), PlatformShopView.entry_spec() },
      modals = {
        lottery = LotteryView.modal_spec(),
        blindbox = BlindboxView.modal_spec(),
        platform = PlatformShopView.modal_spec(),
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
  end)

  after_each(function()
    if view then view:dispose() end
    _G.Vector2, _G.Color = oldVector, oldColor
  end)

  it("三类弹窗互斥，按钮只上行请求，结果由只读仓库投影", function()
    writer:ingest_event("ItemBarState", {
      selectedSlot = 1,
      slots = { { itemId = "item7", count = 1, mult = 1 } },
    })
    writer:open_modal("lottery")
    local lottery = child(root, "ScreenLottery")
    assert.is_not_nil(lottery)
    Eui.Click(child(root, "BtnLotteryDraw"))
    assert.same({ action = "Draw", slot = 1, seq = 1 }, sent.lottery[1])
    writer:ingest_event("LotteryResult", { ok = true, recovered = true, axes = { 1, 1, 2 }, outcome = "pair", coins = 8 })
    assert.matches("8", child(root, "LabelLotteryResult").Text)

    writer:open_modal("blindbox")
    assert.is_true(lottery.Destroyed)
    local blindbox = child(root, "ScreenBlindbox")
    assert.is_not_nil(blindbox)
    Eui.Click(child(root, "BtnBlindboxSingle"))
    assert.same({ action = "Draw", count = 1, seq = 1 }, sent.blindbox[1])
    writer:ingest_event("BlindboxResult", { ok = true, pityAfter = 1, draws = { { itemKey = "item7" } } })
    assert.matches("item7", child(root, "LabelBlindboxResult").Text)

    writer:open_modal("platform")
    assert.is_true(blindbox.Destroyed)
    writer:ingest_event("PlatformResult", {
      ok = true,
      action = "CoinShop",
      currency = "元",
      offers = { { key = "coinPouch", name = "金币小袋", price = 6, coin = 600 } },
    })
    local offerButton = child(root, "BtnPlatformOffer_coinPouch")
    assert.equals(1, offerButton.OnClicked:Count())
    assert.is_true(Eui.Click(offerButton), string.format("destroyed=%s visible=%s touch=%s",
      tostring(offerButton.Destroyed), tostring(offerButton.Visible), tostring(offerButton.TouchEnabled)))
    assert.same({ action = "BuyCoin", goods = "coinPouch", seq = 1 }, sent.platform[1])

    local platformPanel = child(root, "ScreenPlatform")
    Eui.Click(child(root, "BtnPlatformClose"))
    assert.is_nil(store.active_modal:now())
    assert.is_true(platformPanel.Destroyed)
  end)

  it("常驻入口打开对应弹窗，根 UI 销毁后节点与监听零残留", function()
    local blindboxEntry = child(root, "BtnBlindboxEntry")
    Eui.Click(blindboxEntry)
    assert.equals("blindbox", store.active_modal:now())
    writer:open_modal("platform")
    local platformEntry = child(root, "BtnMapShopEntry")
    Eui.Click(platformEntry)
    assert.same({ action = "OpenCoinShop" }, sent.platform[1])
    local panel = child(root, "ScreenPlatform")
    local close = child(root, "BtnPlatformClose")
    root:Destroy()
    assert.is_true(panel.Destroyed)
    assert.is_true(blindboxEntry.Destroyed)
    assert.equals(0, close.OnClicked:Count())
  end)
end)
