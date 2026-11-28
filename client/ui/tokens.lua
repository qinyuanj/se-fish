-- 统一 UI Design Token（归属 L3 client.ui，单一真相）：
-- 方案 A（蛋仔原生质感风）：
--   - 彻底告别素面几何图 11081 硬拉，全部采用 SE 官方立体弹窗框架、双态现代/高光按钮、
--     海岛实木物品格、官方血条槽与造型标签；
--   - 所有尺寸、间距与字号严格取 4 的整数倍；
--   - 仅使用内置圆体（YUANTI_BOLD / YUANTI_REGULAR）；
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
  HUD_CAPSULE = 0.88,
  HUD_SURFACE = 0.92,
  SOLID = 1.0,
}

-- 官方已验证资产协议 URI（按蛋仔原生质感体系选型，严禁裸数字或空串）
Tokens.ASSET = {
  -- 基础色块/圆形与遮罩
  BLOCK = "official://image/11017",
  CIRCLE = "official://image/11018",
  MODAL_MASK = "official://image/14588",
  DECOR_LINE = "official://image/15014",
  -- 蛋仔官方立体弹窗框架
  MODAL_SMALL = "official://image/16347",
  MODAL_MEDIUM = "official://image/31003",
  MODAL_COMPACT = "official://image/31007",
  -- 金属高光主辅按钮
  BTN_GOLD = "official://image/10066",
  BTN_BLUE = "official://image/10067",
  -- 现代条纹双态按钮家族（中号 262x126 与小号 186x90）
  BTN_MOD_GOLD = "official://image/10088",
  BTN_MOD_GOLD_PRESS = "official://image/10089",
  BTN_MOD_BLUE = "official://image/10090",
  BTN_MOD_BLUE_PRESS = "official://image/10091",
  BTN_MOD_DISABLED = "official://image/10092",
  BTN_SM_GOLD = "official://image/10093",
  BTN_SM_GOLD_PRESS = "official://image/10094",
  BTN_SM_BLUE = "official://image/10095",
  BTN_SM_BLUE_PRESS = "official://image/10096",
  BTN_SM_DISABLED = "official://image/10097",
  -- 卡通渐变胶囊按钮（HUD / 选中态）
  BTN_PILL_GOLD = "official://image/10049",
  BTN_PILL_GOLD_PRESS = "official://image/10050",
  BTN_PILL_BLUE = "official://image/10047",
  BTN_PILL_BLUE_PRESS = "official://image/10048",
  -- 正圆动作按钮（攻击大圆键等）
  BTN_CIRCLE_GOLD = "official://image/10059",
  BTN_CIRCLE_GOLD_PRESS = "official://image/10060",
  BTN_CIRCLE_BLUE = "official://image/10057",
  BTN_CIRCLE_BLUE_PRESS = "official://image/10058",
  BTN_CIRCLE_DISABLED = "official://image/10072",
  -- 官方独立关闭图标按钮（105x85）
  BTN_CLOSE = "official://image/10011",
  BTN_CLOSE_PRESS = "official://image/10012",
  -- 分类书签按钮
  BTN_TAB_BLUE = "official://image/16345",
  BTN_TAB_GOLD = "official://image/16346",
  -- 海岛实木与金属物品格体系
  SLOT_WOOD_BG = "official://image/11089",
  SLOT_WOOD_FRAME = "official://image/11094",
  SLOT_METAL_BG = "official://image/11090",
  SLOT_METAL_FRAME = "official://image/11086",
  -- 品质底板与卡片
  CARD_WHITE = "official://image/15922",
  CARD_GRAY = "official://image/15931",
  CARD_ORANGE = "official://image/15925",
  CARD_RED = "official://image/15930",
  CARD_SELECTED = "official://image/15376",
  CARD_BLUE = "official://image/31008",
  -- HUD 造型标签与渐变底条
  TAG_DARK_BLUE = "official://image/11140",
  TAG_LIGHT_BLUE = "official://image/11099",
  GRADIENT_H = "official://image/15009",
  -- 进度条与状态图标
  BAR_FILL = "official://image/30007",
  BAR_BG = "official://image/30008",
  BAR_MED_FILL = "official://image/30003",
  BAR_MED_BG = "official://image/30004",
  RING_FILL = "official://image/30013",
  RING_BG = "official://image/30014",
  COIN = "official://image/16878",
  ICON_HEART = "official://image/11007",
  ICON_FOOD = "official://image/11154",
}

-- 4 元素 RGBA 配色表（全部 0~255）
Tokens.COLOR = {
  -- 浅色弹窗底板与表面（原色贴图保持明亮立体质感）
  MODAL_BG = { 255, 255, 255, 255 },
  MODAL_SURFACE = { 248, 246, 240, 255 },
  MODAL_CARD = { 255, 255, 255, 255 },
  MODAL_CARD_ACTIVE = { 255, 244, 214, 255 },
  MODAL_DIVIDER = { 224, 214, 194, 255 },
  -- 浅底深色字（高对比）
  TEXT_DARK = { 48, 52, 64, 255 },
  TEXT_MUTED = { 100, 106, 120, 255 },
  TEXT_GOLD_DARK = { 164, 96, 16, 255 },
  -- 深色/彩色背景白字与强调字
  WHITE = { 255, 255, 255, 255 },
  TEXT_GOLD = { 255, 212, 84, 255 },
  TEXT_SOFT_WHITE = { 236, 242, 248, 255 },
  -- 语义强调色与按压微反馈染色
  GOLD = { 255, 255, 255, 255 },
  GOLD_PRESS = { 232, 224, 208, 255 },
  BLUE = { 255, 255, 255, 255 },
  BLUE_PRESS = { 220, 232, 248, 255 },
  SELECTED = { 255, 228, 152, 255 },
  SELECTED_PRESS = { 244, 208, 120, 255 },
  DANGER = { 228, 76, 76, 255 },
  DANGER_PRESS = { 196, 56, 56, 255 },
  DISABLED = { 216, 220, 226, 255 },
  SURFACE_BTN = { 255, 255, 255, 255 },
  SURFACE_BTN_PRESS = { 236, 240, 248, 255 },
  -- 3D 场景 HUD 配色（实木物品格原色与深海蓝标签）
  HUD_CAPSULE = { 255, 255, 255, 255 },
  HUD_SLOT = { 255, 255, 255, 255 },
  HUD_SLOT_PRESS = { 228, 220, 208, 255 },
  HUD_SLOT_EMPTY = { 212, 204, 192, 255 },
  HUD_BAR_BG = { 255, 255, 255, 255 },
  HEALTH = { 236, 76, 84, 255 },
  HUNGER = { 248, 172, 48, 255 },
  REEL_FILL = { 64, 204, 124, 255 },
  TOAST_BG = { 255, 255, 255, 255 },
  -- 描边色
  OUTLINE_DARK = { 20, 32, 48, 255 },
  OUTLINE_GOLD = { 132, 76, 12, 255 },
  OUTLINE_BLUE = { 20, 68, 128, 255 },
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

--- 构造 Vector4（九宫格 StretchArea）；离线退回 { x, y, z, w }。
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
