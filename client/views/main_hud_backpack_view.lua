-- Spoke 主 HUD 背包入口与背包面板视图（ADR-0032 / #297-B3c，归属 L2 client.views）：
-- 挂载于 root_view 常驻 HUD 槽位，订阅只读 client_store.item_bar；
-- 常驻入口 BtnBackpack 实时显示「背包 n 格」并随道具栏扩容重排；
-- 展开态 BackpackPanel 由 Phase + Dock 管理 BackpackSlot1..n 与转入道具栏按钮生命周期；
-- 通过共享 backpack_open / open_popup 信号与回调协同控制展开遮挡（关闭装备浮层、隐藏底部装备栏与动作键）；
-- 关闭面板、重连或根 UI 销毁均自动零残留销毁节点与信号连接。

local spoke = require("common.packages.spoke.api")
local game_cfg = require("common.game_cfg")
local number = require("common.number")
local main_hud_layout = require("client.main_hud_layout")
local view_util = require("client.views.view_util")

local Effect = spoke.Effect
local State = spoke.State

local main_hud_backpack_view = {}

local BUTTON_IMAGE = "official://image/11017"
local DRAG_THRESHOLD_PX = 10
local SLOT_COLUMNS = 8
local SLOT_STEP_X = 100
local SLOT_STEP_Y = 100
local SLOT_W = 95
local SLOT_H = 90
local SLOT_LABEL_H = 80

local COLORS = {
  WHITE = { 255, 255, 255, 255 },
  NORMAL = { 54, 100, 140, 255 },
  PRESS = { 42, 82, 118, 255 },
  SELECTED = { 36, 130, 94, 255 },
  DISABLED = { 120, 120, 120, 255 },
  SLOT_NORMAL = { 120, 168, 200, 255 },
  SLOT_PRESS = { 96, 142, 174, 255 },
  CLOSE_NORMAL = { 148, 64, 64, 255 },
  CLOSE_PRESS = { 120, 48, 48, 255 },
  PANEL_BG = { 30, 46, 66, 240 },
}

local function make_color(rgba)
  return Color.New(rgba[1], rgba[2], rgba[3], rgba[4])
end

local function make_passive(node)
  node.TouchEnabled = false
  node.SwallowTouchEnabled = false
  return node
end

local function read_xy(pos)
  if type(pos) ~= "table" and type(pos) ~= "userdata" then
    return nil
  end
  local ok, x, y = pcall(function() return pos.x, pos.y end) -- 兼容 Vector2 userdata 坐标读取，异常时视为无效
  if ok and number.IsFiniteNumber(x) and number.IsFiniteNumber(y) then
    return { x = x, y = y }
  end
  return nil
end

local function read_touch_pos(touch, field)
  if type(touch) ~= "table" and type(touch) ~= "userdata" then
    return nil
  end
  local ok, pos = pcall(function() return touch[field] end) -- 兼容引擎 Touch userdata 字段读取，异常时视为无坐标
  if not ok then
    return nil
  end
  return read_xy(pos)
end

local function place(node, rect)
  if node == nil or rect == nil then
    return
  end
  node.Position = Vector2.New(rect.x, rect.y)
  node.Size = Vector2.New(rect.w, rect.h)
end

local function default_fire_item_bar(payload)
  local ok, err = pcall(function() -- 宿主 RE 通道未就绪或调用异常时记录并安全忽略
    local re_util = rawget(_G, "re_util") or require("common.re_util")
    local re = re_util and re_util:GetRE("ItemBarAction") or nil
    if re ~= nil then
      re:FireServer(payload)
    end
  end)
  if not ok then
    print("[main_hud_backpack_view] 发送 ItemBarAction 失败", tostring(err))
  end
end

local function make_button(ctx, scope, name, x, y, w, h, normal_rgba, press_rgba)
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
  btn.ButtonNormalColor = make_color(normal_rgba or COLORS.NORMAL)
  btn.ButtonPressColor = make_color(press_rgba or COLORS.PRESS)
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

local function compute_layout(resolution, state)
  local slot_count = (type(state) == "table" and number.IsFiniteNumber(state.slotCount))
    and state.slotCount or game_cfg.Items.ItemBarSlots
  return main_hud_layout.Compute({
    width = resolution.x,
    height = resolution.y,
    itemBarSlots = slot_count,
  })
end

local function clamp_backpack_count(state)
  if type(state) ~= "table" or not number.IsFiniteNumber(state.backpackCount) then
    return 0
  end
  local n = math.floor(state.backpackCount)
  return math.max(0, math.min(game_cfg.Items.MaxBackpackSlots, n))
end

local function item_display_name(entry)
  if type(entry) ~= "table" or entry.itemId == nil then
    return nil
  end
  local def = game_cfg.Items.Definitions[entry.itemId]
  if def == nil then
    return nil
  end
  local prefix = game_cfg.Items.CookRate(entry) ~= nil and game_cfg.Grill.CookedPrefix or ""
  return prefix .. def.Name
end

local function has_free_item_bar_slot(state)
  if type(state) ~= "table" then
    return false
  end
  local capacity = number.IsFiniteNumber(state.slotCount)
    and math.floor(state.slotCount) or game_cfg.Items.ItemBarSlots
  local slots = type(state.slots) == "table" and state.slots or {}
  for i = 1, capacity do
    if slots[i] == nil then
      return true
    end
  end
  return false
end

local function slot_position(panel_rect, index)
  local col = (index - 1) % SLOT_COLUMNS
  local row = math.floor((index - 1) / SLOT_COLUMNS)
  return panel_rect.x - 350 + col * SLOT_STEP_X, panel_rect.y + 200 - row * SLOT_STEP_Y
end

--- 挂载常驻背包入口按钮与展开态背包面板（Phase + Dock）。
---@param s table EffectBuilder
---@param ctx table root_view 上下文 { root_node, store, clock, create_node, own_node, connect }
---@param options table|nil { get_resolution?, send_action?, backpack_open?, open_popup?, on_open_changed?, resolve_drop_target?, on_drop_resolver?, layout? }
function main_hud_backpack_view.mount(s, ctx, options)
  options = options or {}
  local resolution = view_util.get_resolution(ctx, options)

  local send_action = options.send_action or function(action, value)
    default_fire_item_bar({ action = action, value = value })
  end

  local backpack_open = options.backpack_open or State.new("main_hud_backpack_view.backpack_open", false)
  local external_open = options.backpack_open ~= nil
  local open_popup = options.open_popup
  local on_open_changed = options.on_open_changed
  local resolve_drop_target = options.resolve_drop_target
  local on_drop_resolver = options.on_drop_resolver
  local selected_slot = State.new("main_hud_backpack_view.selected_slot", nil)
  local active_slot_rects = {}

  local layout_sig = options.layout or s:memo("BackpackLayout", function(ms)
    return compute_layout(resolution, ms:d(ctx.store.item_bar))
  end)

  local function resolve_own_slot(pos)
    if pos == nil or ctx.store.hud_visible:now() == false or backpack_open:now() ~= true then
      return nil
    end
    for index, rect in pairs(active_slot_rects) do
      if math.abs(pos.x - rect.x) <= rect.hw and math.abs(pos.y - rect.y) <= rect.hh then
        return { container = game_cfg.Items.ContainerId.Backpack, index = index }
      end
    end
    return nil
  end

  local function slot_at_position(pos)
    if pos == nil or ctx.store.hud_visible:now() == false then
      return nil
    end
    local own = resolve_own_slot(pos)
    if own ~= nil then
      return own
    end
    if type(resolve_drop_target) == "function" then
      return resolve_drop_target(pos)
    end
    return nil
  end

  if type(on_drop_resolver) == "function" then
    on_drop_resolver(resolve_own_slot)
  end

  local function set_backpack_open(flag)
    local next_open = flag == true
    selected_slot:set(nil)
    if next_open and open_popup ~= nil and type(open_popup.set) == "function" then
      open_popup:set(nil)
    end
    backpack_open:set(next_open)
  end

  s:on_cleanup(function()
    if type(on_drop_resolver) == "function" then
      on_drop_resolver(nil)
    end
    active_slot_rects = {}
    if external_open then
      backpack_open:set(false)
    end
  end)

  local initial_layout = (options.layout ~= nil and options.layout:now())
    or compute_layout(resolution, ctx.store.item_bar:now())
  local entry_rect = initial_layout.Rects.BackpackButton

  -- 1. 常驻背包入口按钮（EUIButton 不写 Color，文字置于同级高 ZOrder EUITextLabel）
  local btn_backpack = make_button(
    ctx, s, "BtnBackpack", entry_rect.x, entry_rect.y, entry_rect.w, entry_rect.h
  )
  btn_backpack.LocalZOrder = 6
  local label_backpack = make_label(
    ctx, s, "LabelBackpack", entry_rect.x, entry_rect.y, entry_rect.w, entry_rect.h,
    "背包", 22, make_color(COLORS.WHITE), 7
  )

  ctx.connect(s, btn_backpack.OnClicked, function()
    if ctx.store.hud_visible:now() == false then
      return
    end
    set_backpack_open(not backpack_open:now())
  end)

  -- 2. 常驻入口排版、关屏显隐与容量文案投影
  s:effect("BackpackEntryProjection", function(es)
    local state = es:d(ctx.store.item_bar)
    local hud_visible = es:d(ctx.store.hud_visible) ~= false
    local layout = es:d(layout_sig) or compute_layout(resolution, state)
    local is_open = es:d(backpack_open) == true

    place(btn_backpack, layout.Rects.BackpackButton)
    place(label_backpack, layout.Rects.BackpackButton)
    btn_backpack.Visible = hud_visible
    btn_backpack.TouchEnabled = hud_visible
    label_backpack.Visible = hud_visible
    btn_backpack.ButtonNormalColor = make_color((hud_visible and is_open) and COLORS.SELECTED or COLORS.NORMAL)

    if type(state) == "table" and number.IsFiniteNumber(state.backpackCount) then
      label_backpack.Text = "背包 " .. tostring(math.floor(state.backpackCount)) .. " 格"
    else
      label_backpack.Text = "背包"
    end
  end)

  -- 3. 展开遮挡联动（展开时关闭装备浮层并通知外部遮挡回调）
  s:effect("BackpackOcclusionSync", function(es)
    local is_open = es:d(backpack_open) == true
    if is_open and open_popup ~= nil and type(open_popup.set) == "function" then
      open_popup:set(nil)
    end
    if type(on_open_changed) == "function" then
      on_open_changed(is_open)
    end
  end)

  -- 4. 展开态背包面板 Phase（关闭、关屏、重连或根 UI 销毁即零残留销毁全部节点与连接）
  local panel_active = s:memo("BackpackPanelActive", function(ms)
    return ms:d(ctx.store.hud_visible) ~= false and ms:d(backpack_open) == true
  end)

  s:phase("BackpackPanelPhase", panel_active, function(ps)
    local cur_layout = layout_sig:now() or compute_layout(resolution, ctx.store.item_bar:now())
    local panel_rect = cur_layout.Panels.BackpackPanel
    local cx, cy = panel_rect.x, panel_rect.y

    local panel = make_passive(ctx.create_node(ps, "EUIImage", {
      Name = "BackpackPanel",
      Position = Vector2.New(cx, cy),
      Size = Vector2.New(panel_rect.w, panel_rect.h),
      Image = BUTTON_IMAGE,
      Color = make_color(COLORS.PANEL_BG),
    }))
    panel.LocalZOrder = 10

    local title = make_label(
      ctx, ps, "BackpackTitle", cx, cy + 290, 700, 48,
      "选择背包物品，再转入道具栏", 28, make_color(COLORS.WHITE), 11
    )

    local close_x = cx + panel_rect.w / 2 - 54
    local close_y = cy + panel_rect.h / 2 - 36
    local btn_close = make_button(
      ctx, ps, "BtnBackpackClose", close_x, close_y, 84, 48,
      COLORS.CLOSE_NORMAL, COLORS.CLOSE_PRESS
    )
    btn_close.LocalZOrder = 11
    local label_close = make_label(
      ctx, ps, "LabelBackpackClose", close_x, close_y, 84, 48,
      "关闭", 20, make_color(COLORS.WHITE), 12
    )
    ctx.connect(ps, btn_close.OnClicked, function()
      set_backpack_open(false)
    end)

    local btn_move = make_button(ctx, ps, "BtnMoveToItemBar", cx, cy - 310, 330, 90)
    btn_move.LocalZOrder = 11
    btn_move.Visible = false
    btn_move.TouchEnabled = false
    local label_move = make_label(
      ctx, ps, "LabelMoveToItemBar", cx, cy - 310, 330, 70,
      "转入道具栏", 26, make_color(COLORS.WHITE), 12
    )
    label_move.Visible = false

    ctx.connect(ps, btn_move.OnClicked, function()
      local idx = selected_slot:now()
      local state = ctx.store.item_bar:now()
      if idx == nil or type(state) ~= "table" then
        return
      end
      local entry = type(state.backpack) == "table" and state.backpack[idx] or nil
      if item_display_name(entry) == nil or not has_free_item_bar_slot(state) then
        return
      end
      send_action("MoveToItemBar", idx)
    end)

    local slot_dock = ps:dock("BackpackSlots")
    local slot_entries = {}
    local drag_source = nil
    local drag_handled = nil
    ps:on_cleanup(function()
      slot_entries = {}
      active_slot_rects = {}
      drag_source = nil
      drag_handled = nil
      selected_slot:set(nil)
    end)

    ps:effect("BackpackPanelSync", function(es)
      local state = es:d(ctx.store.item_bar)
      local layout = es:d(layout_sig) or compute_layout(resolution, state)
      local p_rect = layout.Panels.BackpackPanel
      local count = clamp_backpack_count(state)
      local backpack = type(state) == "table" and type(state.backpack) == "table" and state.backpack or {}
      local cur_selected = es:d(selected_slot)

      place(panel, p_rect)
      title.Position = Vector2.New(p_rect.x, p_rect.y + 290)
      local next_close_x = p_rect.x + p_rect.w / 2 - 54
      local next_close_y = p_rect.y + p_rect.h / 2 - 36
      btn_close.Position = Vector2.New(next_close_x, next_close_y)
      label_close.Position = Vector2.New(next_close_x, next_close_y)
      btn_move.Position = Vector2.New(p_rect.x, p_rect.y - 310)
      label_move.Position = Vector2.New(p_rect.x, p_rect.y - 310)

      -- 若当前选中格已越界或变空，自动复位选中状态
      if cur_selected ~= nil then
        local sel_entry = cur_selected <= count and backpack[cur_selected] or nil
        if item_display_name(sel_entry) == nil then
          cur_selected = nil
          selected_slot:set(nil)
        end
      end

      -- 动态格位 BackpackSlot1..n：按索引键增量同步，扩容新增、缩容卸载
      local seen = {}
      for index = 1, count do
        local slot_index = index
        local dock_key = tostring(slot_index)
        seen[dock_key] = true
        local x, y = slot_position(p_rect, slot_index)
        active_slot_rects[slot_index] = { x = x, y = y, hw = SLOT_W / 2, hh = SLOT_H / 2 }
        local display = item_display_name(backpack[slot_index])
        local slot_data = {
          index = slot_index,
          x = x,
          y = y,
          text = display or "空",
          has_item = display ~= nil,
          selected = cur_selected == slot_index,
        }
        local existing = slot_entries[dock_key]
        if existing ~= nil then
          existing.state:set(slot_data)
        else
          local item_state = State.new("BackpackSlotState:" .. dock_key, slot_data)
          slot_entries[dock_key] = { state = item_state, index = slot_index }
          slot_dock:call(dock_key, Effect.new("BackpackSlotNode:" .. dock_key, function(cs)
            local init = item_state:now()
            local btn = make_button(
              ctx, cs, "BackpackSlot" .. tostring(init.index),
              init.x, init.y, SLOT_W, SLOT_H,
              COLORS.SLOT_NORMAL, COLORS.SLOT_PRESS
            )
            btn.LocalZOrder = 11
            local lbl = make_label(
              ctx, cs, "BackpackLabel" .. tostring(init.index),
              init.x, init.y, SLOT_W, SLOT_LABEL_H,
              init.text, 19, make_color(COLORS.WHITE), 12
            )
            if btn.OnTouchBegan ~= nil and btn.OnTouchEnded ~= nil then
              ctx.connect(cs, btn.OnTouchBegan, function(touch)
                if ctx.store.hud_visible:now() == false then
                  return
                end
                local latest = item_state:now()
                if not latest.has_item then
                  return
                end
                drag_source = {
                  container = game_cfg.Items.ContainerId.Backpack,
                  index = latest.index,
                  began = read_touch_pos(touch, "BeganPosition"),
                }
              end)

              ctx.connect(cs, btn.OnTouchEnded, function(touch)
                local source = drag_source
                drag_source = nil
                if ctx.store.hud_visible:now() == false then
                  return
                end
                local latest = item_state:now()
                if source == nil
                  or source.container ~= game_cfg.Items.ContainerId.Backpack
                  or source.index ~= latest.index then
                  return
                end
                local ended = read_touch_pos(touch, "EndedPosition")
                if ended == nil or source.began == nil then
                  return
                end
                if math.abs(ended.x - source.began.x) < DRAG_THRESHOLD_PX
                  and math.abs(ended.y - source.began.y) < DRAG_THRESHOLD_PX then
                  return
                end
                local target = slot_at_position(ended)
                if target ~= nil and (target.container ~= source.container or target.index ~= source.index) then
                  drag_handled = { index = latest.index, valid = true }
                  send_action("MoveSlot", {
                    from = source.container,
                    index = source.index,
                    target = target.container,
                    slot = target.index,
                  })
                end
              end)
            end
            ctx.connect(cs, btn.OnClicked, function()
              local latest = item_state:now()
              if drag_handled ~= nil and drag_handled.index == latest.index and drag_handled.valid then
                drag_handled.valid = false
                return
              end
              if not latest.has_item then
                return
              end
              selected_slot:set(latest.index)
            end)
            cs:effect("BackpackSlotRender:" .. dock_key, function(rs)
              local data = rs:d(item_state)
              btn.Position = Vector2.New(data.x, data.y)
              lbl.Position = Vector2.New(data.x, data.y)
              btn.Visible = true
              btn.TouchEnabled = data.has_item == true
              btn.ButtonNormalColor = make_color(
                data.selected and COLORS.SELECTED or COLORS.SLOT_NORMAL
              )
              lbl.Visible = true
              lbl.Text = data.text
            end)
          end))
        end
      end

      local to_drop = {}
      for dock_key, entry in pairs(slot_entries) do
        if not seen[dock_key] then
          to_drop[#to_drop + 1] = { key = dock_key, index = entry.index }
        end
      end
      table.sort(to_drop, function(a, b) return a.key < b.key end)
      for _, item in ipairs(to_drop) do
        slot_entries[item.key] = nil
        active_slot_rects[item.index] = nil
        slot_dock:drop(item.key)
      end

      -- 转入道具栏按钮显示与满格保护
      local has_selected = cur_selected ~= nil
      btn_move.Visible = has_selected
      label_move.Visible = has_selected
      if not has_selected then
        btn_move.TouchEnabled = false
        label_move.Text = "转入道具栏"
      else
        local free = has_free_item_bar_slot(state)
        btn_move.TouchEnabled = free
        btn_move.ButtonNormalColor = make_color(free and COLORS.NORMAL or COLORS.DISABLED)
        label_move.Text = free and "转入道具栏" or "道具栏已满"
      end
    end)
  end)

  return {
    backpack_open = backpack_open,
    selected_slot = selected_slot,
    resolve_slot_at = resolve_own_slot,
  }
end

--- 返回可供 root_view.mount({ hud = { ... } }) 直接注册的 HUD spec。
function main_hud_backpack_view.spec(options)
  return {
    name = "MainHudBackpack",
    mount = function(s, ctx)
      main_hud_backpack_view.mount(s, ctx, options)
    end,
  }
end

return main_hud_backpack_view
