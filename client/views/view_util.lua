local EngineRead = require("common.engine_read")
local GameCfg = require("common.game_cfg")
local Number = require("common.number")
local Tokens = require("client.ui.tokens")

local ViewUtil = {}

function ViewUtil.is_record(value)
  return EngineRead.is_object(value)
end

function ViewUtil.read_vec2(value)
  local ok, vec = EngineRead.read_vec2(value, "ViewUtil.read_vec2")
  if ok and vec ~= nil then
    return vec.x, vec.y
  end
  return nil
end

function ViewUtil.read_vec3(value)
  local ok, vec = EngineRead.read_vec3(value, "ViewUtil.read_vec3")
  if ok and vec ~= nil then
    return vec.x, vec.y, vec.z
  end
  return nil
end

-- 两个距离平方的公共实现：读取向量 → 任一无效返回 nil → 按维度累加平方差。
local function squared_distance(a, b, with_y)
  local ax, ay, az = ViewUtil.read_vec3(a)
  local bx, by, bz = ViewUtil.read_vec3(b)
  if ax == nil or bx == nil then
    return nil
  end
  local dx, dz = ax - bx, az - bz
  if not with_y then
    return dx * dx + dz * dz
  end
  local dy = ay - by
  return dx * dx + dy * dy + dz * dz
end

function ViewUtil.distance_sq_xz(a, b)
  return squared_distance(a, b, false)
end

function ViewUtil.distance_sq_xyz(a, b)
  return squared_distance(a, b, true)
end

local function valid_resolution(raw)
  local x, y = ViewUtil.read_vec2(raw)
  if x ~= nil and y ~= nil and x > 0 and y > 0 then
    return { x = x, y = y }
  end
  return nil
end

local function try_read_res(label, fn)
  local ok, raw = pcall(fn)
  if ok then return valid_resolution(raw) end
  print("[ViewUtil] 读取分辨率失败", label, tostring(raw))
  return nil
end
function ViewUtil.get_resolution(ctx, options)
  if type(options) == "table" and type(options.get_resolution) == "function" then
    local resolved = try_read_res("options.get_resolution", options.get_resolution)
    if resolved ~= nil then return resolved end
  end

  local services = type(ctx) == "table" and ctx.services or nil
  if type(services) == "table" then
    if type(services.get_device_resolution) == "function" then
      local resolved = try_read_res("services.get_device_resolution", services.get_device_resolution)
      if resolved ~= nil then return resolved end
    end
    local fallback_res = services.resolution
    local resolved = type(fallback_res) == "function" and try_read_res("services.resolution", fallback_res) or valid_resolution(fallback_res)
    if resolved ~= nil then return resolved end
  end

  if game ~= nil then
    local function read_eui_raw()
      local ok_p, players, reason_p = EngineRead.get_service("Players", "ViewUtil.get_resolution")
      if not ok_p then return false, reason_p end
      local ok_lp, lp, reason_lp = EngineRead.read_field(players, "LocalPlayer", "ViewUtil.get_resolution")
      if not ok_lp then return reason_lp == "missing", reason_lp end
      local ok_pg, pg, reason_pg = EngineRead.read_field(lp, "PlayerGui", "ViewUtil.get_resolution")
      if not ok_pg then return reason_pg == "missing", reason_pg end
      local ok_eui, eui_mgr, reason_eui = EngineRead.read_field(pg, "EuiManager", "ViewUtil.get_resolution")
      if not ok_eui then return reason_eui == "missing", reason_eui end
      local ok_raw, raw, reason_raw = EngineRead.call_method(eui_mgr, "GetDeviceResolution", "ViewUtil.get_resolution")
      if not ok_raw then return reason_raw == "missing", reason_raw end
      return true, raw
    end
    local ok, raw_or_reason = read_eui_raw()
    if not ok then
      print("[ViewUtil] 读取宿主 EUI 分辨率失败", tostring(raw_or_reason))
    else
      local resolved = valid_resolution(raw_or_reason)
      if resolved ~= nil then return resolved end
    end
  end
  print("[ViewUtil] 未获取到有效设备分辨率，返回 nil")
  return nil
end

function ViewUtil.wrap_text(text, columns)
  local limit = math.max(1, math.floor(tonumber(columns) or 1))
  local out, count = {}, 0
  for character in tostring(text):gmatch("[%z\1-\127\194-\244][\128-\191]*") do
    if character == "\n" then
      out[#out + 1] = character
      count = 0
    else
      if count >= limit then
        out[#out + 1] = "\n"
        count = 0
      end
      out[#out + 1] = character
      count = count + 1
    end
  end
  return table.concat(out)
end

function ViewUtil.notify(ctx, text)
  if text == nil or text == "" then
    return
  end
  local fn = type(ctx) == "table" and ctx.services and ctx.services.notify or nil
  if type(fn) == "function" then
    fn(text)
  end
end

function ViewUtil.vec2(x, y)
  return Tokens.vec2(x, y)
end

function ViewUtil.color(rgba)
  return Tokens.color(rgba)
end

function ViewUtil.create_anchor_scene_node(scope, ctx, entry, height, kind, fallback_name)
  local services = type(ctx) == "table" and ctx.services or nil
  local create_scene = services and (services.create_anchor_scene_node or services.create_scene_node)
  local node
  if type(create_scene) == "function" then
    node = ctx.own_node(scope, create_scene(entry, height, kind))
  else
    node = ctx.create_node(scope, "EUIImage", {
      Name = fallback_name,
      Visible = true,
    })
  end
  local ok_name, existing_name = EngineRead.read_field(node, "Name", "ViewUtil.create_anchor_scene_node")
  if node ~= nil and (not ok_name or existing_name == nil) then
    EngineRead.write_field(node, "Name", fallback_name, "ViewUtil.create_anchor_scene_node")
  end
  return node
end

function ViewUtil.resolve_clock(ctx, label, override_now)
  if type(override_now) == "function" then
    return override_now
  end
  local services = type(ctx) == "table" and ctx.services or nil
  if type(services) == "table" and type(services.now) == "function" then
    return services.now
  end
  local clock = type(ctx) == "table" and ctx.clock or nil
  if type(clock) == "table" and type(clock.now) == "function" then
    return clock.now
  end
  error("[" .. tostring(label or "ViewUtil") .. "] 缺少注入时钟（services.now 或 ctx.clock.now）", 3)
end

function ViewUtil.read_now(clock_now, label)
  local ok, value = pcall(clock_now)
  if ok and Number.is_finite_number(value) then
    return value
  end
  print("[" .. tostring(label or "ViewUtil") .. "] 读取时钟失败", tostring(value))
  return nil
end

--- 从 ItemBar 状态读道具栏格数。各视图对状态的有效性判定不同，由调用方显式给出：
--- strict_finite = true 只认有限数值（NaN / ±inf 视为缺失），false 只校验 number 类型。
--- 两者缺失都回退配置满格；上下限一律由 MainHudLayout.compute 内的 clampSlots 负责。
---@param item_bar table|nil
---@param strict_finite boolean
---@return number
function ViewUtil.item_bar_slots(item_bar, strict_finite)
  local raw = type(item_bar) == "table" and item_bar.slotCount or nil
  local valid
  if strict_finite then
    valid = Number.is_finite_number(raw)
  else
    valid = type(raw) == "number"
  end
  if not valid then
    return GameCfg.Items.ItemBarSlots
  end
  return raw
end

--- 读取引擎坐标对象（Vector2 及同形 userdata）的 x / y；读取异常或非有限值返回 nil。
--- 与 ViewUtil.read_vec2 的区别：这里返回 { x, y } 记录，便于把坐标整体继续传递。
--- 返回表的 x / y 已通过 Number.is_finite_number 校验，但诊断器无法从 pcall 结果推断，故按 table 标注。
---@param value any
---@return table|nil
function ViewUtil.read_xy(value)
  if type(value) ~= "table" and type(value) ~= "userdata" then
    return nil
  end
  local ok, x, y = pcall(function() return value.x, value.y end) -- 兼容 Vector2 userdata 坐标读取，异常时视为无效
  if ok and Number.is_finite_number(x) and Number.is_finite_number(y) then
    return { x = x, y = y }
  end
  return nil
end

--- 读取触摸事件对象某字段上的坐标；字段缺失或读取异常返回 nil。
---@param touch table|userdata
---@param field string 触摸字段名，如 "BeganPosition" / "EndedPosition"
---@return table|nil
function ViewUtil.read_touch_xy(touch, field)
  if type(touch) ~= "table" and type(touch) ~= "userdata" then
    return nil
  end
  local ok, pos = pcall(function() return touch[field] end) -- 兼容引擎 Touch userdata 字段读取，异常时视为无坐标
  if not ok then
    return nil
  end
  return ViewUtil.read_xy(pos)
end

--- 安全触发客户端 RE：宿主通道未就绪或调用异常时记录并忽略，不打断视图投影。
---@param channel string RE 名字
---@param payload table|nil
---@param log_tag string 日志前缀，如 "[MainHudItemBarView]"
function ViewUtil.fire_re(channel, payload, log_tag)
  local ok, err = pcall(function()
    local re_util = rawget(_G, "REUtil") or require("common.re_util")
    local re = re_util and re_util:get_re(channel) or nil
    if re ~= nil then
      re:FireServer(payload)
    end
  end)
  if not ok then
    print(tostring(log_tag) .. " 发送 " .. tostring(channel) .. " 失败", tostring(err))
  end
end

--- 在父节点下按中心点矩形创建节点：EUIButton 可点，其余类型穿透。
---@param scope table EffectBuilder
---@param ctx table RootView 上下文
---@param kind string 节点类型名（"EUIImage" / "EUIButton" / "EUITextLabel" ...）
---@param parent table|userdata 父节点
---@param name string 节点名
---@param x number 中心 x
---@param y number 中心 y
---@param width number
---@param height number
---@param props table|nil 其余节点属性
---@return table node
function ViewUtil.create_at(scope, ctx, kind, parent, name, x, y, width, height, props)
  props = props or {}
  props.Parent = parent
  props.Name = name
  props.Position = Vector2.New(x, y)
  props.Size = Vector2.New(width, height)
  local node = ctx.create_node(scope, kind, props)
  node.TouchEnabled = kind == "EUIButton"
  node.SwallowTouchEnabled = false
  return node
end

--- 生成 RootView.mount({ hud = { ... } }) 可直接注册的 HUD spec；
--- 各视图只提供名字与 mount，包装样板集中在这里。
---@param name string
---@param mount fun(scope: table, ctx: table, options: table|nil)
---@param options table|nil
---@return table spec { name, mount }
function ViewUtil.hud_spec(name, mount, options)
  return {
    name = name,
    mount = function(scope, ctx)
      mount(scope, ctx, options)
    end,
  }
end

--- 归一化「当前手持武器」：先认 held.kind == "weapon" 且库存 > 0，再退到 selectedWeapon。
--- 战斗视图与装备浮层共用同一判据（原来各写一份）。
---@param state any ItemBar / 装备状态快照
---@return string|nil
function ViewUtil.equipped_weapon(state)
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

--- 回收本轮未出现的 key：排序后逐个 drop，同时摘掉 entries 里的记录。
--- dock 只需提供 drop(key)；装备浮层的 cell dock 与 RootView 的 item dock 共用这一段。
---@param entries table key -> 记录
---@param seen table 本轮出现过的 key 集合
---@param dock table 具备 drop(key) 的 Spoke dock
function ViewUtil.drop_stale_keys(entries, seen, dock)
  local to_drop = {}
  for key in pairs(entries) do
    if not seen[key] then
      to_drop[#to_drop + 1] = key
    end
  end
  table.sort(to_drop)
  for _, key in ipairs(to_drop) do
    entries[key] = nil
    dock:drop(key)
  end
end

--- 回收本轮未出现的格位：按 key 排序后摘记录、摘命中矩形并 drop 节点。
--- 背包与道具栏的格位表只有命中矩形所在字段不同，由调用方传入。
---@param self table 视图句柄（格位记录取自 self.slot_entries）
---@param seen table 本轮出现过的 key 集合
---@param rects table index -> 命中矩形
function ViewUtil.drop_stale_slots(self, seen, rects)
  local to_drop = {}
  for dock_key, entry in pairs(self.slot_entries) do
    if not seen[dock_key] then
      to_drop[#to_drop + 1] = { key = dock_key, index = entry.index }
    end
  end
  table.sort(to_drop, function(a, b) return a.key < b.key end)
  for _, item in ipairs(to_drop) do
    self.slot_entries[item.key] = nil
    rects[item.index] = nil
    self.slot_dock:drop(item.key)
  end
end

--- 命中本视图的格位：矩形按中心点 + 半宽半高判定，返回 { container, index }。
--- 命中矩形的来源各视图不同（背包在 view 上、道具栏在句柄上），由调用方传入。
---@param pos any 触摸坐标
---@param rects table index -> { x, y, hw, hh }
---@param container any 命中后返回的容器 id
---@return table|nil
function ViewUtil.slot_hit(pos, rects, container)
  for index, rect in pairs(rects or {}) do
    if math.abs(pos.x - rect.x) <= rect.hw and math.abs(pos.y - rect.y) <= rect.hh then
      return { container = container, index = index }
    end
  end
  return nil
end

--- 落点归属：先认本视图格位，再交给外部跨容器解析。
---@param self table 视图句柄（self.ctx.store.hud_visible / resolve_own_slot / resolve_drop_target）
---@param pos any
---@return table|nil
function ViewUtil.slot_at_position(self, pos)
  if pos == nil or self.ctx.store.hud_visible:now() == false then
    return nil
  end
  local own = self:resolve_own_slot(pos)
  if own ~= nil then
    return own
  end
  if type(self.resolve_drop_target) == "function" then
    return self.resolve_drop_target(pos)
  end
  return nil
end

--- 把落点解析器交给外部（跨容器拖拽）；卸载时以 nil 收回。
---@param self table 视图句柄（on_drop_resolver / resolve_own_slot_fn）
function ViewUtil.register_drop_resolver(self)
  if type(self.on_drop_resolver) == "function" then
    self.on_drop_resolver(self.resolve_own_slot_fn)
  end
end

--- 浮层活跃判据：主 HUD 可见、浮层信号有值且背包未展开。
---@param ms table memo scope
---@param store table ClientStore
---@param active any 浮层自己的活跃信号（瞄准格 / 展开项）
---@param backpack_open any 背包开关信号
---@return boolean
function ViewUtil.overlay_active(ms, store, active, backpack_open)
  return ms:d(store.hud_visible) ~= false
    and ms:d(active) ~= nil
    and not ms:d(backpack_open)
end

--- 收回交给外部的落点解析器（跨容器拖拽卸载时以 nil 收回）。
---@param self table 视图句柄（on_drop_resolver 可选）
function ViewUtil.revoke_drop_resolver(self)
  if type(self.on_drop_resolver) == "function" then
    self.on_drop_resolver(nil)
  end
end

--- 把行为表并入句柄：行为表与句柄共用同一套 self 约定，方法逐个铺到 target 上。
--- #412 拆分后各视图各写一遍同样的 for pairs 循环，收拢到这一处，不再各写各的。
---@param target table 句柄
---@param source table 行为方法表
function ViewUtil.merge_methods(target, source)
  for name, method in pairs(source) do
    target[name] = method
  end
end

--- 面板句柄装配：补齐 scope/ctx/services，把行为表方法铺到句柄，建节点并接回包投影。
--- 各面板 mount 的骨架原来逐份复制，只有初始字段与投影 effect 名不同。
---@param scope table EffectBuilder
---@param ctx table RootView 上下文
---@param behavior table 行为方法表
---@param fields table 句柄初始业务字段（scope/ctx/services 由这里写入）
---@param effect_spec { name: string, method: string } name 投影 effect 名，method 投影方法名
---@return table handle
function ViewUtil.mount_panel(scope, ctx, behavior, fields, effect_spec)
  local handle = fields
  handle.scope, handle.ctx = scope, ctx
  handle.services = ctx.services or {}
  for name, method in pairs(behavior) do
    handle[name] = method
  end
  handle:create_nodes()
  scope:effect(effect_spec.name, function(es) handle[effect_spec.method](handle, es) end)
  return handle
end

--- 造「写字段再刷新」的选择器方法（图鉴的页签 / 品级等）。
---@param field string 句柄上的字段名
---@return fun(self: table, value: any)
function ViewUtil.refresh_setter(field)
  return function(self, value)
    self[field] = value
    self:refresh()
  end
end

return ViewUtil
