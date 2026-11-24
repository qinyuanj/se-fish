local Eui = require("tests.support.eui_double")
local ClientStore = require("client.store.client_store")
local RootView = require("client.views.root_view")
local ReelOverlayView = require("client.views.reel_overlay_view")
local SpokeClock = require("common.spoke_clock")

local Host = {}
function Host.new()
  local saved_vector, saved_color = rawget(_G, "Vector2"), rawget(_G, "Color")
  _G.Vector2 = { New = function(x, y) return { x = x, y = y } end }
  _G.Color = { New = function(r, g, b, a) return { r = r, g = g, b = b, a = a } end }
  local clock = SpokeClock.new(20)
  local store, writer = ClientStore.new({ clock = clock })
  local root = Eui.Node({ Name = "UIRoot" })
  local env = { clock = clock, store = store, writer = writer, root = root, saved_vector = saved_vector, saved_color = saved_color,
    sent = {}, closed = {}, created = {}, reel = {} }
  env.view = RootView.mount(root, store, {
    services = {
      reel = env.reel,
      now = function() return clock.now() end,
      send_reel = function(payload) env.sent[#env.sent + 1] = payload end,
      send_close = function(payload) env.closed[#env.closed + 1] = payload end,
    },
    overlays = { reel = ReelOverlayView.spec() },
    create_node = function(kind, props)
      local node = Eui.Node({ Kind = kind, Name = props and props.Name,
        Parent = props and props.Parent, Visible = props and props.Visible,
        Text = props and (props.Text or props.ButtonText) or "",
        Position = props and props.Position, Size = props and props.Size,
        TouchEnabled = kind == "EUIButton" })
      env.created[#env.created + 1] = node
      return node
    end,
  })
  function env:child(name) return self.root:FindFirstChild(name, true) end
  function env:hook(session, cast_id)
    self.writer:ingest_event("CastState", { phase = "hooked", reelSession = session or "s1", castId = cast_id or 1 })
    self.writer:ingest_event("ReelInRE", { action = "started", session = session or "s1", progress = 50 })
  end
  function env:alive()
    local n = 0
    for _, node in ipairs(self.created) do if not node.Destroyed then n = n + 1 end end
    return n
  end
  function env:dispose()
    if self.view then self.view:dispose() self.view = nil end
    _G.Vector2, _G.Color = self.saved_vector, self.saved_color
  end
  return env
end
return Host
