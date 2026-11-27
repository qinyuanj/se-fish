-- #297-B2 主 HUD 左上状态区（血量环、饥饿环、4 条饥饿红边）与预置金币节点 Spoke 视图测试。
-- 失败方式先列：
--   1. 血量/饥饿度文案未用「血 」「饥饿度 」，或满值字号溢出框宽 / 与金币重叠；
--   2. 血量/饥饿/金币变化不随 ClientStore 实时刷新，或脱离饥饿后红边残留可见；
--   3. 饥饿提醒未按 WarnIntervalSec 节流，或重新进入饥饿时不立即再次提醒；
--   4. 重连重置或根 UI 销毁后遗留动态状态区节点，或误销毁编辑器预置节点 ImageCoin / LabelCoin。

local Eui = require("tests.support.eui_double")
local GameCfg = require("common.game_cfg")
local MainHudLayout = require("client.main_hud_layout")
local ClientStore = require("client.store.client_store")
local RootView = require("client.views.root_view")
local MainHudVitalsView = require("client.views.main_hud_vitals_view")

local function assert_at(node, rect, label)
  assert.is_not_nil(node, label)
  assert.same({ x = rect.x, y = rect.y }, { x = node.Position.x, y = node.Position.y }, label)
  assert.same({ x = rect.w, y = rect.h }, { x = node.Size.x, y = node.Size.y }, label)
end

local function overlaps(a, b)
  return math.abs(a.Position.x - b.Position.x) * 2 < a.Size.x + b.Size.x
    and math.abs(a.Position.y - b.Position.y) * 2 < a.Size.y + b.Size.y
end

describe("Spoke 主 HUD 左上状态区与金币视图（#297-B2）", function()
  local saved_globals

  before_each(function()
    saved_globals = {
      Vector2 = rawget(_G, "Vector2"),
      Color = rawget(_G, "Color"),
    }
    _G.Vector2 = { New = function(x, y) return { x = x, y = y } end }
    _G.Color = { New = function(...) return { ... } end }
  end)

  after_each(function()
    _G.Vector2 = saved_globals.Vector2
    _G.Color = saved_globals.Color
  end)

  local function mount_vitals(height, opts)
    opts = opts or {}
    local store, writer = ClientStore.new({ initial_now = opts.initial_now or 100 })
    local root_node = Eui.node({ Name = "UIRoot" })
    local nodes = {}
    local created = {}
    local notices = {}

    if not opts.missing_coin then
      local screen_main = Eui.node({ Name = "ScreenMain", Parent = root_node })
      nodes.ImageCoin = Eui.node({ Name = "ImageCoin", Parent = screen_main })
      nodes.LabelCoin = Eui.node({ Name = "LabelCoin", Parent = screen_main })
    end

    local function create_node(kind, props)
      local node = Eui.node({
        Name = props.Name,
        Kind = kind,
        Parent = props.Parent,
        Visible = props.Visible,
        Text = props.Text,
        TouchEnabled = props.TouchEnabled,
      })
      for k, v in pairs(props) do
        if k ~= "Parent" and k ~= "Name" then
          node[k] = v
        end
      end
      nodes[node.Name] = node
      created[#created + 1] = node
      return node
    end

    local view = RootView.mount(root_node, store, {
      create_node = create_node,
      hud = {
        MainHudVitalsView.spec({
          get_resolution = function() return { x = 1920, y = height or 1080 } end,
          notify = function(text) notices[#notices + 1] = text end,
        }),
      },
    })
    assert.is_nil(view.root.fault)
    return {
      store = store,
      writer = writer,
      root_node = root_node,
      view = view,
      nodes = nodes,
      created = created,
      notices = notices,
    }
  end

  for _, height in ipairs({ 886, 1080, 1238, 1440 }) do
    it("多分辨率排版对齐 MainHudLayout 且满值文案不截断不重叠_" .. height, function()
      local env = mount_vitals(height)
      local layout = MainHudLayout.compute({ width = 1920, height = height, itemBarSlots = 8 })
      local r = layout.rects

      assert_at(env.nodes.HealthRing, r.HealthRing, "HealthRing")
      assert_at(env.nodes.HungerRing, r.HungerRing, "HungerRing")
      assert_at(env.nodes.ImageCoin, r.coin_icon, "ImageCoin")
      assert_at(env.nodes.LabelCoin, r.coin_label, "LabelCoin")
      assert.same({ x = 0.5, y = 0.5 }, env.nodes.ImageCoin.Anchor)
      assert.same({ x = 0.5, y = 0.5 }, env.nodes.LabelCoin.Anchor)

      local c = GameCfg.Vitals
      env.writer:update_vitals({ health = c.MaxHealth, max_health = c.MaxHealth, hunger = c.MaxHunger, max_hunger = c.MaxHunger })
      assert.equals("血 " .. c.MaxHealth, env.nodes.HealthText.Text)
      assert.equals("饥饿度 " .. c.MaxHunger, env.nodes.HungerText.Text)
      for _, label in ipairs({ env.nodes.HealthText, env.nodes.HungerText }) do
        assert.is_true(utf8.len(label.Text) * label.FontSize <= label.Size.x)
        assert.is_true(label.FontSize <= label.Size.y)
      end
      assert.is_false(overlaps(env.nodes.HealthText, env.nodes.HungerText))
      assert.is_false(overlaps(env.nodes.HungerText, env.nodes.ImageCoin))

      env.view:dispose()
    end)
  end

  it("响应式同步血量/饥饿/金币，并在饥饿时闪烁红边与节流提醒、恢复后立刻熄灭", function()
    local env = mount_vitals(1080, { initial_now = 100 })
    local cfg = GameCfg.Vitals

    env.writer:update_vitals({ health = 150, max_health = 300, hunger = 50, max_hunger = 100 })
    env.writer:set_coin(42)
    assert.equals("EUIProgressTimer", env.nodes.HealthRing.Kind)
    assert.equals("EUIProgressTimer", env.nodes.HungerRing.Kind)
    assert.equals(50, env.nodes.HealthRing.Percent)
    assert.equals(50, env.nodes.HungerRing.Percent)
    assert.equals("血 150", env.nodes.HealthText.Text)
    assert.equals("饥饿度 50", env.nodes.HungerText.Text)
    assert.equals("42", env.nodes.LabelCoin.Text)
    for _, name in ipairs({ "FlashTop", "FlashBottom", "FlashLeft", "FlashRight" }) do
      assert.is_false(env.nodes[name].Visible, name)
    end
    assert.equals(0, #env.notices)

    -- ItemBarState 下发新金币同步刷新
    env.writer:ingest_event("ItemBarState", { slots = {}, coin = 388 })
    assert.equals("388", env.nodes.LabelCoin.Text)

    -- 进入饥饿（hunger <= 0 and health > 0）：立即闪红边并触发首次提醒
    env.writer:update_vitals({ hunger = 0 })
    assert.equals(1, #env.notices)
    assert.equals(cfg.WarnText, env.notices[1])
    local expected_on_100 = math.floor(100 / cfg.FlashPeriodSec) % 2 == 0
    assert.equals(expected_on_100, env.nodes.FlashTop.Visible)

    -- 半周期后红边翻转，节流窗口内不重复提醒
    env.writer:step_clock(cfg.FlashPeriodSec, 100 + cfg.FlashPeriodSec)
    assert.equals(not expected_on_100, env.nodes.FlashTop.Visible)
    assert.equals(1, #env.notices)

    -- 超过 WarnIntervalSec 后再次提醒
    env.writer:step_clock(cfg.WarnIntervalSec, 100 + cfg.FlashPeriodSec + cfg.WarnIntervalSec)
    assert.equals(2, #env.notices)

    -- 恢复饥饿：StarvingFx Phase 卸载，4 条红边立即熄灭且不再提醒
    env.writer:update_vitals({ hunger = 30 })
    for _, name in ipairs({ "FlashTop", "FlashBottom", "FlashLeft", "FlashRight" }) do
      assert.is_false(env.nodes[name].Visible, name)
    end
    env.writer:step_clock(cfg.WarnIntervalSec + 1, 100 + cfg.FlashPeriodSec + cfg.WarnIntervalSec * 2 + 1)
    assert.equals(2, #env.notices)

    -- 再次饥饿：新进入 Phase 立即提醒
    env.writer:update_vitals({ hunger = 0 })
    assert.equals(3, #env.notices)

    env.view:dispose()
  end)

  it("缺失预置金币节点不报错；重连重置与销毁后动态节点零残留且不销毁预置节点", function()
    local no_coin = mount_vitals(1080, { missing_coin = true })
    no_coin.writer:set_coin(99)
    assert.is_nil(no_coin.view.root.fault)
    no_coin.view:dispose()

    local env = mount_vitals(1080)
    local first_batch = {}
    for i = 1, #env.created do first_batch[i] = env.created[i] end
    assert.equals(10, #first_batch) -- 2*(Bg+Ring+Text) + 4 FlashEdges

    -- 重连重置：旧动态节点全部销毁，预置金币节点保持存活且重新绑定
    env.writer:reset_session("reconnect")
    for _, node in ipairs(first_batch) do
      assert.is_true(node.Destroyed, "重连后旧动态节点必须销毁: " .. tostring(node.Name))
    end
    assert.is_nil(env.nodes.ImageCoin.Destroyed)
    assert.is_nil(env.nodes.LabelCoin.Destroyed)
    assert.equals("0", env.nodes.LabelCoin.Text)

    -- dispose 视图树：全部新动态节点销毁，预置金币节点仍保持存活
    env.view:dispose()
    for _, node in ipairs(env.created) do
      assert.is_true(node.Destroyed, "卸载视图树后动态节点不得残留: " .. tostring(node.Name))
    end
    assert.is_nil(env.nodes.ImageCoin.Destroyed)
    assert.is_nil(env.nodes.LabelCoin.Destroyed)
  end)

  it("分辨率读取兼容非 1080p 与代理 FindFirstChild，非法分辨率返回 nil 且视图不崩溃", function()
    local store, writer = ClientStore.new({ initial_now = 10 })
    local image_coin = Eui.node({ Name = "ImageCoin" })
    local label_coin = Eui.node({ Name = "LabelCoin" })
    local proxy_nodes = { ImageCoin = image_coin, LabelCoin = label_coin }
    local root_node = {
      Name = "ProxyRoot",
      Destroying = Eui.Signal(),
      FindFirstChild = setmetatable({}, {
        __call = function(_, _, name) return proxy_nodes[name] end,
      }),
    }
    local nodes = {}
    local view = RootView.mount(root_node, store, {
      services = {
        get_device_resolution = function() return { x = 1920, y = 886 } end,
      },
      create_node = function(kind, props)
        local node = Eui.node({ Name = props.Name, Kind = kind, Visible = props.Visible, Text = props.Text })
        for k, v in pairs(props) do
          if k ~= "Parent" and k ~= "Name" then node[k] = v end
        end
        nodes[node.Name] = node
        return node
      end,
      hud = { MainHudVitalsView.spec() },
    })
    assert.is_nil(view.root.fault)
    local layout_886 = MainHudLayout.compute({ width = 1920, height = 886, itemBarSlots = 8 })
    assert_at(nodes.HealthRing, layout_886.rects.HealthRing, "HealthRing @886")
    assert_at(image_coin, layout_886.rects.coin_icon, "ImageCoin @886")
    assert_at(label_coin, layout_886.rects.coin_label, "LabelCoin @886")
    writer:set_coin(77)
    assert.equals("77", label_coin.Text)
    view:dispose()

    local nodes_fb = {}
    local view_fb = RootView.mount(Eui.node({ Name = "FallbackRoot" }), store, {
      services = {
        get_device_resolution = function() return { x = 0 / 0, y = 0 } end,
      },
      create_node = function(kind, props)
        local node = Eui.node({ Name = props.Name, Kind = kind, Visible = props.Visible, Text = props.Text })
        for k, v in pairs(props) do
          if k ~= "Parent" and k ~= "Name" then node[k] = v end
        end
        nodes_fb[node.Name] = node
        return node
      end,
      hud = { MainHudVitalsView.spec() },
    })
    assert.is_nil(view_fb.root.fault)
    assert.is_nil(nodes_fb.HealthRing)
    view_fb:dispose()
  end)
end)
