-- Spoke 主 HUD 武器攻击按钮与伤害飘字视图（#300，归属 L2 client.views）：
-- 攻击按钮直接挂载于 ctx.root_node（不再挂入已隐藏的 ScreenMain），子节点采用相对父容器左下角局部居中坐标杜绝二次叠加；
-- 伤害飘字居中于屏幕中上部安全区（Tokens.Z.TOAST + 圆体描边 + 位移飘字），不再停留在 (0, 0)。

local GameCfg = require("common.game_cfg")
local PressGesture = require("client.press_gesture")
local Spoke = require("common.packages.spoke.api")
local MainHudLayout = require("client.main_hud_layout")
local Tokens = require("client.ui.tokens")
local Layout = require("client.ui.layout")
local Primitives = require("client.ui.primitives")
local Controls = require("client.ui.controls")
local ViewUtil = require("client.views.view_util")

local State = Spoke.State
local AttackView = {}

local HINTS = {
  ["cannot-act"] = "现在不能攻击",
  unavailable = "武器未就绪",
  cooldown = "出手太快",
  reloading = "换弹中",
  empty = "弹匣已空，自动换弹",
  ["not-a-gun"] = "手持的不是枪械",
  ["mag-full"] = "弹匣是满的",
  ["bad-slot"] = "格子不存在",
  ["bad-throwable"] = "这个不能投掷",
  ["bad-target"] = "落点无效",
  ["bad-weapon"] = "武器未配置",
  ["bad-aim"] = "瞄准无效",
}

local DAMAGE_FLOAT_W, DAMAGE_FLOAT_H = 160, 48
local DAMAGE_DRIFT_Y = 48

local function is_gun(weapon_id)
  return weapon_id ~= nil and GameCfg.Ability.Guns[weapon_id] ~= nil
end

local function attack_rect(ctx)
  local resolution = ViewUtil.get_resolution(ctx)
  if resolution == nil then
    return nil
  end
  local layout = MainHudLayout.compute({
    width = resolution.x,
    height = resolution.y,
    itemBarSlots = GameCfg.Items.InitialItemBarSlots,
  })
  return layout and layout.rects and layout.rects.attack_control or nil
end

-- 攻击键句柄：按钮/标签节点、按压手势与自动开火计时都留在句柄上；
-- 方法名沿用拆分前的局部函数名，挂载入口只做装配。
---@class AttackHandle: table<string, any>
---@type AttackHandle
local AttackBehavior = {}

---@param self AttackHandle
---@return number|nil
function AttackBehavior.now_of(self)
  return ViewUtil.read_now(self.clock_now, "AttackView")
end

---@param self AttackHandle
---@return table|nil
function AttackBehavior.current_gun(self)
  local weapon_id = ViewUtil.equipped_weapon(self.ctx.store.item_bar:now())
  return weapon_id and GameCfg.Ability.Guns[weapon_id] or nil
end

--- 发一条武器上行；attack 附带当前瞄准方向。
---@param self AttackHandle
---@param action string
function AttackBehavior.send(self, action)
  local services = self.services
  if type(services.send_weapon) ~= "function" then return end
  local payload = { action = action }
  if action == "attack" and type(services.aim_direction) == "function" then
    local ok, direction = pcall(services.aim_direction)
    if not ok then
      print("[AttackView] 读取瞄准方向失败", tostring(direction))
    elseif ViewUtil.is_record(direction) then
      local x, y, z = ViewUtil.read_vec3(direction)
      payload.aim = x ~= nil and { x = x, y = y, z = z } or direction
    end
  end
  services.send_weapon(payload)
end

--- 逐帧推进按压手势，自动武器按间隔连发。
---@param self AttackHandle
function AttackBehavior.tick(self)
  local t = self:now_of(); if t == nil then return end
  self.gesture:update(t)
  local gun = self:current_gun()
  if gun and gun.Auto and t >= self.next_auto then
    self.next_auto = t + (gun.IntervalSec or 0.2)
    self.auto_fired = true
    self:send("attack")
  end
end

---@param self AttackHandle
function AttackBehavior.on_touch_began(self)
  local t = self:now_of(); if t == nil then return end
  self.touch_handled = false
  self.auto_fired = false; self.next_auto = 0; self.gesture:begin(t); self.pressing:set(true)
end

---@param self AttackHandle
function AttackBehavior.on_touch_ended(self)
  self.pressing:set(false)
  self.touch_handled = true
  local t = self:now_of(); if t == nil then return end
  local result = self.gesture:finish(t)
  if result == "tap" then
    if not self.auto_fired then self:send("attack") end
  elseif result == "long" then
    local gun = self:current_gun()
    if gun and not gun.Auto then self:send("reload") end
  end
end

--- 单击兜底：已由 OnTouchBegan/OnTouchEnded 结算的同一次点击吞掉防重，直接点击则发一次 attack。
---@param self AttackHandle
function AttackBehavior.on_clicked(self)
  if self.touch_handled then
    self.touch_handled = false
    return
  end
  self:send("attack")
end

--- 绑按压：触摸开始/结束与按压期帧订阅，并保留防重 OnClicked 单击入口。
---@param self AttackHandle
---@param ps table phase scope
---@param button table
function AttackBehavior.bind_touch(self, ps, button)
  local ctx = self.ctx
  if button.OnTouchBegan and button.OnTouchEnded then
    ctx.connect(ps, button.OnTouchBegan, function() self:on_touch_began() end)
    ctx.connect(ps, button.OnTouchEnded, function() self:on_touch_ended() end)
    ps:phase("AttackPressPhase", self.pressing, function(press_scope)
      if ctx.clock and ctx.clock.on_frame then
        press_scope:subscribe(ctx.clock.on_frame, function() self:tick() end)
      end
    end)
  end
  if button.OnClicked then
    ctx.connect(ps, button.OnClicked, function() self:on_clicked() end)
  end
end

--- 建攻击键节点：外层容器按屏幕坐标定位，内部按钮采用局部居中坐标 (w/2, h/2) 杜绝二次叠加。
---@param self AttackHandle
---@param ps table phase scope
function AttackBehavior.mount_control(self, ps)
  local ctx = self.ctx
  local rect = attack_rect(ctx)
  if rect == nil then
    return
  end
  local control = Primitives.container(ps, ctx, {
    name = "AttackControl",
    parent = ctx.root_node,
    rect = rect,
    z_order = Tokens.Z.HUD_CONTENT,
    touch = false,
    swallow = false,
  })
  local local_rect = Layout.rect(rect.w / 2, rect.h / 2, rect.w, rect.h)
  local button, label = Controls.button(ps, ctx, {
    name = "BtnAttack",
    parent = control,
    rect = local_rect,
    text = "攻击",
    variant = "hud",
    font_size = Tokens.FONT_SIZE.SUBTITLE,
    bold = true,
    outline = true,
    z_order = 1,
    touch = false,
    label_name = "AttackLabel",
  })
  local screen_open = ctx.store.hud_visible
  ps:effect("AttackEnabled", function(es)
    button.TouchEnabled = es:d(screen_open) == true
  end)

  ps:effect("AttackCaption", function(es)
    local weapon_id = ViewUtil.equipped_weapon(es:d(ctx.store.item_bar))
    if label ~= nil then
      label.Text = is_gun(weapon_id) and "射击" or "攻击"
    end
  end)

  self.button, self.label = button, label
  self.pressing = State.new("AttackView.pressing", false)
  self.auto_fired = false
  self.touch_handled = false
  self.next_auto = 0
  self.gesture = PressGesture.new({ long_press_sec = GameCfg.Ability.Throw.LongPressSec })
  self:bind_touch(ps, button)
end

--- 服务端事件：武器失败提示与伤害飘字数值。
---@param self AttackHandle
---@param event any
function AttackBehavior.on_server_event(self, event)
  if type(event) ~= "table" then return end
  if event.channel == "WeaponResult" then
    local payload = event.payload
    if type(payload) == "table" and payload.ok == false then
      ViewUtil.notify(self.ctx, HINTS[payload.reason] or ("武器操作失败 " .. tostring(payload.reason)))
    end
  elseif event.channel == "DamageNotice" and type(event.payload) == "table" then
    local amount = tonumber(event.payload.amount)
    if amount == nil or amount ~= amount or math.abs(amount) == math.huge then return end
    local notice = self.damage_notice
    notice:set({
      amount = math.floor(amount + 0.5),
      critical = event.payload.critical == true,
      seq = (notice:now() and notice:now().seq or 0) + 1,
    })
  end
end

--- 伤害飘字：置于屏幕中上部 HUD 强调层（Tokens.Z.HUD_ACCENT + 圆体描边 + 上飘位移），
--- 打开模态弹窗时自动抑制，杜绝穿模盖住弹窗文字或停留在 (0, 0)。
---@param self AttackHandle
---@param es table EffectScope
function AttackBehavior.on_damage_float(self, es)
  local notice = es:d(self.damage_notice)
  if type(notice) ~= "table" then return end
  if es:d(self.ctx.store.active_modal) ~= nil then return end
  local res = Primitives.resolution(self.ctx) or { x = 1920, y = 1080 }
  local jitter_x = (((notice.seq or 0) % 5) - 2) * 28
  local base_x = Layout.snap4(res.x / 2 + jitter_x)
  local base_y = Layout.snap4(res.y * 0.62)
  local node = Primitives.label(es, self.ctx, {
    name = "DamageFloat",
    parent = self.ctx.root_node,
    rect = Layout.rect(base_x, base_y, DAMAGE_FLOAT_W, DAMAGE_FLOAT_H),
    text = tostring(notice.amount),
    font_size = notice.critical and Tokens.FONT_SIZE.TITLE or Tokens.FONT_SIZE.SUBTITLE,
    bold = true,
    color = notice.critical and Tokens.COLOR.TEXT_GOLD or Tokens.COLOR.WHITE,
    outline = true,
    outline_color = Tokens.COLOR.OUTLINE_DARK,
    z_order = Tokens.Z.HUD_ACCENT,
  })
  Primitives.tween_position(node, base_x, base_y + DAMAGE_DRIFT_Y, Tokens.ANIM.SLOW)
end

--- 挂载攻击键：造句柄、注册可见性 memo 与按钮 phase、接事件与飘字投影。
---@param scope table
---@param ctx table
function AttackView.mount(scope, ctx)
  ---@type AttackHandle
  local self = {
    scope = scope,
    ctx = ctx,
    services = ctx.services or {},
    clock_now = ViewUtil.resolve_clock(ctx, "AttackView"),
    damage_notice = nil,
    pressing = nil,
    gesture = nil,
    auto_fired = false,
    next_auto = 0,
    button = nil,
    label = nil,
  }
  for name, method in pairs(AttackBehavior) do self[name] = method end
  local active = scope:memo("AttackVisible", function(ms)
    return ms:d(ctx.store.hud_visible) ~= false and ViewUtil.equipped_weapon(ms:d(ctx.store.item_bar)) ~= nil
  end)

  scope:phase("AttackButton", active, function(ps) self:mount_control(ps) end)

  self.damage_notice = State.new("AttackView.damage_notice", nil)
  scope:subscribe(ctx.store.on_server_event, function(event) self:on_server_event(event) end)
  scope:effect("DamageFloat", function(es) self:on_damage_float(es) end)
end

function AttackView.spec()
  return ViewUtil.hud_spec("Attack", AttackView.mount)
end

return AttackView
