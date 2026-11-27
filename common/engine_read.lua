-- 统一引擎对象读写适配层（L3 支撑层，ADR-0012 / ADR-0033 / ADR-0034）：
-- 所有原语统一返回三元组 `ok, value, reason`：
--   - 成功：`true, value, nil`
--   - 缺失：`false, nil, "missing"`（入参为空/非对象、或目标字段/方法不存在）
--   - 销毁：`false, nil, "destroyed"`（单位已销毁或触发销毁态异常）
--   - 异常：`false, nil, "read_error" | "write_error"`（宿主访问或调用抛错，并带上下文输出日志）

-- 内部原语（日志与错误分类、宿主对象判定、字段与方法安全边界）在 common.engine_read_core（拆分见 #414）。
local Number = require("common.number")
local EngineReadCore = require("common.engine_read_core")

local EngineRead = {}

EngineRead.is_object = EngineReadCore.is_object

local log_error = EngineReadCore.log_error
local is_destroyed_error = EngineReadCore.is_destroyed_error
local check_destroyed_flag = EngineReadCore.check_destroyed_flag
local read_field_impl = EngineReadCore.read_field_impl
local write_field_impl = EngineReadCore.write_field_impl
local invoke_action_impl = EngineReadCore.invoke_action_impl
local invoke_method_impl = EngineReadCore.invoke_method_impl
local read_member_impl = EngineReadCore.read_member_impl
local MISSING_SENTINEL = EngineReadCore.MISSING_SENTINEL

--- 安全判断对象是否已销毁。
---@param target any
---@param context? string|table
---@return boolean ok
---@return boolean|nil destroyed
---@return string|nil reason
function EngineRead.is_destroyed(target, context)
  if not EngineRead.is_object(target) then
    return false, nil, "missing"
  end
  local ok, flag = pcall(function()
    return target.Destroyed
  end)
  if ok then
    return true, flag == true, nil
  end
  if is_destroyed_error(flag) then
    return true, true, nil
  end
  -- 严格测试替身未声明 Destroyed 成员时会报缺成员错，此时视为未销毁；其余异常上报 read_error。
  local err_text = tostring(flag or "")
  if err_text:find("没有成员", 1, true) ~= nil then
    return true, false, nil
  end
  log_error("is_destroyed", "read_error", context, flag)
  return false, nil, "read_error"
end

--- 安全读取宿主对象字段。
---@param target any
---@param field string
---@param context? string|table
---@return boolean ok
---@return any value
---@return string|nil reason
function EngineRead.read_field(target, field, context)
  return read_field_impl(target, field, context, "read_field:" .. tostring(field))
end

--- 安全写入宿主对象字段。
---@param target any
---@param field string
---@param value any
---@param context? string|table
---@return boolean ok
---@return any value
---@return string|nil reason
function EngineRead.write_field(target, field, value, context)
  return write_field_impl(target, field, value, context, "write_field:" .. tostring(field))
end

--- 安全读取玩家 UserId。
---@param player any
---@param context? string|table
---@return boolean ok
---@return any user_id
---@return string|nil reason
function EngineRead.read_user_id(player, context)
  return read_field_impl(player, "UserId", context, "read_user_id")
end

--- 判断对象是否为有效玩家（具备非空 UserId 且未销毁）。
---@param player any
---@param context? string|table
---@return boolean
function EngineRead.is_valid_player(player, context)
  local ok = EngineRead.read_user_id(player, context)
  return ok
end

--- 安全读取玩家 Character 对象。
---@param player any
---@param context? string|table
---@return boolean ok
---@return any character
---@return string|nil reason
function EngineRead.read_character(player, context)
  local ok, character, reason = read_field_impl(player, "Character", context, "read_character")
  if not ok then
    return false, nil, reason
  end
  if not EngineRead.is_object(character) then
    return false, nil, "missing"
  end
  if check_destroyed_flag(character) then
    return false, nil, "destroyed"
  end
  return true, character, nil
end

--- 安全读取玩家角色控制器 Controller。
---@param player any
---@param context? string|table
---@return boolean ok
---@return any controller
---@return string|nil reason
function EngineRead.read_controller(player, context)
  local ok_ch, character, reason_ch = EngineRead.read_character(player, context)
  if not ok_ch then
    return false, nil, reason_ch
  end
  local ok_ctrl, controller, reason_ctrl = read_field_impl(character, "Controller", context, "read_controller")
  if not ok_ctrl then
    return false, nil, reason_ctrl
  end
  if not EngineRead.is_object(controller) then
    return false, nil, "missing"
  end
  if check_destroyed_flag(controller) then
    return false, nil, "destroyed"
  end
  return true, controller, nil
end

--- 安全读取玩家控制器生命值 Health。
---@param player any
---@param context? string|table
---@return boolean ok
---@return number|nil health
---@return string|nil reason
function EngineRead.read_health(player, context)
  local ok_ctrl, controller, reason_ctrl = EngineRead.read_controller(player, context)
  if not ok_ctrl or controller == nil then
    return false, nil, reason_ctrl or "missing"
  end
  local ok_h, health, reason_h = read_field_impl(controller, "Health", context, "read_health")
  if not ok_h then
    return false, nil, reason_h
  end
  if not Number.is_finite_number(health) then
    log_error("read_health", "read_error", context, "non-finite health: " .. tostring(health))
    return false, nil, "read_error"
  end
  return true, health, nil
end

--- 安全写入玩家控制器生命值 Health。
---@param player any
---@param value number
---@param context? string|table
---@return boolean ok
---@return number|nil health
---@return string|nil reason
function EngineRead.write_health(player, value, context)
  if not Number.is_finite_number(value) then
    log_error("write_health", "write_error", context, "non-finite health: " .. tostring(value))
    return false, nil, "write_error"
  end
  local ok_ctrl, controller, reason_ctrl = EngineRead.read_controller(player, context)
  if not ok_ctrl then
    return false, nil, reason_ctrl
  end
  return write_field_impl(controller, "Health", value, context, "write_health")
end

--- 安全读取二维向量，返回 `{ x = x, y = y }`。
---@param value any
---@param context? string|table
---@return boolean ok
---@return { x: number, y: number }|nil vec2
---@return string|nil reason
function EngineRead.read_vec2(value, context)
  if not EngineRead.is_object(value) then
    return false, nil, "missing"
  end
  if check_destroyed_flag(value) then
    return false, nil, "destroyed"
  end
  local ok, x, y = pcall(function()
    return value.x, value.y
  end)
  if not ok then
    if check_destroyed_flag(value) or is_destroyed_error(x) then
      return false, nil, "destroyed"
    end
    log_error("read_vec2", "read_error", context, x)
    return false, nil, "read_error"
  end
  if x == nil or y == nil then
    return false, nil, "missing"
  end
  if not Number.is_finite_number(x) or not Number.is_finite_number(y) then
    log_error("read_vec2", "read_error", context, "non-finite vec2 component")
    return false, nil, "read_error"
  end
  ---@cast x number
  ---@cast y number
  return true, { x = x, y = y }, nil
end

--- 安全读取三维向量，返回 `{ x = x, y = y, z = z }`。
---@param value any
---@param context? string|table
---@return boolean ok
---@return { x: number, y: number, z: number }|nil vec3
---@return string|nil reason
function EngineRead.read_vec3(value, context)
  if not EngineRead.is_object(value) then
    return false, nil, "missing"
  end
  if check_destroyed_flag(value) then
    return false, nil, "destroyed"
  end
  local ok, x, y, z = pcall(function()
    return value.x, value.y, value.z
  end)
  if not ok then
    if check_destroyed_flag(value) or is_destroyed_error(x) then
      return false, nil, "destroyed"
    end
    log_error("read_vec3", "read_error", context, x)
    return false, nil, "read_error"
  end
  if x == nil or y == nil or z == nil then
    return false, nil, "missing"
  end
  if not Number.is_finite_number(x) or not Number.is_finite_number(y) or not Number.is_finite_number(z) then
    log_error("read_vec3", "read_error", context, "non-finite vec3 component")
    return false, nil, "read_error"
  end
  ---@cast x number
  ---@cast y number
  ---@cast z number
  return true, { x = x, y = y, z = z }, nil
end

--- 安全读取单位 Position 并规范化为三维坐标表。
---@param target any
---@param context? string|table
---@return boolean ok
---@return { x: number, y: number, z: number }|nil pos
---@return string|nil reason
function EngineRead.read_position(target, context)
  local ok, pos, reason = read_field_impl(target, "Position", context, "read_position")
  if not ok then
    return false, nil, reason
  end
  return EngineRead.read_vec3(pos, context)
end

--- 安全读取玩家当前角色坐标。
---@param player any
---@param context? string|table
---@return boolean ok
---@return { x: number, y: number, z: number }|nil pos
---@return string|nil reason
function EngineRead.read_player_position(player, context)
  local ok_ch, character, reason_ch = EngineRead.read_character(player, context)
  if not ok_ch then
    return false, nil, reason_ch
  end
  return EngineRead.read_position(character, context)
end

--- 使用引擎 Vector3.New 构造三维向量；缺失或抛错时不退回普通 Lua table。
---@param x number
---@param y number
---@param z number
---@param context? string|table
---@return boolean ok
---@return any vec3
---@return string|nil reason
function EngineRead.new_vector3(x, y, z, context)
  if not Number.is_finite_number(x) or not Number.is_finite_number(y) or not Number.is_finite_number(z) then
    log_error("new_vector3", "write_error", context, "non-finite coordinates")
    return false, nil, "write_error"
  end
  if Vector3 == nil or type(Vector3.New) ~= "function" then
    log_error("new_vector3", "missing", context, "Vector3.New unavailable")
    return false, nil, "missing"
  end
  local ok, vec = pcall(Vector3.New, x, y, z)
  if not ok or vec == nil then
    log_error("new_vector3", "write_error", context, vec)
    return false, nil, "write_error"
  end
  return true, vec, nil
end

--- 安全读取对象属性 `GetAttribute(key)`。
---@param target any
---@param key string
---@param context? string|table
---@return boolean ok
---@return any value
---@return string|nil reason
function EngineRead.read_attribute(target, key, context)
  return read_member_impl(target, "GetAttribute", key, context, "read_attribute")
end

--- 安全写入对象属性 `SetAttribute(key, value)`。
---@param target any
---@param key string
---@param value any
---@param context? string|table
---@return boolean ok
---@return any value
---@return string|nil reason
function EngineRead.write_attribute(target, key, value, context)
  if type(key) ~= "string" or key == "" then
    return false, nil, "missing"
  end
  local ok, _, reason = invoke_method_impl(
    target, "SetAttribute", "write_error", context, "write_attribute:" .. key, key, value
  )
  if not ok then
    return false, nil, reason
  end
  return true, value, nil
end

--- 安全获取 SE 内置服务 `game:GetService(name)`。
---@param name string
---@param context? string|table
---@return boolean ok
---@return any service
---@return string|nil reason
function EngineRead.get_service(name, context)
  if type(name) ~= "string" or name == "" or game == nil then
    return false, nil, "missing"
  end
  return read_member_impl(game, "GetService", name, context, "get_service")
end

--- 读取服务器时刻：host.World 作为可注入的 World 服务缓存（测试与会话注入点），缺省时取引擎服务。
---@param host table 带 World 字段的调用方（World 可注入，缺省取 game:GetService("World")）
---@return number
function EngineRead.server_time(host)
  if host.World == nil then
    host.World = game:GetService("World")
  end
  return host.World:GetServerTime()
end

--- 安全调用宿主对象方法（读取/查询类异常返回 `"read_error"`）。
---@param target any
---@param method_name string
---@param context? string|table
---@param ... any
---@return boolean ok
---@return any result
---@return string|nil reason
function EngineRead.call_method(target, method_name, context, ...)
  return invoke_method_impl(target, method_name, "read_error", context, "call_method:" .. tostring(method_name), ...)
end

--- 安全销毁引擎单位（将 Destroyed 检测与 Destroy 调用统一纳入安全边界）。
---@param unit any
---@param context? string|table
---@return boolean ok
---@return boolean|nil destroyed
---@return string|nil reason
function EngineRead.destroy_unit(unit, context)
  local ok, _, reason = invoke_action_impl(unit, "write_error", context, "destroy_unit", function(u)
    if type(u.Destroy) ~= "function" then
      return MISSING_SENTINEL
    end
    u:Destroy()
    return true
  end)
  if not ok then
    return false, nil, reason
  end
  return true, true, nil
end

--- 安全断开引擎信号连接。
---@param conn any
---@param context? string|table
---@return boolean ok
---@return boolean|nil disconnected
---@return string|nil reason
function EngineRead.disconnect(conn, context)
  local ok, _, reason = invoke_action_impl(conn, "write_error", context, "disconnect", function(c)
    if type(c.Disconnect) ~= "function" then
      return MISSING_SENTINEL
    end
    c:Disconnect()
    return true
  end)
  if not ok then
    return false, nil, reason
  end
  return true, true, nil
end

--- 安全经 REUtil / remote 发送指定玩家下行事件。
---@param remote any
---@param channel string
---@param player any
---@param payload any
---@param context? string|table
---@return boolean ok
---@return boolean|nil sent
---@return string|nil reason
function EngineRead.fire_client(remote, channel, player, payload, context)
  if type(channel) ~= "string" or channel == "" then
    return false, nil, "missing"
  end
  local ok_ev, event, reason_ev = invoke_method_impl(remote, "get_re", "read_error", context, "fire_client.get_re:" .. channel, channel)
  if not ok_ev then
    return false, nil, reason_ev
  end
  if not EngineRead.is_object(event) then
    return false, nil, "missing"
  end
  local ok_send, _, reason_send = invoke_method_impl(
    event, "FireClient", "write_error", context, "fire_client:" .. channel, player, payload
  )
  if not ok_send then
    return false, nil, reason_send
  end
  return true, true, nil
end

--- 经 RE 下发一条客户端消息：失败时按模块标签打印一行溯源日志（模块 + 用户 + 业务字段 + 原因）。
--- 各玩家模块原来各写一份「取事件 → 判失败 → 打印」，这里只收共用部分，频道与标签由 spec 给出。
---@param remote any
---@param player any
---@param payload table|nil
---@param spec { tag: string, channel: string, context?: string, field?: string, verb?: string }
---   tag 日志前缀，channel RE 名，field 打印的载荷字段（缺省 action），verb 失败动作文案（缺省「下发失败」）
---@return boolean ok
---@return string|nil reason
function EngineRead.notify_client(remote, player, payload, spec)
  local ok, _, reason = EngineRead.fire_client(remote, spec.channel, player, payload, spec.context or spec.tag)
  if ok then
    return true
  end
  local detail = type(payload) == "table" and payload[spec.field or "action"] or nil
  print("[" .. tostring(spec.tag) .. "] " .. tostring(spec.channel) .. " " .. (spec.verb or "下发失败"),
    player and player.UserId, detail, tostring(reason))
  return false, reason
end

--- 造「下发后原样返回载荷」的函数：频道与标签固定，烤架/武器等模块的 reply 都只是这个形状。
---@param spec table 见 EngineRead.notify_client
---@return fun(remote: any, player: any, payload: table|nil): table|nil
function EngineRead.client_sender(spec)
  return function(remote, player, payload)
    EngineRead.notify_client(remote, player, payload, spec)
    return payload
  end
end

--- 造玩家行为表的 reply 方法 (self, payload)：先判销毁态再下发，失败打印见 EngineRead.notify_client。
--- 各玩家模块原来各写一份，只有 env 字段、销毁态位置、频道与标签不同。
---@param env_field string 句柄上的环境字段名（如 "blindbox_env"）
---@param spec { tag: string, channel: string, context?: string, field?: string, returns?: "status", disposed_on?: "env" }
---   returns = "status" 时返回 ok, reason；缺省原样返回载荷（渔夫/商店的回包契约）。
---   disposed_on = "env" 时读 env.disposed，否则读 env.lifecycle.disposed。
---@return fun(self: table, payload: table|nil): any
function EngineRead.client_reply(env_field, spec)
  return function(self, payload)
    local env = self[env_field]
    local disposed = spec.disposed_on == "env" and env.disposed or (env.lifecycle and env.lifecycle.disposed)
    if disposed then
      return false, "disposed"
    end
    local ok, reason = EngineRead.notify_client(env.remote, env.player, payload, spec)
    if spec.returns == "status" then
      return ok, reason
    end
    return payload
  end
end

return EngineRead
