-- Spoke 主 HUD 背包入口与背包面板视图（ADR-0032 / #297-B3c，归属 L2 client.views）：
-- 挂载于 RootView 常驻 HUD 槽位，订阅只读 ClientStore.item_bar；
-- 常驻入口 BtnBackpack 实时显示「背包 N 格」并随道具栏扩容重排；
-- 展开态 BackpackPanel 由 Phase + Dock 管理 BackpackSlot1..N 与转入道具栏按钮生命周期；
-- 通过共享 backpack_open / open_popup 信号与回调协同控制展开遮挡（关闭装备浮层、隐藏底部装备栏与动作键）；
-- 关闭面板、重连或根 UI 销毁均自动零残留销毁节点与信号连接。

local Spoke = require("common.packages.spoke.api")
local GameCfg = require("common.game_cfg")
local Number = require("common.number")
local MainHudLayout = require("client.main_hud_layout")
local ViewUtil = require("client.views.view_util")
local HudWidgets = require("client.views.hud_widgets")
local MainHudBackpackPanel = require("client.views.main_hud_backpack_panel")

local State = Spoke.State

local MainHudBackpackView = {}

local COLORS = MainHudBackpackPanel.COLORS

local make_color = ViewUtil.color


-- 背包视图句柄：开关信号、选中格、命中矩形与注入回调留在视图句柄上；
-- 方法名沿用拆分前的局部函数名，挂载入口只做装配并返回对外句柄。
---@class MainHudBackpackHandle: table<string, any>
---@type MainHudBackpackHandle
local BackpackBehavior = {}

--- 入口按钮文案：有背包计数时显示「背包 N 格」。
---@param state any
---@return string
local function backpack_entry_text(state)
  if type(state) == "table" and Number.is_finite_number(state.backpackCount) then
    return "背包 " .. tostring(math.floor(state.backpackCount)) .. " 格"
  end
  return "背包"
end

-- ---------------------------------------------------------------------------
-- 背包视图（常驻入口 + 面板装配）方法
-- ---------------------------------------------------------------------------

--- 命中背包格位时返回 { container, index }；背包未展开、关屏或未命中返回 nil。
---@param self MainHudBackpackHandle
---@param pos any
---@return table|nil
function BackpackBehavior.resolve_own_slot(self, pos)
  --- 背包格位只在展开且主 HUD 可见时认（与道具栏的守卫多一条展开判定）。
  local expanded = pos ~= nil and self.ctx.store.hud_visible:now() ~= false and self.backpack_open:now() == true
  if not expanded then return nil end
  return ViewUtil.slot_hit(pos, self.active_slot_rects, GameCfg.Items.ContainerId.Backpack)
end

--- 落点归属：先认背包格位，再交给外部跨容器解析（与道具栏共用 ViewUtil.slot_at_position）。
BackpackBehavior.slot_at_position = ViewUtil.slot_at_position

--- 默认 ItemBarAction 上行。
---@param action string
---@param value any
local function emit_action(action, value)
  ViewUtil.fire_re("ItemBarAction", { action = action, value = value }, "[MainHudBackpackView]")
end

--- 把落点解析器交给外部（跨容器拖拽）；卸载时以 nil 收回（实现见 ViewUtil.register_drop_resolver）。
BackpackBehavior.register_drop_resolver = ViewUtil.register_drop_resolver

--- 开关背包：清选中、展开时先收起装备浮层，再写开关信号。
---@param self MainHudBackpackHandle
---@param flag boolean
function BackpackBehavior.set_backpack_open(self, flag)
  local next_open = flag == true
  self.selected_slot:set(nil)
  if next_open and self.open_popup ~= nil and type(self.open_popup.set) == "function" then
    self.open_popup:set(nil)
  end
  self.backpack_open:set(next_open)
end

--- 卸载：收回落点解析器、清命中矩形，外部注入的开关信号复位为 false。
---@param self MainHudBackpackHandle
function BackpackBehavior.release(self)
  ViewUtil.revoke_drop_resolver(self)
  self.active_slot_rects = {}
  if self.external_open then
    self.backpack_open:set(false)
  end
end

--- 建常驻背包入口按钮与同级文案（EUIButton 不写 Color，文字置于同级高 ZOrder EUITextLabel）。
---@param self MainHudBackpackHandle
function BackpackBehavior.create_entry_nodes(self)
  local ctx, s = self.ctx, self.s
  local entry_rect = self.initial_layout.rects.backpack_button
  self.btn_backpack = HudWidgets.button(ctx, s, {
    name = "BtnBackpack", x = entry_rect.x, y = entry_rect.y, w = entry_rect.w, h = entry_rect.h,
  })
  self.btn_backpack.LocalZOrder = 6
  self.label_backpack = HudWidgets.label(ctx, s, {
    name = "LabelBackpack",
    x = entry_rect.x,
    y = entry_rect.y,
    w = entry_rect.w,
    h = entry_rect.h,
    text = "背包",
    font_size = 22,
    text_color = make_color(COLORS.WHITE),
    z_order = 7,
  })
end

--- 入口点击：关屏不动，否则开关背包。
---@param self MainHudBackpackHandle
function BackpackBehavior.bind_entry_click(self)
  self.ctx.connect(self.s, self.btn_backpack.OnClicked, function()
    if self.ctx.store.hud_visible:now() == false then
      return
    end
    self:set_backpack_open(not self.backpack_open:now())
  end)
end

--- 入口投影：排版、关屏显隐与容量文案。
---@param self MainHudBackpackHandle
---@param es table
function BackpackBehavior.project_entry(self, es)
  local store = self.ctx.store
  local state = es:d(store.item_bar)
  local hud_visible = es:d(store.hud_visible) ~= false
  local layout = es:d(self.layout_sig) or MainHudLayout.from_resolution(self.resolution, ViewUtil.item_bar_slots(state, true))
  local is_open = es:d(self.backpack_open) == true

  HudWidgets.place(self.btn_backpack, layout.rects.backpack_button)
  HudWidgets.place(self.label_backpack, layout.rects.backpack_button)
  self.btn_backpack.Visible = hud_visible
  self.btn_backpack.TouchEnabled = hud_visible
  self.label_backpack.Visible = hud_visible
  self.btn_backpack.ButtonNormalColor = make_color((hud_visible and is_open) and COLORS.SELECTED or COLORS.NORMAL)

  self.label_backpack.Text = backpack_entry_text(state)
end

--- 展开遮挡联动：展开时关闭装备浮层并通知外部遮挡回调。
---@param self MainHudBackpackHandle
---@param es table
function BackpackBehavior.sync_occlusion(self, es)
  local is_open = es:d(self.backpack_open) == true
  if is_open and self.open_popup ~= nil and type(self.open_popup.set) == "function" then
    self.open_popup:set(nil)
  end
  if type(self.on_open_changed) == "function" then
    self.on_open_changed(is_open)
  end
end

--- 面板活跃判据：主 HUD 可见且背包展开。
---@param self MainHudBackpackHandle
---@param ms table
---@return boolean
function BackpackBehavior.panel_visible(self, ms)
  return ms:d(self.ctx.store.hud_visible) ~= false and ms:d(self.backpack_open) == true
end

--- 展开态面板 Phase：关闭、关屏、重连或根 UI 销毁即零残留销毁全部节点与连接。
---@param self MainHudBackpackHandle
---@param ps table
function BackpackBehavior.mount_panel(self, ps)
  local panel_handle = MainHudBackpackPanel.new(self, ps, Spoke)
  panel_handle:create_nodes()
  ps:on_cleanup(function()
    panel_handle:release()
  end)
  ps:effect("BackpackPanelSync", function(es)
    panel_handle:sync(es)
  end)
end

--- 挂入口投影、遮挡联动与面板 Phase 三段 Effect / Phase。
---@param self MainHudBackpackHandle
function BackpackBehavior.bind_effects(self)
  local s = self.s
  s:effect("BackpackEntryProjection", function(es) self:project_entry(es) end)
  s:effect("BackpackOcclusionSync", function(es) self:sync_occlusion(es) end)

  local panel_active = s:memo("BackpackPanelActive", function(ms)
    return self:panel_visible(ms)
  end)
  s:phase("BackpackPanelPhase", panel_active, function(ps)
    self:mount_panel(ps)
  end)
end

--- 造背包视图句柄：注入回调、开关 / 选中信号、布局 memo 与命中矩形都挂在句柄上。
---@param s table EffectBuilder
---@param ctx table RootView 上下文
---@param options table
---@param resolution table|nil
---@return MainHudBackpackHandle
local function new_view(s, ctx, options, resolution)
  ---@type MainHudBackpackHandle
  local view = {
    s = s,
    ctx = ctx,
    options = options,
    resolution = resolution,
    backpack_open = options.backpack_open or State.new("MainHudBackpackView.backpack_open", false),
    external_open = options.backpack_open ~= nil,
    open_popup = options.open_popup,
    on_open_changed = options.on_open_changed,
    resolve_drop_target = options.resolve_drop_target,
    on_drop_resolver = options.on_drop_resolver,
    selected_slot = State.new("MainHudBackpackView.selected_slot", nil),
    active_slot_rects = {},
    layout_sig = nil,
    initial_layout = nil,
    resolve_own_slot_fn = nil,
    btn_backpack = nil,
    label_backpack = nil,
  }
  for name, method in pairs(BackpackBehavior) do
    view[name] = method
  end
  view.send_action = options.send_action or function(action, value)
    emit_action(action, value)
  end
  view.layout_sig = options.layout or s:memo("BackpackLayout", function(ms)
    return MainHudLayout.from_resolution(resolution, ViewUtil.item_bar_slots(ms:d(ctx.store.item_bar), true))
  end)
  view.initial_layout = (options.layout ~= nil and options.layout:now())
    or MainHudLayout.from_resolution(resolution, ViewUtil.item_bar_slots(ctx.store.item_bar:now(), true))
  view.resolve_own_slot_fn = function(pos) return view:resolve_own_slot(pos) end
  return view
end

--- 挂载常驻背包入口按钮与展开态背包面板（Phase + Dock）。
---@param s table EffectBuilder
---@param ctx table RootView 上下文 { root_node, store, clock, create_node, own_node, connect }
---@param options table|nil { get_resolution?, send_action?, backpack_open?, open_popup?, on_open_changed?, resolve_drop_target?, on_drop_resolver?, layout? }
function MainHudBackpackView.mount(s, ctx, options)
  options = options or {}
  local resolution = ViewUtil.get_resolution(ctx, options); if resolution == nil and options.layout == nil then return end

  local view = new_view(s, ctx, options, resolution)
  view:register_drop_resolver()

  s:on_cleanup(function()
    view:release()
  end)

  view:create_entry_nodes()
  view:bind_entry_click()
  view:bind_effects()

  return {
    backpack_open = view.backpack_open,
    selected_slot = view.selected_slot,
    resolve_slot_at = view.resolve_own_slot_fn,
  }
end

--- 返回可供 RootView.mount({ hud = { ... } }) 直接注册的 HUD spec。
function MainHudBackpackView.spec(options)
  return ViewUtil.hud_spec("MainHudBackpack", MainHudBackpackView.mount, options)
end

return MainHudBackpackView
