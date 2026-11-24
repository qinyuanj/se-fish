-- Spoke 主 HUD 左上状态区与金币视图（ADR-0032 / #297-B2，归属 L2 client.views）：
-- 挂载于 root_view 常驻 HUD 槽位，订阅只读 client_store.vitals / coin / clock；
-- 负责血量环（'血 '）、饥饿环（'饥饿度 '）、4 条饥饿闪烁红边与编辑器预置金币节点（ImageCoin/LabelCoin）排版。

local spoke = require("common.packages.spoke.api")
local game_cfg = require("common.game_cfg")
local number = require("common.number")
local main_hud_layout = require("client.main_hud_layout")
local view_util = require("client.views.view_util")

local State = spoke.State

local main_hud_vitals_view = {}

local HEALTH_PREFIX = "血 "
local HUNGER_PREFIX = "饥饿度 "
local VITAL_FONT_MAX = 20

local function make_color(rgba)
  return Color.New(rgba[1], rgba[2], rgba[3], rgba[4])
end

local function make_passive(node)
  node.TouchEnabled = false
  node.SwallowTouchEnabled = false
  return node
end

local function columns_of(text)
  local count = 0
  for _ in tostring(text):gmatch("[%z\1-\127\194-\244][\128-\191]*") do
    count = count + 1
  end
  return count
end

local function vital_font_size(width, config)
  local longest = math.max(
    columns_of(HEALTH_PREFIX .. tostring(config.MaxHealth)),
    columns_of(HUNGER_PREFIX .. tostring(config.MaxHunger))
  )
  return math.max(1, math.min(VITAL_FONT_MAX, math.floor(width / longest)))
end

local function vital_percent(value, maximum)
  return maximum > 0 and math.max(0, math.min(100, value * 100 / maximum)) or 0
end

local function find_editor_node(root, name)
  if root == nil then
    return nil
  end
  local ok, node = pcall(function() return root:FindFirstChild(name, true) end) -- 兼容引擎 userdata 方法代理与测试双查找实现
  return ok and node or nil
end

local function place_editor_node(node, rect)
  if node == nil or rect == nil then
    return
  end
  node.Anchor = Vector2.New(0.5, 0.5)
  node.Position = Vector2.New(rect.x, rect.y)
  node.Size = Vector2.New(rect.w, rect.h)
end

local function create_overlay_label(ctx, scope, name, x, y, width, height, text, font_size, text_color, z_order)
  local label = ctx.create_node(scope, "EUITextLabel", {
    Name = name,
    Position = Vector2.New(x, y),
    Size = Vector2.New(width, height),
    Text = text,
    FontSize = font_size,
    TextColor = text_color,
  })
  label.TextHorizontalAlignment = 1
  label.TextVerticalAlignment = 1
  label.TouchEnabled = false
  label.SwallowTouchEnabled = false
  label.LocalZOrder = z_order or 1
  return label
end

--- 挂载左上状态区（血量环、饥饿环、4 条饥饿红边）与预置金币节点排版。
---@param s table EffectBuilder
---@param ctx table root_view 上下文 { root_node, store, clock, create_node, own_node, connect }
---@param options table|nil { get_resolution?, notify?, find_node? }
function main_hud_vitals_view.mount(s, ctx, options)
  options = options or {}
  local notify = options.notify or function(text) view_util.notify(ctx, text) end
  local find_node = options.find_node or find_editor_node

  local resolution = view_util.get_resolution(ctx, options)
  local layout = main_hud_layout.Compute({
    width = resolution.x,
    height = resolution.y,
    itemBarSlots = game_cfg.Items.ItemBarSlots,
  })
  local rects = layout.Rects
  local cfg = game_cfg.vitals

  -- 1. 编辑器预置金币节点（按名查找并排版，生命周期归属编辑器场景树，不由本视图销毁）
  local label_coin = find_node(ctx.root_node, "LabelCoin")
  local image_coin = find_node(ctx.root_node, "ImageCoin")
  if label_coin ~= nil then
    label_coin.Visible = true
  else
    print("[main_hud_vitals_view] 找不到 LabelCoin 节点")
  end
  if image_coin ~= nil then
    image_coin.Visible = true
  end
  place_editor_node(image_coin, rects.CoinIcon)
  place_editor_node(label_coin, rects.CoinLabel)

  -- 2. 血量环与饥饿度环（动态节点全部经 ctx.create_node 托管）
  local rings = {}
  local specs = {
    { key = "Health", rect = rects.HealthRing, image = cfg.HealthRing, rgba = cfg.HealthColor },
    { key = "Hunger", rect = rects.HungerRing, image = cfg.HungerRing, rgba = cfg.HungerColor },
  }
  for _, spec in ipairs(specs) do
    local r = spec.rect
    local bg = make_passive(ctx.create_node(s, "EUIImage", {
      Name = spec.key .. "RingBg",
      Position = Vector2.New(r.x, r.y),
      Size = Vector2.New(r.w, r.h),
      Image = cfg.RingBg,
    }))
    local ring = make_passive(ctx.create_node(s, "EUIProgressTimer", {
      Name = spec.key .. "Ring",
      Position = Vector2.New(r.x, r.y),
      Size = Vector2.New(r.w, r.h),
      Image = spec.image,
      Percent = 100,
    }))
    ring.Color = make_color(spec.rgba)
    ring.LocalZOrder = 1
    local text = create_overlay_label(
      ctx, s, spec.key .. "Text", r.x, r.y, r.w, 40, "",
      vital_font_size(r.w, cfg), Color.New(255, 255, 255, 255), 2
    )
    rings[spec.key] = { bg = bg, ring = ring, text = text }
  end

  -- 3. 4 条饥饿红边（默认隐藏；仅在饥饿 Phase 活跃期间订阅时钟闪烁）
  local t, w, h = cfg.FlashThickness, resolution.x, resolution.y
  local edge_specs = {
    { "FlashTop", w / 2, h - t / 2, w, t },
    { "FlashBottom", w / 2, t / 2, w, t },
    { "FlashLeft", t / 2, h / 2, t, h },
    { "FlashRight", w - t / 2, h / 2, t, h },
  }
  local flash_edges = {}
  for _, spec in ipairs(edge_specs) do
    local edge = make_passive(ctx.create_node(s, "EUIImage", {
      Name = spec[1],
      Position = Vector2.New(spec[2], spec[3]),
      Size = Vector2.New(spec[4], spec[5]),
      Image = cfg.FlashImage,
    }))
    edge.Color = make_color(cfg.FlashColor)
    edge.LocalZOrder = 3
    edge.Visible = false
    flash_edges[#flash_edges + 1] = edge
  end

  local is_starving = State.new("main_hud_vitals_view.is_starving", false)

  -- 4. 主 HUD 关屏显隐对齐 store.hud_visible
  s:effect("VitalsVisibilityProjection", function(es)
    local visible = es:d(ctx.store.hud_visible) ~= false
    if label_coin ~= nil then
      label_coin.Visible = visible
    end
    if image_coin ~= nil then
      image_coin.Visible = visible
    end
    for _, entry in pairs(rings) do
      entry.bg.Visible = visible
      entry.ring.Visible = visible
      entry.text.Visible = visible
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
    local max_health = v and v.maxHealth or cfg.MaxHealth
    local hunger = v and v.hunger or cfg.MaxHunger
    local max_hunger = v and v.maxHunger or cfg.MaxHunger
    rings.Health.ring.Percent = vital_percent(health, max_health)
    rings.Hunger.ring.Percent = vital_percent(hunger, max_hunger)
    rings.Health.text.Text = HEALTH_PREFIX .. tostring(health)
    rings.Hunger.text.Text = HUNGER_PREFIX .. tostring(hunger)
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
        print("[main_hud_vitals_view] 饥饿提示", cfg.WarnText)
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
    if label_coin ~= nil then
      label_coin.Text = tostring(math.floor(tonumber(coin) or 0))
    end
  end)
end

--- 返回可供 root_view.mount({ hud = { ... } }) 直接注册的 HUD spec。
function main_hud_vitals_view.spec(options)
  return {
    name = "MainHudVitals",
    mount = function(s, ctx)
      main_hud_vitals_view.mount(s, ctx, options)
    end,
  }
end

return main_hud_vitals_view
