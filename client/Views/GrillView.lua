-- 烧烤进度与取出投影（#310）：订阅只读 GrillState 与时钟。
-- 烤制中显示两位小数倍率；取出只上行 GrillAction。会话结束或根节点销毁由视图树清掉节点与连接。

local GameCfg = require("common.GameCfg")
local GrillCurve = require("common.GrillCurve")
local spoke = require("common.packages.spoke.api")
local State = spoke.State

local GrillView = {}

local function cfg()
  return GameCfg.Grill
end

local function item_name(item_id)
  local definition = item_id and GameCfg.Items.Definitions[item_id]
  return definition and definition.Name or tostring(item_id or "")
end

local function color(rgba)
  if Color then return Color.New(rgba[1], rgba[2], rgba[3], rgba[4] or 255) end
  return rgba
end

local function active_grill(snapshot)
  if type(snapshot) ~= "table" then return false end
  return snapshot.state == "cooking" or snapshot.state == "ready"
end

function GrillView.mount(scope, ctx)
  local services = ctx.services or {}
  local notice = State.new("GrillView.notice", nil)
  local active = scope:memo("GrillVisible", function(ms)
    return active_grill(ms:d(ctx.store.grill))
  end)

  scope:phase("GrillPanelPhase", active, function(ps)
    local elapsed_state = State.new("GrillView.elapsed", 0)
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

    ps:effect("GrillLabels", function(es)
      local snapshot = es:d(ctx.store.grill) or {}
      local elapsed = es:d(elapsed_state)
      local rate = snapshot.rate
      if rate == nil then rate = GrillCurve.Rate(elapsed, cfg()) or 0 end
      title.Text = item_name(snapshot.itemId)
      time_label.Text = "已烤 " .. GrillCurve.Format(elapsed) .. " 秒"
      rate_label.Text = "倍率 " .. GrillCurve.Format(rate)
      panel.Visible = true
    end)

    ps:subscribe(ctx.clock.on_frame, function()
      local snapshot = ctx.store.grill:now()
      if type(snapshot) ~= "table" or type(snapshot.startedAt) ~= "number" then return end
      if snapshot.rate ~= nil then return end
      local now = ctx.clock.now()
      local elapsed = math.max(0, now - snapshot.startedAt)
      if elapsed_state:now() ~= elapsed then elapsed_state:set(elapsed) end
    end)

    ctx.connect(ps, takeout.OnClicked, function()
      if type(services.send_grill) == "function" then
        services.send_grill({ action = "Takeout" })
      end
    end)
  end)

  scope:effect("GrillNotices", function(es)
    local snapshot = es:d(ctx.store.grill)
    local state = type(snapshot) == "table" and snapshot.state or nil
    local previous = notice:now()
    if state == "burnt" and previous ~= "burnt" then
      if type(services.notify) == "function" then services.notify(cfg().BurntText) end
    end
    if state ~= previous then notice:set(state) end
  end)
end

function GrillView.spec()
  return {
    name = "Grill",
    mount = function(scope, ctx)
      GrillView.mount(scope, ctx)
    end,
  }
end

return GrillView
