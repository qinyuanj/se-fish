local BodyScale = require("common.body_scale")
local GameCfg = require("common.game_cfg")
local GrillCurve = require("common.grill_curve")
local Spoke = require("common.packages.spoke.api")
local Tokens = require("client.ui.tokens")
local Layout = require("client.ui.layout")
local Primitives = require("client.ui.primitives")
local Controls = require("client.ui.controls")
local ViewUtil = require("client.views.view_util")
local InteractPromptArbiter = require("client.views.interact_prompt_arbiter")

local State = Spoke.State

local GrillView = {}

-- 烤架进度操作面板尺寸（中下方安全带 y ∈ [176, 276]，避开 EquipBottom 与 CenterClear）。
local PANEL_W = 720
local PANEL_H = 100
local PANEL_BOTTOM = 176
local PAD_X = 20
local TAKEOUT_W = 132
local CLOSE_W = 96
local BTN_H = 56
local BTN_GAP = 12

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

--- 刷新时间、倍率与进度条；文案没变就不写节点。
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
  if self.progress ~= nil then
    local burn_sec = cfg().BurnSec or 4.5
    local pct = burn_sec > 0 and math.max(0, math.min(100, (elapsed / burn_sec) * 100)) or 0
    self.progress.set_percent(pct)
  end
end

--- 焦糊提示每轮只发一次。
---@param self GrillHandle
function GrillBehavior.notice_burnt(self)
  if self.burnt_noticed then return end
  self.burnt_noticed = true
  ViewUtil.notify(self.ctx, cfg().BurntText)
end

--- 建烤架深海蓝半透明胶囊面板、进度条与取出/关闭操作按钮（全量 4px 栅格中心排版，零文字重叠）。
---@param self GrillHandle
---@param ps table phase scope
function GrillBehavior.mount_panel(self, ps)
  local ctx, shared = self.ctx, self.shared
  local res = Primitives.resolution(ctx, self.options) or { x = 1920, y = 1080 }
  local panel_w = math.min(PANEL_W, Layout.snap4(res.x - 64, 560))
  local panel = Primitives.capsule(ps, ctx, {
    name = "GrillPanel",
    rect = Layout.bottom_center(res.x, PANEL_BOTTOM, panel_w, PANEL_H),
    z_order = Tokens.Z.HUD_POPUP_BG,
    visible = true,
  })
  panel.TouchEnabled = true
  panel.SwallowTouchEnabled = true

  local left_w = panel_w - PAD_X * 2 - TAKEOUT_W - BTN_GAP - CLOSE_W - 16
  local rate_w = 116
  local time_w = 144
  local title_w = math.max(88, left_w - time_w - rate_w - 16)

  local title = Primitives.label(ps, ctx, {
    name = "GrillTitle",
    parent = panel,
    rect = Layout.from_top_left(PANEL_H, PAD_X, 8, title_w, 32),
    text = "",
    font_size = Tokens.FONT_SIZE.BODY,
    bold = true,
    color = Tokens.COLOR.TEXT_GOLD,
    outline = true,
    outline_color = Tokens.COLOR.OUTLINE_DARK,
    align_x = 0,
    align_y = 1,
    z_order = 1,
  })

  local time_label = Primitives.label(ps, ctx, {
    name = "GrillTime",
    parent = panel,
    rect = Layout.from_top_left(PANEL_H, PAD_X + title_w + 8, 8, time_w, 32),
    text = "",
    font_size = Tokens.FONT_SIZE.CAPTION,
    bold = true,
    color = Tokens.COLOR.WHITE,
    outline = true,
    outline_color = Tokens.COLOR.OUTLINE_DARK,
    align_x = 1,
    align_y = 1,
    z_order = 1,
  })

  local rate_label = Primitives.label(ps, ctx, {
    name = "GrillRate",
    parent = panel,
    rect = Layout.from_top_left(PANEL_H, PAD_X + title_w + 8 + time_w + 8, 8, rate_w, 32),
    text = "",
    font_size = Tokens.FONT_SIZE.CAPTION,
    bold = true,
    color = Tokens.COLOR.TEXT_GOLD,
    outline = true,
    outline_color = Tokens.COLOR.OUTLINE_DARK,
    align_x = 2,
    align_y = 1,
    z_order = 1,
  })

  local progress = Controls.progress_bar(ps, ctx, {
    name = "GrillProgress",
    parent = panel,
    rect = Layout.from_top_left(PANEL_H, PAD_X, 52, left_w, 36),
    fill_color = Tokens.COLOR.HUNGER,
    percent = 0,
    text = "",
    font_size = Tokens.FONT_SIZE.CAPTION,
    z_order = 1,
  })

  Controls.button(ps, ctx, {
    name = "GrillTakeout",
    parent = panel,
    rect = Layout.from_top_right(panel_w, PANEL_H, PAD_X + CLOSE_W + BTN_GAP, 22, TAKEOUT_W, BTN_H),
    text = cfg().TakeoutText,
    variant = "gold",
    font_size = Tokens.FONT_SIZE.BODY,
    z_order = 2,
    on_click = function()
      send_grill(ctx, shared, "Takeout")
    end,
  })

  Controls.button(ps, ctx, {
    name = "GrillClose",
    parent = panel,
    rect = Layout.from_top_right(panel_w, PANEL_H, PAD_X, 22, CLOSE_W, BTN_H),
    text = "关闭",
    variant = "blue",
    font_size = Tokens.FONT_SIZE.BODY,
    z_order = 2,
    on_click = function()
      shared.panel_hidden:set(true)
    end,
  })

  self.panel, self.title, self.time_label, self.rate_label = panel, title, time_label, rate_label
  self.progress = progress
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
    progress = nil,
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
        local aname = entry.name or (entry.point and entry.point.AnchorName) or ("Grill_" .. tostring(index))
        if dist_sq ~= nil and dist_sq <= radius_sq
            and InteractPromptArbiter.is_exclusive(position, character, aname) then
          list[#list + 1] = {
            index = entry.index or index,
            name = aname,
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
      local bw = Layout.snap4(GameCfg.InteractionBubble.Width, 160)
      local bh = Layout.snap4(GameCfg.InteractionBubble.Height, 64)
      Controls.button(scope, ctx, {
        name = "BtnGrill" .. suffix,
        parent = node,
        rect = Layout.rect(bw / 2, bh / 2, bw, bh),
        text = cfg().BubbleText,
        variant = "gold",
        font_size = Tokens.FONT_SIZE.BUTTON,
        z_order = 1,
        on_click = function()
          click_grill(ctx, shared)
        end,
      })
    end,
  }
end

return GrillView
