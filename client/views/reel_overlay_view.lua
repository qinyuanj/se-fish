local GameCfg = require("common.game_cfg")
local RateLimit = require("common.rate_limit")
local ReelDisplay = require("common.reel_display")
local Spoke = require("common.packages.spoke.api")

local State = Spoke.State
local ReelOverlayView = {}
local BLOCK_IMAGE = "official://image/11017"
---@type fun(ctx: table): fun(): number
local resolve_clock
---@type fun(clock_now: fun(): number): number|nil
local read_now
---@type fun(ctx: table, options?: table): { x: number, y: number }|nil
local get_resolution

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

local function make(scope, ctx, kind, parent, name, x, y, width, height, props)
  props = props or {}
  props.Parent = parent
  props.Name = name
  props.Position = Vector2.New(x, y)
  props.Size = Vector2.New(width, height)
  local node = ctx.create_node(scope, kind, props)
  node.TouchEnabled = kind == "EUIButton"
  node.SwallowTouchEnabled = false
  return node
end

local function valid_session(id)
  return type(id) == "string" and id ~= ""
end

function ReelOverlayView.spec(options)
  options = type(options) == "table" and options or {}
  local closed = State.new("ReelOverlay.closedSession", nil)
  return {
    name = "ReelOverlay",
    when = function(ms, store)
      local cast = ms:d(store.cast)
      local survival = ms:d(store.survival)
      local closed_session = ms:d(closed)
      local alive = type(survival) ~= "table" or survival.phase == nil or survival.phase == "alive"
      return alive and type(cast) == "table" and cast.phase == "hooked"
        and valid_session(cast.reelSession) and cast.reelSession ~= closed_session
    end,
    mount = function(scope, ctx)
      local clock_now = resolve_clock(ctx)
      local function now_of() return read_now(clock_now) end
      local cast = ctx.store.cast:now() or {}
      local session = valid_session(cast.reelSession) and cast.reelSession or nil
      local aggregator = session and RateLimit.new_aggregator({
        session_id = session, AggregateSec = GameCfg.HighFreqInput.AggregateSec,
      }) or nil
      local init_now = session and now_of() or nil
      local display = (session and init_now ~= nil) and ReelDisplay.new(init_now, GameCfg.ReelIn) or nil
      local current_progress = GameCfg.ReelIn.Initial
      local last_payload = nil
      local controller = options.controller or (ctx.services and ctx.services.reel) or {}

      local resolution = get_resolution(ctx, options)
      local bar, hint, close
      if resolution ~= nil then
        local mask = make(scope, ctx, "EUIImage", ctx.root_node, "ReelMask", 0, 0, resolution.x, resolution.y, {
          Image = BLOCK_IMAGE, Color = Color.New(0, 0, 0, 1), Visible = true,
        })
        local bar_bg = make(scope, ctx, "EUIImage", mask, "ReelBarBg", 660, 820, 600, 34, {
          Image = BLOCK_IMAGE, Color = Color.New(20, 30, 40, 220), Visible = true,
        })
        bar = make(scope, ctx, "EUIImage", bar_bg, "ReelBar", 0, 0, 600, 34, {
          Image = "official://image/30007", Direction = 0, Percent = GameCfg.ReelIn.Initial,
          Color = Color.New(36, 200, 94, 255), Visible = true,
        })
        hint = make(scope, ctx, "EUITextLabel", mask, "HookHint", 660, 740, 600, 60, {
          Text = GameCfg.HookAlert.Text, FontSize = 32, TextColor = Color.New(255, 220, 40, 255), Visible = true,
        })
        close = make(scope, ctx, "EUIButton", mask, "BtnReelClose", 840, 900, 240, 70, {
          ButtonText = "", NormalImage = BLOCK_IMAGE, PressImage = BLOCK_IMAGE,
          Color = Color.New(60, 80, 100, 255), Visible = true,
        })
        make(scope, ctx, "EUITextLabel", close, "BtnReelCloseLabel", 0, 0, 240, 70, {
          Text = "结束收线", FontSize = 30, TextColor = Color.New(255, 255, 255, 255), Visible = true,
        })
      end
      local last_percent, last_hint_text = nil, nil
      local function render_progress(value, current_cast)
        local current = current_cast or ctx.store.cast:now() or {}
        if bar ~= nil and value ~= last_percent then
          last_percent = value
          bar.Percent = value
        end
        local text = current.phase == "landed" and "鱼已上岸"
          or (last_payload and last_payload.action == "started" and GameCfg.HookAlert.Text)
          or ("收线 " .. tostring(math.floor(value + 0.5)) .. "%")
        if hint ~= nil and text ~= last_hint_text then
          last_hint_text = text
          hint.Text = text
        end
      end
      local function set_progress(value)
        if type(value) == "number" and value == value then
          current_progress = math.max(0, math.min(100, value))
          render_progress(current_progress)
        end
      end
      local function ensure_display(now)
        if display == nil and now ~= nil then display = ReelDisplay.new(now, GameCfg.ReelIn) end
        return display
      end
      local function set_session(id)
        if not valid_session(id) or closed:now() == id then return false end
        if session == id then return true end
        session = id
        aggregator = RateLimit.new_aggregator({ session_id = id, AggregateSec = GameCfg.HighFreqInput.AggregateSec })
        local now = now_of(); display = now ~= nil and ReelDisplay.new(now, GameCfg.ReelIn) or nil
        set_progress(GameCfg.ReelIn.Initial)
        return true
      end
      local function flush(final)
        if not aggregator then return end
        local now = now_of()
        local payload = final and aggregator:flush() or (now ~= nil and aggregator:collect(now) or nil)
        if payload then
          if display and now ~= nil then display:sent(payload.q, payload.n, now) end
          send_reel(ctx, payload)
        end
      end
      local function clear(id, notify_server)
        if not session or (id ~= nil and id ~= session) then return false end
        if notify_server then flush(true); send_close(ctx, { session = session }) end
        closed:set(session)
        session = nil
        aggregator = nil
        display = nil
        return true
      end
      local click_fn = function(id)
        if not session or (id ~= nil and id ~= session) or not aggregator then return false end
        local now = now_of(); if now == nil then return false end
        aggregator:click(now)
        local active_display = ensure_display(now)
        if active_display then active_display:click(now); set_progress(active_display:value(now)) end
        return true
      end
      local close_fn = function(id) return clear(id, true) end
      local active_fn = function(id) return session ~= nil and (id == nil or id == session) end
      local progress_fn = function()
        local now = display and now_of() or nil
        if display and now ~= nil then return display:value(now) end
        return current_progress
      end
      controller.click, controller.close, controller.active, controller.progress = click_fn, close_fn, active_fn, progress_fn

      scope:subscribe(ctx.store.on_server_event, function(event)
        if type(event) ~= "table" then return end
        if event.channel == "CastState" then
          local next_cast = event.payload
          if type(next_cast) == "table" and next_cast.phase == "hooked" and valid_session(next_cast.reelSession) then
            if next_cast.reelSession ~= closed:now() then set_session(next_cast.reelSession) end
          elseif type(next_cast) == "table" and next_cast.phase ~= "hooked" then
            clear(session, false)
          end
          return
        end
        if event.channel ~= "ReelInRE" then return end
        local payload = event.payload
        if type(payload) ~= "table" or not valid_session(payload.session) then return end
        if payload.action == "started" then
          if not set_session(payload.session) then return end
        elseif session ~= payload.session then
          return
        end
        last_payload = payload
        if payload.action == "progress" or payload.action == "started" then
          local now = now_of()
          local active_display = now ~= nil and ensure_display(now) or nil
          if active_display and now ~= nil then active_display:authority(now, payload.progress, payload.q) end
        end
        set_progress(payload.progress)
        if payload.action == "landed" or payload.action == "unhooked" then clear(payload.session, false) end
      end)

      scope:subscribe(ctx.clock.on_frame, function()
        flush(false)
        if display then
          local now = now_of(); if now ~= nil then set_progress(display:value(now)) end
        end
      end)
      scope:effect("ReelOverlayCastRefresh", function(es)
        local current = es:d(ctx.store.cast) or {}
        render_progress(current_progress, current)
      end)
      if close ~= nil then
        ctx.connect(scope, close.OnClicked, function() clear(nil, true) end)
      end
      scope:on_cleanup(function()
        flush(true)
        if controller.click == click_fn then controller.click = nil end
        if controller.close == close_fn then controller.close = nil end
        if controller.active == active_fn then controller.active = nil end
        if controller.progress == progress_fn then controller.progress = nil end
        -- 释放本地聚合与显示状态，等待下次上钩重建
        -- 不保留任何悬空引用
        aggregator = nil
        display = nil
        session = nil
      end)
    end,
  }
end

resolve_clock = function(ctx)
  local services = type(ctx) == "table" and ctx.services or nil
  if type(services) == "table" and type(services.now) == "function" then return services.now end
  local clock = type(ctx) == "table" and ctx.clock or nil
  if type(clock) == "table" and type(clock.now) == "function" then return clock.now end
  error("[ReelOverlayView] 缺少注入时钟（services.now 或 ctx.clock.now）", 3)
end

read_now = function(clock_now)
  local ok, value = pcall(clock_now)
  if ok and type(value) == "number" and value == value and math.abs(value) ~= math.huge then return value end
  print("[ReelOverlayView] 读取时钟失败", tostring(value))
  return nil
end

local function valid_res(raw)
  if type(raw) ~= "table" and type(raw) ~= "userdata" then return nil end
  local ok_x, x = pcall(function() return raw.x end)
  local ok_y, y = pcall(function() return raw.y end)
  if ok_x and ok_y and type(x) == "number" and x == x and math.abs(x) ~= math.huge and type(y) == "number" and y == y and math.abs(y) ~= math.huge and x > 0 and y > 0 then
    return { x = x, y = y }
  end
  return nil
end

get_resolution = function(ctx, options)
  if type(options) == "table" and type(options.get_resolution) == "function" then
    local ok, raw = pcall(options.get_resolution)
    if ok then local r = valid_res(raw); if r ~= nil then return r end else print("[ReelOverlayView] 读取分辨率失败", tostring(raw)) end
  end
  local services = type(ctx) == "table" and ctx.services or nil
  if type(services) == "table" and type(services.get_device_resolution) == "function" then
    local ok, raw = pcall(services.get_device_resolution)
    if ok then local r = valid_res(raw); if r ~= nil then return r end else print("[ReelOverlayView] 读取分辨率失败", tostring(raw)) end
  end
  if game ~= nil then
    local ok, raw = pcall(function()
      ---@type any
      local players = game:GetService("Players")
      local lp = players and players["LocalPlayer"] or nil
      local eui_mgr = lp and lp.PlayerGui and lp.PlayerGui.EuiManager or nil
      return eui_mgr and eui_mgr:GetDeviceResolution() or nil
    end)
    if ok then local r = valid_res(raw); if r ~= nil then return r end else print("[ReelOverlayView] 读取宿主分辨率失败", tostring(raw)) end
  end
  print("[ReelOverlayView] 未获取到有效设备分辨率，返回 nil")
  return nil
end

return ReelOverlayView
