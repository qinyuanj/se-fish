--- HUD 通用节点构造器（L2 client.views）。
--- 常驻 HUD 的五个视图共用同一套标签/按钮排版与点击穿透约定，避免各写一份几乎相同的构造样板。
local HudWidgets = {}

--- 标签默认层级；个别视图（物品栏）按槽位叠放时用 spec.z_order 覆盖。
HudWidgets.DEFAULT_Z_ORDER = 1

--- 按钮默认底色（EUI 蓝金规范）；遮罩、槽位等特例用 spec.normal / spec.press 覆盖。
HudWidgets.BUTTON_COLORS = {
  NORMAL = { 54, 100, 140, 255 },
  PRESS = { 42, 82, 118, 255 },
  DISABLED = { 120, 120, 120, 255 },
}

local BUTTON_IMAGE = "official://image/11017"

--- 静态展示节点不接收触摸，避免挡住下面的按钮。
function HudWidgets.passive(node)
  node.TouchEnabled = false
  node.SwallowTouchEnabled = false
  return node
end

--- 按 MainHudLayout 的中心点矩形摆放节点的位置与尺寸。
--- 节点与矩形都来自动态创建的 EUI 节点/布局表，诊断器推不出形状，按 any 标注避免假阳性。
---@param node any
---@param rect any { x, y, w, h }
function HudWidgets.place(node, rect)
  if node == nil or rect == nil then
    return
  end
  node.Position = Vector2.New(rect.x, rect.y)
  node.Size = Vector2.New(rect.w, rect.h)
end

-- EUIButton 不写 Color：底色只走 ButtonNormalColor / ButtonPressColor / ButtonDisableColor，
-- 文字另置于同级高 ZOrder 的 EUITextLabel（见 HudWidgets.label）。
---@param ctx table RootView 上下文
---@param scope table EffectBuilder
---@param spec table { name, x, y, w, h, normal?, press?, touch?, visible?, z_order? }
---@return table button
function HudWidgets.button(ctx, scope, spec)
  local btn = ctx.create_node(scope, "EUIButton", {
    Name = spec.name,
    Position = Vector2.New(spec.x, spec.y),
    Size = Vector2.New(spec.w, spec.h),
  })
  btn.TouchEnabled = spec.touch ~= false
  btn.ButtonText = ""
  btn.NormalImage = BUTTON_IMAGE
  btn.PressImage = BUTTON_IMAGE
  btn.DisableImage = BUTTON_IMAGE
  local normal = spec.normal or HudWidgets.BUTTON_COLORS.NORMAL
  local press = spec.press or HudWidgets.BUTTON_COLORS.PRESS
  local disable = HudWidgets.BUTTON_COLORS.DISABLED
  btn.ButtonNormalColor = Color.New(normal[1], normal[2], normal[3], normal[4])
  btn.ButtonPressColor = Color.New(press[1], press[2], press[3], press[4])
  btn.ButtonDisableColor = Color.New(disable[1], disable[2], disable[3], disable[4])
  if spec.visible ~= nil then
    btn.Visible = spec.visible
  end
  if spec.z_order ~= nil then
    btn.LocalZOrder = spec.z_order
  end
  return btn
end

---@param ctx table RootView 上下文
---@param scope table EffectBuilder
---@param spec table { name, x, y, w, h, text?, font_size?, text_color?, z_order?, visible? }
---@return table label
function HudWidgets.label(ctx, scope, spec)
  local label = ctx.create_node(scope, "EUITextLabel", {
    Name = spec.name,
    Position = Vector2.New(spec.x, spec.y),
    Size = Vector2.New(spec.w, spec.h),
    Text = spec.text,
    FontSize = spec.font_size,
    TextColor = spec.text_color,
  })
  label.TextHorizontalAlignment = 1
  label.TextVerticalAlignment = 1
  label.TouchEnabled = false
  label.SwallowTouchEnabled = false
  label.LocalZOrder = spec.z_order or HudWidgets.DEFAULT_Z_ORDER
  if spec.visible ~= nil then
    label.Visible = spec.visible
  end
  return label
end

return HudWidgets
