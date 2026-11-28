-- 钓场商店面板节点构建与单行卡片排布（归属 L2 client.views）：
-- 配合 client/views/shop_view.lua 拆分以控制单文件体积在 5500 tokens 以内；
-- 使用 PanelShop 避开编辑器预置 ScreenShop，全 4px 栅格、零嵌套框、零 ButtonText 双字。

local GameCfg = require("common.game_cfg")
local Tokens = require("client.ui.tokens")
local Layout = require("client.ui.layout")
local Primitives = require("client.ui.primitives")
local Controls = require("client.ui.controls")
local Modal = require("client.views.economy_modal")

local ShopPanelNodes = {}

local PANEL_W = 1080
local PANEL_H = 680
local PAD = Tokens.SPACE.PANEL_PAD
local LIST_W = 660
local BODY_H = 504
local DETAIL_W = 340
local ROW_W = 324
local ROW_H = 36

-- 详情卡片五个文本节点的排布与样式（相对 ShopDetailPanel 左上角，4px 栅格）。
local SHOP_DETAIL_LAYOUT = {
  { "LabelShopDetailName", 96, 20, 224, 36, Tokens.FONT_SIZE.BODY, true, Tokens.COLOR.TEXT_DARK, 0, 1 },
  { "LabelShopDetailPrice", 128, 60, 192, 28, Tokens.FONT_SIZE.BODY, true, Tokens.COLOR.TEXT_GOLD_DARK, 0, 1 },
  { "LabelShopDetailDesc", 20, 100, 300, 160, Tokens.FONT_SIZE.CAPTION, false, Tokens.COLOR.TEXT_DARK, 0, 0 },
  { "LabelShopDetailLimit", 20, 276, 300, 32, Tokens.FONT_SIZE.CAPTION, false, Tokens.COLOR.TEXT_MUTED, 0, 1 },
  { "LabelShopDetailUpgrade", 20, 316, 300, 32, Tokens.FONT_SIZE.CAPTION, true, Tokens.COLOR.TEXT_GOLD_DARK, 0, 1 },
}

--- 建面板静态节点：PanelShop 壳、页签栏、金币余额、列表纯容器、金币页卡片与详情卡片。
---@param self table ShopPanelHandle
---@param shop_text table 文案表
function ShopPanelNodes.create_nodes(self, shop_text)
  local scope, ctx = self.scope, self.ctx
  local panel = Modal.panel(scope, ctx, "PanelShop", GameCfg.Shop.HintText, {
    width = PANEL_W,
    height = PANEL_H,
    title_name = "LabelShopTitle",
    close_name = "BtnShopClose",
    modal_id = "shop",
  })
  self.panel = panel

  -- 顶部页签栏（左侧 4 个页签 + 底部独立指示条）与右上金币余额
  self.tab_buttons = {}
  self.tab_indicators = {}
  for index, name in ipairs(self.pages) do
    local left = PAD + (index - 1) * 148
    self.tab_buttons[index] = Controls.button(scope, ctx, {
      name = "BtnShopPage" .. index,
      parent = panel,
      rect = Layout.from_top_left(PANEL_H, left, 84, 136, 40),
      text = name,
      label_name = "LabelShopPage" .. index,
      variant = index == 1 and "primary" or "surface",
      font_size = Tokens.FONT_SIZE.CAPTION,
      z_order = 2,
      on_click = function() self:select_page(name) end,
    })
    self.tab_indicators[index] = Primitives.image(scope, ctx, {
      name = "ImageShopTabIndicator" .. index,
      parent = panel,
      rect = Layout.from_top_left(PANEL_H, left, 128, 136, 4),
      image = Tokens.ASSET.BLOCK,
      color = Tokens.COLOR.GOLD,
      visible = index == 1,
      z_order = 2,
    })
  end

  Primitives.image(scope, ctx, {
    name = "ImageCurCoin",
    parent = panel,
    rect = Layout.from_top_left(PANEL_H, 808, 90, 28, 28),
    image = Tokens.ASSET.COIN,
    z_order = 2,
  })
  self.coin_label = Primitives.label(scope, ctx, {
    name = "LabelCurCoin",
    parent = panel,
    rect = Layout.from_top_left(PANEL_H, 844, 84, 204, 40),
    text = "0",
    font_size = Tokens.FONT_SIZE.BUTTON,
    bold = true,
    color = Tokens.COLOR.TEXT_GOLD_DARK,
    align_x = 0,
    align_y = 1,
    z_order = 2,
  })

  -- 左侧商品列表纯容器（2 列 × 最多 12 行 = 24 项，12*36 + 11*4 = 476 <= 504px）
  self.list_panel = Primitives.container(scope, ctx, {
    name = "ShopListPanel",
    parent = panel,
    rect = Layout.from_top_left(PANEL_H, PAD, 144, LIST_W, BODY_H),
    z_order = 1,
  })
  self.list = Primitives.container(scope, ctx, {
    name = "ShopList",
    parent = self.list_panel,
    rect = Layout.center_in(LIST_W, BODY_H, LIST_W, BODY_H),
    z_order = 1,
  })

  -- 金币页卡片（与普通列表页互斥显示）
  local coin_w = PANEL_W - PAD * 2
  self.coin_panel = Modal.surface(scope, ctx, panel, "ShopCoinPanel",
    Layout.from_top_left(PANEL_H, PAD, 144, coin_w, BODY_H), { z_order = 1 })
  self.hint_label = Primitives.label(scope, ctx, {
    name = "LabelCoinPageHint",
    parent = self.coin_panel,
    rect = Layout.from_top_left(BODY_H, 64, 140, coin_w - 128, 64),
    text = shop_text.coin_page_hint,
    font_size = Tokens.FONT_SIZE.BUTTON,
    color = Tokens.COLOR.TEXT_DARK,
    align_x = 1,
    align_y = 1,
    z_order = 2,
  })
  self.platform = Controls.button(scope, ctx, {
    name = "BtnOpenPlatformShop",
    parent = self.coin_panel,
    rect = Layout.from_top_left(BODY_H, (coin_w - 280) / 2, 252, 280, 64),
    text = shop_text.open_platform_shop,
    label_name = "LabelOpenPlatformShop",
    variant = "gold",
    font_size = Tokens.FONT_SIZE.BUTTON,
    z_order = 2,
  })

  -- 右侧商品详情卡片
  self.detail_panel = Modal.surface(scope, ctx, panel, "ShopDetailPanel",
    Layout.from_top_left(PANEL_H, PAD + LIST_W + 16, 144, DETAIL_W, BODY_H), { z_order = 1 })
  local detail = {}
  for _, spec in ipairs(SHOP_DETAIL_LAYOUT) do
    detail[spec[1]] = Primitives.label(scope, ctx, {
      name = spec[1],
      parent = self.detail_panel,
      rect = Layout.from_top_left(BODY_H, spec[2], spec[3], spec[4], spec[5]),
      text = "",
      font_size = spec[6],
      bold = spec[7],
      color = spec[8],
      align_x = spec[9],
      align_y = spec[10],
      z_order = 2,
    })
  end
  self.detail = detail
  self.detail_icon = Primitives.image(scope, ctx, {
    name = "ImageShopDetailIcon",
    parent = self.detail_panel,
    rect = Layout.from_top_left(BODY_H, 20, 20, 64, 64),
    image = Tokens.ASSET.ROUND_RECT,
    visible = false,
    z_order = 2,
  })
  self.detail_coin = Primitives.image(scope, ctx, {
    name = "ImageShopDetailCoin",
    parent = self.detail_panel,
    rect = Layout.from_top_left(BODY_H, 96, 62, 24, 24),
    image = Tokens.ASSET.COIN,
    visible = false,
    z_order = 2,
  })
  local buy_btn, buy_lbl = Controls.button(scope, ctx, {
    name = "BtnShopBuyDetail",
    parent = self.detail_panel,
    rect = Layout.from_top_left(BODY_H, 40, 420, 260, 60),
    text = shop_text.Buy,
    label_name = "LabelShopBuyDetail",
    variant = "gold",
    font_size = Tokens.FONT_SIZE.BUTTON,
    touch = false,
    z_order = 2,
  })
  self.buy = buy_btn
  self.buy_label = buy_lbl
end

--- 建一行商品卡片（324×36）：零 ButtonText 双字、4px 栅格横向无重叠，单页可容 24+ 项。
---@param self table ShopPanelHandle
---@param es table
---@param row table
---@param index number
---@param is_selected boolean
function ShopPanelNodes.create_row(self, es, row, index, is_selected)
  local ctx = self.ctx
  local cell = Layout.grid_cell(BODY_H, 0, 0, 2, index, ROW_W, ROW_H, 12, 4)
  local button = Controls.button(es, ctx, {
    name = "ShopRow" .. index,
    parent = self.list,
    rect = cell,
    variant = is_selected and "card" or "surface",
    icon_only = true,
    touch = row.selectable,
    z_order = 2,
    on_click = function()
      if row.selectable then self.selected:set(index) end
    end,
  })
  Primitives.image(es, ctx, {
    name = "ShopRowBackground" .. index,
    parent = button,
    rect = Layout.center_in(ROW_W, ROW_H, ROW_W, ROW_H),
    image = Tokens.ASSET.ROUND_RECT,
    color = is_selected and Tokens.COLOR.MODAL_CARD_ACTIVE or Tokens.COLOR.MODAL_CARD,
    stretch = Tokens.vec4(12, 12, 12, 12),
    z_order = 0,
  })
  local icon = Primitives.image(es, ctx, {
    name = "ShopRowIcon" .. index,
    parent = button,
    rect = Layout.from_top_left(ROW_H, 4, 4, 28, 28),
    image = (row.icon ~= nil and row.icon ~= "") and row.icon or Tokens.ASSET.ROUND_RECT,
    visible = row.icon ~= nil and row.icon ~= "",
    z_order = 1,
  })
  if row.icon ~= nil and row.icon ~= "" then icon.Image = row.icon end
  Primitives.label(es, ctx, {
    name = "ShopRowName" .. index,
    parent = button,
    rect = Layout.from_top_left(ROW_H, 36, 4, 128, 28),
    text = row.name,
    font_size = Tokens.FONT_SIZE.MICRO,
    bold = true,
    color = Tokens.COLOR.TEXT_DARK,
    align_x = 0,
    align_y = 1,
    z_order = 1,
  })
  Primitives.image(es, ctx, {
    name = "ShopRowCoin" .. index,
    parent = button,
    rect = Layout.from_top_left(ROW_H, 168, 8, 20, 20),
    image = Tokens.ASSET.COIN,
    z_order = 1,
  })
  Primitives.label(es, ctx, {
    name = "ShopRowPrice" .. index,
    parent = button,
    rect = Layout.from_top_left(ROW_H, 192, 4, 48, 28),
    text = row.priceText,
    font_size = Tokens.FONT_SIZE.MICRO,
    bold = true,
    color = Tokens.COLOR.TEXT_GOLD_DARK,
    align_x = 0,
    align_y = 1,
    z_order = 1,
  })
  Primitives.label(es, ctx, {
    name = "ShopRowNew" .. index,
    parent = button,
    rect = Layout.from_top_left(ROW_H, 244, 0, 76, 16),
    text = row.newText,
    font_size = Tokens.FONT_SIZE.MICRO,
    bold = true,
    color = Tokens.COLOR.DANGER,
    align_x = 2,
    align_y = 1,
    z_order = 1,
  })
  Primitives.label(es, ctx, {
    name = "ShopRowState" .. index,
    parent = button,
    rect = Layout.from_top_left(ROW_H, 244, 16, 76, 20),
    text = row.stateText,
    font_size = Tokens.FONT_SIZE.MICRO,
    color = Tokens.COLOR.TEXT_MUTED,
    align_x = 2,
    align_y = 1,
    z_order = 1,
  })
end

return ShopPanelNodes
