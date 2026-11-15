-- cmd 引用规则（测试侧）：把任意值安全拼进 cmd 命令行。
-- 由 ADR-0017 的测试支撑层重组承接原 sh_quote.lua 的职责：测试要用真实引用规则拼命令，
-- 不冒充 seam。它本身是被测对象，不作为接缝桩——引用规则写错时，这里与 tools/seam.lua
-- 的 quote() 各自对**具体期望字面量**断言，互不比对（两份实现逐字相同，互比会一起错）。
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
