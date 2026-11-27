-- Spoke 相机距离投影视图（ADR-0032 / #297-B，归属 L2 client.views，取代旧 client/LocalAttr.lua）：
-- 订阅只读 ClientStore 的本地角色与归一化 CameraDistance，按角色体型缩放更新 MainCamera.Distance；
-- 若检测到玩家或其它系统手动修改过相机距离则自动让权，角色更换或作用域清理时恢复初始距离。

local Spoke = require("common.packages.spoke.api")
local BodyScale = require("common.body_scale")
local GameCfg = require("common.game_cfg")
local Number = require("common.number")
local ViewUtil = require("client.views.view_util")

local State = Spoke.State

local CameraZoomView = {}

local function resolve_target_distance(character, preset_distance)
  if Number.is_finite_number(preset_distance) and preset_distance > 0 then
    return preset_distance
  end
  if character == nil then
    return nil
  end
  local ok, raw = pcall(function() return character:GetAttribute("CameraDistance") end) -- 角色销毁瞬态读取属性可能抛错，安全忽略
  if not ok or not Number.is_finite_number(raw) or raw <= 0 then
    return nil
  end
  local base = GameCfg.Ability.BodyScale.CameraDistance
  if not Number.is_finite_number(base) or base <= 0 then
    return nil
  end
  return BodyScale.derive(BodyScale.sanitize(raw / base)).CameraDistance
end

local function default_get_camera()
  local ok, camera = pcall(function() -- 相机服务未就绪或切换瞬态可能抛错，安全忽略等待下一帧
    local camera_service = game:GetService("CameraService")
    return camera_service and camera_service.MainCamera or nil
  end)
  return ok and camera or nil
end

--- 创建纯相机投影控制器（无引擎全局耦合，可独立测试与挂载于 Spoke 作用域）。
function CameraZoomView.new_controller()
  local ctrl = {
    camera = nil,
    character = nil,
    last_distance = nil,
    original_distance = nil,
    yielded = nil,
  }

  function ctrl:release()
    if self.camera ~= nil and self.last_distance ~= nil then
      local ok, cur_distance = pcall(function() return self.camera.Distance end) -- 相机销毁瞬态读取可能抛错，安全忽略
      if ok and cur_distance == self.last_distance then
        pcall(function() self.camera.Distance = self.original_distance end) -- 相机已销毁时恢复距离允许安全忽略
      end
    end
    self.camera = nil
    self.character = nil
    self.last_distance = nil
    self.original_distance = nil
    self.yielded = nil
  end

  function ctrl:refresh(character, camera, preset_distance)
    if camera ~= self.camera or character ~= self.character then
      self:release()
      self.camera = camera
      self.character = character
      if camera ~= nil then
        local ok, dist = pcall(function() return camera.Distance end) -- 相机未就绪时安全降级为 nil
        self.original_distance = ok and dist or nil
      end
    end
    if character == nil or camera == nil or self.yielded then
      return false
    end
    if camera.TrackingUnit ~= nil and camera.TrackingUnit ~= character then
      return false
    end
    if self.last_distance ~= nil and camera.Distance ~= self.last_distance then
      self.yielded = true
      return false
    end
    local target = resolve_target_distance(character, preset_distance)
    if target == nil then
      return false
    end
    if self.last_distance ~= target then
      camera.Distance = target
      self.last_distance = target
    end
    return true
  end

  return ctrl
end

--- 挂载到 RootView / Spoke 作用域：响应角色与目标距离变化，并在活跃 Phase 内检测手动改距让权；清理时恢复原始距离。
---@param s table EffectBuilder
---@param ctx table { store, clock, ... }
---@param options table|nil { get_camera?: fun(): any }
function CameraZoomView.mount(s, ctx, options)
  options = options or {}
  local get_camera = options.get_camera or default_get_camera
  local ctrl = CameraZoomView.new_controller()
  local yielded_state = State.new("CameraZoomView.yielded", false)
  local last_error = nil

  local function sync(character, distance)
    local ok, err = pcall(function()
      ctrl:refresh(character, get_camera(), distance)
    end)
    if not ok then
      local text = tostring(err)
      if last_error ~= text then
        last_error = text
        print("[CameraZoomView] 相机刷新失败", last_error)
      end
    else
      last_error = nil
    end
    local next_yielded = ctrl.yielded == true
    if yielded_state:now() ~= next_yielded then
      yielded_state:set(next_yielded)
    end
  end

  s:effect("CameraZoomProjection", function(es)
    local character = es:d(ctx.store.local_character)
    local distance = es:d(ctx.store.camera_distance)
    sync(character, distance)
  end)

  -- 仅在主界面可见、存在本地角色且尚未让权的活跃 Phase 内按需订阅 on_frame，避免根作用域常驻空转
  local watch_active = s:memo("CameraZoomWatchActive", function(ms)
    local hud_visible = ctx.store.hud_visible == nil or ms:d(ctx.store.hud_visible) ~= false
    local character = ms:d(ctx.store.local_character)
    local yielded = ms:d(yielded_state)
    return hud_visible and character ~= nil and not yielded
  end)

  s:phase("CameraZoomWatchPhase", watch_active, function(ps)
    if ctx.clock ~= nil and ctx.clock.on_frame ~= nil then
      ps:subscribe(ctx.clock.on_frame, function()
        sync(ctx.store.local_character:now(), ctx.store.camera_distance:now())
      end)
    end
  end)

  s:on_cleanup(function()
    ctrl:release()
  end)

  return ctrl
end

--- 返回可供 RootView.mount({ hud = { ... } }) 直接注册的 HUD spec。
function CameraZoomView.spec(options)
  return ViewUtil.hud_spec("CameraZoom", CameraZoomView.mount, options)
end

return CameraZoomView
