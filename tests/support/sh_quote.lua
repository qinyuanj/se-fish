-- sh 单引号引用：把任意值安全拼进 POSIX sh 命令行（值里的单引号按 '\'' 拼接）。
-- 开发端只在 WSL（#116），回归里的子进程统一走 POSIX sh；需要起 sh 子进程的测试
-- 一律用本模块，不再各自重抄。tools/win_shell.lua 的 sq 是生产侧同口径实现，
-- 与测试夹具各自独立（生产工具不依赖 tests/）。
local M = {}

function M.q(value)
  return "'" .. tostring(value):gsub("'", "'\\''") .. "'"
end

return M
