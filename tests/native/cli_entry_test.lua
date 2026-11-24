-- tools/cli.lua 的进程边界（#145 接缝一；ADR-0017 Windows native）：真实以子进程执行
-- \`lua tools/cli.lua\`，不打桩，只断言退出码与 stdout / stderr 的关键文案。
-- 子进程清空 LUA_PATH / LUA_INIT（并清掉可能从调用方 shell 泄漏的 PWD），证明模块搜索路径
-- 来自入口脚本自己推导的仓库根，而不是调用方的环境或当前目录。
-- 子进程用 tests.support.interpreter 定位「启动 busted 的那个 lua 5.4」，不靠 PATH 猜 lua。
local fs = require("tests.support.fs_fixture")
local seam = require("tools.seam")
local interpreter = require("tests.support.interpreter")

local REPO = fs.repo_root()
local CLI = REPO .. "/tools/cli.lua"
local ROOT = fs.temp_dir()
local OUT, ERR = ROOT .. "/out", ROOT .. "/err"
local LUA = interpreter.path()

-- 在 dir 里跑 \`<lua> <cli> args...\`，返回退出码、stdout、stderr。
local function cli(args, opts)
  opts = opts or {}
  local argv = { opts.lua or LUA, opts.cli or CLI }
  for i, a in ipairs(args) do argv[#argv + 1] = a end
  fs.mkdirp(ROOT)
  -- 清空路径/初始化相关环境：模块路径只能由入口自己推导；PWD 一并清掉，
  -- 免得调用方 shell（如 MSYS 的 /d/... 形式）把入口的路径推导污染成非法路径。
  local env = {
    LUA_PATH = "", LUA_PATH_5_4 = "", LUA_INIT = "", LUA_INIT_5_4 = "", PWD = "",
  }
  local code = seam.spawn({
    argv = argv,
    cwd = opts.dir or REPO,
    env = env,
    stdout = OUT,
    stderr = ERR,
  })
  return code, fs.slurp(OUT) or "", fs.slurp(ERR) or ""
end

-- 帮助与错误文案里不得再出现旧口径的字样（lua5.4 / WSL / interop）。
local function assert_no_legacy_wording(text)
  for _, word in ipairs({ "lua5.4", "WSL", "interop" }) do
    assert.is_nil(text:find(word, 1, true), "文案仍含旧口径字样: " .. word .. "\n" .. text)
  end
end

describe("TestCliEntryInterpreter", function()
  after_each(function() fs.rmrf(ROOT) end)

  -- 入口在做任何事之前就拒绝非 5.4 解释器，并告诉人该用 lua。
  -- 本机没有 5.4 以外的 lua 可执行，所以造一个 .cmd 垫片：先用 -e 把 _VERSION 改成 5.1，
  -- 再把脚本与参数原样转给真实 lua；guard 仍在真实进程边界上被验证。
  it("test_non_54_interpreter_exits_1_with_hint", function()
    fs.mkdirp(ROOT)
    local shim = ROOT .. "/lua51.cmd"
    local content = '@echo off\r\n"' .. LUA .. '" -e "_VERSION=' .. "'" .. 'Lua 5.1' .. "'" .. '" %*\r\n'
    fs.write_file(shim, content)
    local code, out, err = cli({ "--help" }, { lua = shim })
    assert.are.equal(1, code, out .. err)
    assert.matches("需要 Lua 5.4", err, 1, true)
    assert.matches("请用 lua tools/cli.lua", err, 1, true)
    assert.are.equal("", out)
  end)
end)

-- --help 里「子命令」段每行形如「  <名字>  <说明>」，到空行结束。
local function help_commands(text)
  local names, inside = {}, false
  for raw in (text .. "\n"):gmatch("([^\n]*)\n") do
    local line = (raw:gsub("\r+$", ""))
    if line:match("^子命令") then
      inside = true
    elseif inside then
      if line == "" then break end
      names[#names + 1] = line:match("^  (%S+)")
    end
  end
  return names
end

describe("TestCliEntryHelp", function()
  local routes = require("tools.cli").commands
  after_each(function() fs.rmrf(ROOT) end)

  it("test_help_lists_exactly_the_routed_commands", function()
    local code, out, err = cli({ "--help" })
    assert.are.equal(0, code, err)
    local expected = {}
    for i, c in ipairs(routes) do expected[i] = c.name end
    assert.are.same(expected, help_commands(out))
    assert.matches("lua tools/cli.lua <子命令>", out, 1, true)
    assert_no_legacy_wording(out)
  end)

  it("test_help_states_exit_code_contract", function()
    local code, out = cli({ "-h" })
    assert.are.equal(0, code)
    for _, code_text in ipairs({ "0", "1", "2", "3" }) do
      assert.matches("\n  " .. code_text .. " ", out, 1, true)
    end
    assert.matches("外部工具不可用", out, 1, true)
    assert.matches("robocopy", out, 1, true)
    assert_no_legacy_wording(out)
  end)

  it("test_test_subcommand_is_routed", function()
    local code, out, err = cli({ "test", "--help" }, { dir = REPO .. "/tools" })
    assert.are.equal(0, code, err)
    assert.is_truthy(out:find("tools/cli.lua test [fast|full|spec|art]", 1, true))
  end)

  it("test_naming_help_is_routed", function()
    local code, out, err = cli({ "naming", "--help" })
    assert.are.equal(0, code, out .. err)
    assert.matches("lua tools/cli.lua naming --recon", out, 1, true)
  end)

  it("test_unknown_lane_exits_2_through_the_entry", function()
    local code, out, err = cli({ "test", "slow" })
    assert.are.equal(2, code, out .. err)
    assert.matches("可用车道: fast, full, guards, spec, art", err, 1, true)
  end)

  it("test_unknown_subcommand_exits_2", function()
    local code, out, err = cli({ "nope" })
    assert.are.equal(2, code, out .. err)
    assert.matches("未知子命令: nope", err, 1, true)
    assert_no_legacy_wording(err)
  end)

  it("test_every_route_requires_and_has_main", function()
    assert.is_true(#routes > 0)
    for _, c in ipairs(routes) do
      local ok, mod = pcall(require, c.mod)
      assert.is_true(ok, c.name .. ": " .. tostring(mod))
      assert.are.equal("function", type(mod.main), c.name .. " 没有 main")
    end
  end)
end)

describe("TestCliEntryRepoRoot", function()
  after_each(function() fs.rmrf(ROOT) end)

  -- 绝对入口 + 子目录 cwd：仓库根由入口脚本位置推导，不靠当前目录。
  it("test_subcommand_loads_from_a_subdirectory", function()
    local code, out, err = cli({ "blender", "--help" }, { dir = REPO .. "/docs" })
    assert.are.equal(0, code, err)
    assert.is_truthy(out:find("blender", 1, true))
  end)

  -- 另一个目录里用相对路径指向入口（如从别的 worktree 调本检出的 CLI）。
  it("test_relative_entry_path_from_another_directory", function()
    local elsewhere = ROOT .. "/elsewhere"
    fs.mkdirp(elsewhere)
    local code, out, err = cli({ "worktree-init", "--help" },
      { dir = elsewhere, cli = "../../../tools/cli.lua" })
    assert.are.equal(0, code, err)
    assert.is_truthy(out:find("worktree-init", 1, true))
  end)
end)

describe("TestDocsCli", function()
  local docs = require("tools.docs")
  local fixture = require("tests.support.docs_fixture")
  local sha256 = require("tools.sha256")
  local DOCROOT = fs.temp_dir()
  local responses
  local original_which, original_capture, original_rename

  local function run(args)
    local stdout, stderr = {}, {}
    local real_stdout, real_stderr = io.stdout, io.stderr
    io.stdout = { write = function(self, text) stdout[#stdout + 1] = tostring(text); return self end }
    io.stderr = { write = function(self, text) stderr[#stderr + 1] = tostring(text); return self end }
    local ok, code = pcall(docs.main, args, { repo_root = DOCROOT })
    io.stdout, io.stderr = real_stdout, real_stderr
    assert.is_true(ok, tostring(code))
    return code, table.concat(stdout), table.concat(stderr)
  end

  local function cache_file(relative)
    return DOCROOT .. "/.toolcache/se-manual/" .. relative
  end

  before_each(function()
    responses = fixture.responses()
    original_which, original_capture, original_rename = seam.which, seam.capture, os.rename
    seam.which = function(name)
      assert.are.equal("curl", name)
      return "offline-curl"
    end
    seam.capture = function(spec)
      local url = spec.argv[#spec.argv]
      local body = responses[url]
      if body == false then return 22, "模拟 HTTP 失败" end
      if not body then return 22, "夹具没有该 URL: " .. url end
      return 0, body
    end
  end)

  after_each(function()
    seam.which, seam.capture = original_which, original_capture
    os.rename = original_rename
    fs.rmrf(DOCROOT)
  end)

  it("test_sha256_matches_standard_vectors", function()
    assert.are.equal("e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855", sha256.hex(""))
    assert.are.equal("ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad", sha256.hex("abc"))
    assert.are.equal("248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1",
      sha256.hex("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq"))
  end)

  it("test_sync_caches_core_documents_with_traceable_metadata", function()
    local code, out, err = run({ "sync" })
    assert.are.equal(0, code, err)
    for number = 0, 22 do
      local path = cache_file("lua/" .. string.format("%02d", number) .. "-fixture.txt")
      assert.is_true(fs.exists(path), path)
    end
    assert.are.equal(26, #seam.list_files(DOCROOT .. "/.toolcache/se-manual"))

    local tutorial = fs.slurp(cache_file("lua/08-fixture.txt"))
    assert.is_truthy(tutorial:find("source: " .. fixture.SITE .. "lua/08-fixture.html", 1, true))
    assert.matches("fetched_at: %d%d%d%d%-%d%d%-%d%dT%d%d:%d%d:%d%dZ", tutorial)
    assert.matches("sha256: %x+", tutorial)
    assert.matches("client_ready_retry 与 <Server> & Client", tutorial, 1, true)
    assert.is_nil(tutorial:find("<p>", 1, true))

    local changelog = fs.slurp(cache_file("game_api/changelog/changelog_20261119.txt"))
    assert.matches("changelog_version: 20261119", changelog, 1, true)
    local previous_hash = changelog:match("sha256: (%x+)")
    local repeated_code, repeated_out = run({ "sync" })
    assert.are.equal(0, repeated_code)
    assert.matches("内容未变化", repeated_out, 1, true)
    assert.are.equal(previous_hash, fs.slurp(cache_file("game_api/changelog/changelog_20261119.txt")):match("sha256: (%x+)"))
    assert.matches("已刷新元数据", out .. repeated_out, 1, true)
  end)

  it("test_on_demand_api_and_search_use_only_local_official_cache", function()
    assert.are.equal(0, run({ "sync" }))
    local code, out, err = run({ "sync", "api", "RemoteEvent" })
    assert.are.equal(0, code, err)
    local cached = fs.slurp(cache_file("game_api/classes/RemoteEvent.txt"))
    assert.matches("FireServer 参数必须是 <table>。", cached, 1, true)
    assert.matches("RemoteEvent:FireServer%(player%)", cached)

    fs.write_file(DOCROOT .. "/outside/Roblox.txt", "FireServer 来自 Roblox，不应被检索")
    seam.which = function() error("离线检索不应查找 curl") end
    seam.capture = function() error("离线检索不应访问网络") end
    local search_code, search_out, search_err = run({ "search", "fireservice" })
    assert.are.equal(0, search_code, search_err)
    assert.matches("0 条命中", search_out, 1, true)
    search_code, search_out, search_err = run({ "search", "firesERVER" })
    assert.are.equal(0, search_code, search_err)
    assert.matches(".toolcache/se%-manual/game_api/classes/RemoteEvent%.txt:%d+", search_out)
    assert.matches("来源: " .. fixture.REMOTE_EVENT, search_out, 1, true)
    assert.is_nil(search_out:find("Roblox", 1, true))
  end)

  it("test_network_and_parse_failures_preserve_every_old_document", function()
    assert.are.equal(0, run({ "sync" }))
    local before = {}
    for _, relative in ipairs(seam.list_files(DOCROOT .. "/.toolcache/se-manual")) do
      before[relative] = fs.slurp(cache_file(relative))
    end

    responses[fixture.SITE .. "lua/08-fixture.html"] = "<html><body>格式已变化</body></html>"
    local code, _, err = run({ "sync" })
    assert.are.equal(1, code)
    assert.matches("解析失败", err, 1, true)
    assert.matches("旧缓存未被", err, 1, true)
    for relative, body in pairs(before) do assert.are.equal(body, fs.slurp(cache_file(relative)), relative) end

    responses = fixture.responses()
    responses[fixture.SITE .. "lua/22-fixture.html"] = false
    code, _, err = run({ "sync" })
    assert.are.equal(1, code)
    assert.matches("curl 退出码 22", err, 1, true)
    for relative, body in pairs(before) do assert.are.equal(body, fs.slurp(cache_file(relative)), relative) end
  end)

  it("test_write_failure_rolls_back_the_whole_core_batch", function()
    assert.are.equal(0, run({ "sync" }))
    local before = {}
    for _, relative in ipairs(seam.list_files(DOCROOT .. "/.toolcache/se-manual")) do
      before[relative] = fs.slurp(cache_file(relative))
    end
    responses[fixture.SITE .. "lua/00-fixture.html"] = responses[fixture.SITE .. "lua/00-fixture.html"]
      :gsub("第 00 章官方正文", "尚未成功提交的新正文")
    local target = cache_file("lua/08-fixture.txt")
    os.rename = function(source, destination)
      if destination == target and source:match("%.new$") then return nil, "模拟第 08 章替换失败" end
      return original_rename(source, destination)
    end
    local code, _, err = run({ "sync" })
    os.rename = original_rename
    assert.are.equal(1, code)
    assert.matches("模拟第 08 章替换失败", err, 1, true)
    assert.matches("已回滚本批已替换文件", err, 1, true)
    for relative, body in pairs(before) do assert.are.equal(body, fs.slurp(cache_file(relative)), relative) end
  end)

  it("test_missing_cache_and_curl_have_actionable_errors", function()
    local code, _, err = run({ "search", "RemoteEvent" })
    assert.are.equal(1, code)
    assert.matches("请先运行 lua tools/cli.lua docs sync", err, 1, true)

    code, _, err = run({ "sync", "api", "RemoteEvent" })
    assert.are.equal(1, code)
    assert.matches("本地没有 API 总索引", err, 1, true)

    seam.which = function() return nil end
    code, _, err = run({ "sync" })
    assert.are.equal(3, code)
    assert.matches("找不到 curl", err, 1, true)
    assert.are.equal(2, run({ "sync", "unexpected" }))
    assert.are.equal(2, run({ "search" }))
  end)
end)
