
local BodyScale = require("common.BodyScale")
local GameCfg = require("common.GameCfg")
local GrillCurve = require("common.GrillCurve")
local spoke = require("common.packages.spoke.api")
local ViewUtil = require("client.Views.ViewUtil")

local State = spoke.State

local GrillView = {}

local function cfg()
  return GameCfg.Grill
end

local function item_name(item_id)
  local definition = item_id and GameCfg.Items.Definitions[item_id]
  return definition and definition.Name or tostring(item_id or "")
end

local function active_grill(snapshot)
  if type(snapshot) ~= "table" then return false end
  return snapshot.state == "cooking" or snapshot.state == "ready"
end

local function ensure_shared(shared)
  if type(shared) ~= "table" then
    shared = {}
  end
  if shared.seq == nil then
    shared.seq = 0
  end
  if shared.armed_until == nil then
    shared.armed_until = 0
  end
  if shared.panel_hidden == nil then
    shared.panel_hidden = State.new("GrillView.panel_hidden", false)
  end
  return shared
end

function GrillView.new_shared()
  return ensure_shared({})
end

local function next_seq(ctx, shared)
  local services = ctx.services or {}
  if type(services.next_seq) == "function" then
    return services.next_seq()
  end
  shared.seq = (shared.seq or 0) + 1
  return shared.seq
end

local function send_grill(ctx, shared, action, confirm)
  local services = ctx.services or {}
  if type(services.send_grill) ~= "function" then
    return
  end
  local payload = {
    action = action,
    seq = next_seq(ctx, shared),
  }
  if confirm then
    payload.confirm = true
  end
  services.send_grill(payload)
end

local function click_grill(ctx, shared)
  local snapshot = ctx.store.grill:now()
  if active_grill(snapshot) then
    shared.panel_hidden:set(false)
    send_grill(ctx, shared, "Query")
    return
  end
  local now = ctx.clock.now()
  local confirm = now <= (shared.armed_until or 0)
  shared.armed_until = 0
  send_grill(ctx, shared, "Start", confirm)
end

function GrillView.mount(scope, ctx, options)
  options = type(options) == "table" and options or {}
  local shared = ensure_shared(options.shared or (ctx.services and ctx.services.grill_shared))
  local burnt_noticed = false

  local active = scope:memo("GrillVisible", function(ms)
    return active_grill(ms:d(ctx.store.grill)) and not ms:d(shared.panel_hidden)
  end)

  scope:phase("GrillPanelPhase", active, function(ps)
    local panel = ctx.create_node(ps, "EUIImage", {
      Name = "GrillPanel",
      Visible = true,
    })
    local title = ctx.create_node(ps, "EUITextLabel", {
      Name = "GrillTitle",
      Parent = panel,
      Text = "",
    })
    local time_label = ctx.create_node(ps, "EUITextLabel", {
      Name = "GrillTime",
      Parent = panel,
      Text = "",
    })
    local rate_label = ctx.create_node(ps, "EUITextLabel", {
      Name = "GrillRate",
      Parent = panel,
      Text = "",
    })
    local takeout = ctx.create_node(ps, "EUIButton", {
      Name = "GrillTakeout",
      Parent = panel,
      ButtonText = cfg().TakeoutText,
    })
    takeout.TouchEnabled = true
    local takeout_text = ctx.create_node(ps, "EUITextLabel", {
      Name = "GrillTakeoutText",
      Parent = takeout,
      Text = cfg().TakeoutText,
    })
    takeout_text.Visible = true
    local close_btn = ctx.create_node(ps, "EUIButton", {
      Name = "GrillClose",
      Parent = panel,
      ButtonText = "关闭",
    })
    close_btn.TouchEnabled = true
    local close_text = ctx.create_node(ps, "EUITextLabel", {
      Name = "GrillCloseText",
      Parent = close_btn,
      Text = "关闭",
    })
    close_text.Visible = true

    local last_time_text, last_rate_text = nil, nil

    local function render_progress(snapshot)
      if type(snapshot) ~= "table" then
        return
      end
      local elapsed = 0
      if type(snapshot.startedAt) == "number" then
        elapsed = math.max(0, ctx.clock.now() - snapshot.startedAt)
      end
      local rate = snapshot.rate
      if rate == nil then
        rate = GrillCurve.Rate(elapsed, cfg()) or 0
      end
      local time_text = "已烤 " .. GrillCurve.Format(elapsed) .. " 秒"
      local rate_text = "倍率 " .. GrillCurve.Format(rate)
      if time_text ~= last_time_text then
        last_time_text = time_text
        time_label.Text = time_text
      end
      if rate_text ~= last_rate_text then
        last_rate_text = rate_text
        rate_label.Text = rate_text
      end
    end

    ps:effect("GrillLabels", function(es)
      local snapshot = es:d(ctx.store.grill) or {}
      title.Text = item_name(snapshot.itemId)
      panel.Visible = true
      render_progress(snapshot)
    end)

    ps:subscribe(ctx.clock.on_frame, function()
      local snapshot = ctx.store.grill:now()
      if type(snapshot) ~= "table" or snapshot.rate ~= nil then
        return
      end
      render_progress(snapshot)
    end)

    ctx.connect(ps, takeout.OnClicked, function()
      send_grill(ctx, shared, "Takeout")
    end)

    ctx.connect(ps, close_btn.OnClicked, function()
      shared.panel_hidden:set(true)
    end)
  end)

  scope:effect("GrillNotices", function(es)
    local snapshot = es:d(ctx.store.grill)
    local state = type(snapshot) == "table" and snapshot.state or nil
    if state == "burnt" then
      if not burnt_noticed then
        burnt_noticed = true
        ViewUtil.notify(ctx, cfg().BurntText)
      end
    else
      burnt_noticed = false
      if not active_grill(snapshot) and shared.panel_hidden:now() then
        shared.panel_hidden:set(false)
      end
    end
  end)

  scope:subscribe(ctx.store.on_server_event, function(event)
    if type(event) ~= "table" or event.channel ~= "GrillResult" then
      return
    end
    local result = event.payload
    if type(result) ~= "table" then
      return
    end
    if result.ok then
      if result.action == "Start" then
        burnt_noticed = false
        shared.panel_hidden:set(false)
      elseif result.action == "Takeout" then
        ViewUtil.notify(ctx, cfg().CookedPrefix .. item_name(result.itemId)
          .. "（倍率 " .. GrillCurve.Format(result.rate or 1) .. "）")
      end
      return
    end
    local reason = result.reason
    if reason == "token-warn" then
      ViewUtil.notify(ctx, cfg().TokenWarnText)
      shared.armed_until = ctx.clock.now() + 5
    elseif reason == "no-fish" then
      ViewUtil.notify(ctx, cfg().NoFishText)
    elseif reason == "full" then
      ViewUtil.notify(ctx, cfg().FullText)
    elseif reason == "burnt" then
      if not burnt_noticed then
        burnt_noticed = true
        ViewUtil.notify(ctx, cfg().BurntText)
      end
    elseif reason == "busy" then
      shared.panel_hidden:set(false)
      send_grill(ctx, shared, "Query")
    end
  end)
end

function GrillView.spec(options)
  return {
    name = "Grill",
    mount = function(scope, ctx)
      GrillView.mount(scope, ctx, options)
    end,
  }
end

function GrillView.bubble_spec(options)
  options = type(options) == "table" and options or {}
  return {
    items = function(es, store)
      local position = es:d(store.position)
      local character = es:d(store.local_character)
      local list = {}
      if position == nil then
        return list
      end
      local radius = BodyScale.InteractionRadius(character, cfg().Radius)
      local radius_sq = radius * radius
      for index, entry in ipairs(options.anchors or {}) do
        local dist_sq = ViewUtil.distance_sq_xz(position, entry.position)
        if dist_sq ~= nil and dist_sq <= radius_sq then
          list[#list + 1] = {
            index = entry.index or index,
            name = entry.name or (entry.point and entry.point.AnchorName) or ("Grill_" .. tostring(index)),
            position = entry.position,
          }
        end
      end
      return list
    end,
    key_of = function(entry)
      return "grill:" .. tostring(entry.index) .. ":" .. tostring(entry.name)
    end,
    mount = function(scope, ctx, item_signal)
      local shared = ensure_shared(options.shared or (ctx.services and ctx.services.grill_shared))
      local entry = item_signal:now()
      local suffix = tostring(entry.index)
      local node = ViewUtil.create_anchor_scene_node(
        scope, ctx, entry, cfg().BubbleHeight, "grill", "SceneNodeGrill_" .. suffix
      )
      local button = ctx.create_node(scope, "EUIButton", {
        Name = "BtnGrill" .. suffix,
        Parent = node,
        ButtonText = cfg().BubbleText,
        TouchEnabled = true,
        Visible = true,
      })
      ctx.connect(scope, button.OnClicked, function()
        click_grill(ctx, shared)
      end)
    end,
  }
end

return GrillView
