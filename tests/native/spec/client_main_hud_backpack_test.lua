-- #297-B3c 客户端主 HUD 背包入口与背包面板 Spoke 视图黑盒契约测试。
-- 失败方式先列：
--   1. BtnBackpack 未按 MainHudLayout 排版、未显示「背包 N 格」或升级扩容后未重排与增挂格位，或 EUIButton 误写 Color 属性；
--   2. 展开/关闭背包面板未由 Phase+Dock 干净销毁节点，或选格高亮/空格禁点/烤熟前缀显示错误；
--   3. 点击 BtnMoveToItemBar 未经 ItemBarAction 发送 MoveToItemBar，或道具栏已满时仍可误触；
--   4. 展开背包未与 MainHudEquipPopups 及外部遮挡状态联动（关闭装备浮层并隐藏武器/鱼饵栏）；
--   5. 重连重置或根 UI 销毁后遗留面板/格位节点，或 OnClicked 连接未归零。

local spoke = require("common.packages.spoke.api")
local Eui = require("tests.support.eui_double")
local GameCfg = require("common.game_cfg")
local MainHudLayout = require("client.main_hud_layout")
local ClientStore = require("client.store.client_store")
local RootView = require("client.views.root_view")
local MainHudBackpackView = require("client.views.main_hud_backpack_view")
local MainHudEquipPopups = require("client.views.main_hud_equip_popups")
local MainHudItemBarView = require("client.views.main_hud_item_bar_view")
local MainHudVitalsView = require("client.views.main_hud_vitals_view")
local MainHudActionButtonsView = require("client.views.main_hud_action_buttons_view")

local State = spoke.State

local ITEM_ROD = GameCfg.Items.Id.StarterRod
local ITEM_FISH = GameCfg.Items.Id.Tilapia
local WEAPON_KNIFE = "item135"

local function assert_at(node, rect, label)
  assert.is_not_nil(node, label)
  assert.same({ x = rect.x, y = rect.y }, { x = node.Position.x, y = node.Position.y }, label)
  assert.same({ x = rect.w, y = rect.h }, { x = node.Size.x, y = node.Size.y }, label)
end

describe("Spoke 主 HUD 背包入口与背包面板视图（#297-B3c）", function()
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

  local function mount_hud(opts)
    opts = opts or {}
    local store, writer = ClientStore.new({ initial_now = 100 })
    local root_node = Eui.node({ Name = "UIRoot" })
    local nodes = {}
    local created = {}

    local function create_node(kind, props)
      local node = Eui.node({
        Name = props.Name,
        Kind = kind,
        Parent = props.Parent,
        Visible = props.Visible,
        Text = props.Text,
        TouchEnabled = props.TouchEnabled,
      })
      if kind == "EUIButton" then
        node.OnTouchBegan = Eui.Signal()
        node.OnTouchEnded = Eui.Signal()
      end
      for k, v in pairs(props) do
        if k ~= "Parent" and k ~= "Name" then
          node[k] = v
        end
      end
      nodes[node.Name] = node
      created[#created + 1] = node
      return node
    end

    local resolution_fn = opts.get_resolution or function()
      return { x = 1920, y = opts.height or 1080 }
    end

    local hud_specs = {}
    if opts.with_equip_popups then
      hud_specs[#hud_specs + 1] = MainHudEquipPopups.spec({
        get_resolution = resolution_fn,
        open_popup = opts.open_popup,
        backpack_open = opts.backpack_open,
      })
    end
    hud_specs[#hud_specs + 1] = MainHudBackpackView.spec({
      get_resolution = resolution_fn,
      send_action = opts.send_action,
      backpack_open = opts.backpack_open,
      open_popup = opts.open_popup,
      on_open_changed = opts.on_open_changed,
    })

    local view = RootView.mount(root_node, store, {
      create_node = create_node,
      hud = hud_specs,
    })
    assert.is_nil(view.root.fault)
    return {
      store = store,
      writer = writer,
      root_node = root_node,
      view = view,
      nodes = nodes,
      created = created,
    }
  end

  it("常驻入口显示「背包 N 格」，随道具栏与背包升级扩容实时重排并增量增删格位", function()
    local env = mount_hud({ height = 1080 })

    -- 初始无快照：显示「背包」，按钮不写 Color，标签在更高层级
    assert.equals("背包", env.nodes.LabelBackpack.Text)
    assert.is_nil(env.nodes.BtnBackpack.Color)
    assert.is_true(env.nodes.LabelBackpack.LocalZOrder > env.nodes.BtnBackpack.LocalZOrder)
    assert.is_nil(env.nodes.BackpackPanel)

    -- 初始 2 格道具栏 + 5 格背包
    env.writer:ingest_event("ItemBarState", {
      slotCount = 2,
      slots = {},
      backpackCount = 5,
      backpack = {},
    })
    local layout2 = MainHudLayout.compute({ width = 1920, height = 1080, itemBarSlots = 2 })
    assert_at(env.nodes.BtnBackpack, layout2.Rects.BackpackButton, "BtnBackpack(2)")
    assert_at(env.nodes.LabelBackpack, layout2.Rects.BackpackButton, "LabelBackpack(2)")
    assert.equals("背包 5 格", env.nodes.LabelBackpack.Text)

    -- 展开背包：挂载 BackpackSlot1..5
    assert.is_true(Eui.click(env.nodes.BtnBackpack))
    local slot1 = env.nodes.BackpackSlot1
    local slot5 = env.nodes.BackpackSlot5
    assert.is_not_nil(slot1)
    assert.is_not_nil(slot5)
    assert.is_nil(env.nodes.BackpackSlot6)
    assert.is_nil(slot1.Color)
    assert.is_true(env.nodes.BackpackLabel1.LocalZOrder > slot1.LocalZOrder)

    -- 升级扩容到 5 格道具栏 + 10 格背包：按钮重排、文案更新、原有 1..5 格复用、新增 6..10 格
    env.writer:ingest_event("ItemBarState", {
      slotCount = 5,
      slots = {},
      backpackCount = 10,
      backpack = {},
    })
    local layout5 = MainHudLayout.compute({ width = 1920, height = 1080, itemBarSlots = 5 })
    assert_at(env.nodes.BtnBackpack, layout5.Rects.BackpackButton, "BtnBackpack(5)")
    assert.equals("背包 10 格", env.nodes.LabelBackpack.Text)
    assert.equals(slot1, env.nodes.BackpackSlot1)
    assert.is_not_nil(env.nodes.BackpackSlot10)
    assert.is_nil(env.nodes.BackpackSlot11)

    -- 若快照格数减少（如切换存档）：超出格位立即销毁并断开连接
    local slot10 = env.nodes.BackpackSlot10
    env.writer:ingest_event("ItemBarState", {
      slotCount = 5,
      slots = {},
      backpackCount = 5,
      backpack = {},
    })
    assert.equals("背包 5 格", env.nodes.LabelBackpack.Text)
    assert.is_true(slot10.Destroyed)
    assert.equals(0, slot10.OnClicked:Count())

    env.view:dispose()
  end)

  it("展开/关闭面板、格位文案（含烤熟前缀）与选格高亮按 Phase+Dock 干净运行", function()
    local env = mount_hud({ height = 1080 })
    local fish_name = GameCfg.Items.Definitions[ITEM_FISH].Name
    local rod_name = GameCfg.Items.Definitions[ITEM_ROD].Name

    env.writer:ingest_event("ItemBarState", {
      slotCount = 4,
      slots = {},
      backpackCount = 5,
      backpack = {
        [1] = { itemId = ITEM_FISH, count = 1, cooked = GameCfg.Items.CookedPriceScale },
        [2] = { itemId = ITEM_ROD, count = 1 },
      },
    })

    -- 点击入口展开面板
    assert.is_true(Eui.click(env.nodes.BtnBackpack))
    local panel = env.nodes.BackpackPanel
    local btn_close = env.nodes.BtnBackpackClose
    local slot1 = env.nodes.BackpackSlot1
    local slot2 = env.nodes.BackpackSlot2
    local slot3 = env.nodes.BackpackSlot3
    assert.is_not_nil(panel)
    assert.is_not_nil(btn_close)
    assert.equals(GameCfg.Grill.CookedPrefix .. fish_name, env.nodes.BackpackLabel1.Text)
    assert.equals(rod_name, env.nodes.BackpackLabel2.Text)
    assert.equals("空", env.nodes.BackpackLabel3.Text)
    assert.is_true(slot1.TouchEnabled)
    assert.is_true(slot2.TouchEnabled)
    assert.is_false(slot3.TouchEnabled)
    assert.is_false(env.nodes.BtnMoveToItemBar.Visible)

    -- 点击空格不产生选格
    assert.is_false(Eui.click(slot3))
    assert.is_false(env.nodes.BtnMoveToItemBar.Visible)

    -- 点击第 1 格：高亮切换并显示「转入道具栏」按钮
    local normal_color = slot2.ButtonNormalColor
    assert.is_true(Eui.click(slot1))
    assert.same({ 36, 130, 94, 255 }, slot1.ButtonNormalColor)
    assert.same(normal_color, slot2.ButtonNormalColor)
    assert.is_true(env.nodes.BtnMoveToItemBar.Visible)
    assert.is_true(env.nodes.BtnMoveToItemBar.TouchEnabled)
    assert.equals("转入道具栏", env.nodes.LabelMoveToItemBar.Text)

    -- 点击面板关闭按钮：Phase 卸载，面板/关闭键/全部格位均销毁且连接归零
    assert.is_true(Eui.click(btn_close))
    assert.is_true(panel.Destroyed)
    assert.is_true(btn_close.Destroyed)
    assert.is_true(slot1.Destroyed)
    assert.is_true(slot2.Destroyed)
    assert.equals(0, btn_close.OnClicked:Count())
    assert.equals(0, slot1.OnClicked:Count())

    -- 再次展开时选格状态已复位，点 BtnBackpack 自身也可收起
    assert.is_true(Eui.click(env.nodes.BtnBackpack))
    local panel2 = env.nodes.BackpackPanel
    assert.is_nil(panel2.Destroyed)
    assert.is_false(env.nodes.BtnMoveToItemBar.Visible)
    assert.is_true(Eui.click(env.nodes.BtnBackpack))
    assert.is_true(panel2.Destroyed)

    env.view:dispose()
  end)

  it("BtnMoveToItemBar 经默认 ItemBarAction 上行 MoveToItemBar，道具栏已满时禁点保护", function()
    local sent = {}
    local prev_re_util = rawget(_G, "REUtil")
    _G.REUtil = {
      get_re = function(_, name)
        return {
          FireServer = function(_, payload)
            sent[#sent + 1] = { name = name, payload = payload }
          end,
        }
      end,
    }

    local ok, err = pcall(function()
      local env = mount_hud({ height = 1080 })

      env.writer:ingest_event("ItemBarState", {
        slotCount = 2,
        slots = {
          [1] = { itemId = ITEM_ROD, count = 1 },
        },
        backpackCount = 5,
        backpack = {
          [2] = { itemId = ITEM_FISH, count = 1 },
        },
      })

      assert.is_true(Eui.click(env.nodes.BtnBackpack))
      assert.is_true(Eui.click(env.nodes.BackpackSlot2))
      assert.is_true(Eui.click(env.nodes.BtnMoveToItemBar))
      assert.equals(1, #sent)
      assert.equals("ItemBarAction", sent[1].name)
      assert.same({ action = "MoveToItemBar", value = 2 }, sent[1].payload)

      -- 道具栏已满：提示「道具栏已满」且禁用点击，不再发送 RE
      env.writer:ingest_event("ItemBarState", {
        slotCount = 2,
        slots = {
          [1] = { itemId = ITEM_ROD, count = 1 },
          [2] = { itemId = ITEM_FISH, count = 1 },
        },
        backpackCount = 5,
        backpack = {
          [2] = { itemId = ITEM_FISH, count = 1 },
        },
      })
      assert.is_true(env.nodes.BtnMoveToItemBar.Visible)
      assert.is_false(env.nodes.BtnMoveToItemBar.TouchEnabled)
      assert.equals("道具栏已满", env.nodes.LabelMoveToItemBar.Text)
      assert.is_false(Eui.click(env.nodes.BtnMoveToItemBar))
      assert.equals(1, #sent)

      -- 当选中格物品被移出后，自动清空选中并隐藏转入按钮
      env.writer:ingest_event("ItemBarState", {
        slotCount = 2,
        slots = {
          [1] = { itemId = ITEM_ROD, count = 1 },
        },
        backpackCount = 5,
        backpack = {},
      })
      assert.is_false(env.nodes.BtnMoveToItemBar.Visible)

      env.view:dispose()
    end)

    _G.REUtil = prev_re_util
    if not ok then
      error(err, 0)
    end
  end)

  it("展开背包与 MainHudEquipPopups 协同控制遮挡：关闭武器/鱼饵浮层并隐藏底部栏位", function()
    local backpack_open = State.new("Test.backpack_open", false)
    local open_popup = State.new("Test.open_popup", nil)
    local occlusion_log = {}

    local env = mount_hud({
      height = 1080,
      with_equip_popups = true,
      backpack_open = backpack_open,
      open_popup = open_popup,
      on_open_changed = function(is_open)
        occlusion_log[#occlusion_log + 1] = is_open
      end,
    })

    env.writer:ingest_event("ItemBarState", {
      slotCount = 4,
      slots = {},
      backpackCount = 5,
      backpack = {},
      weapons = { [WEAPON_KNIFE] = 1 },
      selectedWeapon = WEAPON_KNIFE,
      bait = { [GameCfg.Items.Id.Worm] = 3 },
      selectedBait = GameCfg.Items.Id.Worm,
    })

    -- 先打开武器浮层
    assert.is_true(Eui.click(env.nodes.WeaponBar))
    local dismiss = env.nodes.PopupDismiss
    assert.is_not_nil(dismiss)
    assert.equals("Weapon", open_popup:now())
    assert.is_true(env.nodes.WeaponBar.Visible)
    assert.is_true(env.nodes.BaitBar.Visible)

    -- 点击背包入口：装备浮层立即销毁，武器栏/鱼饵栏隐藏且不可点，外部遮挡回调收到 true
    assert.is_true(Eui.click(env.nodes.BtnBackpack))
    assert.is_true(backpack_open:now())
    assert.is_nil(open_popup:now())
    assert.is_true(dismiss.Destroyed)
    assert.is_false(env.nodes.WeaponBar.Visible)
    assert.is_false(env.nodes.WeaponBar.TouchEnabled)
    assert.is_false(env.nodes.BaitBar.Visible)
    assert.is_false(env.nodes.BaitBar.TouchEnabled)
    assert.is_true(occlusion_log[#occlusion_log])

    -- 关闭背包：武器栏与鱼饵栏恢复可见可点，外部遮挡回调收到 false
    assert.is_true(Eui.click(env.nodes.BtnBackpackClose))
    assert.is_false(backpack_open:now())
    assert.is_true(env.nodes.WeaponBar.Visible)
    assert.is_true(env.nodes.WeaponBar.TouchEnabled)
    assert.is_true(env.nodes.BaitBar.Visible)
    assert.is_true(env.nodes.BaitBar.TouchEnabled)
    assert.is_false(occlusion_log[#occlusion_log])

    env.view:dispose()
  end)

  it("重连重置与根 UI 销毁后全部节点及信号连接归零", function()
    local backpack_open = State.new("Test.reconnect_backpack_open", false)
    local env = mount_hud({
      height = 1080,
      backpack_open = backpack_open,
    })

    env.writer:ingest_event("ItemBarState", {
      slotCount = 4,
      slots = {},
      backpackCount = 5,
      backpack = {
        [1] = { itemId = ITEM_FISH, count = 1 },
      },
    })

    assert.is_true(Eui.click(env.nodes.BtnBackpack))
    assert.is_true(Eui.click(env.nodes.BackpackSlot1))
    assert.is_true(backpack_open:now())

    local first_batch = {}
    for i = 1, #env.created do
      first_batch[i] = env.created[i]
    end
    assert.is_true(#first_batch >= 10)

    -- 1. 重连重置：上一轮全部节点销毁且连接归零，共享 backpack_open 复位为 false，新一轮以收起态重建
    env.writer:reset_session("reconnect")
    for _, node in ipairs(first_batch) do
      assert.is_true(node.Destroyed, "重连后旧节点必须销毁: " .. tostring(node.Name))
      assert.equals(0, node.OnClicked:Count(), "重连后旧按钮连接必须归零: " .. tostring(node.Name))
    end
    assert.is_false(backpack_open:now())
    assert.is_nil(env.nodes.BtnBackpack.Destroyed)
    assert.equals(1, env.nodes.BtnBackpack.OnClicked:Count())

    -- 重连后重新下发数据并展开背包
    env.writer:ingest_event("ItemBarState", {
      slotCount = 4,
      slots = {},
      backpackCount = 5,
      backpack = {
        [1] = { itemId = ITEM_ROD, count = 1 },
      },
    })
    assert.is_true(Eui.click(env.nodes.BtnBackpack))
    assert.is_nil(env.nodes.BackpackPanel.Destroyed)

    -- 2. 宿主根 UI 销毁：全部节点销毁，全部 OnClicked 连接归零，外部状态复位
    env.root_node:Destroy()
    assert.is_false(backpack_open:now())
    for _, node in ipairs(env.created) do
      assert.is_true(node.Destroyed, "根 UI 销毁后节点不得残留: " .. tostring(node.Name))
      assert.equals(0, node.OnClicked:Count(), "根 UI 销毁后信号连接必须归零: " .. tostring(node.Name))
      if node.OnTouchBegan then
        assert.equals(0, node.OnTouchBegan:Count(), "根 UI 销毁后 OnTouchBegan 连接必须归零: " .. tostring(node.Name))
      end
      if node.OnTouchEnded then
        assert.equals(0, node.OnTouchEnded:Count(), "根 UI 销毁后 OnTouchEnded 连接必须归零: " .. tostring(node.Name))
      end
    end
  end)

  it("支持背包内换格与道具栏↔背包双向跨容器拖拽发送 MoveSlot", function()
    local store, writer = ClientStore.new({ initial_now = 100 })
    local root_node = Eui.node({ Name = "UIRoot" })
    local nodes = {}
    local actions = {}
    local backpack_open = State.new("Test.drag_backpack_open", false)
    local resolvers = {}

    local function create_node(kind, props)
      local node = Eui.node({
        Name = props.Name,
        Kind = kind,
        Parent = props.Parent,
        Visible = props.Visible,
        Text = props.Text,
        TouchEnabled = props.TouchEnabled,
      })
      if kind == "EUIButton" then
        node.OnTouchBegan = Eui.Signal()
        node.OnTouchEnded = Eui.Signal()
      end
      for k, v in pairs(props) do
        if k ~= "Parent" and k ~= "Name" then
          node[k] = v
        end
      end
      nodes[node.Name] = node
      return node
    end

    local function send_action(action, value)
      actions[#actions + 1] = { action = action, value = value }
    end

    local view = RootView.mount(root_node, store, {
      create_node = create_node,
      hud = {
        MainHudItemBarView.spec({
          get_resolution = function() return { x = 1920, y = 1080 } end,
          backpack_open = backpack_open,
          send_action = send_action,
          resolve_drop_target = function(pos)
            return resolvers.backpack and resolvers.backpack(pos) or nil
          end,
          on_drop_resolver = function(fn)
            resolvers.item_bar = fn
          end,
        }),
        MainHudBackpackView.spec({
          get_resolution = function() return { x = 1920, y = 1080 } end,
          backpack_open = backpack_open,
          send_action = send_action,
          resolve_drop_target = function(pos)
            return resolvers.item_bar and resolvers.item_bar(pos) or nil
          end,
          on_drop_resolver = function(fn)
            resolvers.backpack = fn
          end,
        }),
      },
    })
    assert.is_nil(view.root.fault)

    writer:ingest_event("ItemBarState", {
      slotCount = 4,
      slots = {
        [1] = { itemId = ITEM_ROD, count = 1 },
      },
      backpackCount = 5,
      backpack = {
        [1] = { itemId = ITEM_FISH, count = 1 },
      },
    })

    -- 展开背包：底部道具栏保持可见
    assert.is_true(Eui.click(nodes.BtnBackpack))
    assert.is_true(nodes.ItemBarSlot1.Visible)
    assert.is_true(nodes.BackpackSlot1.Visible)

    local bp1 = nodes.BackpackSlot1.Position
    local bp3 = nodes.BackpackSlot3.Position
    local ib1 = nodes.ItemBarSlot1.Position
    local ib2 = nodes.ItemBarSlot2.Position

    -- 1. 背包内互换格位：背包 1 -> 背包 3
    nodes.BackpackSlot1.OnTouchBegan:Fire({ BeganPosition = { x = bp1.x, y = bp1.y } })
    nodes.BackpackSlot1.OnTouchEnded:Fire({ EndedPosition = { x = bp3.x, y = bp3.y } })
    assert.same({
      action = "MoveSlot",
      value = {
        from = GameCfg.Items.ContainerId.Backpack,
        index = 1,
        target = GameCfg.Items.ContainerId.Backpack,
        slot = 3,
      },
    }, actions[1])

    -- 2. 背包 -> 道具栏：背包 1 -> 道具栏 2
    nodes.BackpackSlot1.OnTouchBegan:Fire({ BeganPosition = { x = bp1.x, y = bp1.y } })
    nodes.BackpackSlot1.OnTouchEnded:Fire({ EndedPosition = { x = ib2.x, y = ib2.y } })
    assert.same({
      action = "MoveSlot",
      value = {
        from = GameCfg.Items.ContainerId.Backpack,
        index = 1,
        target = GameCfg.Items.ContainerId.ItemBar,
        slot = 2,
      },
    }, actions[2])

    -- 3. 道具栏 -> 背包：道具栏 1 -> 背包 3
    nodes.ItemBarSlot1.OnTouchBegan:Fire({ BeganPosition = { x = ib1.x, y = ib1.y } })
    nodes.ItemBarSlot1.OnTouchEnded:Fire({ EndedPosition = { x = bp3.x, y = bp3.y } })
    assert.same({
      action = "MoveSlot",
      value = {
        from = GameCfg.Items.ContainerId.ItemBar,
        index = 1,
        target = GameCfg.Items.ContainerId.Backpack,
        slot = 3,
      },
    }, actions[3])

    view:dispose()
    assert.is_nil(resolvers.item_bar)
    assert.is_nil(resolvers.backpack)
  end)

  it("关屏 hud_visible=false 时全主 HUD 常驻与展开节点零残留隐藏，重新开屏恢复", function()
    local store, writer = ClientStore.new({ initial_now = 100 })
    local root_node = Eui.node({ Name = "UIRoot" })
    local screen_main = Eui.node({ Name = "ScreenMain", Parent = root_node })
    local nodes = {
      ImageCoin = Eui.node({ Name = "ImageCoin", Parent = screen_main }),
      LabelCoin = Eui.node({ Name = "LabelCoin", Parent = screen_main }),
    }
    local backpack_open = State.new("Test.hide_backpack_open", false)
    local open_popup = State.new("Test.hide_open_popup", nil)

    local function create_node(kind, props)
      local node = Eui.node({
        Name = props.Name,
        Kind = kind,
        Parent = props.Parent,
        Visible = props.Visible,
        Text = props.Text,
        TouchEnabled = props.TouchEnabled,
      })
      if kind == "EUIButton" then
        node.OnTouchBegan = Eui.Signal()
        node.OnTouchEnded = Eui.Signal()
      end
      for k, v in pairs(props) do
        if k ~= "Parent" and k ~= "Name" then
          node[k] = v
        end
      end
      nodes[node.Name] = node
      return node
    end

    local view = RootView.mount(root_node, store, {
      create_node = create_node,
      hud = {
        MainHudVitalsView.spec({
          get_resolution = function() return { x = 1920, y = 1080 } end,
          notify = function() end,
        }),
        MainHudEquipPopups.spec({
          get_resolution = function() return { x = 1920, y = 1080 } end,
          open_popup = open_popup,
          backpack_open = backpack_open,
        }),
        MainHudItemBarView.spec({
          get_resolution = function() return { x = 1920, y = 1080 } end,
          backpack_open = backpack_open,
        }),
        MainHudActionButtonsView.spec({
          get_resolution = function() return { x = 1920, y = 1080 } end,
          backpack_open = backpack_open,
        }),
        MainHudBackpackView.spec({
          get_resolution = function() return { x = 1920, y = 1080 } end,
          backpack_open = backpack_open,
          open_popup = open_popup,
        }),
      },
    })
    assert.is_nil(view.root.fault)

    writer:update_vitals({ health = 100, maxHealth = 100, hunger = 0, maxHunger = 100 })
    writer:ingest_event("ItemBarState", {
      slotCount = 3,
      selectedSlot = 1,
      slots = { [1] = { itemId = ITEM_ROD, count = 1 } },
      backpackCount = 5,
      backpack = { [1] = { itemId = ITEM_FISH, count = 1 } },
      weapons = { [WEAPON_KNIFE] = 1 },
      selectedWeapon = WEAPON_KNIFE,
    })

    -- 打开背包面板后执行关屏
    assert.is_true(Eui.click(nodes.BtnBackpack))
    local panel = nodes.BackpackPanel
    assert.is_not_nil(panel)

    writer:set_hud_visible(false)

    -- 全部常驻主 HUD 节点必须隐藏，且展开的背包面板必须销毁
    assert.is_true(panel.Destroyed)
    for _, name in ipairs({
      "ImageCoin", "LabelCoin",
      "HealthRingBg", "HealthRing", "HealthText",
      "HungerRingBg", "HungerRing", "HungerText",
      "FlashTop", "FlashBottom", "FlashLeft", "FlashRight",
      "WeaponBar", "WeaponBarLabel", "BaitBar", "BaitBarLabel",
      "ItemBarSlot1", "ItemBarIcon1", "ItemBarLabel1", "ItemBarAmount1",
      "ItemDiscard", "BtnDiscardLabel", "ItemAction2", "BtnItemActionLabel",
      "BtnBackpack", "LabelBackpack",
    }) do
      assert.is_false(nodes[name].Visible, "关屏后节点不得残留可见: " .. name)
    end
    assert.is_false(nodes.BtnBackpack.TouchEnabled)
    assert.is_false(nodes.ItemBarSlot1.TouchEnabled)

    -- 收起背包并重新开屏：常驻 HUD 节点全部恢复可见
    backpack_open:set(false)
    writer:set_hud_visible(true)
    for _, name in ipairs({
      "ImageCoin", "LabelCoin",
      "HealthRingBg", "HealthRing", "HealthText",
      "HungerRingBg", "HungerRing", "HungerText",
      "WeaponBar", "BaitBar",
      "ItemBarSlot1", "ItemBarIcon1",
      "ItemDiscard", "ItemAction2",
      "BtnBackpack", "LabelBackpack",
    }) do
      assert.is_true(nodes[name].Visible, "重新开屏后节点应恢复可见: " .. name)
    end

    view:dispose()
  end)
end)
