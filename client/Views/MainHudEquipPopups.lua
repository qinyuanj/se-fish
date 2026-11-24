-- Spoke 主 HUD 武器栏/鱼饵栏及其展开浮层视图（ADR-0032 / #297-B3a，归属 L2 client.Views）：
-- 挂载于 RootView 常驻 HUD 槽位，订阅只读 ClientStore.item_bar；
-- 武器栏与鱼饵栏常驻底部栏位，展开浮层由 Phase + Dock 管理候选格生命周期；
-- 点击遮罩、切换另一栏、选择候选、打开背包、重连或根 UI 销毁均自动零残留销毁节点与连接。

local spoke = require("common.packages.spoke.api")
local GameCfg = require("common.game_cfg")
local Number = require("common.number")
local MainHudLayout = require("client.MainHudLayout")
local ViewUtil = require("client.Views.ViewUtil")

local Effect = spoke.Effect
local State = spoke.State

local MainHudEquipPopups = {}

local BUTTON_IMAGE = "official://image/11017"
local CELL_FONT = 18

local COLORS = {
  WHITE = { 255, 255, 255, 255 },
  NORMAL = { 54, 100, 140, 255 },
  PRESS = { 42, 82, 118, 255 },
  SELECTED = { 36, 130, 94, 255 },
  DISABLED = { 120, 120, 120, 255 },
  POPUP_PLATE = { 16, 24, 34, 200 },
}

local function make_color(rgba)
  return Color.New(rgba[1], rgba[2], rgba[3], rgba[4])
end

local function make_passive(node)
  node.TouchEnabled = false
  node.SwallowTouchEnabled = false
  return node
end

local function place(node, rect)
  if node == nil or rect == nil then
    return
  end
  node.Position = Vector2.New(rect.x, rect.y)
  node.Size = Vector2.New(rect.w, rect.h)
end

local function cell_text(name, count, width)
  local cols = math.max(1, math.floor(width / CELL_FONT))
  local text = ViewUtil.wrap_text(name, cols)
  return count ~= nil and (text .. "\n×" .. tostring(count)) or text
end

local function item_name(id)
  local def = GameCfg.Items.Definitions[id]
  return def and def.Name or tostring(id)
end

local function bait_stock(state, id)
  local bait = type(state) == "table" and type(state.bait) == "table" and state.bait or nil
  local count = (bait ~= nil and id ~= nil) and bait[id] or nil
  return type(count) == "number" and count or 0
end

local function worm_count(state)
  return bait_stock(state, GameCfg.Items.Id.Worm)
end

local function equipped_weapon(state)
  if type(state) ~= "table" then
    return nil
  end
  local weapons = type(state.weapons) == "table" and state.weapons or {}
  local held = state.held
  if type(held) == "table" and held.kind == "weapon" and (weapons[held.id] or 0) > 0 then
    return held.id
  end
  local selected = state.selectedWeapon
  if selected ~= nil and (weapons[selected] or 0) > 0 then
    return selected
  end
  return nil
end

local function default_fire_item_bar(payload)
  local ok, err = pcall(function() -- 宿主 RE 通道未就绪或调用异常时记录并安全忽略
    local re_util = rawget(_G, "REUtil") or require("common.re_util")
    local re = re_util and re_util:GetRE("ItemBarAction") or nil
    if re ~= nil then
      re:FireServer(payload)
    end
  end)
  if not ok then
    print("[MainHudEquipPopups] 发送 ItemBarAction 失败", tostring(err))
  end
end

local function make_button(ctx, scope, name, x, y, w, h)
  local btn = ctx.create_node(scope, "EUIButton", {
    Name = name,
    Position = Vector2.New(x, y),
    Size = Vector2.New(w, h),
  })
  btn.TouchEnabled = true
  btn.ButtonText = ""
  btn.NormalImage = BUTTON_IMAGE
  btn.PressImage = BUTTON_IMAGE
  btn.DisableImage = BUTTON_IMAGE
  btn.ButtonNormalColor = make_color(COLORS.NORMAL)
  btn.ButtonPressColor = make_color(COLORS.PRESS)
  btn.ButtonDisableColor = make_color(COLORS.DISABLED)
  return btn
end

local function make_label(ctx, scope, name, x, y, w, h, text, font_size, text_color, z_order)
  local label = ctx.create_node(scope, "EUITextLabel", {
    Name = name,
    Position = Vector2.New(x, y),
    Size = Vector2.New(w, h),
    Text = text,
    FontSize = font_size,
    TextColor = text_color,
  })
  label.TextHorizontalAlignment = 1
  label.TextVerticalAlignment = 1
  label.TouchEnabled = false
  label.SwallowTouchEnabled = false
  label.LocalZOrder = z_order or 1
  return label
end

local function build_weapon_candidates(state, send_operate)
  local weapons = type(state) == "table" and type(state.weapons) == "table" and state.weapons or {}
  local ids = {}
  for id, count in pairs(weapons) do
    if type(count) == "number" then
      ids[#ids + 1] = id
    end
  end
  table.sort(ids)
  local equipped = equipped_weapon(state)
  local list = {}
  for _, id in ipairs(ids) do
    local weapon_id = id
    list[#list + 1] = {
      key = weapon_id,
      name = item_name(weapon_id),
      count = weapons[weapon_id],
      enabled = weapons[weapon_id] > 0,
      selected = weapon_id == equipped,
      choose = function()
        send_operate({ op = "attack", weapon = weapon_id })
      end,
    }
  end
  return list
end

local function build_bait_candidates(state, send_action)
  local ids = GameCfg.Items.Id
  local fixed = { ids.Worm, ids.Sausage, ids.Duck }
  local dynamic, is_fixed = {}, {}
  for _, id in ipairs(fixed) do
    is_fixed[id] = true
  end
  local bait_map = type(state) == "table" and type(state.bait) == "table" and state.bait or {}
  for id in pairs(bait_map) do
    if not is_fixed[id] and bait_stock(state, id) > 0 then
      dynamic[#dynamic + 1] = id
    end
  end
  table.sort(dynamic)
  local list = {}
  local function add(id)
    local bait_id = id
    local count = bait_stock(state, bait_id)
    list[#list + 1] = {
      key = bait_id,
      name = item_name(bait_id),
      count = count,
      enabled = count > 0,
      selected = type(state) == "table" and state.selectedBait == bait_id,
      choose = function()
        send_action("SelectBait", bait_id)
      end,
    }
  end
  for _, id in ipairs(fixed) do
    add(id)
  end
  for _, id in ipairs(dynamic) do
    add(id)
  end
  list[#list + 1] = {
    key = "NoBait",
    name = "不挂鱼饵",
    enabled = true,
    selected = type(state) ~= "table" or state.selectedBait == nil,
    choose = function()
      send_action("SelectBait")
    end,
  }
  list[#list + 1] = {
    key = "EatWorm",
    name = "吃蚯蚓",
    enabled = worm_count(state) > 0,
    choose = function()
      send_action("EatBait", ids.Worm)
    end,
  }
  return list
end

local function compute_layout(resolution, state)
  local slot_count = (type(state) == "table" and type(state.slotCount) == "number")
    and state.slotCount or GameCfg.Items.ItemBarSlots
  return MainHudLayout.Compute({
    width = resolution.x,
    height = resolution.y,
    itemBarSlots = slot_count,
  })
end

--- 挂载武器栏、鱼饵栏常驻入口与互斥展开浮层（Phase + Dock）。
---@param s table EffectBuilder
---@param ctx table RootView 上下文 { root_node, store, clock, create_node, own_node, connect }
---@param options table|nil { get_resolution?, send_action?, send_operate?, open_popup?, backpack_open?, layout? }
function MainHudEquipPopups.mount(s, ctx, options)
  options = options or {}
  local resolution = ViewUtil.get_resolution(ctx, options)

  local op_seq = 0
  local send_action = options.send_action or function(action, value)
    default_fire_item_bar({ action = action, value = value })
  end
  local send_operate = options.send_operate or function(payload)
    op_seq = op_seq + 1
    local body = { action = "Operate", seq = op_seq }
    if type(payload) == "table" then
      for k, v in pairs(payload) do
        body[k] = v
      end
    end
    default_fire_item_bar(body)
  end

  local open_popup = options.open_popup or State.new("MainHudEquipPopups.open_popup", nil)
  local external_popup = options.open_popup ~= nil
  local backpack_open = options.backpack_open or State.new("MainHudEquipPopups.backpack_open", false)

  local layout_sig = options.layout or s:memo("EquipPopupsLayout", function(ms)
    return compute_layout(resolution, ms:d(ctx.store.item_bar))
  end)

  if external_popup then
    s:on_cleanup(function()
      open_popup:set(nil)
    end)
  end

  local initial_layout = (options.layout ~= nil and options.layout:now())
    or compute_layout(resolution, ctx.store.item_bar:now())

  -- 1. 武器栏与鱼饵栏常驻入口按钮（按钮不设 Color 且文字置于同级高 ZOrder EUITextLabel）
  local equip_bars = {}
  for _, kind in ipairs({ "Weapon", "Bait" }) do
    local bar_kind = kind
    local r = initial_layout.Rects[bar_kind .. "Bar"]
    local btn = make_button(ctx, s, bar_kind .. "Bar", r.x, r.y, r.w, r.h)
    btn.LocalZOrder = 6
    local label = make_label(
      ctx, s, bar_kind .. "BarLabel", r.x, r.y, r.w, r.h,
      "", CELL_FONT, make_color(COLORS.WHITE), 7
    )
    equip_bars[bar_kind] = { button = btn, label = label }
    ctx.connect(s, btn.OnClicked, function()
      if ctx.store.hud_visible:now() == false or backpack_open:now() then
        return
      end
      local cur = open_popup:now()
      open_popup:set(cur ~= bar_kind and bar_kind or nil)
    end)
  end

  -- 2. 响应式排版、文案与高亮投影（武器栏 / 鱼饵栏，显隐对齐 store.hud_visible）
  s:effect("EquipBarsProjection", function(es)
    local state = es:d(ctx.store.item_bar)
    local hud_visible = es:d(ctx.store.hud_visible) ~= false
    local layout = es:d(layout_sig) or compute_layout(resolution, state)
    local open_kind = es:d(open_popup)
    local bp_open = es:d(backpack_open)
    local show_bars = hud_visible and not bp_open

    local weapon_bar = equip_bars.Weapon
    local bait_bar = equip_bars.Bait
    place(weapon_bar.button, layout.Rects.WeaponBar)
    place(weapon_bar.label, layout.Rects.WeaponBar)
    place(bait_bar.button, layout.Rects.BaitBar)
    place(bait_bar.label, layout.Rects.BaitBar)

    local weapon = equipped_weapon(state)
    weapon_bar.label.Text = weapon and cell_text(item_name(weapon), nil, layout.Rects.WeaponBar.w) or ""
    local bait_id = type(state) == "table" and state.selectedBait or nil
    bait_bar.label.Text = bait_id
      and cell_text(item_name(bait_id), bait_stock(state, bait_id), layout.Rects.BaitBar.w)
      or cell_text("不挂鱼饵", nil, layout.Rects.BaitBar.w)

    for kind, bar in pairs(equip_bars) do
      bar.button.Visible = show_bars
      bar.button.TouchEnabled = show_bars
      bar.label.Visible = show_bars
      bar.button.ButtonNormalColor = make_color(
        (show_bars and open_kind == kind) and COLORS.SELECTED or COLORS.NORMAL
      )
    end
  end)

  -- 3. 武器/鱼饵展开浮层 Phase（仅在主 HUD 可见、浮层打开且背包未打开时挂载，关闭或关屏即零残留销毁）
  local popup_active = s:memo("EquipPopupActive", function(ms)
    return ms:d(ctx.store.hud_visible) ~= false
      and ms:d(open_popup) ~= nil
      and not ms:d(backpack_open)
  end)

  s:phase("EquipPopupPhase", popup_active, function(ps)
    local w, h = resolution.x, resolution.y
    local dismiss = make_button(ctx, ps, "PopupDismiss", w / 2, h / 2, w, h)
    dismiss.NormalImage = ""
    dismiss.PressImage = ""
    dismiss.DisableImage = ""
    dismiss.ButtonNormalColor = Color.New(0, 0, 0, 0)
    dismiss.ButtonPressColor = Color.New(0, 0, 0, 0)
    dismiss.ButtonDisableColor = Color.New(0, 0, 0, 0)
    dismiss.LocalZOrder = 4
    ctx.connect(ps, dismiss.OnClicked, function()
      open_popup:set(nil)
    end)

    local plates = {}
    local cur_layout = layout_sig:now() or compute_layout(resolution, ctx.store.item_bar:now())
    for _, kind in ipairs({ "Weapon", "Bait" }) do
      local r = cur_layout.Rects[kind .. "Bar"]
      local plate = make_passive(ctx.create_node(ps, "EUIImage", {
        Name = kind .. "Popup",
        Position = Vector2.New(r.x, r.y),
        Size = Vector2.New(r.w, r.h),
        Image = BUTTON_IMAGE,
        Color = make_color(COLORS.POPUP_PLATE),
      }))
      plate.LocalZOrder = 5
      plate.Visible = false
      plates[kind] = plate
    end

    local cell_dock = ps:dock("PopupCells")
    local entries = {}
    ps:on_cleanup(function()
      entries = {}
    end)

    ps:effect("PopupCellsSync", function(es)
      local kind = es:d(open_popup)
      local state = es:d(ctx.store.item_bar)
      local layout = es:d(layout_sig) or compute_layout(resolution, state)

      for _, plate in pairs(plates) do
        plate.Visible = false
      end
      if kind == nil then
        return
      end

      local list = {}
      if state ~= nil then
        if kind == "Weapon" then
          list = build_weapon_candidates(state, send_operate)
        elseif kind == "Bait" then
          list = build_bait_candidates(state, send_action)
        end
      end

      local rects = MainHudLayout.PopupCells(layout, kind, #list)
      local seen = {}

      for i, candidate in ipairs(list) do
        local dock_key = kind .. ":" .. tostring(candidate.key)
        seen[dock_key] = true
        local item_data = {
          kind = kind,
          key = candidate.key,
          name = candidate.name,
          count = candidate.count,
          enabled = candidate.enabled,
          selected = candidate.selected,
          choose = candidate.choose,
          rect = rects[i],
        }
        local existing = entries[dock_key]
        if existing ~= nil then
          existing.state:set(item_data)
        else
          local item_state = State.new("PopupCell:" .. dock_key, item_data)
          entries[dock_key] = { state = item_state }
          cell_dock:call(dock_key, Effect.new("PopupCellNode:" .. dock_key, function(cs)
            local init_data = item_state:now()
            local btn = make_button(
              ctx, cs, init_data.kind .. "PopupCell_" .. tostring(init_data.key), 0, 0, 80, 80
            )
            btn.LocalZOrder = 6
            local lbl = make_label(
              ctx, cs, init_data.kind .. "PopupLabel_" .. tostring(init_data.key), 0, 0, 80, 80,
              "", CELL_FONT, make_color(COLORS.WHITE), 7
            )
            ctx.connect(cs, btn.OnClicked, function()
              local latest = item_state:now()
              if open_popup:now() ~= latest.kind or not latest.enabled then
                return
              end
              if type(latest.choose) == "function" then
                latest.choose()
              end
              open_popup:set(nil)
            end)
            cs:effect("PopupCellRender:" .. dock_key, function(rs)
              local data = rs:d(item_state)
              if data.rect ~= nil then
                place(btn, data.rect)
                place(lbl, data.rect)
                lbl.Text = cell_text(data.name, data.count, data.rect.w)
              end
              btn.Visible = true
              btn.TouchEnabled = data.enabled == true
              btn.ButtonNormalColor = make_color(
                not data.enabled and COLORS.DISABLED
                  or data.selected and COLORS.SELECTED
                  or COLORS.NORMAL
              )
              lbl.Visible = true
            end)
          end))
        end
      end

      local to_drop = {}
      for dock_key in pairs(entries) do
        if not seen[dock_key] then
          to_drop[#to_drop + 1] = dock_key
        end
      end
      table.sort(to_drop)
      for _, dock_key in ipairs(to_drop) do
        entries[dock_key] = nil
        cell_dock:drop(dock_key)
      end

      local plate_rect = MainHudLayout.Bounds(rects, 4)
      if plate_rect ~= nil and plates[kind] ~= nil then
        place(plates[kind], plate_rect)
        plates[kind].Visible = true
      end
    end)
  end)
end

--- 返回可供 RootView.mount({ hud = { ... } }) 直接注册的 HUD spec。
function MainHudEquipPopups.spec(options)
  return {
    name = "MainHudEquipPopups",
    mount = function(s, ctx)
      MainHudEquipPopups.mount(s, ctx, options)
    end,
  }
end

return MainHudEquipPopups
