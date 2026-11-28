local GameCfg = require("common.game_cfg")
local BodyScale = require("common.body_scale")
local Spoke = require("common.packages.spoke.api")
local MainHudLayout = require("client.main_hud_layout")
local Tokens = require("client.ui.tokens")
local Layout = require("client.ui.layout")
local Primitives = require("client.ui.primitives")
local Controls = require("client.ui.controls")
local ViewUtil = require("client.views.view_util")
local InteractPromptArbiter = require("client.views.interact_prompt_arbiter")

local State = Spoke.State

local FerryView = {}

local BUBBLE_W = 160
local BUBBLE_H = 56

local function zone_name(route_id, action)
  local route = GameCfg.Ferry.route(route_id)
  if not route then return "目的地" end
  local zone_id = action == "Return" and route.FromZoneId or route.ToZoneId
  for _, zone in ipairs(GameCfg.Zones) do
    if zone.Id == zone_id then return zone.Name end
  end
  return zone_id
end

local function on_result(ctx, result)
  if type(result) ~= "table" then return end
  if result.ok then
    if result.action == "Board" then
      if result.seconds == nil then
        ViewUtil.notify(ctx, "已经到" .. zone_name(result.route_id) .. "了")
      else
        ViewUtil.notify(ctx, "船票已交，" .. tostring(result.seconds) .. " 秒后开船")
      end
    elseif result.action == "Return" then
      ViewUtil.notify(ctx, "已经回到" .. zone_name(result.route_id, "Return") .. "，金币 -" .. tostring(result.price))
    end
    return
  end
  local reasons = {
    route = "找不到这条航线，请重进本图",
    ticket = "需要本区船票（本区首领信物喂钓鱼佬可换）",
    coin = "金币不够，船家不开船",
    range = "离船太远了",
    sailing = "这条航线已经在倒计时了，等下一班",
    pending = "上一趟摆渡还没结清，稍后再试",
    teleport = result.action == "Board" and "传送失败，船票已退" or "传送失败，金币已退",
    not_aboard = "没赶上船，船票已退",
    anchor = "航班取消，船票已退",
    interrupted = "上次航班已取消，船票已退",
  }
  ViewUtil.notify(ctx, reasons[result.reason] or "摆渡暂时不可用")
end

function FerryView.mount(scope, ctx)
  local countdowns = {}
  local has_countdown = State.new("FerryView.has_countdown", false)
  local version = State.new("FerryView.version", 0)

  local function prune_and_select(now)
    local soonest
    for route_id, row in pairs(countdowns) do
      local remaining = row.ends_at - now
      if remaining <= 0 then
        countdowns[route_id] = nil
      elseif not soonest or remaining < soonest.remaining
          or (remaining == soonest.remaining and route_id < soonest.route_id) then
        soonest = { route_id = route_id, operation = row.operation, remaining = remaining }
      end
    end
    return soonest
  end

  local function sync_phase()
    local soonest = prune_and_select(ctx.clock.now())
    local active = soonest ~= nil
    if has_countdown:now() ~= active then
      has_countdown:set(active)
    end
    if active then
      version:set(version:now() + 1)
    end
  end

  local function on_state(snapshot)
    if type(snapshot) ~= "table" or type(snapshot.route_id) ~= "string" then return end
    local route_id = snapshot.route_id
    if snapshot.phase == "countdown" then
      local seconds = tonumber(snapshot.seconds) or 5
      countdowns[route_id] = { ends_at = ctx.clock.now() + seconds, operation = snapshot.operation }
    elseif snapshot.phase == "departed" or snapshot.phase == "cancelled" then
      local current = countdowns[route_id]
      if not current or current.operation ~= snapshot.operation then return end
      countdowns[route_id] = nil
    else
      return
    end
    sync_phase()
  end

  scope:subscribe(ctx.store.on_server_event, function(event)
    if type(event) ~= "table" then return end
    if event.channel == "FerryState" then
      on_state(event.payload)
    elseif event.channel == "FerryResult" then
      on_result(ctx, event.payload)
    end
  end)

  scope:phase("FerryCountdownPhase", has_countdown, function(ps)
    local resolution = ViewUtil.get_resolution(ctx)
    if resolution == nil then return end
    local layout = MainHudLayout.compute({ width = resolution.x, height = resolution.y })
    local pill_rect = layout.rects.hint_primary or Layout.top_center(resolution.x, resolution.y, 20, 520, 56)
    local bg = Primitives.capsule(ps, ctx, {
      name = "FerryCountdownBg",
      rect = pill_rect,
      z_order = Tokens.Z.HUD_ACCENT,
    })
    local label = Primitives.label(ps, ctx, {
      name = "FerryCountdown",
      parent = bg,
      rect = Layout.rect(pill_rect.w / 2, pill_rect.h / 2, pill_rect.w - 32, pill_rect.h - 8),
      text = "",
      font_size = Tokens.FONT_SIZE.BUTTON,
      bold = true,
      color = Tokens.COLOR.WHITE,
      outline = true,
      outline_color = Tokens.COLOR.OUTLINE_DARK,
      z_order = 1,
    })

    local last_text = nil
    local function render_label()
      local soonest = prune_and_select(ctx.clock.now())
      if soonest == nil then
        if has_countdown:now() then
          has_countdown:set(false)
        end
        return
      end
      ---@diagnostic disable-next-line: undefined-field
      local text = string.format("前往%s %d 秒", zone_name(soonest.route_id), math.ceil(soonest.remaining))
      if text ~= last_text then
        last_text = text
        label.Text = text
      end
    end

    ps:effect("FerryCountdownText", function(es)
      es:d(version)
      render_label()
    end)

    ps:subscribe(ctx.clock.on_second, render_label)
  end)

  scope:on_cleanup(function() countdowns = {} end)
end

function FerryView.spec()
  return ViewUtil.hud_spec("Ferry", FerryView.mount)
end

local function anchor_of(anchor_name)
  for _, zone in ipairs(GameCfg.Zones) do
    ---@cast zone table
    for _, entity in ipairs(zone.Scene and zone.Scene.Entities or {}) do
      if entity.role == "Ferry" and entity.Name == anchor_name then return entity.Position end
    end
  end
  return nil
end

local function near(position, center, radius)
  local dist_sq = ViewUtil.distance_sq_xz(position, center)
  return dist_sq ~= nil and dist_sq <= radius * radius
end

function FerryView.legs_spec()
  local seq = 0
  return {
    items = function(es, store)
      local position = es:d(store.position)
      local character = es:d(store.local_character)
      if not position then return {} end
      local list = {}
      for index, route in ipairs(GameCfg.Ferry.Routes) do
        for _, leg in ipairs({
          { point = route.Outbound, action = "Board", text = "乘船" },
          { point = route.Return, action = "Return", text = "返程" },
        }) do
          local center = anchor_of(leg.point.AnchorName)
          local radius = BodyScale.interaction_radius(character, leg.point.Radius)
          if near(position, center, radius)
              and InteractPromptArbiter.is_exclusive(position, character, leg.point.AnchorName) then
            list[#list + 1] = { key = "ferry:" .. index .. ":" .. leg.action,
              route_id = route.Id, action = leg.action, text = leg.text,
              point = leg.point, center = center }
          end
        end
      end
      return list
    end,
    key_of = function(item) return item.key end,
    mount = function(scope, ctx, item_signal, key)
      local item = item_signal:now()
      local center = item.center
      local position = Vector3.New(center.x, center.y + item.point.BubbleHeight, center.z)
      local parent = nil
      local services = ctx.services or {}
      local create_at = services.create_scene_node_at or services.create_scene_node
      if type(create_at) == "function" then
        parent = create_at(position, "FerryLeg:" .. key)
        ctx.own_node(scope, parent)
      end
      Controls.button(scope, ctx, {
        name = "BtnFerry" .. item.point.AnchorName,
        parent = parent,
        rect = Layout.rect(BUBBLE_W / 2, BUBBLE_H / 2, BUBBLE_W, BUBBLE_H),
        text = item.text,
        variant = "gold",
        font_size = Tokens.FONT_SIZE.BUTTON,
        z_order = 1,
        on_click = function()
          seq = seq + 1
          local payload = { action = item.action, route_id = item.route_id, seq = seq }
          if type(services.send_ferry) == "function" then services.send_ferry(payload) end
        end,
      })
    end,
  }
end

return FerryView
