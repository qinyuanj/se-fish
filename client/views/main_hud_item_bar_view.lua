-- Spoke 主 HUD 底部道具栏视图（ADR-0032 / #297-B3b2，归属 L2 client.views）：
-- 挂载于 RootView 常驻 HUD 槽位，订阅只读 ClientStore.item_bar；
-- 通过 Dock 增量管理 ItemBarSlot1..N（随 slotCount 2..8 扩容重排与缩容卸载）；
-- 支持点击选槽（SelectSlot）、拖拽换格（MoveSlot）、爆炸物点按直投/长按瞄准手势（PressGesture + ThrowAimPhase）；
-- 响应 backpack_open 展开遮挡隐藏，重连或根 UI 销毁自动零残留清理全部节点与连接。

local Spoke = require("common.packages.spoke.api")
local GameCfg = require("common.game_cfg")
local Number = require("common.number")
local MainHudLayout = require("client.main_hud_layout")
local PressGesture = require("client.press_gesture")
local ViewUtil = require("client.views.view_util")
local HudWidgets = require("client.views.hud_widgets")

local Effect = Spoke.Effect
local State = Spoke.State

local MainHudItemBarView = {}

local DRAG_THRESHOLD_PX = 10

local COLORS = {
  WHITE = { 255, 255, 255, 255 },
  AMOUNT = { 255, 220, 40, 255 },
  NORMAL = { 54, 100, 140, 255 },
  PRESS = { 42, 82, 118, 255 },
  SELECTED = { 36, 130, 94, 255 },
  DISABLED = { 120, 120, 120, 255 },
  AIM_NORMAL = { 30, 40, 30, 40 },
  AIM_PRESS = { 30, 40, 30, 60 },
}

local function make_color(rgba)
  return Color.New(rgba[1], rgba[2], rgba[3], rgba[4])
end

local function default_resolve_aim_target(pos)
  if pos == nil then
    return nil
  end
  local ok_ray, ray = pcall(function() -- 宿主 CameraService 未就绪或射线转换失败时安全回退无目标直投
    local camera = game ~= nil and game:GetService("CameraService") or nil
    return camera and camera:ScreenPointToRay(pos.x, pos.y, GameCfg.Ability.Throw.Range * 2) or nil
  end)
  if not ok_ray or ray == nil then
    return nil
  end
  local ok_hit, target = pcall(function() -- 宿主 PhysicsService 射线检测失败时安全回退无目标直投
    local origin, direction = ray.Origin, ray.Direction
    if origin == nil or direction == nil then
      return nil
    end
    local physics = game ~= nil and game:GetService("PhysicsService") or nil
    local hit = physics and physics.Raycast and physics:Raycast(origin, direction, nil) or nil
    local p = hit and hit.Position or nil
    if p == nil then
      return nil
    end
    if Number.is_finite_number(p.x) and Number.is_finite_number(p.y) and Number.is_finite_number(p.z) then
      return { x = p.x, y = p.y, z = p.z }
    end
    return nil
  end)
  return ok_hit and target or nil
end

local function clamp_slot_count(state)
  local items = GameCfg.Items
  local raw = (type(state) == "table" and Number.is_finite_number(state.slotCount))
    and math.floor(state.slotCount) or items.InitialItemBarSlots
  return math.max(items.InitialItemBarSlots, math.min(items.ItemBarSlots, raw))
end

local function item_display_name(entry, def)
  if def == nil then
    return ""
  end
  local prefix = GameCfg.Items.cook_rate(entry) ~= nil and GameCfg.Grill.CookedPrefix or ""
  return prefix .. def.Name
end

local function place_slot(nodes, cell)
  local x, y, w, h = cell.x, cell.y, cell.w, cell.h
  nodes.background.Position = Vector2.New(x, y)
  nodes.background.Size = Vector2.New(w, h)
  nodes.icon.Position = Vector2.New(x, y + h * 0.1)
  nodes.icon.Size = Vector2.New(w * 0.6, h * 0.6)
  nodes.label.Position = Vector2.New(x, y - h * 0.34)
  nodes.label.Size = Vector2.New(w, h * 0.28)
  nodes.count.Position = Vector2.New(x + w * 0.33, y + h * 0.33)
  nodes.count.Size = Vector2.New(w * 0.32, h * 0.32)
end

-- 道具栏句柄：格位 dock、拖拽 / 长按手势状态与注入回调都留在句柄上；
-- 方法名沿用拆分前的局部函数名，挂载入口只做装配并返回对外句柄。
---@class MainHudItemBarHandle: table<string, any>
---@type MainHudItemBarHandle
local SlotBehavior = {}

--- 当前时刻（秒）；读取失败返回 nil 并跳过本次手势时间结算。
---@param self MainHudItemBarHandle
---@return number|nil
function SlotBehavior.now_sec(self)
  return ViewUtil.read_now(self.clock_now, "MainHudItemBarView")
  -- 时钟由入口或 options.now_sec 显式注入
  -- 运行期读取失败记日志返回 nil
  -- 跳过本次手势时间结算
  -- 不回退 World:GetServerTime()
  -- 也不再回退 0
  -- 确保多端时钟一致
  -- 避免长按误判
  -- #367 时钟显式注入契约
  -- 保持挂载期报错校验
  -- 校验通过后绑定槽位
end

--- 命中本视图道具栏格位时返回 { container, index }；关屏或未命中返回 nil。
---@param self MainHudItemBarHandle
---@param pos any
---@return table|nil
function SlotBehavior.resolve_own_slot(self, pos)
  if pos == nil or self.ctx.store.hud_visible:now() == false then
    return nil
  end
  return ViewUtil.slot_hit(pos, self.slot_rects, GameCfg.Items.ContainerId.ItemBar)
end

--- 该格当前是否为爆炸物（决定点按直投 / 长按瞄准）。
---@param self MainHudItemBarHandle
---@param index number
---@return boolean
function SlotBehavior.is_explosive_slot(self, index)
  local state = self.ctx.store.item_bar:now()
  local slots = type(state) == "table" and type(state.slots) == "table" and state.slots or nil
  local entry = slots and slots[index] or nil
  local def = entry and GameCfg.Items.Definitions[entry.itemId] or nil
  return def ~= nil and def.Type == "爆炸物"
end

--- 点按直投后紧跟的 OnClicked 只吞一次，避免同一次点按再发 SelectSlot。
---@param self MainHudItemBarHandle
---@param index number
---@return boolean
function SlotBehavior.consume_throw_click(self, index)
  local handled = self.throw_handled
  if handled ~= nil and handled.index == index and handled.valid then
    handled.valid = false
    return true
  end
  return false
end

--- 落点归属：先认本视图格位，再交给外部跨容器解析（与背包共用 ViewUtil.slot_at_position）。
SlotBehavior.slot_at_position = ViewUtil.slot_at_position

--- 默认 ItemBarAction 上行。
---@param action string
---@param value any
local function emit_action(action, value)
  ViewUtil.fire_re("ItemBarAction", { action = action, value = value }, "[MainHudItemBarView]")
end

--- 默认投掷上行：带单调序号，目标可选。
---@param self MainHudItemBarHandle
---@param slot number
---@param target table|nil
function SlotBehavior.emit_throw(self, slot, target)
  self.weapon_seq = self.weapon_seq + 1
  local payload = { action = "throw", slot = slot, seq = self.weapon_seq }
  if type(target) == "table" then
    payload.target = target
  end
  ViewUtil.fire_re("WeaponAction", payload, "[MainHudItemBarView]")
end

--- 把落点解析器交给外部（跨容器拖拽）；卸载时以 nil 收回（实现见 ViewUtil.register_drop_resolver）。
SlotBehavior.register_drop_resolver = ViewUtil.register_drop_resolver

--- 建单个格位节点：底板按钮 + 图标 + 文案 + 数量，全部由当前 dock 作用域托管。
---@param self MainHudItemBarHandle
---@param cs table
---@param init_cell table
---@param index number
---@return table nodes { background, icon, label, count }
function SlotBehavior.create_slot_nodes(self, cs, init_cell, index)
  local ctx = self.ctx
  local background = HudWidgets.button(ctx, cs, {
    name = "ItemBarSlot" .. tostring(index),
    x = init_cell.x, y = init_cell.y, w = init_cell.w, h = init_cell.h,
  })
  background.LocalZOrder = 6

  local icon = HudWidgets.passive(ctx.create_node(cs, "EUIImage", {
    Name = "ItemBarIcon" .. tostring(index),
    Position = Vector2.New(init_cell.x, init_cell.y),
    Size = Vector2.New(init_cell.w * 0.6, init_cell.h * 0.6),
  }))
  icon.LocalZOrder = 7
  icon.Visible = false

  local label = HudWidgets.label(ctx, cs, {
    name = "ItemBarLabel" .. tostring(index),
    x = init_cell.x,
    y = init_cell.y,
    w = init_cell.w,
    h = init_cell.h * 0.28,
    text = "",
    font_size = 18,
    text_color = make_color(COLORS.WHITE),
    z_order = 8,
  })
  label.Visible = false

  local count = HudWidgets.label(ctx, cs, {
    name = "ItemBarAmount" .. tostring(index),
    x = init_cell.x,
    y = init_cell.y,
    w = init_cell.w * 0.32,
    h = init_cell.h * 0.32,
    text = "",
    font_size = 20,
    text_color = make_color(COLORS.AMOUNT),
    z_order = 8,
  })
  count.Visible = false

  return { background = background, icon = icon, label = label, count = count }
end

--- 按下：记录拖拽起点并按长按阈值起手势。
---@param self MainHudItemBarHandle
---@param touch any
---@param slot_index number
function SlotBehavior.on_slot_touch_began(self, touch, slot_index)
  if self.ctx.store.hud_visible:now() == false then return
  end
  local began = ViewUtil.read_touch_xy(touch, "BeganPosition")
  self.drag_source = {
    container = GameCfg.Items.ContainerId.ItemBar,
    index = slot_index,
    began = began,
  }
  local now = self:now_sec(); if now == nil then return end
  local gesture = PressGesture.new({
    long_press_sec = GameCfg.Ability.Throw.LongPressSec,
  })
  gesture:begin(now, began)
  self.slot_press = { index = slot_index, gesture = gesture }
end

--- 拖拽换格判定（支持道具栏内换格及跨容器拖入背包）。
---@param self MainHudItemBarHandle
---@param source table|nil
---@param slot_index number
---@param ended any
function SlotBehavior.apply_drag_drop(self, source, slot_index, ended)
  if source == nil or source.container ~= GameCfg.Items.ContainerId.ItemBar
    or source.index ~= slot_index or ended == nil or source.began == nil then
    return
  end
  if math.abs(ended.x - source.began.x) < DRAG_THRESHOLD_PX
    and math.abs(ended.y - source.began.y) < DRAG_THRESHOLD_PX then
    return
  end
  local target = self:slot_at_position(ended)
  if target ~= nil and (target.container ~= source.container or target.index ~= source.index) then
    self.send_action("MoveSlot", {
      from = source.container,
      index = source.index,
      target = target.container,
      slot = target.index,
    })
  end
end

--- 爆炸物点按 / 长按手势判定：点按直投，长按进瞄准。
---@param self MainHudItemBarHandle
---@param slot_index number
---@param ended any
function SlotBehavior.apply_press_gesture(self, slot_index, ended)
  local press = self.slot_press
  if press == nil or press.index ~= slot_index then
    return
  end
  self.slot_press = nil
  if not self:is_explosive_slot(slot_index) then
    return
  end
  local now = self:now_sec(); if now == nil then return end; local result = press.gesture:finish(now, ended)
  if result == "tap" then
    self.throw_handled = { index = slot_index, valid = true }
    self.send_throw(slot_index, nil)
  elseif result == "long" then
    self.throw_handled = { index = slot_index, valid = true }
    if type(self.on_aim_begin) == "function" then
      self.on_aim_begin(slot_index)
    else
      self.aim_slot:set(slot_index)
    end
  end
end

--- 抬起：先判拖拽换格，再判点按 / 长按投掷。
---@param self MainHudItemBarHandle
---@param touch any
---@param slot_index number
function SlotBehavior.on_slot_touch_ended(self, touch, slot_index)
  local ended = ViewUtil.read_touch_xy(touch, "EndedPosition")

  local source = self.drag_source
  self.drag_source = nil
  if self.ctx.store.hud_visible:now() == false then
    self.slot_press = nil
    return
  end
  self:apply_drag_drop(source, slot_index, ended)
  self:apply_press_gesture(slot_index, ended)
end

--- 点击：直投点按只吞一次，其余情况走选槽。
---@param self MainHudItemBarHandle
---@param slot_index number
function SlotBehavior.on_slot_clicked(self, slot_index)
  if self.ctx.store.hud_visible:now() == false then
    return
  end
  if self:consume_throw_click(slot_index) then
    return
  end
  self.send_action("SelectSlot", slot_index)
end

--- 格位渲染：占位、图标与颜色、文案、数量、选中高亮。
---@param nodes table
---@param rs table
---@param item_state table
local function render_slot(nodes, rs, item_state)
  local data = rs:d(item_state)
  if data.cell ~= nil then
    place_slot(nodes, data.cell)
  end
  local show = data.visible == true
  local show_item = show and data.has_item == true
  nodes.background.Visible = show
  nodes.background.TouchEnabled = show
  nodes.background.ButtonNormalColor = make_color(
    data.selected and COLORS.SELECTED or COLORS.NORMAL
  )
  nodes.icon.Visible = show_item
  if show_item then
    if data.icon ~= nil then
      nodes.icon.Image = data.icon
    end
    if type(data.icon_color) == "table" then
      nodes.icon.Color = make_color(data.icon_color)
    end
  end
  nodes.label.Text = data.label or ""
  nodes.label.Visible = show_item
  nodes.count.Text = data.count_text or ""
  nodes.count.Visible = show_item
end

--- 挂单个格位：建节点、三条交互连接与渲染 Effect。
---@param self MainHudItemBarHandle
---@param cs table
---@param dock_key string
---@param slot_index number
---@param item_state table
function SlotBehavior.mount_slot_node(self, cs, dock_key, slot_index, item_state)
  local ctx = self.ctx
  local init = item_state:now()
  local init_cell = init.cell or { x = 0, y = 0, w = 80, h = 80 }
  local nodes = self:create_slot_nodes(cs, init_cell, init.index)
  local background = nodes.background

  ctx.connect(cs, background.OnTouchBegan, function(touch)
    self:on_slot_touch_began(touch, slot_index)
  end)

  ctx.connect(cs, background.OnTouchEnded, function(touch)
    self:on_slot_touch_ended(touch, slot_index)
  end)

  ctx.connect(cs, background.OnClicked, function()
    self:on_slot_clicked(slot_index)
  end)

  cs:effect("ItemBarSlotRender:" .. dock_key, function(rs)
    render_slot(nodes, rs, item_state)
  end)
end

--- 同步单个格位：记录命中矩形，已有则原地刷新，否则建 State 与 dock Effect。
---@param self MainHudItemBarHandle
---@param slot_index number
---@param layout table
---@param slots table
---@param hud_visible boolean
---@param selected_slot number|nil
---@param seen table
function SlotBehavior.sync_slot(self, slot_index, layout, slots, hud_visible, selected_slot, seen)
  local dock_key = tostring(slot_index)
  seen[dock_key] = true

  local cell = layout.ItemBarSlots[slot_index]
  if cell ~= nil then
    self.slot_rects[slot_index] = { x = cell.x, y = cell.y, hw = cell.w / 2, hh = cell.h / 2 }
  end

  local entry = slots[slot_index]
  ---@type any
  local def = entry ~= nil and GameCfg.Items.Definitions[entry.itemId] or nil
  local slot_data = {
    index = slot_index,
    cell = cell,
    visible = hud_visible,
    selected = selected_slot == slot_index,
    has_item = def ~= nil,
    icon = def ~= nil and def.Icon or nil,
    icon_color = def ~= nil and def.IconColor or nil,
    label = item_display_name(entry, def),
    count_text = def ~= nil and tostring(entry.count) or "",
  }

  local existing = self.slot_entries[dock_key]
  if existing ~= nil then
    existing.state:set(slot_data)
  else
    local item_state = State.new("ItemBarSlotState:" .. dock_key, slot_data)
    self.slot_entries[dock_key] = { state = item_state, index = slot_index }
    self.slot_dock:call(dock_key, Effect.new("ItemBarSlotNode:" .. dock_key, function(cs)
      self:mount_slot_node(cs, dock_key, slot_index, item_state)
    end))
  end
end

--- 关屏或展开背包时收掉拖拽 / 瞄准态，避免越界手势残留。
---@param self MainHudItemBarHandle
---@param hud_visible boolean
---@param bp_open boolean
function SlotBehavior.refresh_aim_state(self, hud_visible, bp_open)
  if not hud_visible then
    self.drag_source = nil
    self.slot_press = nil
    if self.aim_slot:now() ~= nil then
      self.aim_slot:set(nil)
    end
  elseif bp_open and self.aim_slot:now() ~= nil then
    self.aim_slot:set(nil)
  end
end

--- 格位同步体：扩容增量挂载、缩容自动卸载、关屏隐藏；展开背包时保留可见以支持双向拖拽。
---@param self MainHudItemBarHandle
---@param es table
function SlotBehavior.sync_slots(self, es)
  local store = self.ctx.store
  local state = es:d(store.item_bar)
  local hud_visible = es:d(store.hud_visible) ~= false
  local layout = es:d(self.layout_sig) or MainHudLayout.from_resolution(self.resolution, clamp_slot_count(state))
  local bp_open = es:d(self.backpack_open) == true
  local capacity = clamp_slot_count(state)
  local slots = type(state) == "table" and type(state.slots) == "table" and state.slots or {}
  local selected_slot = type(state) == "table" and state.selectedSlot or nil

  self:refresh_aim_state(hud_visible, bp_open)

  local seen = {}
  for index = 1, capacity do
    self:sync_slot(index, layout, slots, hud_visible, selected_slot, seen)
  end
  ViewUtil.drop_stale_slots(self, seen, self.slot_rects)
end

--- 瞄准落点：读当前瞄准格并收起遮罩，命中则投掷。
---@param self MainHudItemBarHandle
---@param touch any
function SlotBehavior.on_aim_touch_ended(self, touch)
  local slot = self.aim_slot:now()
  self.aim_slot:set(nil)
  local ended = ViewUtil.read_touch_xy(touch, "EndedPosition")
  if slot == nil or ended == nil then
    return
  end
  local target = self.resolve_aim_target(ended)
  self.send_throw(slot, target)
end

--- 爆炸物长按瞄准全屏遮罩（选点投掷、背包展开、关屏、重连或根 UI 销毁即零残留销毁）。
---@param self MainHudItemBarHandle
---@param ps table
function SlotBehavior.mount_aim_overlay(self, ps)
  if self.resolution == nil then return end; local w, h = self.resolution.x, self.resolution.y
  local ctx = self.ctx
  local overlay = HudWidgets.button(ctx, ps, {
    name = "ThrowAimOverlay", x = w / 2, y = h / 2, w = w, h = h,
    normal = COLORS.AIM_NORMAL, press = COLORS.AIM_PRESS,
  })
  overlay.NormalImage = ""
  overlay.PressImage = ""
  overlay.DisableImage = ""
  overlay.LocalZOrder = 9

  self.notify("点击屏幕选择投掷落点")

  ctx.connect(ps, overlay.OnTouchEnded, function(touch)
    self:on_aim_touch_ended(touch)
  end)
end

--- 格位同步 Effect 与瞄准 Phase 的活动信号。
---@param self MainHudItemBarHandle
function SlotBehavior.bind_slots_sync(self)
  self.s:effect("ItemBarSlotsSync", function(es) self:sync_slots(es) end)
end

---@param self MainHudItemBarHandle
function SlotBehavior.bind_aim_phase(self)
  local aim_active = self.s:memo("ThrowAimActive", function(ms)
    return ViewUtil.overlay_active(ms, self.ctx.store, self.aim_slot, self.backpack_open)
  end)
  self.s:phase("ThrowAimPhase", aim_active, function(ps)
    self:mount_aim_overlay(ps)
  end)
end

--- 卸载：收回落点解析器、清空格位与手势状态。
---@param self MainHudItemBarHandle
function SlotBehavior.release(self)
  ViewUtil.revoke_drop_resolver(self)
  self.slot_entries = {}
  self.slot_rects = {}
  self.drag_source = nil
  self.slot_press = nil
  self.throw_handled = nil
  self.aim_slot:set(nil)
end

--- 造道具栏句柄：注入回调、状态信号、布局 memo 与格位容器都挂在句柄上。
---@param s table EffectBuilder
---@param ctx table RootView 上下文
---@param options table
---@param resolution table|nil
---@param clock_now fun(): number
---@return MainHudItemBarHandle
local function new_view(s, ctx, options, resolution, clock_now)
  ---@type MainHudItemBarHandle
  local view = {
    s = s,
    ctx = ctx,
    options = options,
    resolution = resolution,
    clock_now = clock_now,
    weapon_seq = 0,
    on_aim_begin = options.on_aim_begin,
    resolve_drop_target = options.resolve_drop_target,
    on_drop_resolver = options.on_drop_resolver,
    resolve_aim_target = options.resolve_aim_target or default_resolve_aim_target,
    backpack_open = options.backpack_open or State.new("MainHudItemBarView.backpack_open", false),
    aim_slot = State.new("MainHudItemBarView.aim_slot", nil),
    slot_dock = nil,
    slot_entries = {},
    slot_rects = {},
    drag_source = nil,
    slot_press = nil,
    throw_handled = nil,
  }
  for name, method in pairs(SlotBehavior) do
    view[name] = method
  end
  view.send_action = options.send_action or function(action, value)
    emit_action(action, value)
  end
  view.send_throw = options.on_throw or function(slot, target)
    view:emit_throw(slot, target)
  end
  view.notify = options.notify or function(text) ViewUtil.notify(ctx, text) end
  view.layout_sig = options.layout or s:memo("ItemBarLayout", function(ms)
    return MainHudLayout.from_resolution(resolution, clamp_slot_count(ms:d(ctx.store.item_bar)))
  end)
  view.resolve_own_slot_fn = function(pos) return view:resolve_own_slot(pos) end
  return view
end

--- 挂载底部道具栏动态格位、拖拽换格与爆炸物长按/点按手势视图。
---@param s table EffectBuilder
---@param ctx table RootView 上下文 { root_node, store, clock, create_node, own_node, connect }
---@param options table|nil { get_resolution?, send_action?, on_throw?, on_aim_begin?, resolve_drop_target?, resolve_aim_target?, notify?, now_sec?, backpack_open?, layout? }
function MainHudItemBarView.mount(s, ctx, options)
  options = options or {}; local clock_now = ViewUtil.resolve_clock(ctx, "MainHudItemBarView", options.now_sec)
  local resolution = ViewUtil.get_resolution(ctx, options); if resolution == nil and options.layout == nil then return end

  local view = new_view(s, ctx, options, resolution, clock_now)
  view.slot_dock = s:dock("ItemBarSlots")
  view:register_drop_resolver()

  s:on_cleanup(function()
    view:release()
  end)

  view:bind_slots_sync()
  view:bind_aim_phase()

  return {
    aim_slot = view.aim_slot,
    backpack_open = view.backpack_open,
    resolve_slot_at = view.resolve_own_slot_fn,
  }
end

--- 返回可供 RootView.mount({ hud = { ... } }) 直接注册的 HUD spec。
function MainHudItemBarView.spec(options)
  return ViewUtil.hud_spec("MainHudItemBar", MainHudItemBarView.mount, options)
end

return MainHudItemBarView
