-- WSL 接缝层：工具链里唯一跨 WSL/Windows 边界的地方（ADR-0008）。
-- 开发端在 WSL，部署端（eggy 编辑器、editor-cli.exe、宿主目录）在 Windows；仓库内路径一律
-- 是 Linux 形式，只有拼 robocopy.exe / editor-cli.exe 的命令行时才用 wslpath 转成 Windows
-- 形式。目录枚举、存在性判断、删除、捕获都是 POSIX 实现，直接作用于 /mnt/c 下的路径。
--
-- 执行层只支持 WSL，不保留 Windows 原生分支。interop 按 PATH 解析 cmd.exe / robocopy.exe，
-- 不写死 /mnt/c/...；不能用 wslpath -w 的退出码判断 interop（它对不存在的路径也返回 0）。
-- Windows 环境推导（USERPROFILE、%TEMP%）经 cmd.exe 取值，输出里含 % 视为变量未定义。
--
-- 本模块假定进程 cwd 是仓库根（与 tools/cli.lua 的约定一致），临时输出落 tmp/；
-- tmp/ 是 gitignored 的，重定向落点目录由 ensure_dir 在 mirror 前建好。
local M = {}

M.LOG_FILE = "tmp/robocopy.log"

local DEFAULT_WORKSPACE_REL = "Desktop/dev/eggy/LuaSource_钓鱼怎么这么危险啊喂！"
local MAGPIE_LIBRARY_REL = ".config/magpie/library/skills"
local EDITOR_CLI_REL = ".eggitor/cli/editor-cli.exe"

-- sh 单引号引用：内部的 ' 收成 '\''。
function M.q(value)
  return "'" .. tostring(value):gsub("'", "'\\''") .. "'"
end

-- 路径是否是 Windows 形式（盘符或 UNC）；跨接缝的子命令共用这一口径。
function M.is_windows_path(path)
  return path:match("^%a:[/\\]") ~= nil or path:sub(1, 2) == "\\\\"
end
local is_windows_path = M.is_windows_path

function M.trim(text)
  return (tostring(text):gsub("^%s+", ""):gsub("%s+$", ""))
end
local trim = M.trim

local function run(cmd)
  local _, _, code = os.execute(cmd)
  return tonumber(code) or 1
end

-- 跑一条 sh 命令行，stdout/stderr 直通当前进程，返回退出码。供需要原样透传输出的
-- 子命令（blender）使用；导出成字段是为了让 fast 车道能用桩替换，本模块内部仍走 run。
function M.execute(cmd)
  return run(cmd)
end

-- 跑一条 sh 命令行，拿回退出码与 stdout+stderr。io.popen 的 close 返回
-- true / "exit" / 0（成功）或 nil / "exit" / code（失败）。
function M.capture(cmd)
  local handle = io.popen(cmd .. " 2>&1", "r")
  if not handle then return 1, "" end
  local out = handle:read("a") or ""
  local ok, _, code = handle:close()
  if ok then return 0, out end
  return tonumber(code) or 1, out
end

-- 按 PATH 解析一个命令。找不到返回 nil。
local function find_on_path(name)
  local handle = io.popen("command -v " .. M.q(name) .. " 2>/dev/null")
  if not handle then return nil end
  local path = handle:read("l")
  handle:close()
  if path == nil then return nil end
  path = trim(path)
  if path == "" then return nil end
  return path
end

-- 按 PATH 解析一个命令的绝对路径；找不到返回 nil。
function M.which(name)
  return find_on_path(name)
end

-- interop 预检：cmd.exe 与 robocopy.exe 都能按 PATH 解析。
-- 成功返回 true；失败返回 nil, 原因。
function M.interop()
  if not find_on_path("cmd.exe") then
    return nil, "PATH 上找不到 cmd.exe（WSL interop 不可用）"
  end
  if not find_on_path("robocopy.exe") then
    return nil, "PATH 上找不到 robocopy.exe（WSL interop 不可用）"
  end
  return true
end

local function robocopy_exe()
  local exe = find_on_path("robocopy.exe")
  if not exe then error("PATH 上找不到 robocopy.exe（WSL interop 不可用）", 0) end
  return exe
end

local function cmd_exe()
  local exe = find_on_path("cmd.exe")
  if not exe then return nil, "PATH 上找不到 cmd.exe（WSL interop 不可用）" end
  return exe
end

-- Linux 路径 → Windows 形式；已经是 Windows 形式就原样返回。
function M.to_windows(path)
  path = tostring(path)
  if is_windows_path(path) then return path end
  local code, out = M.capture("wslpath -w " .. M.q(path))
  if code ~= 0 then
    return nil, "wslpath -w 失败（退出码 " .. code .. "）: " .. trim(out)
  end
  local value = trim(out)
  if value == "" then return nil, "wslpath -w 没有输出: " .. path end
  return value
end

-- Windows 路径 → Linux 形式；已经是 Linux 形式就原样返回。
function M.to_linux(path)
  path = tostring(path)
  if not is_windows_path(path) then return path end
  local code, out = M.capture("wslpath -u " .. M.q(path))
  if code ~= 0 then
    return nil, "wslpath -u 失败（退出码 " .. code .. "）: " .. trim(out)
  end
  local value = trim(out)
  if value == "" then return nil, "wslpath -u 没有输出: " .. path end
  return value
end

-- 读一个 Windows 环境变量，返回 WSL 路径形式。
-- cmd.exe 在 Linux cwd 下会先打 UNC 警告，所以按「盘符开头的行」取值；取不到就用最后一个
-- 非空行。选中的行含 % 说明变量未定义（cmd 原样回显 %NAME%），判失败。
function M.windows_env(name)
  local exe, err = cmd_exe()
  if not exe then return nil, err end
  local code, out = M.capture(M.q(exe) .. " /c echo %" .. name .. "%")
  if code ~= 0 then
    return nil, "读取 Windows 变量 " .. name .. " 失败（退出码 " .. code .. "）"
  end
  local value, last
  for line in (out .. "\n"):gmatch("([^\r\n]*)\r?\n") do
    line = trim(line)
    if line ~= "" then
      last = line
      -- 取最后一个盘符行：告警可能排在值前面，值总在最后一条。
      if line:match("^%a:[/\\]") then value = line end
    end
  end
  value = value or last
  if not value then
    return nil, "读取 Windows 变量 " .. name .. " 没有输出"
  end
  if value:find("%", 1, true) then
    return nil, "Windows 变量 " .. name .. " 未定义（cmd 原样回显了 " .. value .. "）"
  end
  return M.to_linux(value)
end

-- 部署端 USERPROFILE 的 WSL 路径（一次推导，多个部署端路径共用）。
local function profile()
  return M.windows_env("USERPROFILE")
end

-- 部署端默认宿主目录：<USERPROFILE>/Desktop/dev/eggy/LuaSource_钓鱼怎么这么危险啊喂！
function M.default_workspace()
  local home, err = profile()
  if not home then return nil, err end
  return home .. "/" .. DEFAULT_WORKSPACE_REL
end

-- 部署端 Windows 临时目录的 WSL 路径。
function M.windows_temp()
  return M.windows_env("TEMP")
end

-- editor-cli.exe 的 WSL 路径（由 USERPROFILE 推导）。
function M.editor_cli()
  local home, err = profile()
  if not home then return nil, err end
  return home .. "/" .. EDITOR_CLI_REL
end

-- 部署端 magpie 资源库的 skill 目录（上游 blender-* skill 的来源）。
function M.magpie_library()
  local home, err = profile()
  if not home then return nil, err end
  return home .. "/" .. MAGPIE_LIBRARY_REL
end

-- 绝对化仓库内路径（realpath）；转换失败返回 nil, 原因。
function M.absolute(path)
  local code, out = M.capture("realpath -- " .. M.q(path))
  if code ~= 0 then
    return nil, "realpath 失败（退出码 " .. code .. "）: " .. trim(out)
  end
  local value = trim(out)
  if value == "" then return nil, "realpath 没有输出: " .. path end
  return value
end

-- 路径是否存在（目录或文件）。
function M.exists(path)
  return run("test -e " .. M.q(path)) == 0
end

-- 名字是否被占用：存在，或是 symlink（含断开的——它也占着名字，不能当成空位去覆盖）。
function M.lexists(path)
  return run("test -e " .. M.q(path) .. " || test -L " .. M.q(path)) == 0
end

-- symlink 的原始指向；不是 symlink 返回 nil。
function M.readlink(path)
  local code, out = M.capture("readlink -- " .. M.q(path))
  if code ~= 0 then return nil end
  return trim(out)
end

-- 是否目录。
function M.is_dir(path)
  return run("test -d " .. M.q(path)) == 0
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
  for _, line in ipairs(lines("find " .. M.q(dir) .. " -mindepth 1 -maxdepth 1 -printf '%y %f\\n' 2>/dev/null")) do
    local kind, name = line:match("^(%S) (.*)$")
    out[#out + 1] = { name = name, dir = kind == "d" }
  end
  table.sort(out, function(a, b) return a.name < b.name end)
  return out
end

-- 目录下全部文件（递归），返回相对 dir 的 / 分隔路径，按名排序；目录不存在返回 nil。
function M.list_files(dir)
  if not M.is_dir(dir) then return nil end
  local out = lines("find " .. M.q(dir) .. " -type f -printf '%P\\n' 2>/dev/null")
  table.sort(out)
  return out
end

-- 递归建目录；已存在不算失败。
function M.ensure_dir(path)
  run("mkdir -p " .. M.q(path))
end

-- 镜像一个目标的命令行（纯字符串；失败文案要放命令原文，所以单独取出来）。
-- args 里**不要加 /NJH**：横幅没了就看不出命令到底跑没跑过（见下面 robocopy）。
function M.mirror_cmd(target)
  local exe = robocopy_exe()
  local args = "/NFL /NDL /NJS /NP /R:2 /W:1"
  local function win(path)
    local value, err = M.to_windows(path)
    if not value then error("deploy: " .. tostring(err), 0) end
    return value
  end
  if target.dir then
    return M.q(exe) .. " " .. M.q(win(target.src)) .. " " .. M.q(win(target.dst)) .. " /MIR " .. args
  end
  local src_dir, name = target.src:match("^(.*)/([^/]+)$")
  local dst_dir = target.dst:match("^(.*)/[^/]+$")
  return M.q(exe) .. " " .. M.q(win(src_dir)) .. " " .. M.q(win(dst_dir)) .. " " .. M.q(name) .. " " .. args
end

local function read_file(path)
  local f = io.open(path, "rb")
  if not f then return "" end
  local body = f:read("a") or ""
  f:close()
  return body
end

-- 跑一条输出重定向到 out_file 的命令，返回退出码。落点目录先建出来，否则 sh 直接报错、
-- 被重定向的那条命令根本不执行（robocopy 那侧还会因此拿到退出码 1）。
local function run_redirected(cmd, out_file)
  M.ensure_dir("tmp")
  return run(cmd .. " > " .. M.q(out_file) .. " 2>&1")
end

-- robocopy 退出码 0–7 都是成功（0 无变化、1 有拷贝、2/3 目的地多出东西、…），>= 8 才是失败。
-- 但退出码 1 有第二种含义：命令没起来（命令行解析不了、解释器缺失）也可能返回 1，
-- 所以「退出码 < 8」不能单独当成功——还要有命令确实跑过的证据。证据取 robocopy 自己打的横幅：
-- 日志里没有横幅 = 命令没执行。为此镜像命令**故意不带 /NJH**（实测它会连横幅一起关掉），
-- 横幅与 /NFL 挡不住的那类噪音都只落在日志文件里，不进控制台；只有失败时才读出来当原文。
local function robocopy(cmd)
  os.remove(M.LOG_FILE)
  local code = run_redirected(cmd, M.LOG_FILE)
  local output = read_file(M.LOG_FILE)
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
  run((target.dir and "rm -rf " or "rm -f ") .. M.q(target.dst))
end

return M
