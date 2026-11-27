local GameCfg = require("common.game_cfg")
local Modal = require("client.views.economy_modal")
local ViewUtil = require("client.views.view_util")

local PlatformShopView = {}

--- 商品清单：占位页 CoinPage 的 Offer 加两种肾上腺素商品。
---@return table[]
local function platform_definitions()
  local definitions = {}
  local page = GameCfg.Platform.Placeholder and GameCfg.Platform.Placeholder.CoinPage
  for _, offer in ipairs(page and page.Offers or {}) do definitions[#definitions + 1] = offer end
  for _, key in ipairs({ "adrenaline1", "adrenaline5" }) do
    local row = GameCfg.Platform.Goods[key]
    definitions[#definitions + 1] = { key = key, name = row.name, beans = row.beans }
  end
  return definitions
end

-- 地图商店面板句柄：面板节点、请求序号与可买动作表都留在句柄上；
-- 方法名沿用拆分前的局部函数名，挂载入口只做装配。
---@class PlatformShopPanelHandle: table<string, any>
---@type PlatformShopPanelHandle
local PlatformShopBehavior = {}

--- 建面板节点：结果行、关闭按钮与逐个商品按钮。
---@param self PlatformShopPanelHandle
function PlatformShopBehavior.create_nodes(self)
  local scope, ctx = self.scope, self.ctx
  local panel = Modal.panel(scope, ctx, "ScreenPlatform", "地图商店")
  self.panel = panel
  self.result_label = Modal.place(Modal.label(scope, ctx, panel, "LabelPlatformResult", "请选择商品"), 20, 64, 860, 64)
  Modal.close(scope, ctx, panel, "BtnPlatformClose", "platform")
  for index, offer in ipairs(platform_definitions()) do
    local button = Modal.button(scope, ctx, panel, "BtnPlatformOffer_" .. offer.key, offer.name or offer.key, function()
      self:send_action(offer.key)
    end)
    self.buttons[offer.key] = Modal.place(button, 20 + ((index - 1) % 2) * 440, 148 + math.floor((index - 1) / 2) * 72, 420, 56)
  end
  self:refresh_buttons()
end

--- 面板提示统一走 ViewUtil.notify（services.notify 缺失或文本为空时忽略）。
PlatformShopBehavior.notify = ViewUtil.notify

--- 按当前可买动作刷新商品按钮的可见与可用状态。
---@param self PlatformShopPanelHandle
function PlatformShopBehavior.refresh_buttons(self)
  local actions = self.actions
  local awaiting = self.awaiting
  for key, button in pairs(self.buttons) do
    button.Visible = actions[key] ~= nil and not awaiting
    button.TouchEnabled = actions[key] ~= nil and not awaiting
    button.Disabled = awaiting
  end
end

--- 商品按钮：按该商品当前的 action 发一次上行。
---@param self PlatformShopPanelHandle
---@param offer_key string
function PlatformShopBehavior.send_action(self, offer_key)
  local action = self.actions[offer_key]
  if not action or self.awaiting then return end
  self.seq = self.seq + 1
  self.request_seq = self.seq
  self.awaiting = true
  self:refresh_buttons()
  local services = self.services
  if type(services.send_platform) == "function" then
    services.send_platform({ action = action, goods = offer_key, seq = self.seq })
  end
end

--- 商店可买：按回包的可买清单重建动作表与结果行。
---@param self PlatformShopPanelHandle
---@param result table 商店回包
local function apply_shop_offers(self, result)
  self.awaiting = false
  for key in pairs(self.buttons) do self.actions[key] = nil end
  for _, offer in ipairs(result.offers or {}) do
    ---@type table|userdata|nil
    local button = self.buttons[offer.key]
    if button then
      self.actions[offer.key] = result.action == "CoinShop" and "BuyCoin" or "Purchase"
      Modal.set_button_text(button, string.format("%s（%s）", offer.name or offer.key,
        tostring(offer.price or offer.beans or 0)))
    end
  end
  self.result_label.Text = result.notice or "请选择商品"
end

--- 购买成功：结果行与溢出提示。
---@param self PlatformShopPanelHandle
---@param result table 商店回包
local function apply_grant_result(self, result)
  self.awaiting = false
  self.result_label.Text = string.format("购买成功：%s", tostring(result.goods))
  if (result.overflow or 0) > 0 then
    self.result_label.Text = self.result_label.Text .. string.format("；%d 件落在面前地上", result.overflow)
    self:notify(result.deliveryPending and "商品已记录，落地交付待恢复" or "背包已满，溢出商品落在面前地上")
  end
end

--- 商店失败：等待态与原因文本。
---@param self PlatformShopPanelHandle
---@param result table 商店回包
local function apply_failed_result(self, result)
  self.awaiting = result.deliveryPending == true or result.reason == "unknown"
  self.result_label.Text = result.text or GameCfg.Platform.ReasonText[result.reason]
    or GameCfg.Platform.UnavailableText
  self:notify(self.result_label.Text)
end

--- 商店回包投影：序号去重、按 action 更新可买表与结果行。
---@param self PlatformShopPanelHandle
---@param es table EffectScope
function PlatformShopBehavior.on_result_projection(self, es)
  local result = es:d(self.ctx.store.platform_result)
  if type(result) ~= "table" then return end
  if self.awaiting and result.seq and self.request_seq and result.seq ~= self.request_seq then return end
  if (result.action == "CoinShop" or result.action == "AdrenalineShop") and result.ok then
    apply_shop_offers(self, result)
  elseif result.action == "CoinGrant" and result.ok then
    self.awaiting = false
    self.result_label.Text = string.format("金币 +%d", result.coin or 0)
  elseif result.action == "Grant" and result.ok then
    apply_grant_result(self, result)
  elseif not result.ok then
    apply_failed_result(self, result)
  end
  self:refresh_buttons()
end

--- 挂载地图商店：造句柄、建节点、接回包投影与帧订阅。
---@param scope table
---@param ctx table
local function mount(scope, ctx)
  ---@type PlatformShopPanelHandle
  return ViewUtil.mount_panel(scope, ctx, PlatformShopBehavior, {
    seq = 0, request_seq = nil, awaiting = false, buttons = {}, actions = {},
    panel = nil, result_label = nil,
  }, { name = "PlatformResultProjection", method = "on_result_projection" })
end

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
  return mount
end

return PlatformShopView
