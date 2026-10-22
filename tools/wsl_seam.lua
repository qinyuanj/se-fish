-- Windows 原生执行层：工具链里唯一直接起 cmd / robocopy 的地方。
-- 先例：se-defense tools/wsl_seam.lua 的 WSL 接缝层——本工程在 Windows 原生跑，
-- 目的地一律在本机，「跨接缝」不存在（判定恒真），robocopy 之外也没有本地 cp 回落分支。
--
-- 路径统一按逻辑形式（/ 分隔）收进来，出到命令行前换成 Windows 形式（\ 分隔）；
-- 本模块假定进程 cwd 是仓库根（与 tools/cli.lua 的约定一致），临时输出落 tmp/。
-- tmp/ 是 gitignored 的：全新 clone、git worktree 的树里都没有，而 cmd 打不开重定向落点就会
-- 直接报错、被重定向的那条命令根本不执行（robocopy 那侧还会因此拿到退出码 1）。所以「重定向
-- 落点目录存在」的责任收在 run_redirected 一处，不靠谁顺手先建过。
local M = {}

local SEP = "\\"
local OUT_FILE = "tmp" .. SEP .. "cmd.out"
local LOG_FILE = "tmp" .. SEP .. "robocopy.log"

-- 逻辑路径 → Windows 路径。
function M.win(path)
  return (path:gsub("/", SEP))
end

-- 命令行参数引用：路径里只有仓库内固定字符，但统一加引号防呆。
function M.q(path)
  return '"' .. M.win(path) .. '"'
end

-- 跑一条 cmd 命令行，返回退出码。
local function run(cmd)
  local _, _, code = os.execute(cmd)
  return code
end

local function read_file(path)
  local f = io.open(path, "rb")
  if not f then return "" end
  local body = f:read("a") or ""
  f:close()
  return body
end

-- 跑一条输出重定向到 out_file 的命令，返回退出码。两件事收在这里：
--   * 重定向落点目录先建出来（落点文件所在目录不存在时 cmd 报「找不到路径」、命令不执行）；
--   * 重定向必须写在命令前面：命令行以引号开头（引号包住的 exe 后面还有引号包住的参数）时
--     cmd 会按 cmd /? 的解析规则 2 剥掉首尾引号，把 exe 路径和后续参数一起解析坏
--     （实测报「文件名、目录名或卷标语法不正确」）。
local function run_redirected(cmd, out_file)
  local dir = out_file:match("^(.*)\\[^\\]*$")
  if dir then run("if not exist " .. M.q(dir) .. " md " .. M.q(dir) .. " >nul 2>&1") end
  return run("> " .. M.q(out_file) .. " 2>&1 " .. cmd)
end

-- 跑一条命令，拿回退出码与 stdout+stderr。io.popen 拿不到退出码，所以输出先落文件。
function M.capture(cmd)
  local code = run_redirected(cmd, OUT_FILE)
  return code, read_file(OUT_FILE)
end

-- 以下文件系统操作已是 POSIX 实现（开发端只在 WSL，#116 / #119；口径同 #115 的 WSL 接缝层：
-- 目录枚举、存在性判断、删除改用 POSIX，直接作用于 Linux 路径）。capture / mirror 仍是 cmd 语法，
-- 留给 #115 的 interop 改造。

-- sh 单引号引用：仅用于下面的 POSIX 命令行，与给 cmd 用的 M.q 无关。
local function sq(path)
  return "'" .. tostring(path):gsub("'", "'\\''") .. "'"
end

-- 路径是否存在（目录或文件）。
function M.exists(path)
  return run("test -e " .. sq(path)) == 0
end

-- 是否目录。
function M.is_dir(path)
  return run("test -d " .. sq(path)) == 0
end

-- 跑一条输出行清单的命令，返回去空行的结果。
local function lines(cmd)
  local out = {}
  local handle = io.popen(cmd)
  for line in handle:lines() do
    if line ~= "" then out[#out + 1] = line end
  end
  handle:close()
  return out
end

-- 目录一级条目 { {name=, dir=}, ... }，按名排序（部署计划要稳定）。
function M.list_entries(dir)
  local out = {}
  for _, line in ipairs(lines("find " .. sq(dir) .. " -mindepth 1 -maxdepth 1 -printf '%y %f\\n' 2>/dev/null")) do
    local kind, name = line:match("^(%S) (.*)$")
    out[#out + 1] = { name = name, dir = kind == "d" }
  end
  table.sort(out, function(a, b) return a.name < b.name end)
  return out
end

-- 目录下全部文件（递归），返回相对 dir 的 / 分隔路径，按名排序；目录不存在返回 nil。
function M.list_files(dir)
  if not M.is_dir(dir) then return nil end
  local out = lines("find " .. sq(dir) .. " -type f -printf '%P\\n' 2>/dev/null")
  table.sort(out)
  return out
end

-- 递归建目录；已存在不算失败。
function M.ensure_dir(path)
  run("mkdir -p " .. sq(path))
end

-- 镜像一个目标的命令行（纯字符串；失败文案要放命令原文，所以单独取出来）。
-- args 里**不要加 /NJH**：横幅没了就看不出命令到底跑没跑过（见下面 robocopy）。
function M.mirror_cmd(target)
  local args = "/NFL /NDL /NJS /NP /R:2 /W:1"
  if target.dir then
    return "robocopy " .. M.q(target.src) .. " " .. M.q(target.dst) .. " /MIR " .. args
  end
  local src_dir, name = target.src:match("^(.*)/([^/]+)$")
  local dst_dir = target.dst:match("^(.*)/[^/]+$")
  return "robocopy " .. M.q(src_dir) .. " " .. M.q(dst_dir) .. " " .. M.q(name) .. " " .. args
end

-- robocopy 退出码 0–7 都是成功（0 无变化、1 有拷贝、2/3 目的地多出东西、…），>= 8 才是失败。
-- 但退出码 1 有第二种含义：cmd 连命令都没起来（重定向落点打不开、命令行解析不了）也返回 1，
-- 所以「退出码 < 8」不能单独当成功——还要有命令确实跑过的证据。证据取 robocopy 自己打的横幅：
-- 日志里没有横幅 = 命令没执行。为此镜像命令**故意不带 /NJH**（实测它会连横幅一起关掉，输出
-- 为空；别加回来），横幅与 /NFL 挡不住的那类噪音都只落在日志文件里，不进控制台；只有失败时才
-- 读出来当原文。
local function robocopy(cmd)
  os.remove(LOG_FILE)
  local code = run_redirected(cmd, LOG_FILE)
  local output = read_file(LOG_FILE)
  local executed = output:find("ROBOCOPY", 1, true) ~= nil
  if executed and code ~= nil and code < 8 then return true, code end
  return false, { cmd = cmd, code = code, output = output, executed = executed }
end

-- 镜像一个目标：目录走 robocopy /MIR，单文件按文件名过滤（非递归，目的地目录由 robocopy 自己建）。
-- 成功返回 true, robocopy 退出码；失败返回 nil, { cmd=, code=, output=, executed= }——executed
-- 区分「命令没执行成」与「执行了但失败」，让调用方能把两种原因分开说。
-- 注意：这条只保证「命令真的执行且按 robocopy 的口径成功」，字节到没到目标侧由调用方核（见
-- tools/deploy.lua 的源/目标文件集合比对）。
function M.mirror(target)
  return robocopy(M.mirror_cmd(target))
end

-- 删掉一个目标（目录或单文件）；目标本来就不在不算失败。
function M.remove(target)
  run((target.dir and "rm -rf " or "rm -f ") .. sq(target.dst))
end

return M
