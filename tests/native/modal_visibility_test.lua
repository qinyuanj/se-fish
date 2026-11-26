-- 弹窗可见性与内部布局：
-- #276/#378 守住面板落在界面中心、面板与按钮带不透明底色；
-- #379 守住六个弹窗内部可见控件按 EUI 中心语义（原点左下、Y 向上）落点，除背景节点外，其余同级控件互不重叠且不越出父容器。
local GameCfg = require("common.game_cfg")
local ClientStore = require("client.store.client_store")
local RootView = require("client.views.root_view")
local CompendiumView = require("client.views.compendium_view")
local PlatformShopView = require("client.views.platform_shop_view")
local LotteryView = require("client.views.lottery_view")
local BlindboxView = require("client.views.blindbox_view")
local GMView = require("client.views.gm_view")
local ShopView = require("client.views.shop_view")
local Eui = require("tests.support.eui_double")

local function child(root, name)
  return root:FindFirstChild(name, true)
end

local function bounds_center(node)
  local pos, size = node.Position, node.Size
  if type(pos) ~= "table" or type(size) ~= "table" then
    return nil
  end
  if type(pos.x) ~= "number" or type(pos.y) ~= "number"
      or type(size.x) ~= "number" or type(size.y) ~= "number" then
    return nil
  end
  if size.x <= 0 or size.y <= 0 then
    return nil
  end
  return pos.x - size.x / 2, pos.x + size.x / 2, pos.y - size.y / 2, pos.y + size.y / 2
end

local function is_background_node(node)
  return tostring(node.Name or ""):match("^ShopRowBackground") ~= nil
end

local function assert_tree_layout_valid(parent, modal_label)
  if parent == nil then error(modal_label .. " 缺少容器节点") end
  local psize = parent.Size
  if type(psize) ~= "table" then
    error(modal_label .. " 容器缺少 Size: " .. tostring(parent.Name))
  end
  if not (psize.x > 0 and psize.y > 0) then
    error(modal_label .. " 容器尺寸非法: " .. tostring(parent.Name))
  end

  local siblings = {}
  for _, node in pairs(parent.children) do
    if node.Visible ~= false then
      local l, r, b, t = bounds_center(node)
      if l == nil then
        error(string.format("%s 可见子节点 %s 缺少合法 Position/Size", modal_label, tostring(node.Name)))
      end
      if l < -0.01 or r > psize.x + 0.01 or b < -0.01 or t > psize.y + 0.01 then
        error(string.format(
          "%s 子节点 %s 越出父容器 %s (%.1f..%.1f, %.1f..%.1f) vs (0..%.1f, 0..%.1f)",
          modal_label, tostring(node.Name), tostring(parent.Name), l, r, b, t, psize.x, psize.y))
      end
      if not is_background_node(node) then
        siblings[#siblings + 1] = { node = node, l = l, r = r, b = b, t = t }
      end
      if next(node.children) ~= nil then
        assert_tree_layout_valid(node, modal_label)
      end
    end
  end

  table.sort(siblings, function(a, b) return tostring(a.node.Name) < tostring(b.node.Name) end)
  for i = 1, #siblings do
    for j = i + 1, #siblings do
      local a, b = siblings[i], siblings[j]
      if a.l < b.r - 0.01 and a.r > b.l + 0.01 and a.b < b.t - 0.01 and a.t > b.b + 0.01 then
        error(string.format(
          "%s 同级节点重叠: %s (%.1f..%.1f, %.1f..%.1f) 与 %s (%.1f..%.1f, %.1f..%.1f)",
          modal_label,
          tostring(a.node.Name), a.l, a.r, a.b, a.t,
          tostring(b.node.Name), b.l, b.r, b.b, b.t))
      end
    end
  end
end

describe("弹窗定位与配色", function()
  local root, store, writer, view, oldVector, oldColor

  before_each(function()
    oldVector, oldColor = rawget(_G, "Vector2"), rawget(_G, "Color")
    _G.Vector2 = { New = function(x, y) return { x = x, y = y } end }
    _G.Color = { New = function(r, g, b, a) return { r = r, g = g, b = b, a = a } end }
    store, writer = ClientStore.new()
    root = Eui.node({ Name = "UIRoot", Size = { x = 2280, y = 1080 } })
    view = RootView.mount(root, store, {
      services = {
        open_modal = function(id, payload) writer:open_modal(id, payload) end,
        close_modal = function(id) writer:close_modal(id) end,
        request_compendium = function() end,
        request_records = function() end,
        request_blindbox_state = function() end,
        send_platform = function() end,
        send_lottery = function() end,
        send_blindbox = function() end,
        send_gm = function() end,
        send_shop = function() end,
        get_device_resolution = function() return { x = 2280, y = 1080 } end,
      },
      hud = { CompendiumView.entry_spec() },
      modals = {
        compendium = CompendiumView.modal_spec(),
        platform = PlatformShopView.modal_spec(),
        lottery = LotteryView.modal_spec(),
        blindbox = BlindboxView.modal_spec(),
        gm = GMView.modal_spec(),
        shop = ShopView.modal_spec(),
      },
      create_node = function(kind, props)
        local node = Eui.node({
          Kind = kind,
          Name = props and props.Name,
          Parent = props and props.Parent,
          Visible = props and props.Visible,
          Text = props and props.Text,
          Position = props and props.Position,
          Size = props and props.Size,
          TouchEnabled = kind == "EUIButton",
        })
        if props and props.ButtonText ~= nil then
          node.ButtonText = props.ButtonText
        end
        return node
      end,
    })
  end)

  after_each(function()
    if view then view:dispose() end
    _G.Vector2, _G.Color = oldVector, oldColor
  end)

  it("面板落在界面中心，不再钉在左下角", function()
    Eui.click(child(root, "BtnCompendiumEntry"))
    local panel = child(root, "ScreenCompendium")
    assert.is_not_nil(panel)
    assert.are.equal(1140, panel.Position.x)
    assert.are.equal(540, panel.Position.y)
  end)

  it("面板与入口按钮都带不透明底色", function()
    local entry = child(root, "BtnCompendiumEntry")
    assert.is_not_nil(entry)
    assert.is_not_nil(entry.ButtonNormalColor)
    assert.is_true(entry.ButtonNormalColor.a > 200)

    Eui.click(entry)
    local panel = child(root, "ScreenCompendium")
    assert.is_not_nil(panel)
    assert.is_not_nil(panel.Color)
    assert.is_true(panel.Color.a > 200)
  end)

  it("图鉴弹窗内部控件按中心语义自上而下排布、互不重叠且不越出面板", function()
    Eui.click(child(root, "BtnCompendiumEntry"))
    local panel = child(root, "ScreenCompendium")
    assert_tree_layout_valid(panel, "图鉴")

    local title = child(panel, "LabelCompendiumTitle")
    local page1 = child(panel, "BtnCompendiumPage_1")
    local grade1 = child(panel, "BtnCompendiumGrade_normal")
    local summary = child(panel, "LabelCompendiumSummary")
    local detail = child(panel, "LabelCompendiumDetail")
    local fish_btn = child(panel, "BtnCompendiumFish_bass")
    assert.is_true(title.Position.y > page1.Position.y)
    assert.is_true(page1.Position.y > grade1.Position.y)
    assert.is_true(grade1.Position.y > summary.Position.y)
    assert.is_true(summary.Position.y > detail.Position.y)
    assert.is_true(detail.Position.y > fish_btn.Parent.Position.y)
    assert.is_true(fish_btn.Position.x > 0 and fish_btn.Position.y > 0)
  end)

  it("地图商店、抽奖机、盲盒、GM、钓场商店弹窗内部控件互不重叠且不越出面板", function()
    writer:open_modal("platform")
    writer:ingest_event("PlatformResult", {
      action = "CoinShop",
      ok = true,
      offers = GameCfg.Platform.Placeholder.CoinPage.Offers,
    })
    assert_tree_layout_valid(child(root, "ScreenPlatform"), "地图商店")

    writer:open_modal("lottery")
    assert_tree_layout_valid(child(root, "ScreenLottery"), "抽奖机")

    writer:open_modal("blindbox")
    assert_tree_layout_valid(child(root, "ScreenBlindbox"), "盲盒")

    writer:open_modal("gm")
    assert_tree_layout_valid(child(root, "ScreenGM"), "GM")

    writer:open_modal("shop", { stand = GameCfg.Shop.Stands[#GameCfg.Shop.Stands] })
    assert_tree_layout_valid(child(root, "ScreenShop"), "钓场商店(默认页)")
    Eui.click(child(root, "BtnShopPage3"))
    assert_tree_layout_valid(child(root, "ScreenShop"), "钓场商店(升级页)")
    Eui.click(child(root, "BtnShopPage4"))
    assert_tree_layout_valid(child(root, "ScreenShop"), "钓场商店(金币页)")
  end)
end)
