local GameCfg = require("common.game_cfg")
local BodyScale = require("common.body_scale")
local spoke = require("common.packages.spoke.api")
local SpokeRuntime = require("common.packages.spoke.runtime.spoke_runtime")
local ViewUtil = require("client.views.view_util")
local State = spoke.State

local ShopView = {}

ShopView.FailText = {
  coin = "金币不足，可在金币页打开地图商店购买金币",
  full = "背包已满",
  max = "已升至上限",
  range = "离钓场老板太远了",
  item = "这件商品暂不出售",
  limit = "该商品已达购买次数上限",
  level = "请先完成前一级升级",
  stand = "需要更高等级摊位",
}

ShopView.ShopText = {
  Close = "关闭",
  Buy = "购买",
  GoPlatformShop = "去地图商店",
  OpenPlatformShop = "打开地图商店",
  CoinPageHint = "金币可在地图商店购买",
  PlatformUnavailable = "地图商店暂不可用，可返回其他分页",
  PlatformOpenFailed = "打开地图商店失败，可稍后重试或返回其他分页",
  PlatformOpened = "已请求打开地图商店，请在地图商店内完成操作",
  New = "新品",
  Owned = "已购",
  NoLimit = "不限购",
  StandLocked = "需 %d 级摊位",
  LimitText = "已购 %d / %d 次",
  UpgradeTarget = "当前 %d 级，买完升到 %d 级",
  UpgradeOwned = "当前 %d 级，本行已购买",
}

local function near(position, center, character)
  local dist_sq = ViewUtil.distance_sq_xz(position, center)
  if dist_sq == nil then return false end
  local radius = BodyScale.InteractionRadius(character, GameCfg.Shop.Radius)
  return dist_sq <= radius * radius
end

local function open_modal(ctx, id, payload)
  local fn = ctx.services and ctx.services.open_modal
  if type(fn) == "function" then fn(id, payload) end
end

local function close_modal(ctx, id)
  local fn = ctx.services and ctx.services.close_modal
  if type(fn) == "function" then fn(id) end
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
        open_modal(ctx, "shop", { stand = entry.stand, bubbleKey = key })
      end)
      scope:on_cleanup(function()
        local payload = ctx.store.modal_payload:now()
        if ctx.store.active_modal:now() == "shop" and type(payload) == "table"
            and payload.bubbleKey == key then
          close_modal(ctx, "shop")
        end
      end)
    end,
  }
end

local function notify(ctx, text)
  local fn = ctx.services and ctx.services.notify
  if text and type(fn) == "function" then fn(text) end
end

local function shop_state(ctx)
  return ctx.store.shop and ctx.store.shop:now() or nil
end

local function current_upgrade(ctx, kind)
  local shop = shop_state(ctx) or {}
  if kind == "backpack" then
    local item_bar = ctx.store.item_bar:now() or {}
    return math.max(shop.upgradeLevel or 0, item_bar.upgradeLevel or 0)
  end
  return shop.upgradeLevels and shop.upgradeLevels[kind] or 0
end

local function row_state(goods, level, current, purchases)
  if goods.MinShopLevel > level then
    return "locked", "stand", string.format(ShopView.ShopText.StandLocked, goods.MinShopLevel)
  end
  if goods.Upgrade then
    current = current or 0
    if goods.Upgrade.level <= current then return "owned", "level", ShopView.ShopText.Owned end
    if goods.Upgrade.level > current + 1 then return "locked", "level", ShopView.FailText.level end
  end
  local bought = purchases and purchases[goods.Number] or 0
  if (goods.PurchaseLimit or 0) > 0 and bought >= goods.PurchaseLimit then
    return "owned", "limit", ShopView.ShopText.Owned
  end
  return "buy", nil, ""
end

local function build_rows(ctx, page, level)
  local rows = {}
  local shop = shop_state(ctx) or {}
  for index, goods in ipairs(GameCfg.Shop.ListForPage(level, page, true)) do
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
      upgradeLevel = current,
      isNew = goods.MinShopLevel == level,
      newText = goods.MinShopLevel == level and ShopView.ShopText.New or "",
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
      buyText = ShopView.ShopText.Buy, buyEnabled = false }
  end
  local goods = row.goods
  local shop = shop_state(ctx) or {}
  local bought = shop.purchases and shop.purchases[row.number] or 0
  local limit = goods.PurchaseLimit or 0
  local action
  if row.purchasable then action = ctx.store.coin:now() >= (goods.Price or 0) and "buy" or "coin" end
  local buy_text = ShopView.ShopText.Buy
  if action == "coin" then
    buy_text = ShopView.ShopText.GoPlatformShop
  elseif not action then
    buy_text = row.stateText
  end
  local upgrade_text = ""
  if goods.Upgrade then
    local current = row.upgradeLevel or 0
    upgrade_text = current >= goods.Upgrade.level
        and string.format(ShopView.ShopText.UpgradeOwned, current)
        or string.format(ShopView.ShopText.UpgradeTarget, current, goods.Upgrade.level)
  end
  return {
    number = row.number,
    name = row.name,
    desc = goods.Desc or "",
    icon = row.icon,
    priceText = row.priceText,
    limitText = limit > 0 and string.format(ShopView.ShopText.LimitText, bought, limit)
        or ShopView.ShopText.NoLimit,
    upgradeText = upgrade_text,
    buyText = buy_text,
    buyAction = action,
    buyEnabled = action ~= nil,
  }
end

local function text_node(ctx, scope, parent, name)
  return ctx.create_node(scope, "EUITextLabel", { Name = name, Parent = parent, Text = "" })
end

function ShopView.modal_spec()
  return function(scope, ctx)
    local payload = ctx.store.modal_payload:now() or {}
    local level = payload.stand and payload.stand.Level or GameCfg.Shop.Stands[1].Level
    local pages = GameCfg.Shop.Pages
    local coin_page = pages[#pages]
    local page = State.new("ShopView.page", pages[1])
    local selected = State.new("ShopView.selected", nil)
    local hint = State.new("ShopView.hint", ShopView.ShopText.CoinPageHint)
    local panel = ctx.create_node(scope, "EUIImage", { Name = "ScreenShop", Visible = true })
    ctx.create_node(scope, "EUITextLabel", {
      Name = "LabelShopTitle", Parent = panel, Text = GameCfg.Shop.HintText,
    })
    local coin_label = text_node(ctx, scope, panel, "LabelCurCoin")
    local list_panel = ctx.create_node(scope, "EUIImage", { Name = "ShopListPanel", Parent = panel })
    local list = ctx.create_node(scope, "EUIImage", { Name = "ShopList", Parent = list_panel })
    local coin_panel = ctx.create_node(scope, "EUIImage", { Name = "ShopCoinPanel", Parent = panel })
    local detail_panel = ctx.create_node(scope, "EUIImage", { Name = "ShopDetailPanel", Parent = panel })
    local hint_label = text_node(ctx, scope, coin_panel, "LabelCoinPageHint")
    local platform = ctx.create_node(scope, "EUIButton", {
      Name = "BtnOpenPlatformShop", Parent = coin_panel, TouchEnabled = true,
    })
    text_node(ctx, scope, platform, "LabelOpenPlatformShop").Text = ShopView.ShopText.OpenPlatformShop
    local detail = {}
    for _, name in ipairs({ "LabelShopDetailName", "LabelShopDetailDesc", "LabelShopDetailPrice",
        "LabelShopDetailLimit", "LabelShopDetailUpgrade" }) do
      detail[name] = text_node(ctx, scope, detail_panel, name)
    end
    local detail_icon = ctx.create_node(scope, "EUIImage", { Name = "ImageShopDetailIcon", Parent = detail_panel })
    local detail_coin = ctx.create_node(scope, "EUIImage", { Name = "ImageShopDetailCoin", Parent = detail_panel })
    local buy = ctx.create_node(scope, "EUIButton", {
      Name = "BtnShopBuyDetail", Parent = detail_panel, TouchEnabled = false,
    })
    local buy_label = text_node(ctx, scope, buy, "LabelShopBuyDetail")

    for index, name in ipairs(pages) do
      local tab = ctx.create_node(scope, "EUIButton", {
        Name = "BtnShopPage" .. index, Parent = panel, TouchEnabled = true,
      })
      text_node(ctx, scope, tab, "LabelShopPage" .. index).Text = name
      local indicator = ctx.create_node(scope, "EUIImage", {
        Name = "ImageShopTabIndicator" .. index, Parent = tab,
      })
      indicator.Visible = index == 1
      ctx.connect(scope, tab.OnClicked, function()
        SpokeRuntime.batch(function()
          page:set(name)
          selected:set(nil)
          if name == coin_page then hint:set(ShopView.ShopText.CoinPageHint) end
        end)
      end)
    end

    local close = ctx.create_node(scope, "EUIButton", {
      Name = "BtnShopClose", Parent = panel, ButtonText = ShopView.ShopText.Close, TouchEnabled = true,
    })
    ctx.connect(scope, close.OnClicked, function() close_modal(ctx, "shop") end)

    local function current_rows()
      if page:now() == coin_page then return {} end
      return build_rows(ctx, page:now(), level)
    end

    scope:effect("ShopRowsAndDetail", function(es)
      local current_page = es:d(page)
      local current_selected = es:d(selected)
      local coin = es:d(ctx.store.coin)
      es:d(ctx.store.item_bar)
      if ctx.store.shop then es:d(ctx.store.shop) end
      coin_label.Text = tostring(coin)
      list_panel.Visible = current_page ~= coin_page
      coin_panel.Visible = current_page == coin_page
      detail_panel.Visible = current_page ~= coin_page
      hint_label.Text = es:d(hint) or ""
      for index, name in ipairs(pages) do
        local indicator = panel:FindFirstChild("ImageShopTabIndicator" .. index, true)
        if indicator then indicator.Visible = name == current_page end
      end
      local rows = current_rows()
      for index, row in ipairs(rows) do
        local button = ctx.create_node(es, "EUIButton", {
          Name = "ShopRow" .. index, Parent = list, TouchEnabled = row.selectable,
        })
        text_node(ctx, es, button, "ShopRowName" .. index).Text = row.name
        text_node(ctx, es, button, "ShopRowPrice" .. index).Text = row.priceText
        text_node(ctx, es, button, "ShopRowState" .. index).Text = row.stateText
        text_node(ctx, es, button, "ShopRowNew" .. index).Text = row.newText
        local icon = ctx.create_node(es, "EUIImage", { Name = "ShopRowIcon" .. index, Parent = button })
        icon.Visible = row.icon ~= nil and row.icon ~= ""
        if row.icon then icon.Image = row.icon end
        ctx.create_node(es, "EUIImage", { Name = "ShopRowBackground" .. index, Parent = button })
        ctx.create_node(es, "EUIImage", { Name = "ShopRowCoin" .. index, Parent = button })
        ctx.connect(es, button.OnClicked, function()
          if row.selectable then selected:set(index) end
        end)
      end
      local row = rows[current_selected or 0]
      local model = detail_of(ctx, row)
      detail.LabelShopDetailName.Text = model.name
      detail.LabelShopDetailDesc.Text = model.desc
      detail.LabelShopDetailPrice.Text = model.priceText
      detail.LabelShopDetailLimit.Text = model.limitText
      detail.LabelShopDetailUpgrade.Text = model.upgradeText
      buy_label.Text = model.buyText
      buy.Disabled = not model.buyEnabled
      buy.TouchEnabled = row ~= nil
      detail_icon.Visible = row ~= nil and model.icon ~= nil and model.icon ~= ""
      if model.icon then detail_icon.Image = model.icon end
      detail_coin.Visible = row ~= nil
    end)

    ctx.connect(scope, buy.OnClicked, function()
      local row = current_rows()[selected:now() or 0]
      if not row then return end
      if not row.purchasable then notify(ctx, ShopView.FailText[row.reason]) return end
      if ctx.store.coin:now() < (row.goods.Price or 0) then
        page:set(coin_page)
        return
      end
      local next_seq = ctx.services and ctx.services.next_seq
      local seq = type(next_seq) == "function" and next_seq() or 1
      local send = ctx.services and ctx.services.send_shop
      if type(send) == "function" then send({ action = "Buy", number = row.number, seq = seq }) end
    end)

    ctx.connect(scope, platform.OnClicked, function()
      local open = ctx.services and ctx.services.open_platform_shop
      if type(open) ~= "function" then
        hint:set(ShopView.ShopText.PlatformUnavailable)
        return
      end
      local ok, opened = pcall(open)
      if not ok then
        hint:set(ShopView.ShopText.PlatformOpenFailed)
        print("[ShopView] 打开地图商店失败", tostring(opened))
      elseif opened == false then
        hint:set(ShopView.ShopText.PlatformUnavailable)
      else
        hint:set(ShopView.ShopText.PlatformOpened)
      end
    end)
  end
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
            notify(ctx, "扩容成功：道具栏 " .. tostring(GameCfg.Items.InitialItemBarSlots + result.level)
              .. " 格，背包 " .. tostring(result.level == #GameCfg.Items.UpgradePrices
                and GameCfg.Items.MaxBackpackSlots
                or GameCfg.Items.InitialBackpackSlots + result.level * GameCfg.Items.BackpackSlotsPerUpgrade) .. " 格")
          else
            local definition = result.itemId and GameCfg.Items.Definitions[result.itemId] or nil
            notify(ctx, "购买成功：" .. tostring(result.name or definition and definition.Name or result.itemId)
              .. "，花费 " .. tostring(result.price) .. " 金币")
          end
        else
          notify(ctx, ShopView.FailText[result.reason] or "购买失败")
        end
      end)
    end,
  }
end

return ShopView
