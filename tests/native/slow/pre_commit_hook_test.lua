-- pre-commit hook 的回归护栏（#142、#131 复盘；ADR-0017 Windows native）：接缝是 `git commit`。
-- 每例在 tmp/ 下新建临时 git 仓库，用 fs_fixture（纯 Lua）落盘，复制入库的
-- tools/hooks/pre-commit，把入库的 tools/hooks/shim 装进 hooks 目录（与
-- docs/agents/workflow.md「pre-commit hook」同一份），再断言提交的退出码与输出。
-- hook 由 Git for Windows 自带的 sh 执行（唯一例外），所以断言从 `git commit` 的进程边界打进去。
-- fast 车道经 CLI 调起（#145）：夹具仓库里放入库的 tools/cli.lua、tools/test.lua、tools/exit_code.lua 与
-- tools/seam.lua，hook 执行 `lua tools/cli.lua test fast`，由 CLI 用 seam.which 找 busted。
-- PATH 前插桩 busted.bat：只记录是否被调用及其看到的环境，不真跑 fast。
-- 进程调用统一经 tools.seam 的 spawn；stdout 与 stderr 落不同文件（同一文件在 Git bash 下 2>&1 会 EBUSY）。
local seam = require("tools.seam")
local fs = require("tests.support.fs_fixture")

local REPO = fs.repo_root()
local HOOK = REPO .. "/tools/hooks/pre-commit"
-- hook 经 CLI 跑 fast 所需的入库文件，原样复制进夹具仓库。
local CLI_FILES = { "tools/cli.lua", "tools/test.lua", "tools/exit_code.lua", "tools/seam.lua" }
local ROOT = REPO .. "/tmp/pre-commit-hook-test"
local FAKE = ROOT .. "/repo"
local BIN = ROOT .. "/bin"
local LOG = ROOT .. "/busted.log"

-- 测的就是文档让人装的那一份 shim，不另抄副本。
local SHIM = assert(fs.slurp(REPO .. "/tools/hooks/shim"), "缺 tools/hooks/shim")
local ORIG_PATH = os.getenv("PATH") or ""

-- 桩 busted.bat：--version 有输出（供 seam.which 的一次真实调用验证），普通调用追加一行
-- 调用记录（参数 + 是否看到 GIT_DIR/GIT_INDEX_FILE），以 STUB_BUSTED_RC 退出。
local STUB = table.concat({
  "@echo off",
  'if "%~1"=="--version" ( echo 2.3.0 & exit /b 0 )',
  'set "GD=unset"',
  'if defined GIT_DIR set "GD=%GIT_DIR%"',
  'set "GI=unset"',
  'if defined GIT_INDEX_FILE set "GI=%GIT_INDEX_FILE%"',
  '>>"%STUB_BUSTED_LOG%" echo args=%* GIT_DIR=%GD% GIT_INDEX_FILE=%GI%',
  'echo stub busted: 9 successes / 0 failures / 0 errors / 0 pending : 0.1 seconds',
  'exit /b %STUB_BUSTED_RC%',
}, "\r\n")

local function stub_env(opts)
  opts = opts or {}
  return {
    -- PWD 必须清空：调用方 shell（MSYS）可能导出 POSIX 形式的 PWD，cli.lua 会把它当前缀
    -- 拼到已绝对的仓库根上，导致 test.lua 的 spawn cwd 变成非法路径。同 cli_entry_test。
    PWD = "",
    PATH = opts.path or (BIN .. ";" .. ORIG_PATH),
    STUB_BUSTED_LOG = LOG,
    STUB_BUSTED_RC = tostring((opts.stub and opts.stub.rc) or 0),
  }
end

-- 在夹具仓库里跑一条 git 命令，返回退出码、stdout、stderr（三份分开）。
local function run_git(args, opts)
  local argv = { "git" }
  for _, a in ipairs(args) do argv[#argv + 1] = a end
  local out = ROOT .. "/git.out"
  local err = ROOT .. "/git.err"
  local code = seam.spawn({ argv = argv, cwd = FAKE, env = stub_env(opts), stdout = out, stderr = err })
  return code, (fs.slurp(out) or ""), (fs.slurp(err) or "")
end

local COMMIT_FLAGS = {
  "-c", "user.name=t", "-c", "user.email=t@example.invalid", "-c", "commit.gpgsign=false", "commit", "-q", "-m", "msg",
}

local function commit(opts)
  return run_git(COMMIT_FLAGS, opts)
end

local function stage(...)
  local args = { "add", "--" }
  for _, p in ipairs({ ... }) do args[#args + 1] = p end
  local code, out, err = run_git(args)
  assert(code == 0, out .. err)
end

local function commit_count()
  local _, out = run_git({ "rev-list", "--count", "HEAD" })
  return tonumber(out:match("%d+")) or 0
end

local function write_repo(rel, body)
  fs.write_file(FAKE .. "/" .. rel, body)
end

-- 新仓库：首个提交只含 README（及按需复制的 hook），shim 装在 hooks 目录。
local function seed(opts)
  opts = opts or {}
  fs.rmrf(ROOT)
  fs.mkdirp(FAKE)
  fs.mkdirp(BIN)
  fs.write_file(BIN .. "/busted.bat", STUB)
  write_repo("README.md", "# 夹具\n")
  if opts.with_script ~= false then
    write_repo("tools/hooks/pre-commit", assert(fs.slurp(HOOK)))
    for _, rel in ipairs(CLI_FILES) do
      write_repo(rel, assert(fs.slurp(REPO .. "/" .. rel), "缺 " .. rel))
    end
  end
  local code, out, err = run_git({ "init", "-q", "." })
  assert(code == 0, out .. err)
  code, out, err = run_git({ "add", "-A" })
  assert(code == 0, out .. err)
  code, out, err = run_git(COMMIT_FLAGS)
  assert(code == 0, "临时仓库初始化失败: " .. out .. err)
  fs.write_file(FAKE .. "/.git/hooks/pre-commit", SHIM)
end

local function busted_calls()
  local log = fs.slurp(LOG) or ""
  local calls = {}
  for line in log:gmatch("[^\r\n]+") do calls[#calls + 1] = line end
  return calls
end

-- hook 的工作目录建在 git 目录下（pre-commit.XXXXXX），退出后必须已删除。
local function leftover_workdirs()
  local names = fs.list_dir(FAKE .. "/.git")
  local left = {}
  for _, n in ipairs(names) do
    if n:match("^pre%-commit%.") then left[#left + 1] = n end
  end
  return table.concat(left, ",")
end

-- PATH 去掉桩目录与所有带 busted 的目录，其余（git、sh、lua）照旧。
local function path_without_busted()
  local dirs = {}
  for dir in ORIG_PATH:gmatch("[^;]+") do
    if not fs.exists(dir .. "/busted.bat") and not fs.exists(dir .. "/busted.exe") then
      dirs[#dirs + 1] = dir
    end
  end
  return table.concat(dirs, ";")
end

describe("TestPreCommitHook", function()
  before_each(function() seed() end)
  after_each(function() fs.rmrf(ROOT) end)

  -- 报错指向暂存路径（含空格与中文），而不是 hook 工作目录里的临时 blob 名。
  it("test_staged_syntax_error_blocks_with_staged_path", function()
    write_repo("common/探针 坏.lua", "local x =\nreturn x\n")
    stage("common/探针 坏.lua")
    local code, out, err = commit()
    local output = out .. err
    assert.are_not.equal(0, code, output)
    assert.matches("loadfile 失败: common/探针 坏.lua:2:", output, 1, true)
    assert.is_nil(output:find("blob", 1, true), output)
    assert.matches("提交已拦下", output, 1, true)
    assert.are.equal(1, commit_count())
    assert.are.equal(0, #busted_calls())
    assert.are.equal("", leftover_workdirs())
  end)

  it("test_broken_worktree_with_good_stage_passes", function()
    write_repo("a.lua", "return 1\n")
    stage("a.lua")
    write_repo("a.lua", "return return\n")
    local code, out, err = commit()
    assert.are.equal(0, code, out .. err)
    assert.are.equal(2, commit_count())
  end)

  it("test_broken_stage_with_good_worktree_blocks", function()
    write_repo("a.lua", "return return\n")
    stage("a.lua")
    write_repo("a.lua", "return 1\n")
    local code, out, err = commit()
    assert.are_not.equal(0, code, out .. err)
    assert.matches("loadfile 失败: a.lua:1:", out .. err, 1, true)
    assert.are.equal(1, commit_count())
  end)

  it("test_docs_only_commit_skips_busted", function()
    write_repo("docs/note.md", "# 只改文档\n")
    stage("docs/note.md")
    local code, out, err = commit()
    assert.are.equal(0, code, out .. err)
    assert.are.equal(0, #busted_calls(), out .. err)
    assert.are.equal(2, commit_count())
  end)

  -- 跑的是 fast 车道，且 git 导出给 hook 的 GIT_DIR / GIT_INDEX_FILE 不漏给 busted。
  it("test_lua_change_runs_fast_lane_without_git_env", function()
    write_repo("a.lua", "return 1\n")
    stage("a.lua")
    local code, out, err = commit()
    local output = out .. err
    assert.are.equal(0, code, output)
    local calls = busted_calls()
    assert.are.equal(1, #calls, output)
    assert.is_truthy(calls[1]:find("--run=fast", 1, true), calls[1])
    assert.is_truthy(calls[1]:find("GIT_DIR=unset", 1, true), calls[1])
    assert.is_truthy(calls[1]:find("GIT_INDEX_FILE=unset", 1, true), calls[1])
    assert.matches("pre-commit: lua tools/cli.lua test fast", output, 1, true)
    assert.matches("9 successes / 0 failures", output, 1, true)
    assert.are.equal(2, commit_count())
  end)

  -- commit -a 时 git 把 GIT_INDEX_FILE 指向临时索引，最容易漏进子进程。
  it("test_commit_all_does_not_leak_index_to_busted", function()
    write_repo("a.lua", "return 1\n")
    stage("a.lua")
    assert.are.equal(0, (commit()))
    write_repo("a.lua", "return 2\n")
    local code, out, err = run_git({
      "-c", "user.name=t", "-c", "user.email=t@example.invalid", "-c", "commit.gpgsign=false", "commit", "-q", "-a", "-m", "all",
    })
    assert.are.equal(0, code, out .. err)
    local calls = busted_calls()
    assert.are.equal(2, #calls, out .. err)
    assert.is_truthy(calls[2]:find("GIT_INDEX_FILE=unset", 1, true), calls[2])
  end)

  it("test_deleting_lua_runs_busted", function()
    write_repo("a.lua", "return 1\n")
    stage("a.lua")
    assert.are.equal(0, (commit()))
    local code, out, err = run_git({ "rm", "-q", "a.lua" })
    assert.are.equal(0, code, out .. err)
    code, out, err = commit()
    assert.are.equal(0, code, out .. err)
    assert.are.equal(2, #busted_calls(), out .. err)
  end)

  it("test_busted_config_change_runs_busted", function()
    write_repo(".busted", "return {}\n")
    stage(".busted")
    local code, out, err = commit()
    assert.are.equal(0, code, out .. err)
    assert.are.equal(1, #busted_calls(), out .. err)
  end)

  it("test_failing_fast_lane_blocks_with_output", function()
    write_repo("a.lua", "return 1\n")
    stage("a.lua")
    local code, out, err = commit({ stub = { rc = 1 } })
    local output = out .. err
    assert.are_not.equal(0, code, output)
    -- hook 通过 cat 转出的 busted 输出在 Git bash + cmd 文件句柄下会 EBUSY（非 hook 逻辑问题），
    -- 因此以桩日志证明 fast 车道确实跑过、并以 hook 自带的 echo 证明退出码 1 的归因。
    local calls = busted_calls()
    assert.are.equal(1, #calls, output)
    assert.is_truthy(calls[1]:find("--run=fast", 1, true), calls[1])
    assert.matches("退出码 1", output, 1, true)
    assert.are.equal(1, commit_count())
    assert.are.equal("", leftover_workdirs())
  end)

  it("test_missing_busted_blocks", function()
    write_repo("a.lua", "return 1\n")
    stage("a.lua")
    local code, out, err = commit({ path = path_without_busted() })
    local output = out .. err
    assert.are_not.equal(0, code, output)
    assert.matches("busted 不可用", output, 1, true)
    assert.matches("退出码 3", output, 1, true)
    assert.matches("install busted", output, 1, true)
    assert.are.equal(0, #busted_calls())
    assert.are.equal(1, commit_count())
  end)

  -- 信号路径（hook 里的 trap 'exit 1' 在收到 HUP/INT/TERM 时清理并退出）靠 POSIX 信号，
  -- Windows 原生没有可移植的方式向 Git for Windows 的 sh 投递信号。hook 逻辑未改，这里只
  -- 保留为 pending，留待有 POSIX 环境时执行。
  for _, sig in ipairs({ "INT", "TERM" }) do
    pending("test_signal_" .. sig .. "_aborts_commit_and_cleans_workdir (Windows 原生无法投递 POSIX 信号，pending)", function()
      error("unreachable")
    end)
  end
end)

describe("TestPreCommitShim", function()
  after_each(function() fs.rmrf(ROOT) end)

  -- 旧分支、并行 worktree 里没有 tools/hooks/pre-commit：一行式 shim 直接放行，连坏 Lua 也不查。
  it("test_shim_passes_when_branch_has_no_script", function()
    seed({ with_script = false })
    write_repo("a.lua", "return return\n")
    stage("a.lua")
    local code, out, err = commit()
    assert.are.equal(0, code, out .. err)
    assert.are.equal(2, commit_count())
    assert.are.equal(0, #busted_calls())
  end)
end)
