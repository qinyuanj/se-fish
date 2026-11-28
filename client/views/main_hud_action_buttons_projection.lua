-- 主 HUD 右侧动作键的投影与交互行为（#412 从 main_hud_action_buttons_view 拆出，归属 L2 client.views）：
-- 版面投影、主动作键分支文案、点击 / 按住上行与 SpecialItemResult 提示；呼吸冷却与上钩高亮仍在视图模块。
-- 统一走 Tokens.Z 全局层级表、4px 栅格与圆体描边，保持 ViewUtil.color 与上下文显隐逻辑不变。

local GameCfg = require("common.game_cfg")
local MainHudLayout = require("client.main_hud_layout")
local Tokens = require("client.ui.tokens")
local ViewUtil = require("client.views.view_util")
local HudWidgets = require("client.views.hud_widgets")

local MainHudActionButtonsProjection = {}

local LABEL_FONT_SIZE = Tokens.FONT_SIZE.BUTTON

local COLORS = {
  WHITE = Tokens.COLOR.WHITE,
  NORMAL = Tokens.COLOR.HUD_SLOT,
  PRESS = Tokens.COLOR.HUD_SLOT_PRESS,
  DISABLED = Tokens.COLOR.DISABLED,
}

local make_color = ViewUtil.color

MainHudActionButtonsProjection.COLORS = COLORS

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
  local base = COLORS.NORMAL
  local h = alert.HighlightColor
  return make_color({
    math.floor(base[1] + (h[1] - base[1]) * k),
    math.floor(base[2] + (h[2] - base[2]) * k),
    math.floor(base[3] + (h[3] - base[3]) * k),
    h[4] or 255,
  })
end

MainHudActionButtonsProjection.resolve_mode = resolve_mode
MainHudActionButtonsProjection.cast_action_color = cast_action_color

local SPECIAL_ITEM_HINTS = {
  cooldown = "原子吐息冷却中",
  ["not-godzilla"] = "需要选中哥斯拉变身",
  ["not-wings"] = "需要选中风神之翼",
  ["not-alive"] = "现在不能行动",
  ["no-character"] = "角色未就绪",
}

--- 投影 / 交互行为表：与视图方法共用同一套 handle（self）约定。
local ProjectionBehavior = {}

--- 建 ItemDiscard / ItemAction2 按钮与同级高 ZOrder 圆体描边文案标签（全部由 ctx.create_node 托管）。
---@param self MainHudActionButtonsHandle
function ProjectionBehavior.create_nodes(self)
  local ctx, s = self.ctx, self.s
  local layout = self.initial_layout
  self.btn_discard = HudWidgets.button(ctx, s, {
    name = "ItemDiscard",
    x = layout.rects.discard.x,
    y = layout.rects.discard.y,
    w = layout.rects.discard.w,
    h = layout.rects.discard.h,
    normal = COLORS.NORMAL,
    press = COLORS.PRESS,
    disabled = COLORS.DISABLED,
    touch = false,
    visible = false,
    z_order = Tokens.Z.HUD_CONTENT,
  })
  self.label_discard = HudWidgets.label(ctx, s, {
    name = "BtnDiscardLabel",
    x = layout.rects.discard.x,
    y = layout.rects.discard.y,
    w = layout.rects.discard.w,
    h = layout.rects.discard.h,
    text = "丢弃选中物",
    font_size = LABEL_FONT_SIZE,
    bold = true,
    outline = true,
    text_color = make_color(COLORS.WHITE),
    z_order = Tokens.Z.HUD_ACCENT,
    visible = false,
  })
  self.btn_action = HudWidgets.button(ctx, s, {
    name = "ItemAction2",
    x = layout.rects.item_action.x,
    y = layout.rects.item_action.y,
    w = layout.rects.item_action.w,
    h = layout.rects.item_action.h,
    normal = COLORS.NORMAL,
    press = COLORS.PRESS,
    disabled = COLORS.DISABLED,
    touch = false,
    visible = false,
    z_order = Tokens.Z.HUD_CONTENT,
  })
  self.label_action = HudWidgets.label(ctx, s, {
    name = "BtnItemActionLabel",
    x = layout.rects.item_action.x,
    y = layout.rects.item_action.y,
    w = layout.rects.item_action.w,
    h = layout.rects.item_action.h,
    text = "抛竿",
    font_size = LABEL_FONT_SIZE,
    bold = true,
    outline = true,
    text_color = make_color(COLORS.WHITE),
    z_order = Tokens.Z.HUD_ACCENT,
    visible = false,
  })
end

--- 按投影结果排四块位置。
---@param self MainHudActionButtonsHandle
---@param layout table
function ProjectionBehavior.place_buttons(self, layout)
  HudWidgets.place(self.btn_discard, layout.rects.discard)
  HudWidgets.place(self.label_discard, layout.rects.discard)
  HudWidgets.place(self.btn_action, layout.rects.item_action)
  HudWidgets.place(self.label_action, layout.rects.item_action)
end

--- 被遮挡（背包展开）或主 HUD 隐藏时整体熄灯。
---@param self MainHudActionButtonsHandle
function ProjectionBehavior.hide_buttons(self)
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
function ProjectionBehavior.project_discard(self, item_bar)
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
function ProjectionBehavior.action_view_state(self, item_bar, mode, special_effect, reel_flag)
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
function ProjectionBehavior.project_action(self, item_bar, cast, special_item, reel_flag)
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
function ProjectionBehavior.project(self, es)
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
function ProjectionBehavior.on_discard_clicked(self)
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
function ProjectionBehavior.on_action_clicked(self)
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
function ProjectionBehavior.on_touch_began(self)
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
function ProjectionBehavior.on_touch_ended(self)
  local special_item = self.ctx.store.special_item:now()
  if type(special_item) == "table" and special_item.effect == "wings" then
    self.flying_held = false
    self.send_special({ action = "fly", holding = false })
  end
end

--- 特殊道具失败提示：只认 SpecialItemResult 的 ok == false。
---@param self MainHudActionButtonsHandle
---@param event any
function ProjectionBehavior.on_special_item_result(self, event)
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
function ProjectionBehavior.cleanup(self)
  if self.flying_held then
    self.flying_held = false
    self.send_special({ action = "fly", holding = false })
  end
  self.breath_until = nil
  self.hook_alert_until = nil
  self.alerted_session = nil
end

--- 响应式投影：不依赖高频帧状态的那一路。
---@param self MainHudActionButtonsHandle
function ProjectionBehavior.bind_projection(self)
  self.s:effect("ActionButtonsProjection", function(es) self:project(es) end)
end

--- 点击与按住交互绑定（全部经 ctx.connect 托管），并挂上行提示与卸载清理。
---@param self MainHudActionButtonsHandle
function ProjectionBehavior.bind_interactions(self)
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

MainHudActionButtonsProjection.Behavior = ProjectionBehavior

return MainHudActionButtonsProjection
