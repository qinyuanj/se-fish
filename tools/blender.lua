-- blender 子命令：开发端（WSL）驱动 Windows 侧 Blender 的唯一入口（#125，ADR-0009）。
-- 在仓库根执行 `lua5.4 tools/cli.lua blender ...`。
--
-- 只走无头：经上游 blender-core skill 的 run_in_blender.py（WSL 的 python3 运行）拉起
-- blender.exe -b --factory-startup --python-exit-code 1，只输出脚本的 @@JSON@@ 行。
-- 本模块负责跨接缝的部分：interop 预检、定位 Blender、把路径类实参转成 Windows 形式；
-- 进程调用一律经 tools/wsl_seam，fast 车道用桩替换。
-- 实测（2026-10-25）：Windows 侧 Blender 能直接读写 \\wsl.localhost\... 路径，脚本同目录
-- 依赖（_bpyx.py）也能 import，所以不复制到 Windows 临时目录。

package.path = "./?.lua;./?/init.lua;" .. package.path

local seam = require("tools.wsl_seam")

local M = {}

-- 上游执行脚本（gitignored，不归本仓管理，不改其文件）；路径相对仓库根。
M.RUNNER = ".agents/skills/blender-core/scripts/run_in_blender.py"

local EXE_HINT = "设置环境变量 BLENDER_EXE 指向 blender.exe，接受 /mnt/c/... 与 C:\\... 两种形式，"
  .. "例如 BLENDER_EXE='C:\\Program Files\\Blender Foundation\\Blender 5.2\\blender.exe'"

-- 未设 BLENDER_EXE 时扫的 Windows 标准安装目录：<Windows 变量>/<相对路径>/Blender X.Y/blender.exe。
local INSTALL_ROOTS = {
  { env = "ProgramFiles", rel = "Blender Foundation" },
  { env = "LOCALAPPDATA", rel = "Programs/Blender Foundation" },
}

function M.usage()
  return table.concat({
    "用法: lua5.4 tools/cli.lua blender <脚本.py> [--blend <输入.blend>] [-- <脚本参数>...]",
    "      lua5.4 tools/cli.lua blender --expr <Python 代码> [--blend <输入.blend>]",
    "      lua5.4 tools/cli.lua blender --which",
    "",
    "在 Windows 侧无头 Blender 里执行脚本，只输出脚本的 JSON（@@JSON@@ 行），不夹带启动日志。",
    "经上游 blender-core skill 的 run_in_blender.py 执行（-b --factory-startup --python-exit-code 1），",
    "退出码透传该脚本的退出码（0 成功 / 1 脚本失败）。",
    "",
    "路径一律写开发端（Linux）形式，由入口转成 Windows 形式：脚本、--blend，以及 -- 之后",
    "以 / 或 ./ ../ 开头的参数（含 --key=/path 形式）。其余参数原样传给脚本。",
    "",
    "选项：",
    "  --blend <文件>   先打开这个 .blend 再执行",
    "  --expr <代码>    执行内联 Python（不转换其中的路径）",
    "  --which          打印将要使用的 Blender 路径与版本，不执行脚本",
    "",
    "Blender 定位：先看 BLENDER_EXE（接受 /mnt/c/... 与 C:\\... 两种形式，空串当作未设置）；",
    "未设置时在 %ProgramFiles%\\Blender Foundation 与 %LOCALAPPDATA%\\Programs\\Blender Foundation",
    "下按版本号取最新。interop 不可用或找不到 Blender 时，在启动 Blender 前以退出码 1 失败。",
    "",
  }, "\n") .. "\n"
end

local function fail(msg)
  error("blender: " .. msg, 0)
end

-- "5.10" → {5, 10}；按数字逐段比较，5.10 比 5.9 新。
local function version_key(text)
  local key = {}
  for n in text:gmatch("%d+") do key[#key + 1] = tonumber(n) end
  return key
end

local function newer(a, b)
  for i = 1, math.max(#a, #b) do
    local x, y = a[i] or -1, b[i] or -1
    if x ~= y then return x > y end
  end
  return false
end

-- 解析 BLENDER_EXE；返回 WSL 路径，或 nil, 原因。
local function from_env(value)
  local path = value
  if seam.is_windows_path(value) then
    local converted, err = seam.to_linux(value)
    if not converted then return nil, "BLENDER_EXE 转换失败: " .. tostring(err) end
    path = converted
  end
  if path:sub(1, 1) ~= "/" then
    return nil, "BLENDER_EXE 须为绝对路径（当前为 " .. value .. "）；" .. EXE_HINT
  end
  if not seam.exists(path) then
    return nil, "BLENDER_EXE 指向的文件不存在: " .. value .. "；" .. EXE_HINT
  end
  return path
end

-- 在 Windows 标准安装目录下找最新的 blender.exe。
local function from_install_dirs()
  local best, best_key
  for _, root in ipairs(INSTALL_ROOTS) do
    local base = seam.windows_env(root.env)
    if base then
      local dir = base .. "/" .. root.rel
      for _, entry in ipairs(seam.list_entries(dir)) do
        local ver = entry.dir and entry.name:match("^Blender%s+(%d+[%d%.]*)$")
        local exe = ver and (dir .. "/" .. entry.name .. "/blender.exe")
        if exe and seam.exists(exe) then
          local key = version_key(ver)
          if not best or newer(key, best_key) then best, best_key = exe, key end
        end
      end
    end
  end
  if not best then
    return nil, "找不到 Blender（Windows 标准安装目录下没有 Blender Foundation/Blender X.Y/blender.exe）；"
      .. EXE_HINT
  end
  return best
end

-- 将要使用的 blender.exe（WSL 路径）；找不到返回 nil, 原因。不认 BLENDER_PATH。
function M.locate()
  local env = os.getenv("BLENDER_EXE")
  if env and env ~= "" then return from_env(env) end
  return from_install_dirs()
end

local function windows(path)
  local value, err = seam.to_windows(path)
  if not value then fail(tostring(err)) end
  return value
end

-- 开发端已存在的文件 → 绝对 Windows 路径（wslpath -w 对相对路径只给相对结果，所以先绝对化）。
local function existing_windows(path, what)
  if not seam.is_windows_path(path) then
    local abs = path
    if path:sub(1, 1) ~= "/" then
      local err
      abs, err = seam.absolute(path)
      if not abs then fail(what .. "不存在: " .. path .. "（" .. tostring(err) .. "）") end
    end
    if not seam.exists(abs) then fail(what .. "不存在: " .. path) end
    path = abs
  end
  return windows(path)
end

-- -- 之后的单个参数：像开发端路径的转成 Windows 形式，其余原样。
local function script_arg(arg)
  local prefix, value = arg:match("^(%-%-[%w_%-]+=)(.+)$")
  if not prefix then prefix, value = "", arg end
  if value:match("^/") and not value:match("^//") then
    return prefix .. windows(value)
  end
  if value:match("^%.%.?/") then
    local abs, err = seam.absolute(value)
    if not abs then fail("参数路径无法绝对化: " .. value .. "（" .. tostring(err) .. "）") end
    return prefix .. windows(abs)
  end
  return arg
end

-- 解析参数；用法错误返回 nil, 原因。
local function parse(args)
  local opts = { rest = {} }
  local i = 1
  while i <= #args do
    local a = args[i]
    if a == "--" then
      for j = i + 1, #args do opts.rest[#opts.rest + 1] = args[j] end
      break
    elseif a == "--help" or a == "-h" then
      opts.help = true
    elseif a == "--which" then
      opts.which = true
    elseif a == "--blend" or a == "--expr" then
      local v = args[i + 1]
      if v == nil or v == "--" then return nil, a .. " 缺少取值" end
      opts[a:sub(3)] = v
      i = i + 1
    elseif a:match("^%-") then
      return nil, "未知参数: " .. a
    elseif not a:match("%.py$") then
      return nil, "脚本须为 .py 文件: " .. a
    elseif opts.script then
      return nil, "只能指定一个脚本（已有 " .. opts.script .. "）: " .. a
    else
      opts.script = a
    end
    i = i + 1
  end
  if opts.help or opts.which then return opts end
  if opts.script and opts.expr then return nil, "脚本与 --expr 只能二选一" end
  if not opts.script and not opts.expr then return nil, "缺少脚本或 --expr" end
  return opts
end

-- --which：打印将用的 Blender（WSL 与 Windows 两种形式）及其版本。
local function report_which(exe)
  local code, out = seam.capture(seam.q(exe) .. " --version")
  local version = code == 0 and out:match("Blender%s+(%d[^\r\n]*)")
  if not version then
    fail("读取 Blender 版本失败（退出码 " .. code .. "）: " .. (out:match("^%s*(.-)%s*$") or ""))
  end
  io.stdout:write("blender: " .. exe .. "\n",
    "windows: " .. windows(exe) .. "\n",
    "version: " .. (version:match("^(.-)%s*$")) .. "\n")
  return 0
end

local function run(opts)
  local ok, err = seam.interop()
  if not ok then fail(err) end
  local exe
  exe, err = M.locate()
  if not exe then fail(err) end
  if opts.which then return report_which(exe) end

  if not seam.which("python3") then fail("PATH 上找不到 python3（上游 run_in_blender.py 需要它）") end
  if not seam.exists(M.RUNNER) then
    fail("上游 blender-core skill 未安装（缺 " .. M.RUNNER .. "），"
      .. "来源与重装方式见 docs/agents/art-pipeline.md 的「上游 blender-* skill」")
  end

  local parts = { "BLENDER_EXE=" .. seam.q(exe), "python3", seam.q(M.RUNNER) }
  if opts.blend then
    parts[#parts + 1] = "--blend " .. seam.q(existing_windows(opts.blend, "输入 .blend "))
  end
  if opts.expr then
    parts[#parts + 1] = "--expr " .. seam.q(opts.expr)
  else
    parts[#parts + 1] = seam.q(existing_windows(opts.script, "脚本"))
  end
  if #opts.rest > 0 then
    parts[#parts + 1] = "'--'"
    for _, a in ipairs(opts.rest) do parts[#parts + 1] = seam.q(script_arg(a)) end
  end
  return seam.execute(table.concat(parts, " "))
end

-- 退出码：0 成功 / 1 业务失败（含预检失败）/ 2 用法错误；执行后透传上游脚本的退出码。
function M.main(args)
  local opts, err = parse(args or {})
  if not opts then
    io.stderr:write("blender: " .. err .. "\n\n" .. M.usage())
    return 2
  end
  if opts.help then
    io.stdout:write(M.usage())
    return 0
  end
  local ok, result = pcall(run, opts)
  if not ok then
    io.stderr:write(tostring(result) .. "\n")
    return 1
  end
  return result
end

if ... == "tools.blender" then
  return M
end

os.exit(M.main(arg))
