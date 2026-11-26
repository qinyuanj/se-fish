local EconomyModal = {}

-- 节点写法沿用旧界面层的实测约定：EUI 的 Position 是节点中心，坐标原点在父节点左下角；
-- 纯色块必须给 ColorBlockImage，否则 EUIButton / EUIImage 用自己的圆角贴图，实机是一团白椭圆。
-- 面板若不带底色就是白底白字，玩家既看不见入口也读不到内容。
local ColorBlockImage = "official://image/11017"
local PANEL_BG = { 30, 46, 66, 240 }
local BUTTON_NORMAL = { 54, 100, 140, 255 }
local TEXT = { 240, 245, 250, 255 }
local PANEL_W, PANEL_H = 900, 600
local TITLE_FONT = 30
local LABEL_FONT = 26

local function make_color(rgba)
  if type(Color) ~= "table" or type(Color.New) ~= "function" then
    return nil
  end
  return Color.New(rgba[1], rgba[2], rgba[3], rgba[4])
end

---@param node table|userdata
---@param key string
---@return any
local function read_field(node, key)
  local ok, value = pcall(function() return node[key] end) -- 兼容 Vector2 userdata 字段读取，异常时视为无效
  if not ok then
    return nil
  end
  return value
end

local function read_xy(pos)
  if type(pos) ~= "table" and type(pos) ~= "userdata" then
    return nil
  end
  local x = read_field(pos, "x")
  if x == nil then x = read_field(pos, "X") end
  local y = read_field(pos, "y")
  if y == nil then y = read_field(pos, "Y") end
  if type(x) ~= "number" or type(y) ~= "number" then
    return nil
  end
  return x, y
end

-- Position 是节点中心。根节点 Size 在挂载当帧还没算好，所以优先问设备分辨率服务。
local function panel_center(ctx)
  local services = ctx and ctx.services
  if type(services) == "table" and type(services.get_device_resolution) == "function" then
    local w, h = read_xy(services.get_device_resolution())
    if w and h then
      return w / 2, h / 2
    end
  end
  local w, h = read_xy(ctx and ctx.root_node and ctx.root_node.Size)
  if not w or not h then
    return PANEL_W / 2, PANEL_H / 2
  end
  return w / 2, h / 2
end

-- 入参 (x, y, w, h) 按父节点左上角语义；EUI 实际以父左下为原点、Y 向上、Position 为节点中心。
function EconomyModal.place(node, x, y, w, h, parent_h)
  local ph = parent_h
  if type(ph) ~= "number" then
    local parent = read_field(node, "Parent")
    local _, py = read_xy(parent and read_field(parent, "Size") or nil)
    ph = py or PANEL_H
  end
  node.Position = Vector2.New(x + w / 2, ph - y - h / 2)
  node.Size = Vector2.New(w, h)
  return node
end

function EconomyModal.panel(scope, ctx, name, title)
  local cx, cy = panel_center(ctx)
  local panel = ctx.create_node(scope, "EUIImage", {
    Parent = ctx.root_node, Name = name, Visible = true,
    Position = Vector2.New(cx, cy), Size = Vector2.New(PANEL_W, PANEL_H),
    Image = ColorBlockImage,
  })
  local bg = make_color(PANEL_BG)
  if bg ~= nil then
    panel.Color = bg
  end
  local title_label = EconomyModal.label(scope, ctx, panel, "Label" .. name:gsub("Screen", "") .. "Title", title, TITLE_FONT)
  EconomyModal.place(title_label, 20, 12, 740, 36, PANEL_H)
  return panel
end

function EconomyModal.label(scope, ctx, parent, name, text, font_size)
  local label = ctx.create_node(scope, "EUITextLabel", {
    Parent = parent, Name = name, Text = text or "", Visible = true,
    FontSize = font_size or LABEL_FONT,
  })
  local color = make_color(TEXT)
  if color ~= nil then
    label.TextColor = color
  end
  label.TouchEnabled = false
  label.SwallowTouchEnabled = false
  return label
end

function EconomyModal.button(scope, ctx, parent, name, text, on_click)
  local button = ctx.create_node(scope, "EUIButton", {
    Parent = parent, Name = name, ButtonText = text, Visible = true,
    NormalImage = ColorBlockImage, PressImage = ColorBlockImage,
  })
  button.TouchEnabled = true
  local color = make_color(BUTTON_NORMAL)
  if color ~= nil then
    button.ButtonNormalColor = color
  end
  ctx.connect(scope, button.OnClicked, on_click)
  return button
end

function EconomyModal.close(scope, ctx, parent, name, modal_id)
  local btn = EconomyModal.button(scope, ctx, parent, name, "关闭", function()
    local services = ctx.services or {}
    if type(services.close_modal) == "function" then services.close_modal(modal_id) end
  end)
  return EconomyModal.place(btn, 800, 12, 80, 36, PANEL_H)
end

return EconomyModal
