local MainHudLayout = require("client.main_hud_layout")
local Modal = require("client.views.economy_modal")
local ViewUtil = require("client.views.view_util")
local GuideView = {}

function GuideView.spec(options)
  options = options or {}
  return {
    name = "Guide",
    mount = function(scope, ctx)
      local resolution = ViewUtil.get_resolution(ctx, options)
      local rects = MainHudLayout.Compute({ width = resolution.x, height = resolution.y,
        itemBarSlots = 0, reeling = false }).Rects
      local panel, toggle_rect = rects.QuestPanel, rects.QuestToggle
      local background = ctx.create_node(scope, "EUIImage", {
        Parent = ctx.root_node, Name = "QuestBackground", Position = Vector2.New(panel.x, panel.y),
        Size = Vector2.New(panel.w, panel.h), Image = "official://image/11017",
        Color = Color.New(16, 24, 34, 180), Visible = false,
      })
      background.TouchEnabled, background.SwallowTouchEnabled = false, false
      local label = ctx.create_node(scope, "EUITextLabel", {
        Parent = ctx.root_node, Name = "QuestLabel", Text = "", Visible = false,
        Position = Vector2.New(panel.x, panel.y), Size = Vector2.New(panel.w - 20, panel.h - 12),
        FontSize = 24, Color = Color.New(255, 255, 255, 255),
        TextHorizontalAlignment = 1, TextVerticalAlignment = 1,
      })
      local button = Modal.button(scope, ctx, ctx.root_node, "QuestToggle", "", function() end)
      button.Position, button.Size = Vector2.New(toggle_rect.x, toggle_rect.y), Vector2.New(toggle_rect.w, toggle_rect.h)
      local toggle_label = ctx.create_node(scope, "EUITextLabel", {
        Parent = ctx.root_node, Name = "QuestToggleLabel", Text = "收起任务",
        Position = Vector2.New(toggle_rect.x, toggle_rect.y), Size = Vector2.New(toggle_rect.w, toggle_rect.h),
        FontSize = 22, Color = Color.New(255, 255, 255, 255),
        TextHorizontalAlignment = 1, TextVerticalAlignment = 1,
      })
      local shown, collapsed = false, false
      local function render()
        local expanded = shown and not collapsed
        label.Visible, background.Visible = expanded, expanded
        button.Visible, button.TouchEnabled, toggle_label.Visible = shown, shown, shown
        toggle_label.Text = collapsed and "展开任务" or "收起任务"
      end
      ctx.connect(scope, button.OnClicked, function() collapsed = not collapsed render() end)
      scope:effect("QuestProjection", function(es)
        local quest = es:d(ctx.store.quest)
        shown = type(quest) == "table" and type(quest.text) == "string" and quest.hidden ~= true
        if shown then label.Text = ViewUtil.wrap_text(quest.text, math.max(1, math.floor((panel.w - 20) / 24))) end
        render()
      end)
      render()
    end,
  }
end

return GuideView
