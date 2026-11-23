-- #297-B3b2 客户端主 HUD 底部道具栏动态格位、拖拽换格与爆炸物长按手势 Spoke 视图黑盒契约测试。
-- 失败方式先列：
--   1. 动态槽数（2..8）未按 MainHudLayout 排版、扩容未保留旧格并增挂新格、缩容未销毁多余格或 EUIButton 误写 Color；
--   2. 点击选槽未发送 SelectSlot、选中态高亮错误、烤熟前缀/图标/数量渲染错误；
--   3. 拖拽跨格未按几何命中发送 MoveSlot，或短距离微动/拖回自身误发 MoveSlot；
--   4. 爆炸物槽点按未直投、长按未弹出 ThrowAimOverlay 或选点未携带目标落点投掷、投掷后误发 SelectSlot；
--   5. backpack_open 展开未隐藏底部道具栏与取消瞄准遮罩；
--   6. 重连重置或根 UI 销毁后遗留槽位/瞄准节点，或 OnClicked/OnTouchBegan/OnTouchEnded 连接未归零。

local spoke = require("common.packages.spoke.api")
local Eui = require("tests.support.eui_double")
local GameCfg = require("common.GameCfg")
local MainHudLayout = require("client.MainHudLayout")
local ClientStore = require("client.Store.ClientStore")
local RootView = require("client.Views.RootView")
local MainHudItemBarView = require("client.Views.MainHudItemBarView")

local State = spoke.State

local ITEM_ROD = GameCfg.Items.Id.StarterRod
local ITEM_FISH = GameCfg.Items.Id.Tilapia
local ITEM_GRENADE = "item144" -- 爆炸物：手雷

local function assert_at(node, rect, label)
  assert.is_not_nil(node, label)
  assert.same({ x = rect.x, y = rect.y }, { x = node.Position.x, y = node.Position.y }, label)
  assert.same({ x = rect.w, y = rect.h }, { x = node.Size.x, y = node.Size.y }, label)
end

describe("Spoke 主 HUD 底部道具栏视图（#297-B3b2）", function()
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
    local root_node = Eui.Node({ Name = "UIRoot" })
    local nodes = {}
    local created = {}

    local function create_node(kind, props)
      local node = Eui.Node({
        Name = props.Name,
        Kind = kind,
        Parent = props.Parent,
        Visible = props.Visible,
        Text = props.Text,
        TouchEnabled = props.TouchEnabled,
      })
      node.OnTouchBegan = Eui.Signal()
      node.OnTouchEnded = Eui.Signal()
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

    local view = RootView.mount(root_node, store, {
      create_node = create_node,
      hud = {
        MainHudItemBarView.spec({
          get_resolution = resolution_fn,
          send_action = opts.send_action,
          on_throw = opts.on_throw,
          on_aim_begin = opts.on_aim_begin,
          resolve_aim_target = opts.resolve_aim_target,
          notify = opts.notify,
          backpack_open = opts.backpack_open,
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
    }
  end

  it("动态槽数 2..8 随 slotCount 扩容重排与缩容卸载，且严格遵守按钮无 Color 及高 ZOrder 文字", function()
    local env = mount_hud({ height = 1080 })

    -- 初始默认 2 格
    local slot1 = env.nodes.ItemBarSlot1
    local slot2 = env.nodes.ItemBarSlot2
    assert.is_not_nil(slot1)
    assert.is_not_nil(slot2)
    assert.is_nil(env.nodes.ItemBarSlot3)
    assert.is_nil(slot1.Color)
    assert.is_true(env.nodes.ItemBarIcon1.LocalZOrder > slot1.LocalZOrder)
    assert.is_true(env.nodes.ItemBarLabel1.LocalZOrder > env.nodes.ItemBarIcon1.LocalZOrder)
    assert.is_true(env.nodes.ItemBarAmount1.LocalZOrder > env.nodes.ItemBarIcon1.LocalZOrder)

    local layout2 = MainHudLayout.Compute({ width = 1920, height = 1080, itemBarSlots = 2 })
    assert_at(slot1, layout2.ItemBarSlots[1], "ItemBarSlot1(2)")
    assert_at(slot2, layout2.ItemBarSlots[2], "ItemBarSlot2(2)")

    -- 扩容到 5 格：复用前 2 格节点并重排，新增 3..5 格
    env.writer:ingest_event("ItemBarState", {
      slotCount = 5,
      slots = {},
    })
    local layout5 = MainHudLayout.Compute({ width = 1920, height = 1080, itemBarSlots = 5 })
    assert.equals(slot1, env.nodes.ItemBarSlot1)
    assert.equals(slot2, env.nodes.ItemBarSlot2)
    assert_at(slot1, layout5.ItemBarSlots[1], "ItemBarSlot1(5)")
    assert_at(env.nodes.ItemBarSlot5, layout5.ItemBarSlots[5], "ItemBarSlot5(5)")
    assert.is_nil(env.nodes.ItemBarSlot6)

    -- 扩容到上限 8 格（超上限值钳制到 8）
    env.writer:ingest_event("ItemBarState", {
      slotCount = 12,
      slots = {},
    })
    local layout8 = MainHudLayout.Compute({ width = 1920, height = 1080, itemBarSlots = 8 })
    assert_at(env.nodes.ItemBarSlot8, layout8.ItemBarSlots[8], "ItemBarSlot8(8)")
    assert.is_nil(env.nodes.ItemBarSlot9)

    -- 缩容回 3 格：4..8 格节点销毁且信号连接归零
    local slot8 = env.nodes.ItemBarSlot8
    local icon8 = env.nodes.ItemBarIcon8
    local label8 = env.nodes.ItemBarLabel8
    local amount8 = env.nodes.ItemBarAmount8
    env.writer:ingest_event("ItemBarState", {
      slotCount = 3,
      slots = {},
    })
    assert.is_true(slot8.Destroyed)
    assert.is_true(icon8.Destroyed)
    assert.is_true(label8.Destroyed)
    assert.is_true(amount8.Destroyed)
    assert.equals(0, slot8.OnClicked:Count())
    assert.equals(0, slot8.OnTouchBegan:Count())
    assert.equals(0, slot8.OnTouchEnded:Count())

    env.view:dispose()
  end)

  it("渲染物品图标、烤熟前缀、数量与选中态高亮，点击槽位发送 SelectSlot", function()
    local actions = {}
    local env = mount_hud({
      height = 1080,
      send_action = function(action, value)
        actions[#actions + 1] = { action = action, value = value }
      end,
    })

    local fish_def = GameCfg.Items.Definitions[ITEM_FISH]
    local rod_def = GameCfg.Items.Definitions[ITEM_ROD]

    env.writer:ingest_event("ItemBarState", {
      slotCount = 4,
      selectedSlot = 2,
      slots = {
        [1] = { itemId = ITEM_FISH, count = 3, cooked = GameCfg.Items.CookedPriceScale },
        [2] = { itemId = ITEM_ROD, count = 1 },
      },
    })

    -- 第 1 格：烤熟鱼
    assert.is_true(env.nodes.ItemBarIcon1.Visible)
    assert.equals(fish_def.Icon, env.nodes.ItemBarIcon1.Image)
    assert.equals(GameCfg.Grill.CookedPrefix .. fish_def.Name, env.nodes.ItemBarLabel1.Text)
    assert.equals("3", env.nodes.ItemBarAmount1.Text)
    assert.same({ 54, 100, 140, 255 }, env.nodes.ItemBarSlot1.ButtonNormalColor)

    -- 第 2 格：选中高亮
    assert.is_true(env.nodes.ItemBarIcon2.Visible)
    assert.equals(rod_def.Name, env.nodes.ItemBarLabel2.Text)
    assert.equals("1", env.nodes.ItemBarAmount2.Text)
    assert.same({ 36, 130, 94, 255 }, env.nodes.ItemBarSlot2.ButtonNormalColor)

    -- 第 3 格：空槽隐藏图标与文案
    assert.is_false(env.nodes.ItemBarIcon3.Visible)
    assert.is_false(env.nodes.ItemBarLabel3.Visible)
    assert.is_false(env.nodes.ItemBarAmount3.Visible)

    -- 点击第 1 格发送 SelectSlot
    assert.is_true(Eui.Click(env.nodes.ItemBarSlot1))
    assert.equals(1, #actions)
    assert.same({ action = "SelectSlot", value = 1 }, actions[1])

    env.view:dispose()
  end)

  it("拖拽跨格命中目标发送 MoveSlot，短距微动与拖回自身不误发", function()
    local actions = {}
    local env = mount_hud({
      height = 1080,
      send_action = function(action, value)
        actions[#actions + 1] = { action = action, value = value }
      end,
    })

    env.writer:ingest_event("ItemBarState", {
      slotCount = 4,
      slots = {
        [1] = { itemId = ITEM_ROD, count = 1 },
      },
    })

    local layout = MainHudLayout.Compute({ width = 1920, height = 1080, itemBarSlots = 4 })
    local c1, c3 = layout.ItemBarSlots[1], layout.ItemBarSlots[3]

    -- 短距微动（< 10px）：不触发 MoveSlot
    env.nodes.ItemBarSlot1.OnTouchBegan:Fire({ BeganPosition = { x = c1.x, y = c1.y } })
    env.nodes.ItemBarSlot1.OnTouchEnded:Fire({ EndedPosition = { x = c1.x + 5, y = c1.y + 4 } })
    assert.equals(0, #actions)

    -- 拖回自身格内（移动 >= 10px 但仍在槽 1 范围内）：不触发 MoveSlot
    env.nodes.ItemBarSlot1.OnTouchBegan:Fire({ BeganPosition = { x = c1.x - 15, y = c1.y } })
    env.nodes.ItemBarSlot1.OnTouchEnded:Fire({ EndedPosition = { x = c1.x + 15, y = c1.y } })
    assert.equals(0, #actions)

    -- 从槽 1 拖到槽 3：发送 MoveSlot
    env.nodes.ItemBarSlot1.OnTouchBegan:Fire({ BeganPosition = { x = c1.x, y = c1.y } })
    env.nodes.ItemBarSlot1.OnTouchEnded:Fire({ EndedPosition = { x = c3.x, y = c3.y } })
    assert.equals(1, #actions)
    assert.same({
      action = "MoveSlot",
      value = {
        from = GameCfg.Items.ContainerId.ItemBar,
        index = 1,
        target = GameCfg.Items.ContainerId.ItemBar,
        slot = 3,
      },
    }, actions[1])

    env.view:dispose()
  end)

  it("爆炸物点按直投且消费后续 OnClicked，长按弹出瞄准遮罩选点投掷", function()
    local actions = {}
    local throws = {}
    local notices = {}
    local env = mount_hud({
      height = 1080,
      send_action = function(action, value)
        actions[#actions + 1] = { action = action, value = value }
      end,
      on_throw = function(slot, target)
        throws[#throws + 1] = { slot = slot, target = target }
      end,
      resolve_aim_target = function(pos)
        return { x = pos.x, y = 0, z = pos.y }
      end,
      notify = function(msg)
        notices[#notices + 1] = msg
      end,
    })

    env.writer:ingest_event("ItemBarState", {
      slotCount = 3,
      slots = {
        [1] = { itemId = ITEM_GRENADE, count = 2 },
        [2] = { itemId = ITEM_ROD, count = 1 },
      },
    })

    local layout = MainHudLayout.Compute({ width = 1920, height = 1080, itemBarSlots = 3 })
    local c1 = layout.ItemBarSlots[1]

    -- 1. 短按爆炸物槽（0.1s < LongPressSec）：直投且消费紧随的 OnClicked（不发 SelectSlot）
    env.nodes.ItemBarSlot1.OnTouchBegan:Fire({ BeganPosition = { x = c1.x, y = c1.y } })
    env.writer:advance_clock(0.1)
    env.nodes.ItemBarSlot1.OnTouchEnded:Fire({ EndedPosition = { x = c1.x, y = c1.y } })
    assert.is_true(Eui.Click(env.nodes.ItemBarSlot1))
    assert.equals(1, #throws)
    assert.same({ slot = 1, target = nil }, throws[1])
    assert.equals(0, #actions)

    -- 2. 长按爆炸物槽（0.5s >= LongPressSec）：挂载 ThrowAimOverlay 并提示落点，消费 OnClicked
    env.nodes.ItemBarSlot1.OnTouchBegan:Fire({ BeganPosition = { x = c1.x, y = c1.y } })
    env.writer:advance_clock(0.5)
    env.nodes.ItemBarSlot1.OnTouchEnded:Fire({ EndedPosition = { x = c1.x, y = c1.y } })
    assert.is_true(Eui.Click(env.nodes.ItemBarSlot1))
    assert.equals(0, #actions)

    local overlay = env.nodes.ThrowAimOverlay
    assert.is_not_nil(overlay)
    assert.is_nil(overlay.Color)
    assert.equals("点击屏幕选择投掷落点", notices[#notices])

    -- 点击遮罩选点：卸载 ThrowAimOverlay（节点销毁、连接归零）并按目标落点投掷
    overlay.OnTouchEnded:Fire({ EndedPosition = { x = 640, y = 360 } })
    assert.is_true(overlay.Destroyed)
    assert.equals(0, overlay.OnTouchEnded:Count())
    assert.equals(2, #throws)
    assert.same({ slot = 1, target = { x = 640, y = 0, z = 360 } }, throws[2])

    -- 3. 非爆炸物槽短按不触发投掷，正常发 SelectSlot
    local c2 = layout.ItemBarSlots[2]
    env.nodes.ItemBarSlot2.OnTouchBegan:Fire({ BeganPosition = { x = c2.x, y = c2.y } })
    env.writer:advance_clock(0.1)
    env.nodes.ItemBarSlot2.OnTouchEnded:Fire({ EndedPosition = { x = c2.x, y = c2.y } })
    assert.is_true(Eui.Click(env.nodes.ItemBarSlot2))
    assert.equals(2, #throws)
    assert.equals(1, #actions)
    assert.same({ action = "SelectSlot", value = 2 }, actions[1])

    env.view:dispose()
  end)

  it("backpack_open 展开时保留底部道具栏可见并取消瞄准遮罩；hud_visible=false 关屏时全隐藏", function()
    local backpack_open = State.new("Test.itembar_backpack_open", false)
    local env = mount_hud({
      height = 1080,
      backpack_open = backpack_open,
      notify = function() end,
    })

    env.writer:ingest_event("ItemBarState", {
      slotCount = 3,
      slots = {
        [1] = { itemId = ITEM_GRENADE, count = 1 },
      },
    })

    -- 先长按进入瞄准态
    local layout = MainHudLayout.Compute({ width = 1920, height = 1080, itemBarSlots = 3 })
    local c1 = layout.ItemBarSlots[1]
    env.nodes.ItemBarSlot1.OnTouchBegan:Fire({ BeganPosition = { x = c1.x, y = c1.y } })
    env.writer:advance_clock(0.5)
    env.nodes.ItemBarSlot1.OnTouchEnded:Fire({ EndedPosition = { x = c1.x, y = c1.y } })
    local overlay = env.nodes.ThrowAimOverlay
    assert.is_not_nil(overlay)

    -- 展开背包：取消瞄准遮罩，同时保留底部道具栏可见可交互（支持道具栏↔背包双向拖拽）
    backpack_open:set(true)
    assert.is_true(overlay.Destroyed)
    for i = 1, 3 do
      assert.is_true(env.nodes["ItemBarSlot" .. i].Visible)
      assert.is_true(env.nodes["ItemBarSlot" .. i].TouchEnabled)
    end
    assert.is_true(env.nodes.ItemBarIcon1.Visible)
    assert.is_true(env.nodes.ItemBarLabel1.Visible)
    assert.is_true(env.nodes.ItemBarAmount1.Visible)
    assert.is_false(env.nodes.ItemBarIcon2.Visible)

    -- 关屏（hud_visible=false）：底部道具栏全部隐藏并禁点
    env.writer:set_hud_visible(false)
    for i = 1, 3 do
      assert.is_false(env.nodes["ItemBarSlot" .. i].Visible)
      assert.is_false(env.nodes["ItemBarSlot" .. i].TouchEnabled)
      assert.is_false(env.nodes["ItemBarIcon" .. i].Visible)
      assert.is_false(env.nodes["ItemBarLabel" .. i].Visible)
      assert.is_false(env.nodes["ItemBarAmount" .. i].Visible)
    end

    -- 重新开屏：槽位恢复可见可点，有物品格恢复图标与文字
    env.writer:set_hud_visible(true)
    backpack_open:set(false)
    assert.is_true(env.nodes.ItemBarSlot1.Visible)
    assert.is_true(env.nodes.ItemBarSlot1.TouchEnabled)
    assert.is_true(env.nodes.ItemBarIcon1.Visible)
    assert.is_true(env.nodes.ItemBarLabel1.Visible)
    assert.is_true(env.nodes.ItemBarAmount1.Visible)
    assert.is_true(env.nodes.ItemBarSlot2.Visible)
    assert.is_false(env.nodes.ItemBarIcon2.Visible)

    env.view:dispose()
  end)

  it("重连重置与根 UI 销毁后全部槽位、瞄准节点及信号连接归零", function()
    local env = mount_hud({
      height = 1080,
      notify = function() end,
    })

    env.writer:ingest_event("ItemBarState", {
      slotCount = 4,
      slots = {
        [1] = { itemId = ITEM_GRENADE, count = 2 },
      },
    })

    -- 进入瞄准态，确保重连时连同 ThrowAimOverlay 一并清理
    local layout = MainHudLayout.Compute({ width = 1920, height = 1080, itemBarSlots = 4 })
    local c1 = layout.ItemBarSlots[1]
    env.nodes.ItemBarSlot1.OnTouchBegan:Fire({ BeganPosition = { x = c1.x, y = c1.y } })
    env.writer:advance_clock(0.5)
    env.nodes.ItemBarSlot1.OnTouchEnded:Fire({ EndedPosition = { x = c1.x, y = c1.y } })
    assert.is_not_nil(env.nodes.ThrowAimOverlay)

    local first_batch = {}
    for i = 1, #env.created do
      first_batch[i] = env.created[i]
    end
    assert.is_true(#first_batch >= 17)

    -- 1. 重连重置：上一轮全部节点销毁且所有事件连接归零，新一轮以干净默认 2 格重建
    env.writer:reset_session("reconnect")
    for _, node in ipairs(first_batch) do
      assert.is_true(node.Destroyed, "重连后旧节点必须销毁: " .. tostring(node.Name))
      assert.equals(0, node.OnClicked:Count(), "重连后 OnClicked 连接必须归零: " .. tostring(node.Name))
      assert.equals(0, node.OnTouchBegan:Count(), "重连后 OnTouchBegan 连接必须归零: " .. tostring(node.Name))
      assert.equals(0, node.OnTouchEnded:Count(), "重连后 OnTouchEnded 连接必须归零: " .. tostring(node.Name))
    end
    assert.is_nil(env.nodes.ItemBarSlot1.Destroyed)
    assert.equals(1, env.nodes.ItemBarSlot1.OnClicked:Count())

    -- 2. 宿主根 UI 销毁：全部节点销毁且全部连接归零
    env.root_node:Destroy()
    for _, node in ipairs(env.created) do
      assert.is_true(node.Destroyed, "根 UI 销毁后节点不得残留: " .. tostring(node.Name))
      assert.equals(0, node.OnClicked:Count(), "根 UI 销毁后 OnClicked 连接必须归零: " .. tostring(node.Name))
      assert.equals(0, node.OnTouchBegan:Count(), "根 UI 销毁后 OnTouchBegan 连接必须归零: " .. tostring(node.Name))
      assert.equals(0, node.OnTouchEnded:Count(), "根 UI 销毁后 OnTouchEnded 连接必须归零: " .. tostring(node.Name))
    end
  end)
end)
