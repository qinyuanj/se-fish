local BodyScale = require("common.body_scale")
local GameCfg = require("common.game_cfg")
local MainHudLayout = require("client.main_hud_layout")
local Tokens = require("client.ui.tokens")
local Layout = require("client.ui.layout")
local Primitives = require("client.ui.primitives")
local Controls = require("client.ui.controls")
local ViewUtil = require("client.views.view_util")

local GroundLootView = {}

local TOGGLE_W = 152
local TOGGLE_H = 56
local BUBBLE_W = 160
local BUBBLE_H = 56

local function rows_of(loot)
  local list = {}
  if type(loot) ~= "table" then return list end
  local source = type(loot.list) == "table" and loot.list or loot
  for _, row in pairs(source) do
    if type(row) == "table" and (row.id ~= nil or row.Id ~= nil) then
      list[#list + 1] = row
    end
  end
  table.sort(list, function(a, b)
    return tostring(a.id or a.Id) < tostring(b.id or b.Id)
  end)
  return list
end

local function near(position, row, radius)
  local dist_sq = ViewUtil.distance_sq_xyz(position, row)
  return dist_sq ~= nil and dist_sq <= radius * radius
end

function GroundLootView.pick_nearest(store, radius)
  if type(store) ~= "table" then return nil end
  local position = store.position and store.position:now() or nil
  local character = store.local_character and store.local_character:now() or nil
  local loot = store.loot and store.loot:now() or nil
  if position == nil then return nil end
  local base_radius = radius or GameCfg.Loot.PickupRadius
  local effective = BodyScale.interaction_radius(character, base_radius)
  local limit_sq = effective * effective
  local best_id, best_dist = nil, nil
  for _, row in ipairs(rows_of(loot)) do
    local dist_sq = ViewUtil.distance_sq_xyz(position, row)
    if dist_sq ~= nil and dist_sq <= limit_sq and (best_dist == nil or dist_sq < best_dist) then
      best_dist = dist_sq
      best_id = row.id or row.Id
    end
  end
  return best_id
end

function GroundLootView.bubble_spec(options)
  options = type(options) == "table" and options or {}
  local base_radius = options.radius or GameCfg.Loot.PickupRadius
  return {
    items = function(es, store)
      local loot = es:d(store.loot)
      local position = es:d(store.position)
      local character = es:d(store.local_character)
      local radius = options.radius or BodyScale.interaction_radius(character, base_radius)
      local list = {}
      for _, row in ipairs(rows_of(loot)) do
        if near(position, row, radius) then
          list[#list + 1] = row
        end
      end
      return list
    end,
    key_of = function(item)
      return "loot:" .. tostring(item.id or item.Id)
    end,
    mount = function(scope, ctx, item_signal)
      local row = item_signal:now() or {}
      local id = row.id or row.Id
      local res = Primitives.resolution(ctx, options) or { x = 1920, y = 1080 }
      Controls.button(scope, ctx, {
        name = "BtnPickup_" .. tostring(id),
        rect = Layout.bottom_center(res.x, 180, BUBBLE_W, BUBBLE_H),
        text = "拾取",
        variant = "gold",
        font_size = Tokens.FONT_SIZE.BODY,
        z_order = Tokens.Z.HUD_CONTENT,
        on_click = function()
          if type(options.send) == "function" then
            options.send({ action = "Pickup", value = id })
          end
        end,
      })
    end,
  }
end

-- 瞄准拾取上下文按钮：摆在右侧 item_action 左侧安全空位，避开 StatusTopLeft / MenuEntry / ActionRight / CenterClear。
function GroundLootView.aim_toggle_spec(options)
  options = type(options) == "table" and options or {}
  local base_radius = options.radius or GameCfg.Loot.PickupRadius
  return {
    name = "GroundLootAimToggle",
    mount = function(scope, ctx)
      local function set_aim(active)
        local fn = ctx.services and ctx.services.set_overlay
        if type(fn) == "function" then
          fn("aim_pickup", active == true)
        end
      end

      local has_nearby = scope:memo("GroundLootNearby", function(ms)
        if ms:d(ctx.store.hud_visible) == false then
          return false
        end
        local position = ms:d(ctx.store.position)
        if position == nil then
          return false
        end
        local character = ms:d(ctx.store.local_character)
        local radius = options.radius or BodyScale.interaction_radius(character, base_radius)
        local loot = ms:d(ctx.store.loot)
        for _, row in ipairs(rows_of(loot)) do
          if near(position, row, radius) then
            return true
          end
        end
        return false
      end)

      scope:phase("GroundLootAimTogglePhase", has_nearby, function(ps)
        local res = Primitives.resolution(ctx, options) or { x = 1920, y = 1080 }
        local layout = MainHudLayout.compute({ width = res.x, height = res.y })
        local action_rect = layout.rects.item_action or Layout.rect(res.x - 416, 544, 176, 84)
        local btn_x = Layout.snap4(action_rect.x - action_rect.w / 2 - Tokens.SPACE.MD - TOGGLE_W / 2)
        local btn_y = Layout.snap4(action_rect.y)
        Controls.button(ps, ctx, {
          name = "BtnAimPickup",
          rect = Layout.rect(btn_x, btn_y, TOGGLE_W, TOGGLE_H),
          text = "瞄准拾取",
          variant = "hud",
          font_size = Tokens.FONT_SIZE.BODY,
          z_order = Tokens.Z.HUD_CONTENT,
          on_click = function()
            local flags = ctx.store.overlays:now()
            local active = type(flags) == "table" and flags.aim_pickup == true
            set_aim(not active)
          end,
        })
        ps:on_cleanup(function()
          set_aim(false)
        end)
      end)

      scope:subscribe(ctx.store.on_server_event, function(event)
        if type(event) ~= "table" or event.channel ~= "LootResult" then
          return
        end
        local result = event.payload
        if type(result) == "table" and result.reason == "full" then
          ViewUtil.notify(ctx, "背包已满")
        end
      end)
    end,
  }
end

-- 瞄准拾取全屏捕获层：纯 EUILayout（严禁空图 EUIButton 或暗黑 EUIImage）+ 顶部深海蓝胶囊提示条。
function GroundLootView.aim_spec(options)
  options = type(options) == "table" and options or {}
  return {
    when = function(ms, store)
      local flags = ms:d(store.overlays)
      return type(flags) == "table" and flags.aim_pickup == true
    end,
    mount = function(scope, ctx)
      local res = Primitives.resolution(ctx, options) or { x = 1920, y = 1080 }
      local function handle_pick()
        if type(options.on_pick) == "function" then
          options.on_pick(ctx)
        elseif type(options.send) == "function" then
          local id = GroundLootView.pick_nearest(ctx.store, options.radius)
          if id ~= nil then
            options.send({ action = "Pickup", value = id })
          end
        end
        local set_overlay = ctx.services and ctx.services.set_overlay
        if type(set_overlay) == "function" then
          set_overlay("aim_pickup", false)
        end
      end

      Primitives.dismiss_mask(scope, ctx, {
        name = "AimPickupMask",
        width = res.x,
        height = res.y,
        z_order = Tokens.Z.OVERLAY_MASK,
        swallow = true,
        on_click = handle_pick,
      })

      local layout = MainHudLayout.compute({ width = res.x, height = res.y })
      local hint_rect = layout.rects.hint_primary or Layout.top_center(res.x, res.y, 20, 520, 56)
      local hint_bg = Primitives.capsule(scope, ctx, {
        name = "LootAimHintBg",
        rect = hint_rect,
        z_order = Tokens.Z.OVERLAY_PANEL,
      })
      Primitives.label(scope, ctx, {
        name = "LootAimHint",
        parent = hint_bg,
        rect = Layout.rect(hint_rect.w / 2, hint_rect.h / 2, hint_rect.w - 32, hint_rect.h - 8),
        text = "点击屏幕拾取附近物品",
        font_size = Tokens.FONT_SIZE.BODY,
        bold = true,
        color = Tokens.COLOR.WHITE,
        outline = true,
        outline_color = Tokens.COLOR.OUTLINE_DARK,
        z_order = 1,
      })
    end,
  }
end

return GroundLootView
