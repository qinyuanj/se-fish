-- emmylua 子命令：EmmyLua 诊断门禁（ADR-0038）。
-- 固定 emmylua_check 版本，扫描 client/common/server（排除 tests 与 packages），
-- 与 tools/emmylua_baseline.txt 的「文件+行+诊断码」指纹比对：基线外的新诊断即失败。
-- 退出码：0 通过或基线已收窄 / 1 有基线外诊断或诊断器运行失败 / 2 用法错误或棘轮拒绝 / 3 工具缺失。
-- 进程调用只经 tools/seam.lua；质量口径是诊断型，不含 formatter 与文档生成。
local seam = require("tools.seam")
local exit_code = require("tools.exit_code")

local M = {}

M.VERSION = "0.25.1"
M.RELEASE_URL = "https://github.com/EmmyLuaLs/emmylua-analyzer-rust/releases/download/"
  .. M.VERSION .. "/emmylua_check-win32-x64.zip"
M.CONFIG = ".emmyrc.json"
M.BASELINE = "tools/emmylua_baseline.txt"
-- 门禁扫描范围（ADR-0038）：.emmyrc.json 管诊断规则，这里只管 CLI 门禁范围；
-- in_scope 是解析输出时的兜底，防止忽略参数失效把非业务目录计入。
M.IGNORE = table.concat({
  "tests/**", "**/packages/**", "packages/**", "**/_trigger/**",
  "data/**", "tmp/**", "target/**", ".toolcache/**", "docs/**", "tools/**",
}, ",")

local SCOPE_ROOTS = { client = true, common = true, server = true }

function M.usage()
  return table.concat({
    "用法: lua tools/cli.lua emmylua [--update-baseline]",
    "",
    "用 emmylua_check " .. M.VERSION .. " 扫描 client/common/server（排除 tests 与 packages），",
    "与 " .. M.BASELINE .. " 比对；基线外的新诊断退出码 1。",
    "--update-baseline 只在没有新诊断时收窄基线（棘轮只许减少）；工具缺失退出码 3。",
  }, "\n") .. "\n"
end

local function trim(text)
  return (tostring(text or ""):match("^%s*(.-)%s*$"))
end

function M.parse(args)
  local opts = { mode = "check" }
  for _, a in ipairs(args or {}) do
    if a == "--help" or a == "-h" then
      opts.help = true
    elseif a == "--update-baseline" then
      if opts.mode ~= "check" then return nil, "重复指定 --update-baseline" end
      opts.mode = "update"
    else
      return nil, "未知参数: " .. a
    end
  end
  return opts
end

local function normalize(path)
  local p = tostring(path or ""):gsub("\\", "/")
  return (p:gsub("^%./", ""))
end

local function in_scope(path)
  local root = path:match("^([^/]+)/")
  if not root or not SCOPE_ROOTS[root] then return false end
  if path:find("/packages/", 1, true) or path:find("/_trigger/", 1, true) then return false end
  if path:find("/tests/", 1, true) then return false end
  return true
end

-- 文本输出形如：--- common/foo.lua [1 error] / error: 消息 [code] /   --> common/foo.lua:12:3。
-- 只认 location 行，避免把消息里的路径误判成诊断；路径与盘符统一成仓库内相对正斜杠。
function M.parse_diagnostics(text, root)
  local prefix = normalize(root):gsub("/$", "") .. "/"
  local current, details, seen = {}, {}, {}
  local last_message = ""
  for line in tostring(text or ""):gmatch("[^\r\n]+") do
    local message = line:match("^%s*(%a[%a-]*:.+)")
    if message then last_message = trim(message) end
    local path, lnum = line:match("^%s*%-%->%s*(.-):(%d+):%d+%s*$")
    if path and lnum then
      path = normalize(path)
      if path:find(prefix, 1, true) == 1 then path = path:sub(#prefix + 1) end
      if in_scope(path) then
        local code = last_message:match("%[(%w[%w_-]*)%]%s*$") or "-"
        local fingerprint = path .. ":" .. lnum .. ":" .. code
        if not seen[fingerprint] then
          seen[fingerprint] = true
          current[#current + 1] = fingerprint
          details[fingerprint] = last_message .. " (" .. path .. ":" .. lnum .. ")"
        end
      end
    end
  end
  table.sort(current)
  return current, details
end

function M.read_baseline(root)
  local file = io.open(normalize(root) .. "/" .. M.BASELINE, "r")
  if not file then
    return nil, "缺少基线文件 " .. M.BASELINE .. "，先跑 lua tools/cli.lua emmylua --update-baseline"
  end
  local set, count = {}, 0
  for line in file:lines() do
    local fingerprint = trim(line)
    if fingerprint ~= "" and fingerprint:sub(1, 1) ~= "-" then
      set[fingerprint] = true
      count = count + 1
    end
  end
  file:close()
  return set, nil, count
end

function M.write_baseline(root, current)
  local path = normalize(root) .. "/" .. M.BASELINE
  local file, err = io.open(path, "wb")
  if not file then return nil, err end
  file:write("-- EmmyLua 诊断基线（ADR-0038）：由 lua tools/cli.lua emmylua --update-baseline 写入。\n")
  file:write("-- 逐行格式：相对路径:行号:诊断码；棘轮只许减少，基线外的新诊断由门禁拦住。\n")
  for _, fingerprint in ipairs(current) do file:write(fingerprint, "\n") end
  local ok, close_err = file:close()
  if not ok then return nil, close_err end
  return true
end

local function print_new(new, details)
  io.stderr:write("emmylua: 发现 " .. #new .. " 条基线外诊断：\n")
  for i = 1, math.min(#new, 30) do
    local fingerprint = new[i]
    io.stderr:write("  " .. (details[fingerprint] or fingerprint) .. "\n")
  end
  if #new > 30 then io.stderr:write("  ... 其余 " .. (#new - 30) .. " 条省略\n") end
end

function M.main(args, env)
  local opts, err = M.parse(args or {})
  if not opts then
    io.stderr:write("emmylua: " .. err .. "\n\n" .. M.usage())
    return exit_code.USAGE
  end
  if opts.help then
    io.write(M.usage())
    return exit_code.OK
  end

  local exe = seam.which("emmylua_check")
  if not exe then
    exit_code.unavailable("emmylua: PATH 上找不到 emmylua_check " .. M.VERSION
      .. "；下载预编译包解压入 PATH: " .. M.RELEASE_URL
      .. " ，或执行: cargo install emmylua_check --version " .. M.VERSION .. " --locked")
  end
  local vcode, vout = seam.capture({ argv = { exe, "--version" } })
  if vcode ~= 0 or not tostring(vout):find(M.VERSION, 1, true) then
    exit_code.unavailable("emmylua: 需要 emmylua_check " .. M.VERSION
      .. "，当前: " .. trim(vout))
  end
  local root = normalize((env and env.repo_root) or seam.absolute("."))
  local code, output = seam.capture({
    argv = { exe, ".", "-c", M.CONFIG, "-i", M.IGNORE, "-f", "text" },
    cwd = root,
  })
  local current, details = M.parse_diagnostics(output, root)
  -- 诊断器退出非 0 且一条 location 都没产出，才算运行失败；正常错误诊断也会让 checker 退出 1。
  local has_locations = output:find("-->", 1, true) ~= nil
  if not has_locations and (code ~= 0 or output:find("Failed to load workspace", 1, true) or output:find("Error:", 1, true)) then
    io.stderr:write("emmylua: 诊断器运行失败（退出码 " .. tostring(code) .. "）：\n" .. output)
    return exit_code.FAILURE
  end

  local baseline, b_err, baseline_count = M.read_baseline(root)
  local baseline_missing = baseline == nil and b_err:find("缺少基线文件", 1, true) ~= nil
  local new = {}
  for _, fingerprint in ipairs(current) do
    if not baseline or not baseline[fingerprint] then new[#new + 1] = fingerprint end
  end

  if opts.mode == "update" then
    if baseline_missing then baseline = {} end
    if not baseline_missing and #new > 0 then
      io.stderr:write("emmylua: 拒绝更新基线：" .. #new .. " 条基线外诊断（棘轮只许减少）：\n")
      print_new(new, details)
      return exit_code.USAGE
    end
    local ok, write_err = M.write_baseline(root, current)
    if not ok then
      io.stderr:write("emmylua: 写入基线失败: " .. tostring(write_err) .. "\n")
      return exit_code.FAILURE
    end
    print(string.format("emmylua: 基线已写入 %s（%d 条，原 %s 条）",
      M.BASELINE, #current, tostring(baseline_count or 0)))
    return exit_code.OK
  end

  if not baseline then
    io.stderr:write("emmylua: " .. b_err .. "\n")
    return exit_code.FAILURE
  end
  if #new > 0 then
    print_new(new, details)
    return exit_code.FAILURE
  end
  print(string.format("emmylua: 门禁通过，%d 条存量诊断均在基线内", #current))
  return exit_code.OK
end

return M
