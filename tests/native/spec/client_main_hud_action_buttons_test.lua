-- #297-B3b1 客户端主 HUD 右侧 ItemDiscard 与 ItemAction2 动作键 Spoke 视图黑盒契约测试。
-- 失败方式先列：
--   1. ItemDiscard / ItemAction2 未按 MainHudLayout 排版、EUIButton 误写 Color 属性或文案标签未处于更高 LocalZOrder；
--   2. 不同选中物与收线/持有/特殊态下动作键文案、颜色、可用态或显隐切换与 ScreenMain 不一致；
--   3. 点击丢弃/吃/抛竿/收竿/放下/吐息或长按飞行未发送对应上行 RE（含 ItemBarAction Operate）；
--   4. 背包展开（backpack_open=true）未隐藏并禁用右侧两个动作键，或收起后未按当前快照恢复；
--   5. 重连重置或根 UI 销毁后遗留按钮/标签节点，或 OnClicked / OnTouchBegan / OnTouchEnded 连接未归零。

local spoke = require("common.packages.spoke.api")
local Eui = require("tests.support.eui_double")
local GameCfg = require("common.GameCfg")
local MainHudLayout = require("client.MainHudLayout")
local ClientStore = require("client.Store.ClientStore")
local RootView = require("client.Views.RootView")
local MainHudActionButtonsView = require("client.Views.MainHudActionButtonsView")

local State = spoke.State

local ITEM_ROD = GameCfg.Items.Id.StarterRod
local ITEM_FISH = GameCfg.Items.Id.Tilapia

local function assert_at(node, rect, label)
  assert.is_not_nil(node, label)
  assert.same({ x = rect.x, y = rect.y }, { x = node.Position.x, y = node.Position.y }, label)
  assert.same({ x = rect.w, y = rect.h }, { x = node.Size.x, y = node.Size.y }, label)
end

describe("Spoke 主 HUD 右侧动作键视图（#297-B3b1）", function()
  local saved_globals

  before_each(function()
    saved_globals = {
      Vector2 = rawget(_G, "Vector2"),
      Color = rawget(_G, "Color"),
      REUtil = rawget(_G, "REUtil"),
    }
    _G.Vector2 = { New = function(x, y) return { x = x, y = y } end }
    _G.Color = { New = function(...) return { ... } end }
  end)

  after_each(function()
    _G.Vector2 = saved_globals.Vector2
    _G.Color = saved_globals.Color
    _G.REUtil = saved_globals.REUtil
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

    local view = RootView.mount(root_node, store, {
      create_node = create_node,
      hud = {
        MainHudActionButtonsView.spec({
          get_resolution = resolution_fn,
          backpack_open = opts.backpack_open,
          reel_active = opts.reel_active,
          on_reel_click = opts.on_reel_click,
          send_operate = opts.send_operate,
          send_cast = opts.send_cast,
          send_special = opts.send_special,
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

  it("按 MainHudLayout 排版、EUIButton 不写 Color、同级高 ZOrder 标签，并随选中物切换文案与显隐", function()
    local env = mount_hud({ height = 1080 })
    local layout = MainHudLayout.Compute({ width = 1920, height = 1080, itemBarSlots = GameCfg.Items.ItemBarSlots })

    local btn_discard = env.nodes.ItemDiscard
    local lbl_discard = env.nodes.BtnDiscardLabel
    local btn_action = env.nodes.ItemAction2
    local lbl_action = env.nodes.BtnItemActionLabel

    assert_at(btn_discard, layout.Rects.Discard, "ItemDiscard")
    assert_at(lbl_discard, layout.Rects.Discard, "BtnDiscardLabel")
    assert_at(btn_action, layout.Rects.ItemAction, "ItemAction2")
    assert_at(lbl_action, layout.Rects.ItemAction, "BtnItemActionLabel")

    -- EUIButton 严禁写 Color；文案标签 LocalZOrder 必须高于按钮
    assert.is_nil(btn_discard.Color)
    assert.is_nil(btn_action.Color)
    assert.is_true(lbl_discard.LocalZOrder > btn_discard.LocalZOrder)
    assert.is_true(lbl_action.LocalZOrder > btn_action.LocalZOrder)

    -- 初始无快照：两个按钮均隐藏
    assert.is_false(btn_discard.Visible)
    assert.is_false(lbl_discard.Visible)
    assert.is_false(btn_action.Visible)
    assert.is_false(lbl_action.Visible)

    -- 1. 选中鱼竿：抛竿 + 丢弃选中物
    env.writer:ingest_event("ItemBarState", {
      slotCount = 4,
      selectedSlot = 1,
      slots = { [1] = { itemId = ITEM_ROD, count = 1 } },
    })
    assert.is_true(btn_discard.Visible)
    assert.equals("丢弃选中物", lbl_discard.Text)
    assert.is_true(btn_action.Visible)
    assert.is_true(btn_action.TouchEnabled)
    assert.equals("抛竿", lbl_action.Text)
    assert.same({ 54, 100, 140, 255 }, btn_action.ButtonNormalColor)

    -- 2. 选中鱼（未手持 -> 手持XX；已手持 -> 吃XX + 确认丢弃）
    local fish_name = GameCfg.Items.Definitions[ITEM_FISH].Name
    env.writer:ingest_event("ItemBarState", {
      slotCount = 4,
      selectedSlot = 2,
      slots = { [2] = { itemId = ITEM_FISH, count = 1 } },
    })
    assert.equals("丢弃选中物", lbl_discard.Text)
    assert.equals("手持" .. fish_name, lbl_action.Text)

    env.writer:ingest_event("ItemBarState", {
      slotCount = 4,
      selectedSlot = 2,
      held = { kind = "slot", slot = 2 },
      slots = { [2] = { itemId = ITEM_FISH, count = 1 } },
    })
    assert.equals("确认丢弃", lbl_discard.Text)
    assert.equals("吃" .. fish_name, lbl_action.Text)

    -- 3. 抛竿在线/上钩收线/已上岸/手持放下
    env.writer:ingest_event("CastState", { phase = "cast" })
    assert.equals("收竿", lbl_action.Text)
    assert.is_true(btn_action.TouchEnabled)

    env.writer:ingest_event("CastState", { phase = "hooked", reelSession = 7 })
    assert.equals("点击收线", lbl_action.Text)
    assert.is_true(btn_action.TouchEnabled)

    env.writer:ingest_event("CastState", { phase = "landed" })
    assert.equals("已上岸", lbl_action.Text)
    assert.is_false(btn_action.TouchEnabled)
    assert.same({ 120, 120, 120, 255 }, btn_action.ButtonNormalColor)

    env.writer:ingest_event("CastState", { phase = "idle", holding = { fishId = ITEM_FISH } })
    assert.equals("放下", lbl_action.Text)
    assert.is_true(btn_action.TouchEnabled)

    -- 4. 特殊道具：风神之翼（长按飞行）与哥斯拉（原子吐息冷却倒计时）
    env.writer:ingest_event("CastState", { phase = "idle" })
    env.writer:ingest_event("SpecialItemState", { effect = "wings" })
    assert.equals("长按飞行", lbl_action.Text)
    assert.is_true(btn_action.TouchEnabled)

    env.writer:ingest_event("SpecialItemState", { effect = "godzilla", breathRemaining = 2.4 })
    assert.equals("吐息冷却 3秒", lbl_action.Text)
    assert.is_false(btn_action.TouchEnabled)

    -- 1Hz on_second 逐秒更新吐息冷却文案，满 3 秒后恢复可用
    env.writer:step_clock(1, 101)
    assert.equals("吐息冷却 2秒", lbl_action.Text)
    assert.is_false(btn_action.TouchEnabled)
    env.writer:step_clock(1, 102)
    assert.equals("吐息冷却 1秒", lbl_action.Text)
    assert.is_false(btn_action.TouchEnabled)
    env.writer:step_clock(1, 103)
    assert.equals("原子吐息", lbl_action.Text)
    assert.is_true(btn_action.TouchEnabled)

    env.view:dispose()
  end)

  it("上钩高亮闪烁仅在活跃窗口内原地更新按钮颜色，绝不触发 ActionButtonsProjection Effect 重跑", function()
    local layout_reads = 0
    local custom_layout = State.new("Test.action_layout", MainHudLayout.Compute({
      width = 1920,
      height = 1080,
      itemBarSlots = 4,
    }))
    local tracked_layout = {
      now = function()
        return custom_layout:now()
      end,
      subscribe = function(_, fn)
        return custom_layout:subscribe(fn)
      end,
      unsubscribe = function(_, fn)
        custom_layout:unsubscribe(fn)
      end,
    }

    local store, writer = ClientStore.new({ initial_now = 100 })
    local root_node = Eui.Node({ Name = "UIRoot" })
    local nodes = {}
    local discard_visible_writes = 0

    local function create_node(kind, props)
      local node = Eui.Node({
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
      if node.Name == "ItemDiscard" then
        local mt = getmetatable(node)
        local orig_newindex = mt.__newindex
        mt.__newindex = function(tbl, key, val)
          if key == "Visible" then
            discard_visible_writes = discard_visible_writes + 1
          end
          return orig_newindex(tbl, key, val)
        end
      end
      nodes[node.Name] = node
      return node
    end

    local view = RootView.mount(root_node, store, {
      create_node = create_node,
      hud = {
        MainHudActionButtonsView.spec({
          get_resolution = function() return { x = 1920, y = 1080 } end,
          layout = tracked_layout,
        }),
      },
    })
    assert.is_nil(view.root.fault)

    writer:ingest_event("CastState", { phase = "hooked", reelSession = 99 })
    local btn_action = nodes.ItemAction2
    local writes_before_frames = discard_visible_writes
    local color_t0 = btn_action.ButtonNormalColor

    -- 推进多帧闪烁：按钮颜色原地变化，但 ActionButtonsProjection 不得重跑（ItemDiscard.Visible 写入次数为 0）
    local quarter_period = GameCfg.HookAlert.BreathPeriodSec / 4
    writer:step_clock(quarter_period, 100 + quarter_period)
    local color_t1 = btn_action.ButtonNormalColor
    assert.equals(writes_before_frames, discard_visible_writes, "on_frame 闪烁不得重建/重跑 ActionButtonsProjection Effect")
    assert.is_not.same(color_t0, color_t1)
    assert.same(color_t1, btn_action.ButtonPressColor)

    writer:step_clock(quarter_period, 100 + quarter_period * 2)
    assert.equals(writes_before_frames, discard_visible_writes)

    -- 超过高亮时长后恢复常态颜色并退出闪烁 Phase，同样不触发 ActionButtonsProjection 重跑
    writer:step_clock(GameCfg.HookAlert.DurationSec + 0.5, 100 + GameCfg.HookAlert.DurationSec + 1)
    assert.equals(writes_before_frames, discard_visible_writes)
    assert.same({ 54, 100, 140, 255 }, btn_action.ButtonNormalColor)
    assert.same({ 42, 82, 118, 255 }, btn_action.ButtonPressColor)
    assert.equals(0, layout_reads)

    view:dispose()
  end)

  it("点击 ItemDiscard / ItemAction2 经默认 RE 通道发送 Operate 丢弃/吃、CastAction 与 SpecialItemAction", function()
    local sent = {}
    _G.REUtil = {
      GetRE = function(_, name)
        return {
          FireServer = function(_, payload)
            sent[#sent + 1] = { name = name, payload = payload }
          end,
        }
      end,
    }

    local reel_clicks = {}
    local env = mount_hud({
      on_reel_click = function(session_id)
        reel_clicks[#reel_clicks + 1] = session_id
      end,
    })

    -- 1. 丢弃选中格 & 吃鱼
    env.writer:ingest_event("ItemBarState", {
      slotCount = 4,
      selectedSlot = 2,
      held = { kind = "slot", slot = 2 },
      slots = { [2] = { itemId = ITEM_FISH, count = 1 } },
    })
    assert.is_true(Eui.Click(env.nodes.ItemDiscard))
    assert.equals("ItemBarAction", sent[1].name)
    assert.equals("Operate", sent[1].payload.action)
    assert.equals("discard", sent[1].payload.op)
    assert.equals(2, sent[1].payload.slot)
    assert.equals(1, sent[1].payload.seq)

    assert.is_true(Eui.Click(env.nodes.ItemAction2))
    assert.equals("ItemBarAction", sent[2].name)
    assert.equals("Operate", sent[2].payload.action)
    assert.equals("eat", sent[2].payload.op)
    assert.equals(2, sent[2].payload.slot)
    assert.equals(2, sent[2].payload.seq)

    -- 2. 选中鱼竿点击抛竿 -> CastAction Cast
    env.writer:ingest_event("ItemBarState", {
      slotCount = 4,
      selectedSlot = 1,
      slots = { [1] = { itemId = ITEM_ROD, count = 1 } },
    })
    assert.is_true(Eui.Click(env.nodes.ItemAction2))
    assert.equals("CastAction", sent[3].name)
    assert.same({ action = "Cast", slot = 1, itemId = ITEM_ROD }, sent[3].payload)

    -- 3. 抛竿在线点击收竿 -> CastAction Reel；上钩点击收线 -> on_reel_click
    env.writer:ingest_event("CastState", { phase = "cast" })
    assert.is_true(Eui.Click(env.nodes.ItemAction2))
    assert.same({ action = "Reel" }, sent[4].payload)

    env.writer:ingest_event("CastState", { phase = "hooked", reelSession = 42 })
    assert.is_true(Eui.Click(env.nodes.ItemAction2))
    assert.same({ 42 }, reel_clicks)

    -- 4. 持有物点击放下 -> CastAction Drop
    env.writer:ingest_event("CastState", { phase = "idle", holding = { fishId = ITEM_FISH } })
    assert.is_true(Eui.Click(env.nodes.ItemAction2))
    assert.same({ action = "Drop" }, sent[5].payload)

    -- 5. 风神之翼长按/松开飞行 -> SpecialItemAction fly
    env.writer:ingest_event("CastState", { phase = "idle" })
    env.writer:ingest_event("SpecialItemState", { effect = "wings" })
    env.nodes.ItemAction2.OnTouchBegan:Fire()
    env.nodes.ItemAction2.OnTouchEnded:Fire()
    assert.equals("SpecialItemAction", sent[6].name)
    assert.same({ action = "fly", holding = true }, sent[6].payload)
    assert.equals("SpecialItemAction", sent[7].name)
    assert.same({ action = "fly", holding = false }, sent[7].payload)

    -- 6. 哥斯拉原子吐息 -> SpecialItemAction breath
    env.writer:ingest_event("SpecialItemState", { effect = "godzilla", breathRemaining = 0 })
    assert.is_true(Eui.Click(env.nodes.ItemAction2))
    assert.equals("SpecialItemAction", sent[8].name)
    assert.same({ action = "breath" }, sent[8].payload)

    env.view:dispose()
  end)

  it("背包展开（backpack_open=true）遮挡隐藏并禁用动作键，收起后按当前快照恢复", function()
    local backpack_open = State.new("Test.actions_backpack_open", false)
    local sent_ops = {}
    local env = mount_hud({
      backpack_open = backpack_open,
      send_operate = function(payload)
        sent_ops[#sent_ops + 1] = payload
      end,
    })

    env.writer:ingest_event("ItemBarState", {
      slotCount = 4,
      selectedSlot = 1,
      slots = { [1] = { itemId = ITEM_ROD, count = 1 } },
    })
    assert.is_true(env.nodes.ItemDiscard.Visible)
    assert.is_true(env.nodes.BtnDiscardLabel.Visible)
    assert.is_true(env.nodes.ItemAction2.Visible)
    assert.is_true(env.nodes.BtnItemActionLabel.Visible)

    -- 展开背包：全部隐藏且禁点
    backpack_open:set(true)
    assert.is_false(env.nodes.ItemDiscard.Visible)
    assert.is_false(env.nodes.ItemDiscard.TouchEnabled)
    assert.is_false(env.nodes.BtnDiscardLabel.Visible)
    assert.is_false(env.nodes.ItemAction2.Visible)
    assert.is_false(env.nodes.ItemAction2.TouchEnabled)
    assert.is_false(env.nodes.BtnItemActionLabel.Visible)
    assert.is_false(Eui.Click(env.nodes.ItemDiscard))
    assert.equals(0, #sent_ops)

    -- 收起背包：恢复显示并可点击
    backpack_open:set(false)
    assert.is_true(env.nodes.ItemDiscard.Visible)
    assert.is_true(env.nodes.ItemDiscard.TouchEnabled)
    assert.is_true(env.nodes.ItemAction2.Visible)
    assert.is_true(env.nodes.ItemAction2.TouchEnabled)
    assert.is_true(Eui.Click(env.nodes.ItemDiscard))
    assert.equals(1, #sent_ops)

    env.view:dispose()
  end)

  it("重连重置与根 UI 销毁后全部节点销毁且所有事件连接归零", function()
    local sent_special = {}
    local env = mount_hud({
      send_special = function(payload)
        sent_special[#sent_special + 1] = payload
      end,
    })

    env.writer:ingest_event("ItemBarState", {
      slotCount = 4,
      selectedSlot = 1,
      slots = { [1] = { itemId = ITEM_ROD, count = 1 } },
    })
    env.writer:ingest_event("SpecialItemState", { effect = "wings" })
    env.nodes.ItemAction2.OnTouchBegan:Fire()

    local first_batch = {}
    for i = 1, #env.created do
      first_batch[i] = env.created[i]
    end
    assert.equals(4, #first_batch)

    -- 1. 重连重置：旧节点销毁、连接归零，且飞行按住态自动发送 holding=false 兜底
    env.writer:reset_session("reconnect")
    assert.same({ action = "fly", holding = false }, sent_special[#sent_special])
    for _, node in ipairs(first_batch) do
      assert.is_true(node.Destroyed, "重连后旧节点必须销毁: " .. tostring(node.Name))
      assert.equals(0, node.OnClicked:Count(), "重连后 OnClicked 必须归零: " .. tostring(node.Name))
      if node.OnTouchBegan then
        assert.equals(0, node.OnTouchBegan:Count(), "重连后 OnTouchBegan 必须归零: " .. tostring(node.Name))
      end
      if node.OnTouchEnded then
        assert.equals(0, node.OnTouchEnded:Count(), "重连后 OnTouchEnded 必须归零: " .. tostring(node.Name))
      end
    end

    -- 新一轮节点已干净重建
    assert.is_nil(env.nodes.ItemDiscard.Destroyed)
    assert.equals(1, env.nodes.ItemDiscard.OnClicked:Count())
    assert.equals(1, env.nodes.ItemAction2.OnClicked:Count())

    -- 2. 宿主根 UI 销毁：全部节点销毁，全部信号连接归零
    env.root_node:Destroy()
    for _, node in ipairs(env.created) do
      assert.is_true(node.Destroyed, "根 UI 销毁后节点不得残留: " .. tostring(node.Name))
      assert.equals(0, node.OnClicked:Count(), "根 UI 销毁后 OnClicked 必须归零: " .. tostring(node.Name))
      if node.OnTouchBegan then
        assert.equals(0, node.OnTouchBegan:Count(), "根 UI 销毁后 OnTouchBegan 必须归零: " .. tostring(node.Name))
      end
      if node.OnTouchEnded then
        assert.equals(0, node.OnTouchEnded:Count(), "根 UI 销毁后 OnTouchEnded 必须归零: " .. tostring(node.Name))
      end
    end
  end)
end)
