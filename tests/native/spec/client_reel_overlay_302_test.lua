local Eui = require("tests.support.eui_double")
local ClientStore = require("client.Store.ClientStore")
local RootView = require("client.Views.RootView")
local ReelOverlayView = require("client.Views.ReelOverlayView")
local SpokeClock = require("common.spoke_clock")

local function mount()
  local clock = SpokeClock.new(20)
  local store, writer = ClientStore.new({ clock = clock })
  local root = Eui.Node({ Name = "UIRoot" })
  local sent, closed, created = {}, {}, {}
  local reel = {}
  local view = RootView.mount(root, store, {
    services = {
      reel = reel,
      now = function() return clock.now() end,
      send_reel = function(payload) sent[#sent + 1] = payload end,
      send_close = function(payload) closed[#closed + 1] = payload end,
    },
    overlays = { reel = ReelOverlayView.spec() },
    create_node = function(kind, props)
      local node = Eui.Node({
        Kind = kind, Name = props and props.Name, Parent = props and props.Parent,
        Visible = props and props.Visible, Text = props and (props.Text or props.ButtonText) or "",
        Position = props and props.Position, Size = props and props.Size,
        TouchEnabled = kind == "EUIButton",
      })
      created[#created + 1] = node
      return node
    end,
  })
  return { clock = clock, store = store, writer = writer, root = root, view = view,
    sent = sent, closed = closed, created = created, reel = reel }
end

local function child(env, name)
  return env.root:FindFirstChild(name, true)
end

local function alive(env)
  local n = 0
  for _, node in ipairs(env.created) do if not node.Destroyed then n = n + 1 end end
  return n
end

describe("客户端收线覆盖层宿主接缝（#302）", function()
  local saved_vector, saved_color
  before_each(function()
    saved_vector, saved_color = rawget(_G, "Vector2"), rawget(_G, "Color")
    _G.Vector2 = { New = function(x, y) return { x = x, y = y } end }
    _G.Color = { New = function(r, g, b, a) return { r = r, g = g, b = b, a = a } end }
  end)
  after_each(function()
    _G.Vector2, _G.Color = saved_vector, saved_color
  end)

  it("上钩才挂载收线条，点击经聚合上行，进度下行刷新显示", function()
    local env = mount()
    assert.is_nil(child(env, "ReelMask"))
    env.writer:ingest_event("CastState", { phase = "hooked", reelSession = "s1", castId = 1 })
    assert.is_not_nil(child(env, "ReelMask"))
    assert.are.equal("function", type(env.reel.click))
    env.writer:ingest_event("ReelInRE", { action = "started", session = "s1", progress = 50 })
    assert.are.equal(50, child(env, "ReelBar").Percent)
    env.reel.click("s1")
    env.clock:advance(0.1)
    assert.are.equal(1, #env.sent)
    assert.are.same({ s = "s1", n = 1, q = 1 }, env.sent[1])
    env.writer:ingest_event("ReelInRE", { action = "progress", session = "s1", progress = 55, q = 1 })
    assert.are.equal(55, child(env, "ReelBar").Percent)
    env.view:dispose()
  end)

  it("关闭、脱钩、上岸、濒死和根销毁都逆序释放节点与监听", function()
    local env = mount()
    env.writer:ingest_event("CastState", { phase = "hooked", reelSession = "s1", castId = 1 })
    env.writer:ingest_event("ReelInRE", { action = "started", session = "s1", progress = 50 })
    local close = child(env, "BtnReelClose")
    assert.is_true(Eui.Click(close))
    assert.are.same({ session = "s1" }, env.closed[1])
    assert.is_nil(child(env, "ReelMask"))

    env.writer:ingest_event("CastState", { phase = "hooked", reelSession = "s2", castId = 2 })
    env.writer:ingest_event("ReelInRE", { action = "unhooked", session = "s2", progress = 0 })
    env.writer:ingest_event("CastState", { phase = "unhooked" })
    assert.is_nil(child(env, "ReelMask"))

    env.writer:ingest_event("CastState", { phase = "hooked", reelSession = "s3", castId = 3 })
    env.writer:ingest_event("SurvivalState", { phase = "downed" })
    assert.is_nil(child(env, "ReelMask"))

    env.writer:ingest_event("SurvivalState", { phase = "alive" })
    env.writer:ingest_event("CastState", { phase = "hooked", reelSession = "s4", castId = 4 })
    assert.is_true(alive(env) > 0)
    env.root:Destroy()
    assert.are.equal(0, alive(env))
    assert.are.equal(0, close.OnClicked:Count())
  end)
end)
