--- HUD 通用节点构造器（L4 client.views，委托 L3 client.ui 统一原语层）。
--- 保持常驻 HUD 各视图简洁构造入口，并严格遵守圆体、4px 栅格、零 ButtonText 双重重影与触控穿透约定。
local Tokens = require("client.ui.tokens")
local Layout = require("client.ui.layout")
local Primitives = require("client.ui.primitives")
local ViewUtil = require("client.views.view_util")

local HudWidgets = {}

--- 标签默认层级；按全局 Z-Layer 分层表取值。
HudWidgets.DEFAULT_Z_ORDER = Tokens.Z.HUD_CONTENT

--- 按钮默认底色（深海蓝半透明 HUD 槽位风格）；特例用 spec.normal / spec.press 覆盖。
HudWidgets.BUTTON_COLORS = {
  NORMAL = Tokens.COLOR.HUD_SLOT,
  PRESS = Tokens.COLOR.HUD_SLOT_PRESS,
  DISABLED = Tokens.COLOR.DISABLED,
}

local BUTTON_IMAGE = Tokens.ASSET.SLOT_WOOD_BG

--- 静态展示节点不接收触摸，避免挡住下面的按钮。
function HudWidgets.passive(node)
  return Primitives.passive(node)
end

--- 按中心点矩形摆放节点的位置与尺寸（同步刷新按钮内子 LabelButtonText 尺寸）。
---@param node any
---@param rect any { x, y, w, h }
function HudWidgets.place(node, rect)
  Layout.apply(node, rect)
end

--- HUD 按钮（方案 A：默认采用海岛实木物品格 11089，严禁写 ButtonText，文字独立于同级高 ZOrder 标签）。
---@param ctx table RootView 上下文
---@param scope table EffectBuilder
---@param spec table { name, x, y, w, h, parent?, image?, normal?, press?, disabled?, touch?, swallow?, visible?, z_order? }
---@return table button
function HudWidgets.button(ctx, scope, spec)
  local img = spec.image or BUTTON_IMAGE
  local btn = ctx.create_node(scope, "EUIButton", {
    Name = spec.name,
    Parent = spec.parent or ctx.root_node,
    Position = Tokens.vec2(spec.x, spec.y),
    Size = Tokens.vec2(spec.w, spec.h),
    ButtonText = "",
    NormalImage = img,
    PressImage = img,
    DisableImage = img,
  })
  btn.TouchEnabled = spec.touch ~= false
  btn.SwallowTouchEnabled = spec.swallow ~= false
  btn.ButtonText = ""
  btn.NormalImage = img
  btn.PressImage = img
  btn.DisableImage = img
  local normal = spec.normal or HudWidgets.BUTTON_COLORS.NORMAL
  local press = spec.press or HudWidgets.BUTTON_COLORS.PRESS
  local disable = spec.disabled or HudWidgets.BUTTON_COLORS.DISABLED
  btn.ButtonNormalColor = ViewUtil.color(normal)
  btn.ButtonPressColor = ViewUtil.color(press)
  btn.ButtonDisableColor = ViewUtil.color(disable)
  if spec.visible ~= nil then
    btn.Visible = spec.visible
  end
  btn.LocalZOrder = spec.z_order or Tokens.Z.HUD_CONTENT
  return btn
end

--- HUD 标签（委托 Primitives.label，默认圆体白字 + 轻量描边 + 禁用阴影与触控）。
---@param ctx table RootView 上下文
---@param scope table EffectBuilder
---@param spec table { name, x, y, w, h, parent?, text?, font_size?, bold?, text_color?, outline?, outline_color?, align_x?, align_y?, z_order?, visible? }
---@return table label
function HudWidgets.label(ctx, scope, spec)
  return Primitives.label(scope, ctx, {
    name = spec.name,
    parent = spec.parent,
    rect = Layout.rect(spec.x, spec.y, spec.w, spec.h),
    text = spec.text,
    font_size = spec.font_size or Tokens.FONT_SIZE.CAPTION,
    bold = spec.bold ~= false,
    color = spec.text_color or Tokens.COLOR.WHITE,
    outline = spec.outline ~= false,
    outline_color = spec.outline_color or Tokens.COLOR.OUTLINE_DARK,
    align_x = spec.align_x ~= nil and spec.align_x or 1,
    align_y = spec.align_y ~= nil and spec.align_y or 1,
    z_order = spec.z_order or HudWidgets.DEFAULT_Z_ORDER,
    visible = spec.visible,
  })
end

return HudWidgets
