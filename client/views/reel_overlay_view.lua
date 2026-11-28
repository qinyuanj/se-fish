local GameCfg = require("common.game_cfg")
local RateLimit = require("common.rate_limit")
local ReelDisplay = require("common.reel_display")
local Spoke = require("common.packages.spoke.api")
local Tokens = require("client.ui.tokens")
local Layout = require("client.ui.layout")
local Primitives = require("client.ui.primitives")
local Controls = require("client.ui.controls")
local ViewUtil = require("client.views.view_util")

local State = Spoke.State
local ReelOverlayView = {}

-- 中下方安全带（y ∈ [176, 272]）：稳避 EquipBottom (<=168) 与两档分辨率下的 CenterClear (>=283.5)。
local PANEL_MAX_W = 720
local PANEL_H = 96
local PANEL_BOTTOM = 176
local CLOSE_W = 160
local CLOSE_H = 56
local PAD_X = 20
local GAP_X = 16

-- 收线浮层句柄：session / aggregator / display 与节点、ctx、scope 都留在句柄上；
-- 方法名沿用拆分前的局部函数名，调用方照旧用 :method(...)。
---@class ReelOverlayHandle: table<string, any>
---@type ReelOverlayHandle
local ReelBehavior = {}

local function send_reel(ctx, payload)
  if payload == nil then return end
  local services = ctx.services or {}
  if type(services.send_reel) == "function" then
    services.send_reel(payload)
    return
  end
  local ok, err = pcall(function()
    local Re = require("common.re_util"):get_re("ReelInRE")
    if Re and type(Re.FireServer) == "function" then Re:FireServer(payload) end
  end)
  if not ok then
    print("[ReelOverlayView] 发送 ReelInRE 失败", tostring(err))
  end
end

local function send_close(ctx, payload)
  local services = ctx.services or {}
  if type(services.send_close) == "function" then
    services.send_close(payload)
    return
  end
  local ok, err = pcall(function()
    local Re = require("common.re_util"):get_re("CloseReelIn")
    if Re and type(Re.FireServer) == "function" then Re:FireServer(payload) end
  end)
  if not ok then
    print("[ReelOverlayView] 发送 CloseReelIn 失败", tostring(err))
  end
end

local function valid_session(id)
  return type(id) == "string" and id ~= ""
end

local function valid_res(raw)
  if type(raw) ~= "table" and type(raw) ~= "userdata" then return nil end
  local ok_x, x = pcall(function() return raw.x end)
  local ok_y, y = pcall(function() return raw.y end)
  if ok_x and ok_y and type(x) == "number" and x == x and math.abs(x) ~= math.huge
      and type(y) == "number" and y == y and math.abs(y) ~= math.huge and x > 0 and y > 0 then
    return { x = x, y = y }
  end
  return nil
end

--- pcall 一次分辨率读取：抛错时按调用点打日志，读取成功但格式非法时静默返回 nil。
---@param loader fun(): any
---@param failure_text string 日志正文，如 "读取分辨率失败"
---@return { x: number, y: number }|nil
local function try_resolution(loader, failure_text)
  local ok, raw = pcall(loader)
  if not ok then
    print("[ReelOverlayView] " .. failure_text, tostring(raw))
    return nil
  end
  return valid_res(raw)
end

--- 读宿主 EUI 的设备分辨率原始值；宿主未就绪时返回 nil。
---@return any
local function host_resolution()
  ---@type any
  local players = game:GetService("Players")
  local lp = players and players["LocalPlayer"] or nil
  local eui_mgr = lp and lp.PlayerGui and lp.PlayerGui.EuiManager or nil
  return eui_mgr and eui_mgr:GetDeviceResolution() or nil
end

--- 依次尝试 options / services / 宿主注入的分辨率来源，全部不可用时返回 nil。
---@param ctx table
---@param options table|nil
---@return { x: number, y: number }|nil
local function get_resolution(ctx, options)
  if type(options) == "table" and type(options.get_resolution) == "function" then
    local resolved = try_resolution(options.get_resolution, "读取分辨率失败")
    if resolved ~= nil then return resolved end
  end
  local services = type(ctx) == "table" and ctx.services or nil
  if type(services) == "table" and type(services.get_device_resolution) == "function" then
    local resolved = try_resolution(services.get_device_resolution, "读取分辨率失败")
    if resolved ~= nil then return resolved end
  end
  if game ~= nil then
    local resolved = try_resolution(host_resolution, "读取宿主分辨率失败")
    if resolved ~= nil then return resolved end
  end
  print("[ReelOverlayView] 未获取到有效设备分辨率，返回 nil")
  return nil
end

local function resolve_clock(ctx)
  return ViewUtil.resolve_clock(ctx, "ReelOverlayView")
end

local function read_now(clock_now)
  return ViewUtil.read_now(clock_now, "ReelOverlayView")
end

--- 浮层可见性判据：存活、处于上钩态，且不是已关闭的收线会话。
---@param self ReelOverlayHandle
---@param ms table
---@param store table
---@return boolean
function ReelBehavior.visible(self, ms, store)
  local cast = ms:d(store.cast)
  local survival = ms:d(store.survival)
  local closed_session = ms:d(self.closed)
  local alive = type(survival) ~= "table" or survival.phase == nil or survival.phase == "alive"
  return alive and type(cast) == "table" and cast.phase == "hooked"
    and valid_session(cast.reelSession) and cast.reelSession ~= closed_session
end

--- 读取注入时钟的当前时刻，失败返回 nil。
---@param self ReelOverlayHandle
---@return number|nil
function ReelBehavior.now_of(self)
  return read_now(self.clock_now)
end

--- 把百分比写进进度条与提示行；文案判定沿用拆分前的规则。
---@param self ReelOverlayHandle
---@param value number
---@param current_cast table|nil
function ReelBehavior.render_progress(self, value, current_cast)
  local current = current_cast or self.ctx.store.cast:now() or {}
  local pct_int = math.floor(value + 0.5)
  if self.bar ~= nil and value ~= self.last_percent then
    self.last_percent = value
    self.bar.Percent = value
    if self.bar_label ~= nil then
      self.bar_label.Text = tostring(pct_int) .. "%"
    end
  end
  local text = current.phase == "landed" and "鱼已上岸"
    or (self.last_payload and self.last_payload.action == "started" and GameCfg.HookAlert.Text)
    or ("收线 " .. tostring(pct_int) .. "%")
  if self.hint ~= nil and text ~= self.last_hint_text then
    self.last_hint_text = text
    self.hint.Text = text
  end
end

--- 夹紧并记录当前收线百分比，非有限数值直接忽略。
---@param self ReelOverlayHandle
---@param value any
function ReelBehavior.set_progress(self, value)
  if type(value) == "number" and value == value then
    self.current_progress = math.max(0, math.min(100, value))
    self:render_progress(self.current_progress)
  end
end

--- 懒建收线显示插值；时钟缺失时返回 nil。
---@param self ReelOverlayHandle
---@param now number|nil
---@return table|nil
function ReelBehavior.ensure_display(self, now)
  if self.display == nil and now ~= nil then self.display = ReelDisplay.new(now, GameCfg.ReelIn) end
  return self.display
end

--- 切到新的收线会话；会话非法或已关闭时返回 false。
---@param self ReelOverlayHandle
---@param id string
---@return boolean
function ReelBehavior.set_session(self, id)
  if not valid_session(id) or self.closed:now() == id then return false end
  if self.session == id then return true end
  self.session = id
  self.aggregator = RateLimit.new_aggregator({ session_id = id, AggregateSec = GameCfg.HighFreqInput.AggregateSec })
  local now = self:now_of()
  self.display = now ~= nil and ReelDisplay.new(now, GameCfg.ReelIn) or nil
  self:set_progress(GameCfg.ReelIn.Initial)
  return true
end

--- 把当前聚合的点击量发给服务端；final 为真时强制冲刷剩余计数。
---@param self ReelOverlayHandle
---@param final boolean
function ReelBehavior.flush(self, final)
  local aggregator = self.aggregator
  if not aggregator then return end
  local now = self:now_of()
  local payload = final and aggregator:flush() or (now ~= nil and aggregator:collect(now) or nil)
  if payload then
    if self.display and now ~= nil then self.display:sent(payload.q, payload.n, now) end
    send_reel(self.ctx, payload)
  end
end

--- 结束当前会话并标记已关闭；id 与会话不符时不动。
---@param self ReelOverlayHandle
---@param id string|nil
---@param notify_server boolean
---@return boolean
function ReelBehavior.clear(self, id, notify_server)
  if not self.session or (id ~= nil and id ~= self.session) then return false end
  if notify_server then self:flush(true); send_close(self.ctx, { session = self.session }) end
  self.closed:set(self.session)
  self.session = nil
  self.aggregator = nil
  self.display = nil
  return true
end

--- 记一次收线点击并推进显示进度。
---@param self ReelOverlayHandle
---@param id string|nil
---@return boolean
function ReelBehavior.click(self, id)
  if not self.session or (id ~= nil and id ~= self.session) or not self.aggregator then return false end
  local now = self:now_of(); if now == nil then return false end
  self.aggregator:click(now)
  local active_display = self:ensure_display(now)
  if active_display then active_display:click(now); self:set_progress(active_display:value(now)) end
  return true
end

--- 结束收线并向服务端确认。
---@param self ReelOverlayHandle
---@param id string|nil
---@return boolean
function ReelBehavior.request_close(self, id)
  return self:clear(id, true)
end

--- 当前是否有活跃会话（id 为 nil 时只看有无会话）。
---@param self ReelOverlayHandle
---@param id string|nil
---@return boolean
function ReelBehavior.is_active(self, id)
  return self.session ~= nil and (id == nil or id == self.session)
end

--- 读取当前收线百分比：优先用插值显示值，没有则用本地记录值。
---@param self ReelOverlayHandle
---@return number
function ReelBehavior.progress(self)
  local now = self.display and self:now_of() or nil
  if self.display and now ~= nil then return self.display:value(now) end
  return self.current_progress
end

--- 把点击 / 结束 / 活跃 / 进度四类回调挂到外部 controller 上，同时记住函数身份便于清理比对。
---@param self ReelOverlayHandle
function ReelBehavior.bind_controller(self)
  local controller = self.controller
  self.controller_fns = {
    click = function(id) return self:click(id) end,
    close = function(id) return self:request_close(id) end,
    active = function(id) return self:is_active(id) end,
    progress = function() return self:progress() end,
  }
  controller.click, controller.close = self.controller_fns.click, self.controller_fns.close
  controller.active, controller.progress = self.controller_fns.active, self.controller_fns.progress
end

--- 只清掉仍然是自己挂上去的回调，避免覆盖外部替换过的实现。
---@param self ReelOverlayHandle
function ReelBehavior.release_controller(self)
  local controller, fns = self.controller, self.controller_fns
  if controller == nil or fns == nil then return end
  if controller.click == fns.click then controller.click = nil end
  if controller.close == fns.close then controller.close = nil end
  if controller.active == fns.active then controller.active = nil end
  if controller.progress == fns.progress then controller.progress = nil end
end

--- 按设备分辨率建纯 EUILayout 全屏点击层、深海蓝进度胶囊与「结束收线」按钮；分辨率不可用时整层不建。
---@param self ReelOverlayHandle
function ReelBehavior.create_nodes(self)
  local scope, ctx = self.scope, self.ctx
  local resolution = get_resolution(ctx, self.options)
  if resolution == nil then
    return
  end

  -- 全屏收线点击捕获层：唯一合法实现为纯 EUILayout（杜绝左下角黑块）。
  Primitives.dismiss_mask(scope, ctx, {
    name = "ReelMask",
    width = resolution.x,
    height = resolution.y,
    z_order = Tokens.Z.OVERLAY_MASK,
    swallow = false,
    on_click = function()
      self:click(nil)
    end,
  })

  local panel_w = math.min(PANEL_MAX_W, Layout.snap4(resolution.x - 64, 480))
  local panel_rect = Layout.bottom_center(resolution.x, PANEL_BOTTOM, panel_w, PANEL_H)
  local panel = Primitives.capsule(scope, ctx, {
    name = "ReelPanel",
    rect = panel_rect,
    z_order = Tokens.Z.OVERLAY_PANEL,
    visible = true,
  })
  panel.TouchEnabled = true
  panel.SwallowTouchEnabled = true

  local left_w = panel_w - PAD_X * 2 - CLOSE_W - GAP_X
  self.hint = Primitives.label(scope, ctx, {
    name = "HookHint",
    parent = panel,
    rect = Layout.from_top_left(PANEL_H, PAD_X, 8, left_w, 32),
    text = GameCfg.HookAlert.Text,
    font_size = Tokens.FONT_SIZE.BODY,
    bold = true,
    color = Tokens.COLOR.TEXT_GOLD,
    outline = true,
    outline_color = Tokens.COLOR.OUTLINE_DARK,
    align_x = 0,
    align_y = 1,
    z_order = 1,
  })

  local init_pct = GameCfg.ReelIn.Initial
  local progress = Controls.progress_bar(scope, ctx, {
    name = "ReelBar",
    parent = panel,
    rect = Layout.from_top_left(PANEL_H, PAD_X, 48, left_w, 36),
    fill_color = Tokens.COLOR.REEL_FILL,
    percent = init_pct,
    text = tostring(math.floor(init_pct + 0.5)) .. "%",
    font_size = Tokens.FONT_SIZE.CAPTION,
    z_order = 1,
  })
  self.bar = progress.fill
  self.bar_label = progress.label

  self.close = Controls.button(scope, ctx, {
    name = "BtnReelClose",
    parent = panel,
    rect = Layout.from_top_right(panel_w, PANEL_H, PAD_X, 20, CLOSE_W, CLOSE_H),
    text = "结束收线",
    variant = "blue",
    font_size = Tokens.FONT_SIZE.BODY,
    z_order = 2,
    on_click = function()
      self:request_close(nil)
    end,
  })
end

--- CastState 上行：上钩进新会话，离开上钩清会话（不回声服务端）。
---@param self ReelOverlayHandle
---@param next_cast any
function ReelBehavior.apply_cast_state(self, next_cast)
  if type(next_cast) == "table" and next_cast.phase == "hooked" and valid_session(next_cast.reelSession) then
    if next_cast.reelSession ~= self.closed:now() then self:set_session(next_cast.reelSession) end
  elseif type(next_cast) == "table" and next_cast.phase ~= "hooked" then
    self:clear(self.session, false)
  end
end

--- ReelInRE 上行：权威进度覆盖插值，结算 / 脱钩即清会话。
---@param self ReelOverlayHandle
---@param payload any
function ReelBehavior.apply_reel_payload(self, payload)
  if type(payload) ~= "table" or not valid_session(payload.session) then return end
  if payload.action == "started" then
    if not self:set_session(payload.session) then return end
  elseif self.session ~= payload.session then
    return
  end
  self.last_payload = payload
  if payload.action == "progress" or payload.action == "started" then
    local now = self:now_of()
    local active_display = now ~= nil and self:ensure_display(now) or nil
    if active_display and now ~= nil then active_display:authority(now, payload.progress, payload.q) end
  end
  self:set_progress(payload.progress)
  if payload.action == "landed" or payload.action == "unhooked" then self:clear(payload.session, false) end
end

--- 服务端上行分发：CastState 与 ReelInRE 各自处理，其余通道忽略。
---@param self ReelOverlayHandle
---@param event any
function ReelBehavior.on_server_event(self, event)
  if type(event) ~= "table" then return end
  if event.channel == "CastState" then
    self:apply_cast_state(event.payload)
    return
  end
  if event.channel ~= "ReelInRE" then return end
  self:apply_reel_payload(event.payload)
end

--- 每帧：冲刷聚合点击，并按插值推进进度条。
---@param self ReelOverlayHandle
function ReelBehavior.on_frame(self)
  self:flush(false)
  if self.display then
    local now = self:now_of()
    if now ~= nil then self:set_progress(self.display:value(now)) end
  end
end

--- 收线下行状态变化时重绘提示行（不重建节点）。
---@param self ReelOverlayHandle
---@param es table
function ReelBehavior.on_cast_refresh(self, es)
  local current = es:d(self.ctx.store.cast) or {}
  self:render_progress(self.current_progress, current)
end

--- 卸载：冲刷剩余点击、摘掉自己挂的 controller 回调、释放本地聚合与显示状态。
---@param self ReelOverlayHandle
function ReelBehavior.release(self)
  self:flush(true)
  self:release_controller()
  self.aggregator = nil
  self.display = nil
  self.session = nil
end

--- 装配浮层：建节点、挂回调、订阅上行与帧更新，全部由 scope 托管。
---@param self ReelOverlayHandle
---@param scope table
---@param ctx table
function ReelBehavior.mount_view(self, scope, ctx)
  self.scope, self.ctx = scope, ctx
  self.clock_now = resolve_clock(ctx)
  local cast = ctx.store.cast:now() or {}
  local session = valid_session(cast.reelSession) and cast.reelSession or nil
  self.session = session
  self.aggregator = session and RateLimit.new_aggregator({
    session_id = session, AggregateSec = GameCfg.HighFreqInput.AggregateSec,
  }) or nil
  local init_now = session and self:now_of() or nil
  self.display = (session and init_now ~= nil) and ReelDisplay.new(init_now, GameCfg.ReelIn) or nil
  self.controller = self.options.controller or (ctx.services and ctx.services.reel) or {}

  self:create_nodes()
  self:bind_controller()

  scope:subscribe(ctx.store.on_server_event, function(event) self:on_server_event(event) end)
  scope:subscribe(ctx.clock.on_frame, function() self:on_frame() end)
  scope:effect("ReelOverlayCastRefresh", function(es) self:on_cast_refresh(es) end)
  scope:on_cleanup(function() self:release() end)
end

--- 造浮层句柄：状态字段留在句柄上，方法由 ReelBehavior 提供。
---@param options table|nil
---@return ReelOverlayHandle
local function new_view(options)
  ---@type ReelOverlayHandle
  local view = {
    options = type(options) == "table" and options or {},
    closed = State.new("ReelOverlay.closedSession", nil),
    clock_now = nil,
    session = nil,
    aggregator = nil,
    display = nil,
    controller = nil,
    controller_fns = nil,
    bar = nil,
    bar_label = nil,
    hint = nil,
    close = nil,
    current_progress = GameCfg.ReelIn.Initial,
    last_payload = nil,
    last_percent = nil,
    last_hint_text = nil,
  }
  for name, method in pairs(ReelBehavior) do
    view[name] = method
  end
  return view
end

--- 返回可供 RootView.mount({ overlays = { reel = ... } }) 直接注册的浮层 spec。
---@param options table|nil
---@return table
function ReelOverlayView.spec(options)
  local view = new_view(options)
  return {
    name = "ReelOverlay",
    when = function(ms, store) return view:visible(ms, store) end,
    mount = function(scope, ctx) view:mount_view(scope, ctx) end,
  }
end

return ReelOverlayView
