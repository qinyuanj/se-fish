local GameCfg = require("common.game_cfg")
local Modal = require("client.views.economy_modal")

local PlatformShopView = {}

function PlatformShopView.entry_spec()
  return {
    name = "PlatformShopEntry",
    mount = function(scope, ctx)
      local button = Modal.button(scope, ctx, ctx.root_node, "BtnMapShopEntry", "地图商店", function()
        local services = ctx.services or {}
        if type(services.open_modal) == "function" then services.open_modal("platform") end
        if type(services.send_platform) == "function" then services.send_platform({ action = "OpenCoinShop" }) end
      end)
      local rect = type((ctx.services or {}).hud_entry_rect) == "function" and ctx.services.hud_entry_rect("ShopEntry") or nil
      if rect then
        button.Position = Vector2.New(rect.x, rect.y)
        button.Size = Vector2.New(rect.w, rect.h)
      end
    end,
  }
end

function PlatformShopView.modal_spec()
  return function(scope, ctx)
    local services = ctx.services or {}
    local panel = Modal.panel(scope, ctx, "ScreenPlatform", "地图商店")
    local result_label = Modal.place(Modal.label(scope, ctx, panel, "LabelPlatformResult", "请选择商品"), 20, 64, 860, 64)
    Modal.close(scope, ctx, panel, "BtnPlatformClose", "platform")
    local seq, request_seq = 0, nil
    local awaiting = false
    local buttons, actions = {}, {}
    local function notify(text)
      if type(services.notify) == "function" then services.notify(text) end
    end
    local function refresh_buttons()
      for key, button in pairs(buttons) do
        button.Visible = actions[key] ~= nil and not awaiting
        button.TouchEnabled = actions[key] ~= nil and not awaiting
        button.Disabled = awaiting
      end
    end

    local definitions = {}
    local page = GameCfg.Platform.Placeholder and GameCfg.Platform.Placeholder.CoinPage
    for _, offer in ipairs(page and page.Offers or {}) do definitions[#definitions + 1] = offer end
    for _, key in ipairs({ "adrenaline1", "adrenaline5" }) do
      local row = GameCfg.Platform.Goods[key]
      definitions[#definitions + 1] = { key = key, name = row.name, beans = row.beans }
    end
    for index, offer in ipairs(definitions) do
      local button = Modal.button(scope, ctx, panel, "BtnPlatformOffer_" .. offer.key, offer.name or offer.key, function()
        local action = actions[offer.key]
        if not action or awaiting then return end
        seq = seq + 1
        request_seq = seq
        awaiting = true
        refresh_buttons()
        if type(services.send_platform) == "function" then
          services.send_platform({ action = action, goods = offer.key, seq = seq })
        end
      end)
      buttons[offer.key] = Modal.place(button, 20 + ((index - 1) % 2) * 440, 148 + math.floor((index - 1) / 2) * 72, 420, 56)
    end
    refresh_buttons()

    scope:effect("PlatformResultProjection", function(es)
      local result = es:d(ctx.store.platform_result)
      if type(result) ~= "table" then return end
      if awaiting and result.seq and request_seq and result.seq ~= request_seq then return end
      if (result.action == "CoinShop" or result.action == "AdrenalineShop") and result.ok then
        awaiting = false
        for key in pairs(buttons) do actions[key] = nil end
        for _, offer in ipairs(result.offers or {}) do
          local button = buttons[offer.key]
          if button then
            actions[offer.key] = result.action == "CoinShop" and "BuyCoin" or "Purchase"
            button.ButtonText = string.format("%s（%s）", offer.name or offer.key,
              tostring(offer.price or offer.beans or 0))
          end
        end
        result_label.Text = result.notice or "请选择商品"
      elseif result.action == "CoinGrant" and result.ok then
        awaiting = false
        result_label.Text = string.format("金币 +%d", result.coin or 0)
      elseif result.action == "Grant" and result.ok then
        awaiting = false
        result_label.Text = string.format("购买成功：%s", tostring(result.goods))
        if (result.overflow or 0) > 0 then
          result_label.Text = result_label.Text .. string.format("；%d 件落在面前地上", result.overflow)
          notify(result.deliveryPending and "商品已记录，落地交付待恢复" or "背包已满，溢出商品落在面前地上")
        end
      elseif not result.ok then
        awaiting = result.deliveryPending == true or result.reason == "unknown"
        result_label.Text = result.text or GameCfg.Platform.ReasonText[result.reason]
          or GameCfg.Platform.UnavailableText
        notify(result_label.Text)
      end
      refresh_buttons()
    end)
  end
end

return PlatformShopView
