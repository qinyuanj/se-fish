-- cmd 引用规则（测试侧）：把任意值安全拼进 cmd 命令行。
-- 与生产侧 tools/seam.lua 的 quote() 同口径：整段双引号包裹、内部引号双写成 ""、
-- 尾随反斜杠加倍。它是被测对象而非接缝桩——测试用真实规则拼命令，不冒充 seam。
local M = {}

local BACKSLASH = string.char(92)
local DQUOTE = string.char(34)

local function double_trailing_backslashes(s)
  local n = #s
  local i = n
  while i >= 1 and s:sub(i, i) == BACKSLASH do i = i - 1 end
  local trailing = n - i
  if trailing > 0 then return s .. string.rep(BACKSLASH, trailing) end
  return s
end

function M.q(value)
  local s = tostring(value)
  s = s:gsub(DQUOTE, DQUOTE .. DQUOTE)
  s = double_trailing_backslashes(s)
  return DQUOTE .. s .. DQUOTE
end

return M
