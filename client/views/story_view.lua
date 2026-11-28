local Tokens = require("client.ui.tokens")
local Layout = require("client.ui.layout")
local Primitives = require("client.ui.primitives")
local Controls = require("client.ui.controls")
local ViewUtil = require("client.views.view_util")

local StoryView = {}

local PANEL_H = 440
local PAD = Tokens.SPACE.PANEL_PAD

function StoryView.modal_spec(options)
  options = options or {}
  return function(scope, ctx)
    local resolution = ViewUtil.get_resolution(ctx, options)
    if resolution == nil then return end

    local width = Layout.snap4(math.min(928, resolution.x - PAD * 2), 480)
    local shell = Controls.modal_shell(scope, ctx, {
      name = "ScreenStory",
      title = "钓鱼佬",
      title_name = "DialogueTitle",
      width = width,
      height = PANEL_H,
      show_close = false,
      get_resolution = function() return resolution end,
    })
    local panel = shell.panel
    local title = shell.title_label

    -- 单层扁平奶白底板，正文留足 32px 内边距，只写 TextColor、绝不写 .Color
    local body_w = width - PAD * 2
    local body = Primitives.label(scope, ctx, {
      name = "DialogueBody",
      parent = panel,
      rect = Layout.from_top_left(PANEL_H, PAD, 96, body_w, 224),
      text = "",
      font_size = Tokens.FONT_SIZE.BODY,
      color = Tokens.COLOR.TEXT_DARK,
      align_x = 0,
      align_y = 0,
      z_order = 2,
    })

    local payload = ctx.store.modal_payload:now() or ctx.store.story:now() or {}
    local page = 1
    ---@type fun()
    local render

    local confirm_btn = Controls.button(scope, ctx, {
      name = "BtnStoryConfirm",
      parent = panel,
      rect = Layout.bottom_center(width, PAD, 300, 64),
      text = "已读，开始钓鱼",
      variant = "gold",
      font_size = Tokens.FONT_SIZE.BUTTON,
      z_order = 2,
      on_click = function()
        if type(payload) ~= "table" then return end
        local lines = type(payload.lines) == "table" and payload.lines or { payload.text or payload.fallbackText or "" }
        if #lines > 1 and page < #lines then
          page = page + 1
          render()
          return
        end
        local services = ctx.services or {}
        if type(services.send_story) == "function" then
          services.send_story({ action = "read", read_key = payload.read_key or "opening" })
        end
      end,
    })

    render = function()
      if type(payload) ~= "table" then return end
      local lines = type(payload.lines) == "table" and payload.lines or { payload.text or payload.fallbackText or "" }
      if #lines == 0 then lines = { "" } end
      page = math.max(1, math.min(page, #lines))
      local suffix = #lines > 1 and ("  " .. page .. "/" .. #lines) or ""
      title.Text = tostring(payload.title or "钓鱼佬") .. suffix
      body.Text = ViewUtil.wrap_text(lines[page], math.max(12, math.floor(body_w / Tokens.FONT_SIZE.BODY)))
      local btn_text = page < #lines and "下一段"
        or (payload.read_key and "已读，开始钓鱼" or "知道了")
      Controls.set_button_text(confirm_btn, btn_text)
      Controls.set_button_enabled(confirm_btn, true, "gold")
    end

    render()
    scope:effect("StoryProjection", function(es)
      local value = es:d(ctx.store.story)
      if type(value) == "table" then
        if value ~= payload then payload, page = value, 1 end
        render()
      end
    end)
  end
end

return StoryView
