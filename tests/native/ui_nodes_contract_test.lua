local GameCfg = require("common.game_cfg")
local ClientStore = require("client.Store.ClientStore")
local RootView = require("client.Views.RootView")
local ShopView = require("client.Views.ShopView")
local Eui = require("tests.support.eui_double")

local REQUIRED = {
  "ScreenShop", "LabelShopTitle", "LabelCurCoin", "ShopListPanel", "ShopList",
  "ShopCoinPanel", "ShopDetailPanel", "LabelCoinPageHint", "BtnOpenPlatformShop",
  "LabelOpenPlatformShop", "LabelShopDetailName", "LabelShopDetailDesc",
  "LabelShopDetailPrice", "LabelShopDetailLimit", "LabelShopDetailUpgrade",
  "ImageShopDetailIcon", "ImageShopDetailCoin", "BtnShopBuyDetail", "LabelShopBuyDetail",
  "BtnShopClose",
}

local function child(root, name) return root:FindFirstChild(name, true) end

local function collect_names(node, seen, duplicates)
  local name = node.Name
  if name then
    if seen[name] then duplicates[name] = true end
    seen[name] = true
  end
  for _, node_child in pairs(node.Children or {}) do collect_names(node_child, seen, duplicates) end
end

describe("商店统一视图的动态节点合同", function()
  local root, writer
  before_each(function()
    local store
    store, writer = ClientStore.new({ initial_now = 1000 })
    root = Eui.Node({ Name = "UIRoot" })
    RootView.mount(root, store, {
      modals = { shop = ShopView.modal_spec() },
      services = {
        open_modal = function(id, payload) writer:open_modal(id, payload) end,
        close_modal = function(id) writer:close_modal(id) end,
      },
      create_node = function(kind, props)
        return Eui.Node({ Kind = kind, Name = props and props.Name, Parent = props and props.Parent,
          Text = props and (props.Text or props.ButtonText) or "", TouchEnabled = kind == "EUIButton" })
      end,
    })
    writer:set_coin(100)
    writer:open_modal("shop", { stand = GameCfg.Shop.Stands[1] })
  end)
  after_each(function() root:Destroy() end)

  it("关键控件与所有页签都按公开名字创建", function()
    for _, name in ipairs(REQUIRED) do assert.is_not_nil(child(root, name), name) end
    for index, page in ipairs(GameCfg.Shop.Pages) do
      assert.is_not_nil(child(root, "BtnShopPage" .. index))
      assert.same(page, child(root, "LabelShopPage" .. index).Text)
      assert.is_not_nil(child(root, "ImageShopTabIndicator" .. index))
    end
    assert.is_true(Eui.Click(child(root, "ShopRow1")))
    for _, name in ipairs({ "ShopRow1", "ShopRowName1", "ShopRowPrice1", "ShopRowState1",
        "ShopRowNew1", "ShopRowIcon1", "ShopRowBackground1", "ShopRowCoin1" }) do
      assert.is_not_nil(child(root, name), name)
    end
  end)

  it("所有动态后代的非空名字唯一，深查不会静默抓错控件", function()
    local seen, duplicates = {}, {}
    collect_names(child(root, "ScreenShop"), seen, duplicates)
    assert.same({}, duplicates)
    for _, name in ipairs(REQUIRED) do assert.is_true(seen[name], name) end
  end)

  it("关闭重开重建同一份唯一节点，不叠加旧商品行", function()
    writer:close_modal("shop")
    writer:open_modal("shop", { stand = GameCfg.Shop.Stands[1] })
    local seen, duplicates = {}, {}
    collect_names(child(root, "ScreenShop"), seen, duplicates)
    assert.same({}, duplicates)
    local rows = GameCfg.Shop.ListForPage(GameCfg.Shop.Stands[1].Level, GameCfg.Shop.Pages[1], true)
    assert.is_not_nil(child(root, "ShopRow" .. #rows))
    assert.is_nil(child(root, "ShopRow" .. (#rows + 1)))
  end)
end)
