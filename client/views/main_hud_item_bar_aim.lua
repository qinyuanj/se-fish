-- 主 HUD 道具栏的瞄准与投掷行为（#412 从 main_hud_item_bar_view 拆出，归属 L2 client.views）：
-- 爆炸物点按直投 / 长按瞄准的手势判定、遮罩与投掷上行；格位同步与拖拽仍留在视图模块。
-- 行为表由视图模块在造句柄时并入，方法沿用同一套 self 约定。

local GameCfg = require("common.game_cfg")
local Number = require("common.number")
local ViewUtil = require("client.views.view_util")
local HudWidgets = require("client.views.hud_widgets")

local MainHudItemBarAim = {}

--- 瞄准遮罩的半透明底色：只服务长按瞄准，随本模块迁移。
local AIM_NORMAL = { 30, 40, 30, 40 }
local AIM_PRESS = { 30, 40, 30, 60 }

local Behavior = {}

function MainHudItemBarAim.default_resolve_aim_target(pos)
  if pos == nil then
    return nil
  end
  local ok_ray, ray = pcall(function() -- 宿主 CameraService 未就绪或射线转换失败时安全回退无目标直投
    -- 宿主 CameraService 不在引擎存根里，按 any 标注避免诊断假阳性（拆分前由诊断基线压住）。
    ---@type any
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
    ---@type any 宿主 PhysicsService 不在引擎存根里，同上按 any 标注。
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

--- 该格当前是否为爆炸物（决定点按直投 / 长按瞄准）。
---@param self MainHudItemBarHandle
---@param index number
---@return boolean
function Behavior.is_explosive_slot(self, index)
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
function Behavior.consume_throw_click(self, index)
  local handled = self.throw_handled
  if handled ~= nil and handled.index == index and handled.valid then
    handled.valid = false
    return true
  end
  return false
end

--- 默认投掷上行：带单调序号，目标可选。
---@param self MainHudItemBarHandle
---@param slot number
---@param target table|nil
function Behavior.emit_throw(self, slot, target)
  self.weapon_seq = self.weapon_seq + 1
  local payload = { action = "throw", slot = slot, seq = self.weapon_seq }
  if type(target) == "table" then
    payload.target = target
  end
  ViewUtil.fire_re("WeaponAction", payload, "[MainHudItemBarView]")
end

--- 爆炸物点按 / 长按手势判定：点按直投，长按进瞄准。
---@param self MainHudItemBarHandle
---@param slot_index number
---@param ended any
function Behavior.apply_press_gesture(self, slot_index, ended)
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

--- 关屏或展开背包时收掉拖拽 / 瞄准态，避免越界手势残留。
---@param self MainHudItemBarHandle
---@param hud_visible boolean
---@param bp_open boolean
function Behavior.refresh_aim_state(self, hud_visible, bp_open)
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

--- 瞄准落点：读当前瞄准格并收起遮罩，命中则投掷。
---@param self MainHudItemBarHandle
---@param touch any
function Behavior.on_aim_touch_ended(self, touch)
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
function Behavior.mount_aim_overlay(self, ps)
  if self.resolution == nil then return end; local w, h = self.resolution.x, self.resolution.y
  local ctx = self.ctx
  local overlay = HudWidgets.button(ctx, ps, {
    name = "ThrowAimOverlay", x = w / 2, y = h / 2, w = w, h = h,
    normal = AIM_NORMAL, press = AIM_PRESS,
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

---@param self MainHudItemBarHandle
function Behavior.bind_aim_phase(self)
  local aim_active = self.s:memo("ThrowAimActive", function(ms)
    return ViewUtil.overlay_active(ms, self.ctx.store, self.aim_slot, self.backpack_open)
  end)
  self.s:phase("ThrowAimPhase", aim_active, function(ps)
    self:mount_aim_overlay(ps)
  end)
end

MainHudItemBarAim.Behavior = Behavior

return MainHudItemBarAim
