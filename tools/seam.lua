-- 全仓唯一发起外部进程与文件系统探测的模块（ADR-0017）。
-- 文件系统探测全部纯 Lua（lfs + io/os）；外部进程只有一种形状：spawn{ argv, ... }。
-- 需要读回输出时用 capture{ argv, ... }——它内部仍是 spawn，只把两路输出重定向到临时文件再读回。
-- 路径只有一种形式：仓库内相对、离开仓库正斜杠+盘符；系统返回的反斜杠进本模块即归一。
-- 本模块假定进程 cwd 是仓库根（与 tools/cli.lua 一致），临时输出落 tmp/（gitignored）。
local lfs = require("lfs")

local M = {}

local BACKSLASH = string.char(92)
local DQUOTE = string.char(34)

local DEFAULT_WORKSPACE_REL = "Desktop/dev/eggy/LuaSource_钓鱼怎么这么危险啊喂！"
local EDITOR_CLI_REL = ".eggitor/cli/editor-cli.exe"

M.DEFAULT_WORKSPACE_REL = DEFAULT_WORKSPACE_REL
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
  -- 盘符根的尾斜杠不能丢：Windows 上 "C:" 是「该盘的当前目录」，不是根。
  if body:match("^%a:$") then return body .. "/" end
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
-- 所以先试 symlinkattributes 并用 pcall 兜住。这里的 pcall 是刻意的语义：查不出类型时
-- 不能断言「不占名」，失败结果不丢——回退到 exists，两种口径都判不出才算不占名。
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

-- 文件字节数；不存在或不是文件返回 nil。
function M.size(path)
  if path == nil then return nil end
  return lfs.attributes(tostring(path), "size")
end

-- 文件最后修改时间（Unix 秒）；不存在返回 nil。
function M.mtime(path)
  if path == nil then return nil end
  return lfs.attributes(tostring(path), "modification")
end

-- 打开目录迭代器。调用方已确认目标是目录，所以这里的失败是真错误（权限、句柄耗尽）；
-- 不能返回空表——deploy 会把读不出的宿主目录当成「没有残留」而放行。
local function open_dir(path)
  local ok, iter, state, ctrl = pcall(lfs.dir, path)
  if not ok then
    error(string.format("seam: 读取目录失败 %s（lfs.dir 报错：%s）",
      tostring(path), tostring(iter)), 0)
  end
  return iter, state, ctrl
end

-- 目录一级条目 { {name=, dir=}, ... }，按名排序；目录不存在返回空表。
function M.list_entries(dir)
  local out = {}
  if not M.is_dir(dir) then return out end
  local iter, state, ctrl = open_dir(dir)
  for name in iter, state, ctrl do
    if name ~= "." and name ~= ".." then
      out[#out + 1] = { name = name, dir = M.is_dir(dir .. "/" .. name) }
    end
  end
  table.sort(out, function(a, b) return a.name < b.name end)
  return out
end

local function walk_files(dir, prefix, acc)
  local iter, state, ctrl = open_dir(dir)
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
-- target = { dir = <bool>, dst = <path> }：dir 只是调用方的意图标记，实际按目标自身的
-- 文件属性递归删（目录 lfs.rmdir、文件 os.remove），所以 dir 与真实类型不一致也不会删错。
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

local function read_file(path)
  local f = io.open(path, "rb")
  if not f then return "" end
  local body = f:read("a") or ""
  f:close()
  return body
end

local dir_counter = 0

-- 每个子进程调用独占一个临时目录：lfs.mkdir 是原子的，同名已被别的进程占住就换下一个，
-- 两个进程（例如 hook 与手动 test 同时跑）不会抢同一个目录。capture 与 spawn_bg 共用这一份。
local function unique_dir(base, prefix, label)
  for _ = 1, 1000 do
    dir_counter = dir_counter + 1
    local dir = string.format("%s/%s-%d-%06d", base, prefix, os.time(), dir_counter)
    if lfs.mkdir(dir) then return dir end
  end
  error(string.format("%s: 无法在 %s 下创建临时目录", label, base), 0)
end

-- 跑一条命令并读回 stdout+stderr：只收 argv，不收整条命令串（ADR-0017）。
-- spec = { argv=<字符串数组>, cwd=<?>, env=<?>, tmp_dir=<? 默认 tmp> }
-- 内部仍是 spawn：两路输出重定向到临时文件，读完即删。返回 退出码, 输出文本。
function M.capture(spec)
  assert(type(spec) == "table", "capture 需要一个 table 参数")
  local base = M.normalize(spec.tmp_dir or "tmp")
  M.ensure_dir(base)
  local dir = unique_dir(base, "seam-capture", "seam.capture")
  local out = dir .. "/out.log"
  local code = M.spawn({ argv = spec.argv, cwd = spec.cwd, env = spec.env, stdout = out, stderr = out })
  local body = read_file(out)
  os.remove(out)
  lfs.rmdir(dir)
  return code, body
end

-- 宿主侧工具就位（至少 robocopy 可用）。成功 true；失败 nil, 原因。
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
  local code, out = M.capture({ argv = { exe, "--version" } })
  if code == 0 and has_output(out) then return true end
  code, out = M.capture({ argv = { exe, "-v" } })
  return code == 0 and has_output(out)
end

-- 按 PATH 找命令，并对候选做一次真实调用验证。返回可执行绝对路径或 nil。
function M.which(name)
  for _, exe in ipairs(path_candidates(name)) do
    if version_ok(exe) then return exe end
  end
  return nil
end

-- 环境变量前缀：一条一条的 `set "K=V"`，怎么拼由调用方决定
-- （spawn 用 && 串进同一行，spawn_bg 写成 batch 的独立行）。
local function env_assignments(env)
  local parts = {}
  if not env then return parts end
  local keys = {}
  for k in pairs(env) do keys[#keys + 1] = k end
  table.sort(keys)
  for _, k in ipairs(keys) do
    parts[#parts + 1] = "set " .. M.quote(tostring(k) .. "=" .. tostring(env[k]))
  end
  return parts
end

-- argv 逐个 cmd 引用后拼成一行：spawn 与 spawn_bg 共用这一份，拼法只有这里一处。
local function render_argv(argv)
  local rendered = {}
  for i = 1, #argv do rendered[i] = M.quote(argv[i]) end
  return table.concat(rendered, " ")
end

-- cmd 的单行上限。超了要在起进程之前断言，否则 cmd 会截断命令、跑出莫名其妙的结果。
local function assert_line_limit(text, label)
  if #text > CMD_LINE_LIMIT then
    error(string.format("%s：命令行超过 cmd %d 字符上限（实际 %d 字符）：%s...",
      label, CMD_LINE_LIMIT, #text, text:sub(1, 160)), 0)
  end
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
  for _, assign in ipairs(env_assignments(spec.env)) do parts[#parts + 1] = assign .. " &&" end

  local command = render_argv(argv)

  if spec.stdout and spec.stderr and spec.stdout == spec.stderr then
    command = command .. " > " .. M.quote(spec.stdout) .. " 2>&1"
  else
    if spec.stdout then command = command .. " > " .. M.quote(spec.stdout) end
    if spec.stderr then command = command .. " 2> " .. M.quote(spec.stderr) end
  end
  parts[#parts + 1] = command

  local line = "@" .. table.concat(parts, " ")
  assert_line_limit(line, "seam.spawn")
  local _, _, code = os.execute(line)
  return tonumber(code) or 1
end

-- ============================ 并发子进程 ============================

-- 目标是不是「cmd 会把控制权交给它」的那种：批处理要 call，否则 run.cmd 后面的退出码与
-- 完成标记一行都不会执行；没有扩展名的命令同样要 call（PATH 上命中的往往正是 .bat）。
local function needs_call(cmd)
  if cmd:match("%.[Bb][Aa][Tt]$") or cmd:match("%.[Cc][Mm][Dd]$") then return true end
  return not cmd:match("%.[%w]+$")
end

-- 并发形状：argv 与 spawn 完全一样，只把「起来」与「等完」拆成两步。
-- 需要它的理由只有一个：spawn 走 os.execute，会一直等到子进程退出，而测试分片要并跑就得
-- 先把所有分片都起来，再按完成顺序收。
-- 落地方式是给每次调用写一份 run.cmd 再 `start /B` 起后台：命令行的拼法仍是接缝这一份
-- （quote / env_assignments / cd /d），调用方依旧只交 argv；单行上限照旧断言。
-- 子进程把 stdout+stderr 合并进 out.log，退出码写 code.txt，最后写 done.txt 当完成标记。
-- 判完成看 done.txt 而不是 out.log 的非空：done.txt 由 batch 最后一行写，它出现即说明
-- 前一行（code.txt）已经写完并关闭，不会读到半个数字。
-- spec = { argv, cwd, env, tmp_dir=<? 默认 tmp> }。返回句柄，交给 bg_done / bg_output / bg_close。
function M.spawn_bg(spec)
  assert(type(spec) == "table", "spawn_bg 需要一个 table 参数")
  local argv = spec.argv
  assert(type(argv) == "table" and #argv > 0, "spawn_bg.argv 必须是非空字符串数组")

  -- 临时目录必须绝对化：run.cmd 里会 cd 到 spec.cwd，相对路径的日志文件会被解析到那边去；
  -- 而且 `start` 拿相对路径（哪怕文件真的在）不会去当前目录找，只会静默什么都不做。
  local base, base_err = M.absolute(spec.tmp_dir or "tmp")
  assert(base, "spawn_bg.tmp_dir 无效: " .. tostring(base_err))
  M.ensure_dir(base)
  local dir = unique_dir(base, "seam-bg", "seam.spawn_bg")

  local handle = {
    dir = dir,
    cmd = dir .. "/run.cmd",
    out = dir .. "/out.log",
    code = dir .. "/code.txt",
    done = dir .. "/done.txt",
  }

  local command = render_argv(argv)

  local lines = { "@echo off" }
  for _, assign in ipairs(env_assignments(spec.env)) do lines[#lines + 1] = assign end
  -- 批处理目标必须用 call 调：在 batch 里直接写另一个 batch 会把控制权交给它，回来时
  -- 整份 run.cmd 已经结束，后面的退出码与完成标记一行都不会执行（busted 正是 .bat）。
  -- 可执行文件不加 call，保持与 spawn 同一种调用形态。
  local lead = needs_call(argv[1]) and "call " or ""
  -- cd 与命令并到同一行：cd 失败时命令不该照跑（跑在错误的 cwd 里比直接失败更难查），
  -- 这个语义与 spawn 的 `cd /d ... &&` 对齐。
  local prefix = ""
  if spec.cwd then prefix = "cd /d " .. M.quote(spec.cwd) .. " && " end
  lines[#lines + 1] = prefix .. lead .. command .. " > " .. M.quote(handle.out) .. " 2>&1"
  lines[#lines + 1] = ">" .. M.quote(handle.code) .. " echo %ERRORLEVEL%"
  lines[#lines + 1] = ">" .. M.quote(handle.done) .. " echo ok"

  local longest = ""
  for _, text in ipairs(lines) do
    if #text > #longest then longest = text end
  end
  if #longest > CMD_LINE_LIMIT then
    rmrf(dir)
    assert_line_limit(longest, "seam.spawn_bg")
  end

  local file = assert(io.open(handle.cmd, "wb"), handle.cmd .. " 建不出来")
  file:write(table.concat(lines, "\r\n") .. "\r\n")
  file:close()

  -- start 的第一个引号参数被当成窗口标题，必须显式给空串，否则带空格的路径会被当标题吞掉。
  local _, _, code = os.execute("@start /B " .. M.quote("") .. " " .. M.quote(handle.cmd) .. " > nul 2>&1")
  if code ~= 0 then
    local output = read_file(handle.out)
    error(string.format("seam.spawn_bg: start 起不来（退出码 %s）：%s\n%s",
      tostring(code), handle.cmd, output), 0)
  end
  -- start 找不到目标时退出码仍是 0（静默什么都不做），所以还要求证据：子进程一启动就建 out.log
  -- （重定向在命令跑之前就建好），3 秒内两样都没有，就是这次并发调用没起来。
  -- 窗口给到 10 秒：8 路同起、叠上杀软扫描时，进程真正起来可能要几秒，宁可多等也别误判成没起来。
  for _ = 1, 200 do
    if M.exists(handle.out) or M.exists(handle.done) then return handle end
    M.sleep(50)
  end
  error(string.format("seam.spawn_bg: start 之后 10 秒内没有生成 %s，子进程没起来：%s",
    handle.out, handle.cmd), 0)
end

-- 子进程结束了吗：结束返回退出码，还在跑返回 nil。
function M.bg_done(handle)
  assert(type(handle) == "table" and handle.done, "bg_done 需要一个 spawn_bg 返回的句柄")
  if not M.exists(handle.done) then return nil end
  return tonumber((read_file(handle.code):gsub("%s", ""))) or 1
end

-- 子进程到目前为止的输出（stdout 与 stderr 合并）。只能在 bg_done 返回退出码之后读全文。
function M.bg_output(handle)
  assert(type(handle) == "table" and handle.out, "bg_output 需要一个 spawn_bg 返回的句柄")
  return read_file(handle.out)
end

-- 删掉这次并发调用的临时目录（日志已读走时调用）。删不干净返回 false，由调用方决定要不要提示。
-- 不能只删一次：完成标记由子进程最后一行写，我们读到时它往往还没退出，句柄没关，
-- 这时 lfs.dir 或 os.remove 会撞上共享冲突、整轮什么都没删掉（实测留下过完整的 run.cmd/out.log）。
-- 所以中间退避再试。
function M.bg_close(handle)
  if type(handle) ~= "table" or not handle.dir then return true end
  for _ = 1, 10 do
    rmrf(handle.dir)
    if not M.exists(handle.dir) then return true end
    M.sleep(50)
  end
  return false
end

-- 亚秒等待。Windows 没有内置的亚秒 sleep（timeout 最小 1 秒，ping 的包间隔固定 1 秒），
-- 起一个进程去睡比本进程空转更贵，所以这里就空转：只在轮询并发子进程时用。
-- 空转是占满一个核的，调用方要自己把间隔放大（分片是秒级的，50~100 ms 一轮不影响墙钟）。
function M.sleep(ms)
  local deadline = os.clock() + (tonumber(ms) or 0) / 1000
  while os.clock() < deadline do end
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
