-- screenshot 子命令：抓桌面合成像素存 PNG（虚拟屏兜底；ADR-0017）。
-- 在仓库根执行 `lua tools/cli.lua screenshot ...`。
--
-- 背景：editor-cli 的 `screenshot game` / `screenshot editor` 走窗口表面抓取（PrintWindow）。
-- 在虚拟显示器上（UU 远程的 GameViewer Virtual Display Adapter 这类）3D 画面只存在于桌面
-- 合成里，窗口表面抓到的永远是黑帧，而且校验会判 FRAME_VALID。本命令改读桌面合成
-- （CopyFromScreen），是虚拟屏上取证游戏画面的入口。
--
-- 前置条件：目标窗口必须真的显示在屏幕上——被别的窗口盖住时，抓到的是遮挡物。
--
-- 进程与文件系统探测只经 tools/seam.lua（唯一接缝）：pwsh 由 seam.which 定位并做一次真实
-- 调用验证，抓屏经 seam.capture{argv} 执行同目录的 screenshot_capture.ps1。
-- 输出落仓库 tmp/（gitignored），路径一律正斜杠 Windows 形式。
local seam = require("tools.seam")
local exit_code = require("tools.exit_code")

local M = {}

M.SCRIPT = "tools/screenshot_capture.ps1"

-- 默认目标窗口：编辑器试玩时游戏画面那层顶层窗口的标题就叫 client。
M.DEFAULT_WINDOW = "client"

function M.usage()
  return table.concat({
    "用法: lua tools/cli.lua screenshot [--window <标题子串> | --rect X,Y,W,H] [--out <文件.png>]",
    "",
    "抓桌面合成像素存 PNG。给虚拟屏用：3D 画面只在桌面合成里，",
    "editor-cli 的 screenshot 走窗口表面抓取，在虚拟屏上拿到的是黑帧。",
    "",
    "选项：",
    "  --window <子串>   取标题包含该子串、面积最大的可见顶层窗口的客户区（缺省 client）",
    "  --rect X,Y,W,H    直接给屏幕矩形，覆盖 --window",
    "  --out <文件.png>  输出路径（缺省 tmp/screenshot-<时间>.png，相对路径相对仓库根）",
    "",
    "前置条件：目标窗口必须显示在屏幕上；被盖住时抓到的是遮挡物，先把窗口切到前台。",
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

-- 取景参数：--rect 优先，否则按标题找窗口（缺省 client）。
function M.framing(opts)
  if opts.rect then
    local rect, err = M.parse_rect(opts.rect)
    if not rect then return nil, err end
    return { flag = "-Rect", value = opts.rect, rect = rect }
  end
  return { flag = "-Window", value = opts.window or M.DEFAULT_WINDOW }
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

    local code, body = seam.capture({
      argv = { pwsh, "-NoProfile", "-File", script, "-Out", out, frame.flag, frame.value },
      tmp_dir = root .. "/tmp",
    })
    local line = tostring(body):match("RESULT=([^\r\n]*)")
    if code ~= 0 or not line or line:sub(1, 2) ~= "OK" then
      local reason = line and (line:gsub("^FAIL%s*", "")) or tostring(body)
      io.stderr:write("screenshot: " .. reason .. "\n")
      return exit_code.FAILURE
    end
    -- 抓对了没有取决于窗口，把实际取景打给人看；stdout 只留路径给脚本消费。
    local geometry, tail = line:match("^OK%s+(%S+)%s+(.*)$")
    if geometry then
      local label = tail:match("^(.-)%s+%S+$") or tail
      io.stderr:write("screenshot: 取景 " .. geometry .. " " .. label .. "\n")
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