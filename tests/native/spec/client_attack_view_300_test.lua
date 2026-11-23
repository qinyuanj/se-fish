-- #300 客户端攻击与瞄准投影：客户端宿主接缝（ADR-0032 / #292 Testing Decisions）
-- 失败方式先列：
--   1. 持武器且 HUD 可见时不出现攻击键，或空手/关 HUD 仍可点击；
--   2. 点击不上行带相机瞄准的 WeaponAction；长按枪械不上行 reload；
--   3. WeaponResult 失败不投影玩家可读提示；DamageNotice 不投影伤害数字；
--   4. 角色死亡、HUD 关闭或根节点销毁后攻击键、提示与飘字节点及点击连接零残留。
-- 接缝：EUI 测试双、ClientStore 下行、按钮上行、根节点销毁。不窥探私有 Effect 拓扑。

local GameCfg = require("common.GameCfg")
local ClientStore = require("client.Store.ClientStore")
local RootView = require("client.Views.RootView")
local AttackView = require("client.Views.AttackView")
local Eui = require("tests.support.eui_double")

local function mount(store, sent, notices)
  local root = Eui.Node({ Name = "UIRoot" })
  local view = RootView.mount(root, store, {
    hud = { AttackView.spec() },
    services = {
      send_weapon = function(payload) sent[#sent + 1] = payload end,
      notify = function(text) notices[#notices + 1] = text end,
      aim_direction = function() return { x = 0, y = 0.6, z = 0.8 } end,
      now = function() return store.clock.now() end,
      resolution = { x = 1920, y = 1080 },
    },
    create_node = function(kind, props)
      return Eui.Node({
        Kind = kind,
        Name = props and props.Name,
        Parent = props and props.Parent,
        Visible = props and props.Visible,
        Text = props and (props.Text or props.ButtonText) or "",
        Position = props and props.Position,
        Size = props and props.Size,
        TouchEnabled = kind == "EUIButton",
      })
    end,
  })
  return root, view
end

local function child(root, name)
  return root:FindFirstChild(name, true)
end

describe("客户端攻击与瞄准投影宿主接缝（#300）", function()
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
    local button = child(root, "BtnAttack")
    local label = child(root, "AttackLabel")
    assert.is_not_nil(button)
    assert.is_not_nil(label)
    assert.is_true(button.Visible)
    assert.equals("射击", label.Text)

    assert.is_true(Eui.Click(button))
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
end)
