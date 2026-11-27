
local GameCfg = require("common.game_cfg")
local PressGesture = require("client.press_gesture")
local Spoke = require("common.packages.spoke.api")
local MainHudLayout = require("client.main_hud_layout")
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
    slots = 1,
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
  self.auto_fired = false; self.next_auto = 0; self.gesture:begin(t); self.pressing:set(true)
end

---@param self AttackHandle
function AttackBehavior.on_touch_ended(self)
  self.pressing:set(false)
  local t = self:now_of(); if t == nil then return end
  local result = self.gesture:finish(t)
  if result == "tap" then
    if not self.auto_fired then self:send("attack") end
  elseif result == "long" then
    local gun = self:current_gun()
    if gun and not gun.Auto then self:send("reload") end
  end
end

--- 绑按压：触摸开始/结束与按压期帧订阅；没有触摸事件时退回单击。
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
  else
    ctx.connect(ps, button.OnClicked, function() self:send("attack") end)
  end
end

--- 建攻击键节点：布局块、按钮、标签与两个投影，然后绑按压。
---@param self AttackHandle
---@param ps table phase scope
function AttackBehavior.mount_control(self, ps)
  local ctx = self.ctx
  local rect = attack_rect(ctx)
  if rect == nil then
    return
  end
  local screen = ctx.root_node and ctx.root_node.FindFirstChild and ctx.root_node:FindFirstChild("ScreenMain", true)
  local control = ctx.create_node(ps, "EUILayout", {
    Name = "AttackControl",
    Parent = screen or nil,
    Position = ViewUtil.vec2(rect.x, rect.y),
    Size = ViewUtil.vec2(rect.w, rect.h),
  })
  control.TouchEnabled = false
  control.Visible = true
  local button = ctx.create_node(ps, "EUIButton", {
    Name = "BtnAttack",
    Parent = control,
    Position = ViewUtil.vec2(rect.x, rect.y),
    Size = ViewUtil.vec2(rect.w, rect.h),
    ButtonText = "",
  })
  button.TouchEnabled = false
  button.Visible = true
  local screen_open = ctx.store.hud_visible
  ps:effect("AttackEnabled", function(es)
    button.TouchEnabled = es:d(screen_open) == true
  end)
  local label = ctx.create_node(ps, "EUITextLabel", {
    Name = "AttackLabel",
    Parent = control,
    Position = button.Position,
    Size = button.Size,
    Text = "攻击",
  })
  label.TouchEnabled = false

  ps:effect("AttackCaption", function(es)
    local weapon_id = ViewUtil.equipped_weapon(es:d(ctx.store.item_bar))
    label.Text = is_gun(weapon_id) and "射击" or "攻击"
  end)

  self.button, self.label = button, label
  self.pressing = State.new("AttackView.pressing", false)
  self.auto_fired = false
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

--- 伤害飘字：按暴击着色新建一个文本节点。
---@param self AttackHandle
---@param es table EffectScope
function AttackBehavior.on_damage_float(self, es)
  local notice = es:d(self.damage_notice)
  if type(notice) ~= "table" then return end
  local node = self.ctx.create_node(es, "EUITextLabel", {
    Name = "DamageFloat",
    Text = tostring(notice.amount),
    Position = ViewUtil.vec2(0, 0),
    Size = ViewUtil.vec2(120, 40),
  })
  node.TextColor = ViewUtil.color(notice.critical and { 255, 214, 74, 255 } or { 255, 255, 255, 255 })
  node.TouchEnabled = false
  node.Visible = true
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
