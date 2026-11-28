local GameCfg = require("common.game_cfg")
local Spoke = require("common.packages.spoke.api")
local MainHudLayout = require("client.main_hud_layout")
local Tokens = require("client.ui.tokens")
local Layout = require("client.ui.layout")
local Primitives = require("client.ui.primitives")
local Controls = require("client.ui.controls")
local ViewUtil = require("client.views.view_util")

local State = Spoke.State

local SurvivalOverlayView = {}

local PANEL_W = 832
local PANEL_H = 240
local BTN_W = 340
local BTN_H = 68
local BTN_GAP = 32
local BTN_Y = 72

local function services_of(ctx)
  return ctx.services or {}
end

local function now_of_fn(ctx)
  return ViewUtil.resolve_clock(ctx, "SurvivalOverlayView")
end

local function read_now(clock_now)
  return ViewUtil.read_now(clock_now, "SurvivalOverlayView")
end

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

-- 倒地 / 抢救中 / 死亡覆盖蒙版：14588 半透遮罩 + 3A 奶白卡片 + 顶部倒计时标题 + 底部并排双按钮。
local function mount_banner(scope, ctx, survival, seq, noticed_dead, clock_now)
  local res = ViewUtil.get_resolution(ctx)
  if res == nil then
    return
  end
  local shell = Controls.modal_shell(scope, ctx, {
    name = "SurvivalBanner",
    title = "",
    title_name = "SurvivalTitle",
    width = PANEL_W,
    height = PANEL_H,
    show_close = false,
    backdrop_dismiss = false,
    z_mask = Tokens.Z.OVERLAY_MASK,
    z_panel = Tokens.Z.OVERLAY_PANEL,
    get_resolution = function()
      return res
    end,
  })
  local panel = shell.panel
  local title = shell.title_label
  pcall(function()
    title.TextHorizontalAlignment = 1
  end) -- 兼容离线测试替身无对齐字段

  local slots = Layout.centered_row(PANEL_W, BTN_Y, 2, BTN_W, BTN_H, BTN_GAP)
  local left_slot = slots[1]
  local right_slot = slots[2]
  ---@cast left_slot { x: number, y: number, w: number, h: number }
  ---@cast right_slot { x: number, y: number, w: number, h: number }

  local adrenaline = Controls.button(scope, ctx, {
    name = "SurvivalAdrenaline",
    parent = panel,
    rect = left_slot,
    text = GameCfg.Survival.AdrenalineText,
    variant = "gold",
    font_size = Tokens.FONT_SIZE.BUTTON,
    z_order = 2,
    visible = false,
    on_click = function()
      seq:set(seq:now() + 1)
      send(ctx, seq, "UseAdrenaline", nil)
    end,
  })

  local ad = Controls.button(scope, ctx, {
    name = "SurvivalAdRevive",
    label_name = "SurvivalAdReviveText",
    parent = panel,
    rect = right_slot,
    text = GameCfg.Survival.AdReviveText,
    variant = "blue",
    font_size = Tokens.FONT_SIZE.BUTTON,
    z_order = 2,
    visible = false,
    on_click = function()
      seq:set(seq:now() + 1)
      send(ctx, seq, "FullRevive", "ad")
    end,
  })

  local paid = Controls.button(scope, ctx, {
    name = "SurvivalPaidRevive",
    label_name = "SurvivalPaidReviveText",
    parent = panel,
    rect = right_slot,
    text = GameCfg.Survival.PaidReviveText,
    variant = "gold",
    font_size = Tokens.FONT_SIZE.BUTTON,
    z_order = 2,
    visible = false,
    on_click = function()
      seq:set(seq:now() + 1)
      send(ctx, seq, "FullRevive", "goods")
    end,
  })

  local function refresh()
    local state = survival:now() or {}
    local phase = state.phase
    local pending = state.platformPending == true
    if pending then
      title.Text = GameCfg.Survival.PlatformWaitText
      title.TextColor = ViewUtil.color(Tokens.COLOR.TEXT_DARK)
    else
      local now = read_now(clock_now)
      if now ~= nil then
        local left = math.max(0, math.ceil((state.endsAt or 0) - now))
        local base = phase == "rescuing" and GameCfg.Rescue.RescuingTitle
          or GameCfg.Survival[phase == "dead" and "DeadTitle" or "DownedTitle"]
        title.Text = base .. "（" .. tostring(left) .. " 秒）"
        title.TextColor = ViewUtil.color(phase == "rescuing" and Tokens.COLOR.TEXT_DARK or Tokens.COLOR.DANGER)
      end
    end

    local show_adrenaline = phase == "downed" and not pending
    local show_ad = (phase == "downed" or phase == "dead") and not pending
    local show_paid = phase == "dead" and not pending

    adrenaline.Visible = show_adrenaline
    ad.Visible = show_ad
    paid.Visible = show_paid
    Layout.apply(ad, phase == "downed" and right_slot or left_slot)
    Layout.apply(paid, right_slot)

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
end

-- 虚弱状态提示：放在顶部安全区 MainHudLayout hint_secondary 的深海蓝半透明胶囊条。
local function mount_weak(scope, ctx, survival, clock_now)
  local res = ViewUtil.get_resolution(ctx)
  if res == nil then
    return
  end
  local layout = MainHudLayout.compute({ width = res.x, height = res.y })
  local pill_rect = layout.rects.hint_secondary or Layout.top_center(res.x, res.y, 84, 520, 48)
  local bg = Primitives.capsule(scope, ctx, {
    name = "SurvivalWeakBg",
    rect = pill_rect,
    z_order = Tokens.Z.HUD_ACCENT,
    visible = false,
  })
  local label = Primitives.label(scope, ctx, {
    name = "SurvivalWeak",
    parent = bg,
    rect = Layout.rect(pill_rect.w / 2, pill_rect.h / 2, pill_rect.w - 32, pill_rect.h - 8),
    text = "",
    font_size = Tokens.FONT_SIZE.BODY,
    bold = true,
    color = Tokens.COLOR.TEXT_SOFT_WHITE,
    outline = true,
    outline_color = Tokens.COLOR.OUTLINE_DARK,
    z_order = 1,
    visible = false,
  })

  scope:effect("SurvivalWeakRefresh", function(es)
    local state = es:d(survival) or {}
    es:d(ctx.clock.second)
    local now = read_now(clock_now)
    if now == nil then
      return
    end
    local left = math.max(0, math.ceil((state.weakUntil or 0) - now))
    local active = left > 0
    bg.Visible = active
    label.Visible = active
    label.Text = GameCfg.Survival.WeakText .. "（" .. tostring(left) .. " 秒）"
  end)
end

function SurvivalOverlayView.spec()
  return {
    name = "SurvivalOverlay",
    when = function(ms, store)
      local state = ms:d(store.survival)
      if type(state) ~= "table" then
        return false
      end
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
