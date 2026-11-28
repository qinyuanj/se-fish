-- 统一 UI 复合交互控件（归属 L3 client.ui）：
-- 与 client/ui/primitives.lua 同层，封装按钮（单源居中子 LabelButtonText、零双字重影）、
-- 标准模态弹窗壳（14588 半透遮罩 + 浅白底板 + 标题 + 关闭键）与水平胶囊进度条。

local Tokens = require("client.ui.tokens")
local Layout = require("client.ui.layout")
local Primitives = require("client.ui.primitives")

local Controls = {}

local BUTTON_LABEL_NAME = "LabelButtonText"
Controls.BUTTON_LABEL_NAME = BUTTON_LABEL_NAME

-- 按钮外观变体表：统一 3A 蛋仔金蓝体系（弹窗浅白底 + 金主/蓝辅，HUD 深海蓝半透）
local BUTTON_VARIANTS = {
  gold = {
    image = Tokens.ASSET.BTN_GOLD,
    use_stretch = true,
    normal = Tokens.COLOR.WHITE,
    press = { 236, 224, 200, 255 },
    disabled = Tokens.COLOR.DISABLED,
    text_color = Tokens.COLOR.WHITE,
    outline = true,
    outline_color = Tokens.COLOR.OUTLINE_GOLD,
    bold = true,
  },
  blue = {
    image = Tokens.ASSET.BTN_BLUE,
    use_stretch = true,
    normal = Tokens.COLOR.WHITE,
    press = { 220, 232, 248, 255 },
    disabled = Tokens.COLOR.DISABLED,
    text_color = Tokens.COLOR.WHITE,
    outline = true,
    outline_color = Tokens.COLOR.OUTLINE_BLUE,
    bold = true,
  },
  primary = {
    image = Tokens.ASSET.ROUND_RECT,
    use_stretch = true,
    normal = Tokens.COLOR.GOLD,
    press = Tokens.COLOR.GOLD_PRESS,
    disabled = Tokens.COLOR.DISABLED,
    text_color = Tokens.COLOR.WHITE,
    outline = true,
    outline_color = Tokens.COLOR.OUTLINE_GOLD,
    bold = true,
  },
  secondary = {
    image = Tokens.ASSET.ROUND_RECT,
    use_stretch = true,
    normal = Tokens.COLOR.BLUE,
    press = Tokens.COLOR.BLUE_PRESS,
    disabled = Tokens.COLOR.DISABLED,
    text_color = Tokens.COLOR.WHITE,
    outline = true,
    outline_color = Tokens.COLOR.OUTLINE_BLUE,
    bold = true,
  },
  selected = {
    image = Tokens.ASSET.ROUND_RECT,
    use_stretch = true,
    normal = Tokens.COLOR.SELECTED,
    press = Tokens.COLOR.SELECTED_PRESS,
    disabled = Tokens.COLOR.DISABLED,
    text_color = Tokens.COLOR.WHITE,
    outline = true,
    outline_color = Tokens.COLOR.OUTLINE_DARK,
    bold = true,
  },
  danger = {
    image = Tokens.ASSET.ROUND_RECT,
    use_stretch = true,
    normal = Tokens.COLOR.DANGER,
    press = Tokens.COLOR.DANGER_PRESS,
    disabled = Tokens.COLOR.DISABLED,
    text_color = Tokens.COLOR.WHITE,
    outline = true,
    outline_color = Tokens.COLOR.OUTLINE_DARK,
    bold = true,
  },
  surface = {
    image = Tokens.ASSET.ROUND_RECT,
    use_stretch = true,
    normal = Tokens.COLOR.SURFACE_BTN,
    press = Tokens.COLOR.SURFACE_BTN_PRESS,
    disabled = Tokens.COLOR.DISABLED,
    text_color = Tokens.COLOR.TEXT_DARK,
    outline = false,
    bold = false,
  },
  card = {
    image = Tokens.ASSET.ROUND_RECT,
    use_stretch = true,
    normal = Tokens.COLOR.MODAL_CARD,
    press = Tokens.COLOR.MODAL_CARD_ACTIVE,
    disabled = Tokens.COLOR.DISABLED,
    text_color = Tokens.COLOR.TEXT_DARK,
    outline = false,
    bold = false,
  },
  hud = {
    image = Tokens.ASSET.ROUND_RECT,
    use_stretch = true,
    normal = Tokens.COLOR.HUD_SLOT,
    press = Tokens.COLOR.HUD_SLOT_PRESS,
    disabled = Tokens.COLOR.DISABLED,
    text_color = Tokens.COLOR.WHITE,
    outline = true,
    outline_color = Tokens.COLOR.OUTLINE_DARK,
    bold = true,
  },
  disabled = {
    image = Tokens.ASSET.ROUND_RECT,
    use_stretch = true,
    normal = Tokens.COLOR.DISABLED,
    press = Tokens.COLOR.DISABLED,
    disabled = Tokens.COLOR.DISABLED,
    text_color = Tokens.COLOR.WHITE,
    outline = false,
    bold = false,
  },
}

local function safe_write(node, key, value)
  if node == nil or value == nil then
    return
  end
  pcall(function() node[key] = value end) -- 兼容离线测试替身缺少部分引擎专属字段
end

local function find_button_label(button)
  local ok, sub = pcall(function()
    return button.FindFirstChild and button:FindFirstChild(BUTTON_LABEL_NAME, false) or nil
  end)
  return ok and sub or nil
end

--- 套用按钮外观变体（支持运行期切换选中态/禁用态/主辅态）。
---@param button any
---@param variant_name string
function Controls.set_button_style(button, variant_name)
  if button == nil then
    return
  end
  local style = BUTTON_VARIANTS[variant_name] or BUTTON_VARIANTS.secondary
  button.NormalImage = style.image
  button.PressImage = style.image
  button.DisableImage = style.image
  button.ButtonNormalColor = Tokens.color(style.normal)
  button.ButtonPressColor = Tokens.color(style.press)
  button.ButtonDisableColor = Tokens.color(style.disabled)
  if style.use_stretch then
    safe_write(button, "StretchArea", Tokens.vec4(24, 24, 24, 24))
  end
  local sub = find_button_label(button)
  if sub ~= nil then
    sub.TextColor = Tokens.color(style.text_color)
    safe_write(sub, "Font", Tokens.font(style.bold == true))
    if style.outline then
      safe_write(sub, "OutlineEnabled", true)
      safe_write(sub, "OutlineWidth", 2)
      safe_write(sub, "OutlineColor", Tokens.color(style.outline_color or Tokens.COLOR.OUTLINE_DARK))
      safe_write(sub, "OutlineOpacity", 0.85)
    else
      safe_write(sub, "OutlineEnabled", false)
    end
  end
end

--- 设置按钮文本（唯一写子 LabelButtonText，强制清空原生 ButtonText 防重影）。
---@param button any
---@param text string|nil
function Controls.set_button_text(button, text)
  if button == nil then
    return
  end
  button.ButtonText = ""
  local sub = find_button_label(button)
  if sub ~= nil then
    sub.Text = text or ""
  end
end

--- 设置按钮可用态（兼容 #235 引擎 Disabled=true 会关闭 TouchEnabled 的宿主行为）。
---@param button any
---@param enabled boolean
---@param active_variant string|nil
function Controls.set_button_enabled(button, enabled, active_variant)
  if button == nil then
    return
  end
  local is_enabled = enabled == true
  button.Disabled = not is_enabled
  button.TouchEnabled = is_enabled
  if not is_enabled then
    Controls.set_button_style(button, "disabled")
  elseif active_variant ~= nil then
    Controls.set_button_style(button, active_variant)
  end
end

--- 规范化按钮（强制 ButtonText="" + 单源居中子 EUITextLabel，杜绝双字重叠）。
---@param scope table
---@param ctx table
---@param opts table { name, parent?, rect, text?, variant?, font_size?, bold?, text_color?, outline?, z_order?, visible?, touch?, on_click?, label_name? }
---@return any, any
function Controls.button(scope, ctx, opts)
  local r = opts.rect
  local variant_name = opts.variant or "secondary"
  local style = BUTTON_VARIANTS[variant_name] or BUTTON_VARIANTS.secondary
  local btn = ctx.create_node(scope, "EUIButton", {
    Name = opts.name,
    Parent = opts.parent or ctx.root_node,
    Position = Tokens.vec2(r.x, r.y),
    Size = Tokens.vec2(r.w, r.h),
    ButtonText = "",
    NormalImage = style.image,
    PressImage = style.image,
    DisableImage = style.image,
    Visible = opts.visible ~= false,
    TouchEnabled = opts.touch ~= false,
    SwallowTouchEnabled = true,
    LocalZOrder = opts.z_order or 0,
  })
  btn.ButtonText = ""
  btn.TouchEnabled = opts.touch ~= false
  btn.SwallowTouchEnabled = true
  btn.LocalZOrder = opts.z_order or 0
  btn.NormalImage = style.image
  btn.PressImage = style.image
  btn.DisableImage = style.image
  btn.ButtonNormalColor = Tokens.color(style.normal)
  btn.ButtonPressColor = Tokens.color(style.press)
  btn.ButtonDisableColor = Tokens.color(style.disabled)
  if style.use_stretch then
    safe_write(btn, "StretchArea", Tokens.vec4(24, 24, 24, 24))
  end

  local sub_label = nil
  if opts.icon_only ~= true then
    local pad_x = r.w >= 48 and 8 or 4
    local pad_y = r.h >= 32 and 4 or 0
    local sub_rect = Layout.rect(r.w / 2, r.h / 2, math.max(4, r.w - pad_x * 2), math.max(4, r.h - pad_y * 2))
    sub_label = Primitives.label(scope, ctx, {
      name = opts.label_name or BUTTON_LABEL_NAME,
      parent = btn,
      rect = sub_rect,
      text = opts.text or "",
      font_size = opts.font_size or Tokens.FONT_SIZE.BUTTON,
      bold = opts.bold ~= nil and opts.bold or style.bold,
      color = opts.text_color or style.text_color,
      outline = opts.outline ~= nil and opts.outline or style.outline,
      outline_color = opts.outline_color or style.outline_color,
      align_x = opts.align_x ~= nil and opts.align_x or 1,
      align_y = opts.align_y ~= nil and opts.align_y or 1,
      z_order = 1,
      visible = true,
    })
  end

  if type(opts.on_click) == "function" and btn.OnClicked ~= nil then
    ctx.connect(scope, btn.OnClicked, opts.on_click)
  end
  return btn, sub_label
end

--- 标准模态弹窗壳（14588 半透遮罩 + 单层扁平奶白底板 + 标题 + 不撞字的右上关闭按钮 + 0.2s override 淡入）。
---@param scope table
---@param ctx table
---@param opts table { name, title, width?, height?, close_name?, title_name?, on_close?, backdrop_dismiss?, theme?, z_mask?, z_panel? }
---@return table
function Controls.modal_shell(scope, ctx, opts)
  local res = Primitives.resolution(ctx, opts) or { x = 1920, y = 1080 }
  local panel_w = Layout.snap4(opts.width or 928, 320)
  local panel_h = Layout.snap4(opts.height or 640, 240)
  local pad = Tokens.SPACE.PANEL_PAD
  local z_mask = opts.z_mask or Tokens.Z.MODAL_MASK
  local z_panel = opts.z_panel or Tokens.Z.MODAL_PANEL

  local backdrop = Primitives.modal_backdrop(scope, ctx, {
    name = (opts.name or "modal") .. "_backdrop",
    width = res.x,
    height = res.y,
    z_order = z_mask,
    on_dismiss = opts.backdrop_dismiss == true and opts.on_close or nil,
    animate = opts.animate,
  })

  local is_dark = opts.theme == "dark"
  local panel = Primitives.image(scope, ctx, {
    name = opts.name,
    parent = ctx.root_node,
    rect = Layout.center_in(res.x, res.y, panel_w, panel_h),
    image = Tokens.ASSET.ROUND_RECT,
    color = is_dark and Tokens.COLOR.HUD_CAPSULE or Tokens.COLOR.MODAL_BG,
    opacity = is_dark and 0.94 or Tokens.OPACITY.SOLID,
    stretch = Tokens.vec4(32, 32, 32, 32),
    z_order = z_panel,
    touch = true,
    swallow = true,
  })
  if opts.animate ~= false then
    Primitives.tween_fade_in(panel, is_dark and 0.94 or Tokens.OPACITY.SOLID, Tokens.ANIM.NORMAL)
  end

  local close_w, close_h = 96, 48
  local close_btn = nil
  if opts.show_close ~= false then
    local close_rect = Layout.from_top_right(panel_w, panel_h, pad, 20, close_w, close_h)
    close_btn = Controls.button(scope, ctx, {
      name = opts.close_name or "btn_close",
      parent = panel,
      rect = close_rect,
      text = "关闭",
      variant = "blue",
      font_size = Tokens.FONT_SIZE.BODY,
      z_order = 2,
      on_click = opts.on_close,
    })
  end

  local title_w = panel_w - pad * 2 - (close_btn and (close_w + Tokens.SPACE.LG) or 0)
  local title_rect = Layout.from_top_left(panel_h, pad, 20, title_w, 48)
  local title_label = Primitives.label(scope, ctx, {
    name = opts.title_name or "label_title",
    parent = panel,
    rect = title_rect,
    text = opts.title or "",
    font_size = Tokens.FONT_SIZE.SUBTITLE,
    bold = true,
    color = is_dark and Tokens.COLOR.TEXT_GOLD or Tokens.COLOR.TEXT_DARK,
    align_x = 0,
    align_y = 1,
    z_order = 2,
  })

  return {
    backdrop = backdrop,
    panel = panel,
    title_label = title_label,
    close_button = close_btn,
    width = panel_w,
    height = panel_h,
    pad = pad,
    content_top = 20 + 48 + Tokens.SPACE.LG,
  }
end

--- 水平胶囊进度条（底槽 + 填充 + 居中白字轻描边，零嵌套多余外框）。
---@param scope table
---@param ctx table
---@param opts table { name, parent?, rect, fill_color?, bg_color?, percent?, text?, font_size?, z_order?, visible?, opacity? }
---@return table
function Controls.progress_bar(scope, ctx, opts)
  local r = opts.rect
  local bg = Primitives.image(scope, ctx, {
    name = opts.name .. "_bg",
    parent = opts.parent,
    rect = r,
    image = Tokens.ASSET.ROUND_RECT,
    color = opts.bg_color or Tokens.COLOR.HUD_BAR_BG,
    opacity = opts.opacity or Tokens.OPACITY.HUD_SURFACE,
    stretch = Tokens.vec4(12, 12, 12, 12),
    z_order = opts.z_order or Tokens.Z.HUD_BG,
    visible = opts.visible,
  })
  local fill_w = math.max(4, r.w - 8)
  local fill_h = math.max(4, r.h - 8)
  local fill = ctx.create_node(scope, "EUILoadingBar", {
    Name = opts.name,
    Parent = bg,
    Position = Tokens.vec2(r.w / 2, r.h / 2),
    Size = Tokens.vec2(fill_w, fill_h),
    Image = Tokens.ASSET.BAR_FILL,
    Direction = 0,
    Percent = opts.percent or 100,
    Visible = true,
    LocalZOrder = 1,
  })
  fill.Color = Tokens.color(opts.fill_color or Tokens.COLOR.HEALTH)
  fill.TouchEnabled = false
  fill.SwallowTouchEnabled = false
  local lbl = Primitives.label(scope, ctx, {
    name = opts.name .. "_label",
    parent = bg,
    rect = Layout.rect(r.w / 2, r.h / 2, fill_w, fill_h),
    text = opts.text or "",
    font_size = opts.font_size or Tokens.FONT_SIZE.CAPTION,
    bold = true,
    color = Tokens.COLOR.WHITE,
    outline = true,
    outline_color = Tokens.COLOR.OUTLINE_DARK,
    z_order = 2,
  })
  return {
    bg = bg,
    fill = fill,
    label = lbl,
    set_percent = function(pct)
      fill.Percent = math.max(0, math.min(100, tonumber(pct) or 0))
    end,
  }
end

return Controls
