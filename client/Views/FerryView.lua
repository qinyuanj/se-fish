-- 客户端摆渡视图（#313 / ADR-0032 §1）：统一挂在 RootView 的 HUD 与 Dock。
-- 六条去程、六条返程按各自锚点与交互半径投影；点击只上行 FerryAction。
-- 倒计时按 routeId 独立递减，显示最近一班；终局按 operation 防止旧回包误清新航班。
-- 所有场景节点、倒计时标签和下行订阅都由所在 Spoke 作用域逆序回收。

local GameCfg = require("common.GameCfg")
local BodyScale = require("common.BodyScale")
local spoke = require("common.packages.spoke.api")

local State = spoke.State

local FerryView = {}

local function zone_name(route_id, action)
  local route = GameCfg.Ferry.Route(route_id)
  if not route then return "目的地" end
  local zone_id = action == "Return" and route.FromZoneId or route.ToZoneId
  for _, zone in ipairs(GameCfg.Zones) do
    if zone.Id == zone_id then return zone.Name end
  end
  return zone_id
end

local function notify(ctx, text)
  local services = ctx.services or {}
  if type(services.notify) == "function" then
    services.notify(text)
  elseif type(rawget(_G, "LocalMsgNotice")) == "function" then
    rawget(_G, "LocalMsgNotice")(text)
  end
end

local function on_result(ctx, result)
  if type(result) ~= "table" then return end
  if result.ok then
    if result.action == "Board" then
      if result.seconds == nil then
        notify(ctx, "已经到" .. zone_name(result.routeId) .. "了")
      else
        notify(ctx, "船票已交，" .. tostring(result.seconds) .. " 秒后开船")
      end
    elseif result.action == "Return" then
      notify(ctx, "已经回到" .. zone_name(result.routeId, "Return") .. "，金币 -" .. tostring(result.price))
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
  notify(ctx, reasons[result.reason] or "摆渡暂时不可用")
end

function FerryView.mount(scope, ctx)
  local countdowns = {}
  local selected = State.new("FerryView.selected", nil)

  local function refresh()
    local soonest
    for route_id, row in pairs(countdowns) do
      if not soonest or row.remaining < soonest.remaining
          or (row.remaining == soonest.remaining and route_id < soonest.routeId) then
        soonest = { routeId = route_id, operation = row.operation, remaining = row.remaining }
      end
    end
    selected:set(soonest)
  end

  local function on_state(snapshot)
    if type(snapshot) ~= "table" or type(snapshot.routeId) ~= "string" then return end
    local route_id = snapshot.routeId
    if snapshot.phase == "countdown" then
      countdowns[route_id] = { remaining = tonumber(snapshot.seconds) or 5, operation = snapshot.operation }
    elseif snapshot.phase == "departed" or snapshot.phase == "cancelled" then
      local current = countdowns[route_id]
      if not current or current.operation ~= snapshot.operation then return end
      countdowns[route_id] = nil
    else
      return
    end
    refresh()
  end

  scope:subscribe(ctx.store.on_server_event, function(event)
    if type(event) ~= "table" then return end
    if event.channel == "FerryState" then
      on_state(event.payload)
    elseif event.channel == "FerryResult" then
      on_result(ctx, event.payload)
    end
  end)

  scope:subscribe(ctx.clock.on_frame, function(frame)
    local dt = type(frame) == "table" and tonumber(frame.dt) or 0
    if dt <= 0 or not next(countdowns) then return end
    for route_id, row in pairs(countdowns) do
      row.remaining = row.remaining - dt
      if row.remaining <= 0 then countdowns[route_id] = nil end
    end
    refresh()
  end)

  local visible = scope:memo("FerryCountdownVisible", function(ms)
    return ms:d(selected) ~= nil
  end)
  scope:phase("FerryCountdownPhase", visible, function(ps)
    local resolution = type(ctx.services.get_device_resolution) == "function"
      and ctx.services.get_device_resolution() or { x = 1920, y = 1080 }
    local label = ctx.create_node(ps, "EUITextLabel", {
      Name = "FerryCountdown",
      Position = Vector2.New((resolution.x or 1920) / 2, (resolution.y or 1080) - 120),
      Size = Vector2.New(360, 60),
      Text = "",
      FontSize = 36,
      TextColor = Color.New(255, 255, 255, 255),
      Visible = true,
      TouchEnabled = false,
      SwallowTouchEnabled = false,
    })
    ps:effect("FerryCountdownText", function(es)
      local current = es:d(selected)
      if current then
        label.Text = string.format("前往%s %d 秒", zone_name(current.routeId), math.ceil(current.remaining))
      end
    end)
  end)

  scope:on_cleanup(function() countdowns = {} end)
end

function FerryView.spec()
  return { name = "Ferry", mount = FerryView.mount }
end

local function anchor_of(anchor_name)
  for _, zone in ipairs(GameCfg.Zones) do
    for _, entity in ipairs(zone.Scene and zone.Scene.Entities or {}) do
      if entity.Role == "Ferry" and entity.Name == anchor_name then return entity.Position end
    end
  end
  return nil
end

local function near(position, center, radius)
  if not position or not center then return false end
  local dx, dz = position.x - center.x, position.z - center.z
  return dx * dx + dz * dz <= radius * radius
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
          local radius = BodyScale.InteractionRadius(character, leg.point.Radius)
          if near(position, center, radius) then
            list[#list + 1] = { key = "ferry:" .. index .. ":" .. leg.action,
              routeId = route.Id, action = leg.action, text = leg.text,
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
      if type(ctx.services.create_scene_node) == "function" then
        parent = ctx.services.create_scene_node(position, "FerryLeg:" .. key)
        ctx.own_node(scope, parent)
      end
      local button = ctx.create_node(scope, "EUIButton", {
        Name = "BtnFerry" .. item.point.AnchorName,
        Parent = parent,
        ButtonText = item.text,
        TouchEnabled = true,
        Visible = true,
      })
      ctx.connect(scope, button.OnClicked, function()
        seq = seq + 1
        local payload = { action = item.action, routeId = item.routeId, seq = seq }
        if type(ctx.services.send_ferry) == "function" then ctx.services.send_ferry(payload) end
      end)
    end,
  }
end

return FerryView
