local GameCfg = require("common.game_cfg")
local BodyScale = require("common.body_scale")
local Spoke = require("common.packages.spoke.api")
local SpokeRuntime = require("common.packages.spoke.runtime.spoke_runtime")
local Modal = require("client.views.economy_modal")
local ViewUtil = require("client.views.view_util")
local State = Spoke.State

local ShopView = {}

ShopView.fail_text = {
  coin = "金币不足，可在金币页打开地图商店购买金币",
  full = "背包已满",
  max = "已升至上限",
  range = "离钓场老板太远了",
  item = "这件商品暂不出售",
  limit = "该商品已达购买次数上限",
  level = "请先完成前一级升级",
  stand = "需要更高等级摊位",
}

ShopView.shop_text = {
  close = "关闭",
  Buy = "购买",
  go_platform_shop = "去地图商店",
  open_platform_shop = "打开地图商店",
  coin_page_hint = "金币可在地图商店购买",
  platform_unavailable = "地图商店暂不可用，可返回其他分页",
  platform_open_failed = "打开地图商店失败，可稍后重试或返回其他分页",
  platform_opened = "已请求打开地图商店，请在地图商店内完成操作",
  New = "新品",
  owned = "已购",
  no_limit = "不限购",
  stand_locked = "需 %d 级摊位",
  limit_text = "已购 %d / %d 次",
  upgrade_target = "当前 %d 级，买完升到 %d 级",
  upgrade_owned = "当前 %d 级，本行已购买",
}

local function near(position, center, character)
  local dist_sq = ViewUtil.distance_sq_xz(position, center)
  if dist_sq == nil then return false end
  local radius = BodyScale.interaction_radius(character, GameCfg.Shop.Radius)
  return dist_sq <= radius * radius
end

function ShopView.bubble_spec(options)
  options = type(options) == "table" and options or {}
  return {
    items = function(es, store)
      local position = es:d(store.position)
      local character = es:d(store.local_character)
      local list = {}
      for _, entry in ipairs(options.anchors or {}) do
        if entry.stand and near(position, entry.position, character) then
          list[#list + 1] = entry
        end
      end
      return list
    end,
    key_of = function(entry) return "shop:" .. tostring(entry.name or entry.stand.AnchorName) end,
    mount = function(scope, ctx, item_signal)
      local entry = item_signal:now()
      local key = "shop:" .. tostring(entry.name or entry.stand.AnchorName)
      local fallback_name = "SceneNodeShop_" .. tostring(entry.name or entry.stand.AnchorName)
      local node = ViewUtil.create_anchor_scene_node(scope, ctx, entry, GameCfg.Shop.BubbleHeight, "shop", fallback_name)
      local title = ctx.create_node(scope, "EUITextLabel", {
        Name = "LabelShopTitle",
        Parent = node,
        Text = GameCfg.Shop.HintText,
      })
      title.TouchEnabled = false
      local button = ctx.create_node(scope, "EUIButton", {
        Name = "BtnShopEnter_" .. tostring(entry.name or entry.stand.AnchorName),
        Parent = node,
        ButtonText = GameCfg.Shop.HintText,
        TouchEnabled = true,
      })
      ctx.connect(scope, button.OnClicked, function()
        Modal.open_modal(ctx, "shop", { stand = entry.stand, bubbleKey = key })
      end)
      scope:on_cleanup(function()
        local payload = ctx.store.modal_payload:now()
        if ctx.store.active_modal:now() == "shop" and type(payload) == "table"
            and payload.bubbleKey == key then
          Modal.close_modal(ctx, "shop")
        end
      end)
    end,
  }
end

local function shop_state(ctx)
  return ctx.store.shop and ctx.store.shop:now() or nil
end

local function current_upgrade(ctx, kind)
  local shop = shop_state(ctx) or {}
  if kind == "backpack" then
    local item_bar = ctx.store.item_bar:now() or {}
    return math.max(shop.upgrade_level or 0, item_bar.upgrade_level or 0)
  end
  return shop.upgrade_levels and shop.upgrade_levels[kind] or 0
end

local function row_state(goods, level, current, purchases)
  if goods.MinShopLevel > level then
    return "locked", "stand", string.format(ShopView.shop_text.stand_locked, goods.MinShopLevel)
  end
  if goods.Upgrade then
    current = current or 0
    if goods.Upgrade.level <= current then return "owned", "level", ShopView.shop_text.owned end
    if goods.Upgrade.level > current + 1 then return "locked", "level", ShopView.fail_text.level end
  end
  local bought = purchases and purchases[goods.Number] or 0
  if (goods.PurchaseLimit or 0) > 0 and bought >= goods.PurchaseLimit then
    return "owned", "limit", ShopView.shop_text.owned
  end
  return "buy", nil, ""
end

local function build_rows(ctx, page, level)
  local rows = {}
  local shop = shop_state(ctx) or {}
  for index, goods in ipairs(GameCfg.Shop.list_for_page(level, page, true)) do
    local current = goods.Upgrade and current_upgrade(ctx, goods.Upgrade.kind) or nil
    local state, reason, state_text = row_state(goods, level, current, shop.purchases)
    local definition = goods.ItemId and GameCfg.Items.Definitions[goods.ItemId] or nil
    rows[index] = {
      index = index,
      number = goods.Number,
      goods = goods,
      name = goods.Name,
      priceText = tostring(goods.Price),
      state = state,
      reason = reason,
      stateText = state_text,
      upgrade_level = current,
      isNew = goods.MinShopLevel == level,
      newText = goods.MinShopLevel == level and ShopView.shop_text.New or "",
      icon = definition and definition.Icon or nil,
      selectable = state ~= "owned",
      purchasable = state == "buy",
    }
  end
  return rows
end

local function detail_of(ctx, row)
  if not row then
    return { name = "", desc = "", priceText = "", limitText = "", upgradeText = "",
      buyText = ShopView.shop_text.Buy, buyEnabled = false }
  end
  local goods = row.goods
  local shop = shop_state(ctx) or {}
  local bought = shop.purchases and shop.purchases[row.number] or 0
  local limit = goods.PurchaseLimit or 0
  local action
  if row.purchasable then action = ctx.store.coin:now() >= (goods.Price or 0) and "buy" or "coin" end
  local buy_text = ShopView.shop_text.Buy
  if action == "coin" then
    buy_text = ShopView.shop_text.go_platform_shop
  elseif not action then
    buy_text = row.stateText
  end
  local upgrade_text = ""
  if goods.Upgrade then
    local current = row.upgrade_level or 0
    upgrade_text = current >= goods.Upgrade.level
        and string.format(ShopView.shop_text.upgrade_owned, current)
        or string.format(ShopView.shop_text.upgrade_target, current, goods.Upgrade.level)
  end
  return {
    number = row.number,
    name = row.name,
    desc = goods.Desc or "",
    icon = row.icon,
    priceText = row.priceText,
    limitText = limit > 0 and string.format(ShopView.shop_text.limit_text, bought, limit)
        or ShopView.shop_text.no_limit,
    upgradeText = upgrade_text,
    buyText = buy_text,
    buyAction = action,
    buyEnabled = action ~= nil,
  }
end

local function text_node(ctx, scope, parent, name)
  return ctx.create_node(scope, "EUITextLabel", { Name = name, Parent = parent, Text = "" })
end

-- 详情块五个文本节点的名字与排布（x, y, w, h 按父节点左上角语义）。
local SHOP_DETAIL_LAYOUT = {
  { "LabelShopDetailName", 88, 12, 224, 36 },
  { "LabelShopDetailPrice", 118, 52, 194, 28 },
  { "LabelShopDetailDesc", 12, 90, 300, 140 },
  { "LabelShopDetailLimit", 12, 242, 300, 36 },
  { "LabelShopDetailUpgrade", 12, 288, 300, 36 },
}

-- 商店面板句柄：分页/选中/提示 State、面板节点与详情节点都留在句柄上；
-- 方法名沿用拆分前的局部函数名，挂载入口只做装配。
---@class ShopPanelHandle: table<string, any>
---@type ShopPanelHandle
local ShopBehavior = {}

--- 当前分页要展示的商品行；金币页没有商品行。
---@param self ShopPanelHandle
---@return table[]
function ShopBehavior.current_rows(self)
  if self.page:now() == self.coin_page then return {} end
  return build_rows(self.ctx, self.page:now(), self.level)
end

--- 分页页签：切页、清选中，并在金币页重置提示。
---@param self ShopPanelHandle
---@param name string
function ShopBehavior.select_page(self, name)
  local page, selected, hint = self.page, self.selected, self.hint
  SpokeRuntime.batch(function()
    page:set(name)
    selected:set(nil)
    if name == self.coin_page then hint:set(ShopView.shop_text.coin_page_hint) end
  end)
end

--- 建面板节点：金币数、列表/金币页/详情三块、分页页签与关闭按钮。
---@param self ShopPanelHandle
function ShopBehavior.create_nodes(self)
  local scope, ctx = self.scope, self.ctx
  local panel = Modal.panel(scope, ctx, "ScreenShop", GameCfg.Shop.HintText)
  self.panel = panel
  self.coin_label = Modal.place(text_node(ctx, scope, panel, "LabelCurCoin"), 620, 60, 260, 36)
  self.list_panel = Modal.place(ctx.create_node(scope, "EUIImage", { Name = "ShopListPanel", Parent = panel }), 20, 108, 520, 472)
  self.list = Modal.place(ctx.create_node(scope, "EUIImage", { Name = "ShopList", Parent = self.list_panel }), 0, 0, 520, 472, 472)
  self.coin_panel = Modal.place(ctx.create_node(scope, "EUIImage", { Name = "ShopCoinPanel", Parent = panel }), 20, 108, 860, 472)
  self.detail_panel = Modal.place(ctx.create_node(scope, "EUIImage", { Name = "ShopDetailPanel", Parent = panel }), 556, 108, 324, 472)
  self.hint_label = Modal.place(text_node(ctx, scope, self.coin_panel, "LabelCoinPageHint"), 40, 120, 780, 64, 472)
  self.platform = Modal.place(ctx.create_node(scope, "EUIButton", {
    Name = "BtnOpenPlatformShop", Parent = self.coin_panel, TouchEnabled = true,
  }), 300, 220, 260, 60, 472)
  Modal.place(text_node(ctx, scope, self.platform, "LabelOpenPlatformShop"), 0, 0, 260, 60, 60).Text = ShopView.shop_text.open_platform_shop
  local detail = {}
  for _, spec in ipairs(SHOP_DETAIL_LAYOUT) do
    detail[spec[1]] = Modal.place(text_node(ctx, scope, self.detail_panel, spec[1]), spec[2], spec[3], spec[4], spec[5], 472)
  end
  self.detail = detail
  self.detail_icon = Modal.place(ctx.create_node(scope, "EUIImage", { Name = "ImageShopDetailIcon", Parent = self.detail_panel }), 12, 12, 64, 64, 472)
  self.detail_coin = Modal.place(ctx.create_node(scope, "EUIImage", { Name = "ImageShopDetailCoin", Parent = self.detail_panel }), 88, 54, 24, 24, 472)
  self.buy = Modal.place(ctx.create_node(scope, "EUIButton", {
    Name = "BtnShopBuyDetail", Parent = self.detail_panel, TouchEnabled = false,
  }), 42, 396, 240, 56, 472)
  self.buy_label = Modal.place(text_node(ctx, scope, self.buy, "LabelShopBuyDetail"), 0, 0, 240, 56, 56)

  for index, name in ipairs(self.pages) do
    local tab = Modal.place(ctx.create_node(scope, "EUIButton", {
      Name = "BtnShopPage" .. index, Parent = panel, TouchEnabled = true,
    }), 20 + (index - 1) * 144, 60, 134, 36)
    Modal.place(text_node(ctx, scope, tab, "LabelShopPage" .. index), 0, 0, 134, 30, 36).Text = name
    local indicator = Modal.place(ctx.create_node(scope, "EUIImage", {
      Name = "ImageShopTabIndicator" .. index, Parent = tab,
    }), 0, 31, 134, 5, 36)
    indicator.Visible = index == 1
    ctx.connect(scope, tab.OnClicked, function()
      self:select_page(name)
    end)
  end

  Modal.close(scope, ctx, panel, "BtnShopClose", "shop")
end

--- 建一行商品：名称/价格/状态/新品/图标/底色/金币标与点击选中。
---@param self ShopPanelHandle
---@param es table
---@param row table
---@param index number
function ShopBehavior.create_row(self, es, row, index)
  local ctx = self.ctx
  local col = (index - 1) % 2
  local row_idx = math.floor((index - 1) / 2)
  local button = Modal.place(ctx.create_node(es, "EUIButton", {
    Name = "ShopRow" .. index, Parent = self.list, TouchEnabled = row.selectable,
  }), 4 + col * 258, 4 + row_idx * 38, 250, 34, 472)
  Modal.place(text_node(ctx, es, button, "ShopRowName" .. index), 36, 3, 104, 28, 34).Text = row.name
  Modal.place(text_node(ctx, es, button, "ShopRowPrice" .. index), 164, 3, 40, 28, 34).Text = row.priceText
  Modal.place(text_node(ctx, es, button, "ShopRowState" .. index), 206, 3, 40, 14, 34).Text = row.stateText
  Modal.place(text_node(ctx, es, button, "ShopRowNew" .. index), 206, 17, 40, 14, 34).Text = row.newText
  local icon = Modal.place(ctx.create_node(es, "EUIImage", { Name = "ShopRowIcon" .. index, Parent = button }), 4, 3, 28, 28, 34)
  icon.Visible = row.icon ~= nil and row.icon ~= ""
  if row.icon then icon.Image = row.icon end
  Modal.place(ctx.create_node(es, "EUIImage", { Name = "ShopRowBackground" .. index, Parent = button }), 0, 0, 250, 34, 34)
  Modal.place(ctx.create_node(es, "EUIImage", { Name = "ShopRowCoin" .. index, Parent = button }), 142, 7, 20, 20, 34)
  ctx.connect(es, button.OnClicked, function()
    if row.selectable then self.selected:set(index) end
  end)
end

--- 商品行与详情投影：切页可见性、页签高亮、行节点重建与详情文案。
---@param self ShopPanelHandle
---@param es table EffectScope
function ShopBehavior.on_rows_and_detail(self, es)
  local ctx = self.ctx
  local current_page = es:d(self.page)
  local current_selected = es:d(self.selected)
  local coin = es:d(ctx.store.coin)
  es:d(ctx.store.item_bar)
  if ctx.store.shop then es:d(ctx.store.shop) end
  self.coin_label.Text = tostring(coin)
  self.list_panel.Visible = current_page ~= self.coin_page
  self.coin_panel.Visible = current_page == self.coin_page
  self.detail_panel.Visible = current_page ~= self.coin_page
  self.hint_label.Text = es:d(self.hint) or ""
  for index, name in ipairs(self.pages) do
    local indicator = self.panel:FindFirstChild("ImageShopTabIndicator" .. index, true)
    if indicator then indicator.Visible = name == current_page end
  end
  local rows = self:current_rows()
  for index, row in ipairs(rows) do
    self:create_row(es, row, index)
  end
  local row = rows[current_selected or 0]
  local model = detail_of(ctx, row)
  self.detail.LabelShopDetailName.Text = model.name
  self.detail.LabelShopDetailDesc.Text = model.desc
  self.detail.LabelShopDetailPrice.Text = model.priceText
  self.detail.LabelShopDetailLimit.Text = model.limitText
  self.detail.LabelShopDetailUpgrade.Text = model.upgradeText
  self.buy_label.Text = model.buyText
  self.buy.Disabled = not model.buyEnabled
  self.buy.TouchEnabled = row ~= nil
  self.detail_icon.Visible = row ~= nil and model.icon ~= nil and model.icon ~= ""
  if model.icon then self.detail_icon.Image = model.icon end
  self.detail_coin.Visible = row ~= nil
end

--- 详情购买按钮：不可买提示原因，金币不足切到金币页，否则发 Buy 上行。
---@param self ShopPanelHandle
function ShopBehavior.on_buy_clicked(self)
  local ctx = self.ctx
  local row = self:current_rows()[self.selected:now() or 0]
  if not row then return end
  if not row.purchasable then ViewUtil.notify(ctx, ShopView.fail_text[row.reason]) return end
  if ctx.store.coin:now() < (row.goods.Price or 0) then
    self.page:set(self.coin_page)
    return
  end
  local next_seq = ctx.services and ctx.services.next_seq
  local seq = type(next_seq) == "function" and next_seq() or 1
  local send = ctx.services and ctx.services.send_shop
  if type(send) == "function" then send({ action = "Buy", number = row.number, seq = seq }) end
end

--- 打开地图商店：按 pcall 结果写提示，失败时打日志。
---@param self ShopPanelHandle
function ShopBehavior.on_platform_clicked(self)
  local ctx = self.ctx
  local open = ctx.services and ctx.services.open_platform_shop
  if type(open) ~= "function" then
    self.hint:set(ShopView.shop_text.platform_unavailable)
    return
  end
  local ok, opened = pcall(open)
  if not ok then
    self.hint:set(ShopView.shop_text.platform_open_failed)
    print("[ShopView] 打开地图商店失败", tostring(opened))
  elseif opened == false then
    self.hint:set(ShopView.shop_text.platform_unavailable)
  else
    self.hint:set(ShopView.shop_text.platform_opened)
  end
end

--- 挂载商店面板：造句柄、建节点、接投影与两个按钮。
---@param scope table
---@param ctx table
local function mount(scope, ctx)
  local payload = ctx.store.modal_payload:now() or {}
  local level = payload.stand and payload.stand.Level or GameCfg.Shop.Stands[1].Level
  local pages = GameCfg.Shop.Pages
  local coin_page = pages[#pages]
  ---@type ShopPanelHandle
  local self = {
    scope = scope,
    ctx = ctx,
    level = level,
    pages = pages,
    coin_page = coin_page,
    page = State.new("ShopView.page", pages[1]),
    selected = State.new("ShopView.selected", nil),
    hint = State.new("ShopView.hint", ShopView.shop_text.coin_page_hint),
    panel = nil,
    coin_label = nil,
    list_panel = nil,
    list = nil,
    coin_panel = nil,
    detail_panel = nil,
    hint_label = nil,
    platform = nil,
    detail = {},
    detail_icon = nil,
    detail_coin = nil,
    buy = nil,
    buy_label = nil,
  }
  for name, method in pairs(ShopBehavior) do self[name] = method end
  self:create_nodes()

  scope:effect("ShopRowsAndDetail", function(es) self:on_rows_and_detail(es) end)
  ctx.connect(scope, self.buy.OnClicked, function() self:on_buy_clicked() end)
  ctx.connect(scope, self.platform.OnClicked, function() self:on_platform_clicked() end)
end

function ShopView.modal_spec()
  return mount
end

function ShopView.presentation_spec()
  return {
    name = "ShopPresentation",
    mount = function(scope, ctx)
      scope:subscribe(ctx.store.on_server_event, function(event)
        if event.channel ~= "ShopResult" or type(event.payload) ~= "table" then return end
        local result = event.payload
        if result.ok then
          if result.action == "UpgradeStorage" then
            ViewUtil.notify(ctx, "扩容成功：道具栏 " .. tostring(GameCfg.Items.InitialItemBarSlots + result.level)
              .. " 格，背包 " .. tostring(result.level == #GameCfg.Items.UpgradePrices
                and GameCfg.Items.MaxBackpackSlots
                or GameCfg.Items.InitialBackpackSlots + result.level * GameCfg.Items.BackpackSlotsPerUpgrade) .. " 格")
          else
            local definition = result.itemId and GameCfg.Items.Definitions[result.itemId] or nil
            ViewUtil.notify(ctx, "购买成功：" .. tostring(result.name or definition and definition.Name or result.itemId)
              .. "，花费 " .. tostring(result.price) .. " 金币")
          end
        else
          ViewUtil.notify(ctx, ShopView.fail_text[result.reason] or "购买失败")
        end
      end)
    end,
  }
end

return ShopView
