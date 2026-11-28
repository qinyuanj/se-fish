-- 2A 右上角单一紧凑菜单视图（HudMenuView）、1A 任务引导条（GuideView）与顶部胶囊消息（MessageView）契约测试。
-- 失败方式先列：
--   1. BtnMenuEntry 未对齐 MainHudLayout rects.MenuEntry、ButtonText 非空造成双字，或点击不能展开/收起浮层；
--   2. 浮层收起层未用纯 EUILayout（Primitives.dismiss_mask），或点击空白未彻底销毁浮层节点并断开连接；
--   3. 点击图鉴 / 盲盒 / 地图商店 / GM 调试未先收起菜单再调用对应服务，或 Debug=false 时泄漏 GM 项；
--   4. hud_visible=false 或打开任意模态弹窗时未自动收起菜单，或关窗后残留弹开；
--   5. GuideView 未默认折叠或 EUITextLabel 误写 .Color；MessageView 未置于 hint_transient 胶囊或零尺寸停在 (0,0)。

local Eui = require("tests.support.eui_double")
local GameCfg = require("common.game_cfg")
local MainHudLayout = require("client.main_hud_layout")
local Tokens = require("client.ui.tokens")
local Layout = require("client.ui.layout")
local ClientStore = require("client.store.client_store")
local RootView = require("client.views.root_view")
local HudMenuView = require("client.views.hud_menu_view")
local GuideView = require("client.views.guide_view")
local MessageView = require("client.views.message_view")

local function assert_at(node, rect, label)
  assert.is_not_nil(node, label)
  assert.same({ x = rect.x, y = rect.y }, { x = node.Position.x, y = node.Position.y }, label)
  assert.same({ x = rect.w, y = rect.h }, { x = node.Size.x, y = node.Size.y }, label)
end

local function make_factory()
  local nodes, created = {}, {}
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
  return create_node, nodes, created
end

describe("Spoke 2A 主 HUD 菜单视图（HudMenuView）", function()
  local saved_globals

  before_each(function()
    saved_globals = {
      Vector2 = rawget(_G, "Vector2"),
      Vector4 = rawget(_G, "Vector4"),
      Color = rawget(_G, "Color"),
      debug_enabled = GameCfg.Debug.Enabled,
    }
    _G.Vector2 = { New = function(x, y) return { x = x, y = y } end }
    _G.Vector4 = { New = function(l, t, r, b) return { x = l, y = t, z = r, w = b } end }
    _G.Color = { New = function(...) return { ... } end }
  end)

  after_each(function()
    _G.Vector2 = saved_globals.Vector2
    _G.Vector4 = saved_globals.Vector4
    _G.Color = saved_globals.Color
    GameCfg.Debug.Enabled = saved_globals.debug_enabled
  end)

  local function mount_menu(opts)
    opts = opts or {}
    local store, writer = ClientStore.new({ initial_now = 100 })
    local root_node = Eui.node({ Name = "UIRoot" })
    local create_node, nodes, created = make_factory()
    local calls = { modals = {}, compendium = 0, blindbox = 0, platform = 0 }

    local view = RootView.mount(root_node, store, {
      create_node = create_node,
      services = {
        get_device_resolution = function() return { x = 1920, y = opts.height or 1080 } end,
        open_modal = function(id, payload)
          calls.modals[#calls.modals + 1] = { id = id, payload = payload }
          writer:open_modal(id, payload)
        end,
        request_compendium = function()
          calls.compendium = calls.compendium + 1
        end,
        request_blindbox_state = function()
          calls.blindbox = calls.blindbox + 1
        end,
        open_platform_shop = function()
          calls.platform = calls.platform + 1
          writer:open_modal("platform")
        end,
      },
      hud = { HudMenuView.spec(opts.spec_opts) },
    })
    assert.is_nil(view.root.fault)
    return {
      store = store,
      writer = writer,
      root_node = root_node,
      view = view,
      nodes = nodes,
      created = created,
      calls = calls,
    }
  end

  it("右上角单一菜单按钮对齐 MenuEntry，点击展开纯 EUILayout 收起层与 3 个入口，点空白收起零残留", function()
    GameCfg.Debug.Enabled = false
    local env = mount_menu({ height = 1080 })
    local layout = MainHudLayout.compute({ width = 1920, height = 1080, itemBarSlots = GameCfg.Items.ItemBarSlots })

    local entry = env.nodes.BtnMenuEntry
    assert_at(entry, layout.rects.MenuEntry, "BtnMenuEntry")
    assert.equals("", entry.ButtonText)
    assert.equals("菜单", entry:FindFirstChild("LabelButtonText", false).Text)
    assert.is_nil(env.nodes.HudMenuDismiss)
    assert.is_nil(env.nodes.MenuDrawerPanel)

    -- 点击展开浮层
    assert.is_true(Eui.click(entry))
    local dismiss = env.nodes.HudMenuDismiss
    local drawer = env.nodes.MenuDrawerPanel
    local btn_comp = env.nodes.BtnMenuCompendium
    local btn_box = env.nodes.BtnMenuBlindbox
    local btn_shop = env.nodes.BtnMenuPlatformShop
    assert.is_not_nil(dismiss)
    assert.equals("EUILayout", dismiss.Kind)
    assert.equals(Tokens.Z.HUD_POPUP_MASK, dismiss.LocalZOrder)
    assert.equals(Tokens.Z.HUD_POPUP_BG, drawer.LocalZOrder)
    assert.equals(Tokens.Z.HUD_POPUP_CONTENT, btn_comp.LocalZOrder)
    assert.is_nil(env.nodes.BtnMenuGM)

    local drawer_rect, item_rects = MainHudLayout.menu_items(layout, 3)
    assert_at(drawer, drawer_rect, "MenuDrawerPanel")
    assert_at(btn_comp, item_rects[1], "BtnMenuCompendium")
    assert_at(btn_box, item_rects[2], "BtnMenuBlindbox")
    assert_at(btn_shop, item_rects[3], "BtnMenuPlatformShop")
    assert.equals("", btn_comp.ButtonText)
    assert.equals("", btn_box.ButtonText)
    assert.equals("", btn_shop.ButtonText)

    -- 点击空白收起层：全部浮层节点销毁且连接归零
    assert.is_true(Eui.click(dismiss))
    assert.is_true(dismiss.Destroyed)
    assert.is_true(drawer.Destroyed)
    assert.is_true(btn_comp.Destroyed)
    assert.equals(0, dismiss.OnClicked:Count())
    assert.equals(0, btn_comp.OnClicked:Count())

    env.view:dispose()
  end)

  it("点击图鉴/盲盒/地图商店立即收起菜单再打开对应弹窗，Debug=true 时追加 GM 调试项", function()
    GameCfg.Debug.Enabled = true
    local env = mount_menu({ height = 1080 })

    -- 1. 图鉴
    assert.is_true(Eui.click(env.nodes.BtnMenuEntry))
    local drawer1 = env.nodes.MenuDrawerPanel
    assert.is_not_nil(env.nodes.BtnMenuGM)
    assert.is_true(Eui.click(env.nodes.BtnMenuCompendium))
    assert.is_true(drawer1.Destroyed)
    assert.equals("compendium", env.calls.modals[1].id)
    assert.equals(1, env.calls.compendium)
    env.writer:close_modal("compendium")
    -- 关闭弹窗后菜单保持收起态
    assert.is_true(env.nodes.MenuDrawerPanel.Destroyed)

    -- 2. 盲盒
    assert.is_true(Eui.click(env.nodes.BtnMenuEntry))
    local drawer2 = env.nodes.MenuDrawerPanel
    assert.is_true(Eui.click(env.nodes.BtnMenuBlindbox))
    assert.is_true(drawer2.Destroyed)
    assert.equals("blindbox", env.calls.modals[2].id)
    assert.equals(1, env.calls.blindbox)
    env.writer:close_modal("blindbox")

    -- 3. 地图商店
    assert.is_true(Eui.click(env.nodes.BtnMenuEntry))
    local drawer3 = env.nodes.MenuDrawerPanel
    assert.is_true(Eui.click(env.nodes.BtnMenuPlatformShop))
    assert.is_true(drawer3.Destroyed)
    assert.equals(1, env.calls.platform)
    env.writer:close_modal("platform")

    -- 4. GM 调试
    assert.is_true(Eui.click(env.nodes.BtnMenuEntry))
    local drawer4 = env.nodes.MenuDrawerPanel
    assert.is_true(Eui.click(env.nodes.BtnMenuGM))
    assert.is_true(drawer4.Destroyed)
    assert.equals("gm", env.calls.modals[#env.calls.modals].id)

    env.view:dispose()
  end)

  it("hud_visible=false 或外部打开 modal 自动收起浮层，根 UI 销毁零残留", function()
    local env = mount_menu({ height = 1080 })

    -- 展开后外部打开弹窗 -> 立即收起
    assert.is_true(Eui.click(env.nodes.BtnMenuEntry))
    local drawer1 = env.nodes.MenuDrawerPanel
    assert.is_nil(drawer1.Destroyed)
    env.writer:open_modal("shop")
    assert.is_true(drawer1.Destroyed)
    assert.is_false(env.nodes.BtnMenuEntry.TouchEnabled)
    env.writer:close_modal("shop")
    assert.is_true(env.nodes.BtnMenuEntry.TouchEnabled)
    assert.is_true(env.nodes.MenuDrawerPanel.Destroyed)

    -- 展开后关屏 hud_visible=false -> 收起且入口隐藏
    assert.is_true(Eui.click(env.nodes.BtnMenuEntry))
    local drawer2 = env.nodes.MenuDrawerPanel
    env.writer:set_hud_visible(false)
    assert.is_true(drawer2.Destroyed)
    assert.is_false(env.nodes.BtnMenuEntry.Visible)
    assert.is_false(env.nodes.BtnMenuEntry.TouchEnabled)

    -- 重开屏恢复可见且菜单不弹开
    env.writer:set_hud_visible(true)
    assert.is_true(env.nodes.BtnMenuEntry.Visible)
    assert.is_true(env.nodes.BtnMenuEntry.TouchEnabled)
    assert.is_true(env.nodes.MenuDrawerPanel.Destroyed)

    env.root_node:Destroy()
    for _, node in ipairs(env.created) do
      assert.is_true(node.Destroyed, "根 UI 销毁后不得残留: " .. tostring(node.Name))
      assert.equals(0, node.OnClicked:Count())
    end
  end)
end)

describe("Spoke 1A 左侧任务引导条（GuideView）与顶部消息胶囊（MessageView）", function()
  local saved_globals

  before_each(function()
    saved_globals = {
      Vector2 = rawget(_G, "Vector2"),
      Vector4 = rawget(_G, "Vector4"),
      Color = rawget(_G, "Color"),
    }
    _G.Vector2 = { New = function(x, y) return { x = x, y = y } end }
    _G.Vector4 = { New = function(l, t, r, b) return { x = l, y = t, z = r, w = b } end }
    _G.Color = { New = function(...) return { ... } end }
  end)

  after_each(function()
    _G.Vector2 = saved_globals.Vector2
    _G.Vector4 = saved_globals.Vector4
    _G.Color = saved_globals.Color
  end)

  it("GuideView 默认折叠为单行目标胶囊，点击展开详情卡片，文本用 TextColor 绝不写 Color", function()
    local store, writer = ClientStore.new({ initial_now = 100 })
    local root_node = Eui.node({ Name = "UIRoot" })
    local create_node, nodes = make_factory()
    local view = RootView.mount(root_node, store, {
      create_node = create_node,
      services = { get_device_resolution = function() return { x = 1920, y = 1080 } end },
      hud = { GuideView.spec() },
    })
    assert.is_nil(view.root.fault)

    writer:ingest_event("QuestState", { text = "新手任务：拾取 5 只蚯蚓并前往鱼塘抛竿" })
    local toggle = nodes.QuestToggle
    local toggle_lbl = nodes.QuestToggleLabel
    local bg = nodes.QuestBackground
    local detail = nodes.QuestLabel

    assert.is_true(toggle.Visible)
    assert.equals("", toggle.ButtonText)
    assert.matches("▶ ", toggle_lbl.Text)
    assert.is_false(bg.Visible)
    assert.is_false(detail.Visible)
    assert.is_nil(detail.Color)
    assert.is_not_nil(detail.TextColor)
    assert.is_nil(toggle_lbl.Color)
    assert.is_not_nil(toggle_lbl.TextColor)
    assert.is_false(detail.TouchEnabled)

    -- 点击切换展开详情
    assert.is_true(Eui.click(toggle))
    assert.is_true(bg.Visible)
    assert.is_true(detail.Visible)
    assert.matches("▼ ", toggle_lbl.Text)
    assert.matches("拾取", detail.Text)

    -- 再点击折叠并跨快照保留折叠态
    assert.is_true(Eui.click(toggle))
    assert.is_false(bg.Visible)
    assert.is_false(detail.Visible)
    writer:ingest_event("QuestState", { text = "新任务：卖鱼赚金币" })
    assert.is_false(detail.Visible)
    assert.matches("卖鱼", toggle_lbl.Text)

    -- 关屏隐藏全部节点
    writer:set_hud_visible(false)
    assert.is_false(toggle.Visible)
    assert.is_false(bg.Visible)
    assert.is_false(detail.Visible)

    view:dispose()
  end)

  it("MessageView 在顶部安全区 hint_transient 显示半透明深海蓝胶囊 Toast，非零尺寸且穿透触控", function()
    local store, writer = ClientStore.new({ initial_now = 100 })
    local root_node = Eui.node({ Name = "UIRoot" })
    local create_node, nodes = make_factory()
    local view = RootView.mount(root_node, store, {
      create_node = create_node,
      services = { get_device_resolution = function() return { x = 1920, y = 1080 } end },
      hud = { MessageView.spec() },
    })
    assert.is_nil(view.root.fault)

    local layout = MainHudLayout.compute({ width = 1920, height = 1080, itemBarSlots = 0, reeling = false })
    local toast = nodes.MessageToast
    local label = nodes.LabelMessage

    assert_at(toast, layout.rects.hint_primary, "MessageToast")
    assert.equals(Tokens.Z.TOAST, toast.LocalZOrder)
    assert.is_false(toast.Visible)
    assert.is_false(label.Visible)
    assert.is_false(toast.TouchEnabled)
    assert.is_false(toast.SwallowTouchEnabled)
    assert.is_false(label.TouchEnabled)
    assert.is_false(label.SwallowTouchEnabled)
    assert.is_true(label.Size.x > 0 and label.Size.y > 0)
    assert.is_true(Layout.inside(
      Layout.rect(toast.Position.x, toast.Position.y, toast.Size.x, toast.Size.y),
      Layout.rect(960, 540, 1920, 1080)
    ))

    writer:show_notice("成功钓到一条大鱼！")
    assert.is_true(toast.Visible)
    assert.is_true(label.Visible)
    assert.equals("成功钓到一条大鱼！", label.Text)

    view:dispose()
  end)
end)
