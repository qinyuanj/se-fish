-- Spoke 主 HUD 左上状态区与金币胶囊视图（1A + 4px 栅格，归属 L2 client.views）：
-- 挂载于 RootView 常驻 HUD 槽位，订阅只读 ClientStore.vitals / coin / clock；
-- 负责左上横向胶囊血量条（HealthBar）、饥饿条（HungerBar）、金币胶囊（CoinCapsule）与 4 条饥饿闪烁红边。

local Spoke = require("common.packages.spoke.api")
local GameCfg = require("common.game_cfg")
local MainHudLayout = require("client.main_hud_layout")
local Tokens = require("client.ui.tokens")
local Layout = require("client.ui.layout")
local Primitives = require("client.ui.primitives")
local Controls = require("client.ui.controls")
local ViewUtil = require("client.views.view_util")
local HudWidgets = require("client.views.hud_widgets")

local State = Spoke.State

local MainHudVitalsView = {}

local HEALTH_PREFIX = "血 "
local HUNGER_PREFIX = "饥饿度 "

local make_color = ViewUtil.color

local function vital_percent(value, maximum)
  return maximum > 0 and math.max(0, math.min(100, value * 100 / maximum)) or 0
end

local function build_coin_capsule_rect(icon_rect, label_rect)
  local il, _, ib, it = Layout.edges(icon_rect)
  local _, lr, lb, lt = Layout.edges(label_rect)
  return Layout.from_edges(il - Tokens.SPACE.XS, lr + Tokens.SPACE.XS, math.min(ib, lb), math.max(it, lt))
end

--- 挂载左上横向胶囊状态条（血量、饥饿、金币）与 4 条饥饿闪烁红边。
---@param s table EffectBuilder
---@param ctx table RootView 上下文 { root_node, store, clock, create_node, own_node, connect }
---@param options table|nil { get_resolution?, notify? }
function MainHudVitalsView.mount(s, ctx, options)
  options = options or {}
  local notify = options.notify or function(text) ViewUtil.notify(ctx, text) end

  local resolution = ViewUtil.get_resolution(ctx, options); if resolution == nil then return end
  local layout = MainHudLayout.compute({
    width = resolution.x,
    height = resolution.y,
    itemBarSlots = GameCfg.Items.ItemBarSlots,
  })
  local rects = layout.rects
  local cfg = GameCfg.Vitals

  -- 1. 官方质感血量条 + 饥饿条（30008 立体底槽 + 30007 填充 + 左侧爱心/食物图标 + 居中白字轻描边）
  local bars = {}
  local bar_specs = {
    { key = "Health", name = "HealthBar", rect = rects.HealthBar, rgba = Tokens.COLOR.HEALTH, icon = Tokens.ASSET.ICON_HEART },
    { key = "Hunger", name = "HungerBar", rect = rects.HungerBar, rgba = Tokens.COLOR.HUNGER, icon = Tokens.ASSET.ICON_FOOD },
  }
  for _, spec in ipairs(bar_specs) do
    local bar = Controls.progress_bar(s, ctx, {
      name = spec.name,
      parent = ctx.root_node,
      rect = spec.rect,
      fill_color = spec.rgba,
      bg_color = Tokens.COLOR.HUD_BAR_BG,
      opacity = Tokens.OPACITY.SOLID,
      icon = spec.icon,
      percent = 100,
      text = "",
      font_size = Tokens.FONT_SIZE.MICRO,
      z_order = Tokens.Z.HUD_BG,
    })
    bar.fill.Color = make_color(spec.rgba)
    bars[spec.key] = bar
  end

  -- 2. 金币胶囊（底板 + 金币图标 + 金色数字，托管于当前作用域，不依赖已隐藏的旧预置画布）
  local coin_capsule_rect = build_coin_capsule_rect(rects.coin_icon, rects.coin_label)
  local coin_capsule = Primitives.capsule(s, ctx, {
    name = "CoinCapsule",
    parent = ctx.root_node,
    rect = coin_capsule_rect,
    z_order = Tokens.Z.HUD_BG,
  })
  local coin_icon = Primitives.image(s, ctx, {
    name = "CoinIcon",
    parent = ctx.root_node,
    rect = rects.coin_icon,
    image = Tokens.ASSET.COIN,
    z_order = Tokens.Z.HUD_CONTENT,
  })
  local coin_label = Primitives.label(s, ctx, {
    name = "CoinLabel",
    parent = ctx.root_node,
    rect = rects.coin_label,
    text = "0",
    font_size = Tokens.FONT_SIZE.BODY,
    bold = true,
    color = Tokens.COLOR.TEXT_GOLD,
    outline = true,
    outline_color = Tokens.COLOR.OUTLINE_DARK,
    align_x = 0,
    align_y = 1,
    z_order = Tokens.Z.HUD_CONTENT,
  })

  -- 3. 4 条饥饿红边（默认隐藏；仅在饥饿 Phase 活跃期间订阅时钟闪烁）
  local t, w, h = Layout.snap4(cfg.FlashThickness, 8), resolution.x, resolution.y
  local edge_specs = {
    { "FlashTop", Layout.rect(w / 2, h - t / 2, w, t) },
    { "FlashBottom", Layout.rect(w / 2, t / 2, w, t) },
    { "FlashLeft", Layout.rect(t / 2, h / 2, t, h) },
    { "FlashRight", Layout.rect(w - t / 2, h / 2, t, h) },
  }
  local flash_edges = {}
  for _, spec in ipairs(edge_specs) do
    local edge = HudWidgets.passive(Primitives.image(s, ctx, {
      name = spec[1],
      parent = ctx.root_node,
      rect = spec[2],
      image = cfg.FlashImage,
      color = Tokens.COLOR.STARVE_FLASH,
      opacity = 0.60,
      z_order = Tokens.Z.HUD_FLASH,
      visible = false,
    }))
    edge.Color = make_color(cfg.FlashColor)
    flash_edges[#flash_edges + 1] = edge
  end

  local is_starving = State.new("MainHudVitalsView.is_starving", false)

  -- 4. 主 HUD 关屏显隐对齐 store.hud_visible
  s:effect("VitalsVisibilityProjection", function(es)
    local visible = es:d(ctx.store.hud_visible) ~= false
    coin_capsule.Visible = visible
    coin_icon.Visible = visible
    coin_label.Visible = visible
    for _, entry in pairs(bars) do
      entry.bg.Visible = visible
      entry.fill.Visible = visible
      entry.label.Visible = visible
      if entry.icon ~= nil then
        entry.icon.Visible = visible
      end
    end
    if not visible then
      for _, edge in ipairs(flash_edges) do
        edge.Visible = false
      end
    end
  end)

  -- 5. 血量与饥饿度响应式投影
  s:effect("VitalsProjection", function(es)
    local v = es:d(ctx.store.vitals)
    local health = v and v.health or cfg.MaxHealth
    local max_health = v and v.max_health or cfg.MaxHealth
    local hunger = v and v.hunger or cfg.MaxHunger
    local max_hunger = v and v.max_hunger or cfg.MaxHunger
    bars.Health.set_percent(vital_percent(health, max_health))
    bars.Hunger.set_percent(vital_percent(hunger, max_hunger))
    bars.Health.label.Text = HEALTH_PREFIX .. tostring(health)
    bars.Hunger.label.Text = HUNGER_PREFIX .. tostring(hunger)
    is_starving:set(hunger <= 0 and health > 0)
  end)

  -- 6. 饥饿红边闪烁与节流提示（仅在主 HUD 可见且饥饿时挂载，关屏或脱离饥饿立即退订并隐藏）
  local starving_fx_active = s:memo("StarvingFxActive", function(ms)
    return ms:d(is_starving) and ms:d(ctx.store.hud_visible) ~= false
  end)

  s:phase("StarvingFx", starving_fx_active, function(ps)
    local next_warn_at = nil

    local function update_fx()
      local now = ctx.clock.now()
      local on = math.floor(now / cfg.FlashPeriodSec) % 2 == 0
      for _, edge in ipairs(flash_edges) do
        edge.Visible = on
      end
      if next_warn_at == nil or now >= next_warn_at then
        next_warn_at = now + cfg.WarnIntervalSec
        notify(cfg.WarnText)
        print("[MainHudVitalsView] 饥饿提示", cfg.WarnText)
      end
    end

    update_fx()
    ps:subscribe(ctx.clock.on_frame, update_fx)
    ps:on_cleanup(function()
      for _, edge in ipairs(flash_edges) do
        edge.Visible = false
      end
    end)
  end)

  -- 7. 金币响应式投影
  s:effect("CoinProjection", function(es)
    local coin = es:d(ctx.store.coin)
    coin_label.Text = tostring(math.floor(tonumber(coin) or 0))
  end)
end

--- 返回可供 RootView.mount({ hud = { ... } }) 直接注册的 HUD spec。
function MainHudVitalsView.spec(options)
  return ViewUtil.hud_spec("MainHudVitals", MainHudVitalsView.mount, options)
end

return MainHudVitalsView
