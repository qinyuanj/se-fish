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

local State = Spoke.State

local MainHudActionButtonsView = {}

local BUTTON_IMAGE = "official://image/11017"
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

local function place(node, rect)
  if node == nil or rect == nil then
    return
  end
  node.Position = Vector2.New(rect.x, rect.y)
  node.Size = Vector2.New(rect.w, rect.h)
end

local function fire_re(channel, payload)
  local ok, err = pcall(function() -- 宿主 RE 通道未就绪或调用异常时记录并安全忽略
    local re_util = rawget(_G, "REUtil") or require("common.re_util")
    local re = re_util and re_util:get_re(channel) or nil
    if re ~= nil then
      re:FireServer(payload)
    end
  end)
  if not ok then
    print("[MainHudActionButtonsView] 发送 " .. tostring(channel) .. " 失败", tostring(err))
  end
end

local function make_button(ctx, scope, name, rect)
  local btn = ctx.create_node(scope, "EUIButton", {
    Name = name,
    Position = Vector2.New(rect.x, rect.y),
    Size = Vector2.New(rect.w, rect.h),
  })
  btn.TouchEnabled = false
  btn.Visible = false
  btn.ButtonText = ""
  btn.NormalImage = BUTTON_IMAGE
  btn.PressImage = BUTTON_IMAGE
  btn.DisableImage = BUTTON_IMAGE
  btn.ButtonNormalColor = make_color(COLORS.NORMAL)
  btn.ButtonPressColor = make_color(COLORS.PRESS)
  btn.ButtonDisableColor = make_color(COLORS.DISABLED)
  btn.LocalZOrder = 0
  return btn
end

local function make_label(ctx, scope, name, rect, text)
  local label = ctx.create_node(scope, "EUITextLabel", {
    Name = name,
    Position = Vector2.New(rect.x, rect.y),
    Size = Vector2.New(rect.w, rect.h),
    Text = text,
    FontSize = LABEL_FONT_SIZE,
    TextColor = make_color(COLORS.WHITE),
  })
  label.TextHorizontalAlignment = 1
  label.TextVerticalAlignment = 1
  label.TouchEnabled = false
  label.SwallowTouchEnabled = false
  label.Visible = false
  label.LocalZOrder = 1
  return label
end

local function compute_layout(resolution, item_bar)
  local slot_count = (type(item_bar) == "table" and Number.is_finite_number(item_bar.slotCount))
    and item_bar.slotCount or GameCfg.Items.ItemBarSlots
  return MainHudLayout.compute({
    width = resolution.x,
    height = resolution.y,
    itemBarSlots = slot_count,
  })
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

local function selected_food(item_bar)
  local entry, slot = selected_entry(item_bar)
  local def = entry and GameCfg.Items.Definitions[entry.itemId] or nil
  if def ~= nil and type(def.EatPercent) == "number" then
    return entry, slot, def
  end
  return nil, nil, nil
end

local function selected_rod(item_bar)
  local entry, slot = selected_entry(item_bar)
  local def = entry and GameCfg.Items.Definitions[entry.itemId] or nil
  if def ~= nil and type(def.Level) == "number" then
    return entry, slot, def
  end
  return nil, nil, nil
end

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

--- 挂载右侧动作键（ItemDiscard 与 ItemAction2）。
---@param s table EffectBuilder
---@param ctx table RootView 上下文 { root_node, store, clock, create_node, own_node, connect }
---@param options table|nil { get_resolution?, backpack_open?, layout?, reel_active?, is_reel_active?, on_reel_click?, send_operate?, send_cast?, send_special? }
function MainHudActionButtonsView.mount(s, ctx, options)
  options = options or {}
  local resolution = ViewUtil.get_resolution(ctx, options)
  local backpack_open = options.backpack_open
  local reel_active_sig = options.reel_active
  local is_reel_active_fn = options.is_reel_active or default_is_reel_active
  local on_reel_click = options.on_reel_click or default_on_reel_click

  local op_seq = 0
  local send_operate = options.send_operate or function(payload)
    op_seq = op_seq + 1
    local body = { action = "Operate", seq = op_seq }
    for k, v in pairs(payload) do
      body[k] = v
    end
    fire_re("ItemBarAction", body)
  end
  local send_cast = options.send_cast or function(action, extra)
    local body = { action = action }
    for k, v in pairs(extra or {}) do
      body[k] = v
    end
    fire_re("CastAction", body)
  end
  local send_special = options.send_special or function(payload)
    fire_re("SpecialItemAction", payload)
  end

  local layout_sig = options.layout or s:memo("ActionButtonsLayout", function(ms)
    return compute_layout(resolution, ms:d(ctx.store.item_bar))
  end)

  local initial_layout = (options.layout ~= nil and options.layout:now())
    or compute_layout(resolution, ctx.store.item_bar:now())

  -- 1. 创建 ItemDiscard / ItemAction2 按钮与同级高 ZOrder 文案标签（全部由 ctx.create_node 托管）
  local btn_discard = make_button(ctx, s, "ItemDiscard", initial_layout.Rects.Discard)
  local label_discard = make_label(ctx, s, "BtnDiscardLabel", initial_layout.Rects.Discard, "丢弃选中物")
  local btn_action = make_button(ctx, s, "ItemAction2", initial_layout.Rects.ItemAction)
  local label_action = make_label(ctx, s, "BtnItemActionLabel", initial_layout.Rects.ItemAction, "抛竿")

  -- 2. 原子吐息冷却（1Hz on_second）与上钩呼吸高亮（活跃期 on_frame 原地改色，绝不重建 Effect）
  local breath_until = nil
  local breath_active = State.new("MainHudActionButtonsView.breath_active", false)

  local alerted_session = nil
  local hook_alert_until = nil
  local hook_alert_active = State.new("MainHudActionButtonsView.hook_alert_active", false)

  local flying_held = false

  local function breath_remaining()
    if breath_until == nil then
      return 0
    end
    return math.max(0, breath_until - ctx.clock.now())
  end

  local function is_interactive()
    if ctx.store.hud_visible:now() == false then
      return false
    end
    if backpack_open ~= nil and backpack_open:now() == true then
      return false
    end
    return true
  end

  local function current_reel_active(cast)
    if reel_active_sig ~= nil then
      return reel_active_sig:now() == true
    end
    return is_reel_active_fn(cast) == true
  end

  local function apply_breath_ui()
    if not is_interactive() then
      return
    end
    local mode, _, special_effect = resolve_mode(
      ctx.store.item_bar:now(),
      ctx.store.cast:now(),
      ctx.store.special_item:now()
    )
    if mode ~= "special" or special_effect ~= "godzilla" then
      return
    end
    local left = breath_remaining()
    label_action.Text = left > 0 and string.format("吐息冷却 %d秒", math.ceil(left)) or "原子吐息"
    btn_action.TouchEnabled = left <= 0
  end

  local function apply_hook_alert_color()
    if not is_interactive() then
      return
    end
    local cast = ctx.store.cast:now()
    local mode, phase = resolve_mode(
      ctx.store.item_bar:now(),
      cast,
      ctx.store.special_item:now()
    )
    if mode ~= "hooked" then
      return
    end
    local reel_flag = current_reel_active(cast)
    local now = ctx.clock.now()
    local alert_now = (reel_flag and hook_alert_until ~= nil and now < hook_alert_until) and now or nil
    local normal_color = cast_action_color(phase, alert_now)
    btn_action.ButtonNormalColor = normal_color
    btn_action.ButtonPressColor = alert_now ~= nil and normal_color or make_color(COLORS.PRESS)
  end

  s:effect("BreathCooldownSync", function(es)
    local special_item = es:d(ctx.store.special_item)
    if type(special_item) == "table"
      and special_item.effect == "godzilla"
      and Number.is_finite_number(special_item.breathRemaining)
      and special_item.breathRemaining > 0 then
      breath_until = ctx.clock.now() + special_item.breathRemaining
      breath_active:set(true)
    else
      breath_until = nil
      breath_active:set(false)
    end
  end)

  s:phase("BreathCooldownPhase", breath_active, function(ps)
    ps:subscribe(ctx.clock.on_second, function()
      if breath_until == nil or ctx.clock.now() >= breath_until then
        breath_until = nil
        breath_active:set(false)
      end
      apply_breath_ui()
    end)
  end)

  s:effect("HookAlertSync", function(es)
    local cast = es:d(ctx.store.cast)
    local phase = type(cast) == "table" and cast.phase or "idle"
    local session = type(cast) == "table" and cast.reelSession or nil
    if phase == "hooked" and session ~= nil then
      if session ~= alerted_session then
        alerted_session = session
        hook_alert_until = ctx.clock.now() + GameCfg.HookAlert.DurationSec
      end
      hook_alert_active:set(hook_alert_until ~= nil and ctx.clock.now() < hook_alert_until)
    else
      hook_alert_until = nil
      hook_alert_active:set(false)
    end
  end)

  s:phase("HookAlertPhase", hook_alert_active, function(ps)
    apply_hook_alert_color()
    ps:subscribe(ctx.clock.on_frame, function()
      if hook_alert_until == nil or ctx.clock.now() >= hook_alert_until then
        hook_alert_until = nil
        hook_alert_active:set(false)
      end
      apply_hook_alert_color()
    end)
    ps:on_cleanup(function()
      apply_hook_alert_color()
    end)
  end)

  -- 3. 响应式投影：排版、遮挡隐藏、文案、可用态与按钮颜色（不依赖高频帧状态）
  s:effect("ActionButtonsProjection", function(es)
    local item_bar = es:d(ctx.store.item_bar)
    local cast = es:d(ctx.store.cast)
    local special_item = es:d(ctx.store.special_item)
    local hud_visible = es:d(ctx.store.hud_visible) ~= false
    local occluded = backpack_open ~= nil and es:d(backpack_open) == true
    local layout = es:d(layout_sig) or compute_layout(resolution, item_bar)
    local reel_flag = reel_active_sig ~= nil and (es:d(reel_active_sig) == true) or is_reel_active_fn(cast) == true

    place(btn_discard, layout.Rects.Discard)
    place(label_discard, layout.Rects.Discard)
    place(btn_action, layout.Rects.ItemAction)
    place(label_action, layout.Rects.ItemAction)

    if occluded or not hud_visible then
      btn_discard.Visible = false
      btn_discard.TouchEnabled = false
      label_discard.Visible = false
      btn_action.Visible = false
      btn_action.TouchEnabled = false
      label_action.Visible = false
      return
    end

    -- 丢弃按钮投影
    local sel_entry, sel_slot = selected_entry(item_bar)
    local discard_visible = sel_entry ~= nil
    btn_discard.Visible = discard_visible
    btn_discard.TouchEnabled = discard_visible
    label_discard.Visible = discard_visible
    label_discard.Text = (discard_visible and held_slot(item_bar) == sel_slot) and "确认丢弃" or "丢弃选中物"

    -- 主动作键投影
    local mode, phase, special_effect = resolve_mode(item_bar, cast, special_item)
    local visible = true
    local enabled = nil
    local text = nil

    if mode == "special" then
      if special_effect == "wings" then
        text = "长按飞行"
        enabled = true
      elseif special_effect == "godzilla" then
        local left = breath_remaining()
        text = left > 0 and string.format("吐息冷却 %d秒", math.ceil(left)) or "原子吐息"
        enabled = left <= 0
      end
    elseif mode == "hooked" then
      text = "点击收线"
      enabled = reel_flag
    elseif mode == "lineOut" then
      text = "收竿"
      enabled = true
    elseif mode == "landed" then
      text = "已上岸"
      enabled = false
    elseif mode == "drop" then
      text = "放下"
      enabled = true
    elseif mode == "food" then
      local _, food_slot, def = selected_food(item_bar)
      text = (held_slot(item_bar) == food_slot and "吃" or "手持") .. def.Name
      enabled = true
    elseif mode == "rod" then
      text = "抛竿"
      enabled = true
    else
      text = "使用"
      enabled = false
      visible = false
    end

    local now = ctx.clock.now()
    local alert_now = (mode == "hooked" and reel_flag and hook_alert_until ~= nil and now < hook_alert_until)
      and now or nil
    local normal_color = cast_action_color(phase, alert_now)

    btn_action.Visible = visible
    label_action.Visible = visible
    btn_action.ButtonNormalColor = normal_color
    btn_action.ButtonPressColor = alert_now ~= nil and normal_color or make_color(COLORS.PRESS)
    if enabled ~= nil then
      btn_action.TouchEnabled = enabled == true
    end
    if text ~= nil then
      label_action.Text = text
    end
  end)

  -- 4. 点击与按住交互绑定（全部经 ctx.connect 托管）
  ctx.connect(s, btn_discard.OnClicked, function()
    if not is_interactive() then
      return
    end
    local item_bar = ctx.store.item_bar:now()
    if type(item_bar) == "table" and item_bar.selectedSlot ~= nil then
      send_operate({ op = "discard", slot = item_bar.selectedSlot })
    end
  end)

  ctx.connect(s, btn_action.OnClicked, function()
    if not is_interactive() then
      return
    end
    local item_bar = ctx.store.item_bar:now()
    local cast = ctx.store.cast:now()
    local special_item = ctx.store.special_item:now()
    local mode, _, special_effect = resolve_mode(item_bar, cast, special_item)

    if mode == "special" then
      if special_effect == "godzilla" and breath_remaining() <= 0 then
        send_special({ action = "breath" })
      end
    elseif mode == "hooked" then
      if current_reel_active(cast) and type(cast) == "table" then
        on_reel_click(cast.reelSession)
      end
    elseif mode == "lineOut" then
      send_cast("Reel")
    elseif mode == "drop" then
      send_cast("Drop")
    elseif mode == "food" then
      local _, food_slot = selected_food(item_bar)
      if food_slot ~= nil then
        send_operate({ op = "eat", slot = food_slot })
      end
    elseif mode == "rod" then
      local entry, slot = selected_rod(item_bar)
      if entry ~= nil and slot ~= nil then
        send_cast("Cast", { slot = slot, itemId = entry.itemId })
      end
    end
  end)

  if btn_action.OnTouchBegan ~= nil and btn_action.OnTouchEnded ~= nil then
    ctx.connect(s, btn_action.OnTouchBegan, function()
      if not is_interactive() then
        return
      end
      local mode, _, special_effect = resolve_mode(
        ctx.store.item_bar:now(),
        ctx.store.cast:now(),
        ctx.store.special_item:now()
      )
      if mode == "special" and special_effect == "wings" then
        flying_held = true
        send_special({ action = "fly", holding = true })
      end
    end)

    ctx.connect(s, btn_action.OnTouchEnded, function()
      local special_item = ctx.store.special_item:now()
      if type(special_item) == "table" and special_item.effect == "wings" then
        flying_held = false
        send_special({ action = "fly", holding = false })
      end
    end)
  end

  s:subscribe(ctx.store.on_server_event, function(event)
    if type(event) ~= "table" or event.channel ~= "SpecialItemResult" then return end
    local result = event.payload
    if type(result) ~= "table" or result.ok ~= false then return end
    local hints = {
      cooldown = "原子吐息冷却中",
      ["not-godzilla"] = "需要选中哥斯拉变身",
      ["not-wings"] = "需要选中风神之翼",
      ["not-alive"] = "现在不能行动",
      ["no-character"] = "角色未就绪",
    }
    local notify = ctx.services and ctx.services.notify
    if type(notify) == "function" then
      notify(hints[result.reason] or ("操作失败 " .. tostring(result.reason)))
    end
  end)

  s:on_cleanup(function()
    if flying_held then
      flying_held = false
      send_special({ action = "fly", holding = false })
    end
    breath_until = nil
    hook_alert_until = nil
    alerted_session = nil
  end)
end

--- 返回可供 RootView.mount({ hud = { ... } }) 直接注册的 HUD spec。
function MainHudActionButtonsView.spec(options)
  return {
    name = "MainHudActionButtons",
    mount = function(s, ctx)
      MainHudActionButtonsView.mount(s, ctx, options)
    end,
  }
end

return MainHudActionButtonsView
