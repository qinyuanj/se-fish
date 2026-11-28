-- Spoke 主 HUD 右上角 2A 单一紧凑菜单入口与浮层视图（归属 L2 client.views）：
-- 挂载于 RootView 常驻 HUD 槽位，在 MainHudLayout rects.MenuEntry 放单个「菜单」按钮 BtnMenuEntry；
-- 点击切换展开浮层（由 Spoke.State + Phase 驱动）：全屏纯 EUILayout 收起层 + MainHudLayout.menu_items 排布紧凑胶囊浮层；
-- 收纳图鉴、盲盒、地图商店，GameCfg.Debug.Enabled == true 时追加 GM 调试；
-- 点击任一项立即收起菜单再打开目标弹窗；hud_visible == false 或有 modal 打开时自动收起浮层。

local Spoke = require("common.packages.spoke.api")
local GameCfg = require("common.game_cfg")
local MainHudLayout = require("client.main_hud_layout")
local Tokens = require("client.ui.tokens")
local Primitives = require("client.ui.primitives")
local Controls = require("client.ui.controls")
local ViewUtil = require("client.views.view_util")

local State = Spoke.State

local HudMenuView = {}

local function call_service(ctx, name, ...)
  local services = type(ctx) == "table" and ctx.services or nil
  local fn = type(services) == "table" and services[name] or nil
  if type(fn) == "function" then
    fn(...)
  end
end

local function build_menu_entries(ctx, debug_enabled)
  local entries = {
    {
      name = "BtnMenuCompendium",
      text = "图鉴",
      action = function()
        call_service(ctx, "open_modal", "compendium")
        call_service(ctx, "request_compendium")
      end,
    },
    {
      name = "BtnMenuBlindbox",
      text = "盲盒",
      action = function()
        call_service(ctx, "open_modal", "blindbox")
        call_service(ctx, "request_blindbox_state")
      end,
    },
    {
      name = "BtnMenuPlatformShop",
      text = "地图商店",
      action = function()
        call_service(ctx, "open_platform_shop")
      end,
    },
  }
  if debug_enabled then
    entries[#entries + 1] = {
      name = "BtnMenuGM",
      text = "GM 调试",
      action = function()
        call_service(ctx, "open_modal", "gm")
      end,
    }
  end
  return entries
end

--- 挂载右上角单一「菜单」入口按钮与展开态浮层（Spoke.State + Phase）。
---@param s table EffectBuilder
---@param ctx table RootView 上下文 { root_node, store, services, create_node, connect }
---@param options table|nil { get_resolution?, debug_enabled? }
function HudMenuView.mount(s, ctx, options)
  options = options or {}
  local resolution = ViewUtil.get_resolution(ctx, options)
  if resolution == nil then
    return
  end
  local layout = MainHudLayout.compute({
    width = resolution.x,
    height = resolution.y,
    itemBarSlots = GameCfg.Items.ItemBarSlots,
  })
  local entry_rect = layout.rects.MenuEntry
  if entry_rect == nil then
    return
  end

  local menu_open = State.new("HudMenuView.menu_open", false)

  local entry_btn, entry_label = Controls.button(s, ctx, {
    name = "BtnMenuEntry",
    parent = ctx.root_node,
    rect = entry_rect,
    text = "菜单",
    variant = "hud",
    font_size = Tokens.FONT_SIZE.BODY,
    bold = true,
    z_order = Tokens.Z.HUD_CONTENT,
    on_click = function()
      if ctx.store.hud_visible:now() == false or ctx.store.active_modal:now() ~= nil then
        return
      end
      menu_open:set(not menu_open:now())
    end,
  })
  entry_btn.Opacity = Tokens.OPACITY.HUD_SURFACE

  -- 主 HUD 隐藏或任意模态弹窗打开时自动收起菜单，避免关窗后残留弹开。
  s:effect("HudMenuAutoClose", function(es)
    local hud_visible = es:d(ctx.store.hud_visible) ~= false
    local active_modal = es:d(ctx.store.active_modal)
    local open_now = es:d(menu_open) == true

    entry_btn.Visible = hud_visible
    entry_btn.TouchEnabled = hud_visible and active_modal == nil
    if entry_label ~= nil then
      entry_label.Visible = hud_visible
    end
    if (not hud_visible or active_modal ~= nil) and open_now then
      menu_open:set(false)
      return
    end
    entry_btn.LocalZOrder = (hud_visible and open_now) and Tokens.Z.HUD_POPUP_CONTENT or Tokens.Z.HUD_CONTENT
  end)

  local drawer_active = s:memo("HudMenuDrawerActive", function(ms)
    return ms:d(ctx.store.hud_visible) ~= false
      and ms:d(ctx.store.active_modal) == nil
      and ms:d(menu_open) == true
  end)

  s:phase("HudMenuDrawerPhase", drawer_active, function(ps)
    local debug_enabled
    if options.debug_enabled ~= nil then
      debug_enabled = options.debug_enabled == true
    else
      debug_enabled = GameCfg.Debug ~= nil and GameCfg.Debug.Enabled == true
    end
    local items = build_menu_entries(ctx, debug_enabled)
    local drawer_rect, item_rects = MainHudLayout.menu_items(layout, #items)
    if drawer_rect == nil then
      return
    end

    Primitives.dismiss_mask(ps, ctx, {
      name = "HudMenuDismiss",
      width = resolution.x,
      height = resolution.y,
      z_order = Tokens.Z.HUD_POPUP_MASK,
      on_click = function()
        menu_open:set(false)
      end,
    })

    local drawer = Primitives.image(ps, ctx, {
      name = "MenuDrawerPanel",
      parent = ctx.root_node,
      rect = drawer_rect,
      image = Tokens.ASSET.ROUND_RECT,
      color = Tokens.COLOR.HUD_CAPSULE,
      opacity = 0.96,
      stretch = Tokens.vec4(24, 24, 24, 24),
      z_order = Tokens.Z.HUD_POPUP_BG,
      touch = true,
      swallow = true,
    })
    Primitives.tween_fade_in(drawer, 0.96, Tokens.ANIM.FAST)

    for index, item in ipairs(items) do
      local item_rect = item_rects[index]
      if item_rect ~= nil then
        local action = item.action
        Controls.button(ps, ctx, {
          name = item.name,
          parent = ctx.root_node,
          rect = item_rect,
          text = item.text,
          variant = "hud",
          font_size = Tokens.FONT_SIZE.BODY,
          bold = true,
          z_order = Tokens.Z.HUD_POPUP_CONTENT,
          on_click = function()
            menu_open:set(false)
            action()
          end,
        })
      end
    end
  end)
end

--- 返回可供 RootView.mount({ hud = { ... } }) 直接注册的 HUD spec。
---@param options table|nil { get_resolution?, debug_enabled? }
---@return table spec
function HudMenuView.spec(options)
  return ViewUtil.hud_spec("HudMenu", HudMenuView.mount, options)
end

return HudMenuView
