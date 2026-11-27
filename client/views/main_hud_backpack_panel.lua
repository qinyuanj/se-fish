-- 主 HUD 背包展开面板行为（#412 从 main_hud_backpack_view 拆出，归属 L2 client.views）：
-- 面板节点、格位 dock、拖拽与选中同步；入口按钮投影与开关信号仍留在视图模块。
-- 配色表由入口与面板共用，随本模块导出；Spoke 运行时由视图模块注入，避免 packages 依赖进本模块。

local GameCfg = require("common.game_cfg")
local Number = require("common.number")
local MainHudLayout = require("client.main_hud_layout")
local ViewUtil = require("client.views.view_util")
local HudWidgets = require("client.views.hud_widgets")

local MainHudBackpackPanel = {}

local BUTTON_IMAGE = "official://image/11017"
local DRAG_THRESHOLD_PX = 10
local SLOT_COLUMNS = 8
local SLOT_STEP_X = 100
local SLOT_STEP_Y = 100
local SLOT_W = 95
local SLOT_H = 90
local SLOT_LABEL_H = 80

local COLORS = {
  WHITE = { 255, 255, 255, 255 },
  NORMAL = { 54, 100, 140, 255 },
  PRESS = { 42, 82, 118, 255 },
  SELECTED = { 36, 130, 94, 255 },
  DISABLED = { 120, 120, 120, 255 },
  SLOT_NORMAL = { 120, 168, 200, 255 },
  SLOT_PRESS = { 96, 142, 174, 255 },
  CLOSE_NORMAL = { 148, 64, 64, 255 },
  CLOSE_PRESS = { 120, 48, 48, 255 },
  PANEL_BG = { 30, 46, 66, 240 },
}
MainHudBackpackPanel.COLORS = COLORS

local make_color = ViewUtil.color

local function clamp_backpack_count(state)
  if type(state) ~= "table" or not Number.is_finite_number(state.backpackCount) then
    return 0
  end
  local n = math.floor(state.backpackCount)
  return math.max(0, math.min(GameCfg.Items.MaxBackpackSlots, n))
end

local function item_display_name(entry)
  if type(entry) ~= "table" or entry.itemId == nil then
    return nil
  end
  local def = GameCfg.Items.Definitions[entry.itemId]
  if def == nil then
    return nil
  end
  local prefix = GameCfg.Items.cook_rate(entry) ~= nil and GameCfg.Grill.CookedPrefix or ""
  return prefix .. def.Name
end

local function has_free_item_bar_slot(state)
  if type(state) ~= "table" then
    return false
  end
  local capacity = Number.is_finite_number(state.slotCount)
    and math.floor(state.slotCount) or GameCfg.Items.ItemBarSlots
  local slots = type(state.slots) == "table" and state.slots or {}
  for i = 1, capacity do
    if slots[i] == nil then
      return true
    end
  end
  return false
end

local function slot_position(panel_rect, index)
  local col = (index - 1) % SLOT_COLUMNS
  local row = math.floor((index - 1) / SLOT_COLUMNS)
  return panel_rect.x - 350 + col * SLOT_STEP_X, panel_rect.y + 200 - row * SLOT_STEP_Y
end

-- 背包面板句柄：面板内的节点、格位 dock 与拖拽态留在面板句柄上，view 指回外层的背包视图；
-- 方法名沿用拆分前的局部函数名。
---@class MainHudBackpackPanelHandle: table<string, any>
---@type MainHudBackpackPanelHandle
local PanelBehavior = {}

-- ---------------------------------------------------------------------------
-- 面板（展开态）方法
-- ---------------------------------------------------------------------------

--- 建面板节点：底板、标题、关闭键、转入按钮，并接上关闭 / 转入的回调。
---@param self MainHudBackpackPanelHandle
function PanelBehavior.create_nodes(self)
  local view = self.view
  local ctx, ps = view.ctx, self.ps
  local cur_layout = view.layout_sig:now()
    or MainHudLayout.from_resolution(view.resolution, ViewUtil.item_bar_slots(ctx.store.item_bar:now(), true))
  local panel_rect = cur_layout.panels.BackpackPanel
  local cx, cy = panel_rect.x, panel_rect.y

  self.panel = HudWidgets.passive(ctx.create_node(ps, "EUIImage", {
    Name = "BackpackPanel",
    Position = Vector2.New(cx, cy),
    Size = Vector2.New(panel_rect.w, panel_rect.h),
    Image = BUTTON_IMAGE,
    Color = make_color(COLORS.PANEL_BG),
  }))
  self.panel.LocalZOrder = 10

  self.title = HudWidgets.label(ctx, ps, {
    name = "BackpackTitle",
    x = cx,
    y = cy + 290,
    w = 700,
    h = 48,
    text = "选择背包物品，再转入道具栏",
    font_size = 28,
    text_color = make_color(COLORS.WHITE),
    z_order = 11,
  })

  local close_x = cx + panel_rect.w / 2 - 54
  local close_y = cy + panel_rect.h / 2 - 36
  self.btn_close = HudWidgets.button(ctx, ps, {
    name = "BtnBackpackClose", x = close_x, y = close_y, w = 84, h = 48,
    normal = COLORS.CLOSE_NORMAL, press = COLORS.CLOSE_PRESS,
  })
  self.btn_close.LocalZOrder = 11
  self.label_close = HudWidgets.label(ctx, ps, {
    name = "LabelBackpackClose",
    x = close_x,
    y = close_y,
    w = 84,
    h = 48,
    text = "关闭",
    font_size = 20,
    text_color = make_color(COLORS.WHITE),
    z_order = 12,
  })
  ctx.connect(ps, self.btn_close.OnClicked, function()
    view:set_backpack_open(false)
  end)

  self.btn_move = HudWidgets.button(ctx, ps, {
    name = "BtnMoveToItemBar", x = cx, y = cy - 310, w = 330, h = 90,
  })
  self.btn_move.LocalZOrder = 11
  self.btn_move.Visible = false
  self.btn_move.TouchEnabled = false
  self.label_move = HudWidgets.label(ctx, ps, {
    name = "LabelMoveToItemBar",
    x = cx,
    y = cy - 310,
    w = 330,
    h = 70,
    text = "转入道具栏",
    font_size = 26,
    text_color = make_color(COLORS.WHITE),
    z_order = 12,
  })
  self.label_move.Visible = false

  ctx.connect(ps, self.btn_move.OnClicked, function()
    self:on_move_clicked()
  end)

  self.slot_dock = ps:dock("BackpackSlots")
end

--- 转入道具栏：选中格有效且道具栏有空位时才发上行。
---@param self MainHudBackpackPanelHandle
function PanelBehavior.on_move_clicked(self)
  local view = self.view
  local idx = view.selected_slot:now()
  local state = view.ctx.store.item_bar:now()
  if idx == nil or type(state) ~= "table" then
    return
  end
  local entry = type(state.backpack) == "table" and state.backpack[idx] or nil
  if item_display_name(entry) == nil or not has_free_item_bar_slot(state) then
    return
  end
  view.send_action("MoveToItemBar", idx)
end

--- 面板卸载：清空格位、命中矩形与拖拽 / 选中态。
---@param self MainHudBackpackPanelHandle
function PanelBehavior.release(self)
  self.slot_entries = {}
  self.view.active_slot_rects = {}
  self.drag_source = nil
  self.drag_handled = nil
  self.view.selected_slot:set(nil)
end

--- 面板排版：底板、标题、关闭键与转入按钮跟着当前布局走。
---@param self MainHudBackpackPanelHandle
---@param p_rect table
function PanelBehavior.place_nodes(self, p_rect)
  HudWidgets.place(self.panel, p_rect)
  self.title.Position = Vector2.New(p_rect.x, p_rect.y + 290)
  local next_close_x = p_rect.x + p_rect.w / 2 - 54
  local next_close_y = p_rect.y + p_rect.h / 2 - 36
  self.btn_close.Position = Vector2.New(next_close_x, next_close_y)
  self.label_close.Position = Vector2.New(next_close_x, next_close_y)
  self.btn_move.Position = Vector2.New(p_rect.x, p_rect.y - 310)
  self.label_move.Position = Vector2.New(p_rect.x, p_rect.y - 310)
end

--- 若当前选中格已越界或变空，自动复位选中状态。
---@param self MainHudBackpackPanelHandle
---@param cur_selected number|nil
---@param count number
---@param backpack table
---@return number|nil
function PanelBehavior.reset_selection(self, cur_selected, count, backpack)
  if cur_selected == nil then
    return nil
  end
  local sel_entry = cur_selected <= count and backpack[cur_selected] or nil
  if item_display_name(sel_entry) == nil then
    self.view.selected_slot:set(nil)
    return nil
  end
  return cur_selected
end

--- 同步单个背包格：记录命中矩形，已有则原地刷新，否则建 State 与 dock Effect。
---@param self MainHudBackpackPanelHandle
---@param slot_index number
---@param p_rect table
---@param backpack table
---@param cur_selected number|nil
---@param seen table
function PanelBehavior.sync_slot(self, slot_index, p_rect, backpack, cur_selected, seen)
  local dock_key = tostring(slot_index)
  seen[dock_key] = true
  local x, y = slot_position(p_rect, slot_index)
  self.view.active_slot_rects[slot_index] = { x = x, y = y, hw = SLOT_W / 2, hh = SLOT_H / 2 }
  local display = item_display_name(backpack[slot_index])
  local slot_data = {
    index = slot_index,
    x = x,
    y = y,
    text = display or "空",
    has_item = display ~= nil,
    selected = cur_selected == slot_index,
  }
  local existing = self.slot_entries[dock_key]
  if existing ~= nil then
    existing.state:set(slot_data)
  else
    local item_state = self.spoke.State.new("BackpackSlotState:" .. dock_key, slot_data)
    self.slot_entries[dock_key] = { state = item_state, index = slot_index }
    self.slot_dock:call(dock_key, self.spoke.Effect.new("BackpackSlotNode:" .. dock_key, function(cs)
      self:mount_slot_node(cs, dock_key, item_state)
    end))
  end
end

--- 按下：有物品的格位记录拖拽起点。
---@param self MainHudBackpackPanelHandle
---@param touch any
---@param item_state table
function PanelBehavior.on_slot_touch_began(self, touch, item_state)
  local ctx = self.view.ctx
  if ctx.store.hud_visible:now() == false then
    return
  end
  local latest = item_state:now()
  if not latest.has_item then
    return
  end
  self.drag_source = {
    container = GameCfg.Items.ContainerId.Backpack,
    index = latest.index,
    began = ViewUtil.read_touch_xy(touch, "BeganPosition"),
  }
end

--- 抬起：越过拖拽阈值且落到别的格位时发 MoveSlot，并标记本次拖拽已处理。
---@param self MainHudBackpackPanelHandle
---@param touch any
---@param item_state table
function PanelBehavior.on_slot_touch_ended(self, touch, item_state)
  local ctx = self.view.ctx
  local source = self.drag_source
  self.drag_source = nil
  if ctx.store.hud_visible:now() == false then
    return
  end
  local latest = item_state:now()
  if source == nil
    or source.container ~= GameCfg.Items.ContainerId.Backpack
    or source.index ~= latest.index then
    return
  end
  local ended = ViewUtil.read_touch_xy(touch, "EndedPosition")
  if ended == nil or source.began == nil then
    return
  end
  if math.abs(ended.x - source.began.x) < DRAG_THRESHOLD_PX
    and math.abs(ended.y - source.began.y) < DRAG_THRESHOLD_PX then
    return
  end
  local target = self.view:slot_at_position(ended)
  if target ~= nil and (target.container ~= source.container or target.index ~= source.index) then
    self.drag_handled = { index = latest.index, valid = true }
    self.view.send_action("MoveSlot", {
      from = source.container,
      index = source.index,
      target = target.container,
      slot = target.index,
    })
  end
end

--- 点击：拖拽刚处理过的那一次点击直接吞掉，其余情况选中该格。
---@param self MainHudBackpackPanelHandle
---@param item_state table
function PanelBehavior.on_slot_clicked(self, item_state)
  local latest = item_state:now()
  local handled = self.drag_handled
  if handled ~= nil and handled.index == latest.index and handled.valid then
    handled.valid = false
    return
  end
  if not latest.has_item then
    return
  end
  self.view.selected_slot:set(latest.index)
end

--- 格位渲染：占位、可点态、选中高亮与文案。
---@param btn table
---@param lbl table
---@param rs table
---@param item_state table
local function render_slot(btn, lbl, rs, item_state)
  local data = rs:d(item_state)
  btn.Position = Vector2.New(data.x, data.y)
  lbl.Position = Vector2.New(data.x, data.y)
  btn.Visible = true
  btn.TouchEnabled = data.has_item == true
  btn.ButtonNormalColor = make_color(
    data.selected and COLORS.SELECTED or COLORS.SLOT_NORMAL
  )
  lbl.Visible = true
  lbl.Text = data.text
end

--- 挂单个背包格：建按钮与文案，接三条交互连接与渲染 Effect。
---@param self MainHudBackpackPanelHandle
---@param cs table
---@param dock_key string
---@param item_state table
function PanelBehavior.mount_slot_node(self, cs, dock_key, item_state)
  local ctx = self.view.ctx
  local init = item_state:now()
  local btn = HudWidgets.button(ctx, cs, {
    name = "BackpackSlot" .. tostring(init.index),
    x = init.x, y = init.y, w = SLOT_W, h = SLOT_H,
    normal = COLORS.SLOT_NORMAL, press = COLORS.SLOT_PRESS,
  })
  btn.LocalZOrder = 11
  local lbl = HudWidgets.label(ctx, cs, {
    name = "BackpackLabel" .. tostring(init.index),
    x = init.x,
    y = init.y,
    w = SLOT_W,
    h = SLOT_LABEL_H,
    text = init.text,
    font_size = 19,
    text_color = make_color(COLORS.WHITE),
    z_order = 12,
  })
  if btn.OnTouchBegan ~= nil and btn.OnTouchEnded ~= nil then
    ctx.connect(cs, btn.OnTouchBegan, function(touch)
      self:on_slot_touch_began(touch, item_state)
    end)

    ctx.connect(cs, btn.OnTouchEnded, function(touch)
      self:on_slot_touch_ended(touch, item_state)
    end)
  end
  ctx.connect(cs, btn.OnClicked, function()
    self:on_slot_clicked(item_state)
  end)
  cs:effect("BackpackSlotRender:" .. dock_key, function(rs)
    render_slot(btn, lbl, rs, item_state)
  end)
end

--- 转入道具栏按钮显示与满格保护。
---@param self MainHudBackpackPanelHandle
---@param cur_selected number|nil
---@param state any
function PanelBehavior.apply_move_projection(self, cur_selected, state)
  local has_selected = cur_selected ~= nil
  self.btn_move.Visible = has_selected
  self.label_move.Visible = has_selected
  if not has_selected then
    self.btn_move.TouchEnabled = false
    self.label_move.Text = "转入道具栏"
  else
    local free = has_free_item_bar_slot(state)
    self.btn_move.TouchEnabled = free
    self.btn_move.ButtonNormalColor = make_color(free and COLORS.NORMAL or COLORS.DISABLED)
    self.label_move.Text = free and "转入道具栏" or "道具栏已满"
  end
end

--- 面板同步体：排版、选中复位、格位增量同步、回收，最后刷转入按钮。
---@param self MainHudBackpackPanelHandle
---@param es table
function PanelBehavior.sync(self, es)
  local view = self.view
  local state = es:d(view.ctx.store.item_bar)
  local layout = es:d(view.layout_sig) or MainHudLayout.from_resolution(view.resolution, ViewUtil.item_bar_slots(state, true))
  local p_rect = layout.panels.BackpackPanel
  local count = clamp_backpack_count(state)
  local backpack = type(state) == "table" and type(state.backpack) == "table" and state.backpack or {}
  local cur_selected = es:d(view.selected_slot)

  self:place_nodes(p_rect)
  cur_selected = self:reset_selection(cur_selected, count, backpack)

  local seen = {}
  for index = 1, count do
    self:sync_slot(index, p_rect, backpack, cur_selected, seen)
  end
  ViewUtil.drop_stale_slots(self, seen, self.view.active_slot_rects)
  self:apply_move_projection(cur_selected, state)
end

--- 造面板句柄：把面板作用域、dock 与拖拽态挂到面板句柄上，view 指回外层视图。
---@param view table
---@param ps table
---@param spoke table Spoke 运行时（Effect / State 构造器）
---@return MainHudBackpackPanelHandle
function MainHudBackpackPanel.new(view, ps, spoke)
  ---@type MainHudBackpackPanelHandle
  local panel = {
    view = view,
    ps = ps,
    spoke = spoke,
    slot_dock = nil,
    slot_entries = {},
    drag_source = nil,
    drag_handled = nil,
  }
  ViewUtil.merge_methods(panel, PanelBehavior)
  return panel
end

return MainHudBackpackPanel
