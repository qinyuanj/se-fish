-- 互斥弹窗薄适配层（归属 L2 client.views）：
-- 统一收口到 client/ui/{tokens,layout,primitives,controls}.lua，
-- 强制按钮单源子 LabelButtonText（零 ButtonText 双字重影）与 3A 明亮奶白风弹窗壳。

local Tokens = require("client.ui.tokens")
local Layout = require("client.ui.layout")
local Primitives = require("client.ui.primitives")
local Controls = require("client.ui.controls")
local ViewUtil = require("client.views.view_util")

local EconomyModal = {}

local DEFAULT_PANEL_W = 928
local DEFAULT_PANEL_H = 640

EconomyModal.PANEL_W = DEFAULT_PANEL_W
EconomyModal.PANEL_H = DEFAULT_PANEL_H
EconomyModal.BUTTON_LABEL_NAME = Controls.BUTTON_LABEL_NAME
EconomyModal.color = ViewUtil.color

---@param node table|userdata
---@param key string
---@return any
local function read_field(node, key)
  local ok, value = pcall(function() return node[key] end) -- 兼容引擎 userdata 字段读取，异常视为缺失
  if not ok then
    return nil
  end
  return value
end

local function read_height(size)
  if type(size) ~= "table" and type(size) ~= "userdata" then
    return nil
  end
  local y = read_field(size, "y")
  if y == nil then
    y = read_field(size, "Y")
  end
  return type(y) == "number" and y > 0 and y or nil
end

--- 入参 (x, y, w, h) 按父节点左上角语义；通过 Layout 统一转为 EUI Y-up 中心坐标并同步子标签。
---@param node any
---@param x number
---@param y number
---@param w number
---@param h number
---@param parent_h number|nil
---@return any
function EconomyModal.place(node, x, y, w, h, parent_h)
  local ph = parent_h
  if type(ph) ~= "number" then
    local parent = read_field(node, "Parent")
    ph = read_height(parent and read_field(parent, "Size") or nil) or DEFAULT_PANEL_H
  end
  return Layout.apply(node, Layout.from_top_left(ph, x, y, w, h))
end

--- 直接套用 Layout 计算好的中心矩形。
---@param node any
---@param rect { x: number, y: number, w: number, h: number }
---@return any
function EconomyModal.apply_rect(node, rect)
  return Layout.apply(node, rect)
end

--- 构造完整模态弹窗壳（14588 半透遮罩 + 浅奶白底板 + 标题 + 可选不撞字关闭按钮）。
---@param scope table
---@param ctx table
---@param opts table
---@return table shell
function EconomyModal.shell(scope, ctx, opts)
  opts = opts or {}
  local name = opts.name or "PanelModal"
  local modal_id = opts.modal_id
  local on_close = opts.on_close
  if on_close == nil and modal_id ~= nil then
    on_close = function()
      EconomyModal.close_modal(ctx, modal_id)
    end
  end
  local derived_title = "Label" .. name:gsub("^Screen", ""):gsub("^Panel", "") .. "Title"
  return Controls.modal_shell(scope, ctx, {
    name = name,
    title = opts.title or "",
    width = opts.width or DEFAULT_PANEL_W,
    height = opts.height or DEFAULT_PANEL_H,
    title_name = opts.title_name or derived_title,
    close_name = opts.close_name,
    show_close = opts.show_close,
    on_close = on_close,
    backdrop_dismiss = opts.backdrop_dismiss,
    theme = opts.theme,
    z_mask = opts.z_mask,
    z_panel = opts.z_panel,
    animate = opts.animate,
    get_resolution = opts.get_resolution,
  })
end

--- 兼容旧签名的模态面板入口：底层使用 Controls.modal_shell，返回 panel 与 shell。
---@param scope table
---@param ctx table
---@param name string
---@param title string
---@param opts table|nil
---@return any, table
function EconomyModal.panel(scope, ctx, name, title, opts)
  local merged = {}
  if type(opts) == "table" then
    for k, v in pairs(opts) do
      merged[k] = v
    end
  end
  merged.name = name
  merged.title = title
  if merged.show_close == nil then
    merged.show_close = merged.close_name ~= nil or merged.modal_id ~= nil or merged.on_close ~= nil
  end
  local shell = EconomyModal.shell(scope, ctx, merged)
  return shell.panel, shell
end

--- 浅色内容卡片/分区底板（默认穿透触控，零黑屏风险）。
---@param scope table
---@param ctx table
---@param parent any
---@param name string
---@param rect { x: number, y: number, w: number, h: number }
---@param opts table|nil
---@return any
function EconomyModal.surface(scope, ctx, parent, name, rect, opts)
  opts = opts or {}
  return Primitives.image(scope, ctx, {
    name = name,
    parent = parent,
    rect = rect,
    image = opts.image or Tokens.ASSET.ROUND_RECT,
    color = opts.color or Tokens.COLOR.MODAL_SURFACE,
    opacity = opts.opacity or Tokens.OPACITY.SOLID,
    stretch = opts.stretch or Tokens.vec4(24, 24, 24, 24),
    z_order = opts.z_order or 1,
    visible = opts.visible,
    touch = false,
    swallow = false,
  })
end

--- 规范化文本标签（圆体、TextColor、无阴影、穿透触控）。
---@param scope table
---@param ctx table
---@param parent any
---@param name string
---@param text string|nil
---@param font_size number|nil
---@param opts table|nil
---@return any
function EconomyModal.label(scope, ctx, parent, name, text, font_size, opts)
  opts = opts or {}
  local rect = opts.rect or Layout.rect(100, 20, 200, 40)
  return Primitives.label(scope, ctx, {
    name = name,
    parent = parent,
    rect = rect,
    text = text or "",
    font_size = font_size or opts.font_size or Tokens.FONT_SIZE.BODY,
    bold = opts.bold,
    color = opts.color or Tokens.COLOR.TEXT_DARK,
    align_x = opts.align_x,
    align_y = opts.align_y,
    outline = opts.outline,
    outline_color = opts.outline_color,
    z_order = opts.z_order or 2,
    visible = opts.visible,
  })
end

--- 设置按钮文本：只写唯一子 LabelButtonText，强制清空原生 ButtonText 防双字重影。
---@param button table|userdata
---@param text string|nil
function EconomyModal.set_button_text(button, text)
  Controls.set_button_text(button, text)
end

--- 切换按钮主题变体（gold/blue/primary/secondary/selected/danger/surface/card/hud/disabled）。
---@param button table|userdata
---@param variant string
function EconomyModal.set_button_style(button, variant)
  Controls.set_button_style(button, variant)
end

--- 设置按钮可用态并同步变体色。
---@param button table|userdata
---@param enabled boolean
---@param active_variant string|nil
function EconomyModal.set_button_enabled(button, enabled, active_variant)
  Controls.set_button_enabled(button, enabled, active_variant)
end

--- 打开模态弹层：宿主未注入 open_modal 时静默跳过。
---@param ctx table RootView 上下文
---@param modal_id string
---@param payload table|nil
function EconomyModal.open_modal(ctx, modal_id, payload)
  local fn = type(ctx) == "table" and ctx.services and ctx.services.open_modal or nil
  if type(fn) == "function" then fn(modal_id, payload) end
end

--- 关闭模态弹层：宿主未注入 close_modal 时静默跳过。
---@param ctx table RootView 上下文
---@param modal_id string
function EconomyModal.close_modal(ctx, modal_id)
  local fn = type(ctx) == "table" and ctx.services and ctx.services.close_modal or nil
  if type(fn) == "function" then fn(modal_id) end
end

--- 规范化按钮（强制 ButtonText="" + 唯一子 LabelButtonText）。
---@param scope table
---@param ctx table
---@param parent any
---@param name string
---@param text string|nil
---@param on_click function|nil
---@param opts table|nil
---@return any, any
function EconomyModal.button(scope, ctx, parent, name, text, on_click, opts)
  opts = opts or {}
  local rect = opts.rect or Layout.rect(64, 24, 128, 48)
  return Controls.button(scope, ctx, {
    name = name,
    parent = parent,
    rect = rect,
    text = text or "",
    variant = opts.variant or "secondary",
    font_size = opts.font_size or Tokens.FONT_SIZE.BODY,
    bold = opts.bold,
    text_color = opts.text_color,
    outline = opts.outline,
    outline_color = opts.outline_color,
    align_x = opts.align_x,
    align_y = opts.align_y,
    z_order = opts.z_order or 2,
    visible = opts.visible,
    touch = opts.touch,
    icon_only = opts.icon_only,
    label_name = opts.label_name,
    on_click = on_click,
  })
end

--- 兼容旧签名：若面板未在 panel() 中内置关闭键，可在右上角补建标准蓝色关闭按钮。
---@param scope table
---@param ctx table
---@param parent any
---@param name string
---@param modal_id string
---@return any
function EconomyModal.close(scope, ctx, parent, name, modal_id)
  local pw = read_field(parent, "Size")
  local parent_w = (type(pw) == "table" or type(pw) == "userdata") and (read_field(pw, "x") or read_field(pw, "X")) or DEFAULT_PANEL_W
  local parent_h = read_height(pw) or DEFAULT_PANEL_H
  local rect = Layout.from_top_right(parent_w, parent_h, Tokens.SPACE.PANEL_PAD, 20, 96, 48)
  local btn = Controls.button(scope, ctx, {
    name = name,
    parent = parent,
    rect = rect,
    text = "关闭",
    variant = "blue",
    font_size = Tokens.FONT_SIZE.BODY,
    z_order = 2,
    on_click = function()
      EconomyModal.close_modal(ctx, modal_id)
    end,
  })
  return btn
end

return EconomyModal
