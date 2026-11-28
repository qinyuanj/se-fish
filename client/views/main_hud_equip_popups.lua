-- Spoke 主 HUD 武器栏/鱼饵栏及其展开浮层视图（ADR-0032 / #297-B3a，归属 L2 client.views）：
-- 挂载于 RootView 常驻 HUD 槽位，订阅只读 ClientStore.item_bar；
-- 武器栏与鱼饵栏常驻底部栏位，展开浮层由 Phase + Dock 管理候选格生命周期；
-- 全屏点击收起层严格使用 Primitives.dismiss_mask（纯 EUILayout），根治空图 EUIButton 黑屏。

local Spoke = require("common.packages.spoke.api")
local MainHudLayout = require("client.main_hud_layout")
local Tokens = require("client.ui.tokens")
local Primitives = require("client.ui.primitives")
local ViewUtil = require("client.views.view_util")
local HudWidgets = require("client.views.hud_widgets")
local MainHudEquipCandidates = require("client.views.main_hud_equip_candidates")

local Effect = Spoke.Effect
local State = Spoke.State

local MainHudEquipPopups = {}

local CELL_FONT = Tokens.FONT_SIZE.MICRO

local COLORS = {
  WHITE = Tokens.COLOR.WHITE,
  NORMAL = Tokens.COLOR.HUD_SLOT,
  PRESS = Tokens.COLOR.HUD_SLOT_PRESS,
  SELECTED = Tokens.COLOR.SELECTED,
  DISABLED = Tokens.COLOR.DISABLED,
}

local make_color = ViewUtil.color

local function cell_text(name, count, width)
  local cols = math.max(1, math.floor(width / CELL_FONT))
  local text = ViewUtil.wrap_text(name, cols)
  return count ~= nil and (text .. "\n×" .. tostring(count)) or text
end

-- ---------------------------------------------------------------------------
-- 无状态单元格辅助
-- ---------------------------------------------------------------------------

--- 单元格渲染：占位、折行文案、可用态与选中高亮。
---@param btn table
---@param lbl table
---@param rs table
---@param item_state table
local function render_cell(btn, lbl, rs, item_state)
  local data = rs:d(item_state)
  if data.rect ~= nil then
    HudWidgets.place(btn, data.rect)
    HudWidgets.place(lbl, data.rect)
    lbl.Text = cell_text(data.name, data.count, data.rect.w)
  end
  btn.Visible = true
  btn.TouchEnabled = data.enabled == true
  btn.ButtonNormalColor = make_color(
    not data.enabled and COLORS.DISABLED
      or data.selected and COLORS.SELECTED
      or COLORS.NORMAL
  )
  lbl.Visible = true
end

--- 点亮当前展开项的底板并套上候选区外框。
---@param kind string
---@param rects table
---@param plates table
local function place_plate(kind, rects, plates)
  local plate_rect = MainHudLayout.bounds(rects, Tokens.SPACE.SM)
  if plate_rect ~= nil and plates[kind] ~= nil then
    HudWidgets.place(plates[kind], plate_rect)
    plates[kind].Visible = true
  end
end

-- 装备浮层句柄：状态信号、布局 memo 与外部依赖都留在句柄上，方法集中在 PopupBehavior；
-- 方法名沿用拆分前的局部函数名，挂载入口只做装配。
---@class MainHudEquipPopupsHandle: table<string, any>
---@type MainHudEquipPopupsHandle
local PopupBehavior = {}

--- 发一条 ItemBarAction 上行（select / eat 等无序号动作）。
---@param action string
---@param value any
local function emit_action(action, value)
  ViewUtil.fire_re("ItemBarAction", { action = action, value = value }, "[MainHudEquipPopups]")
end

--- 发一条带单调序号的 Operate 上行。
---@param self MainHudEquipPopupsHandle
---@param payload table|nil
function PopupBehavior.emit_operate(self, payload)
  self.op_seq = self.op_seq + 1
  local body = { action = "Operate", seq = self.op_seq }
  if type(payload) == "table" then
    for k, v in pairs(payload) do
      body[k] = v
    end
  end
  ViewUtil.fire_re("ItemBarAction", body, "[MainHudEquipPopups]")
end

--- 外部注入的展开态信号：卸载时复位为 nil，不留给下一次挂载。
---@param self MainHudEquipPopupsHandle
function PopupBehavior.watch_external_popup(self)
  if not self.external_popup then
    return
  end
  local open_popup = self.open_popup
  self.s:on_cleanup(function()
    open_popup:set(nil)
  end)
end

--- 建武器栏与鱼饵栏常驻入口按钮（严禁写 ButtonText，文字置于同级高 ZOrder EUITextLabel）。
---@param self MainHudEquipPopupsHandle
function PopupBehavior.create_equip_bars(self)
  local ctx, s = self.ctx, self.s
  local open_popup, backpack_open = self.open_popup, self.backpack_open
  for _, kind in ipairs({ "Weapon", "Bait" }) do
    local bar_kind = kind
    local r = self.initial_layout.rects[bar_kind .. "Bar"]
    local btn = HudWidgets.button(ctx, s, {
      name = bar_kind .. "Bar",
      x = r.x,
      y = r.y,
      w = r.w,
      h = r.h,
      normal = COLORS.NORMAL,
      press = COLORS.PRESS,
      disabled = COLORS.DISABLED,
      z_order = Tokens.Z.HUD_CONTENT,
    })
    local label = HudWidgets.label(ctx, s, {
      name = bar_kind .. "BarLabel",
      x = r.x,
      y = r.y,
      w = r.w,
      h = r.h,
      text = "",
      font_size = CELL_FONT,
      text_color = make_color(COLORS.WHITE),
      z_order = Tokens.Z.HUD_ACCENT,
    })
    self.equip_bars[bar_kind] = { button = btn, label = label }
    ctx.connect(s, btn.OnClicked, function()
      if ctx.store.hud_visible:now() == false or backpack_open:now() then
        return
      end
      local cur = open_popup:now()
      open_popup:set(cur ~= bar_kind and bar_kind or nil)
    end)
  end
end

--- 常驻入口的响应式排版、文案与高亮投影（显隐对齐 store.hud_visible）。
---@param self MainHudEquipPopupsHandle
function PopupBehavior.bind_bars_projection(self)
  self.s:effect("EquipBarsProjection", function(es)
    self:project_bars(es)
  end)
end

--- 武器栏文案：装备武器名按栏宽折行，未装备为空串。
---@param state any
---@param rect table
---@return string
local function weapon_label_text(state, rect)
  local weapon = ViewUtil.equipped_weapon(state)
  return weapon and cell_text(MainHudEquipCandidates.item_name(weapon), nil, rect.w) or ""
end

--- 鱼饵栏文案：选中鱼饵带库存，未选中显示「不挂鱼饵」。
---@param state any
---@param rect table
---@return string
local function bait_label_text(state, rect)
  local bait_id = type(state) == "table" and state.selectedBait or nil
  return bait_id
    and cell_text(MainHudEquipCandidates.item_name(bait_id), MainHudEquipCandidates.bait_stock(state, bait_id), rect.w)
    or cell_text("不挂鱼饵", nil, rect.w)
end

--- 按显隐与展开态刷两个入口的可见性、可点态、层级与高亮色。
--- 浮层展开时把入口提至遮罩之上，确保玩家可直接切换另一栏或点自身收起。
---@param equip_bars table
---@param show_bars boolean
---@param open_kind string|nil
local function apply_bar_visibility(equip_bars, show_bars, open_kind)
  local elevated = show_bars and open_kind ~= nil
  local btn_z = elevated and Tokens.Z.HUD_POPUP_CONTENT or Tokens.Z.HUD_CONTENT
  local lbl_z = elevated and Tokens.Z.HUD_POPUP_LABEL or Tokens.Z.HUD_ACCENT
  for kind, bar in pairs(equip_bars) do
    bar.button.Visible = show_bars
    bar.button.TouchEnabled = show_bars
    bar.button.LocalZOrder = btn_z
    bar.label.Visible = show_bars
    bar.label.LocalZOrder = lbl_z
    bar.button.ButtonNormalColor = make_color(
      (show_bars and open_kind == kind) and COLORS.SELECTED or COLORS.NORMAL
    )
  end
end

--- 投影体：排四块位置、写两栏文案、刷可见性。
---@param self MainHudEquipPopupsHandle
---@param es table
function PopupBehavior.project_bars(self, es)
  local ctx = self.ctx
  local state = es:d(ctx.store.item_bar)
  local hud_visible = es:d(ctx.store.hud_visible) ~= false
  local layout = es:d(self.layout_sig) or MainHudLayout.from_resolution(self.resolution, ViewUtil.item_bar_slots(state, false))
  local open_kind = es:d(self.open_popup)
  local bp_open = es:d(self.backpack_open)
  local show_bars = hud_visible and not bp_open

  local weapon_bar = self.equip_bars.Weapon
  local bait_bar = self.equip_bars.Bait
  HudWidgets.place(weapon_bar.button, layout.rects.WeaponBar)
  HudWidgets.place(weapon_bar.label, layout.rects.WeaponBar)
  HudWidgets.place(bait_bar.button, layout.rects.BaitBar)
  HudWidgets.place(bait_bar.label, layout.rects.BaitBar)

  weapon_bar.label.Text = weapon_label_text(state, layout.rects.WeaponBar)
  bait_bar.label.Text = bait_label_text(state, layout.rects.BaitBar)

  apply_bar_visibility(self.equip_bars, show_bars, open_kind)
end

--- 挂载武器/鱼饵展开浮层 Phase（关闭或关屏即零残留销毁）。
---@param self MainHudEquipPopupsHandle
function PopupBehavior.bind_popup_phase(self)
  local s = self.s
  local popup_active = s:memo("EquipPopupActive", function(ms)
    return ViewUtil.overlay_active(ms, self.ctx.store, self.open_popup, self.backpack_open)
  end)
  s:phase("EquipPopupPhase", popup_active, function(ps)
    self:mount_popup(ps)
  end)
end

--- 建浮层底：全屏纯 EUILayout dismiss、两块胶囊底板、单元格 Dock 与同步 Effect。
---@param self MainHudEquipPopupsHandle
---@param ps table
function PopupBehavior.mount_popup(self, ps)
  local ctx = self.ctx
  local w, h = self.resolution.x, self.resolution.y
  Primitives.dismiss_mask(ps, ctx, {
    name = "PopupDismiss",
    width = w,
    height = h,
    z_order = Tokens.Z.HUD_POPUP_MASK,
    on_click = function()
      self.open_popup:set(nil)
    end,
  })

  local plates = self:create_plates(ps)

  local cell_dock = ps:dock("PopupCells")
  local entries = {}
  ps:on_cleanup(function()
    entries = {}
  end)

  ps:effect("PopupCellsSync", function(es)
    self:sync_popup_cells(es, cell_dock, entries, plates)
  end)
end

--- 按当前布局建两块深海蓝胶囊浮层底板，默认隐藏，等同步体按展开项点亮。
---@param self MainHudEquipPopupsHandle
---@param ps table
---@return table
function PopupBehavior.create_plates(self, ps)
  local plates = {}
  local cur_layout = self.layout_sig:now()
    or MainHudLayout.from_resolution(self.resolution, ViewUtil.item_bar_slots(self.ctx.store.item_bar:now(), false))
  for _, kind in ipairs({ "Weapon", "Bait" }) do
    local r = cur_layout.rects[kind .. "Bar"]
    local plate = Primitives.capsule(ps, self.ctx, {
      name = kind .. "Popup",
      parent = self.ctx.root_node,
      rect = r,
      opacity = Tokens.OPACITY.HUD_SURFACE,
      z_order = Tokens.Z.HUD_POPUP_BG,
      visible = false,
    })
    plates[kind] = plate
  end
  return plates
end

--- 同步体：先熄底板，再按展开项算候选、增量维护单元格、回收多余项、最后点亮底板。
---@param self MainHudEquipPopupsHandle
---@param es table
---@param cell_dock table
---@param entries table
---@param plates table
function PopupBehavior.sync_popup_cells(self, es, cell_dock, entries, plates)
  local ctx = self.ctx
  local kind = es:d(self.open_popup)
  local state = es:d(ctx.store.item_bar)
  local layout = es:d(self.layout_sig) or MainHudLayout.from_resolution(self.resolution, ViewUtil.item_bar_slots(state, false))

  for _, plate in pairs(plates) do
    plate.Visible = false
  end
  if kind == nil then
    return
  end

  local list = self:popup_candidates(kind, state)
  local rects = MainHudLayout.popup_cells(layout, kind, #list)
  local seen = self:sync_popup_cells_of_kind(kind, list, rects, cell_dock, entries)
  ViewUtil.drop_stale_keys(entries, seen, cell_dock)
  place_plate(kind, rects, plates)
end

--- 展开项的候选清单：武器走 send_operate，鱼饵走 send_action。
---@param self MainHudEquipPopupsHandle
---@param kind string
---@param state any
---@return table
function PopupBehavior.popup_candidates(self, kind, state)
  local list = {}
  if state ~= nil then
    if kind == "Weapon" then
      list = MainHudEquipCandidates.build_weapon_candidates(state, self.send_operate)
    elseif kind == "Bait" then
      list = MainHudEquipCandidates.build_bait_candidates(state, self.send_action)
    end
  end
  return list
end

--- 逐个候选复用或新建单元格，返回本次出现过的 dock_key 集合。
---@param self MainHudEquipPopupsHandle
---@param kind string
---@param list table
---@param rects table
---@param cell_dock table
---@param entries table
---@return table
function PopupBehavior.sync_popup_cells_of_kind(self, kind, list, rects, cell_dock, entries)
  local seen = {}
  for i, candidate in ipairs(list) do
    local dock_key = kind .. ":" .. tostring(candidate.key)
    seen[dock_key] = true
    local item_data = {
      kind = kind,
      key = candidate.key,
      name = candidate.name,
      count = candidate.count,
      enabled = candidate.enabled,
      selected = candidate.selected,
      choose = candidate.choose,
      rect = rects[i],
    }
    local existing = entries[dock_key]
    if existing ~= nil then
      existing.state:set(item_data)
    else
      local item_state = State.new("PopupCell:" .. dock_key, item_data)
      entries[dock_key] = { state = item_state }
      cell_dock:call(dock_key, Effect.new("PopupCellNode:" .. dock_key, function(cs)
        self:mount_cell(cs, dock_key, item_state)
      end))
    end
  end
  return seen
end

--- 建单个单元格节点：按钮 + 同级文案，点击回调与渲染 Effect 都挂在该单元格作用域上。
---@param self MainHudEquipPopupsHandle
---@param cs table
---@param dock_key string
---@param item_state table
function PopupBehavior.mount_cell(self, cs, dock_key, item_state)
  local ctx = self.ctx
  local init_data = item_state:now()
  local btn = HudWidgets.button(ctx, cs, {
    name = init_data.kind .. "PopupCell_" .. tostring(init_data.key),
    x = 0,
    y = 0,
    w = 80,
    h = 80,
    normal = COLORS.NORMAL,
    press = COLORS.PRESS,
    disabled = COLORS.DISABLED,
    z_order = Tokens.Z.HUD_POPUP_CONTENT,
  })
  local lbl = HudWidgets.label(ctx, cs, {
    name = init_data.kind .. "PopupLabel_" .. tostring(init_data.key),
    x = 0,
    y = 0,
    w = 80,
    h = 80,
    text = "",
    font_size = CELL_FONT,
    text_color = make_color(COLORS.WHITE),
    z_order = Tokens.Z.HUD_POPUP_LABEL,
  })
  ctx.connect(cs, btn.OnClicked, function()
    self:choose_cell(item_state)
  end)
  cs:effect("PopupCellRender:" .. dock_key, function(rs)
    render_cell(btn, lbl, rs, item_state)
  end)
end

--- 点选候选：展开态与候选都还匹配时才发上行，然后收起浮层。
---@param self MainHudEquipPopupsHandle
---@param item_state table
function PopupBehavior.choose_cell(self, item_state)
  local latest = item_state:now()
  if self.open_popup:now() ~= latest.kind or not latest.enabled then
    return
  end
  if type(latest.choose) == "function" then
    latest.choose()
  end
  self.open_popup:set(nil)
end

--- 造装备浮层句柄：状态信号、布局 memo 与外部依赖都挂在句柄上。
---@param s table EffectBuilder
---@param ctx table RootView 上下文
---@param options table
---@param resolution { x: number, y: number }
---@return MainHudEquipPopupsHandle
local function new_view(s, ctx, options, resolution)
  ---@type MainHudEquipPopupsHandle
  local view = {
    s = s,
    ctx = ctx,
    options = options,
    resolution = resolution,
    op_seq = 0,
    open_popup = options.open_popup or State.new("MainHudEquipPopups.open_popup", nil),
    external_popup = options.open_popup ~= nil,
    backpack_open = options.backpack_open or State.new("MainHudEquipPopups.backpack_open", false),
    equip_bars = {},
  }
  for name, method in pairs(PopupBehavior) do
    view[name] = method
  end
  view.send_action = options.send_action or function(action, value)
    emit_action(action, value)
  end
  view.send_operate = options.send_operate or function(payload)
    view:emit_operate(payload)
  end
  view.layout_sig = options.layout or s:memo("EquipPopupsLayout", function(ms)
    return MainHudLayout.from_resolution(resolution, ViewUtil.item_bar_slots(ms:d(ctx.store.item_bar), false))
  end)
  view:watch_external_popup()
  view.initial_layout = (options.layout ~= nil and options.layout:now())
    or MainHudLayout.from_resolution(resolution, ViewUtil.item_bar_slots(ctx.store.item_bar:now(), false))
  return view
end

--- 挂载武器栏、鱼饵栏常驻入口与互斥展开浮层（Phase + Dock）。
---@param s table EffectBuilder
---@param ctx table RootView 上下文 { root_node, store, clock, create_node, own_node, connect }
---@param options table|nil { get_resolution?, send_action?, send_operate?, open_popup?, backpack_open?, layout? }
function MainHudEquipPopups.mount(s, ctx, options)
  options = options or {}
  local resolution = ViewUtil.get_resolution(ctx, options); if resolution == nil and options.layout == nil then return end
  local view = new_view(s, ctx, options, resolution)
  view:create_equip_bars()
  view:bind_bars_projection()
  view:bind_popup_phase()
end

--- 返回可供 RootView.mount({ hud = { ... } }) 直接注册的 HUD spec。
function MainHudEquipPopups.spec(options)
  return ViewUtil.hud_spec("MainHudEquipPopups", MainHudEquipPopups.mount, options)
end

return MainHudEquipPopups
