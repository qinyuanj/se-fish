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
local HudWidgets = require("client.views.hud_widgets")

local State = Spoke.State

local MainHudActionButtonsView = {}

local LABEL_FONT_SIZE = 30

local COLORS = {
  WHITE = { 255, 255, 255, 255 },
  NORMAL = { 54, 100, 140, 255 },
  PRESS = { 42, 82, 118, 255 },
  DISABLED = { 120, 120, 120, 255 },
}

local function make_color(rgba)
  return Color.New(rgba[1], rgba[2], rgba[3], rgba[4])
end

local function held_slot(item_bar)
  local held = type(item_bar) == "table" and item_bar.held or nil
  return type(held) == "table" and held.kind == "slot" and held.slot or nil
end

local function selected_entry(item_bar)
  if type(item_bar) ~= "table" or item_bar.selectedSlot == nil or type(item_bar.slots) ~= "table" then
    return nil, nil
  end
  local slot = item_bar.selectedSlot
  return item_bar.slots[slot], slot
end

-- 选中格 + 定义表里的数值字段：食物认 EatPercent、鱼竿认 Level，两者只差字段名。
local function selected_with(field)
  return function(item_bar)
    local entry, slot = selected_entry(item_bar)
    local def = entry and GameCfg.Items.Definitions[entry.itemId] or nil
    if def ~= nil and type(def[field]) == "number" then
      return entry, slot, def
    end
    return nil, nil, nil
  end
end

local selected_food = selected_with("EatPercent")
local selected_rod = selected_with("Level")

local function line_still_out(phase)
  return phase == "cast" or phase == "unhooked"
end

local function resolve_mode(item_bar, cast, special_item)
  local phase = (type(cast) == "table" and cast.phase) or "idle"
  local drop = phase == "idle" and type(cast) == "table" and cast.holding ~= nil
  local special_effect = type(special_item) == "table" and special_item.effect or nil
  if phase == "idle" and not drop and special_effect ~= nil then
    return "special", phase, special_effect
  end
  if phase == "hooked" then
    return "hooked", phase, special_effect
  end
  if line_still_out(phase) then
    return "lineOut", phase, special_effect
  end
  if phase == "landed" then
    return "landed", phase, special_effect
  end
  if drop then
    return "drop", phase, special_effect
  end
  if selected_food(item_bar) ~= nil then
    return "food", phase, special_effect
  end
  if selected_rod(item_bar) ~= nil then
    return "rod", phase, special_effect
  end
  return "none", phase, special_effect
end

local function cast_action_color(phase, alert_now)
  if alert_now == nil then
    return phase == "landed" and make_color(COLORS.DISABLED) or make_color(COLORS.NORMAL)
  end
  local alert = GameCfg.HookAlert
  local k = (math.sin(alert_now * 2 * math.pi / alert.BreathPeriodSec) + 1) / 2
  local h = alert.HighlightColor
  return Color.New(
    math.floor(54 + (h[1] - 54) * k),
    math.floor(100 + (h[2] - 100) * k),
    math.floor(140 + (h[3] - 140) * k),
    h[4]
  )
end

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

-- SpecialItemResult 失败原因 -> 玩家提示文案
local SPECIAL_ITEM_HINTS = {
  cooldown = "原子吐息冷却中",
  ["not-godzilla"] = "需要选中哥斯拉变身",
  ["not-wings"] = "需要选中风神之翼",
  ["not-alive"] = "现在不能行动",
  ["no-character"] = "角色未就绪",
}

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

--- 建 ItemDiscard / ItemAction2 按钮与同级高 ZOrder 文案标签（全部由 ctx.create_node 托管）。
---@param self MainHudActionButtonsHandle
function ActionBehavior.create_nodes(self)
  local ctx, s = self.ctx, self.s
  local layout = self.initial_layout
  self.btn_discard = HudWidgets.button(ctx, s, {
    name = "ItemDiscard", x = layout.rects.discard.x, y = layout.rects.discard.y,
    w = layout.rects.discard.w, h = layout.rects.discard.h,
    touch = false, visible = false, z_order = 0,
  })
  self.label_discard = HudWidgets.label(ctx, s, {
    name = "BtnDiscardLabel",
    x = layout.rects.discard.x,
    y = layout.rects.discard.y,
    w = layout.rects.discard.w,
    h = layout.rects.discard.h,
    text = "丢弃选中物",
    font_size = LABEL_FONT_SIZE,
    text_color = make_color(COLORS.WHITE),
    visible = false,
  })
  self.btn_action = HudWidgets.button(ctx, s, {
    name = "ItemAction2", x = layout.rects.item_action.x, y = layout.rects.item_action.y,
    w = layout.rects.item_action.w, h = layout.rects.item_action.h,
    touch = false, visible = false, z_order = 0,
  })
  self.label_action = HudWidgets.label(ctx, s, {
    name = "BtnItemActionLabel",
    x = layout.rects.item_action.x,
    y = layout.rects.item_action.y,
    w = layout.rects.item_action.w,
    h = layout.rects.item_action.h,
    text = "抛竿",
    font_size = LABEL_FONT_SIZE,
    text_color = make_color(COLORS.WHITE),
    visible = false,
  })
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

--- 按投影结果排四块位置。
---@param self MainHudActionButtonsHandle
---@param layout table
function ActionBehavior.place_buttons(self, layout)
  HudWidgets.place(self.btn_discard, layout.rects.discard)
  HudWidgets.place(self.label_discard, layout.rects.discard)
  HudWidgets.place(self.btn_action, layout.rects.item_action)
  HudWidgets.place(self.label_action, layout.rects.item_action)
end

--- 被遮挡（背包展开）或主 HUD 隐藏时整体熄灯。
---@param self MainHudActionButtonsHandle
function ActionBehavior.hide_buttons(self)
  self.btn_discard.Visible = false
  self.btn_discard.TouchEnabled = false
  self.label_discard.Visible = false
  self.btn_action.Visible = false
  self.btn_action.TouchEnabled = false
  self.label_action.Visible = false
end

--- 丢弃按钮投影：有选中格才亮，选中格与手持格相同时文案改「确认丢弃」。
---@param self MainHudActionButtonsHandle
---@param item_bar any
function ActionBehavior.project_discard(self, item_bar)
  local sel_entry, sel_slot = selected_entry(item_bar)
  local discard_visible = sel_entry ~= nil
  self.btn_discard.Visible = discard_visible
  self.btn_discard.TouchEnabled = discard_visible
  self.label_discard.Visible = discard_visible
  self.label_discard.Text = (discard_visible and held_slot(item_bar) == sel_slot) and "确认丢弃" or "丢弃选中物"
end

--- 主动作键的可见态 / 可用态 / 文案：与拆分前的 if 链逐分支对应。
---@param self MainHudActionButtonsHandle
---@param item_bar any
---@param mode string
---@param special_effect string|nil
---@param reel_flag boolean
---@return boolean visible
---@return boolean|nil enabled
---@return string|nil text
function ActionBehavior.action_view_state(self, item_bar, mode, special_effect, reel_flag)
  if mode == "special" then
    if special_effect == "wings" then
      return true, true, "长按飞行"
    end
    if special_effect == "godzilla" then
      local left = self:breath_remaining()
      return true, left <= 0, left > 0 and string.format("吐息冷却 %d秒", math.ceil(left)) or "原子吐息"
    end
    return true, nil, nil
  end
  if mode == "hooked" then
    return true, reel_flag, "点击收线"
  end
  if mode == "lineOut" then
    return true, true, "收竿"
  end
  if mode == "landed" then
    return true, false, "已上岸"
  end
  if mode == "drop" then
    return true, true, "放下"
  end
  if mode == "food" then
    local _, food_slot, def = selected_food(item_bar)
    return true, true, (held_slot(item_bar) == food_slot and "吃" or "手持") .. def.Name
  end
  if mode == "rod" then
    return true, true, "抛竿"
  end
  return false, false, "使用"
end

--- 主动作键投影：文案 / 可用态 / 呼吸高亮色。
---@param self MainHudActionButtonsHandle
---@param item_bar any
---@param cast any
---@param special_item any
---@param reel_flag boolean
function ActionBehavior.project_action(self, item_bar, cast, special_item, reel_flag)
  local mode, phase, special_effect = resolve_mode(item_bar, cast, special_item)
  local visible, enabled, text = self:action_view_state(item_bar, mode, special_effect, reel_flag)

  local now = self.ctx.clock.now()
  local alert_now = (mode == "hooked" and reel_flag and self.hook_alert_until ~= nil and now < self.hook_alert_until)
    and now or nil
  local normal_color = cast_action_color(phase, alert_now)

  self.btn_action.Visible = visible
  self.label_action.Visible = visible
  self.btn_action.ButtonNormalColor = normal_color
  self.btn_action.ButtonPressColor = alert_now ~= nil and normal_color or make_color(COLORS.PRESS)
  if enabled ~= nil then
    self.btn_action.TouchEnabled = enabled == true
  end
  if text ~= nil then
    self.label_action.Text = text
  end
end

--- 投影体：排版、遮挡隐藏、丢弃键与主动作键。
---@param self MainHudActionButtonsHandle
---@param es table
function ActionBehavior.project(self, es)
  local store = self.ctx.store
  local item_bar = es:d(store.item_bar)
  local cast = es:d(store.cast)
  local special_item = es:d(store.special_item)
  local hud_visible = es:d(store.hud_visible) ~= false
  local occluded = self.backpack_open ~= nil and es:d(self.backpack_open) == true
  local layout = es:d(self.layout_sig) or MainHudLayout.from_resolution(self.resolution, ViewUtil.item_bar_slots(item_bar, true))
  local reel_flag = self.reel_active_sig ~= nil and (es:d(self.reel_active_sig) == true) or self.is_reel_active_fn(cast) == true

  self:place_buttons(layout)
  if occluded or not hud_visible then
    self:hide_buttons()
    return
  end
  self:project_discard(item_bar)
  self:project_action(item_bar, cast, special_item, reel_flag)
end

--- 丢弃键点击：有选中格时按 Operate 上行。
---@param self MainHudActionButtonsHandle
function ActionBehavior.on_discard_clicked(self)
  if not self:is_interactive() then
    return
  end
  local item_bar = self.ctx.store.item_bar:now()
  if type(item_bar) == "table" and item_bar.selectedSlot ~= nil then
    self.send_operate({ op = "discard", slot = item_bar.selectedSlot })
  end
end

--- 主动作键点击：按 resolve_mode 分发到吐息 / 收线 / 收竿 / 放下 / 吃 / 抛竿。
---@param self MainHudActionButtonsHandle
function ActionBehavior.on_action_clicked(self)
  if not self:is_interactive() then
    return
  end
  local store = self.ctx.store
  local item_bar = store.item_bar:now()
  local cast = store.cast:now()
  local special_item = store.special_item:now()
  local mode, _, special_effect = resolve_mode(item_bar, cast, special_item)

  if mode == "special" then
    if special_effect == "godzilla" and self:breath_remaining() <= 0 then
      self.send_special({ action = "breath" })
    end
  elseif mode == "hooked" then
    if self:current_reel_active(cast) and type(cast) == "table" then
      self.on_reel_click(cast.reelSession)
    end
  elseif mode == "lineOut" then
    self.send_cast("Reel")
  elseif mode == "drop" then
    self.send_cast("Drop")
  elseif mode == "food" then
    local _, food_slot = selected_food(item_bar)
    if food_slot ~= nil then
      self.send_operate({ op = "eat", slot = food_slot })
    end
  elseif mode == "rod" then
    local entry, slot = selected_rod(item_bar)
    if entry ~= nil and slot ~= nil then
      self.send_cast("Cast", { slot = slot, itemId = entry.itemId })
    end
  end
end

--- 长按开始：风神之翼进入按住飞行。
---@param self MainHudActionButtonsHandle
function ActionBehavior.on_touch_began(self)
  if not self:is_interactive() then
    return
  end
  local store = self.ctx.store
  local mode, _, special_effect = resolve_mode(
    store.item_bar:now(),
    store.cast:now(),
    store.special_item:now()
  )
  if mode == "special" and special_effect == "wings" then
    self.flying_held = true
    self.send_special({ action = "fly", holding = true })
  end
end

--- 长按结束：仍手持风神之翼时松开飞行。
---@param self MainHudActionButtonsHandle
function ActionBehavior.on_touch_ended(self)
  local special_item = self.ctx.store.special_item:now()
  if type(special_item) == "table" and special_item.effect == "wings" then
    self.flying_held = false
    self.send_special({ action = "fly", holding = false })
  end
end

--- 特殊道具失败提示：只认 SpecialItemResult 的 ok == false。
---@param self MainHudActionButtonsHandle
---@param event any
function ActionBehavior.on_special_item_result(self, event)
  if type(event) ~= "table" or event.channel ~= "SpecialItemResult" then return end
  local result = event.payload
  if type(result) ~= "table" or result.ok ~= false then return end
  local notify = self.ctx.services and self.ctx.services.notify
  if type(notify) == "function" then
    notify(SPECIAL_ITEM_HINTS[result.reason] or ("操作失败 " .. tostring(result.reason)))
  end
end

--- 卸载：仍按住飞行时补发松开，清掉冷却与高亮窗口。
---@param self MainHudActionButtonsHandle
function ActionBehavior.cleanup(self)
  if self.flying_held then
    self.flying_held = false
    self.send_special({ action = "fly", holding = false })
  end
  self.breath_until = nil
  self.hook_alert_until = nil
  self.alerted_session = nil
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

--- 响应式投影：不依赖高频帧状态的那一路。
---@param self MainHudActionButtonsHandle
function ActionBehavior.bind_projection(self)
  self.s:effect("ActionButtonsProjection", function(es) self:project(es) end)
end

--- 点击与按住交互绑定（全部经 ctx.connect 托管），并挂上行提示与卸载清理。
---@param self MainHudActionButtonsHandle
function ActionBehavior.bind_interactions(self)
  local ctx, s = self.ctx, self.s
  ctx.connect(s, self.btn_discard.OnClicked, function() self:on_discard_clicked() end)
  ctx.connect(s, self.btn_action.OnClicked, function() self:on_action_clicked() end)

  if self.btn_action.OnTouchBegan ~= nil and self.btn_action.OnTouchEnded ~= nil then
    ctx.connect(s, self.btn_action.OnTouchBegan, function() self:on_touch_began() end)
    ctx.connect(s, self.btn_action.OnTouchEnded, function() self:on_touch_ended() end)
  end

  s:subscribe(ctx.store.on_server_event, function(event) self:on_special_item_result(event) end)
  s:on_cleanup(function() self:cleanup() end)
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
