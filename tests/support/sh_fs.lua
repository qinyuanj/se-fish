-- POSIX sh 文件系统夹具助手：需要真实落盘的回归（sync / deploy 传输、worktree-init 等）共用。
-- 断言在 CLI 进程边界上做，夹具只需要最少的读写与存在性判断；路径一律由调用方给出。
local q = require("tests.support.sh_quote").q

local M = {}

function M.slurp(path)
  local f = io.open(path, "rb")
  if not f then return nil end
  local body = f:read("a")
  f:close()
  return body
end

function M.code_of(cmd)
  local _, _, code = os.execute(cmd)
  return code
end

function M.mkdirp(path)
  M.code_of("mkdir -p " .. q(path))
end

function M.rmrf(path)
  M.code_of("rm -rf " .. q(path))
end

function M.exists(path)
  return M.code_of("test -e " .. q(path)) == 0
end

-- 含断开的 symlink：它也占着名字。
function M.lexists(path)
  return M.code_of("test -e " .. q(path) .. " || test -L " .. q(path)) == 0
end

function M.write_file(path, body)
  local dir = path:match("^(.*)/[^/]*$")
  if dir then M.mkdirp(dir) end
  local f = assert(io.open(path, "wb"), path .. " 建不出来")
  f:write(body)
  f:close()
end

return M
