-- 统一 UI Design Token（归属 L3 client.ui，单一真相）：
-- 遵循 DESIGN.md 与 eggy-se-lua-coding-eui 规范：
--   - 所有尺寸、间距与字号取 4 的整数倍；
--   - 仅使用内置圆体（YUANTI_BOLD / YUANTI_REGULAR）；
--   - 默认蛋仔金蓝主题（弹窗浅白/奶白底板 + 深灰正文 + 金确认/蓝取消 + 14588 半透遮罩；
--     3D 场景叠层 HUD 采用半透明深海蓝胶囊 + 白字 + 轻量描边）；
--   - 全局单调递增 Z-Layer 分层表，杜绝同层 ZOrder 冲突。

local Tokens = {}

-- 4px 栅格间距与安全留白
Tokens.GRID = 4
Tokens.SPACE = {
  XS = 4,
  SM = 8,
  MD = 12,
  LG = 16,
  XL = 20,
  XXL = 24,
  PANEL_PAD = 32,
  SAFE_EDGE = 16,
}

-- 字号阶梯（全部为 4 的整数倍）
Tokens.FONT_SIZE = {
  TITLE = 40,
  SUBTITLE = 32,
  BUTTON = 28,
  BODY = 24,
  CAPTION = 20,
  MICRO = 16,
}

-- 全局 Z-Layer 分层表（所有视图必须引用，禁止手写魔术数字）
Tokens.Z = {
  HUD_BG = 10,
  HUD_CONTENT = 20,
  HUD_ACCENT = 24,
  HUD_FLASH = 30,
  HUD_POPUP_MASK = 40,
  HUD_POPUP_BG = 44,
  HUD_POPUP_CONTENT = 48,
  HUD_POPUP_LABEL = 52,
  BACKPACK_MASK = 60,
  BACKPACK_PANEL = 64,
  BACKPACK_CONTENT = 68,
  BACKPACK_LABEL = 72,
  MODAL_MASK = 100,
  MODAL_PANEL = 110,
  MODAL_CONTENT = 114,
  MODAL_LABEL = 118,
  OVERLAY_MASK = 140,
  OVERLAY_PANEL = 150,
  OVERLAY_CONTENT = 154,
  OVERLAY_LABEL = 158,
  TOAST = 200,
}

-- 面板开关与位置过渡时长（DESIGN.md：0.15~0.25s + override=true）
Tokens.ANIM = {
  FAST = 0.16,
  NORMAL = 0.20,
  SLOW = 0.24,
}

-- 常用不透明度（0~1，与 Color alpha 区分）
Tokens.OPACITY = {
  MODAL_MASK = 0.56,
  OVERLAY_MASK = 0.64,
  HUD_CAPSULE = 0.76,
  HUD_SURFACE = 0.84,
  SOLID = 1.0,
}

-- 官方已验证资产协议 URI（严禁裸数字或空串）
Tokens.ASSET = {
  BLOCK = "official://image/11017",
  CIRCLE = "official://image/11018",
  ROUND_RECT = "official://image/11081",
  MODAL_MASK = "official://image/14588",
  MODAL_SMALL = "official://image/16347",
  MODAL_MEDIUM = "official://image/31003",
  BTN_GOLD = "official://image/10066",
  BTN_BLUE = "official://image/10067",
  BTN_CLOSE = "official://image/10011",
  BAR_FILL = "official://image/30007",
  BAR_BG = "official://image/30008",
  RING_FILL = "official://image/30013",
  RING_BG = "official://image/30014",
  COIN = "official://image/16878",
}

-- 4 元素 RGBA 配色表（全部 0~255）
Tokens.COLOR = {
  -- 浅色弹窗底板与表面（3A 明亮奶白风）
  MODAL_BG = { 255, 250, 238, 255 },
  MODAL_SURFACE = { 244, 238, 224, 255 },
  MODAL_CARD = { 255, 255, 252, 255 },
  MODAL_CARD_ACTIVE = { 255, 240, 200, 255 },
  MODAL_DIVIDER = { 224, 212, 188, 255 },
  -- 浅底深色字（高对比）
  TEXT_DARK = { 48, 52, 64, 255 },
  TEXT_MUTED = { 104, 110, 124, 255 },
  TEXT_GOLD_DARK = { 164, 96, 16, 255 },
  -- 深色/彩色背景白字与强调字
  WHITE = { 255, 255, 255, 255 },
  TEXT_GOLD = { 255, 212, 84, 255 },
  TEXT_SOFT_WHITE = { 236, 242, 248, 255 },
  -- 蛋仔金蓝按钮色（用于色块按钮及三态染色）
  GOLD = { 244, 180, 44, 255 },
  GOLD_PRESS = { 216, 152, 28, 255 },
  BLUE = { 60, 140, 224, 255 },
  BLUE_PRESS = { 42, 112, 192, 255 },
  SELECTED = { 44, 156, 108, 255 },
  SELECTED_PRESS = { 32, 128, 88, 255 },
  DANGER = { 212, 68, 68, 255 },
  DANGER_PRESS = { 176, 48, 48, 255 },
  DISABLED = { 152, 160, 172, 255 },
  SURFACE_BTN = { 228, 222, 208, 255 },
  SURFACE_BTN_PRESS = { 208, 200, 184, 255 },
  -- 3D 场景 HUD 半透明深海蓝胶囊与状态条
  HUD_CAPSULE = { 20, 36, 56, 255 },
  HUD_SLOT = { 36, 68, 100, 255 },
  HUD_SLOT_PRESS = { 26, 52, 80, 255 },
  HUD_BAR_BG = { 16, 28, 44, 255 },
  HEALTH = { 228, 72, 72, 255 },
  HUNGER = { 244, 172, 48, 255 },
  REEL_FILL = { 56, 196, 116, 255 },
  TOAST_BG = { 20, 36, 56, 255 },
  -- 描边色
  OUTLINE_DARK = { 16, 24, 36, 255 },
  OUTLINE_GOLD = { 128, 76, 16, 255 },
  OUTLINE_BLUE = { 20, 64, 116, 255 },
  -- 警告闪烁红边
  STARVE_FLASH = { 228, 52, 52, 255 },
}

-- 统一 4 元素表转引擎 Color；离线无 Color 构造器时返回原表。
---@param rgba table|userdata
---@return any
function Tokens.color(rgba)
  if type(rgba) ~= "table" then
    return rgba
  end
  if Color ~= nil and type(Color.New) == "function" then
    return Color.New(rgba[1], rgba[2], rgba[3], rgba[4] or 255)
  end
  return rgba
end

--- 读取内置圆体字体枚举；离线测试无 Enums 时退回字面量名。
---@param bold boolean|nil
---@return any
function Tokens.font(bold)
  local font_enum = Enums and Enums.TextFontType or nil
  if bold then
    return (font_enum and font_enum.YUANTI_BOLD) or "YUANTI_BOLD"
  end
  return (font_enum and font_enum.YUANTI_REGULAR) or "YUANTI_REGULAR"
end

--- 构造 Vector2；离线无 Vector2 构造器时退回 { x, y }。
---@param x number
---@param y number
---@return any
function Tokens.vec2(x, y)
  if Vector2 ~= nil and type(Vector2.New) == "function" then
    return Vector2.New(x, y)
  end
  return { x = x, y = y }
end

--- 构造 Vector4（九宫格 StretchArea）；离线退回 { l, t, r, b }。
---@param l number
---@param t number
---@param r number
---@param b number
---@return any
function Tokens.vec4(l, t, r, b)
  if Vector4 ~= nil and type(Vector4.New) == "function" then
    return Vector4.New(l, t, r, b)
  end
  return { x = l, y = t, z = r, w = b }
end

-- 需在 RootView 启动时统一隐藏的旧编辑器预置业务画布（绝不销毁，仅隐藏避免黑幕与重名冲突）。
Tokens.LEGACY_PRESET_SCREENS = {
  "ScreenMain",
  "ScreenShop",
  "DialogNoticeConfirm",
  "ScreenMsg",
}

return Tokens
