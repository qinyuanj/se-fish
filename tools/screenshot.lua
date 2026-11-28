-- screenshot 子命令：抓游戏/编辑器画面存 PNG。
-- 在仓库根执行 `lua tools/cli.lua screenshot ...`。
--
-- 两条通道：
--   后台（缺省）    PrintWindow + PW_RENDERFULLCONTENT 直接读窗口表面，目标窗口被遮挡也能取当前帧
--   前台（--screen）CopyFromScreen 读桌面合成，目标窗口必须在最前面；被盖住时抓到的是遮挡物
--
-- 缺省取景是编辑器主窗口（client.exe 进程里面积最大的窗口），试玩时游戏视口就在它里面。
-- 选窗一律排除 WS_EX_LAYERED 的辅助表面：Qt 的 Qt5QWindowToolSaveBits 这类窗口标题也叫
-- client，却什么都不画，桌面合成在那个矩形上给的是盖在上层的别的东西（#185）。
-- `--info` 只报显示路径（虚拟屏 / 非虚拟屏 / 不确定），判据是显示器适配器是否挂在 PCI 总线上。
--
-- 本地多人测试（ADR-0044）会同时开多个客户端窗口：`--list` 只读枚举候选窗口，`--all` 一次
-- 抓全部候选，`--hwnd` 按句柄精确抓一个。候选顺序由抓屏脚本固定（pid 升序、面积降序、句柄升序），
-- `--list` 的序号与 `--all` 的文件后缀 -<序号> 一一对应。
--
-- 进程与文件系统探测只经 tools/seam.lua（唯一接缝）：pwsh 由 seam.which 定位并做一次真实
-- 调用验证，抓屏经 seam.capture{argv} 执行同目录的 screenshot_capture.ps1。
-- 输出落仓库 tmp/（gitignored），路径一律正斜杠 Windows 形式。
local seam = require("tools.seam")
local exit_code = require("tools.exit_code")

local M = {}

M.SCRIPT = "tools/screenshot_capture.ps1"

-- 缺省不指定标题：抓屏脚本按 -Auto 自动选（编辑器进程里面积最大的窗口）。
M.DEFAULT_WINDOW = nil

function M.usage()
  return table.concat({
    "用法: lua tools/cli.lua screenshot [--window <标题子串>] [--screen] [--out <文件.png>]",
    "      lua tools/cli.lua screenshot --rect X,Y,W,H [--out <文件.png>]",
    "      lua tools/cli.lua screenshot --info [--window <标题子串>]",
    "      lua tools/cli.lua screenshot --list [--window <标题子串>]",
    "      lua tools/cli.lua screenshot --hwnd <句柄> [--screen] [--out <文件.png>]",
    "      lua tools/cli.lua screenshot --all [--window <标题子串>] [--screen] [--out <文件.png>]",
    "",
    "抓画面存 PNG。缺省走后台抓屏（PrintWindow），读窗口表面，目标窗口被遮挡也能取到当前帧；",
    "取景缺省是编辑器主窗口，试玩时游戏视口就在它里面。",
    "",
    "选项：",
    "  --window <子串>   取标题包含该子串、面积最大的窗口（排除不可见与 layered 辅助表面）；",
    "                    省略时自动选编辑器进程（client.exe）里面积最大的窗口",
    "  --screen          改走桌面合成（CopyFromScreen），抓窗口在屏幕上显示的样子；",
    "                    目标窗口必须在最前面，被盖住时抓到的是遮挡物",
    "  --rect X,Y,W,H    直接给屏幕矩形（只能走桌面合成），覆盖 --window",
    "  --out <文件.png>  输出路径（缺省 tmp/screenshot-<时间>.png，相对路径相对仓库根）",
    "  --info            只报显示路径与判定（虚拟屏 / 非虚拟屏 / 不确定）及候选窗口数，不抓图；",
    "                    与 --rect 互斥",
    "  --list            只读列出全部候选窗口（省略 --window 时为 client.exe 的窗口），每行",
    "                    「序号 hwnd= pid= rect=X,Y,W,H proc= title=」；顺序固定：pid 升序、",
    "                    面积降序、句柄升序；只能搭配 --window",
    "  --hwnd <句柄>     按精确窗口句柄抓一个窗口（十进制或 0x 十六进制，取自 --list）；",
    "                    与 --rect、--all、--window 互斥",
    "  --all             按 --list 的顺序抓全部候选窗口；第 N 个落在 --out 加后缀 -N",
    "                    （foo.png → foo-1.png；无扩展名直接接 -N），缺省 tmp/screenshot-<时间>-N.png；",
    "                    与 --rect、--hwnd 互斥",
    "",
    "成功时 stdout 只输出绝对 PNG 路径（--all 每张一行，--list 每个窗口一行），退出码 0；",
    "找不到窗口或抓屏失败 1；用法错误 2；pwsh 不在 PATH 上时在抓屏前以退出码 3 失败。",
    "",
  }, "\n") .. "\n"
end

-- 句柄文本 → 正整数：十进制或 0x 十六进制；非法返回 nil, 原因。
function M.parse_hwnd(text)
  local s = tostring(text)
  local n
  if s:match("^%d+$") then
    n = math.tointeger(tonumber(s))
  elseif s:match("^0[xX]%x+$") then
    n = math.tointeger(tonumber(s:sub(3), 16))
  end
  if not n or n <= 0 then
    return nil, "--hwnd 需要正的十进制或 0x 十六进制句柄: " .. s
  end
  return n
end

-- 选项组合的互斥校验；opts 里出现的第一个冲突项报错。
local CONFLICTS = {
  { "list", { "info", "rect", "hwnd", "all", "screen", "out" }, "--list 只能搭配 --window" },
  { "hwnd", { "rect", "all", "window", "info" }, "--hwnd 不能与 --rect、--all、--window、--info 同用" },
  { "all", { "rect", "info" }, "--all 不能与 --rect、--info 同用" },
}

local function check_conflicts(opts)
  for _, rule in ipairs(CONFLICTS) do
    if opts[rule[1]] then
      for _, other in ipairs(rule[2]) do
        if opts[other] then return rule[3] end
      end
    end
  end
  return nil
end

local SWITCHES = { ["--info"] = "info", ["--screen"] = "screen", ["--list"] = "list", ["--all"] = "all" }
local VALUED = { ["--window"] = true, ["--rect"] = true, ["--out"] = true, ["--hwnd"] = true }

-- 解析参数；用法错误返回 nil, 原因。
function M.parse(args)
  local opts = {}
  local i = 1
  while i <= #args do
    local a = args[i]
    if a == "--help" or a == "-h" then
      opts.help = true
    elseif SWITCHES[a] then
      opts[SWITCHES[a]] = true
    elseif VALUED[a] then
      local value = args[i + 1]
      if value == nil or value:match("^%-") then
        return nil, a .. " 需要一个值"
      end
      opts[a:sub(3)] = value
      i = i + 1
    else
      return nil, "未知参数: " .. a
    end
    i = i + 1
  end
  if opts.help then return opts end
  if opts.hwnd then
    local n, err = M.parse_hwnd(opts.hwnd)
    if not n then return nil, err end
    opts.hwnd = n
  end
  local conflict = check_conflicts(opts)
  if conflict then return nil, conflict end
  return opts
end

-- "X,Y,W,H" → {x,y,w,h}；非法返回 nil, 原因。
function M.parse_rect(text)
  local x, y, w, h = tostring(text):match("^(%-?%d+),(%-?%d+),(%-?%d+),(%-?%d+)$")
  if not x then return nil, "矩形格式应为 X,Y,W,H: " .. tostring(text) end
  x, y, w, h = tonumber(x), tonumber(y), tonumber(w), tonumber(h)
  if w <= 0 or h <= 0 then return nil, "矩形宽高必须为正: " .. text end
  return { x = x, y = y, w = w, h = h }
end

-- --all 的第 n 张：文件名有扩展名时插在扩展名前（foo.png → foo-1.png），否则直接接在末尾。
function M.indexed_out(path, n)
  local stem, ext = path:match("^(.*[^/])(%.[^./]+)$")
  if stem then return stem .. "-" .. n .. ext end
  return path .. "-" .. n
end

-- 仓库根：CLI 入口给的是 Windows 绝对路径；直接跑本模块时用接缝按当前目录绝对化。
local function repo_root(env)
  local root = env and env.repo_root
  if root and (root:match("^%a:/") or root:sub(1, 2) == "//") then return root end
  return assert(seam.absolute("."))
end

-- 相对路径相对仓库根绝对化；已是绝对路径则归一。
local function resolve_out(root, value)
  local path = seam.normalize(value)
  if path:match("^%a:/") or path:sub(1, 2) == "//" then return path end
  return root .. "/" .. path:gsub("^%./", "")
end

-- 取景参数：--rect 优先（只能前台），否则按窗口标题（空串=自动选窗）。
function M.framing(opts)
  if opts.rect then
    local rect, err = M.parse_rect(opts.rect)
    if not rect then return nil, err end
    return { flag = "-Rect", value = opts.rect, rect = rect }
  end
  return { flag = "-Window", value = opts.window }
end

-- 抓屏脚本的 stdout：若干 INFO 行（人读）+ 一行 RESULT=<结果>。
function M.parse_info(body)
  local lines = {}
  for line in tostring(body):gmatch("[^\r\n]+") do
    local info = line:match("^INFO%s+(.*)$")
    if info then lines[#lines + 1] = info end
  end
  return lines, tostring(body):match("RESULT=([^\r\n]*)")
end

-- -List 的 stdout：每个候选一行 WIN <hwnd十进制> <pid> X,Y,W,H <进程名|?> <标题>。
function M.parse_windows(body)
  local list = {}
  for line in tostring(body):gmatch("[^\r\n]+") do
    local hwnd, pid, x, y, w, h, proc, title =
      line:match("^WIN%s+(%d+)%s+(%d+)%s+(%-?%d+),(%-?%d+),(%d+),(%d+)%s+(%S+)%s?(.*)$")
    if hwnd then
      list[#list + 1] = {
        hwnd = math.tointeger(tonumber(hwnd)), pid = math.tointeger(tonumber(pid)),
        x = tonumber(x), y = tonumber(y), w = tonumber(w), h = tonumber(h),
        proc = proc == "?" and "" or proc, title = title,
      }
    end
  end
  return list
end

function M.format_window(index, win)
  return string.format("%d hwnd=0x%X pid=%d rect=%d,%d,%d,%d proc=%s title=%s",
    index, win.hwnd, win.pid, win.x, win.y, win.w, win.h, win.proc, win.title)
end

-- 抓屏前置：pwsh 与抓屏脚本都在。缺失算「外部工具不可用」，由 protect 收成退出码 3。
local function prepare(env)
  local pwsh = seam.which("pwsh")
  if not pwsh then
    exit_code.unavailable("screenshot: 找不到 pwsh。PowerShell 7 需在 PATH 上（pwsh.exe）")
  end
  local root = repo_root(env)
  local script = root .. "/" .. M.SCRIPT
  if not seam.exists(script) then
    exit_code.unavailable("screenshot: 抓屏脚本缺失: " .. script)
  end
  return { pwsh, "-NoProfile", "-File", script }, root
end

-- 选窗参数：给了标题子串按子串，否则 -Auto（编辑器进程）。
local function add_window(argv, opts)
  if opts.window then
    argv[#argv + 1] = "-Window"
    argv[#argv + 1] = opts.window
  else
    argv[#argv + 1] = "-Auto"
  end
end

-- 跑脚本并取 RESULT 行；失败把原因打到 stderr 并返回 nil。
local function run(argv, root, want)
  local code, body = seam.capture({ argv = argv, tmp_dir = root .. "/tmp" })
  local line = tostring(body):match("RESULT=([^\r\n]*)")
  if code ~= 0 or not line or not line:match(want) then
    local reason = line and (line:gsub("^FAIL%s*", "")) or tostring(body)
    io.stderr:write("screenshot: " .. reason .. "\n")
    return nil
  end
  return line, body
end

-- 抓对了没有取决于窗口与通道，把实际取景和通道打给人看；stdout 只留路径给脚本消费。
local function report_shot(line, tag)
  local rest = line:match("^OK%s+%S+%s+(.*)$")
  if not rest then return end
  local label, channel = rest:match("^(.-)%s+(%S+)%s+%S+$")
  io.stderr:write("screenshot: 取景" .. tag .. " " .. (line:match("^OK%s+(%S+)") or "?") .. " " ..
    (label or rest) .. " 通道=" .. (channel == "bg" and "后台" or "桌面合成") .. "\n")
end

local function emit_verified(paths)
  for _, path in ipairs(paths) do
    if not seam.exists(path) then
      io.stderr:write("screenshot: 抓屏脚本声称成功但文件不存在: " .. path .. "\n")
      return exit_code.FAILURE
    end
  end
  for _, path in ipairs(paths) do io.stdout:write(path .. "\n") end
  return exit_code.OK
end

-- 显示路径自检：只问脚本，不抓图；取证前先看清是虚拟屏还是物理屏。
function M.info(opts, env)
  if opts.rect then
    io.stderr:write("screenshot: --info 不能用 --rect；它按窗口判定所在屏\n")
    return exit_code.USAGE
  end
  return exit_code.protect(function()
    local argv, root = prepare(env)
    argv[#argv + 1] = "-Info"
    add_window(argv, opts)
    local result, body = run(argv, root, "^OK%s+INFO%s+.+$")
    if not result then return exit_code.FAILURE end
    for _, line in ipairs((M.parse_info(body))) do
      io.stdout:write("screenshot: " .. line .. "\n")
    end
    return exit_code.OK
  end)
end

-- 只读枚举候选窗口：stdout 每个窗口一行，序号与 --all 的文件后缀对应。
function M.list(opts, env)
  return exit_code.protect(function()
    local argv, root = prepare(env)
    argv[#argv + 1] = "-List"
    add_window(argv, opts)
    local result, body = run(argv, root, "^OK%s+LIST%s+%d+")
    if not result then return exit_code.FAILURE end
    local wins = M.parse_windows(body)
    if #wins == 0 then
      io.stderr:write("screenshot: 没有匹配的可见窗口\n")
    end
    for i, win in ipairs(wins) do io.stdout:write(M.format_window(i, win) .. "\n") end
    return exit_code.OK
  end)
end

local function default_out(root, opts)
  return opts.out and resolve_out(root, opts.out)
    or (root .. "/tmp/screenshot-" .. os.time() .. ".png")
end

-- 一次脚本调用顺序抓全部候选，路径模板里的 {n} 由脚本替换成序号。
local function capture_all(opts, argv, root)
  local out = default_out(root, opts)
  seam.ensure_dir(out:match("^(.*)/[^/]*$") or root)
  argv[#argv + 1] = "-All"
  argv[#argv + 1] = "-Out"
  argv[#argv + 1] = M.indexed_out(out, "{n}")
  add_window(argv, opts)
  if opts.screen then argv[#argv + 1] = "-Screen" end
  local line, body = run(argv, root, "^OK%s+ALL%s+%d+")
  if not line then return exit_code.FAILURE end
  local shots = {}
  for shot in tostring(body):gmatch("SHOT=([^\r\n]*)") do shots[#shots + 1] = shot end
  local count = math.tointeger(tonumber(line:match("^OK%s+ALL%s+(%d+)")))
  if count == 0 or count ~= #shots then
    io.stderr:write("screenshot: 抓屏脚本报告 " .. count .. " 张，实际回执 " .. #shots .. " 张\n")
    return exit_code.FAILURE
  end
  local paths = {}
  for i, shot in ipairs(shots) do
    report_shot(shot, "[" .. i .. "]")
    paths[i] = M.indexed_out(out, i)
  end
  return emit_verified(paths)
end

function M.main(args, env)
  local opts, err = M.parse(args or {})
  if not opts then
    io.stderr:write("screenshot: " .. err .. "\n\n" .. M.usage())
    return exit_code.USAGE
  end
  if opts.help then
    io.stdout:write(M.usage())
    return exit_code.OK
  end

  if opts.info then return M.info(opts, env) end
  if opts.list then return M.list(opts, env) end

  local frame, frame_err = M.framing(opts)
  if not frame then
    io.stderr:write("screenshot: " .. frame_err .. "\n")
    return exit_code.USAGE
  end

  return exit_code.protect(function()
    local argv, root = prepare(env)
    if opts.all then return capture_all(opts, argv, root) end

    local out = default_out(root, opts)
    seam.ensure_dir(out:match("^(.*)/[^/]*$") or root)
    argv[#argv + 1] = "-Out"
    argv[#argv + 1] = out
    if frame.rect then
      -- 屏幕矩形没有窗口可抓，桌面合成是唯一通道。
      argv[#argv + 1] = "-Rect"
      argv[#argv + 1] = frame.value
      argv[#argv + 1] = "-Screen"
    else
      if opts.hwnd then
        argv[#argv + 1] = "-Hwnd"
        argv[#argv + 1] = string.format("%d", opts.hwnd)
      else
        add_window(argv, opts)
      end
      -- --screen 显式要求抓屏幕上显示的样子，缺省是后台抓窗口表面。
      if opts.screen then argv[#argv + 1] = "-Screen" end
    end

    local line = run(argv, root, "^OK")
    if not line then return exit_code.FAILURE end
    report_shot(line, "")
    return emit_verified({ out })
  end)
end

return M
