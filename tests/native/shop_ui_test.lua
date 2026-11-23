-- #311 商店 UI：只通过统一视图树、Store 写侧、按钮点击与远端回执观察。
-- 旧 ScreenShop 私有 View、颜色、底图和内部注册表不再作为测试接缝。
local GameCfg = require("common.GameCfg")
local ClientStore = require("client.Store.ClientStore")
local RootView = require("client.Views.RootView")
local ShopView = require("client.Views.ShopView")
local Eui = require("tests.support.eui_double")

local function child(root, name) return root:FindFirstChild(name, true) end

describe("钓场商店统一视图行为", function()
  local ctx
  local old_vector

  local function rows_for(page)
    return GameCfg.Shop.ListForPage(ctx.stand.Level, page, true)
  end

  local function row_index(number, page)
    for index, row in ipairs(rows_for(page or GameCfg.Shop.Pages[1])) do
      if row.Number == number then return index end
    end
  end

  local function select_number(number, page)
    if page then Eui.Click(child(ctx.root, "BtnShopPage" .. assert((function()
      for index, name in ipairs(GameCfg.Shop.Pages) do if name == page then return index end end
    end)()))) end
    local index = assert(row_index(number, page))
    return Eui.Click(child(ctx.root, "ShopRow" .. index)), index
  end

  before_each(function()
    old_vector = rawget(_G, "Vector3")
    _G.Vector3 = { New = function(x, y, z) return { x = x, y = y, z = z } end }
    ctx = { sent = {}, notices = {}, seq = 10, stand = GameCfg.Shop.Stands[2] }
    ctx.store, ctx.writer = ClientStore.new({ initial_now = 1000 })
    ctx.root = Eui.Node({ Name = "UIRoot" })
    RootView.mount(ctx.root, ctx.store, {
      modals = { shop = ShopView.modal_spec() },
      docks = { shop = ShopView.bubble_spec({ anchors = { {
        stand = ctx.stand, name = ctx.stand.AnchorName, position = { x = 0, y = 0, z = 0 },
      } } }) },
      hud = { ShopView.presentation_spec() },
      services = {
        next_seq = function() ctx.seq = ctx.seq + 1 return ctx.seq end,
        send_shop = function(payload) ctx.sent[#ctx.sent + 1] = payload end,
        notify = function(message) ctx.notices[#ctx.notices + 1] = message end,
        open_modal = function(id, payload) ctx.writer:open_modal(id, payload) end,
        close_modal = function(id) ctx.writer:close_modal(id) end,
        open_platform_shop = function()
          if ctx.platform_error then error("platform") end
          if ctx.platform_available == false then return false end
          ctx.platform_opened = (ctx.platform_opened or 0) + 1
        end,
      },
      create_node = function(kind, props)
        return Eui.Node({
          Kind = kind, Name = props and props.Name, Parent = props and props.Parent,
          Visible = props and props.Visible ~= false,
          Text = props and (props.Text or props.ButtonText) or "",
          TouchEnabled = kind == "EUIButton",
        })
      end,
    })
    ctx.writer:set_coin(77)
    ctx.writer:update_spatial({ x = 0, y = 0, z = 0 }, {})
    assert.is_true(Eui.Click(child(ctx.root, "BtnShopEnter_" .. ctx.stand.AnchorName)))
  end)

  after_each(function()
    ctx.root:Destroy()
    _G.Vector3 = old_vector
  end)

  it("打开显示全部页签、第一页与实时金币，详情为空且不可购买", function()
    for index, page in ipairs(GameCfg.Shop.Pages) do
      assert.same(page, child(ctx.root, "LabelShopPage" .. index).Text)
    end
    assert.is_true(child(ctx.root, "ShopListPanel").Visible)
    assert.is_false(child(ctx.root, "ShopCoinPanel").Visible)
    assert.same("77", child(ctx.root, "LabelCurCoin").Text)
    assert.same("", child(ctx.root, "LabelShopDetailName").Text)
    assert.is_true(child(ctx.root, "BtnShopBuyDetail").Disabled)
  end)

  it("逐页切换同步容器和唯一指示条，并清空上一页详情", function()
    local coin_page = GameCfg.Shop.Pages[#GameCfg.Shop.Pages]
    for index, page in ipairs(GameCfg.Shop.Pages) do
      if page ~= coin_page then select_number(rows_for(page)[1].Number, page) end
      assert.is_true(Eui.Click(child(ctx.root, "BtnShopPage" .. index)))
      assert.same(page ~= coin_page, child(ctx.root, "ShopListPanel").Visible)
      assert.same(page == coin_page, child(ctx.root, "ShopCoinPanel").Visible)
      assert.same("", child(ctx.root, "LabelShopDetailName").Text)
      for other = 1, #GameCfg.Shop.Pages do
        assert.same(other == index, child(ctx.root, "ImageShopTabIndicator" .. other).Visible)
      end
    end
  end)

  it("商品顺序、当地新品与等级锁定原因跟配置和摊位等级一致", function()
    local rows = rows_for(GameCfg.Shop.Pages[1])
    local expected = {}
    for index, row in ipairs(rows) do
      expected[index] = row.Number
      assert.same(row.Name, child(ctx.root, "ShopRowName" .. index).Text)
      assert.same(tostring(row.Price), child(ctx.root, "ShopRowPrice" .. index).Text)
      assert.same(row.MinShopLevel == ctx.stand.Level and ShopView.ShopText.New or "",
        child(ctx.root, "ShopRowNew" .. index).Text)
      if row.MinShopLevel > ctx.stand.Level then
        assert.matches("需 " .. row.MinShopLevel .. " 级摊位", child(ctx.root, "ShopRowState" .. index).Text, 1, true)
      end
    end
    assert.same({ 11, 12, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 13, 14 }, expected)
  end)

  it("升级页完整列出所有行，无图标商品不显示白色占位", function()
    Eui.Click(child(ctx.root, "BtnShopPage3"))
    local rows = rows_for("升级")
    for index = 1, #rows do assert.is_not_nil(child(ctx.root, "ShopRow" .. index)) end
    assert.is_nil(child(ctx.root, "ShopRow" .. (#rows + 1)))
    assert.is_true(Eui.Click(child(ctx.root, "ShopRow1")))
    assert.is_false(child(ctx.root, "ImageShopDetailIcon").Visible)
    assert.is_false(child(ctx.root, "ShopRowIcon1").Visible)
  end)

  it("点行只看详情，详情购买是唯一指令入口且只发稳定编号", function()
    local ok, index = select_number(12)
    assert.is_true(ok)
    assert.same(0, #ctx.sent)
    local goods = rows_for(GameCfg.Shop.Pages[1])[index]
    assert.same(goods.Name, child(ctx.root, "LabelShopDetailName").Text)
    assert.same(goods.Desc, child(ctx.root, "LabelShopDetailDesc").Text)
    assert.same(tostring(goods.Price), child(ctx.root, "LabelShopDetailPrice").Text)
    assert.is_true(Eui.Click(child(ctx.root, "BtnShopBuyDetail")))
    assert.same({ action = "Buy", number = 12, seq = 11 }, ctx.sent[1])
    assert.is_nil(ctx.sent[1].itemId)
    assert.is_nil(ctx.sent[1].price)
  end)

  it("升级详情显示当前与目标等级及限购进度", function()
    select_number(33, "升级")
    assert.matches("当前 0 级，买完升到 1 级", child(ctx.root, "LabelShopDetailUpgrade").Text, 1, true)
    assert.same("已购 0 / 1 次", child(ctx.root, "LabelShopDetailLimit").Text)
  end)

  it("金币不足只引导金币页，不发出必被服务端拒绝的购买", function()
    ctx.writer:set_coin(0)
    select_number(12)
    assert.same(ShopView.ShopText.GoPlatformShop, child(ctx.root, "LabelShopBuyDetail").Text)
    assert.is_true(Eui.Click(child(ctx.root, "BtnShopBuyDetail")))
    assert.same(0, #ctx.sent)
    assert.is_true(child(ctx.root, "ShopCoinPanel").Visible)
    assert.is_false(child(ctx.root, "ShopListPanel").Visible)
  end)

  it("地图商店不可用、成功和抛错都有明确反馈且可返回其他页", function()
    Eui.Click(child(ctx.root, "BtnShopPage4"))
    ctx.platform_available = false
    Eui.Click(child(ctx.root, "BtnOpenPlatformShop"))
    assert.same(ShopView.ShopText.PlatformUnavailable, child(ctx.root, "LabelCoinPageHint").Text)
    assert.same(0, ctx.platform_opened or 0)
    ctx.platform_available = true
    Eui.Click(child(ctx.root, "BtnOpenPlatformShop"))
    assert.same(1, ctx.platform_opened)
    ctx.platform_error = true
    Eui.Click(child(ctx.root, "BtnOpenPlatformShop"))
    assert.same(ShopView.ShopText.PlatformOpenFailed, child(ctx.root, "LabelCoinPageHint").Text)
    Eui.Click(child(ctx.root, "BtnShopPage1"))
    assert.is_true(child(ctx.root, "ShopListPanel").Visible)
    assert.same(0, #ctx.sent)
  end)

  it("锁定行仍能看详情和原因，购买禁用且不会发指令", function()
    select_number(1)
    assert.same("科技假饵", child(ctx.root, "LabelShopDetailName").Text)
    assert.matches("需 7 级摊位", child(ctx.root, "LabelShopBuyDetail").Text, 1, true)
    assert.is_true(child(ctx.root, "BtnShopBuyDetail").Disabled)
    assert.is_true(Eui.Click(child(ctx.root, "BtnShopBuyDetail")))
    assert.same(0, #ctx.sent)
    assert.same(ShopView.FailText.stand, ctx.notices[#ctx.notices])
  end)

  it("成功回执原子刷新金币、限购和当前详情；拒绝不伪成功", function()
    select_number(12)
    ctx.writer:ingest_event("ShopResult", { ok = false, reason = "coin" })
    assert.same("77", child(ctx.root, "LabelCurCoin").Text)
    assert.same("钓虾竿", child(ctx.root, "LabelShopDetailName").Text)
    assert.same(ShopView.FailText.coin, ctx.notices[#ctx.notices])
    ctx.writer:ingest_event("ShopResult", {
      ok = true, action = "Buy", number = 12, itemId = "shrimpRod",
      name = "钓虾竿", price = 5, coinAfter = 72,
    })
    assert.same("72", child(ctx.root, "LabelCurCoin").Text)
    assert.same("钓虾竿", child(ctx.root, "LabelShopDetailName").Text)
    assert.same("购买成功：钓虾竿，花费 5 金币", ctx.notices[#ctx.notices])
  end)

  it("重开商店回到第一页且没有旧选中", function()
    select_number(12)
    ctx.writer:close_modal("shop")
    ctx.writer:open_modal("shop", { stand = ctx.stand })
    assert.same("", child(ctx.root, "LabelShopDetailName").Text)
    assert.is_true(child(ctx.root, "ImageShopTabIndicator1").Visible)
    assert.is_true(child(ctx.root, "ShopListPanel").Visible)
  end)

  it("离开范围回收弹窗和气泡，重新进入只保留一个新气泡", function()
    local old = child(ctx.root, "SceneNodeShop_" .. ctx.stand.AnchorName)
    local old_button = child(old, "BtnShopEnter_" .. ctx.stand.AnchorName)
    ctx.writer:update_spatial({ x = 100000, y = 0, z = 0 }, {})
    assert.is_true(old.Destroyed)
    assert.is_nil(child(ctx.root, "ScreenShop"))
    ctx.writer:update_spatial({ x = 0, y = 0, z = 0 }, {})
    local current = child(ctx.root, "SceneNodeShop_" .. ctx.stand.AnchorName)
    assert.is_not_nil(current)
    assert.is_not.equal(old, current)
    assert.equals(0, old_button.OnClicked:Count())
  end)

  it("远端失败原因与成功通知共用视图文案", function()
    for _, reason in ipairs({ "coin", "full", "max", "range", "item", "limit", "level", "stand" }) do
      ctx.writer:ingest_event("ShopResult", { ok = false, reason = reason })
      assert.same(ShopView.FailText[reason], ctx.notices[#ctx.notices])
    end
    ctx.writer:ingest_event("ShopResult", { ok = false, reason = "unknown" })
    assert.same("购买失败", ctx.notices[#ctx.notices])
    ctx.writer:ingest_event("ShopResult", { ok = true, action = "Buy", name = "香肠", price = 2 })
    assert.same("购买成功：香肠，花费 2 金币", ctx.notices[#ctx.notices])
  end)
end)
