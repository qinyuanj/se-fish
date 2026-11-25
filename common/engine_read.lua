-- 统一引擎对象读写适配层（L3 支撑层，ADR-0012 / ADR-0033 / ADR-0034）：
-- 所有原语统一返回三元组 `ok, value, reason`：
--   - 成功：`true, value, nil`
--   - 缺失：`false, nil, "missing"`（入参为空/非对象、或目标字段/方法不存在）
--   - 销毁：`false, nil, "destroyed"`（单位已销毁或触发销毁态异常）
--   - 异常：`false, nil, "read_error" | "write_error"`（宿主访问或调用抛错，并带上下文输出日志）

local Number = require("common.number")

local EngineRead = {}

local function parse_context(context)
  if type(context) == "string" then
    return context, nil
  end
  if type(context) == "table" then
    local label = context.context or context.tag or ""
    return type(label) == "string" and label or tostring(label), context.logger
  end
  return "", nil
end

local function log_error(operation, reason, context, err)
  local label, logger = parse_context(context)
  local suffix = label ~= "" and (" context=" .. label) or ""
  local message = string.format(
    "[EngineRead] operation=%s reason=%s%s error=%s",
    tostring(operation),
    tostring(reason),
    suffix,
    tostring(err)
  )
  if logger and type(logger.error) == "function" then
    pcall(logger.error, logger, message)
  else
    print(message)
  end
end

local function is_missing_member_error(err)
  local raw = tostring(err or "")
  local lower = raw:lower()
  return raw:find("没有成员", 1, true) ~= nil
    or lower:find("not a valid member", 1, true) ~= nil
    or lower:find("no member", 1, true) ~= nil
end

local function is_destroyed_error(err)
  if is_missing_member_error(err) then
    return false
  end
  local raw = tostring(err or "")
  local lower = raw:lower()
  return lower:find("destroyed", 1, true) ~= nil or raw:find("已销毁", 1, true) ~= nil
end

--- 判断值是否为可索引的宿主对象（table 或 userdata）。
---@param value any
---@return boolean
function EngineRead.is_object(value)
  local kind = type(value)
  return kind == "table" or kind == "userdata"
end

local function check_destroyed_flag(target)
  if not EngineRead.is_object(target) then
    return false
  end
  local ok, flag = pcall(function()
    return target.Destroyed
  end)
  if ok then
    return flag == true
  end
  return is_destroyed_error(flag)
end

local function read_field_impl(target, field, context, operation)
  if not EngineRead.is_object(target) or type(field) ~= "string" or field == "" then
    return false, nil, "missing"
  end
  local ok, value = pcall(function()
    return target[field]
  end)
  if not ok then
    if check_destroyed_flag(target) or is_destroyed_error(value) then
      return false, nil, "destroyed"
    end
    log_error(operation, "read_error", context, value)
    return false, nil, "read_error"
  end
  if check_destroyed_flag(target) then
    return false, nil, "destroyed"
  end
  if value == nil then
    return false, nil, "missing"
  end
  return true, value, nil
end

local function write_field_impl(target, field, value, context, operation)
  if not EngineRead.is_object(target) or type(field) ~= "string" or field == "" then
    return false, nil, "missing"
  end
  if check_destroyed_flag(target) then
    return false, nil, "destroyed"
  end
  local ok, err = pcall(function()
    target[field] = value
  end)
  if not ok then
    if check_destroyed_flag(target) or is_destroyed_error(err) then
      return false, nil, "destroyed"
    end
    log_error(operation, "write_error", context, err)
    return false, nil, "write_error"
  end
  return true, value, nil
end

local MISSING_SENTINEL = {}

local function invoke_action_impl(target, error_reason, context, operation, fn)
  if not EngineRead.is_object(target) then
    return false, nil, "missing"
  end
  if check_destroyed_flag(target) then
    return false, nil, "destroyed"
  end
  local ok, res = pcall(fn, target)
  if not ok then
    if check_destroyed_flag(target) or is_destroyed_error(res) then
      return false, nil, "destroyed"
    end
    log_error(operation, error_reason, context, res)
    return false, nil, error_reason
  end
  if res == MISSING_SENTINEL then
    return false, nil, "missing"
  end
  return true, res, nil
end

local function invoke_method_impl(target, method_name, error_reason, context, operation, ...)
  if not EngineRead.is_object(target) or type(method_name) ~= "string" or method_name == "" then
    return false, nil, "missing"
  end
  if check_destroyed_flag(target) then
    return false, nil, "destroyed"
  end
  local ok_fn, fn, reason_fn = read_field_impl(target, method_name, context, operation)
  if not ok_fn then
    return false, nil, reason_fn
  end
  if type(fn) ~= "function" then
    return false, nil, "missing"
  end
  local ok, res = pcall(fn, target, ...)
  if not ok then
    if check_destroyed_flag(target) or is_destroyed_error(res) then
      return false, nil, "destroyed"
    end
    log_error(operation, error_reason, context, res)
    return false, nil, error_reason
  end
  return true, res, nil
end

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
  if type(key) ~= "string" or key == "" then
    return false, nil, "missing"
  end
  local ok, val, reason = invoke_method_impl(target, "GetAttribute", "read_error", context, "read_attribute:" .. key, key)
  if not ok then
    return false, nil, reason
  end
  if val == nil then
    return false, nil, "missing"
  end
  return true, val, nil
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
  local ok, service, reason = invoke_method_impl(game, "GetService", "read_error", context, "get_service:" .. name, name)
  if not ok then
    return false, nil, reason
  end
  if service == nil then
    return false, nil, "missing"
  end
  return true, service, nil
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

return EngineRead
