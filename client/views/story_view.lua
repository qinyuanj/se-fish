local ViewUtil = require("client.views.view_util")
local StoryView = {}

function StoryView.modal_spec(options)
  options = options or {}
  return function(scope, ctx)
    local resolution = ViewUtil.get_resolution(ctx, options); if resolution == nil then return end
    local width = math.min(1000, resolution.x - 60)
    local panel = ctx.create_node(scope, "EUIImage", {
      Parent = ctx.root_node, Name = "ScreenStory", Position = Vector2.New(resolution.x / 2, resolution.y / 2),
      Size = Vector2.New(width, 360), Image = "official://image/11017", Color = Color.New(22, 38, 54, 250),
      Visible = true, LocalZOrder = 20,
    })
    panel.TouchEnabled, panel.SwallowTouchEnabled = true, true
    local function label(name, x, y, w, h, size)
      return ctx.create_node(scope, "EUITextLabel", { Parent = panel, Name = name, Text = "",
        Position = Vector2.New(x, y), Size = Vector2.New(w, h), FontSize = size,
        Color = Color.New(255, 255, 255, 255), TextHorizontalAlignment = 1, TextVerticalAlignment = 1,
        LocalZOrder = 22 })
    end
    local function button(name, x, w, text, on_click)
      local node = ctx.create_node(scope, "EUIButton", { Parent = panel, Name = name,
        Position = Vector2.New(x, -115), Size = Vector2.New(w, 80), ButtonText = "", LocalZOrder = 21 })
      node.TouchEnabled = true
      ctx.connect(scope, node.OnClicked, on_click)
      local text_node = label(name .. "Label", x, -115, w, 80, 26)
      text_node.Text = text
      return node, text_node
    end
    local title = label("DialogueTitle", 0, 120, width - 50, 50, 30)
    title.Color = Color.New(255, 225, 130, 255)
    local body = label("DialogueBody", 0, -10, width - 80, 130, 26)
    local payload, page = ctx.store.modal_payload:now() or ctx.store.story:now() or {}, 1
    local render
    local next_button
    next_button = button("DialogueNext", -160, 260, "下一段", function()
      if type(payload) ~= "table" or type(payload.lines) ~= "table" then return end
      if page < #payload.lines then page = page + 1 render() end
    end)
    local read_button, read_label
    local function send_read()
      if type(payload) ~= "table" then return end
      local services = ctx.services or {}
      if type(services.send_story) == "function" then
        services.send_story({ action = "read", read_key = payload.read_key or "opening" })
      end
    end
    read_button, read_label = button("DialogueRead", 160, 300, "已读，开始钓鱼", send_read)
    render = function()
      if type(payload) ~= "table" then return end
      local lines = type(payload.lines) == "table" and payload.lines or { payload.text or payload.fallbackText or "" }
      if #lines == 0 then lines = { "" } end
      page = math.max(1, math.min(page, #lines))
      title.Text = tostring(payload.title or "钓鱼佬") .. "  " .. page .. "/" .. #lines
      body.Text = ViewUtil.wrap_text(lines[page], math.max(12, math.floor((width - 80) / 26)))
      next_button.TouchEnabled = page < #lines
      read_button.TouchEnabled = true
      read_label.Text = payload.read_key and "已读，开始钓鱼" or "知道了"
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
