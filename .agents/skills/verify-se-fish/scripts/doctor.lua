-- 只读验证环境体检脚本：检查 Lua 5.4、busted、editor-cli、qa-slot、编辑器/试玩状态、宿主 code diff 与截图通道。
-- 用法（在仓库根执行）：
--   lua .agents/skills/verify-se-fish/scripts/doctor.lua [--instance <地图名|pid|port>] [--json]
-- 退出码：0 = 当前实例可直接驱动（编辑态就绪或试玩态就绪）；1 = 存在阻塞项需先处理。

if _VERSION ~= "Lua 5.4" then
  io.stderr:write("verify-se-fish doctor 需要 Lua 5.4，当前为 " .. tostring(_VERSION) .. "\n")
  os.exit(1)
end

local function script_repo_root()
  local src = debug.getinfo(1, "S").source
  local path = src:sub(1, 1) == "@" and src:sub(2) or src
  path = path:gsub("\\", "/")
  local root = path:match("^(.*)/%.agents/skills/verify%-se%-fish/scripts/doctor%.lua$")
    or path:match("^(.*)/%.dsh/skills/verify%-se%-fish/scripts/doctor%.lua$")
  return root or "."
end

local REPO_ROOT = script_repo_root()
package.path = REPO_ROOT .. "/?.lua;" .. REPO_ROOT .. "/?/init.lua;" .. package.path

local lfs = require("lfs")
local seam = require("tools.seam")
local eggy_ws = require("tools.eggy_workspace")
local dkjson = require("dkjson")

local function is_file(path)
  return type(path) == "string" and lfs.attributes(path, "mode") == "file"
end

local function has_value(list, target)
  if type(list) ~= "table" then return false end
  for _, v in ipairs(list) do
    if v == target then return true end
  end
  return false
end

-- ADR-0044 实证时的 editor-cli 版本：该版本的 play start 仍只起单客户端，
-- 本地多人测试（多窗口）与调试插件 AI 只能从编辑器 UI 触发。版本变化时提示复核是否开放了自动化参数。
local ADR0044_CLI_PIN = "0.20.20"
local MULTIPLAYER_LIVE_NOTE = "ADR-0044: 编辑器 GUI 支持本地多人测试（测试 → 测试页签 → 本地多人测试 → 开始，多独立客户端窗口）"
  .. "与试玩内调试插件 AI（添加AI / 切换AI）；editor-cli " .. ADR0044_CLI_PIN
  .. " 的 play start 仍只起单客户端，尚无对应自动化启动参数，多窗口须在编辑器 UI 手动启动一次"

local function parse_args(argv)
  local opts = { json = false, instance = nil }
  local i = 1
  while i <= #argv do
    local a = argv[i]
    if a == "--json" then
      opts.json = true
    elseif a == "--instance" or a == "--editor-instance" then
      i = i + 1
      opts.instance = argv[i]
    elseif a == "-h" or a == "--help" then
      io.stdout:write(table.concat({
        "用法: lua .agents/skills/verify-se-fish/scripts/doctor.lua [--instance <地图名|pid|port>] [--json]",
        "",
        "只读体检：检查 Lua 5.4、busted、editor-cli 版本、qa-slot、编辑器/试玩就绪态、宿主 code diff 与截图窗口。",
        "退出码：0 = 可驱动；1 = 存在阻塞项。",
      }, "\n") .. "\n")
      os.exit(0)
    else
      io.stderr:write("未知参数: " .. tostring(a) .. "\n")
      os.exit(2)
    end
    i = i + 1
  end
  return opts
end

local function parse_json_object(out)
  if type(out) ~= "string" then return nil end
  local body = out:match("%b{}")
  if not body then return nil end
  local ok, val = pcall(dkjson.decode, body)
  if ok and type(val) == "table" then return val end
  return nil
end

local function editor_cli_path()
  local home = seam.windows_env("USERPROFILE")
  if not home or home == "" then return nil end
  local candidate = seam.normalize(home) .. "/" .. seam.EDITOR_CLI_REL
  if is_file(candidate) then return candidate end
  return nil
end

local function run_cli(cli, instance, subargs, cwd)
  local argv = { cli }
  if instance and instance ~= "" then
    argv[#argv + 1] = "--editor-instance"
    argv[#argv + 1] = instance
  end
  for _, arg in ipairs(subargs) do
    argv[#argv + 1] = arg
  end
  return seam.capture({ argv = argv, cwd = cwd or REPO_ROOT })
end

local function read_qa_slot()
  local f = io.open(REPO_ROOT .. "/common/game_cfg.lua", "rb")
  if not f then return nil, "无法读取 common/game_cfg.lua" end
  local text = f:read("*a")
  f:close()
  local start = text:find("\nGameCfg.Save%s*=%s*{")
  if not start then return nil, "找不到 GameCfg.Save" end
  local finish = text:find("\n}", start + 1, true)
  if not finish then return nil, "GameCfg.Save 块不完整" end
  local section = text:sub(start + 1, finish - 1)
  local slot = section:match("QaSlot%s*=%s*'([^'\r\n]*)'")
  return slot or "", nil
end

local function check_code_diff(cli, instance, ws)
  if not ws then
    return { checked = false, reason = "未解析到宿主目录" }
  end
  -- 必须传 --workspace（不能把 cwd 切到含中文的宿主目录，避免 cmd.exe 代码页路径失败）
  local code, out = run_cli(cli, instance, { "code", "diff", "--workspace", ws }, REPO_ROOT)
  local line = out and out:match("changelist:[^\r\n]*") or nil
  if not line then
    return { checked = false, exit_code = code, reason = "code diff 未返回 changelist", raw = (out or ""):sub(1, 200) }
  end
  local cl = {}
  for k, v in line:gmatch("([%w%-]+)=(%d+)") do cl[k] = tonumber(v) end
  local dirty_non_exempt = {}
  local exempt = {}
  for row in (out or ""):gmatch("[^\r\n]+") do
    local status, path = row:match("^%s*(only%-local|differs|only%-on%-map)%s+(.-)%s*$")
    if not status then
      status, path = row:match("^%s*([%w%-]+)%s+(.-)%s*$")
      if status ~= "only-local" and status ~= "differs" and status ~= "only-on-map" then
        status, path = nil, nil
      end
    end
    if status and path then
      local p = path:gsub("\\", "/")
      if status == "only-local" and (p:match("^unit_scripts/") or p:match("^%.agents/")) then
        exempt[#exempt + 1] = p
      else
        dirty_non_exempt[#dirty_non_exempt + 1] = status .. ":" .. p
      end
    end
  end
  local total_raw = (cl["only-local"] or 0) + (cl["differs"] or 0) + (cl["only-on-map"] or 0)
  local dirty_count = (#dirty_non_exempt > 0 or #exempt > 0) and #dirty_non_exempt or total_raw
  return {
    checked = true,
    clean = dirty_count == 0,
    dirty_count = dirty_count,
    dirty_sample = { table.unpack(dirty_non_exempt, 1, 10) },
    exempt_count = #exempt,
    changelist = cl,
    host_dir = ws,
  }
end

local function main()
  local opts = parse_args(arg)
  local blockers = {}
  local warnings = {}

  local report = {
    lua_version = _VERSION,
    repo_root = seam.normalize(REPO_ROOT),
    busted = { available = false, path = nil },
    editor_cli = { available = false, path = nil, version = nil, adr0044_pin = ADR0044_CLI_PIN },
    host_workspace = { path = nil, error = nil },
    qa_slot = { slot = nil, is_production = false, error = nil },
    editor = { state = "unknown", running = false, map_name = nil, map_id = nil, editor_mode = nil, play_session = nil, instances_count = 0 },
    input_state = { checked = false, success = false, position = nil, state = nil },
    code_diff = { checked = false },
    screenshot = { ok = false, display_mode = nil, summary = nil },
    capabilities = {
      offline_spec_ready = false,
      solo_playtest_ready = false,
      multiplayer_offline_ready = false,
      multiplayer_live_note = MULTIPLAYER_LIVE_NOTE,
    },
    blockers = blockers,
    warnings = warnings,
  }

  -- 1. busted
  local busted_path = seam.which("busted")
  if busted_path then
    report.busted.available = true
    report.busted.path = seam.normalize(busted_path)
    report.capabilities.offline_spec_ready = true
    report.capabilities.multiplayer_offline_ready = true
  else
    warnings[#warnings + 1] = "PATH 上未找到 busted，无法运行离线验收车道（lua tools/cli.lua test spec）"
  end

  -- 2. host workspace & qa-slot
  local ws, ws_err = eggy_ws.resolve()
  report.host_workspace.path = ws
  report.host_workspace.error = ws_err
  if not ws then
    warnings[#warnings + 1] = "宿主目录未定位：" .. tostring(ws_err)
  end

  local slot, slot_err = read_qa_slot()
  report.qa_slot.slot = slot
  report.qa_slot.error = slot_err
  if slot == "" then
    report.qa_slot.is_production = true
    warnings[#warnings + 1] = "GameCfg.Save.QaSlot 为空（正式存档）：试玩前建议先 lua tools/cli.lua qa-slot new && lua tools/cli.lua deploy"
  end

  -- 3. editor-cli
  local cli = editor_cli_path()
  if not cli then
    blockers[#blockers + 1] = "未找到 editor-cli.exe（预期位于 %USERPROFILE%/.eggitor/cli/editor-cli.exe）"
  else
    report.editor_cli.available = true
    report.editor_cli.path = cli
    local _, ver_out = seam.capture({ argv = { cli, "--version" }, cwd = REPO_ROOT })
    local ver = ver_out and ver_out:match("(%d+%.%d+%.%d+)") or nil
    report.editor_cli.version = ver
    if ver and ver ~= ADR0044_CLI_PIN then
      warnings[#warnings + 1] = "editor-cli 版本已变更（当前 " .. ver .. " vs ADR-0044 钉子 " .. ADR0044_CLI_PIN .. "），请复核 play start --help 是否开放了本地多人测试 / 调试插件 AI 的自动化启动参数"
    end

    -- instances
    local _, inst_out = run_cli(cli, nil, { "editor-instances", "list", "--json" })
    local inst_json = parse_json_object(inst_out)
    if inst_json and type(inst_json.instances) == "table" then
      report.editor.instances_count = #inst_json.instances
      if #inst_json.instances > 1 and not opts.instance then
        warnings[#warnings + 1] = "检测到 " .. tostring(#inst_json.instances) .. " 个编辑器实例，驱动命令建议显式传 --editor-instance <pid|port|地图名>"
      end
    end

    -- status
    local st_code, st_out = run_cli(cli, opts.instance, { "status", "--json" })
    local st = parse_json_object(st_out)
    if st_code ~= 0 or not st or st.running ~= true then
      report.editor.state = "not_running"
      blockers[#blockers + 1] = "编辑器未连接或未运行（先运行 lua tools/cli.lua editor open，连接异常按 eggy-se-editor-cli 排查）"
    else
      report.editor.running = true
      report.editor.map_name = st.map_name
      report.editor.map_id = st.map_id
      report.editor.editor_mode = st.editor_mode
      report.editor.play_session = st.play_session
      report.editor.edit_mode = st.edit_mode
      report.editor.in_game_runtime = st.in_game_runtime
      report.editor.editor_state = st.editor_state
      report.editor.ready = st.ready
      report.editor.available_runtimes = st.available_runtimes or {}

      if st.editor_mode ~= "se" then
        blockers[#blockers + 1] = "当前编辑器模式不是 SE（editor_mode=" .. tostring(st.editor_mode) .. "）"
      end
      if st.in_game_runtime == true and st.editor_state == "playing" then
        report.editor.state = "playing"
        local in_code, in_out = run_cli(cli, opts.instance, { "input", "state", "--json" })
        local inp = parse_json_object(in_out)
        report.input_state.checked = true
        if in_code == 0 and inp and inp.success == true then
          report.input_state.success = true
          report.input_state.position = inp.position
          report.input_state.state = inp.state
          report.capabilities.solo_playtest_ready = true
        else
          blockers[#blockers + 1] = "试玩态已开启，但 input state 未返回合法玩家状态（可能仍在加载或重启间隙，稍候重查）"
        end
      elseif st.edit_mode == true and st.ready == true then
        report.editor.state = "edit_ready"
        report.capabilities.solo_playtest_ready = true
      else
        report.editor.state = "transitioning"
        blockers[#blockers + 1] = "编辑器处于过渡态（edit_mode=" .. tostring(st.edit_mode) .. ", in_game_runtime=" .. tostring(st.in_game_runtime) .. ", editor_state=" .. tostring(st.editor_state) .. ", ready=" .. tostring(st.ready) .. "）"
      end

      -- code diff（必须从宿主目录运行）
      if ws and seam.is_dir(ws) then
        report.code_diff = check_code_diff(cli, opts.instance, ws)
        if report.code_diff.checked and not report.code_diff.clean then
          warnings[#warnings + 1] = "宿主目录与地图存在 " .. tostring(report.code_diff.dirty_count) .. " 处非豁免差异，试玩前请跑 lua tools/cli.lua deploy"
        end
      end
    end
  end

  -- 4. screenshot --info
  local sc_code, sc_out = seam.capture({ argv = { "lua", "tools/cli.lua", "screenshot", "--info" }, cwd = REPO_ROOT })
  report.screenshot.exit_code = sc_code
  report.screenshot.summary = sc_out and sc_out:gsub("%s+$", "") or ""
  if sc_code == 0 and sc_out and not sc_out:find("找不到编辑器进程的窗口", 1, true) then
    report.screenshot.ok = true
  else
    warnings[#warnings + 1] = "截图通道未定位到可用编辑器窗口（常见原因：编辑器窗口被最小化 Iconic=True；还原窗口后后台 PrintWindow 即可抓取，无需置前）"
  end

  local ok_exit = (#blockers == 0)
  report.ok = ok_exit

  if opts.json then
    io.stdout:write(dkjson.encode(report, { indent = true }) .. "\n")
  else
    local lines = {
      "=== verify-se-fish doctor ===",
      "结果       : " .. (ok_exit and "READY（可驱动）" or "BLOCKED（存在阻塞项）"),
      "Lua / 离线 : " .. report.lua_version .. " | busted=" .. tostring(report.busted.available),
      "editor-cli : " .. tostring(report.editor_cli.version or "缺失") .. " (ADR-0044 钉子=" .. ADR0044_CLI_PIN .. ")",
      "宿主目录   : " .. tostring(report.host_workspace.path or "未定位"),
      "QA 存档槽  : " .. (report.qa_slot.slot == "" and "<空 / 正式存档>" or tostring(report.qa_slot.slot)),
      "编辑器状态 : " .. report.editor.state
        .. " | map=" .. tostring(report.editor.map_name or "-")
        .. " | mode=" .. tostring(report.editor.editor_mode or "-")
        .. " | play_session=" .. tostring(report.editor.play_session or "-")
        .. " | instances=" .. tostring(report.editor.instances_count),
    }
    if report.input_state.checked then
      local p = report.input_state.position
      local pstr = p and string.format("(%.2f, %.2f, %.2f)", p.x or 0, p.y or 0, p.z or 0) or "-"
      lines[#lines + 1] = "试玩输入   : success=" .. tostring(report.input_state.success) .. " state=" .. tostring(report.input_state.state or "-") .. " pos=" .. pstr
    end
    if report.code_diff.checked then
      lines[#lines + 1] = "代码同步   : " .. (report.code_diff.clean and "CLEAN" or ("DIRTY(" .. tostring(report.code_diff.dirty_count) .. ")")) .. " (host_dir=" .. tostring(report.code_diff.host_dir) .. ")"
    elseif report.code_diff.reason then
      lines[#lines + 1] = "代码同步   : 未校验 (" .. tostring(report.code_diff.reason) .. ")"
    end
    lines[#lines + 1] = "截图通道   : " .. (report.screenshot.ok and "OK" or "WARN（窗口不可见或已最小化）")
    lines[#lines + 1] = "多人提示   : " .. report.capabilities.multiplayer_live_note
    if #blockers > 0 then
      lines[#lines + 1] = "阻塞项:"
      for _, b in ipairs(blockers) do lines[#lines + 1] = "  - [BLOCKER] " .. b end
    end
    if #warnings > 0 then
      lines[#lines + 1] = "警告:"
      for _, w in ipairs(warnings) do lines[#lines + 1] = "  - [WARN] " .. w end
    end
    io.stdout:write(table.concat(lines, "\n") .. "\n")
  end

  os.exit(ok_exit and 0 or 1)
end

main()
