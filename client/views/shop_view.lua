local GameCfg = require("common.game_cfg")
local BodyScale = require("common.body_scale")
local Spoke = require("common.packages.spoke.api")
local SpokeRuntime = require("common.packages.spoke.runtime.spoke_runtime")
local Tokens = require("client.ui.tokens")
local Layout = require("client.ui.layout")
local Primitives = require("client.ui.primitives")
local Controls = require("client.ui.controls")
local Modal = require("client.views.economy_modal")
local ShopPanelNodes = require("client.views.shop_panel_nodes")
local ViewUtil = require("client.views.view_util")
local InteractPromptArbiter = require("client.views.interact_prompt_arbiter")

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
        local aname = entry.name or (entry.stand and entry.stand.AnchorName)
        if entry.stand and near(position, entry.position, character)
            and InteractPromptArbiter.is_exclusive(position, character, aname) then
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
      Primitives.label(scope, ctx, {
        name = "LabelShopTitle",
        parent = node,
        rect = Layout.rect(80, 68, 160, 28),
        text = GameCfg.Shop.HintText,
        font_size = Tokens.FONT_SIZE.CAPTION,
        bold = true,
        color = Tokens.COLOR.WHITE,
        outline = true,
        outline_color = Tokens.COLOR.OUTLINE_DARK,
        z_order = 1,
      })
      Controls.button(scope, ctx, {
        name = "BtnShopEnter_" .. tostring(entry.name or entry.stand.AnchorName),
        parent = node,
        rect = Layout.rect(80, 24, 160, 44),
        text = GameCfg.Shop.HintText,
        variant = "gold",
        font_size = Tokens.FONT_SIZE.CAPTION,
        z_order = 2,
        on_click = function()
          Modal.open_modal(ctx, "shop", { stand = entry.stand, bubbleKey = key })
        end,
      })
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
    return {
      name = "",
      desc = "",
      priceText = "",
      limitText = "",
      upgradeText = "",
      buyText = ShopView.shop_text.Buy,
      buyEnabled = false,
    }
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

-- 商店面板句柄：分页/选中/提示 State、面板节点与详情节点都留在句柄上。
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

--- 建面板节点：委托 ShopPanelNodes 保持单文件紧凑。
---@param self ShopPanelHandle
function ShopBehavior.create_nodes(self)
  ShopPanelNodes.create_nodes(self, ShopView.shop_text)
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
    local is_active = name == current_page
    if self.tab_buttons[index] then
      Controls.set_button_style(self.tab_buttons[index], is_active and "primary" or "surface")
    end
    if self.tab_indicators[index] then
      self.tab_indicators[index].Visible = is_active
    end
  end
  local rows = self:current_rows()
  for index, row in ipairs(rows) do
    ShopPanelNodes.create_row(self, es, row, index, index == current_selected)
  end
  local row = rows[current_selected or 0]
  local model = detail_of(ctx, row)
  self.detail.LabelShopDetailName.Text = model.name
  self.detail.LabelShopDetailDesc.Text = model.desc
  self.detail.LabelShopDetailPrice.Text = model.priceText
  self.detail.LabelShopDetailLimit.Text = model.limitText
  self.detail.LabelShopDetailUpgrade.Text = model.upgradeText
  self.buy_label.Text = model.buyText
  local buy_variant = model.buyAction == "buy" and "gold"
    or model.buyAction == "coin" and "blue"
    or "disabled"
  Controls.set_button_style(self.buy, buy_variant)
  -- #235：Disabled=true 会关闭 TouchEnabled；锁定行需要保留点击以弹出原因提示，故先写 Disabled 再写 TouchEnabled。
  self.buy.Disabled = not model.buyEnabled
  self.buy.TouchEnabled = row ~= nil
  self.detail_icon.Visible = row ~= nil and model.icon ~= nil and model.icon ~= ""
  if model.icon ~= nil and model.icon ~= "" then self.detail_icon.Image = model.icon end
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
    tab_buttons = {},
    tab_indicators = {},
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
