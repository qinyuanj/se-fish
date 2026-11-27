
local BodyScale = require("common.body_scale")
local GameCfg = require("common.game_cfg")
local GrillCurve = require("common.grill_curve")
local Spoke = require("common.packages.spoke.api")
local ViewUtil = require("client.views.view_util")

local State = Spoke.State

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

-- 烤架面板句柄：面板节点、上一帧文案与焦糊提示标记都留在句柄上；
-- 方法名沿用拆分前的局部函数名，挂载入口只做装配。
---@class GrillHandle: table<string, any>
---@type GrillHandle
local GrillBehavior = {}

--- 刷新时间与倍率两行；文案没变就不写节点。
---@param self GrillHandle
---@param snapshot table|nil
function GrillBehavior.render_progress(self, snapshot)
  if type(snapshot) ~= "table" then
    return
  end
  local ctx = self.ctx
  ---@type number
  local elapsed = 0
  if type(snapshot.startedAt) == "number" then
    elapsed = math.max(0, ctx.clock.now() - snapshot.startedAt)
  end
  local rate = snapshot.rate
  if rate == nil then
    rate = GrillCurve.rate(elapsed, cfg()) or 0
  end
  local time_text = "已烤 " .. GrillCurve.Format(elapsed) .. " 秒"
  local rate_text = "倍率 " .. GrillCurve.Format(rate)
  if time_text ~= self.last_time_text then
    self.last_time_text = time_text
    self.time_label.Text = time_text
  end
  if rate_text ~= self.last_rate_text then
    self.last_rate_text = rate_text
    self.rate_label.Text = rate_text
  end
end

--- 焦糊提示每轮只发一次。
---@param self GrillHandle
function GrillBehavior.notice_burnt(self)
  if self.burnt_noticed then return end
  self.burnt_noticed = true
  ViewUtil.notify(self.ctx, cfg().BurntText)
end

--- 建面板节点并接标签投影、逐帧刷新与取餐/关闭按钮。
---@param self GrillHandle
---@param ps table phase scope
function GrillBehavior.mount_panel(self, ps)
  local ctx, shared = self.ctx, self.shared
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

  self.panel, self.title, self.time_label, self.rate_label = panel, title, time_label, rate_label
  self.last_time_text, self.last_rate_text = nil, nil

  ps:effect("GrillLabels", function(es)
    local snapshot = es:d(ctx.store.grill) or {}
    title.Text = item_name(snapshot.itemId)
    panel.Visible = true
    self:render_progress(snapshot)
  end)

  ps:subscribe(ctx.clock.on_frame, function()
    local snapshot = ctx.store.grill:now()
    if type(snapshot) ~= "table" or snapshot.rate ~= nil then
      return
    end
    self:render_progress(snapshot)
  end)

  ctx.connect(ps, takeout.OnClicked, function()
    send_grill(ctx, shared, "Takeout")
  end)

  ctx.connect(ps, close_btn.OnClicked, function()
    shared.panel_hidden:set(true)
  end)
end

--- 烤架状态通知：焦糊只提示一次；不在烤制中时把隐藏面板放回来。
---@param self GrillHandle
---@param es table EffectScope
function GrillBehavior.on_notices(self, es)
  local snapshot = es:d(self.ctx.store.grill)
  local state = type(snapshot) == "table" and snapshot.state or nil
  if state == "burnt" then
    self:notice_burnt()
  else
    self.burnt_noticed = false
    local shared = self.shared
    if not active_grill(snapshot) and shared.panel_hidden:now() then
      shared.panel_hidden:set(false)
    end
  end
end

--- GrillResult 回执：成功分支复位标记，失败分支按原因提示。
---@param self GrillHandle
---@param event any
function GrillBehavior.on_server_event(self, event)
  if type(event) ~= "table" or event.channel ~= "GrillResult" then
    return
  end
  local result = event.payload
  if type(result) ~= "table" then
    return
  end
  local ctx, shared = self.ctx, self.shared
  if result.ok then
    if result.action == "Start" then
      self.burnt_noticed = false
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
    self:notice_burnt()
  elseif reason == "busy" then
    shared.panel_hidden:set(false)
    send_grill(ctx, shared, "Query")
  end
end

--- 挂载烤架面板：造句柄、注册可见性 memo 与面板 phase、接通知与回执订阅。
---@param scope table
---@param ctx table
---@param options table|nil
function GrillView.mount(scope, ctx, options)
  options = type(options) == "table" and options or {}
  ---@type GrillHandle
  local self = {
    scope = scope,
    ctx = ctx,
    options = options,
    shared = ensure_shared(options.shared or (ctx.services and ctx.services.grill_shared)),
    burnt_noticed = false,
    panel = nil,
    title = nil,
    time_label = nil,
    rate_label = nil,
    last_time_text = nil,
    last_rate_text = nil,
  }
  for name, method in pairs(GrillBehavior) do self[name] = method end

  local shared = self.shared
  local active = scope:memo("GrillVisible", function(ms)
    return active_grill(ms:d(ctx.store.grill)) and not ms:d(shared.panel_hidden)
  end)

  scope:phase("GrillPanelPhase", active, function(ps) self:mount_panel(ps) end)

  scope:effect("GrillNotices", function(es) self:on_notices(es) end)

  scope:subscribe(ctx.store.on_server_event, function(event) self:on_server_event(event) end)
end

function GrillView.spec(options)
  return ViewUtil.hud_spec("Grill", GrillView.mount, options)
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
      local radius = BodyScale.interaction_radius(character, cfg().Radius)
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
