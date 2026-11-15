-- 全仓唯一发起外部进程与文件系统探测的模块（ADR-0017）。
-- 文件系统探测全部纯 Lua（lfs + io/os）；外部进程统一走 spawn{ argv, ... }。
-- 路径只有一种形式：仓库内相对、离开仓库正斜杠+盘符；系统返回的反斜杠进本模块即归一。
-- 本模块假定进程 cwd 是仓库根（与 tools/cli.lua 一致），临时输出落 tmp/（gitignored）。
local lfs = require("lfs")

local M = {}

local BACKSLASH = string.char(92)
local DQUOTE = string.char(34)

local DEFAULT_WORKSPACE_REL = "Desktop/dev/eggy/LuaSource_钓鱼怎么这么危险啊喂！"
local MAGPIE_LIBRARY_REL = ".config/magpie/library/skills"
local EDITOR_CLI_REL = ".eggitor/cli/editor-cli.exe"

M.DEFAULT_WORKSPACE_REL = DEFAULT_WORKSPACE_REL
M.MAGPIE_LIBRARY_REL = MAGPIE_LIBRARY_REL
M.EDITOR_CLI_REL = EDITOR_CLI_REL
M.LOG_FILE = "tmp/robocopy.log"

local CMD_LINE_LIMIT = 8191
M.CMD_LINE_LIMIT = CMD_LINE_LIMIT

-- ============================ 路径归一 ============================

-- 反斜杠折成正斜杠。路径只有一种形式。
function M.normalize(path)
  if path == nil then return nil end
  return (tostring(path):gsub(BACKSLASH, "/"))
end

local function is_absolute(path)
  return path:match("^%a:/") ~= nil or path:sub(1, 2) == "//"
end

-- 折叠 "." 与 ".."，保留盘符与 UNC 前缀。
local function collapse(path)
  local unc = path:sub(1, 2) == "//"
  local leading = path:sub(1, 1) == "/"
  local segs = {}
  for seg in path:gmatch("[^/]+") do
    if seg == "." then
      -- 跳过
    elseif seg == ".." then
      if #segs > 0 and segs[#segs] ~= ".." then
        segs[#segs] = nil
      elseif not leading then
        segs[#segs + 1] = ".."
      end
    else
      segs[#segs + 1] = seg
    end
  end
  local body = table.concat(segs, "/")
  if unc then return "//" .. body end
  return body
end

-- 绝对化：已是绝对路径就归一返回，否则拼上当前目录再折叠。失败返回 nil, 原因。
function M.absolute(path)
  if path == nil then return nil, "路径为空" end
  local p = M.normalize(tostring(path))
  if p == "" then return nil, "路径为空" end
  if not is_absolute(p) then
    local cwd = lfs.currentdir()
    if not cwd then return nil, "无法读取当前工作目录" end
    p = M.normalize(cwd) .. "/" .. p
  end
  return collapse(p)
end

-- ============================ 文件系统探测 ============================

function M.exists(path)
  if path == nil then return false end
  return lfs.attributes(tostring(path)) ~= nil
end

-- 名字是否被占用：存在，或是 symlink（含断开的——它也占着名字）。
-- Windows 上 lfs.symlinkattributes 对目录会直接抛错（attempt to index a nil value），
-- 所以先试 symlinkattributes 并 pcall 兜住，失败时退回 exists；两种口径都判不出才算不占名。
function M.lexists(path)
  if path == nil then return false end
  local name = tostring(path)
  local ok, mode = pcall(lfs.symlinkattributes, name, "mode")
  if ok and mode ~= nil then return true end
  return M.exists(name)
end

function M.is_dir(path)
  if path == nil then return false end
  return lfs.attributes(tostring(path), "mode") == "directory"
end

-- 目录一级条目 { {name=, dir=}, ... }，按名排序；目录不存在返回空表。
function M.list_entries(dir)
  local out = {}
  if not M.is_dir(dir) then return out end
  local ok, iter, state, ctrl = pcall(lfs.dir, dir)
  if not ok then return out end
  for name in iter, state, ctrl do
    if name ~= "." and name ~= ".." then
      out[#out + 1] = { name = name, dir = M.is_dir(dir .. "/" .. name) }
    end
  end
  table.sort(out, function(a, b) return a.name < b.name end)
  return out
end

local function walk_files(dir, prefix, acc)
  local ok, iter, state, ctrl = pcall(lfs.dir, dir)
  if not ok then return end
  for name in iter, state, ctrl do
    if name ~= "." and name ~= ".." then
      local full = dir .. "/" .. name
      local mode = lfs.attributes(full, "mode")
      if mode == "directory" then
        walk_files(full, prefix .. name .. "/", acc)
      elseif mode == "file" then
        acc[#acc + 1] = prefix .. name
      end
    end
  end
end

-- 目录下全部文件（递归），返回相对 dir 的 / 分隔路径，按名排序；目录不存在返回 nil。
function M.list_files(dir)
  if not M.is_dir(dir) then return nil end
  local acc = {}
  walk_files(tostring(dir), "", acc)
  table.sort(acc)
  return acc
end

-- 递归建目录；已存在不算失败。
function M.ensure_dir(path)
  path = M.normalize(path)
  if path == "" then return end
  if M.is_dir(path) then return end
  if path:match("^%a:/?$") then return end
  local parent = path:match("^(.*)/[^/]*$")
  if parent and parent ~= "" and parent ~= path then
    M.ensure_dir(parent)
  end
  lfs.mkdir(path)
end

local function rmrf(path)
  local mode = lfs.symlinkattributes(path, "mode")
  if mode == nil then return end
  if mode == "directory" then
    local names = {}
    local ok, iter, state, ctrl = pcall(lfs.dir, path)
    if ok then
      for name in iter, state, ctrl do
        if name ~= "." and name ~= ".." then names[#names + 1] = name end
      end
    end
    for _, name in ipairs(names) do rmrf(path .. "/" .. name) end
    lfs.rmdir(path)
  else
    os.remove(path)
  end
end

-- 递归删除（纯 Lua；不设 rmdir 降级）。目标不存在不算失败。
-- target = { dir = <bool>, dst = <path> }
function M.remove(target)
  if type(target) ~= "table" or target.dst == nil then return true end
  rmrf(M.normalize(target.dst))
  return true
end

-- ============================ cmd 引用 ============================

-- 对尾随反斜杠加倍：CRT 会把引号前的反斜杠当转义，尾随反斜杠跟着闭合引号会被吃掉。
local function double_trailing_backslashes(s)
  local n = #s
  local i = n
  while i >= 1 and s:sub(i, i) == BACKSLASH do i = i - 1 end
  local trailing = n - i
  if trailing > 0 then return s .. string.rep(BACKSLASH, trailing) end
  return s
end

-- cmd 语法引用：整段双引号包裹，内部引号双写成 ""（cmd + CRT 两层都能还原）。
-- 始终加引号还能让 & | < > ( ) 等 cmd 元字符在引号内保持字面。
function M.quote(value)
  local s = tostring(value)
  s = s:gsub(DQUOTE, DQUOTE .. DQUOTE)
  s = double_trailing_backslashes(s)
  return DQUOTE .. s .. DQUOTE
end

-- ============================ 子进程 ============================

-- 跑一条命令，拿回退出码与 stdout+stderr。@ 前缀规避 cmd /c 对引号开头命令行的剥离。
local function capture(command)
  local handle = io.popen("@" .. command .. " 2>&1", "r")
  if not handle then return 1, "" end
  local out = handle:read("a") or ""
  local ok, _, code = handle:close()
  if ok then return 0, out end
  return tonumber(code) or 1, out
end

-- 部署端工具就位（至少 robocopy 可用）。成功 true；失败 nil, 原因。
function M.preflight()
  local raw = os.getenv("PATH") or ""
  for entry in (raw .. ";"):gmatch("([^;]*);") do
    entry = entry:gsub("^" .. DQUOTE, ""):gsub(DQUOTE .. "$", "")
    if entry ~= "" then
      local exe = M.normalize(entry) .. "/robocopy.exe"
      if M.exists(exe) then return true end
    end
  end
  return nil, "PATH 上找不到 robocopy.exe"
end

-- 按 PATH 找命令的候选绝对路径（name.exe / name.bat）。不做真实调用验证。
local function path_candidates(name)
  local names
  if name:match("%.[%a]+$") then
    names = { name }
  else
    names = { name .. ".exe", name .. ".bat" }
  end
  local raw = os.getenv("PATH") or ""
  local result = {}
  for entry in (raw .. ";"):gmatch("([^;]*);") do
    entry = entry:gsub("^" .. DQUOTE, ""):gsub(DQUOTE .. "$", "")
    if entry ~= "" then
      local dir = M.normalize(entry)
      for _, n in ipairs(names) do
        local full = dir .. "/" .. n
        if M.exists(full) then result[#result + 1] = full end
      end
    end
  end
  return result
end

local function has_output(text)
  return (text:gsub("%s", "")) ~= ""
end

-- 一次真实调用验证：--version 有非空输出且退 0；Lua 5.4 只认 -v，故回退 -v。
-- 两者都不满足即判不可用（防止 0 字节假壳 python3）。
local function version_ok(exe)
  local code, out = capture(M.quote(exe) .. " --version")
  if code == 0 and has_output(out) then return true end
  code, out = capture(M.quote(exe) .. " -v")
  return code == 0 and has_output(out)
end

-- 按 PATH 找命令，并对候选做一次真实调用验证。返回可执行绝对路径或 nil。
function M.which(name)
  for _, exe in ipairs(path_candidates(name)) do
    if version_ok(exe) then return exe end
  end
  return nil
end

local function env_prefix(env)
  local parts = {}
  if not env then return parts end
  local keys = {}
  for k in pairs(env) do keys[#keys + 1] = k end
  table.sort(keys)
  for _, k in ipairs(keys) do
    parts[#parts + 1] = "set " .. M.quote(tostring(k) .. "=" .. tostring(env[k])) .. " &&"
  end
  return parts
end

-- 唯一子进程形状：只收 argv，不收整条命令串。
-- spec = { argv=<字符串数组>, cwd=<?>, env=<table|nil>, stdout=<?文件>, stderr=<?文件> }
-- cmd 引用、cd /d、set 前缀、输出重定向都由本函数拼；超过 8191 字符断言报错。
-- 返回子进程退出码。
function M.spawn(spec)
  assert(type(spec) == "table", "spawn 需要一个 table 参数")
  local argv = spec.argv
  assert(type(argv) == "table" and #argv > 0, "spawn.argv 必须是非空字符串数组")

  local parts = {}
  if spec.cwd then
    parts[#parts + 1] = "cd /d " .. M.quote(spec.cwd) .. " &&"
  end
  for _, prefix in ipairs(env_prefix(spec.env)) do parts[#parts + 1] = prefix end

  local rendered = {}
  for i = 1, #argv do rendered[i] = M.quote(argv[i]) end
  local command = table.concat(rendered, " ")

  if spec.stdout and spec.stderr and spec.stdout == spec.stderr then
    command = command .. " > " .. M.quote(spec.stdout) .. " 2>&1"
  else
    if spec.stdout then command = command .. " > " .. M.quote(spec.stdout) end
    if spec.stderr then command = command .. " 2> " .. M.quote(spec.stderr) end
  end
  parts[#parts + 1] = command

  local line = "@" .. table.concat(parts, " ")
  if #line > CMD_LINE_LIMIT then
    error(string.format("命令行超过 cmd %d 字符上限（实际 %d 字符）：%s...",
      CMD_LINE_LIMIT, #line, line:sub(1, 160)), 0)
  end
  local _, _, code = os.execute(line)
  return tonumber(code) or 1
end

-- ============================ 路径推导 ============================

-- 读进程环境变量并归一为正斜杠。
function M.windows_env(name)
  local value = os.getenv(name)
  if value == nil then return nil end
  return M.normalize(value)
end

local function profile()
  local home = M.windows_env("USERPROFILE")
  if not home then return nil, "环境变量 USERPROFILE 未设置" end
  return home
end

-- 默认宿主目录：<USERPROFILE>/Desktop/dev/eggy/LuaSource_钓鱼怎么这么危险啊喂！
function M.default_workspace()
  local home, err = profile()
  if not home then return nil, err end
  return home .. "/" .. DEFAULT_WORKSPACE_REL
end

-- editor-cli.exe：<USERPROFILE>/.eggitor/cli/editor-cli.exe
function M.editor_cli()
  local home, err = profile()
  if not home then return nil, err end
  return home .. "/" .. EDITOR_CLI_REL
end

-- magpie 资源库 skill 目录：<USERPROFILE>/.config/magpie/library/skills
function M.magpie_library()
  local home, err = profile()
  if not home then return nil, err end
  return home .. "/" .. MAGPIE_LIBRARY_REL
end

-- %TEMP%。
function M.windows_temp()
  return M.windows_env("TEMP")
end

-- ============================ robocopy 镜像 ============================

local ROBOCOPY_ARGS = { "/NFL", "/NDL", "/NJS", "/NP", "/R:2", "/W:1" }

local function robocopy_exe()
  local candidates = path_candidates("robocopy")
  return candidates[1]
end

-- 目标 -> robocopy argv（dir 走 /MIR；单文件按文件名过滤，目的地目录由 robocopy 自建）。
local function mirror_argv(target)
  local args = { robocopy_exe() or "robocopy" }
  if target.dir then
    args[#args + 1] = M.normalize(target.src)
    args[#args + 1] = M.normalize(target.dst)
    args[#args + 1] = "/MIR"
  else
    local src_dir, name = M.normalize(target.src):match("^(.*)/([^/]+)$")
    local dst_dir = M.normalize(target.dst):match("^(.*)/[^/]+$")
    args[#args + 1] = src_dir
    args[#args + 1] = dst_dir
    args[#args + 1] = name
  end
  for _, a in ipairs(ROBOCOPY_ARGS) do args[#args + 1] = a end
  return args
end

-- 可读命令字符串（失败文案放命令原文用）。
function M.mirror_cmd(target)
  local rendered = {}
  for i, a in ipairs(mirror_argv(target)) do rendered[i] = M.quote(a) end
  return table.concat(rendered, " ")
end

local function read_file(path)
  local f = io.open(path, "rb")
  if not f then return "" end
  local body = f:read("a") or ""
  f:close()
  return body
end

-- robocopy 退出码 0-7 成功，>=8 失败；但退回码 1 也意味着"命令没起来"，
-- 所以还要求有命令确实跑过的证据：日志里的 ROBOCOPY 横幅（故意不带 /NJH）。
-- 成功返回 true, 退出码；失败返回 nil, { cmd=, code=, output=, executed= }。
function M.mirror(target)
  local argv = mirror_argv(target)
  local command = M.mirror_cmd(target)
  M.ensure_dir("tmp")
  os.remove(M.LOG_FILE)
  local code = M.spawn({ argv = argv, stdout = M.LOG_FILE, stderr = M.LOG_FILE })
  local output = read_file(M.LOG_FILE)
  local executed = output:find("ROBOCOPY", 1, true) ~= nil
  if executed and code ~= nil and code < 8 then return true, code end
  return nil, { cmd = command, code = code, output = output, executed = executed }
end

return M
