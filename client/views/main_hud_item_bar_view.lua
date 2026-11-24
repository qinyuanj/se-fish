-- Spoke 主 HUD 底部道具栏视图（ADR-0032 / #297-B3b2，归属 L2 client.views）：
-- 挂载于 RootView 常驻 HUD 槽位，订阅只读 ClientStore.item_bar；
-- 通过 Dock 增量管理 ItemBarSlot1..N（随 slotCount 2..8 扩容重排与缩容卸载）；
-- 支持点击选槽（SelectSlot）、拖拽换格（MoveSlot）、爆炸物点按直投/长按瞄准手势（PressGesture + ThrowAimPhase）；
-- 响应 backpack_open 展开遮挡隐藏，重连或根 UI 销毁自动零残留清理全部节点与连接。

local spoke = require("common.packages.spoke.api")
local GameCfg = require("common.game_cfg")
local Number = require("common.number")
local MainHudLayout = require("client.main_hud_layout")
local PressGesture = require("client.press_gesture")
local ViewUtil = require("client.views.view_util")

local Effect = spoke.Effect
local State = spoke.State

local MainHudItemBarView = {}

local BUTTON_IMAGE = "official://image/11017"
local DRAG_THRESHOLD_PX = 10

local COLORS = {
  WHITE = { 255, 255, 255, 255 },
  AMOUNT = { 255, 220, 40, 255 },
  NORMAL = { 54, 100, 140, 255 },
  PRESS = { 42, 82, 118, 255 },
  SELECTED = { 36, 130, 94, 255 },
  DISABLED = { 120, 120, 120, 255 },
  AIM_NORMAL = { 30, 40, 30, 40 },
  AIM_PRESS = { 30, 40, 30, 60 },
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
  if ok and Number.IsFiniteNumber(x) and Number.IsFiniteNumber(y) then
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

local function default_fire_re(re_name, payload)
  local ok, err = pcall(function() -- 宿主 RE 通道未就绪或调用异常时记录并安全忽略
    local re_util = rawget(_G, "REUtil") or require("common.re_util")
    local re = re_util and re_util:GetRE(re_name) or nil
    if re ~= nil then
      re:FireServer(payload)
    end
  end)
  if not ok then
    print("[MainHudItemBarView] 发送 " .. tostring(re_name) .. " 失败", tostring(err))
  end
end

local function default_resolve_aim_target(pos)
  if pos == nil then
    return nil
  end
  local ok_ray, ray = pcall(function() -- 宿主 CameraService 未就绪或射线转换失败时安全回退无目标直投
    local camera = game ~= nil and game:GetService("CameraService") or nil
    return camera and camera:ScreenPointToRay(pos.x, pos.y, GameCfg.Ability.Throw.Range * 2) or nil
  end)
  if not ok_ray or ray == nil then
    return nil
  end
  local ok_hit, target = pcall(function() -- 宿主 PhysicsService 射线检测失败时安全回退无目标直投
    local origin, direction = ray.Origin, ray.Direction
    if origin == nil or direction == nil then
      return nil
    end
    local physics = game ~= nil and game:GetService("PhysicsService") or nil
    local hit = physics and physics.Raycast and physics:Raycast(origin, direction, nil) or nil
    local p = hit and hit.Position or nil
    if p == nil then
      return nil
    end
    if Number.IsFiniteNumber(p.x) and Number.IsFiniteNumber(p.y) and Number.IsFiniteNumber(p.z) then
      return { x = p.x, y = p.y, z = p.z }
    end
    return nil
  end)
  return ok_hit and target or nil
end

local function clamp_slot_count(state)
  local items = GameCfg.Items
  local raw = (type(state) == "table" and Number.IsFiniteNumber(state.slotCount))
    and math.floor(state.slotCount) or items.InitialItemBarSlots
  return math.max(items.InitialItemBarSlots, math.min(items.ItemBarSlots, raw))
end

local function compute_layout(resolution, state)
  return MainHudLayout.Compute({
    width = resolution.x,
    height = resolution.y,
    itemBarSlots = clamp_slot_count(state),
  })
end

local function item_display_name(entry, def)
  if def == nil then
    return ""
  end
  local prefix = GameCfg.Items.CookRate(entry) ~= nil and GameCfg.Grill.CookedPrefix or ""
  return prefix .. def.Name
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
  label.LocalZOrder = z_order or 8
  return label
end

local function place_slot(nodes, cell)
  local x, y, w, h = cell.x, cell.y, cell.w, cell.h
  nodes.background.Position = Vector2.New(x, y)
  nodes.background.Size = Vector2.New(w, h)
  nodes.icon.Position = Vector2.New(x, y + h * 0.1)
  nodes.icon.Size = Vector2.New(w * 0.6, h * 0.6)
  nodes.label.Position = Vector2.New(x, y - h * 0.34)
  nodes.label.Size = Vector2.New(w, h * 0.28)
  nodes.count.Position = Vector2.New(x + w * 0.33, y + h * 0.33)
  nodes.count.Size = Vector2.New(w * 0.32, h * 0.32)
end

--- 挂载底部道具栏动态格位、拖拽换格与爆炸物长按/点按手势视图。
---@param s table EffectBuilder
---@param ctx table RootView 上下文 { root_node, store, clock, create_node, own_node, connect }
---@param options table|nil { get_resolution?, send_action?, on_throw?, on_aim_begin?, resolve_drop_target?, resolve_aim_target?, notify?, now_sec?, backpack_open?, layout? }
function MainHudItemBarView.mount(s, ctx, options)
  options = options or {}
  local resolution = ViewUtil.get_resolution(ctx, options)

  local send_action = options.send_action or function(action, value)
    default_fire_re("ItemBarAction", { action = action, value = value })
  end

  local weapon_seq = 0
  local on_throw = options.on_throw or function(slot, target)
    weapon_seq = weapon_seq + 1
    local payload = { action = "throw", slot = slot, seq = weapon_seq }
    if type(target) == "table" then
      payload.target = target
    end
    default_fire_re("WeaponAction", payload)
  end

  local on_aim_begin = options.on_aim_begin
  local resolve_drop_target = options.resolve_drop_target
  local on_drop_resolver = options.on_drop_resolver
  local resolve_aim_target = options.resolve_aim_target or default_resolve_aim_target
  local notify = options.notify or function(text) ViewUtil.notify(ctx, text) end

  local function now_sec()
    if type(options.now_sec) == "function" then
      return options.now_sec()
    end
    if ctx.clock ~= nil and type(ctx.clock.now) == "function" then
      return ctx.clock.now()
    end
    local ok, t = pcall(function() -- 宿主 World 时钟未就绪时安全回退 0
      local world = game ~= nil and game:GetService("World") or nil
      return world and world.GetServerTime and world:GetServerTime() or 0
    end)
    return (ok and Number.IsFiniteNumber(t)) and t or 0
  end

  local backpack_open = options.backpack_open or State.new("MainHudItemBarView.backpack_open", false)
  local aim_slot = State.new("MainHudItemBarView.aim_slot", nil)

  local layout_sig = options.layout or s:memo("ItemBarLayout", function(ms)
    return compute_layout(resolution, ms:d(ctx.store.item_bar))
  end)

  local slot_dock = s:dock("ItemBarSlots")
  local slot_entries = {}
  local slot_rects = {}
  local drag_source = nil
  local slot_press = nil
  local throw_handled = nil

  local function resolve_own_slot(pos)
    if pos == nil or ctx.store.hud_visible:now() == false then
      return nil
    end
    for index, rect in pairs(slot_rects) do
      if math.abs(pos.x - rect.x) <= rect.hw and math.abs(pos.y - rect.y) <= rect.hh then
        return { container = GameCfg.Items.ContainerId.ItemBar, index = index }
      end
    end
    return nil
  end

  if type(on_drop_resolver) == "function" then
    on_drop_resolver(resolve_own_slot)
  end

  s:on_cleanup(function()
    if type(on_drop_resolver) == "function" then
      on_drop_resolver(nil)
    end
    slot_entries = {}
    slot_rects = {}
    drag_source = nil
    slot_press = nil
    throw_handled = nil
    aim_slot:set(nil)
  end)

  local function is_explosive_slot(index)
    local state = ctx.store.item_bar:now()
    local slots = type(state) == "table" and type(state.slots) == "table" and state.slots or nil
    local entry = slots and slots[index] or nil
    local def = entry and GameCfg.Items.Definitions[entry.itemId] or nil
    return def ~= nil and def.Type == "爆炸物"
  end

  local function consume_throw_click(index)
    if throw_handled ~= nil and throw_handled.index == index and throw_handled.valid then
      throw_handled.valid = false
      return true
    end
    return false
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

  -- 1. 底部道具栏动态格位同步（扩容增量挂载、缩容自动卸载、关屏隐藏；展开背包时保留可见以支持双向拖拽）
  s:effect("ItemBarSlotsSync", function(es)
    local state = es:d(ctx.store.item_bar)
    local hud_visible = es:d(ctx.store.hud_visible) ~= false
    local layout = es:d(layout_sig) or compute_layout(resolution, state)
    local bp_open = es:d(backpack_open) == true
    local capacity = clamp_slot_count(state)
    local slots = type(state) == "table" and type(state.slots) == "table" and state.slots or {}
    local selected_slot = type(state) == "table" and state.selectedSlot or nil

    if not hud_visible then
      drag_source = nil
      slot_press = nil
      if aim_slot:now() ~= nil then
        aim_slot:set(nil)
      end
    elseif bp_open and aim_slot:now() ~= nil then
      aim_slot:set(nil)
    end

    local seen = {}
    for index = 1, capacity do
      local slot_index = index
      local dock_key = tostring(slot_index)
      seen[dock_key] = true

      local cell = layout.ItemBarSlots[slot_index]
      if cell ~= nil then
        slot_rects[slot_index] = { x = cell.x, y = cell.y, hw = cell.w / 2, hh = cell.h / 2 }
      end

      local entry = slots[slot_index]
      local def = entry ~= nil and GameCfg.Items.Definitions[entry.itemId] or nil
      local slot_data = {
        index = slot_index,
        cell = cell,
        visible = hud_visible,
        selected = selected_slot == slot_index,
        has_item = def ~= nil,
        icon = def ~= nil and def.Icon or nil,
        icon_color = def ~= nil and def.IconColor or nil,
        label = item_display_name(entry, def),
        count_text = def ~= nil and tostring(entry.count) or "",
      }

      local existing = slot_entries[dock_key]
      if existing ~= nil then
        existing.state:set(slot_data)
      else
        local item_state = State.new("ItemBarSlotState:" .. dock_key, slot_data)
        slot_entries[dock_key] = { state = item_state, index = slot_index }
        slot_dock:call(dock_key, Effect.new("ItemBarSlotNode:" .. dock_key, function(cs)
          local init = item_state:now()
          local init_cell = init.cell or { x = 0, y = 0, w = 80, h = 80 }
          local background = make_button(
            ctx, cs, "ItemBarSlot" .. tostring(init.index),
            init_cell.x, init_cell.y, init_cell.w, init_cell.h
          )
          background.LocalZOrder = 6

          local icon = make_passive(ctx.create_node(cs, "EUIImage", {
            Name = "ItemBarIcon" .. tostring(init.index),
            Position = Vector2.New(init_cell.x, init_cell.y),
            Size = Vector2.New(init_cell.w * 0.6, init_cell.h * 0.6),
          }))
          icon.LocalZOrder = 7
          icon.Visible = false

          local label = make_label(
            ctx, cs, "ItemBarLabel" .. tostring(init.index),
            init_cell.x, init_cell.y, init_cell.w, init_cell.h * 0.28,
            "", 18, make_color(COLORS.WHITE), 8
          )
          label.Visible = false

          local count = make_label(
            ctx, cs, "ItemBarAmount" .. tostring(init.index),
            init_cell.x, init_cell.y, init_cell.w * 0.32, init_cell.h * 0.32,
            "", 20, make_color(COLORS.AMOUNT), 8
          )
          count.Visible = false

          local nodes = { background = background, icon = icon, label = label, count = count }

          ctx.connect(cs, background.OnTouchBegan, function(touch)
            if ctx.store.hud_visible:now() == false then
              return
            end
            local began = read_touch_pos(touch, "BeganPosition")
            drag_source = {
              container = GameCfg.Items.ContainerId.ItemBar,
              index = slot_index,
              began = began,
            }
            local gesture = PressGesture.New({
              LongPressSec = GameCfg.Ability.Throw.LongPressSec,
            })
            gesture:Begin(now_sec(), began)
            slot_press = { index = slot_index, gesture = gesture }
          end)

          ctx.connect(cs, background.OnTouchEnded, function(touch)
            local ended = read_touch_pos(touch, "EndedPosition")

            -- 拖拽换格判定（支持道具栏内换格及跨容器拖入背包）
            local source = drag_source
            drag_source = nil
            if ctx.store.hud_visible:now() == false then
              slot_press = nil
              return
            end
            if source ~= nil and source.container == GameCfg.Items.ContainerId.ItemBar
              and source.index == slot_index and ended ~= nil and source.began ~= nil then
              if math.abs(ended.x - source.began.x) >= DRAG_THRESHOLD_PX
                or math.abs(ended.y - source.began.y) >= DRAG_THRESHOLD_PX then
                local target = slot_at_position(ended)
                if target ~= nil and (target.container ~= source.container or target.index ~= source.index) then
                  send_action("MoveSlot", {
                    from = source.container,
                    index = source.index,
                    target = target.container,
                    slot = target.index,
                  })
                end
              end
            end

            -- 爆炸物点按/长按手势判定
            local press = slot_press
            if press == nil or press.index ~= slot_index then
              return
            end
            slot_press = nil
            if not is_explosive_slot(slot_index) then
              return
            end
            local result = press.gesture:End(now_sec(), ended)
            if result == "tap" then
              throw_handled = { index = slot_index, valid = true }
              on_throw(slot_index, nil)
            elseif result == "long" then
              throw_handled = { index = slot_index, valid = true }
              if type(on_aim_begin) == "function" then
                on_aim_begin(slot_index)
              else
                aim_slot:set(slot_index)
              end
            end
          end)

          ctx.connect(cs, background.OnClicked, function()
            if ctx.store.hud_visible:now() == false then
              return
            end
            if consume_throw_click(slot_index) then
              return
            end
            send_action("SelectSlot", slot_index)
          end)

          cs:effect("ItemBarSlotRender:" .. dock_key, function(rs)
            local data = rs:d(item_state)
            if data.cell ~= nil then
              place_slot(nodes, data.cell)
            end
            local show = data.visible == true
            local show_item = show and data.has_item == true
            background.Visible = show
            background.TouchEnabled = show
            background.ButtonNormalColor = make_color(
              data.selected and COLORS.SELECTED or COLORS.NORMAL
            )
            icon.Visible = show_item
            if show_item then
              if data.icon ~= nil then
                icon.Image = data.icon
              end
              if type(data.icon_color) == "table" then
                icon.Color = make_color(data.icon_color)
              end
            end
            label.Text = data.label or ""
            label.Visible = show_item
            count.Text = data.count_text or ""
            count.Visible = show_item
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
      slot_rects[item.index] = nil
      slot_dock:drop(item.key)
    end
  end)

  -- 2. 爆炸物长按瞄准全屏遮罩 Phase（选点投掷、背包展开、关屏、重连或根 UI 销毁即零残留销毁）
  local aim_active = s:memo("ThrowAimActive", function(ms)
    return ms:d(ctx.store.hud_visible) ~= false
      and ms:d(aim_slot) ~= nil
      and not ms:d(backpack_open)
  end)

  s:phase("ThrowAimPhase", aim_active, function(ps)
    local w, h = resolution.x, resolution.y
    local overlay = make_button(
      ctx, ps, "ThrowAimOverlay", w / 2, h / 2, w, h,
      COLORS.AIM_NORMAL, COLORS.AIM_PRESS
    )
    overlay.NormalImage = ""
    overlay.PressImage = ""
    overlay.DisableImage = ""
    overlay.LocalZOrder = 9

    notify("点击屏幕选择投掷落点")

    ctx.connect(ps, overlay.OnTouchEnded, function(touch)
      local slot = aim_slot:now()
      aim_slot:set(nil)
      local ended = read_touch_pos(touch, "EndedPosition")
      if slot == nil or ended == nil then
        return
      end
      local target = resolve_aim_target(ended)
      on_throw(slot, target)
    end)
  end)

  return {
    aim_slot = aim_slot,
    backpack_open = backpack_open,
    resolve_slot_at = resolve_own_slot,
  }
end

--- 返回可供 RootView.mount({ hud = { ... } }) 直接注册的 HUD spec。
function MainHudItemBarView.spec(options)
  return {
    name = "MainHudItemBar",
    mount = function(s, ctx)
      MainHudItemBarView.mount(s, ctx, options)
    end,
  }
end

return MainHudItemBarView
