local GameCfg = require("common.game_cfg")
local RateLimit = require("common.rate_limit")
local ReelDisplay = require("common.reel_display")
local Spoke = require("common.packages.spoke.api")

local State = Spoke.State
local ReelOverlayView = {}
local BLOCK_IMAGE = "official://image/11017"

local function now_of(ctx)
  local services = ctx.services or {}
  if type(services.now) == "function" then
    local value = services.now()
    if type(value) == "number" then return value end
  end
  return ctx.clock and ctx.clock.now() or 0
end

local function send_reel(ctx, payload)
  if payload == nil then return end
  local services = ctx.services or {}
  if type(services.send_reel) == "function" then
    services.send_reel(payload)
    return
  end
  local ok, err = pcall(function()
    local Re = require("common.re_util"):GetRE("ReelInRE")
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
    local Re = require("common.re_util"):GetRE("CloseReelIn")
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
      local cast = ctx.store.cast:now() or {}
      local session = valid_session(cast.reelSession) and cast.reelSession or nil
      local aggregator = session and RateLimit.NewAggregator({
        SessionId = session, AggregateSec = GameCfg.HighFreqInput.AggregateSec,
      }) or nil
      local display = session and ReelDisplay.New(now_of(ctx), GameCfg.ReelIn) or nil
      local current_progress = GameCfg.ReelIn.Initial
      local last_payload = nil
      local controller = options.controller or (ctx.services and ctx.services.reel) or {}

      local mask = make(scope, ctx, "EUIImage", ctx.root_node, "ReelMask", 0, 0, 1920, 1080, {
        Image = BLOCK_IMAGE, Color = Color.New(0, 0, 0, 1), Visible = true,
      })
      local bar_bg = make(scope, ctx, "EUIImage", mask, "ReelBarBg", 660, 820, 600, 34, {
        Image = BLOCK_IMAGE, Color = Color.New(20, 30, 40, 220), Visible = true,
      })
      local bar = make(scope, ctx, "EUIImage", bar_bg, "ReelBar", 0, 0, 600, 34, {
        Image = "official://image/30007", Direction = 0, Percent = GameCfg.ReelIn.Initial,
        Color = Color.New(36, 200, 94, 255), Visible = true,
      })
      local hint = make(scope, ctx, "EUITextLabel", mask, "HookHint", 660, 740, 600, 60, {
        Text = GameCfg.HookAlert.Text, FontSize = 32, TextColor = Color.New(255, 220, 40, 255), Visible = true,
      })
      local close = make(scope, ctx, "EUIButton", mask, "BtnReelClose", 840, 900, 240, 70, {
        ButtonText = "", NormalImage = BLOCK_IMAGE, PressImage = BLOCK_IMAGE,
        Color = Color.New(60, 80, 100, 255), Visible = true,
      })
      make(scope, ctx, "EUITextLabel", close, "BtnReelCloseLabel", 0, 0, 240, 70, {
        Text = "结束收线", FontSize = 30, TextColor = Color.New(255, 255, 255, 255), Visible = true,
      })

      local last_percent, last_hint_text = nil, nil

      local function render_progress(value, current_cast)
        local current = current_cast or ctx.store.cast:now() or {}
        if value ~= last_percent then
          last_percent = value
          bar.Percent = value
        end
        local text = current.phase == "landed" and "鱼已上岸"
          or (last_payload and last_payload.action == "started" and GameCfg.HookAlert.Text)
          or ("收线 " .. tostring(math.floor(value + 0.5)) .. "%")
        if text ~= last_hint_text then
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

      local function set_session(id)
        if not valid_session(id) or closed:now() == id then return false end
        if session == id then return true end
        session = id
        aggregator = RateLimit.NewAggregator({ SessionId = id, AggregateSec = GameCfg.HighFreqInput.AggregateSec })
        display = ReelDisplay.New(now_of(ctx), GameCfg.ReelIn)
        set_progress(GameCfg.ReelIn.Initial)
        return true
      end

      local function flush(final)
        if not aggregator then return end
        local payload = final and aggregator:Flush() or aggregator:Collect(now_of(ctx))
        if payload then
          if display then display:Sent(payload.q, payload.n, now_of(ctx)) end
          send_reel(ctx, payload)
        end
      end

      local function clear(id, notify_server)
        if not session or (id ~= nil and id ~= session) then return false end
        if notify_server then
          flush(true)
          send_close(ctx, { session = session })
        end
        closed:set(session)
        session = nil
        aggregator = nil
        display = nil
        return true
      end

      local click_fn = function(id)
        if not session or (id ~= nil and id ~= session) or not aggregator then return false end
        local now = now_of(ctx)
        aggregator:Click(now)
        if display then
          display:Click(now)
          set_progress(display:Value(now))
        end
        return true
      end
      local close_fn = function(id) return clear(id, true) end
      local active_fn = function(id)
        return session ~= nil and (id == nil or id == session)
      end
      local progress_fn = function()
        return display and display:Value(now_of(ctx)) or GameCfg.ReelIn.Initial
      end
      controller.click = click_fn
      controller.close = close_fn
      controller.active = active_fn
      controller.progress = progress_fn

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
        if display and (payload.action == "progress" or payload.action == "started") then
          display:Authority(now_of(ctx), payload.progress, payload.q)
        end
        set_progress(payload.progress)
        if payload.action == "landed" or payload.action == "unhooked" then
          clear(payload.session, false)
        end
      end)

      scope:subscribe(ctx.clock.on_frame, function()
        flush(false)
        if display then set_progress(display:Value(now_of(ctx))) end
      end)
      scope:effect("ReelOverlayCastRefresh", function(es)
        local current = es:d(ctx.store.cast) or {}
        render_progress(current_progress, current)
      end)
      ctx.connect(scope, close.OnClicked, function() clear(nil, true) end)
      scope:on_cleanup(function()
        flush(true)
        if controller.click == click_fn then controller.click = nil end
        if controller.close == close_fn then controller.close = nil end
        if controller.active == active_fn then controller.active = nil end
        if controller.progress == progress_fn then controller.progress = nil end
        aggregator = nil
        display = nil
        session = nil
      end)
    end,
  }
end

return ReelOverlayView
