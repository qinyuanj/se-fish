-- 统一 UI 底层安全原语（归属 L3 client.ui）：
-- 经实机取证与原型验证确立的硬不变量：
--   1. 全屏透明点击收起层必须用 EUILayout（零图像渲染，杜绝 EUIButton 空图 / Color.a=0 黑屏）；
--   2. 模态半透明遮罩统一用 EUIImage + official://image/14588 + 显式 Opacity（绝不靠 Color.a）；
--   3. 所有 EUITextLabel 只写 TextColor（绝不写 Color），统一内置圆体 Font，显式禁用 ShadowEnabled，
--      纯展示节点强制 TouchEnabled = false, SwallowTouchEnabled = false；
--   4. 面板开关与过渡统一 0.16~0.24s + override = true（在无 Tween 的离线测试环境安全跳过）；
--   5. 方案 A 蛋仔原生质感：根据长宽比自动匹配官方立体底框、品质底板与深蓝造型标签，弃用素面 11081。

local Tokens = require("client.ui.tokens")
local Layout = require("client.ui.layout")

local Primitives = {}

local DEFAULT_STRETCH = {
  [Tokens.ASSET.MODAL_MEDIUM] = { 64, 64, 64, 64 },
  [Tokens.ASSET.MODAL_SMALL] = { 56, 56, 56, 56 },
  [Tokens.ASSET.MODAL_COMPACT] = { 36, 36, 36, 36 },
  [Tokens.ASSET.CARD_WHITE] = { 28, 28, 28, 28 },
  [Tokens.ASSET.CARD_GRAY] = { 28, 28, 28, 28 },
  [Tokens.ASSET.CARD_ORANGE] = { 28, 28, 28, 28 },
  [Tokens.ASSET.CARD_RED] = { 28, 28, 28, 28 },
  [Tokens.ASSET.CARD_SELECTED] = { 24, 24, 24, 24 },
}

local function safe_write(node, key, value)
  if node == nil or value == nil then
    return
  end
  pcall(function() node[key] = value end) -- 兼容离线测试替身缺少部分引擎专属字段
end

local function easing_out_quad()
  local dir = Enums and Enums.EasingDirection and Enums.EasingDirection.Out or nil
  local style = Enums and Enums.EasingStyle and Enums.EasingStyle.Quad or nil
  return dir, style
end

--- 标记节点为纯展示被动节点（绝不抢占摇杆或按钮触控）。
---@param node any
---@return any
function Primitives.passive(node)
  if node == nil then
    return nil
  end
  node.TouchEnabled = false
  node.SwallowTouchEnabled = false
  return node
end

--- 安全淡入动画（0.15~0.25s + override=true）；无 Tween 方法时直接设为目标不透明度。
---@param node any
---@param target_opacity number
---@param duration number|nil
function Primitives.tween_fade_in(node, target_opacity, duration)
  if node == nil then
    return
  end
  local target = target_opacity or Tokens.OPACITY.SOLID
  local dur = duration or Tokens.ANIM.NORMAL
  if type(node.TweenOpacity) == "function" then
    local dir, style = easing_out_quad()
    node.Opacity = 0
    local ok = pcall(function()
      node:TweenOpacity(target, dir, style, dur, true, function()
        pcall(function() node.Opacity = target end)
      end)
    end) -- 引擎 Tween 异常时回退直写目标 Opacity
    if ok then
      return
    end
  end
  node.Opacity = target
end

--- 安全位移过渡（0.15~0.25s + override=true）；无 Tween 方法时直接赋值。
---@param node any
---@param x number
---@param y number
---@param duration number|nil
function Primitives.tween_position(node, x, y, duration)
  if node == nil then
    return
  end
  local pos = Tokens.vec2(x, y)
  local dur = duration or Tokens.ANIM.NORMAL
  if type(node.TweenPosition) == "function" then
    local dir, style = easing_out_quad()
    local ok = pcall(function()
      node:TweenPosition(pos, dir, style, dur, true, function()
        pcall(function() node.Position = pos end)
      end)
    end) -- 引擎 Tween 异常时回退直写目标 Position
    if ok then
      return
    end
  end
  node.Position = pos
end

--- 读回设备分辨率；无有效分辨率返回 nil。
---@param ctx table
---@param options table|nil
---@return { x: number, y: number }|nil
function Primitives.resolution(ctx, options)
  local raw = nil
  if type(options) == "table" and type(options.get_resolution) == "function" then
    local ok, v = pcall(options.get_resolution)
    if ok then raw = v end
  end
  if raw == nil and type(ctx) == "table" and type(ctx.services) == "table" then
    if type(ctx.services.get_device_resolution) == "function" then
      local ok, v = pcall(ctx.services.get_device_resolution)
      if ok then raw = v end
    elseif ctx.services.resolution ~= nil then
      raw = type(ctx.services.resolution) == "function" and ctx.services.resolution() or ctx.services.resolution
    end
  end
  if raw == nil and type(ctx) == "table" and ctx.root_node ~= nil then
    local ok, sz = pcall(function() return ctx.root_node.Size end)
    if ok then raw = sz end
  end
  local src = raw
  if src ~= nil and (type(src) == "table" or type(src) == "userdata") then
    ---@param v table
    local function read_xy(v)
      return v.x or v.X, v.y or v.Y
    end
    local ok, x, y = pcall(read_xy, src)
    if ok and type(x) == "number" and type(y) == "number" and x > 0 and y > 0 then
      return { x = x, y = y }
    end
  end
  return nil
end

--- 无视觉变暗的全屏透明点击收起 / 捕获层（唯一合法实现：纯 EUILayout）。
--- 严禁用 EUIButton 空贴图或 EUIImage Color.a=0 替代！
---@param scope table
---@param ctx table
---@param opts table { name?, width, height, z_order?, swallow?, on_click?, on_touch_ended?, visible? }
---@return any
function Primitives.dismiss_mask(scope, ctx, opts)
  opts = opts or {}
  local w, h = opts.width, opts.height
  local mask = ctx.create_node(scope, "EUILayout", {
    Name = opts.name or "mask_dismiss",
    Parent = opts.parent or ctx.root_node,
    Position = Tokens.vec2(w / 2, h / 2),
    Size = Tokens.vec2(w, h),
    Visible = opts.visible ~= false,
    TouchEnabled = true,
    SwallowTouchEnabled = opts.swallow ~= false,
    LocalZOrder = opts.z_order or Tokens.Z.HUD_POPUP_MASK,
  })
  mask.TouchEnabled = true
  mask.SwallowTouchEnabled = opts.swallow ~= false
  mask.LocalZOrder = opts.z_order or Tokens.Z.HUD_POPUP_MASK
  if type(opts.on_click) == "function" and mask.OnClicked ~= nil then
    ctx.connect(scope, mask.OnClicked, opts.on_click)
  end
  if type(opts.on_touch_ended) == "function" and mask.OnTouchEnded ~= nil then
    ctx.connect(scope, mask.OnTouchEnded, opts.on_touch_ended)
  end
  return mask
end

--- 模态弹窗半透明暗色背景遮罩（统一 official://image/14588 + 显式 Opacity）。
---@param scope table
---@param ctx table
---@param opts table { name?, width, height, opacity?, z_order?, on_dismiss?, animate? }
---@return any
function Primitives.modal_backdrop(scope, ctx, opts)
  opts = opts or {}
  local w, h = opts.width, opts.height
  local opacity = opts.opacity or Tokens.OPACITY.MODAL_MASK
  local mask = ctx.create_node(scope, "EUIImage", {
    Name = opts.name or "mask_modal",
    Parent = opts.parent or ctx.root_node,
    Position = Tokens.vec2(w / 2, h / 2),
    Size = Tokens.vec2(w, h),
    Image = Tokens.ASSET.MODAL_MASK,
    Visible = opts.visible ~= false,
    Opacity = opacity,
    TouchEnabled = true,
    SwallowTouchEnabled = true,
    LocalZOrder = opts.z_order or Tokens.Z.MODAL_MASK,
  })
  mask.Image = Tokens.ASSET.MODAL_MASK
  mask.TouchEnabled = true
  mask.SwallowTouchEnabled = true
  mask.LocalZOrder = opts.z_order or Tokens.Z.MODAL_MASK
  if opts.animate ~= false then
    Primitives.tween_fade_in(mask, opacity, Tokens.ANIM.FAST)
  else
    mask.Opacity = opacity
  end
  if type(opts.on_dismiss) == "function" and mask.OnClicked ~= nil then
    ctx.connect(scope, mask.OnClicked, opts.on_dismiss)
  end
  return mask
end

--- 纯容器（无背景图，用于分组与裁切）。
---@param scope table
---@param ctx table
---@param opts table { name, parent?, rect, z_order?, clipping?, visible?, touch?, swallow? }
---@return any
function Primitives.container(scope, ctx, opts)
  local r = opts.rect
  local node = ctx.create_node(scope, "EUILayout", {
    Name = opts.name,
    Parent = opts.parent or ctx.root_node,
    Position = Tokens.vec2(r.x, r.y),
    Size = Tokens.vec2(r.w, r.h),
    Visible = opts.visible ~= false,
    LocalZOrder = opts.z_order or 0,
  })
  node.TouchEnabled = opts.touch == true
  node.SwallowTouchEnabled = opts.swallow == true
  node.LocalZOrder = opts.z_order or 0
  if opts.clipping ~= nil then
    safe_write(node, "ClippingEnabled", opts.clipping == true)
  end
  return node
end

--- 静态图片 / 官方贴图表面（按素材自动匹配安全九宫格，默认禁止触控，显式 Opacity）。
---@param scope table
---@param ctx table
---@param opts table { name, parent?, rect, image?, color?, opacity?, stretch?, z_order?, visible?, touch?, swallow? }
---@return any
function Primitives.image(scope, ctx, opts)
  local r = opts.rect
  local img = opts.image or Tokens.ASSET.BLOCK
  local node = ctx.create_node(scope, "EUIImage", {
    Name = opts.name,
    Parent = opts.parent or ctx.root_node,
    Position = Tokens.vec2(r.x, r.y),
    Size = Tokens.vec2(r.w, r.h),
    Image = img,
    Visible = opts.visible ~= false,
    Opacity = opts.opacity or Tokens.OPACITY.SOLID,
    LocalZOrder = opts.z_order or 0,
  })
  node.Image = img
  if opts.color ~= nil then
    node.Color = Tokens.color(opts.color)
  end
  node.Opacity = opts.opacity or Tokens.OPACITY.SOLID
  node.TouchEnabled = opts.touch == true
  node.SwallowTouchEnabled = opts.swallow == true
  node.LocalZOrder = opts.z_order or 0
  if opts.stretch ~= nil then
    safe_write(node, "StretchArea", opts.stretch)
  else
    local preset = DEFAULT_STRETCH[img]
    if preset ~= nil then
      safe_write(node, "StretchArea", Tokens.vec4(preset[1], preset[2], preset[3], preset[4]))
    end
  end
  return node
end

--- HUD 造型底条 / 卡片托盘（方案 A：横条用 11140 深蓝造型标签，卡片用 31008 蓝卡，弃用素面 11081）。
---@param scope table
---@param ctx table
---@param opts table { name, parent?, rect, image?, z_order?, opacity?, visible?, color? }
---@return any
function Primitives.capsule(scope, ctx, opts)
  local r = opts.rect
  local is_wide_strip = (r.h > 0) and ((r.w / r.h) >= 2.2)
  local default_img = is_wide_strip and Tokens.ASSET.TAG_DARK_BLUE or Tokens.ASSET.CARD_BLUE
  return Primitives.image(scope, ctx, {
    name = opts.name,
    parent = opts.parent,
    rect = r,
    image = opts.image or default_img,
    color = opts.color or Tokens.COLOR.HUD_CAPSULE,
    opacity = opts.opacity or Tokens.OPACITY.HUD_CAPSULE,
    z_order = opts.z_order or Tokens.Z.HUD_BG,
    visible = opts.visible,
    touch = false,
    swallow = false,
  })
end

--- 规范化文本标签（圆体、TextColor、无阴影、按需轻量描边、强制穿透触控）。
---@param scope table
---@param ctx table
---@param opts table { name, parent?, rect, text?, font_size?, bold?, color?, align_x?, align_y?, outline?, outline_color?, outline_width?, z_order?, visible? }
---@return any
function Primitives.label(scope, ctx, opts)
  local r = opts.rect
  local font_size = Layout.snap4(opts.font_size or Tokens.FONT_SIZE.BODY, Tokens.FONT_SIZE.MICRO)
  local text_color = Tokens.color(opts.color or Tokens.COLOR.TEXT_DARK)
  local node = ctx.create_node(scope, "EUITextLabel", {
    Name = opts.name,
    Parent = opts.parent or ctx.root_node,
    Position = Tokens.vec2(r.x, r.y),
    Size = Tokens.vec2(r.w, r.h),
    Text = opts.text or "",
    FontSize = font_size,
    TextColor = text_color,
    Visible = opts.visible ~= false,
    LocalZOrder = opts.z_order or 0,
  })
  node.FontSize = font_size
  node.TextColor = text_color
  safe_write(node, "Font", Tokens.font(opts.bold == true))
  safe_write(node, "TextHorizontalAlignment", opts.align_x ~= nil and opts.align_x or 1)
  safe_write(node, "TextVerticalAlignment", opts.align_y ~= nil and opts.align_y or 1)
  safe_write(node, "ShadowEnabled", false)
  if opts.outline == true then
    safe_write(node, "OutlineEnabled", true)
    safe_write(node, "OutlineWidth", opts.outline_width or 2)
    safe_write(node, "OutlineColor", Tokens.color(opts.outline_color or Tokens.COLOR.OUTLINE_DARK))
    safe_write(node, "OutlineOpacity", opts.outline_opacity or 0.85)
  else
    safe_write(node, "OutlineEnabled", false)
  end
  node.TouchEnabled = false
  node.SwallowTouchEnabled = false
  node.LocalZOrder = opts.z_order or 0
  return node
end

return Primitives
