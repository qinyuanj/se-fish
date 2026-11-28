-- 客户端收线覆盖层宿主入口契约。
-- 失败方式先列：
--   1. 上钩不挂载收线条、点击不上行聚合、进度下行不刷新显示；
--   2. 关闭、脱钩、上岸、濒死或根销毁后残留节点与监听；
--   3. 设备分辨率不按 options.get_resolution → services.get_device_resolution → 宿主 EUI 的顺序回退，宿主抛错被吞成静默 nil，或全部不可用时仍半建遮罩。

-- 客户端收线覆盖层宿主入口契约。
-- 失败方式先列：
--   1. 上钩不挂载收线条、点击不上行聚合、进度下行不刷新显示；
--   2. 关闭、脱钩、上岸、濒死或根销毁后残留节点与监听；
--   3. 设备分辨率不按 options.get_resolution → services.get_device_resolution → 宿主 EUI 的顺序回退，宿主抛错被吞成静默 nil，或全部不可用时仍半建遮罩。

local Eui = require("tests.support.eui_double")
local ClientStore = require("client.store.client_store")
local RootView = require("client.views.root_view")
local ReelOverlayView = require("client.views.reel_overlay_view")
local SpokeClock = require("common.spoke_clock")

local function mount(opts)
  opts = opts or {}
  local clock = SpokeClock.new(20)
  local store, writer = ClientStore.new({ clock = clock })
  local root = Eui.node({ Name = "UIRoot" })
  local sent, closed, created = {}, {}, {}
  local reel = {}
  local services = {
    reel = reel,
    now = function() return clock.now() end,
    send_reel = function(payload) sent[#sent + 1] = payload end,
    send_close = function(payload) closed[#closed + 1] = payload end,
  }
  if not opts.without_device_resolution then
    services.get_device_resolution = opts.get_device_resolution or function() return { x = 1920, y = 1080 } end
  end
  local view = RootView.mount(root, store, {
    services = services,
    overlays = { reel = ReelOverlayView.spec(opts.reel_options) },
    create_node = function(kind, props)
      local node = Eui.node({
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

describe("客户端收线覆盖层宿主入口（#302）", function()
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
    local mask = child(env, "ReelMask")
    assert.is_not_nil(mask)
    assert.are.equal("EUILayout", mask.Kind)
    assert.are.equal(960, mask.Position.x)
    assert.are.equal(540, mask.Position.y)
    assert.are.equal("function", type(env.reel.click))
    env.writer:ingest_event("ReelInRE", { action = "started", session = "s1", progress = 50 })
    assert.are.equal(50, child(env, "ReelBar").Percent)
    assert.is_true(Eui.click(mask))
    env.clock:advance(0.1)
    assert.are.equal(1, #env.sent)
    assert.are.same({ s = "s1", n = 1, q = 1 }, env.sent[1])
    env.writer:ingest_event("ReelInRE", { action = "progress", session = "s1", progress = 55, q = 1 })
    assert.are.equal(55, child(env, "ReelBar").Percent)
    local close_btn = child(env, "BtnReelClose")
    assert.are.equal("", close_btn.ButtonText)
    assert.are.equal("结束收线", close_btn:FindFirstChild("LabelButtonText", false).Text)
    env.view:dispose()
  end)

  it("关闭、脱钩、上岸、濒死和根销毁都逆序释放节点与监听", function()
    local env = mount()
    env.writer:ingest_event("CastState", { phase = "hooked", reelSession = "s1", castId = 1 })
    env.writer:ingest_event("ReelInRE", { action = "started", session = "s1", progress = 50 })
    local close = child(env, "BtnReelClose")
    assert.is_true(Eui.click(close))
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

  it("设备分辨率按 options → services → 宿主 EUI 依次回退，全部不可用时不建整层", function()
    local saved_game = rawget(_G, "game")
    local saved_print = _G.print
    local logs = {}
    local function capture_print()
      logs = {}
      _G.print = function(...)
        local parts = {}
        for i = 1, select("#", ...) do parts[i] = tostring((select(i, ...))) end
        logs[#logs + 1] = table.concat(parts, "\t")
      end
    end
    local function restore_print()
      _G.print = saved_print
      return table.concat(logs, "\n")
    end
    local ok, err = pcall(function()
      local function host_game(eui_manager)
        return {
          GetService = function(_, service)
            if service ~= "Players" then return nil end
            return { LocalPlayer = { PlayerGui = { EuiManager = eui_manager } } }
          end,
        }
      end
      local function mask_size(env, name)
        local mask = child(env, "ReelMask")
        assert.is_not_nil(mask, name)
        return { x = mask.Size.x, y = mask.Size.y }
      end

      -- 1. options.get_resolution 优先：宿主与服务注入都取不到它这一档
      _G.game = host_game({ GetDeviceResolution = function() return { x = 800, y = 600 } end })
      local injected = mount({
        get_device_resolution = function() return { x = 1920, y = 1080 } end,
        reel_options = { get_resolution = function() return { x = 1280, y = 720 } end },
      })
      injected.writer:ingest_event("CastState", { phase = "hooked", reelSession = "r1", castId = 1 })
      assert.are.same({ x = 1280, y = 720 }, mask_size(injected, "options 注入优先"))
      injected.view:dispose()

      -- 2. options 抛错：记录日志并回退 services.get_device_resolution
      capture_print()
      local fell_back = mount({
        get_device_resolution = function() return { x = 1600, y = 900 } end,
        reel_options = { get_resolution = function() error("options-broken") end },
      })
      fell_back.writer:ingest_event("CastState", { phase = "hooked", reelSession = "r2", castId = 2 })
      assert.are.same({ x = 1600, y = 900 }, mask_size(fell_back, "options 抛错回退 services"))
      assert.matches("读取分辨率失败", restore_print())
      fell_back.view:dispose()

      -- 3. services 返回非法分辨率：回退宿主 EUI 的设备分辨率
      _G.game = host_game({ GetDeviceResolution = function() return { x = 1600, y = 900 } end })
      local from_host = mount({ get_device_resolution = function() return { x = 0, y = 0 } end })
      from_host.writer:ingest_event("CastState", { phase = "hooked", reelSession = "r3", castId = 3 })
      assert.are.same({ x = 1600, y = 900 }, mask_size(from_host, "宿主 EUI 分辨率"))
      from_host.view:dispose()

      -- 4. 宿主 EUI 读设备分辨率抛错：整层不建，日志点名读取宿主的调用点
      _G.game = host_game({ GetDeviceResolution = function() error("eui-down") end })
      capture_print()
      local broken_host = mount({ without_device_resolution = true })
      broken_host.writer:ingest_event("CastState", { phase = "hooked", reelSession = "r4", castId = 4 })
      assert.is_nil(child(broken_host, "ReelMask"))
      assert.matches("读取宿主分辨率失败", restore_print())
      broken_host.view:dispose()

      -- 5. 没有宿主（game 缺失）也没有注入：整层不建，日志说明返回 nil
      _G.game = nil
      capture_print()
      local no_host = mount({ without_device_resolution = true })
      no_host.writer:ingest_event("CastState", { phase = "hooked", reelSession = "r5", castId = 5 })
      assert.is_nil(child(no_host, "ReelMask"))
      assert.matches("未获取到有效设备分辨率，返回 nil", restore_print())
      no_host.view:dispose()
    end)

    _G.game = saved_game
    _G.print = saved_print
    if not ok then
      error(err, 0)
    end
  end)
end)
