
local GameCfg = require("common.game_cfg")
local MainHudLayout = require("client.main_hud_layout")
local Tokens = require("client.ui.tokens")
local ClientStore = require("client.store.client_store")
local RootView = require("client.views.root_view")
local AttackView = require("client.views.attack_view")
local Eui = require("tests.support.eui_double")

local function mount(store, sent, notices, opts)
  opts = opts or {}
  local root = Eui.node({ Name = "UIRoot" })
  local view = RootView.mount(root, store, {
    hud = { AttackView.spec() },
    services = {
      send_weapon = function(payload) sent[#sent + 1] = payload end,
      notify = function(text) notices[#notices + 1] = text end,
      aim_direction = opts.aim_direction or function() return { x = 0, y = 0.6, z = 0.8 } end,
      get_device_resolution = opts.get_device_resolution or function() return { x = 1920, y = 1080 } end,
    },
    create_node = function(kind, props)
      local node = Eui.node({
        Kind = kind,
        Name = props and props.Name,
        Parent = props and props.Parent,
        Visible = props and props.Visible,
        Text = props and (props.Text or props.ButtonText) or "",
        Position = props and props.Position,
        Size = props and props.Size,
        TouchEnabled = kind == "EUIButton",
      })
      if opts.with_touch and kind == "EUIButton" then
        node.OnTouchBegan = Eui.Signal()
        node.OnTouchEnded = Eui.Signal()
      end
      return node
    end,
  })
  return root, view
end

local function child(root, name)
  return root:FindFirstChild(name, true)
end

describe("客户端攻击与瞄准投影宿主入口（#300）", function()
  local saved_vector, saved_color

  before_each(function()
    saved_vector = rawget(_G, "Vector2")
    saved_color = rawget(_G, "Color")
    _G.Vector2 = { New = function(x, y) return { x = x, y = y } end }
    _G.Color = { New = function(...) return { ... } end }
  end)

  after_each(function()
    _G.Vector2 = saved_vector
    _G.Color = saved_color
  end)

  it("持武器显示攻击键，点击带相机瞄准上行，失败结果与伤害数字投影后随销毁清掉", function()
    local store, writer = ClientStore.new({ initial_now = 100 })
    local sent, notices = {}, {}
    local root = mount(store, sent, notices)
    writer:ingest_event("ItemBarState", {
      weapons = { item137 = 1 },
      held = { kind = "weapon", id = "item137" },
      slots = {},
    })
    local control = child(root, "AttackControl")
    local button = child(root, "BtnAttack")
    local label = child(root, "AttackLabel")
    local expected_rect = MainHudLayout.compute({ width = 1920, height = 1080 }).rects.attack_control
    assert.is_not_nil(control)
    assert.is_not_nil(button)
    assert.is_not_nil(label)
    assert.equals(root, control.Parent)
    assert.equals(Tokens.Z.HUD_CONTENT, control.LocalZOrder)
    assert.same({ x = expected_rect.x, y = expected_rect.y }, { x = control.Position.x, y = control.Position.y })
    -- 子按钮相对父容器左下角局部居中，绝不与父容器屏幕坐标二次叠加
    assert.same({ x = expected_rect.w / 2, y = expected_rect.h / 2 }, { x = button.Position.x, y = button.Position.y })
    assert.equals("", button.ButtonText)
    assert.is_true(button.Visible)
    assert.equals("射击", label.Text)

    assert.is_true(Eui.click(button))
    assert.same({ action = "attack", aim = { x = 0, y = 0.6, z = 0.8 } }, sent[#sent])

    writer:ingest_event("WeaponResult", { ok = false, action = "attack", reason = "reloading" })
    assert.equals("换弹中", notices[#notices])

    writer:ingest_event("DamageNotice", {
      amount = 12.4,
      category = "weapon",
      targetUserId = 2,
      position = { x = 1, y = 2, z = 3 },
    })
    local floater = child(root, "DamageFloat")
    assert.is_not_nil(floater)
    assert.equals("12", floater.Text)
    assert.equals(Tokens.Z.HUD_ACCENT, floater.LocalZOrder)
    assert.is_false(floater.TouchEnabled)
    assert.is_true(floater.Position.x > 0 and floater.Position.y > 0, "DamageFloat 不得停留在 (0, 0)")

    writer:set_hud_visible(false)
    assert.is_nil(child(root, "BtnAttack"))
    assert.equals(0, button.OnClicked:Count())

    writer:set_hud_visible(true)
    writer:ingest_event("ItemBarState", {
      weapons = { item137 = 1 },
      held = { kind = "weapon", id = "item137" },
      slots = {},
    })
    button = child(root, "BtnAttack")
    assert.is_not_nil(button)
    root:Destroy()
    assert.is_true(button.Destroyed)
    assert.equals(0, button.OnClicked:Count())
    writer:ingest_event("WeaponResult", { ok = false, reason = "cooldown" })
    assert.is_nil(child(root, "BtnAttack"))
  end)

  it("空手不建攻击键，近战文案是攻击", function()
    local store, writer = ClientStore.new({ initial_now = 100 })
    local root = mount(store, {}, {})
    writer:ingest_event("ItemBarState", { weapons = {}, held = {}, slots = {} })
    assert.is_nil(child(root, "BtnAttack"))
    writer:ingest_event("ItemBarState", {
      weapons = { item136 = 1 },
      held = { kind = "weapon", id = "item136" },
      slots = {},
    })
    assert.equals("攻击", child(root, "AttackLabel").Text)
    assert.is_not_nil(GameCfg.Ability.MeleeWeapons.item136)
  end)

  it("长按连发与换弹完全由注入 SpokeClock 短寿命相位驱动，无需引擎 RunService/World", function()
    local store, writer = ClientStore.new({ initial_now = 100 })
    local sent, notices = {}, {}
    local root = mount(store, sent, notices, { with_touch = true })

    writer:ingest_event("ItemBarState", {
      weapons = { item139 = 1 },
      held = { kind = "weapon", id = "item139" },
      slots = {},
    })
    assert.is_true(GameCfg.Ability.Guns.item139.Auto == true)
    local button = child(root, "BtnAttack")
    button.OnTouchBegan:Fire()
    writer:advance_clock(0.05)
    assert.equals(1, #sent)
    assert.equals("attack", sent[1].action)
    writer:advance_clock(GameCfg.Ability.Guns.item139.IntervalSec)
    assert.equals(2, #sent)
    button.OnTouchEnded:Fire()
    writer:advance_clock(1.0)
    assert.equals(2, #sent)

    writer:ingest_event("ItemBarState", {
      weapons = { item137 = 1 },
      held = { kind = "weapon", id = "item137" },
      slots = {},
    })
    button.OnTouchBegan:Fire()
    writer:advance_clock(GameCfg.Ability.Throw.LongPressSec + 0.1)
    button.OnTouchEnded:Fire()
    assert.equals("reload", sent[#sent].action)
    root:Destroy()
  end)
end)
