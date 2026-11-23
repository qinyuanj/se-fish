-- #311 客户端商店与钓鱼佬宿主接缝（#292 Testing Decisions）。
-- 通过位置写侧、UI 点击、远端回执和根节点销毁观察，不读取视图私有 Effect 拓扑。
local GameCfg = require("common.GameCfg")
local ClientStore = require("client.Store.ClientStore")
local RootView = require("client.Views.RootView")
local ShopView = require("client.Views.ShopView")
local FishermanView = require("client.Views.FishermanView")
local Eui = require("tests.support.eui_double")

local function child(root, name) return root:FindFirstChild(name, true) end

local function mount(store, options)
  options = options or {}
  local root = Eui.Node({ Name = "UIRoot" })
  local view = RootView.mount(root, store, {
    modals = { shop = ShopView.modal_spec() },
    docks = { shop = ShopView.bubble_spec({ anchors = options.anchors or {} }) },
    services = {
      next_seq = options.next_seq,
      send_shop = options.send_shop,
      open_modal = options.open_modal,
      close_modal = options.close_modal,
      notify = options.notify,
    },
    create_node = function(kind, props)
      return Eui.Node({
        Kind = kind,
        Name = props and props.Name,
        Parent = props and props.Parent,
        Visible = props and props.Visible ~= false,
        Text = props and (props.Text or props.ButtonText) or "",
        TouchEnabled = kind == "EUIButton",
      })
    end,
  })
  return root, view
end

describe("客户端商店弹窗与场景气泡（#311）", function()
  local old_vector
  before_each(function()
    old_vector = rawget(_G, "Vector3")
    _G.Vector3 = { New = function(x, y, z) return { x = x, y = y, z = z } end }
  end)
  after_each(function() _G.Vector3 = old_vector end)

  it("进入范围建商店气泡，点击开弹窗，切换弹窗和离开范围均对称回收", function()
    local store, writer = ClientStore.new({ initial_now = 1000 })
    local stand = GameCfg.Shop.Stands[1]
    local root = mount(store, {
      anchors = { { stand = stand, name = stand.AnchorName, position = { x = 0, y = 0, z = 0 } } },
      open_modal = function(id, payload) writer:open_modal(id, payload) end,
      close_modal = function(id) writer:close_modal(id) end,
    })
    writer:update_spatial({ x = 100, y = 0, z = 0 }, {})
    assert.is_nil(child(root, "SceneNodeShop_" .. stand.AnchorName))

    writer:update_spatial({ x = 0, y = 0, z = 0 }, {})
    local enter = child(root, "BtnShopEnter_" .. stand.AnchorName)
    assert.is_not_nil(enter)
    assert.is_true(Eui.Click(enter))
    local panel = child(root, "ScreenShop")
    local close = child(root, "BtnShopClose")
    assert.is_not_nil(panel)
    assert.is_not_nil(close)

    writer:open_modal("other", {})
    assert.is_nil(child(root, "ScreenShop"))
    assert.is_true(panel.Destroyed)
    assert.equals(0, close.OnClicked:Count())

    writer:open_modal("shop", { stand = stand, bubbleKey = "shop:" .. stand.AnchorName })
    assert.is_not_nil(child(root, "ScreenShop"))
    writer:update_spatial({ x = 100, y = 0, z = 0 }, {})
    assert.is_nil(child(root, "SceneNodeShop_" .. stand.AnchorName))
    assert.is_nil(child(root, "ScreenShop"))
    assert.is_nil(store.active_modal:now())
    root:Destroy()
  end)

  it("商品行保留货架等级与升级状态，详情购买只发商品编号", function()
    local store, writer = ClientStore.new({ initial_now = 1000 })
    local sent, seq = {}, 40
    local stand = GameCfg.Shop.Stands[1]
    local root = mount(store, {
      send_shop = function(payload) sent[#sent + 1] = payload end,
      next_seq = function() seq = seq + 1 return seq end,
      open_modal = function(id, payload) writer:open_modal(id, payload) end,
      close_modal = function(id) writer:close_modal(id) end,
    })
    writer:set_coin(100)
    writer:open_modal("shop", { stand = stand })
    local goods = GameCfg.Shop.ListForPage(stand.Level, GameCfg.Shop.Pages[1], true)[1]
    local row = child(root, "ShopRow1")
    assert.is_not_nil(row)
    assert.is_true(Eui.Click(row))
    assert.equals(goods.Name, child(root, "LabelShopDetailName").Text)
    assert.is_true(Eui.Click(child(root, "BtnShopBuyDetail")))
    assert.same({ action = "Buy", number = goods.Number, seq = 41 }, sent[#sent])
    assert.is_nil(sent[#sent].price)
    root:Destroy()
    assert.equals(0, row.OnClicked:Count())
  end)

  it("钓鱼佬气泡上行喂食，对话与确认弹窗互斥且按钮监听随切换断开", function()
    local store, writer = ClientStore.new({ initial_now = 1000 })
    local npc = GameCfg.Interact.Fishermen[1]
    local anchor_name = npc.AnchorNames[1]
    local sent, confirmed, seq = {}, nil, 80
    local root = Eui.Node({ Name = "UIRoot" })
    RootView.mount(root, store, {
      modals = {
        fisherman = FishermanView.modal_spec(),
        confirm = FishermanView.confirm_modal_spec(),
      },
      docks = {
        fisherman = FishermanView.bubble_spec({
          anchors = { { npc = npc, name = anchor_name, index = 1, position = { x = 0, y = 0, z = 0 } } },
        }),
      },
      services = {
        next_seq = function() seq = seq + 1 return seq end,
        send_interact = function(payload) sent[#sent + 1] = payload end,
        open_modal = function(id, payload) writer:open_modal(id, payload) end,
        close_modal = function(id) writer:close_modal(id) end,
      },
      create_node = function(kind, props)
        return Eui.Node({
          Kind = kind, Name = props and props.Name, Parent = props and props.Parent,
          Visible = props and props.Visible ~= false,
          Text = props and (props.Text or props.ButtonText) or "",
          TouchEnabled = kind == "EUIButton",
        })
      end,
    })
    writer:update_spatial({ x = 0, y = 0, z = 0 }, {})
    local feed = child(root, "BtnFishermanFeed1_" .. anchor_name)
    local talk = child(root, "BtnFishermanTalk1_" .. anchor_name)
    assert.is_not_nil(feed)
    assert.is_true(Eui.Click(feed))
    assert.same({ target = "fisherman", action = "Feed", seq = 81 }, sent[#sent])
    assert.is_true(Eui.Click(talk))
    local dialog = child(root, "FishermanDialog")
    local dialog_close = child(root, "BtnFishermanClose")
    assert.is_not_nil(dialog)
    writer:open_modal("confirm", {
      Msg = "确认交付信物？",
      CallBack = function(yes) confirmed = yes end,
    })
    assert.is_true(dialog.Destroyed)
    assert.equals(0, dialog_close.OnClicked:Count())
    assert.is_true(Eui.Click(child(root, "BtnYes")))
    assert.is_true(confirmed)
    assert.is_nil(store.active_modal:now())
    writer:update_spatial({ x = 100, y = 0, z = 0 }, {})
    assert.is_nil(child(root, "SceneNodeFisherman_1_" .. anchor_name))
    root:Destroy()
    assert.equals(0, feed.OnClicked:Count())
  end)

  it("抢救气泡按濒死状态与距离建拆，点击只上行目标玩家和操作身份", function()
    local store, writer = ClientStore.new({ initial_now = 1000 })
    local me = { UserId = 1 }
    local target = {
      UserId = 2,
      Character = { Position = { x = 0, y = 0, z = 0 } },
      GetAttribute = function(_, key) return key == "SurvivalPhase" and "downed" or nil end,
    }
    local sent, seq = {}, 90
    local players = { me, target }
    local shared = FishermanView.rescue_state({
      get_players = function() return players end,
      get_local_player = function() return me end,
    })
    local root = Eui.Node({ Name = "UIRoot" })
    RootView.mount(root, store, {
      hud = { FishermanView.rescue_driver_spec(shared) },
      docks = { rescue = FishermanView.rescue_bubble_spec(shared) },
      services = {
        next_seq = function() seq = seq + 1 return seq end,
        send_interact = function(payload) sent[#sent + 1] = payload end,
      },
      create_node = function(kind, props)
        return Eui.Node({
          Kind = kind, Name = props and props.Name, Parent = props and props.Parent,
          Visible = props and props.Visible ~= false,
          Text = props and (props.Text or props.ButtonText) or "",
          TouchEnabled = kind == "EUIButton",
        })
      end,
    })
    writer:update_spatial({ x = 0, y = 0, z = 0 }, {})
    writer:advance_clock(0.1)
    local rescue = child(root, "BtnRescue2")
    assert.is_not_nil(rescue)
    assert.is_true(Eui.Click(rescue))
    assert.same({
      target = GameCfg.Rescue.Target,
      action = GameCfg.Rescue.Action,
      targetUserId = 2,
      seq = 91,
    }, sent[#sent])
    target.GetAttribute = function(_, key) return key == "SurvivalPhase" and "rescuing" or nil end
    writer:advance_clock(0.1)
    assert.is_not_nil(child(root, "BtnRescue2"))
    target.GetAttribute = function(_, key) return key == "SurvivalPhase" and "alive" or nil end
    writer:advance_clock(0.1)
    assert.is_nil(child(root, "BtnRescue2"))
    assert.equals(0, rescue.OnClicked:Count())
    target.GetAttribute = function(_, key) return key == "SurvivalPhase" and "downed" or nil end
    writer:advance_clock(0.1)
    rescue = child(root, "BtnRescue2")
    players = { me }
    writer:advance_clock(0.1)
    assert.is_nil(child(root, "BtnRescue2"))
    assert.equals(0, rescue.OnClicked:Count())
    writer:update_spatial({ x = 100, y = 0, z = 0 }, {})
    writer:advance_clock(0.1)
    root:Destroy()
  end)

  it("抢救 busy 回执给玩家提示", function()
    local store, writer = ClientStore.new({ initial_now = 1000 })
    local notices = {}
    local root = Eui.Node({ Name = "UIRoot" })
    RootView.mount(root, store, {
      hud = { FishermanView.presentation_spec() },
      services = { notify = function(text) notices[#notices + 1] = text end },
      create_node = function(kind, props) return Eui.Node({ Kind = kind, Name = props and props.Name }) end,
    })
    writer:ingest_event("InteractResult", { action = "Rescue", ok = false, reason = "busy" })
    assert.same({ "正在抢救中" }, notices)
    root:Destroy()
  end)

  it("抢救按钮创建失败立即销毁已创建的场景根节点", function()
    local store, writer = ClientStore.new({ initial_now = 1000 })
    local me = { UserId = 1 }
    local target = {
      UserId = 2,
      Character = { Position = { x = 0, y = 0, z = 0 } },
      GetAttribute = function(_, key) return key == "SurvivalPhase" and "downed" or nil end,
    }
    local shared = FishermanView.rescue_state({
      get_players = function() return { me, target } end,
      get_local_player = function() return me end,
    })
    local scene_root
    local root = Eui.Node({ Name = "UIRoot" })
    RootView.mount(root, store, {
      hud = { FishermanView.rescue_driver_spec(shared) },
      docks = { rescue = FishermanView.rescue_bubble_spec(shared) },
      services = {
        create_scene_node = function()
          scene_root = Eui.Node({ Name = "RescueSceneRoot" })
          return scene_root
        end,
      },
      create_node = function(kind, props)
        if kind == "EUIButton" then return nil end
        return Eui.Node({ Kind = kind, Name = props and props.Name })
      end,
    })
    writer:update_spatial({ x = 0, y = 0, z = 0 }, {})
    writer:advance_clock(0.1)
    assert.is_not_nil(scene_root)
    assert.is_true(scene_root.Destroyed)
    root:Destroy()
  end)
end)
