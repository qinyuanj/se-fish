-- #297-B3a 客户端主 HUD 武器栏/鱼饵栏及其展开浮层 Spoke 视图黑盒契约测试。
-- 失败方式先列：
--   1. 武器栏/鱼饵栏未按 MainHudLayout 排版或未随 ItemBarState 实时更新文案，或 EUIButton 误写 Color 属性；
--   2. 点击武器栏/鱼饵栏不能展开浮层、切换另一栏未互斥销毁旧候选格，或点击遮罩/再次点击自身无法关闭；
--   3. 点击浮层候选格未经 ItemBarAction 发送正确上行协议（operate attack / SelectBait / EatBait），或禁用项可被误触；
--   4. 重连重置或根 UI 销毁后遗留浮层/栏位节点，或按钮 OnClicked 信号连接未归零。

local Eui = require("tests.support.eui_double")
local GameCfg = require("common.game_cfg")
local MainHudLayout = require("client.main_hud_layout")
local ClientStore = require("client.store.client_store")
local RootView = require("client.views.root_view")
local MainHudEquipPopups = require("client.views.main_hud_equip_popups")

local WEAPON_KNIFE = "item135"
local WEAPON_PISTOL = "item137"

local function assert_at(node, rect, label)
  assert.is_not_nil(node, label)
  assert.same({ x = rect.x, y = rect.y }, { x = node.Position.x, y = node.Position.y }, label)
  assert.same({ x = rect.w, y = rect.h }, { x = node.Size.x, y = node.Size.y }, label)
end

describe("Spoke 主 HUD 武器栏/鱼饵栏与展开浮层视图（#297-B3a）", function()
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

  local function mount_popups(opts)
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
        MainHudEquipPopups.spec({
          get_resolution = opts.get_resolution or function() return { x = 1920, y = opts.height or 1080 } end,
          send_action = opts.send_action,
          send_operate = opts.send_operate,
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

  it("武器栏与鱼饵栏按 MainHudLayout 排版并随 ItemBarState 实时渲染，且 EUIButton 不写 Color 属性", function()
    local env = mount_popups({ height = 1080 })
    local ids = GameCfg.Items.Id

    -- 初始无快照时鱼饵栏回退「不挂鱼饵」
    assert.is_truthy(env.nodes.BaitBarLabel.Text:find("不挂", 1, true))
    assert.equals("", env.nodes.WeaponBarLabel.Text)
    assert.is_nil(env.nodes.WeaponBar.Color)
    assert.is_nil(env.nodes.BaitBar.Color)
    assert.is_true(env.nodes.WeaponBarLabel.LocalZOrder > env.nodes.WeaponBar.LocalZOrder)
    assert.is_true(env.nodes.BaitBarLabel.LocalZOrder > env.nodes.BaitBar.LocalZOrder)

    -- 推入 5 格 ItemBarState：排版随 slotCount 更新，武器栏优先展示手持武器，鱼饵栏展示当前选中鱼饵与数量
    env.writer:ingest_event("ItemBarState", {
      slotCount = 5,
      slots = {},
      weapons = { [WEAPON_KNIFE] = 1, [WEAPON_PISTOL] = 1 },
      selectedWeapon = WEAPON_KNIFE,
      held = { kind = "weapon", id = WEAPON_PISTOL },
      bait = { [ids.Worm] = 7, [ids.Sausage] = 2 },
      selectedBait = ids.Worm,
    })

    local layout = MainHudLayout.compute({ width = 1920, height = 1080, itemBarSlots = 5 })
    assert_at(env.nodes.WeaponBar, layout.Rects.WeaponBar, "WeaponBar")
    assert_at(env.nodes.WeaponBarLabel, layout.Rects.WeaponBar, "WeaponBarLabel")
    assert_at(env.nodes.BaitBar, layout.Rects.BaitBar, "BaitBar")
    assert_at(env.nodes.BaitBarLabel, layout.Rects.BaitBar, "BaitBarLabel")

    local pistol_name = GameCfg.Items.Definitions[WEAPON_PISTOL].Name
    local worm_name = GameCfg.Items.Definitions[ids.Worm].Name
    assert.is_truthy(env.nodes.WeaponBarLabel.Text:gsub("\n", ""):find(pistol_name, 1, true))
    assert.is_truthy(env.nodes.BaitBarLabel.Text:gsub("\n", ""):find(worm_name, 1, true))
    assert.is_truthy(env.nodes.BaitBarLabel.Text:find("×7", 1, true))

    env.view:dispose()
  end)

  it("展开浮层、互斥切换与遮罩关闭均由 Phase+Dock 干净销毁旧节点", function()
    local env = mount_popups({ height = 1080 })
    local ids = GameCfg.Items.Id

    env.writer:ingest_event("ItemBarState", {
      slotCount = 8,
      slots = {},
      weapons = { [WEAPON_KNIFE] = 1, [WEAPON_PISTOL] = 0 },
      selectedWeapon = WEAPON_KNIFE,
      bait = { [ids.Worm] = 3, [ids.Sausage] = 0, [ids.Duck] = 1 },
      selectedBait = ids.Worm,
    })

    -- 初始未展开：浮层遮罩与底板均不存在
    assert.is_nil(env.nodes.PopupDismiss)
    assert.is_nil(env.nodes.WeaponPopup)

    -- 1. 点击武器栏展开武器浮层
    assert.is_true(Eui.click(env.nodes.WeaponBar))
    local dismiss = env.nodes.PopupDismiss
    local knife_btn = env.nodes["WeaponPopupCell_" .. WEAPON_KNIFE]
    local pistol_btn = env.nodes["WeaponPopupCell_" .. WEAPON_PISTOL]
    assert.is_not_nil(dismiss)
    assert.is_not_nil(knife_btn)
    assert.is_not_nil(pistol_btn)
    assert.is_true(env.nodes.WeaponPopup.Visible)
    assert.is_false(env.nodes.BaitPopup.Visible)
    assert.is_true(knife_btn.TouchEnabled)
    assert.is_false(pistol_btn.TouchEnabled)
    assert.is_nil(knife_btn.Color)

    -- 2. 直接点击鱼饵栏：互斥切换，武器候选格立即销毁并断开连接，鱼饵候选格挂载
    assert.is_true(Eui.click(env.nodes.BaitBar))
    assert.is_true(knife_btn.Destroyed)
    assert.is_true(pistol_btn.Destroyed)
    assert.equals(0, knife_btn.OnClicked:Count())
    assert.is_false(env.nodes.WeaponPopup.Visible)
    assert.is_true(env.nodes.BaitPopup.Visible)
    local worm_btn = env.nodes["BaitPopupCell_" .. ids.Worm]
    local no_bait_btn = env.nodes["BaitPopupCell_NoBait"]
    local eat_worm_btn = env.nodes["BaitPopupCell_EatWorm"]
    assert.is_not_nil(worm_btn)
    assert.is_not_nil(no_bait_btn)
    assert.is_not_nil(eat_worm_btn)
    assert.is_true(worm_btn.TouchEnabled)
    assert.is_true(no_bait_btn.TouchEnabled)
    assert.is_true(eat_worm_btn.TouchEnabled)

    -- 3. 点击透明遮罩关闭浮层：Phase 卸载，遮罩/底板/候选格全部销毁且连接归零
    assert.is_true(Eui.click(dismiss))
    assert.is_true(dismiss.Destroyed)
    assert.is_true(worm_btn.Destroyed)
    assert.is_true(no_bait_btn.Destroyed)
    assert.is_true(eat_worm_btn.Destroyed)
    assert.equals(0, dismiss.OnClicked:Count())
    assert.equals(0, worm_btn.OnClicked:Count())

    -- 4. 再次点击武器栏展开，再点一次武器栏自身可收起
    assert.is_true(Eui.click(env.nodes.WeaponBar))
    local dismiss2 = env.nodes.PopupDismiss
    assert.is_nil(dismiss2.Destroyed)
    assert.is_true(Eui.click(env.nodes.WeaponBar))
    assert.is_true(dismiss2.Destroyed)

    env.view:dispose()
  end)

  it("点击浮层候选格经默认 ItemBarAction 上行 RE 发送正确协议并自动收起，禁用项不触发", function()
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
      local env = mount_popups({ height = 1080 })
      local ids = GameCfg.Items.Id

      env.writer:ingest_event("ItemBarState", {
        slotCount = 8,
        slots = {},
        weapons = { [WEAPON_KNIFE] = 1, [WEAPON_PISTOL] = 0 },
        selectedWeapon = WEAPON_KNIFE,
        bait = { [ids.Worm] = 2, [ids.Sausage] = 0, [ids.Duck] = 1 },
        selectedBait = ids.Worm,
      })

      -- 点击禁用武器（数量 0）不发送 RE
      assert.is_true(Eui.click(env.nodes.WeaponBar))
      assert.is_false(Eui.click(env.nodes["WeaponPopupCell_" .. WEAPON_PISTOL]))
      assert.equals(0, #sent)

      -- 点击可用武器：发送 operate / op = attack / weapon = Knife 并自动关闭浮层
      local weapon_dismiss = env.nodes.PopupDismiss
      assert.is_true(Eui.click(env.nodes["WeaponPopupCell_" .. WEAPON_KNIFE]))
      assert.equals(1, #sent)
      assert.equals("ItemBarAction", sent[1].name)
      assert.equals("Operate", sent[1].payload.action)
      assert.equals("attack", sent[1].payload.op)
      assert.equals(WEAPON_KNIFE, sent[1].payload.weapon)
      assert.equals(1, sent[1].payload.seq)
      assert.is_true(weapon_dismiss.Destroyed)

      -- 展开鱼饵浮层，点击鸭肉 -> SelectBait(Duck)
      assert.is_true(Eui.click(env.nodes.BaitBar))
      assert.is_true(Eui.click(env.nodes["BaitPopupCell_" .. ids.Duck]))
      assert.equals(2, #sent)
      assert.equals("ItemBarAction", sent[2].name)
      assert.same({ action = "SelectBait", value = ids.Duck }, sent[2].payload)

      -- 展开鱼饵浮层，点击不挂鱼饵 -> SelectBait(nil)
      assert.is_true(Eui.click(env.nodes.BaitBar))
      assert.is_true(Eui.click(env.nodes["BaitPopupCell_NoBait"]))
      assert.equals(3, #sent)
      assert.same({ action = "SelectBait" }, sent[3].payload)

      -- 展开鱼饵浮层，点击吃蚯蚓 -> EatBait(Worm)
      assert.is_true(Eui.click(env.nodes.BaitBar))
      assert.is_true(Eui.click(env.nodes["BaitPopupCell_EatWorm"]))
      assert.equals(4, #sent)
      assert.same({ action = "EatBait", value = ids.Worm }, sent[4].payload)

      env.view:dispose()
    end)

    _G.REUtil = prev_re_util
    if not ok then
      error(err, 0)
    end
  end)

  it("重连重置与根 UI 销毁后全部节点与信号连接归零", function()
    local env = mount_popups({ height = 1080 })
    local ids = GameCfg.Items.Id

    env.writer:ingest_event("ItemBarState", {
      slotCount = 8,
      slots = {},
      weapons = { [WEAPON_KNIFE] = 1 },
      selectedWeapon = WEAPON_KNIFE,
      bait = { [ids.Worm] = 5 },
      selectedBait = ids.Worm,
    })

    -- 打开武器浮层
    assert.is_true(Eui.click(env.nodes.WeaponBar))
    local first_batch = {}
    for i = 1, #env.created do
      first_batch[i] = env.created[i]
    end
    assert.is_true(#first_batch >= 6)

    -- 1. 重连重置：上一轮常驻栏位与展开浮层全部销毁且信号连接归零，新一轮以干净收起态重建
    env.writer:reset_session("reconnect")
    for _, node in ipairs(first_batch) do
      assert.is_true(node.Destroyed, "重连后旧节点必须销毁: " .. tostring(node.Name))
      assert.equals(0, node.OnClicked:Count(), "重连后旧按钮连接必须归零: " .. tostring(node.Name))
    end
    assert.is_nil(env.nodes.WeaponBar.Destroyed)
    assert.equals(1, env.nodes.WeaponBar.OnClicked:Count())
    assert.equals(1, env.nodes.BaitBar.OnClicked:Count())

    -- 重连后重新下发数据并展开鱼饵浮层
    env.writer:ingest_event("ItemBarState", {
      slotCount = 8,
      slots = {},
      weapons = { [WEAPON_KNIFE] = 1 },
      bait = { [ids.Worm] = 2 },
    })
    assert.is_true(Eui.click(env.nodes.BaitBar))
    assert.is_nil(env.nodes.PopupDismiss.Destroyed)

    -- 2. 宿主根 UI 销毁：全部节点销毁，全部 OnClicked 连接归零
    env.root_node:Destroy()
    for _, node in ipairs(env.created) do
      assert.is_true(node.Destroyed, "根 UI 销毁后节点不得残留: " .. tostring(node.Name))
      assert.equals(0, node.OnClicked:Count(), "根 UI 销毁后信号连接必须归零: " .. tostring(node.Name))
    end
  end)
end)
