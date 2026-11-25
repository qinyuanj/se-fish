
local GameCfg = require("common.game_cfg")
local Spoke = require("common.packages.spoke.api")
local ViewUtil = require("client.views.view_util")

local State = Spoke.State

local SurvivalOverlayView = {}

local COLOR_BLOCK = "official://image/11017"

local function services_of(ctx)
  return ctx.services or {}
end
local function now_of_fn(ctx) return ViewUtil.resolve_clock(ctx, "SurvivalOverlayView") end
local function read_now(clock_now) return ViewUtil.read_now(clock_now, "SurvivalOverlayView") end

local function send(ctx, seq, action, mode)
  local services = services_of(ctx)
  local payload = { action = action, mode = mode, seq = seq:now() }
  if type(services.send_survival) == "function" then
    services.send_survival(payload)
    return
  end
  local ok, err = pcall(function()
    local Re = require("common.re_util"):get_re("SurvivalAction")
    if Re and type(Re.FireServer) == "function" then
      Re:FireServer(payload)
    end
  end)
  if not ok then
    print("[SurvivalOverlayView] 发送 SurvivalAction 失败", tostring(action), tostring(err))
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

local function mount_banner(scope, ctx, survival, seq, noticed_dead, clock_now)
  local res = ViewUtil.get_resolution(ctx); if res == nil then return end
  local cx, cy = res.x / 2, res.y / 2
  local banner = make(scope, ctx, "EUIImage", ctx.root_node, "SurvivalBanner", cx - 320, cy - 90, 640, 180, {
    Color = Color.New(0, 0, 0, 160),
    Image = COLOR_BLOCK,
    Visible = true,
  })
  local title = make(scope, ctx, "EUITextLabel", banner, "SurvivalTitle", 0, -80, 640, 80, {
    Text = "",
    FontSize = 48,
    TextColor = Color.New(255, 80, 80, 255),
    LocalZOrder = 1,
    Visible = true,
  })
  local adrenaline = make(scope, ctx, "EUIButton", banner, "SurvivalAdrenaline", 10, 20, 300, 80, {
    ButtonText = "",
    NormalImage = COLOR_BLOCK,
    PressImage = COLOR_BLOCK,
    Color = Color.New(230, 120, 40, 255),
    Visible = false,
  })
  make(scope, ctx, "EUITextLabel", adrenaline, "SurvivalAdrenalineText", 0, 0, 300, 80, {
    Text = GameCfg.Survival.AdrenalineText,
    FontSize = 32,
    TextColor = Color.New(255, 255, 255, 255),
    LocalZOrder = 1,
  })
  local ad = make(scope, ctx, "EUIButton", banner, "SurvivalAdRevive", 10, 20, 300, 80, {
    ButtonText = "",
    NormalImage = COLOR_BLOCK,
    PressImage = COLOR_BLOCK,
    Color = Color.New(60, 150, 90, 255),
    Visible = false,
  })
  make(scope, ctx, "EUITextLabel", ad, "SurvivalAdReviveText", 0, 0, 300, 80, {
    Text = GameCfg.Survival.AdReviveText,
    FontSize = 30,
    TextColor = Color.New(255, 255, 255, 255),
    LocalZOrder = 1,
  })
  local paid = make(scope, ctx, "EUIButton", banner, "SurvivalPaidRevive", 330, 20, 300, 80, {
    ButtonText = "",
    NormalImage = COLOR_BLOCK,
    PressImage = COLOR_BLOCK,
    Color = Color.New(210, 160, 40, 255),
    Visible = false,
  })
  make(scope, ctx, "EUITextLabel", paid, "SurvivalPaidReviveText", 0, 0, 300, 80, {
    Text = GameCfg.Survival.PaidReviveText,
    FontSize = 30,
    TextColor = Color.New(255, 255, 255, 255),
    LocalZOrder = 1,
  })

  local function refresh()
    local state = survival:now() or {}
    local phase = state.phase
    local pending = state.platformPending == true
    if pending then
      title.Text = GameCfg.Survival.PlatformWaitText
    else
      local now = read_now(clock_now)
      if now ~= nil then
        local left = math.max(0, math.ceil((state.endsAt or 0) - now))
        local base = phase == "rescuing" and GameCfg.Rescue.RescuingTitle or GameCfg.Survival[phase == "dead" and "DeadTitle" or "DownedTitle"]
        title.Text = base .. "（" .. tostring(left) .. " 秒）"
      end
    end
    adrenaline.Visible = phase == "downed" and not pending
    ad.Visible = (phase == "downed" or phase == "dead") and not pending
    ad.Position = Vector2.New(phase == "downed" and 330 or 10, 20)
    paid.Visible = phase == "dead" and not pending
    paid.Position = Vector2.New(330, 20)
    if phase == "dead" and not noticed_dead:now() then
      noticed_dead:set(true)
      ViewUtil.notify(ctx, GameCfg.Survival.CallHelpText)
    elseif phase ~= "dead" then
      noticed_dead:set(false)
    end
  end

  scope:effect("SurvivalBannerRefresh", function(es)
    es:d(survival)
    es:d(ctx.clock.second)
    refresh()
  end)

  if adrenaline.OnClicked then
    ctx.connect(scope, adrenaline.OnClicked, function()
      seq:set(seq:now() + 1)
      send(ctx, seq, "UseAdrenaline", nil)
    end)
  end
  if ad.OnClicked then
    ctx.connect(scope, ad.OnClicked, function()
      seq:set(seq:now() + 1)
      send(ctx, seq, "FullRevive", "ad")
    end)
  end
  if paid.OnClicked then
    ctx.connect(scope, paid.OnClicked, function()
      seq:set(seq:now() + 1)
      send(ctx, seq, "FullRevive", "goods")
    end)
  end
end

local function mount_weak(scope, ctx, survival, clock_now)
  local res = ViewUtil.get_resolution(ctx); if res == nil then return end
  local label = make(scope, ctx, "EUITextLabel", ctx.root_node, "SurvivalWeak", res.x / 2 - 320, res.y - 200, 640, 60, {
    Text = "",
    FontSize = 30,
    TextColor = Color.New(200, 200, 255, 255),
    Visible = true,
  })
  scope:effect("SurvivalWeakRefresh", function(es)
    local state = es:d(survival) or {}
    es:d(ctx.clock.second)
    local now = read_now(clock_now); if now == nil then return end
    local left = math.max(0, math.ceil((state.weakUntil or 0) - now))
    label.Visible = left > 0
    label.Text = GameCfg.Survival.WeakText .. "（" .. tostring(left) .. " 秒）"
  end)
end

function SurvivalOverlayView.spec()
  return {
    name = "SurvivalOverlay",
    when = function(ms, store)
      local state = ms:d(store.survival)
      if type(state) ~= "table" then return false end
      if state.phase == "downed" or state.phase == "rescuing" or state.phase == "dead" then
        return true
      end
      local weak_until = state.weakUntil
      return type(weak_until) == "number" and weak_until > ms:d(store.clock.second)
    end,
    mount = function(scope, ctx)
      local clock_now = now_of_fn(ctx)
      local survival = ctx.store.survival
      local seq = State.new("SurvivalOverlay.seq", 0)
      local noticed_dead = State.new("SurvivalOverlay.noticed_dead", false)
      local banner_when = scope:memo("SurvivalBannerWhen", function(ms)
        local state = ms:d(survival)
        local phase = type(state) == "table" and state.phase
        return phase == "downed" or phase == "rescuing" or phase == "dead"
      end)
      scope:phase("SurvivalBannerPhase", banner_when, function(ps)
        mount_banner(ps, ctx, survival, seq, noticed_dead, clock_now)
      end)
      mount_weak(scope, ctx, survival, clock_now)
    end,
  }
end

return SurvivalOverlayView
