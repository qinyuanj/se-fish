-- Spoke 主 HUD 右侧动作键视图（ADR-0032 / #297-B3b1，归属 L2 client.views）：
-- 挂载于 RootView 常驻 HUD 槽位，订阅只读 ClientStore.item_bar / cast / special_item / hud_visible；
-- 负责右侧 ItemDiscard（丢弃/确认丢弃）与 ItemAction2（抛竿/收竿/点击收线/已上岸/放下/手持与吃/长按飞行/原子吐息冷却）
-- 的排版、文案、呼吸高亮色、交互上行 RE 与 backpack_open 展开遮挡隐藏；
-- 所有动态 UI 节点与事件连接统一经 ctx.create_node / ctx.connect 托管，随重连或根 UI 销毁零残留释放。

local Spoke = require("common.packages.spoke.api")
local GameCfg = require("common.game_cfg")
local Number = require("common.number")
local MainHudLayout = require("client.main_hud_layout")
local ViewUtil = require("client.views.view_util")
local MainHudActionButtonsProjection = require("client.views.main_hud_action_buttons_projection")

local State = Spoke.State

local MainHudActionButtonsView = {}

local COLORS = MainHudActionButtonsProjection.COLORS
local make_color = MainHudActionButtonsProjection.make_color
local resolve_mode = MainHudActionButtonsProjection.resolve_mode
local cast_action_color = MainHudActionButtonsProjection.cast_action_color

local function default_is_reel_active(cast)
  return type(cast) == "table" and cast.phase == "hooked" and cast.reelSession ~= nil
end

local function default_on_reel_click(_session_id)
end

-- 动作键句柄：状态字段（冷却截止、呼吸高亮、飞行按住、op 序号）与节点、ctx 都留在句柄上；
-- 方法名沿用拆分前的局部函数名，挂载入口只做装配。
---@class MainHudActionButtonsHandle: table<string, any>
---@type MainHudActionButtonsHandle
local ActionBehavior = {}

--- 发一条带单调序号的 Operate 上行。
---@param self MainHudActionButtonsHandle
---@param payload table
function ActionBehavior.emit_operate(self, payload)
  self.op_seq = self.op_seq + 1
  local body = { action = "Operate", seq = self.op_seq }
  for k, v in pairs(payload) do
    body[k] = v
  end
  ViewUtil.fire_re("ItemBarAction", body, "[MainHudActionButtonsView]")
end

--- 发一条抛竿 / 收竿类上行。
---@param action string
---@param extra table|nil
local function emit_cast(action, extra)
  local body = { action = action }
  for k, v in pairs(extra or {}) do
    body[k] = v
  end
  ViewUtil.fire_re("CastAction", body, "[MainHudActionButtonsView]")
end

--- 发一条特殊道具上行（吐息 / 飞行按住与松开）。
---@param payload table
local function emit_special(payload)
  ViewUtil.fire_re("SpecialItemAction", payload, "[MainHudActionButtonsView]")
end

--- 剩余吐息冷却秒数（无冷却为 0）。
---@param self MainHudActionButtonsHandle
---@return number
function ActionBehavior.breath_remaining(self)
  if self.breath_until == nil then
    return 0
  end
  return math.max(0, self.breath_until - self.ctx.clock.now())
end

--- 交互可用判据：主 HUD 可见且背包未展开。
---@param self MainHudActionButtonsHandle
---@return boolean
function ActionBehavior.is_interactive(self)
  if self.ctx.store.hud_visible:now() == false then
    return false
  end
  if self.backpack_open ~= nil and self.backpack_open:now() == true then
    return false
  end
  return true
end

--- 收线是否活跃：优先读注入信号，否则退回 is_reel_active 判定函数。
---@param self MainHudActionButtonsHandle
---@param cast any
---@return boolean
function ActionBehavior.current_reel_active(self, cast)
  if self.reel_active_sig ~= nil then
    return self.reel_active_sig:now() == true
  end
  return self.is_reel_active_fn(cast) == true
end

--- 原子吐息按钮的文案与可用态（非吐息模式不动按钮）。
---@param self MainHudActionButtonsHandle
function ActionBehavior.apply_breath_ui(self)
  if not self:is_interactive() then
    return
  end
  local mode, _, special_effect = resolve_mode(
    self.ctx.store.item_bar:now(),
    self.ctx.store.cast:now(),
    self.ctx.store.special_item:now()
  )
  if mode ~= "special" or special_effect ~= "godzilla" then
    return
  end
  local left = self:breath_remaining()
  self.label_action.Text = left > 0 and string.format("吐息冷却 %d秒", math.ceil(left)) or "原子吐息"
  self.btn_action.TouchEnabled = left <= 0
end

--- 上钩呼吸高亮的原地改色（非 active 期不动颜色）。
---@param self MainHudActionButtonsHandle
function ActionBehavior.apply_hook_alert_color(self)
  if not self:is_interactive() then
    return
  end
  local cast = self.ctx.store.cast:now()
  local mode, phase = resolve_mode(
    self.ctx.store.item_bar:now(),
    cast,
    self.ctx.store.special_item:now()
  )
  if mode ~= "hooked" then
    return
  end
  local reel_flag = self:current_reel_active(cast)
  local now = self.ctx.clock.now()
  local alert_now = (reel_flag and self.hook_alert_until ~= nil and now < self.hook_alert_until) and now or nil
  local normal_color = cast_action_color(phase, alert_now)
  self.btn_action.ButtonNormalColor = normal_color
  self.btn_action.ButtonPressColor = alert_now ~= nil and normal_color or make_color(COLORS.PRESS)
end

--- 吐息冷却同步：下行剩余秒数转成截止时刻，归零即熄活动 State。
---@param self MainHudActionButtonsHandle
---@param es table
function ActionBehavior.sync_breath(self, es)
  local special_item = es:d(self.ctx.store.special_item)
  if type(special_item) == "table"
    and special_item.effect == "godzilla"
    and Number.is_finite_number(special_item.breathRemaining)
    and special_item.breathRemaining > 0 then
    self.breath_until = self.ctx.clock.now() + special_item.breathRemaining
    self.breath_active:set(true)
  else
    self.breath_until = nil
    self.breath_active:set(false)
  end
end

--- 吐息冷却活动期：1Hz 推进截止判定并刷新按钮。
---@param self MainHudActionButtonsHandle
---@param ps table
function ActionBehavior.run_breath_phase(self, ps)
  local clock = self.ctx.clock
  ps:subscribe(clock.on_second, function()
    if self.breath_until == nil or clock.now() >= self.breath_until then
      self.breath_until = nil
      self.breath_active:set(false)
    end
    self:apply_breath_ui()
  end)
end

--- 上钩高亮同步：同一收线会话只起一次呼吸窗口，离开上钩即熄。
---@param self MainHudActionButtonsHandle
---@param es table
function ActionBehavior.sync_hook_alert(self, es)
  local cast = es:d(self.ctx.store.cast)
  local phase = type(cast) == "table" and cast.phase or "idle"
  local session = type(cast) == "table" and cast.reelSession or nil
  if phase == "hooked" and session ~= nil then
    if session ~= self.alerted_session then
      self.alerted_session = session
      self.hook_alert_until = self.ctx.clock.now() + GameCfg.HookAlert.DurationSec
    end
    self.hook_alert_active:set(self.hook_alert_until ~= nil and self.ctx.clock.now() < self.hook_alert_until)
  else
    self.hook_alert_until = nil
    self.hook_alert_active:set(false)
  end
end

--- 上钩高亮活动期：进相先刷一次，活跃期 on_frame 原地改色，清理由退出时再刷一次。
---@param self MainHudActionButtonsHandle
---@param ps table
function ActionBehavior.run_hook_alert_phase(self, ps)
  local clock = self.ctx.clock
  self:apply_hook_alert_color()
  ps:subscribe(clock.on_frame, function()
    if self.hook_alert_until == nil or clock.now() >= self.hook_alert_until then
      self.hook_alert_until = nil
      self.hook_alert_active:set(false)
    end
    self:apply_hook_alert_color()
  end)
  ps:on_cleanup(function()
    self:apply_hook_alert_color()
  end)
end

--- 冷却与高亮的活动 State：1Hz / 帧驱动的两个活动期。
---@param self MainHudActionButtonsHandle
function ActionBehavior.bind_state_sync(self)
  local s = self.s
  s:effect("BreathCooldownSync", function(es) self:sync_breath(es) end)
  s:phase("BreathCooldownPhase", self.breath_active, function(ps) self:run_breath_phase(ps) end)
  s:effect("HookAlertSync", function(es) self:sync_hook_alert(es) end)
  s:phase("HookAlertPhase", self.hook_alert_active, function(ps) self:run_hook_alert_phase(ps) end)
end

--- 造动作键句柄：状态、注入回调与布局 memo 都挂在句柄上。
---@param s table EffectBuilder
---@param ctx table RootView 上下文
---@param options table
---@param resolution { x: number, y: number }
---@return MainHudActionButtonsHandle
local function new_view(s, ctx, options, resolution)
  ---@type MainHudActionButtonsHandle
  local view = {
    s = s,
    ctx = ctx,
    options = options,
    resolution = resolution,
    op_seq = 0,
    backpack_open = options.backpack_open,
    reel_active_sig = options.reel_active,
    is_reel_active_fn = options.is_reel_active or default_is_reel_active,
    on_reel_click = options.on_reel_click or default_on_reel_click,
    btn_discard = nil,
    label_discard = nil,
    btn_action = nil,
    label_action = nil,
    breath_until = nil,
    breath_active = State.new("MainHudActionButtonsView.breath_active", false),
    alerted_session = nil,
    hook_alert_until = nil,
    hook_alert_active = State.new("MainHudActionButtonsView.hook_alert_active", false),
    flying_held = false,
  }
  for name, method in pairs(ActionBehavior) do
    view[name] = method
  end
  -- 投影与交互行为表并入句柄：与呼吸 / 警报方法共用同一套 self 约定。
  for name, method in pairs(MainHudActionButtonsProjection.Behavior) do
    view[name] = method
  end
  view.send_operate = options.send_operate or function(payload)
    view:emit_operate(payload)
  end
  view.send_cast = options.send_cast or function(action, extra)
    emit_cast(action, extra)
  end
  view.send_special = options.send_special or function(payload)
    emit_special(payload)
  end
  view.layout_sig = options.layout or s:memo("ActionButtonsLayout", function(ms)
    return MainHudLayout.from_resolution(resolution, ViewUtil.item_bar_slots(ms:d(ctx.store.item_bar), true))
  end)
  view.initial_layout = (options.layout ~= nil and options.layout:now())
    or MainHudLayout.from_resolution(resolution, ViewUtil.item_bar_slots(ctx.store.item_bar:now(), true))
  return view
end

--- 挂载右侧动作键（ItemDiscard 与 ItemAction2）。
---@param s table EffectBuilder
---@param ctx table RootView 上下文 { root_node, store, clock, create_node, own_node, connect }
---@param options table|nil { get_resolution?, backpack_open?, layout?, reel_active?, is_reel_active?, on_reel_click?, send_operate?, send_cast?, send_special? }
function MainHudActionButtonsView.mount(s, ctx, options)
  options = options or {}
  local resolution = ViewUtil.get_resolution(ctx, options); if resolution == nil and options.layout == nil then return end

  local view = new_view(s, ctx, options, resolution)
  view:create_nodes()
  view:bind_state_sync()
  view:bind_projection()
  view:bind_interactions()
end

--- 返回可供 RootView.mount({ hud = { ... } }) 直接注册的 HUD spec。
function MainHudActionButtonsView.spec(options)
  return ViewUtil.hud_spec("MainHudActionButtons", MainHudActionButtonsView.mount, options)
end

return MainHudActionButtonsView
