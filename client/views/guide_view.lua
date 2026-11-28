-- Spoke 主 HUD 左侧任务引导条视图（1A 折叠态单行胶囊 + 展开详情卡片，归属 L2 client.views）：
-- 默认折叠为 1 行当前目标摘要胶囊按钮（QuestToggle），点击切换展开详情面板（QuestBackground + QuestLabel）；
-- 所有文本严格走 Primitives.label（TextColor + 内置圆体，绝不写 Color），显隐对齐 store.hud_visible。

local MainHudLayout = require("client.main_hud_layout")
local Tokens = require("client.ui.tokens")
local Layout = require("client.ui.layout")
local Primitives = require("client.ui.primitives")
local Controls = require("client.ui.controls")
local ViewUtil = require("client.views.view_util")

local GuideView = {}

local SUMMARY_MAX_CHARS = 14

local function single_line_summary(text)
  local first_line = tostring(text or ""):match("^([^\r\n]+)") or ""
  local out, count = {}, 0
  for ch in first_line:gmatch("[%z\1-\127\194-\244][\128-\191]*") do
    if count >= SUMMARY_MAX_CHARS then
      out[#out + 1] = "…"
      break
    end
    out[#out + 1] = ch
    count = count + 1
  end
  return table.concat(out)
end

function GuideView.mount(scope, ctx, options)
  options = options or {}
  local resolution = ViewUtil.get_resolution(ctx, options)
  if resolution == nil then
    return
  end
  local rects = MainHudLayout.compute({
    width = resolution.x,
    height = resolution.y,
    itemBarSlots = 0,
    reeling = false,
  }).rects
  ---@type { x: number, y: number, w: number, h: number }?
  local panel = rects.quest_panel
  ---@type { x: number, y: number, w: number, h: number }?
  local toggle_rect = rects.quest_toggle
  if not panel or not toggle_rect then
    return
  end

  local background = Primitives.capsule(scope, ctx, {
    name = "QuestBackground",
    parent = ctx.root_node,
    rect = panel,
    opacity = Tokens.OPACITY.HUD_SURFACE,
    z_order = Tokens.Z.HUD_BG,
    visible = false,
  })

  local label_w = Layout.snap4(panel.w - Tokens.SPACE.XXL, 32)
  local label_h = Layout.snap4(panel.h - Tokens.SPACE.LG, 24)
  local label = Primitives.label(scope, ctx, {
    name = "QuestLabel",
    parent = ctx.root_node,
    rect = Layout.rect(panel.x, panel.y, label_w, label_h),
    text = "",
    font_size = Tokens.FONT_SIZE.CAPTION,
    bold = false,
    color = Tokens.COLOR.WHITE,
    outline = true,
    outline_color = Tokens.COLOR.OUTLINE_DARK,
    align_x = 0,
    align_y = 1,
    z_order = Tokens.Z.HUD_CONTENT,
    visible = false,
  })

  local button, toggle_label = Controls.button(scope, ctx, {
    name = "QuestToggle",
    parent = ctx.root_node,
    rect = toggle_rect,
    text = "",
    variant = "hud",
    font_size = Tokens.FONT_SIZE.CAPTION,
    bold = true,
    align_x = 0,
    z_order = Tokens.Z.HUD_CONTENT,
    visible = false,
    touch = false,
    label_name = "QuestToggleLabel",
  })
  button.Opacity = Tokens.OPACITY.HUD_SURFACE

  local shown = false
  local collapsed = true
  local current_summary = ""

  local function render(animate_expand)
    local expanded = shown and not collapsed
    background.Visible = expanded
    label.Visible = expanded
    button.Visible = shown
    button.TouchEnabled = shown
    if toggle_label ~= nil then
      toggle_label.Visible = shown
      local prefix = collapsed and "▶ " or "▼ "
      toggle_label.Text = shown and (prefix .. current_summary) or ""
    end
    if expanded and animate_expand then
      Primitives.tween_fade_in(background, Tokens.OPACITY.HUD_SURFACE, Tokens.ANIM.FAST)
    end
  end

  ctx.connect(scope, button.OnClicked, function()
    if not shown then
      return
    end
    collapsed = not collapsed
    render(not collapsed)
  end)

  scope:effect("QuestProjection", function(es)
    local quest = es:d(ctx.store.quest)
    local hud_visible = es:d(ctx.store.hud_visible) ~= false
    local has_quest = type(quest) == "table"
      and type(quest.text) == "string"
      and quest.text ~= ""
      and quest.hidden ~= true
    shown = hud_visible and has_quest
    if has_quest then
      current_summary = single_line_summary(quest.text)
      local cols = math.max(1, math.floor(label_w / Tokens.FONT_SIZE.CAPTION))
      label.Text = ViewUtil.wrap_text(quest.text, cols)
    else
      current_summary = ""
      label.Text = ""
    end
    render(false)
  end)
end

function GuideView.spec(options)
  return ViewUtil.hud_spec("Guide", GuideView.mount, options)
end

return GuideView
