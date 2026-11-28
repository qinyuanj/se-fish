-- 唯一坐标系排版器（归属 L3 client.ui）：
-- 统一 EUI 原生坐标语义：
--   - 画布原点在左下角，X 向右为正，Y 向上为正；
--   - 节点默认 Anchor = (0.5, 0.5)，Position 始终表示节点中心点；
--   - 子节点 Position 相对父节点左下角原点（不是父节点中心）。
-- 所有矩形表统一形态为 { x, y, w, h }（中心点 + 宽高）。

local Tokens = require("client.ui.tokens")

local Layout = {}

--- 对齐到 4px 栅格（四舍五入，保留至少 min_val）。
---@param value number
---@param min_val number|nil
---@return number
function Layout.snap4(value, min_val)
  local snapped = math.floor((tonumber(value) or 0) / 4 + 0.5) * 4
  if min_val ~= nil and snapped < min_val then
    return min_val
  end
  return snapped
end

--- 构造中心点矩形。
---@param x number
---@param y number
---@param w number
---@param h number
---@return { x: number, y: number, w: number, h: number }
function Layout.rect(x, y, w, h)
  return { x = x, y = y, w = w, h = h }
end

--- 返回矩形四条边：left, right, bottom, top。
---@param r { x: number, y: number, w: number, h: number }
---@return number, number, number, number
function Layout.edges(r)
  local hw, hh = r.w / 2, r.h / 2
  return r.x - hw, r.x + hw, r.y - hh, r.y + hh
end

--- 从四条边构造中心点矩形。
---@param left number
---@param right number
---@param bottom number
---@param top number
---@return { x: number, y: number, w: number, h: number }
function Layout.from_edges(left, right, bottom, top)
  return Layout.rect((left + right) / 2, (bottom + top) / 2, right - left, top - bottom)
end

--- AABB 重叠检测（带 0.5px 浮点容差）。
---@param a { x: number, y: number, w: number, h: number }
---@param b { x: number, y: number, w: number, h: number }
---@param eps number|nil
---@return boolean
function Layout.overlaps(a, b, eps)
  local e = eps or 0.5
  local al, ar, ab, at = Layout.edges(a)
  local bl, br, bb, bt = Layout.edges(b)
  return al < br - e and bl < ar - e and ab < bt - e and bb < at - e
end

--- 判断 inner 是否完全在 outer 内（带 0.5px 容差）。
---@param inner { x: number, y: number, w: number, h: number }
---@param outer { x: number, y: number, w: number, h: number }
---@param eps number|nil
---@return boolean
function Layout.inside(inner, outer, eps)
  local e = eps or 0.5
  local il, ir, ib, it = Layout.edges(inner)
  local ol, orr, ob, ot = Layout.edges(outer)
  return il >= ol - e and ir <= orr + e and ib >= ob - e and it <= ot + e
end

--- 在父容器 (parent_w, parent_h) 内居中放置尺寸 (w, h)。
---@param parent_w number
---@param parent_h number
---@param w number
---@param h number
---@return { x: number, y: number, w: number, h: number }
function Layout.center_in(parent_w, parent_h, w, h)
  return Layout.rect(parent_w / 2, parent_h / 2, w, h)
end

--- 在父容器内按「距左边 left、距顶边 top」计算 EUI 中心点矩形（Y-up 自动翻转）。
---@param parent_h number 父容器高度（必填，杜绝错读）
---@param left number 距父左边缘像素
---@param top number 距父顶边缘像素
---@param w number
---@param h number
---@return { x: number, y: number, w: number, h: number }
function Layout.from_top_left(parent_h, left, top, w, h)
  return Layout.rect(left + w / 2, parent_h - top - h / 2, w, h)
end

--- 在父容器内按「距右边 right、距顶边 top」计算 EUI 中心点矩形。
---@param parent_w number
---@param parent_h number
---@param right number 距父右边缘像素
---@param top number 距父顶边缘像素
---@param w number
---@param h number
---@return { x: number, y: number, w: number, h: number }
function Layout.from_top_right(parent_w, parent_h, right, top, w, h)
  return Layout.rect(parent_w - right - w / 2, parent_h - top - h / 2, w, h)
end

--- 在父容器内按「距左边 left、距底边 bottom」计算 EUI 中心点矩形。
---@param left number
---@param bottom number
---@param w number
---@param h number
---@return { x: number, y: number, w: number, h: number }
function Layout.from_bottom_left(left, bottom, w, h)
  return Layout.rect(left + w / 2, bottom + h / 2, w, h)
end

--- 在父容器内水平居中、距顶边 top。
---@param parent_w number
---@param parent_h number
---@param top number
---@param w number
---@param h number
---@return { x: number, y: number, w: number, h: number }
function Layout.top_center(parent_w, parent_h, top, w, h)
  return Layout.rect(parent_w / 2, parent_h - top - h / 2, w, h)
end

--- 在父容器内水平居中、距底边 bottom。
---@param parent_w number
---@param bottom number
---@param w number
---@param h number
---@return { x: number, y: number, w: number, h: number }
function Layout.bottom_center(parent_w, bottom, w, h)
  return Layout.rect(parent_w / 2, bottom + h / 2, w, h)
end

--- 网格单元格定位（1-based index，行主序自上而下、从左到右）。
---@param parent_h number
---@param origin_left number
---@param origin_top number
---@param cols number
---@param index number
---@param cell_w number
---@param cell_h number
---@param gap_x number
---@param gap_y number
---@return { x: number, y: number, w: number, h: number }
function Layout.grid_cell(parent_h, origin_left, origin_top, cols, index, cell_w, cell_h, gap_x, gap_y)
  local col = (index - 1) % cols
  local row = math.floor((index - 1) / cols)
  local left = origin_left + col * (cell_w + gap_x)
  local top = origin_top + row * (cell_h + gap_y)
  return Layout.from_top_left(parent_h, left, top, cell_w, cell_h)
end

--- 水平均分按钮行（居中排布 count 个按钮）。
---@param parent_w number
---@param y_center number
---@param count number
---@param btn_w number
---@param btn_h number
---@param gap number
---@return table[]
function Layout.centered_row(parent_w, y_center, count, btn_w, btn_h, gap)
  local total_w = count * btn_w + math.max(0, count - 1) * gap
  local start_left = (parent_w - total_w) / 2
  local rects = {}
  for i = 1, count do
    local left = start_left + (i - 1) * (btn_w + gap)
    rects[i] = Layout.rect(left + btn_w / 2, y_center, btn_w, btn_h)
  end
  return rects
end

--- 把矩形应用到 EUI 节点（同时同步按钮内部托管的子标签，保持零错位）。
---@param node any
---@param r { x: number, y: number, w: number, h: number }
---@return any
function Layout.apply(node, r)
  if node == nil or r == nil then
    return node
  end
  node.Position = Tokens.vec2(r.x, r.y)
  node.Size = Tokens.vec2(r.w, r.h)
  local ok_find, sub = pcall(function()
    return node.FindFirstChild and node:FindFirstChild("LabelButtonText", false) or nil
  end) -- 兼容测试替身与引擎节点
  if ok_find and sub ~= nil then
    local pad_x = r.w >= 48 and 8 or 4
    local pad_y = r.h >= 32 and 4 or 0
    sub.Position = Tokens.vec2(r.w / 2, r.h / 2)
    sub.Size = Tokens.vec2(math.max(4, r.w - pad_x * 2), math.max(4, r.h - pad_y * 2))
  end
  return node
end

return Layout
