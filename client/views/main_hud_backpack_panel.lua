-- 主 HUD 背包展开面板行为（3A 明亮奶白底板 + 14588 半透遮罩 + 4px 栅格零重叠，归属 L2 client.views）：
-- 面板节点、格位 dock、拖拽与选中同步；入口按钮投影与开关信号仍留在视图模块。
-- 配色表由入口与面板共用，随本模块导出；Spoke 运行时由视图模块注入，避免 packages 依赖进本模块。

local GameCfg = require("common.game_cfg")
local Number = require("common.number")
local MainHudLayout = require("client.main_hud_layout")
local Tokens = require("client.ui.tokens")
local Layout = require("client.ui.layout")
local Primitives = require("client.ui.primitives")
local Controls = require("client.ui.controls")
local ViewUtil = require("client.views.view_util")
local HudWidgets = require("client.views.hud_widgets")

local MainHudBackpackPanel = {}

local DRAG_THRESHOLD_PX = 10
local PANEL_PAD = Tokens.SPACE.PANEL_PAD
local HEADER_TOP = 20
local HEADER_H = 48
local CLOSE_W, CLOSE_H = 96, 48
local GRID_ORIGIN_LEFT = 36
local GRID_ORIGIN_TOP = 84
local SLOT_COLUMNS = 8
local SLOT_W, SLOT_H = 92, 88
local SLOT_GAP_X, SLOT_GAP_Y = 8, 8
local SLOT_LABEL_H = 76
local MOVE_BTN_W, MOVE_BTN_H, MOVE_BTN_BOTTOM = 320, 64, 32

local COLORS = {
  WHITE = Tokens.COLOR.WHITE,
  TEXT_DARK = Tokens.COLOR.TEXT_DARK,
  TEXT_MUTED = Tokens.COLOR.TEXT_MUTED,
  NORMAL = Tokens.COLOR.HUD_SLOT,
  PRESS = Tokens.COLOR.HUD_SLOT_PRESS,
  SELECTED = Tokens.COLOR.SELECTED,
  DISABLED = Tokens.COLOR.DISABLED,
  SLOT_NORMAL = Tokens.COLOR.MODAL_SURFACE,
  SLOT_ITEM = Tokens.COLOR.MODAL_CARD,
  SLOT_PRESS = Tokens.COLOR.MODAL_CARD_ACTIVE,
  PANEL_BG = Tokens.COLOR.MODAL_BG,
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

--- 把面板局部中心矩形换算为屏幕坐标中心矩形（保持与道具栏同一屏幕坐标系，便于双向拖拽命中）。
---@param p_rect { x: number, y: number, w: number, h: number }
---@param local_r { x: number, y: number, w: number, h: number }
---@return { x: number, y: number, w: number, h: number }
local function to_screen_rect(p_rect, local_r)
  local panel_left, _, panel_bottom = Layout.edges(p_rect)
  return Layout.rect(panel_left + local_r.x, panel_bottom + local_r.y, local_r.w, local_r.h)
end

local function header_rects(p_rect)
  local close_local = Layout.from_top_right(p_rect.w, p_rect.h, PANEL_PAD, HEADER_TOP, CLOSE_W, CLOSE_H)
  local title_w = Layout.snap4(p_rect.w - PANEL_PAD * 2 - CLOSE_W - Tokens.SPACE.LG, 160)
  local title_local = Layout.from_top_left(p_rect.h, PANEL_PAD, HEADER_TOP, title_w, HEADER_H)
  local move_local = Layout.bottom_center(p_rect.w, MOVE_BTN_BOTTOM, MOVE_BTN_W, MOVE_BTN_H)
  return to_screen_rect(p_rect, title_local),
    to_screen_rect(p_rect, close_local),
    to_screen_rect(p_rect, move_local)
end

local function slot_rect(p_rect, index)
  local local_r = Layout.grid_cell(
    p_rect.h,
    GRID_ORIGIN_LEFT,
    GRID_ORIGIN_TOP,
    SLOT_COLUMNS,
    index,
    SLOT_W,
    SLOT_H,
    SLOT_GAP_X,
    SLOT_GAP_Y
  )
  return to_screen_rect(p_rect, local_r)
end

-- 背包面板句柄：面板内的节点、格位 dock 与拖拽态留在面板句柄上，view 指回外层的背包视图；
-- 方法名沿用拆分前的局部函数名。
---@class MainHudBackpackPanelHandle: table<string, any>
---@type MainHudBackpackPanelHandle
local PanelBehavior = {}

-- ---------------------------------------------------------------------------
-- 面板（展开态）方法
-- ---------------------------------------------------------------------------

--- 建面板节点：14588 半透遮罩、3A 奶白底板、隔离排版的标题与关闭键、底部金色转入按钮。
---@param self MainHudBackpackPanelHandle
function PanelBehavior.create_nodes(self)
  local view = self.view
  local ctx, ps = view.ctx, self.ps
  local cur_layout = view.layout_sig:now()
    or MainHudLayout.from_resolution(view.resolution, ViewUtil.item_bar_slots(ctx.store.item_bar:now(), true))
  local panel_rect = cur_layout.panels.BackpackPanel
  local res = view.resolution or Primitives.resolution(ctx) or { x = 1920, y = 1080 }

  self.backdrop = Primitives.modal_backdrop(ps, ctx, {
    name = "BackpackBackdrop",
    width = res.x,
    height = res.y,
    z_order = Tokens.Z.BACKPACK_MASK,
    on_dismiss = function()
      view:set_backpack_open(false)
    end,
  })

  self.panel = Primitives.image(ps, ctx, {
    name = "BackpackPanel",
    parent = ctx.root_node,
    rect = panel_rect,
    image = Tokens.ASSET.ROUND_RECT,
    color = COLORS.PANEL_BG,
    opacity = Tokens.OPACITY.SOLID,
    stretch = Tokens.vec4(32, 32, 32, 32),
    z_order = Tokens.Z.BACKPACK_PANEL,
    touch = true,
    swallow = true,
  })
  self.panel.Color = make_color(COLORS.PANEL_BG)
  Primitives.tween_fade_in(self.panel, Tokens.OPACITY.SOLID, Tokens.ANIM.NORMAL)

  local title_r, close_r, move_r = header_rects(panel_rect)

  self.title = Primitives.label(ps, ctx, {
    name = "BackpackTitle",
    parent = ctx.root_node,
    rect = title_r,
    text = "选择背包物品，再转入道具栏",
    font_size = Tokens.FONT_SIZE.BUTTON,
    bold = true,
    color = COLORS.TEXT_DARK,
    outline = false,
    align_x = 0,
    align_y = 1,
    z_order = Tokens.Z.BACKPACK_CONTENT,
  })

  self.btn_close, self.label_close = Controls.button(ps, ctx, {
    name = "BtnBackpackClose",
    parent = ctx.root_node,
    rect = close_r,
    text = "关闭",
    variant = "blue",
    font_size = Tokens.FONT_SIZE.BODY,
    z_order = Tokens.Z.BACKPACK_CONTENT,
    label_name = "LabelBackpackClose",
    on_click = function()
      view:set_backpack_open(false)
    end,
  })

  self.btn_move, self.label_move = Controls.button(ps, ctx, {
    name = "BtnMoveToItemBar",
    parent = ctx.root_node,
    rect = move_r,
    text = "转入道具栏",
    variant = "gold",
    font_size = Tokens.FONT_SIZE.BUTTON,
    z_order = Tokens.Z.BACKPACK_CONTENT,
    visible = false,
    touch = false,
    label_name = "LabelMoveToItemBar",
    on_click = function()
      self:on_move_clicked()
    end,
  })
  if self.label_move ~= nil then
    self.label_move.Visible = false
  end

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

--- 面板排版：底板、标题、关闭键与转入按钮跟着当前布局走，标题与关闭键严格零重叠。
---@param self MainHudBackpackPanelHandle
---@param p_rect table
function PanelBehavior.place_nodes(self, p_rect)
  local title_r, close_r, move_r = header_rects(p_rect)
  Layout.apply(self.panel, p_rect)
  Layout.apply(self.title, title_r)
  Layout.apply(self.btn_close, close_r)
  Layout.apply(self.btn_move, move_r)
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
  local r = slot_rect(p_rect, slot_index)
  self.view.active_slot_rects[slot_index] = { x = r.x, y = r.y, hw = r.w / 2, hh = r.h / 2 }
  local display = item_display_name(backpack[slot_index])
  local slot_data = {
    index = slot_index,
    x = r.x,
    y = r.y,
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

--- 格位渲染：占位、可点态、浅色卡片 / 选中绿底高对比配色与文案。
---@param btn table
---@param lbl table
---@param rs table
---@param item_state table
local function render_slot(btn, lbl, rs, item_state)
  local data = rs:d(item_state)
  btn.Position = Tokens.vec2(data.x, data.y)
  lbl.Position = Tokens.vec2(data.x, data.y)
  btn.Visible = true
  btn.TouchEnabled = data.has_item == true
  btn.ButtonNormalColor = make_color(
    data.selected and COLORS.SELECTED
      or data.has_item and COLORS.SLOT_ITEM
      or COLORS.SLOT_NORMAL
  )
  lbl.Visible = true
  lbl.Text = data.text
  lbl.TextColor = make_color(
    data.selected and COLORS.WHITE
      or data.has_item and COLORS.TEXT_DARK
      or COLORS.TEXT_MUTED
  )
end

--- 挂单个背包格：建按钮与文案（4px 栅格，零 ButtonText 双字），接三条交互连接与渲染 Effect。
---@param self MainHudBackpackPanelHandle
---@param cs table
---@param dock_key string
---@param item_state table
function PanelBehavior.mount_slot_node(self, cs, dock_key, item_state)
  local ctx = self.view.ctx
  local init = item_state:now()
  local btn = HudWidgets.button(ctx, cs, {
    name = "BackpackSlot" .. tostring(init.index),
    x = init.x,
    y = init.y,
    w = SLOT_W,
    h = SLOT_H,
    normal = COLORS.SLOT_NORMAL,
    press = COLORS.SLOT_PRESS,
    disabled = COLORS.DISABLED,
    z_order = Tokens.Z.BACKPACK_CONTENT,
  })
  local lbl = HudWidgets.label(ctx, cs, {
    name = "BackpackLabel" .. tostring(init.index),
    x = init.x,
    y = init.y,
    w = SLOT_W - Tokens.SPACE.SM,
    h = SLOT_LABEL_H,
    text = init.text,
    font_size = Tokens.FONT_SIZE.CAPTION,
    bold = false,
    outline = false,
    text_color = make_color(COLORS.TEXT_DARK),
    z_order = Tokens.Z.BACKPACK_LABEL,
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
  if self.label_move ~= nil then
    self.label_move.Visible = has_selected
  end
  if not has_selected then
    self.btn_move.TouchEnabled = false
    if self.label_move ~= nil then
      self.label_move.Text = "转入道具栏"
    end
  else
    local free = has_free_item_bar_slot(state)
    Controls.set_button_enabled(self.btn_move, free, "gold")
    if self.label_move ~= nil then
      self.label_move.Text = free and "转入道具栏" or "道具栏已满"
    end
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
