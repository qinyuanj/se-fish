-- ADR-0044 语义一键核查脚本（宿主机 Lua 5.4，严格只读，不启停编辑器）。
-- 用法（在仓库根执行，需编辑器已处于对应试玩态）：
--   lua .agents/skills/verify-se-fish/scripts/probe_local_mp_run.lua --mode <local-mp|debug-ai> [--instance <id>] [--out <report.md>] [--json]

local M = {}

local function script_repo_root()
  local src = debug.getinfo(1, "S").source
  local path = src:sub(1, 1) == "@" and src:sub(2) or src
  path = path:gsub("\\", "/")
  local root = path:match("^(.*)/%.agents/skills/verify%-se%-fish/scripts/probe_local_mp_run%.lua$")
    or path:match("^(.*)/%.dsh/skills/verify%-se%-fish/scripts/probe_local_mp_run%.lua$")
  return root or "."
end

local REPO_ROOT = script_repo_root()
if not package.path:find(REPO_ROOT .. "/?.lua", 1, true) then
  package.path = REPO_ROOT .. "/?.lua;" .. REPO_ROOT .. "/?/init.lua;" .. package.path
end

local seam = require("tools.seam")
local dkjson = require("dkjson")

function M.usage()
  return table.concat({
    "用法: lua .agents/skills/verify-se-fish/scripts/probe_local_mp_run.lua --mode <local-mp|debug-ai> [--instance <id>] [--out <report.md>] [--json]",
    "",
    "只读核查 ADR-0044 运行时语义（不启停编辑器、不修改游戏状态）。",
    "  --mode <local-mp|debug-ai>  核查模式：local-mp（本地多人多窗口）或 debug-ai（调试插件 AI）",
    "  --instance <id>             多编辑器实例时指定地图名、pid 或端口",
    "  --out <report.md>           将 Markdown 语义核查报告写入文件",
    "  --json                      以 JSON 输出完整结构化结果",
    "  --wait-ms <ms>              exec 提交后等待日志落盘毫秒数（默认 800）",
    "  -h, --help                  显示帮助",
  }, "\n") .. "\n"
end

function M.parse_args(argv)
  local opts = { mode = nil, instance = nil, out = nil, json = false, wait_ms = 800 }
  local i = 1
  while i <= #(argv or {}) do
    local a = argv[i]
    if a == "-h" or a == "--help" then
      opts.help = true
    elseif a == "--json" then
      opts.json = true
    elseif a == "--mode" or a == "--instance" or a == "--editor-instance" or a == "--out" or a == "--wait-ms" then
      local v = argv[i + 1]
      if v == nil or v:match("^%-") then
        return nil, a .. " 缺少参数值"
      end
      if a == "--mode" then
        if v ~= "local-mp" and v ~= "debug-ai" then
          return nil, "--mode 只接受 local-mp 或 debug-ai: " .. tostring(v)
        end
        opts.mode = v
      elseif a == "--out" then
        opts.out = v
      elseif a == "--wait-ms" then
        local n = tonumber(v)
        if not n or n < 0 then return nil, "--wait-ms 须为非负整数: " .. tostring(v) end
        opts.wait_ms = math.floor(n)
      else
        opts.instance = v
      end
      i = i + 1
    else
      return nil, "未知参数: " .. tostring(a)
    end
    i = i + 1
  end
  if not opts.help and not opts.mode then
    return nil, "必须指定 --mode local-mp 或 --mode debug-ai"
  end
  return opts
end

function M.decode(value)
  local text = tostring(value or ""):gsub("%%(%x%x)", function(hex)
    return string.char(tonumber(hex, 16))
  end)
  if text == "nil" then return nil end
  if text == "true" then return true end
  if text == "false" then return false end
  if text:match("^%-?%d+$") then return tonumber(text) end
  return text
end

function M.parse_kv_line(line, prefix)
  local pos = tostring(line or ""):find(prefix, 1, true)
  if not pos then return nil end
  local tail = tostring(line):sub(pos + #prefix)
  local kind, rest = tail:match("^%s+(%u+)%s*(.*)$")
  if not kind then return nil end
  local fields = {}
  for k, v in rest:gmatch("([%w_]+)=([^%s]+)") do
    fields[k] = M.decode(v)
  end
  return kind, fields
end

function M.parse_server_log(raw, nonce)
  local prefix = "PROBE_MP_SRV_" .. tostring(nonce)
  local data = { tag = prefix, summary = nil, players = {}, conflicts = {}, eggy_samples = {}, complete = false }
  for line in tostring(raw or ""):gmatch("[^\r\n]+") do
    local kind, fields = M.parse_kv_line(line, prefix)
    if kind == "SUMMARY" then
      data.summary = fields
    elseif kind == "PLAYER" then
      if fields.uid ~= nil then fields.uid = tostring(fields.uid) end
      data.players[#data.players + 1] = fields
    elseif kind == "CONFLICT" then
      data.conflicts[#data.conflicts + 1] = fields
    elseif kind == "EGGY" then
      data.eggy_samples[#data.eggy_samples + 1] = fields
    elseif kind == "END" then
      data.complete = true
    end
  end
  return data
end

function M.parse_client_log(raw, nonce)
  local prefix = "PROBE_MP_CLI_" .. tostring(nonce)
  local data = { tag = prefix, client = nil, visible = {}, complete = false }
  for line in tostring(raw or ""):gmatch("[^\r\n]+") do
    local kind, fields = M.parse_kv_line(line, prefix)
    if kind == "CLIENT" then
      if fields.local_uid ~= nil then fields.local_uid = tostring(fields.local_uid) end
      if fields.party_self_uid ~= nil then fields.party_self_uid = tostring(fields.party_self_uid) end
      data.client = fields
    elseif kind == "VISIBLE" then
      if fields.uid ~= nil then fields.uid = tostring(fields.uid) end
      data.visible[#data.visible + 1] = fields
    elseif kind == "END" then
      data.complete = true
    end
  end
  return data
end

function M.parse_screenshot_list(raw)
  local windows = {}
  for line in tostring(raw or ""):gmatch("[^\r\n]+") do
    local idx, hwnd, pid, rect, proc, title =
      line:match("^%s*(%d+)%s+hwnd=(%S+)%s+pid=(%d+)%s+rect=(%S+)%s+proc=(%S+)%s+title=(.*)$")
    if idx then
      windows[#windows + 1] = {
        index = tonumber(idx),
        hwnd = hwnd,
        pid = tonumber(pid),
        rect = rect,
        proc = proc,
        title = title,
      }
    end
  end
  return windows
end

local function item(id, title, status, detail)
  return { id = id, title = title, status = status, detail = detail }
end

function M.evaluate(mode, server, client_runs, windows)
  local checks = {}
  local s = server and server.summary or nil
  local win_count = type(windows) == "table" and #windows or 0

  if not s then
    checks[#checks + 1] = item("server_probe", "服务端只读探针回读", "UNOBSERVED", "未从日志读取到 PROBE_MP_SRV SUMMARY")
    return { mode = mode, checks = checks, server = server, client_runs = client_runs or {}, windows = windows or {} }
  end

  local players = tonumber(s.players) or 0
  if mode == "local-mp" then
    checks[#checks + 1] = item(
      "players_multi",
      "多窗口各自进入 Players:GetPlayers()",
      players >= 2 and "CONFIRMED" or "MISMATCH",
      string.format("Players=%d (期望 >=2)", players)
    )
  else
    local non_player = tonumber(s.eggy_non_player) or 0
    if players >= 2 then
      checks[#checks + 1] = item(
        "ai_in_players",
        "调试插件 添加AI 是否进入 Players",
        "CONFIRMED",
        string.format("Players=%d, eggy_non_player=%s", players, tostring(s.eggy_non_player))
      )
    elseif players == 1 and non_player > 0 then
      checks[#checks + 1] = item(
        "ai_in_players",
        "调试插件 添加AI 是否进入 Players",
        "MISMATCH",
        string.format("Players=1 但场景存在 %d 个非 Player EggyUnit（AI 未进入 Players）", non_player)
      )
    else
      checks[#checks + 1] = item(
        "ai_in_players",
        "调试插件 添加AI 是否进入 Players",
        "UNOBSERVED",
        string.format("Players=%d, eggy_scan=%s, eggy_non_player=%s（请确认已点击添加AI）",
          players, tostring(s.eggy_scan), tostring(s.eggy_non_player))
      )
    end
  end

  if players >= 2 then
    local dup = tonumber(s.dup_uid) or 0
    checks[#checks + 1] = item(
      "unique_uid",
      "在线玩家 UserId 唯一",
      dup == 0 and "CONFIRMED" or "MISMATCH",
      string.format("players=%d, dup_uid=%d", players, dup)
    )
    local missing = tonumber(s.save_key_missing) or 0
    local conflicts = tonumber(s.save_key_conflicts) or 0
    checks[#checks + 1] = item(
      "unique_save_key",
      "SaveHost 存档键独立且无冲突",
      (missing == 0 and conflicts == 0) and "CONFIRMED" or "MISMATCH",
      string.format("save_keys=%s, missing=%d, conflicts=%d", tostring(s.save_keys), missing, conflicts)
    )
  else
    checks[#checks + 1] = item("unique_uid", "在线玩家 UserId 唯一", "UNOBSERVED", "在线玩家不足 2 人")
    checks[#checks + 1] = item("unique_save_key", "SaveHost 存档键独立且无冲突", "UNOBSERVED", "在线玩家不足 2 人")
  end

  if s.runtime_consistent == true then
    checks[#checks + 1] = item(
      "runtime_consistent",
      "ServerRuntime 在线表与 Players 一致",
      "CONFIRMED",
      string.format("players=%d, rt_current=%s, rt_trees=%s", players, tostring(s.rt_current), tostring(s.rt_trees))
    )
  elseif s.runtime_consistent == false then
    checks[#checks + 1] = item(
      "runtime_consistent",
      "ServerRuntime 在线表与 Players 一致",
      "MISMATCH",
      string.format("players=%d, rt_current=%s, rt_trees=%s", players, tostring(s.rt_current), tostring(s.rt_trees))
    )
  else
    checks[#checks + 1] = item(
      "runtime_consistent",
      "ServerRuntime 在线表与 Players 一致",
      "UNOBSERVED",
      string.format("runtime=%s, rt_current=%s", tostring(s.runtime), tostring(s.rt_current))
    )
  end

  local runs = client_runs or {}
  if mode == "local-mp" then
    if #runs == 0 then
      checks[#checks + 1] = item("client_player_routing", "exec --platform client --player 定向路由", "UNOBSERVED", "未执行客户端定向探针")
    else
      local matched, observed, pairs_desc = 0, 0, {}
      for _, r in ipairs(runs) do
        local actual = r.client and r.client.local_uid or nil
        if actual ~= nil then observed = observed + 1 end
        if actual ~= nil and tostring(actual) == tostring(r.target_uid) then matched = matched + 1 end
        pairs_desc[#pairs_desc + 1] = tostring(r.target_uid) .. "->" .. tostring(actual or "nil")
      end
      local status = observed == 0 and "UNOBSERVED" or (matched == #runs and "CONFIRMED" or "MISMATCH")
      checks[#checks + 1] = item(
        "client_player_routing",
        "exec --platform client --player 定向路由",
        status,
        string.format("命中 %d/%d (%s)", matched, #runs, table.concat(pairs_desc, ", "))
      )
    end
    checks[#checks + 1] = item(
      "multi_window_screenshot",
      "screenshot --list 识别多客户端窗口",
      win_count >= 2 and "CONFIRMED" or (win_count == 1 and "MISMATCH" or "UNOBSERVED"),
      string.format("检测到 %d 个可见客户端窗口", win_count)
    )
  else
    local first = runs[1]
    if first and first.client then
      checks[#checks + 1] = item(
        "client_local_player",
        "客户端 LocalPlayer 与 ClientStore 快照",
        "CONFIRMED",
        string.format("local_uid=%s, name=%s, store=%s, zone=%s, pos=%s（切换AI前后各跑一次对照）",
          tostring(first.client.local_uid), tostring(first.client.local_name),
          tostring(first.client.store), tostring(first.client.zone_id), tostring(first.client.pos))
      )
    else
      checks[#checks + 1] = item("client_local_player", "客户端 LocalPlayer 与 ClientStore 快照", "UNOBSERVED", "未读到客户端探针输出")
    end
    checks[#checks + 1] = item(
      "window_capture",
      "screenshot --list 窗口概况",
      win_count >= 1 and "CONFIRMED" or "UNOBSERVED",
      string.format("检测到 %d 个可见窗口", win_count)
    )
  end

  return {
    mode = mode,
    checks = checks,
    server = server,
    client_runs = runs,
    windows = windows or {},
  }
end

function M.render_markdown(report)
  local lines = {
    "# ADR-0044 运行时语义核查报告",
    "",
    "- 模式：" .. tostring(report.mode),
    "- 会话：" .. tostring(report.play_session or "-"),
    "",
    "| 检查项 | 状态 | 观测明细 |",
    "| --- | --- | --- |",
  }
  for _, c in ipairs(report.checks or {}) do
    lines[#lines + 1] = string.format("| %s (`%s`) | %s | %s |", c.title, c.id, c.status, tostring(c.detail or ""))
  end
  if report.server and #(report.server.players or {}) > 0 then
    lines[#lines + 1] = ""
    lines[#lines + 1] = "## 在线 Player 列表"
    lines[#lines + 1] = ""
    for _, p in ipairs(report.server.players) do
      lines[#lines + 1] = string.format("- #%s uid=%s name=%s save_key=%s (%s) party=%s in_runtime=%s",
        tostring(p.idx), tostring(p.uid), tostring(p.name), tostring(p.save_key),
        tostring(p.save_key_source), tostring(p.party), tostring(p.in_runtime))
    end
  end
  if #(report.windows or {}) > 0 then
    lines[#lines + 1] = ""
    lines[#lines + 1] = "## 可见客户端窗口"
    lines[#lines + 1] = ""
    for _, w in ipairs(report.windows) do
      lines[#lines + 1] = string.format("- #%s hwnd=%s pid=%s rect=%s proc=%s title=%s",
        tostring(w.index), tostring(w.hwnd), tostring(w.pid), tostring(w.rect), tostring(w.proc), tostring(w.title))
    end
  end
  return table.concat(lines, "\n") .. "\n"
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
  if seam.exists(candidate) then return candidate end
  return nil
end

local function run_cli(cli, instance, subargs)
  local argv = { cli }
  if instance and instance ~= "" then
    argv[#argv + 1] = "--editor-instance"
    argv[#argv + 1] = instance
  end
  for _, a in ipairs(subargs) do argv[#argv + 1] = a end
  return seam.capture({ argv = argv, cwd = REPO_ROOT })
end

local function read_text(path)
  local f = io.open(path, "rb")
  if not f then return nil end
  local text = f:read("*a")
  f:close()
  return text
end

local function write_text(path, content)
  seam.ensure_dir(path:match("^(.*)/[^/]*$") or REPO_ROOT)
  local f = assert(io.open(path, "wb"))
  f:write(content)
  f:close()
end

local function sleep_ms(ms)
  if ms <= 0 then return end
  local pwsh = seam.which("pwsh")
  if pwsh then
    seam.capture({ argv = { pwsh, "-NoProfile", "-Command", "Start-Sleep -Milliseconds " .. tostring(ms) }, cwd = REPO_ROOT })
  end
end

local function run_probe_file(cli, instance, play_session, platform, target_uid, source_path, prefix, nonce, wait_ms)
  local body = assert(read_text(source_path), "无法读取探针文件: " .. source_path)
  local tmp_file = seam.normalize(REPO_ROOT) .. "/tmp/probe_mp_" .. platform .. "_" .. nonce .. ".lua"
  write_text(tmp_file, "local PROBE_MP_NONCE = '" .. nonce .. "'\n" .. body)
  local sub = { "exec", "--platform", platform, "--file", tmp_file, "--json" }
  if target_uid and target_uid ~= "" then
    table.insert(sub, 4, "--player")
    table.insert(sub, 5, tostring(target_uid))
  end
  local exec_code, exec_out = run_cli(cli, instance, sub)
  sleep_ms(wait_ms)
  local grep_args = { "log", "grep", prefix .. nonce, "--max-matches", "500" }
  if play_session and play_session ~= "" then
    grep_args[#grep_args + 1] = "--play-session"
    grep_args[#grep_args + 1] = play_session
  end
  local _, grep_out = run_cli(cli, nil, grep_args)
  os.remove(tmp_file)
  return exec_code, exec_out, grep_out
end

function M.run(opts)
  local cli = editor_cli_path()
  if not cli then return nil, "未找到 editor-cli.exe" end

  local st_code, st_out = run_cli(cli, opts.instance, { "status", "--json" })
  local st = parse_json_object(st_out)
  if st_code ~= 0 or not st or st.running ~= true then
    return nil, "编辑器未运行或不可连接"
  end
  if st.in_game_runtime ~= true then
    return nil, "当前编辑器未处于试玩态（editor_state=" .. tostring(st.editor_state) .. "），请先从编辑器进入对应试玩模式"
  end

  local play_session = st.play_session or ""
  local base_nonce = tostring(os.time()) .. "_" .. tostring(math.random(1000, 9999))
  local scripts_dir = seam.normalize(REPO_ROOT) .. "/.agents/skills/verify-se-fish/scripts"

  local _, _, srv_raw = run_probe_file(
    cli, opts.instance, play_session, "server", nil,
    scripts_dir .. "/probe_local_mp_server.lua", "PROBE_MP_SRV_", base_nonce, opts.wait_ms
  )
  local server_data = M.parse_server_log(srv_raw, base_nonce)

  local client_runs = {}
  if opts.mode == "local-mp" and #server_data.players > 0 then
    for idx, p in ipairs(server_data.players) do
      local cnonce = base_nonce .. "_c" .. tostring(idx)
      local _, _, cli_raw = run_probe_file(
        cli, opts.instance, play_session, "client", p.uid,
        scripts_dir .. "/probe_local_mp_client.lua", "PROBE_MP_CLI_", cnonce, opts.wait_ms
      )
      local parsed = M.parse_client_log(cli_raw, cnonce)
      parsed.target_uid = p.uid
      client_runs[#client_runs + 1] = parsed
    end
  else
    local cnonce = base_nonce .. "_c0"
    local _, _, cli_raw = run_probe_file(
      cli, opts.instance, play_session, "client", nil,
      scripts_dir .. "/probe_local_mp_client.lua", "PROBE_MP_CLI_", cnonce, opts.wait_ms
    )
    local parsed = M.parse_client_log(cli_raw, cnonce)
    parsed.target_uid = nil
    client_runs[#client_runs + 1] = parsed
  end

  local _, sc_out = seam.capture({ argv = { "lua", "tools/cli.lua", "screenshot", "--list" }, cwd = REPO_ROOT })
  local windows = M.parse_screenshot_list(sc_out)

  local report = M.evaluate(opts.mode, server_data, client_runs, windows)
  report.play_session = play_session
  return report
end

function M.main(argv)
  local opts, err = M.parse_args(argv or {})
  if not opts then
    io.stderr:write("probe_local_mp_run: " .. err .. "\n\n" .. M.usage())
    return 2
  end
  if opts.help then
    io.stdout:write(M.usage())
    return 0
  end
  local report, run_err = M.run(opts)
  if not report then
    io.stderr:write("probe_local_mp_run: " .. tostring(run_err) .. "\n")
    return 1
  end
  local md = M.render_markdown(report)
  if opts.out then
    local out_path = seam.normalize(opts.out)
    if not out_path:match("^%a:/") then out_path = seam.normalize(REPO_ROOT) .. "/" .. out_path end
    write_text(out_path, md)
  end
  if opts.json then
    io.stdout:write(dkjson.encode(report, { indent = true }) .. "\n")
  else
    io.stdout:write(md)
  end
  return 0
end

local is_main = debug.getinfo(3) == nil
if is_main then
  os.exit(M.main(arg))
end

return M
