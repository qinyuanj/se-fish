-- blender 子命令：Windows 原生无头 Blender 的唯一入口（#125，#190；ADR-0009、ADR-0017）。
-- 在仓库根执行 `lua tools/cli.lua blender ...`。
--
-- 只走无头：经上游 blender-core skill 的 run_in_blender.py（系统 python 3.x 运行）拉起
-- blender.exe -b --factory-startup --python-exit-code 1，只输出脚本的 @@JSON@@ 行。
-- 本模块只经 tools/seam.lua（唯一接缝）发起进程与文件系统探测：
--   * 无头入口只认 `python`，并断言主版本为 3.x（python3 可能是 0 字节假壳，不再使用）；
--   * BLENDER_EXE 经 spawn 的 env 传给 run_in_blender.py，不拼在命令行前面；
--   * 路径一律正斜杠 Windows 形式（如 C:/Program Files/...），不做 WSL 式路径转换。

package.path = "./?.lua;./?/init.lua;" .. package.path

local seam = require("tools.seam")
local exit_code = require("tools.exit_code")

local M = {}

-- 上游执行脚本（gitignored，不归本仓管理，不改其文件）；路径相对仓库根。
M.RUNNER = ".agents/skills/blender-core/scripts/run_in_blender.py"

local EXE_HINT = "设置环境变量 BLENDER_EXE 指向 blender.exe，用正斜杠 Windows 路径，"
  .. "例如 BLENDER_EXE='C:/Program Files/Blender Foundation/Blender 5.2/blender.exe'"

-- 未设 BLENDER_EXE 时扫的 Windows 标准安装目录：<Windows 变量>/<相对路径>/Blender X.Y/blender.exe。
local INSTALL_ROOTS = {
  { env = "ProgramFiles", rel = "Blender Foundation" },
  { env = "LOCALAPPDATA", rel = "Programs/Blender Foundation" },
}

function M.usage()
  return table.concat({
    "用法: lua tools/cli.lua blender <脚本.py> [--blend <输入.blend>] [-- <脚本参数>...]",
    "      lua tools/cli.lua blender --expr <Python 代码> [--blend <输入.blend>]",
    "      lua tools/cli.lua blender --which",
    "",
    "在 Windows 原生无头 Blender 里执行脚本，只输出脚本的 JSON（@@JSON@@ 行），不夹带启动日志。",
    "经上游 blender-core skill 的 run_in_blender.py 执行（-b --factory-startup --python-exit-code 1），",
    "退出码透传该脚本的退出码（0 成功 / 1 脚本失败）。",
    "",
    "路径一律写正斜杠 Windows 形式（如 C:/Program Files/...）：脚本、--blend，以及 -- 之后",
    "以盘符、/ 或 ./ ../ 开头的参数（含 --key=/path 形式）由入口绝对化并归一。其余参数原样传给脚本。",
    "",
    "选项：",
    "  --blend <文件>   先打开这个 .blend 再执行",
    "  --expr <代码>    执行内联 Python（不转换其中的路径）",
    "  --which          打印将要使用的 Blender 路径与版本，不执行脚本",
    "",
    "Blender 定位：先看 BLENDER_EXE（正斜杠 Windows 路径，空串当作未设置）；",
    "未设置时在 %ProgramFiles%\\Blender Foundation 与 %LOCALAPPDATA%\\Programs\\Blender Foundation",
    "下按版本号取最新。找不到 Blender、缺 python 3.x 或上游 skill 时，",
    "在启动 Blender 前以退出码 3 失败。",
    "",
  }, "\n") .. "\n"
end

local function fail(msg)
  error("blender: " .. msg, 0)
end

-- 平台或工具不可用（Blender、python、上游 runner）：main 收成退出码 3。
local function unavailable(msg)
  exit_code.unavailable("blender: " .. msg)
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

local function trim(text)
  return (tostring(text):match("^%s*(.-)%s*$")) or ""
end

-- 跑一条只读查询命令并读回 stdout+stderr（seam.capture 内部就是 spawn + 临时文件再读回）。
-- tmp 基准用 CLI 传来的仓库根，避免从子目录调用时把 tmp/ 建在子目录里。
local function capture(root, argv)
  return seam.capture({ argv = argv, tmp_dir = root .. "/tmp" })
end

local function is_absolute_windows(path)
  return path:match("^%a:/") ~= nil or path:sub(1, 2) == "//"
end

-- 解析 BLENDER_EXE；返回归一的正斜杠 Windows 路径，或 nil, 原因。
local function from_env(value)
  local path = seam.normalize(value)
  if not is_absolute_windows(path) then
    return nil, "BLENDER_EXE 须为绝对 Windows 路径（当前为 " .. value .. "）；" .. EXE_HINT
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

-- 将要使用的 blender.exe（正斜杠 Windows 路径）；找不到返回 nil, 原因。不认 BLENDER_PATH。
function M.locate()
  local env = os.getenv("BLENDER_EXE")
  if env and env ~= "" then return from_env(env) end
  return from_install_dirs()
end

-- 找 python 并断言主版本为 3.x；返回解释器绝对路径，或 nil, 原因。
local function python3(root)
  local python = seam.which("python")
  if not python then
    return nil, "PATH 上找不到 python（上游 run_in_blender.py 需要 Python 3.x；"
      .. "python3 可能是 0 字节假壳，不再使用）"
  end
  local _, out = capture(root, { python, "--version" })
  local major, minor = out:match("Python%s+(%d+)%.(%d+)")
  if not major then
    return nil, "无法读取 python 版本（`python --version` 输出：" .. trim(out) .. "）"
  end
  if tonumber(major) ~= 3 then
    return nil, "需要 Python 3.x，当前 python 主版本为 " .. major .. "（" .. trim(out) .. "）"
  end
  return python, tonumber(major) .. "." .. minor
end

-- 仓库检出里已存在的路径 → 绝对正斜杠 Windows 路径（seam.absolute 已归一）。
local function existing_windows(path, what)
  local abs, err = seam.absolute(path)
  if not abs then fail(what .. "路径无法绝对化: " .. tostring(path) .. "（" .. tostring(err) .. "）") end
  if not seam.exists(abs) then fail(what .. "不存在: " .. abs) end
  return abs
end

-- 像路径：盘符、UNC、/ 开头、./ 或 ../ 开头（--key= 形式只看等号右边）。
local function looks_like_path(value)
  return value:match("^%a:/") ~= nil or value:match("^/") ~= nil
    or value:match("^%./") ~= nil or value:match("^%.%./") ~= nil
end

-- -- 之后的单个参数：像路径的绝对化并归一，其余原样。
local function script_arg(arg)
  local prefix, value = arg:match("^(%-%-[%w_%-]+=)(.+)$")
  if not prefix then prefix, value = "", arg end
  if looks_like_path(value) then
    local abs, err = seam.absolute(value)
    if not abs then fail("参数路径无法绝对化: " .. value .. "（" .. tostring(err) .. "）") end
    return prefix .. abs
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
      return nil, "只能指定一个脚本（已有 " .. opts.script .. "）：" .. a
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

-- --which：打印将用的 Blender（一条正斜杠 Windows 路径）及其版本。
local function report_which(root, exe)
  local code, out = capture(root, { exe, "--version" })
  local version = out:match("Blender%s+(%d[^\r\n]*)")
  if not version then
    fail("读取 Blender 版本失败（退出码 " .. tostring(code) .. "）：" .. trim(out))
  end
  io.stdout:write("blender: " .. exe .. "\n", "version: " .. trim(version) .. "\n")
  return 0
end

local function run(opts, root)
  local exe, err = M.locate()
  if not exe then unavailable(err) end
  if opts.which then return report_which(root, exe) end

  local python
  python, err = python3(root)
  if not python then unavailable(err) end
  if not seam.exists(M.RUNNER) then
    unavailable("上游 blender-core skill 未安装（缺 " .. M.RUNNER .. "），"
      .. "来源与重装方式见 docs/agents/art-pipeline.md 的「上游 blender-* skill」")
  end

  local argv = { python, M.RUNNER }
  if opts.blend then
    argv[#argv + 1] = "--blend"
    argv[#argv + 1] = existing_windows(opts.blend, "输入 .blend ")
  end
  if opts.expr then
    argv[#argv + 1] = "--expr"
    argv[#argv + 1] = opts.expr
  else
    argv[#argv + 1] = existing_windows(opts.script, "脚本")
  end
  if #opts.rest > 0 then
    argv[#argv + 1] = "--"
    for _, a in ipairs(opts.rest) do argv[#argv + 1] = script_arg(a) end
  end
  -- 在仓库根执行：RUNNER 是相对仓库根的路径，从子目录调用时也不会找不到。
  return seam.spawn({ argv = argv, cwd = root, env = { BLENDER_EXE = exe } })
end

-- 仓库根：CLI 入口给的是 Windows 绝对路径（cli.lua 已用 lfs.currentdir 推导，不读 PWD）。
-- 直接跑本模块时没有 env，用接缝按当前目录绝对化兜底。
local function repo_root(env)
  local root = env and env.repo_root
  if root and (root:match("^%a:/") or root:sub(1, 2) == "//") then return root end
  return assert(seam.absolute("."))
end

-- 退出码：0 成功 / 1 业务失败 / 2 用法错误 / 3 平台或工具不可用；执行后透传上游脚本的退出码。
function M.main(args, env)
  local root = repo_root(env)
  local opts, err = parse(args or {})
  if not opts then
    io.stderr:write("blender: " .. err .. "\n\n" .. M.usage())
    return 2
  end
  if opts.help then
    io.stdout:write(M.usage())
    return 0
  end
  return exit_code.protect(run, opts, root)
end

if ... == "tools.blender" then
  return M
end

os.exit(M.main(arg))
