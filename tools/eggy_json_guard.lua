-- 仓库根 eggy.json 守卫（#166）：仓库这份只留 isSEMap（布尔）。
-- 仓库这份唯一的读者是 eggitor SessionStart hook（session_start.mjs 从 cwd 向上找 eggy.json，
-- 只认 "isSEMap": true）；projectID / playerNid / serverPort / mapDir 等是部署端本机信息，
-- 只属于宿主目录那份（code-* 一律 --workspace 指宿主）。纯模块：判定只看传入文本，
-- 读真文件由 tests/native/eggy_json_guard_test.lua 做，随 fast 车道判红。
local M = {}

local ALLOWED_KEYS = { isSEMap = true }
-- 数组与 null 都带元表，借此与对象区分（顶层必须是对象）。
local NULL = setmetatable({}, { __jsonnull = true })

local function prefixed(text)
  return "eggy_json_guard: " .. text
end

-- 最小严格 JSON 解码：够判 eggy.json 的形状即可（对象 / 数组 / 字符串 / 数字 / 字面量）。
-- 字符串只做转义跳过、不还原 \uXXXX——键名比对只需要 ASCII 键原样相等。
local decode_value

local function skip_ws(s, i)
  return s:find("[^ \t\r\n]", i) or #s + 1
end

local function decode_string(s, i)
  local j, parts = i + 1, {}
  while true do
    local c = s:sub(j, j)
    if c == "" then error("unterminated string", 0) end
    if c == '"' then return table.concat(parts), j + 1 end
    if c == "\\" then
      parts[#parts + 1] = s:sub(j, j + 1)
      j = j + 2
    else
      parts[#parts + 1] = c
      j = j + 1
    end
  end
end

local function decode_container(s, i, close, item)
  i = skip_ws(s, i + 1)
  if s:sub(i, i) == close then return i + 1 end
  while true do
    i = skip_ws(s, item(s, i))
    local c = s:sub(i, i)
    if c == close then return i + 1 end
    if c ~= "," then error("expected ',' or '" .. close .. "' at " .. i, 0) end
    i = skip_ws(s, i + 1)
  end
end

function decode_value(s, i)
  i = skip_ws(s, i)
  local c = s:sub(i, i)
  if c == "{" then
    local obj = {}
    local next_i = decode_container(s, i, "}", function(_, k)
      if s:sub(k, k) ~= '"' then error("expected key at " .. k, 0) end
      local key, after = decode_string(s, k)
      after = skip_ws(s, after)
      if s:sub(after, after) ~= ":" then error("expected ':' at " .. after, 0) end
      local value
      value, after = decode_value(s, after + 1)
      obj[key] = value
      return after
    end)
    return obj, next_i
  elseif c == "[" then
    local arr = {}
    local next_i = decode_container(s, i, "]", function(_, k)
      local value, after = decode_value(s, k)
      arr[#arr + 1] = value
      return after
    end)
    return setmetatable(arr, { __jsonarray = true }), next_i
  elseif c == '"' then
    return decode_string(s, i)
  end
  local num = s:match("^-?%d+%.?%d*[eE]?[-+]?%d*", i)
  if num and num ~= "" and num ~= "-" then return tonumber(num), i + #num end
  for literal, value in pairs({ ["true"] = true, ["false"] = false, ["null"] = NULL }) do
    if s:sub(i, i + #literal - 1) == literal then return value, i + #literal end
  end
  error("unexpected character at " .. i, 0)
end

local function decode(text)
  local value, i = decode_value(text, 1)
  if skip_ws(text, i) <= #text then error("trailing content at " .. i, 0) end
  return value
end

-- 返回违规描述列表（空表 = 通过）；多余键按字典序逐个点名。
function M.check(text)
  local ok, decoded = pcall(decode, text)
  if not ok then
    return { prefixed("invalid json: " .. tostring(decoded)) }
  end
  if type(decoded) ~= "table" or getmetatable(decoded) then
    return { prefixed("top level must be a JSON object") }
  end
  local violations, extra = {}, {}
  for key in pairs(decoded) do
    if not ALLOWED_KEYS[key] then extra[#extra + 1] = key end
  end
  table.sort(extra)
  for _, key in ipairs(extra) do
    violations[#violations + 1] = prefixed("disallowed key: " .. key)
  end
  if type(decoded.isSEMap) ~= "boolean" then
    violations[#violations + 1] = prefixed("isSEMap must be a boolean")
  end
  return violations
end

return M
