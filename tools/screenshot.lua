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
    "  --info            只报显示路径与判定（虚拟屏 / 非虚拟屏 / 不确定），不抓图；",
    "                    与 --rect 互斥",
    "",
    "成功时 stdout 只输出一行绝对 PNG 路径，退出码 0；找不到窗口或抓屏失败 1；",
    "pwsh 不在 PATH 上时在抓屏前以退出码 3 失败。",
    "",
  }, "\n") .. "\n"
end

-- 解析参数；用法错误返回 nil, 原因。
function M.parse(args)
  local opts = {}
  local i = 1
  while i <= #args do
    local a = args[i]
    if a == "--help" or a == "-h" then
      opts.help = true
    elseif a == "--info" then
      opts.info = true
    elseif a == "--screen" then
      opts.screen = true
    elseif a == "--window" or a == "--rect" or a == "--out" then
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

-- 显示路径自检：只问脚本，不抓图；取证前先看清是虚拟屏还是物理屏。
function M.info(opts, env)
  if opts.rect then
    io.stderr:write("screenshot: --info 不能用 --rect；它按窗口判定所在屏\n")
    return exit_code.USAGE
  end
  return exit_code.protect(function()
    local pwsh = seam.which("pwsh")
    if not pwsh then
      exit_code.unavailable("screenshot: 找不到 pwsh。PowerShell 7 需在 PATH 上（pwsh.exe）")
    end

    local root = repo_root(env)
    local script = root .. "/" .. M.SCRIPT
    if not seam.exists(script) then
      exit_code.unavailable("screenshot: 抓屏脚本缺失: " .. script)
    end

    local argv = { pwsh, "-NoProfile", "-File", script, "-Info" }
    if opts.window then
      argv[#argv + 1] = "-Window"
      argv[#argv + 1] = opts.window
    else
      argv[#argv + 1] = "-Auto"
    end
    local code, body = seam.capture({ argv = argv, tmp_dir = root .. "/tmp" })
    local lines, result = M.parse_info(body)
    local verdict = result and result:match("^OK%s+INFO%s+(.+)$")
    if code ~= 0 or not verdict then
      local reason = (result and result:gsub("^FAIL%s*", "")) or tostring(body)
      io.stderr:write("screenshot: " .. reason .. "\n")
      return exit_code.FAILURE
    end
    for _, line in ipairs(lines) do
      io.stdout:write("screenshot: " .. line .. "\n")
    end
    return exit_code.OK
  end)
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

  if opts.info then
    return M.info(opts, env)
  end

  local frame, frame_err = M.framing(opts)
  if not frame then
    io.stderr:write("screenshot: " .. frame_err .. "\n")
    return exit_code.USAGE
  end

  -- pwsh 缺失与抓屏脚本缺失都算「外部工具不可用」，由 protect 收成退出码 3。
  return exit_code.protect(function()
    local pwsh = seam.which("pwsh")
    if not pwsh then
      exit_code.unavailable("screenshot: 找不到 pwsh。PowerShell 7 需在 PATH 上（pwsh.exe）")
    end

    local root = repo_root(env)
    local script = root .. "/" .. M.SCRIPT
    if not seam.exists(script) then
      exit_code.unavailable("screenshot: 抓屏脚本缺失: " .. script)
    end

    local out = opts.out and resolve_out(root, opts.out)
      or (root .. "/tmp/screenshot-" .. os.time() .. ".png")
    seam.ensure_dir(out:match("^(.*)/[^/]*$") or root)

    local argv = { pwsh, "-NoProfile", "-File", script, "-Out", out }
    if frame.rect then
      -- 屏幕矩形没有窗口可抓，桌面合成是唯一通道。
      argv[#argv + 1] = "-Rect"
      argv[#argv + 1] = frame.value
      argv[#argv + 1] = "-Screen"
    else
      if opts.window then
        argv[#argv + 1] = "-Window"
        argv[#argv + 1] = opts.window
      else
        argv[#argv + 1] = "-Auto"
      end
      -- --screen 显式要求抓屏幕上显示的样子，缺省是后台抓窗口表面。
      if opts.screen then argv[#argv + 1] = "-Screen" end
    end

    local code, body = seam.capture({ argv = argv, tmp_dir = root .. "/tmp" })
    local line = tostring(body):match("RESULT=([^\r\n]*)")
    if code ~= 0 or not line or line:sub(1, 2) ~= "OK" then
      local reason = line and (line:gsub("^FAIL%s*", "")) or tostring(body)
      io.stderr:write("screenshot: " .. reason .. "\n")
      return exit_code.FAILURE
    end
    -- 抓对了没有取决于窗口与通道，把实际取景和通道打给人看；stdout 只留路径给脚本消费。
    local rest = line:match("^OK%s+%S+%s+(.*)$")
    if rest then
      local label, channel = rest:match("^(.-)%s+(%S+)%s+%S+$")
      io.stderr:write("screenshot: 取景 " .. (line:match("^OK%s+(%S+)") or "?") .. " " ..
        (label or rest) .. " 通道=" .. (channel == "bg" and "后台" or "桌面合成") .. "\n")
    end
    if not seam.exists(out) then
      io.stderr:write("screenshot: 抓屏脚本声称成功但文件不存在: " .. out .. "\n")
      return exit_code.FAILURE
    end
    io.stdout:write(out .. "\n")
    return exit_code.OK
  end)
end

return M
