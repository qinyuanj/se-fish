-- common.engine_read 的内部原语层（L3 支撑层，ADR-0012 / ADR-0033 / ADR-0034，拆分见 #414）：
-- 日志与错误分类、宿主对象判定、字段读写与方法/动作调用的 pcall 安全边界。
-- 只被 common.engine_read 依赖并回导出 is_object，不是公开面；调用方仍只用 EngineRead 的公开接口。

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

--- 判断值是否为可索引的宿主对象（table、userdata 或编辑器自定义对象类型）。
---@param value any
---@return boolean
local function is_object(value)
  local kind = type(value)
  if kind == "table" or kind == "userdata" then
    return true
  end
  -- SE 运行时的 type 会直接返回 "Player"、"Players"、"EggyUnit" 等对象名。
  return kind ~= "nil" and kind ~= "boolean" and kind ~= "number" and kind ~= "string"
    and kind ~= "function" and kind ~= "thread"
end

local function check_destroyed_flag(target)
  if not is_object(target) then
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
  if not is_object(target) or type(field) ~= "string" or field == "" then
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
  if not is_object(target) or type(field) ~= "string" or field == "" then
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
  if not is_object(target) then
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
  if not is_object(target) or type(method_name) ~= "string" or method_name == "" then
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

--- 按名称读取成员的公共实现：`GetAttribute` / `GetService` 都是「名称校验 → 调用方法 → nil 视为 missing」。
---@param target any
---@param method_name string
---@param member_name string
---@param context? string|table
---@param operation string 调用点名字，拼进上下文前缀
---@return boolean ok
---@return any value
---@return string|nil reason
local function read_member_impl(target, method_name, member_name, context, operation)
  if type(member_name) ~= "string" or member_name == "" then
    return false, nil, "missing"
  end
  local ok, value, reason = invoke_method_impl(
    target, method_name, "read_error", context, operation .. ":" .. member_name, member_name
  )
  if not ok then
    return false, nil, reason
  end
  if value == nil then
    return false, nil, "missing"
  end
  return true, value, nil
end

-- 内部契约：主文件按名取用，不对外暴露。
return {
  is_object = is_object,
  log_error = log_error,
  is_destroyed_error = is_destroyed_error,
  check_destroyed_flag = check_destroyed_flag,
  read_field_impl = read_field_impl,
  write_field_impl = write_field_impl,
  invoke_action_impl = invoke_action_impl,
  invoke_method_impl = invoke_method_impl,
  read_member_impl = read_member_impl,
  MISSING_SENTINEL = MISSING_SENTINEL,
}
