-- 子命令共用的退出码约定（#145）：0 成功 / 1 业务失败 / 2 用法错误 / 3 平台或工具不可用。
-- 「平台或工具不可用」在子命令深处用 M.unavailable 抛出，由 main 外层的 M.protect 收成退出码 3；
-- 普通 error（字符串）收成 1。约定的来由见 docs/adr/0011-cli-single-entry-standard-quality-no-acceptance.md。
local M = {
  OK = 0,
  FAILURE = 1,
  USAGE = 2,
  UNAVAILABLE = 3,
}

-- 平台或工具不可用（busted 缺失、editor-cli.exe 或 Blender 找不到、WSL interop 失败）：
-- 抛出带退出码的错误；msg 是完整的 stderr 文本（含子命令前缀）。
function M.unavailable(msg)
  error({ code = M.UNAVAILABLE, msg = msg }, 0)
end

-- 保护模式下跑 fn(...)：M.unavailable 抛出的错误印到 stderr 并返回 3，其余错误印到 stderr 并返回 1；
-- 正常返回时，fn 返回数字即作退出码，否则 0。
function M.protect(fn, ...)
  local ok, result = pcall(fn, ...)
  if not ok then
    if type(result) == "table" and result.code == M.UNAVAILABLE then
      io.stderr:write(tostring(result.msg) .. "\n")
      return M.UNAVAILABLE
    end
    io.stderr:write(tostring(result) .. "\n")
    return M.FAILURE
  end
  if type(result) == "number" then return result end
  return M.OK
end

return M
