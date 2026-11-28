-- UI 契约与几何守卫（静态源码红线 + 多分辨率运行期全态节点树巡检）：
-- 锁定根因修复永不回潮：
--   1. 静态红线：禁全屏 EUIButton 透明收起层、禁空贴图、禁 Color(0,0,0,0)/(0,0,0,1)、
--      禁 EUITextLabel 写 .Color/.FontType、禁非法类名 EUIFrame、禁非空 ButtonText；
--   2. 运行期全态巡检（1920x1080 与 1920x886）：
--      - 预置旧画布（ScreenMain/ScreenShop/DialogNoticeConfirm/ScreenMsg）启动必隐藏且不销毁；
--      - 零未声明全屏暗色遮挡（大面积节点只许 EUILayout 或 14588 且 0 < Opacity <= 0.72）；
--      - 同层可见文本 AABB 零重叠、零越界；
--      - 所有可见文本字号为 4 的倍数、使用圆体、强制 TouchEnabled=false & SwallowTouchEnabled=false；
--      - 所有可见按钮 ButtonText == ""；
--      - 切弹窗与重连 reset_session 后零残留节点。

local fs = require("tests.support.fs_fixture")
local Spoke = require("common.packages.spoke.api")
local ClientStore = require("client.store.client_store")
local RootView = require("client.views.root_view")
local Tokens = require("client.ui.tokens")
local Eui = require("tests.support.eui_double")

local MainHudVitalsView = require("client.views.main_hud_vitals_view")
local MainHudEquipPopups = require("client.views.main_hud_equip_popups")
local MainHudItemBarView = require("client.views.main_hud_item_bar_view")
local MainHudActionButtonsView = require("client.views.main_hud_action_buttons_view")
local MainHudBackpackView = require("client.views.main_hud_backpack_view")
local AttackView = require("client.views.attack_view")
local GuideView = require("client.views.guide_view")
local MessageView = require("client.views.message_view")
local HudMenuView = require("client.views.hud_menu_view")
local SquadView = require("client.views.squad_view")
local GroundLootView = require("client.views.ground_loot_view")
local GrillView = require("client.views.grill_view")
local CompendiumView = require("client.views.compendium_view")
local ShopView = require("client.views.shop_view")
local BlindboxView = require("client.views.blindbox_view")
local PlatformShopView = require("client.views.platform_shop_view")
local LotteryView = require("client.views.lottery_view")
local GMView = require("client.views.gm_view")
local StoryView = require("client.views.story_view")
local FishermanView = require("client.views.fisherman_view")
local SurvivalOverlayView = require("client.views.survival_overlay_view")
local ReelOverlayView = require("client.views.reel_overlay_view")

local function list_lua_files(dir)
  local out = {}
  local lfs = require("lfs")
  for name in lfs.dir(dir) do
    if name:match("%.lua$") then
      out[#out + 1] = dir .. "/" .. name
    end
  end
  table.sort(out)
  return out
end

local function strip_comments(line)
  return (line:gsub("%-%-.*$", ""))
end

local function scan_static_violations(dirs)
  local violations = {}
  for _, dir in ipairs(dirs) do
    for _, path in ipairs(list_lua_files(dir)) do
      local body = assert(fs.slurp(path), "读不到 " .. path)
      local line_no = 0
      for raw in (body .. "\n"):gmatch("(.-)\n") do
        line_no = line_no + 1
        local code = strip_comments(raw)
        if code:find('"EUIFrame"', 1, true) or code:find("'EUIFrame'", 1, true) then
          violations[#violations + 1] = string.format("%s:%d 使用了非法类名 EUIFrame", path, line_no)
        end
        if code:find('NormalImage%s*=%s*""') or code:find('PressImage%s*=%s*""')
            or code:find('DisableImage%s*=%s*""') or code:find('Image%s*=%s*""') then
          violations[#violations + 1] = string.format("%s:%d 写了空贴图路径（会导致白块或黑块）", path, line_no)
        end
        if code:find("Color%.New%s*%(%s*0%s*,%s*0%s*,%s*0%s*,%s*[01]%s*%)")
            or code:find("{%s*0%s*,%s*0%s*,%s*0%s*,%s*[01]%s*}") then
          violations[#violations + 1] = string.format("%s:%d 使用了危险黑底色 (0,0,0,0/1)", path, line_no)
        end
        if code:find("%.FontType%s*=") then
          violations[#violations + 1] = string.format("%s:%d 错写 .FontType（引擎属性应为 .Font）", path, line_no)
        end
        local bt = code:match('ButtonText%s*=%s*"([^"]+)"') or code:match("ButtonText%s*=%s*'([^']+)'")
        if bt ~= nil then
          violations[#violations + 1] = string.format("%s:%d 写了非空 ButtonText=%q（会导致双字重影）", path, line_no, bt)
        end
        if code:find("official://image/11081", 1, true) or code:find("ASSET%.ROUND_RECT") then
          violations[#violations + 1] = string.format("%s:%d 禁止使用素面 11081 圆角矩形，请用蛋仔官方质感框架/按钮/物品格", path, line_no)
        end
      end
    end
  end
  return violations
end

local function make_env(width, height)
  local store, writer = ClientStore.new()
  local root = Eui.node({ Name = "UIRoot", Size = { x = width, y = height } })
  -- 预置旧画布节点（模拟编辑器导出树）
  for _, legacy_name in ipairs(Tokens.LEGACY_PRESET_SCREENS) do
    local legacy = Eui.node({ Name = legacy_name, Parent = root, Visible = true, Size = { x = width, y = height } })
    Eui.node({ Name = legacy_name .. "_LegacyBg", Parent = legacy, Kind = "EUIImage", Visible = true, Size = { x = width, y = height } })
  end

  local backpack_open = Spoke.State.new("Guard.backpack_open", false)
  local open_popup = Spoke.State.new("Guard.open_popup", nil)
  local services = {
    open_modal = function(id, payload) writer:open_modal(id, payload) end,
    close_modal = function(id) writer:close_modal(id) end,
    set_overlay = function(id, active) writer:set_overlay(id, active) end,
    request_compendium = function() end,
    request_records = function() end,
    request_blindbox_state = function() end,
    open_platform_shop = function() writer:open_modal("platform"); return true end,
    send_platform = function() end,
    send_lottery = function() end,
    send_blindbox = function() end,
    send_gm = function() end,
    send_shop = function() end,
    send_story = function() end,
    send_survival = function() end,
    send_reel = function() end,
    send_close = function() end,
    send_grill = function() end,
    send_party = function() end,
    send_interact = function() end,
    send_weapon = function() end,
    notify = function(text) writer:show_notice(text) end,
    get_device_resolution = function() return { x = width, y = height } end,
    grill_shared = GrillView.new_shared(),
  }

  local view = RootView.mount(root, store, {
    create_node = function(kind, props)
      props = props or {}
      local node = Eui.node({
        Kind = kind,
        Name = props.Name,
        Parent = props.Parent,
        Visible = props.Visible,
        Text = props.Text,
        Position = props.Position,
        Size = props.Size,
        Opacity = props.Opacity,
        LocalZOrder = props.LocalZOrder,
        TouchEnabled = props.TouchEnabled ~= nil and props.TouchEnabled or (kind == "EUIButton"),
        SwallowTouchEnabled = props.SwallowTouchEnabled,
      })
      for k, v in pairs(props) do
        if k ~= "Parent" and k ~= "Name" and k ~= "Visible" and k ~= "Position" and k ~= "Size"
            and k ~= "Opacity" and k ~= "LocalZOrder" and k ~= "TouchEnabled" and k ~= "SwallowTouchEnabled" then
          node[k] = v
        end
      end
      return node
    end,
    services = services,
    hud = {
      MainHudVitalsView.spec(),
      MainHudEquipPopups.spec({ open_popup = open_popup, backpack_open = backpack_open, send_operate = function() end }),
      MainHudItemBarView.spec({ backpack_open = backpack_open }),
      MainHudActionButtonsView.spec({ backpack_open = backpack_open, send_operate = function() end }),
      MainHudBackpackView.spec({ backpack_open = backpack_open, open_popup = open_popup }),
      AttackView.spec(),
      GuideView.spec(),
      MessageView.spec(),
      HudMenuView.spec({ debug_enabled = true }),
      SquadView.hud_spec(),
      GroundLootView.aim_toggle_spec(),
      GrillView.spec(),
    },
    modals = {
      compendium = CompendiumView.modal_spec(),
      shop = ShopView.modal_spec(),
      blindbox = BlindboxView.modal_spec(),
      platform = PlatformShopView.modal_spec(),
      lottery = LotteryView.modal_spec(),
      gm = GMView.modal_spec(),
      story = StoryView.modal_spec(),
      fisherman = FishermanView.modal_spec(),
      confirm = FishermanView.confirm_modal_spec(),
    },
    overlays = {
      survival = SurvivalOverlayView.spec(),
      reel = ReelOverlayView.spec(),
      aim_pickup = GroundLootView.aim_spec({ on_pick = function() end }),
    },
  })

  return {
    root = root,
    store = store,
    writer = writer,
    view = view,
    backpack_open = backpack_open,
    open_popup = open_popup,
    width = width,
    height = height,
  }
end

local function collect_visible(root, width, height)
  local list = {}
  local function walk(node, origin_x, origin_y, top_z)
    if node.Destroyed == true or node.Visible == false then
      return
    end
    local pos = node.Position or { x = 0, y = 0 }
    local size = node.Size or { x = 0, y = 0 }
    local cx = origin_x + (pos.x or 0)
    local cy = origin_y + (pos.y or 0)
    local w = size.x or 0
    local h = size.y or 0
    local l, r, b, t = cx - w / 2, cx + w / 2, cy - h / 2, cy + h / 2
    local z = top_z ~= nil and top_z or (node.LocalZOrder or 0)
    list[#list + 1] = {
      node = node,
      l = l, r = r, b = b, t = t, w = w, h = h,
      z = z,
      local_z = node.LocalZOrder or 0,
    }
    for _, ch in pairs(node.children or {}) do
      walk(ch, l, b, z)
    end
  end
  for _, ch in pairs(root.children or {}) do
    walk(ch, 0, 0, nil)
  end
  return list
end

local function rects_overlap(a, b)
  return a.l < b.r - 0.5 and a.r > b.l + 0.5 and a.b < b.t - 0.5 and a.t > b.b + 0.5
end

local function is_valid_yuanti(font)
  if font == nil then
    return false
  end
  local s = tostring(font)
  return s:find("YUANTI_BOLD", 1, true) ~= nil
    or s:find("YUANTI_REGULAR", 1, true) ~= nil
    or s:find("YuanTi", 1, true) ~= nil
end

local function audit_state(env, label)
  local items = collect_visible(env.root, env.width, env.height)
  local screen_area = env.width * env.height
  local blockers = {}
  local labels = {}

  for _, it in ipairs(items) do
    local n = it.node
    assert.is_true(it.w > 0 and it.h > 0, string.format("[%s] 节点 %s 尺寸非正 (%.1fx%.1f)", label, tostring(n.Name), it.w, it.h))
    -- 零未声明全屏暗色遮挡
    if (it.w * it.h) >= screen_area * 0.85 then
      if n.Kind == "EUILayout" then
        -- 合法透明纯容器捕获层
      elseif n.Kind == "EUIImage" then
        assert.equals(Tokens.ASSET.MODAL_MASK, n.Image,
          string.format("[%s] 全屏图片节点 %s 必须使用 14588 遮罩贴图", label, tostring(n.Name)))
        local op = n.Opacity
        assert.is_true(type(op) == "number" and op > 0 and op <= 0.72,
          string.format("[%s] 全屏遮罩 %s 的 Opacity=%s 不在 (0, 0.72]", label, tostring(n.Name), tostring(op)))
        blockers[#blockers + 1] = it
      else
        error(string.format("[%s] 禁止非 EUILayout/14588 全屏节点 %s (Kind=%s)", label, tostring(n.Name), tostring(n.Kind)))
      end
    else
      -- 非全屏节点不越界（允许 2px 舍入误差）
      assert.is_true(it.l >= -2 and it.r <= env.width + 2 and it.b >= -2 and it.t <= env.height + 2,
        string.format("[%s] 节点 %s 越界 (%.1f..%.1f, %.1f..%.1f) vs %dx%d",
          label, tostring(n.Name), it.l, it.r, it.b, it.t, env.width, env.height))
      if n.Kind == "EUIImage" and (n.TouchEnabled == true or (tonumber(n.Opacity) or 1) >= 0.85) then
        blockers[#blockers + 1] = it
      end
    end

    if n.Kind == "EUIButton" then
      assert.is_true(n.ButtonText == nil or n.ButtonText == "",
        string.format("[%s] 按钮 %s 违规写入 ButtonText=%q", label, tostring(n.Name), tostring(n.ButtonText)))
    elseif n.Kind == "EUITextLabel" then
      assert.is_false(n.TouchEnabled == true,
        string.format("[%s] 文本 %s 必须 TouchEnabled=false", label, tostring(n.Name)))
      assert.is_false(n.SwallowTouchEnabled == true,
        string.format("[%s] 文本 %s 必须 SwallowTouchEnabled=false", label, tostring(n.Name)))
      local fs_val = tonumber(n.FontSize) or 0
      assert.is_true(fs_val >= 16 and fs_val % 4 == 0,
        string.format("[%s] 文本 %s FontSize=%s 不符合 4px 栅格（>=16）", label, tostring(n.Name), tostring(n.FontSize)))
      assert.is_true(is_valid_yuanti(n.Font),
        string.format("[%s] 文本 %s 未使用内置圆体 Font=%s", label, tostring(n.Name), tostring(n.Font)))
      if type(n.Text) == "string" and n.Text ~= "" then
        labels[#labels + 1] = it
      end
    end
  end

  -- 过滤被更高层级不透明面板/全屏模态遮罩覆盖的底层文本，只校验同一可见层的文本零重叠
  local active_labels = {}
  for _, lbl in ipairs(labels) do
    local occluded = false
    for _, blk in ipairs(blockers) do
      if blk.z > lbl.z and rects_overlap(lbl, blk) then
        occluded = true
        break
      end
    end
    if not occluded then
      active_labels[#active_labels + 1] = lbl
    end
  end

  for i = 1, #active_labels do
    for j = i + 1, #active_labels do
      local a, b = active_labels[i], active_labels[j]
      if rects_overlap(a, b) then
        error(string.format(
          "[%s] 可见文本 AABB 重叠: %s(%q %.0f..%.0f,%.0f..%.0f z=%d) 与 %s(%q %.0f..%.0f,%.0f..%.0f z=%d)",
          label,
          tostring(a.node.Name), tostring(a.node.Text), a.l, a.r, a.b, a.t, a.z,
          tostring(b.node.Name), tostring(b.node.Text), b.l, b.r, b.b, b.t, b.z))
      end
    end
  end
end

describe("UI 契约与全态几何守卫", function()
  local oldVector, oldColor, oldVector4

  before_each(function()
    oldVector = rawget(_G, "Vector2")
    oldColor = rawget(_G, "Color")
    oldVector4 = rawget(_G, "Vector4")
    _G.Vector2 = { New = function(x, y) return { x = x, y = y } end }
    _G.Color = { New = function(r, g, b, a) return { r = r, g = g, b = b, a = a } end }
    _G.Vector4 = { New = function(l, t, r, b) return { x = l, y = t, z = r, w = b } end }
  end)

  after_each(function()
    _G.Vector2 = oldVector
    _G.Color = oldColor
    _G.Vector4 = oldVector4
  end)

  it("静态源码红线：全仓 client/ui 与 client/views 无黑屏/双字/非法属性写法", function()
    local violations = scan_static_violations({ "client/ui", "client/views" })
    assert.same({}, violations)
  end)

  it("预置旧画布在 RootView 启动时必须隐藏且不销毁", function()
    local env = make_env(1920, 1080)
    for _, legacy_name in ipairs(Tokens.LEGACY_PRESET_SCREENS) do
      local node = env.root:FindFirstChild(legacy_name, false)
      assert.is_not_nil(node, "缺少预置画布 " .. legacy_name)
      assert.is_false(node.Visible, "预置画布未隐藏 " .. legacy_name)
      assert.is_not_true(node.Destroyed, "不应销毁预置画布 " .. legacy_name)
    end
    env.view:dispose()
  end)

  for _, res in ipairs({ { 1920, 1080 }, { 1920, 886 } }) do
    local tag = res[1] .. "x" .. res[2]
    it("运行期全态巡检 @" .. tag .. "：零黑屏、零文字重叠、4px 圆体与触控安全", function()
      local env = make_env(res[1], res[2])
      local w = env.writer

      -- 准备真实业务数据
      w:update_vitals({ health = 80, maxHealth = 100, hunger = 65, maxHunger = 100 })
      w:set_coin(1280)
      w:ingest_event("QuestState", { title = "初次下竿", desc = "去浅水区钓一条小鱼", progress = "0/1" })
      w:ingest_event("ItemBarState", {
        slotCount = 4,
        slots = { { id = "rod_wood", count = 1 }, { id = "fish_crucian", count = 2 } },
        weapons = { rod_wood = 1, spear_iron = 1 },
        selectedWeapon = "rod_wood",
        baits = { earthworm = 5 },
        held = { kind = "weapon", id = "rod_wood" },
        backpack = { { id = "fish_crucian", count = 3 } },
      })
      w:show_notice("欢迎来到危险垂钓岛")

      audit_state(env, tag .. ":MainHUD")

      -- 展开菜单
      local menu_btn = env.root:FindFirstChild("BtnMenuEntry", true)
      assert.is_not_nil(menu_btn)
      Eui.click(menu_btn)
      audit_state(env, tag .. ":MenuOpen")
      local menu_dismiss = env.root:FindFirstChild("HudMenuDismiss", true)
      assert.is_not_nil(menu_dismiss)
      assert.equals("EUILayout", menu_dismiss.Kind)
      Eui.click(menu_dismiss)

      -- 展开武器浮层（核心黑屏回归）
      env.open_popup:set("weapon")
      w:step_clock(0.05)
      local popup_dismiss = env.root:FindFirstChild("PopupDismiss", true)
      assert.is_not_nil(popup_dismiss)
      assert.equals("EUILayout", popup_dismiss.Kind)
      audit_state(env, tag .. ":WeaponPopup")
      Eui.click(popup_dismiss)
      assert.is_nil(env.open_popup:now())

      -- 展开背包
      env.backpack_open:set(true)
      audit_state(env, tag .. ":Backpack")
      env.backpack_open:set(false)

      -- 逐一打开全部互斥弹窗并验证零残留切换
      local modal_cases = {
        { id = "compendium", setup = function() w:ingest_event("CompendiumState", { unlocked = {}, total = 10 }) end },
        { id = "shop", setup = function() w:ingest_event("ShopState", { standId = "stand_1", tab = "sell", items = {} }) end },
        { id = "blindbox", setup = function() w:ingest_event("BlindboxState", { pity = 2, freeDraw = false }) end },
        { id = "platform", setup = function() end },
        { id = "lottery", setup = function() end },
        { id = "gm", setup = function() end },
        { id = "story", setup = function() w:ingest_event("StoryState", { lines = { "欢迎来到钓鱼岛！" } }) end },
        { id = "fisherman", setup = function() w:ingest_event("FishermanState", { npcId = "old_man", lines = { "今天鱼情不错。" } }) end },
        { id = "confirm", payload = { text = "确定花费 100 鱼币？", onConfirm = function() end } },
      }
      for _, mc in ipairs(modal_cases) do
        if mc.setup then mc.setup() end
        w:open_modal(mc.id, mc.payload)
        w:ingest_event("DamageNotice", { amount = 12, critical = false })
        audit_state(env, tag .. ":Modal:" .. mc.id)
      end
      w:close_modal()

      -- 覆盖蒙版：虚弱、倒地/死亡、收线、瞄准拾取
      w:ingest_event("SurvivalState", { state = "weak", hp = 20, maxHp = 100 })
      w:set_overlay("survival", true)
      audit_state(env, tag .. ":SurvivalWeak")
      w:ingest_event("SurvivalState", { state = "downed", countdown = 15, canRevive = true })
      audit_state(env, tag .. ":SurvivalDowned")
      w:set_overlay("survival", false)

      w:ingest_event("ReelState", { active = true, sessionId = 1, progress = 45, fishName = "巨型电鳗" })
      w:set_overlay("reel", true)
      audit_state(env, tag .. ":ReelOverlay")
      w:set_overlay("reel", false)

      w:set_overlay("aim_pickup", true)
      audit_state(env, tag .. ":AimPickup")
      w:set_overlay("aim_pickup", false)

      -- 重连 reset_session 零残留
      w:open_modal("compendium")
      local comp_panel = env.root:FindFirstChild("ScreenCompendium", true)
      assert.is_not_nil(comp_panel)
      w:reset_session()
      assert.is_true(comp_panel.Destroyed == true, "reset_session 后旧弹窗应被销毁")

      env.view:dispose()
    end)
  end
end)
