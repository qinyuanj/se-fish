-- Spoke 主 HUD 顶部临时消息胶囊 Toast 视图（归属 L2 client.views）：
-- 位于顶部安全区（MainHudLayout hint_transient 矩形），居中半透明深海蓝胶囊（z = Tokens.Z.TOAST）；
-- 修复旧 LabelMessage 零尺寸停在 (0, 0) 问题，支持自动淡入与显隐，强制穿透触控。

local MainHudLayout = require("client.main_hud_layout")
local Tokens = require("client.ui.tokens")
local Layout = require("client.ui.layout")
local Primitives = require("client.ui.primitives")
local ViewUtil = require("client.views.view_util")

local MessageView = {}

function MessageView.mount(scope, ctx, options)
  options = options or {}
  local resolution = ViewUtil.get_resolution(ctx, options)
    or Primitives.resolution(ctx, options)
    or { x = 1920, y = 1080 }
  local layout = MainHudLayout.compute({
    width = resolution.x,
    height = resolution.y,
    itemBarSlots = 0,
    reeling = false,
  })
  local toast_rect = layout.rects.hint_primary
    or Layout.top_center(resolution.x, resolution.y, 20, 520, 56)

  local toast = Primitives.capsule(scope, ctx, {
    name = "MessageToast",
    parent = ctx.root_node,
    rect = toast_rect,
    color = Tokens.COLOR.TOAST_BG,
    opacity = 0.92,
    z_order = Tokens.Z.TOAST,
    visible = false,
  })

  local label_w = Layout.snap4(toast_rect.w - Tokens.SPACE.XXL * 2, 64)
  local label_h = Layout.snap4(toast_rect.h - Tokens.SPACE.SM, 24)
  local label = Primitives.label(scope, ctx, {
    name = "LabelMessage",
    parent = toast,
    rect = Layout.rect(toast_rect.w / 2, toast_rect.h / 2, label_w, label_h),
    text = "",
    font_size = Tokens.FONT_SIZE.BODY,
    bold = true,
    color = Tokens.COLOR.WHITE,
    outline = true,
    outline_color = Tokens.COLOR.OUTLINE_DARK,
    align_x = 1,
    align_y = 1,
    z_order = 1,
    visible = false,
  })

  local last_shown_text = nil
  scope:effect("MessageProjection", function(es)
    local message = es:d(ctx.store.message)
    local text = type(message) == "table" and message.text or nil
    local visible = type(text) == "string" and text ~= ""
    label.Text = visible and text or ""
    toast.Visible = visible
    label.Visible = visible
    if visible and text ~= last_shown_text then
      last_shown_text = text
      Primitives.tween_fade_in(toast, 0.92, Tokens.ANIM.FAST)
    elseif not visible then
      last_shown_text = nil
    end
  end)
end

function MessageView.spec(options)
  return ViewUtil.hud_spec("Message", MessageView.mount, options)
end

return MessageView
