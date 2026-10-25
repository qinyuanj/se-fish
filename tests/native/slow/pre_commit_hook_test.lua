-- pre-commit hook 的回归护栏（#142，#131 复盘）：接缝是 `git commit`。
-- 每例在 tmp/ 下新建临时 git 仓库，复制入库的 tools/hooks/pre-commit，把入库的
-- tools/hooks/shim 装进 hooks 目录（与 docs/agents/workflow.md「pre-commit hook」同一份），
-- 再断言提交的退出码与输出。
-- PATH 前插桩 busted：只记录是否被调用及其看到的环境，不真跑 fast。
-- 每个子进程先清掉全部 GIT_* 变量并屏蔽全局/系统 git 配置——本文件可能在别的 hook
-- 或 git 子进程里被跑到，不能让临时仓库的 git 操作落到外层仓库的索引上。
local q = require("tests.support.sh_quote").q

local fs = require("tests.support.sh_fs")
local slurp, code_of, rmrf, exists, write_file =
  fs.slurp, fs.code_of, fs.rmrf, fs.exists, fs.write_file

-- 本仓库根的绝对路径。busted 从仓库根运行。
local REPO = assert(io.popen("pwd")):read("l")
local HOOK = REPO .. "/tools/hooks/pre-commit"
local ROOT = REPO .. "/tmp/pre-commit-hook-test"
local FAKE = ROOT .. "/repo"
local STUB_DIR = ROOT .. "/bin"
local BUSTED_LOG = ROOT .. "/busted.log"
local STUB_ERROR = ROOT .. "/stub-error.log"
local OUT = ROOT .. "/out"

-- 测的就是文档让人装的那一份 shim，不另抄副本。
local SHIM = assert(slurp(REPO .. "/tools/hooks/shim"), "缺 tools/hooks/shim")

-- 清掉外层 git 导出的全部 GIT_* 与 LUA_BIN，再屏蔽全局/系统配置（hooksPath、签名等）。
local CLEAN_ENV = "for v in $(env | sed -n 's/^\\(GIT_[A-Za-z0-9_]*\\)=.*/\\1/p'); do unset \"$v\"; done; "
  .. "unset LUA_BIN; export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null; "

-- 在临时仓库里跑一段 sh，返回 stdout+stderr 与退出码。
-- opts.path 省略时把桩目录插到 PATH 最前；opts.stub 给桩 busted 的变量（rc、signal）。
local function sh(script, opts)
  opts = opts or {}
  local stub = opts.stub or {}
  local cmd = "( " .. CLEAN_ENV
    .. "export PATH=" .. q(opts.path or (STUB_DIR .. ":" .. os.getenv("PATH"))) .. "; "
    .. "export STUB_BUSTED_LOG=" .. q(BUSTED_LOG)
    .. " STUB_BUSTED_RC=" .. q(stub.rc or 0)
    .. " STUB_BUSTED_SIGNAL=" .. q(stub.signal or "")
    .. " STUB_ERROR_LOG=" .. q(STUB_ERROR) .. "; "
    .. "cd " .. q(FAKE) .. " && " .. script .. " ) > " .. q(OUT) .. " 2>&1"
  local code = code_of(cmd)
  return slurp(OUT) or "", code
end

local GIT = "git -c user.name=t -c user.email=t@example.invalid "

local function commit(opts)
  return sh(GIT .. "commit -q -m msg", opts)
end

local function stage(...)
  local paths = {}
  for i, p in ipairs({ ... }) do paths[i] = q(p) end
  local out, code = sh("git add -- " .. table.concat(paths, " "))
  assert(code == 0, out)
end

local function commit_count()
  local out = sh("git rev-list --count HEAD 2>/dev/null || echo 0")
  return tonumber(out:match("%d+"))
end

local function write_repo(rel, body)
  write_file(FAKE .. "/" .. rel, body)
end

-- 桩 busted：追加一行调用记录（参数 + 是否看到 GIT_DIR/GIT_INDEX_FILE），以 STUB_BUSTED_RC 退出。
-- STUB_BUSTED_SIGNAL 非空时，沿父进程链找到最外层的 hook 进程（shim `exec sh "$f"` 后命令行
-- 含 tools/hooks/pre-commit；它 fork 的子 shell 命令行相同），给它发该信号，模拟提交途中被
-- Ctrl-C / kill。这依赖 shim 的 exec 写法：若 shim 改写后链上（往上 8 级内）找不到这样的进程，
-- 桩把原因写进 STUB_ERROR_LOG 并以 97 退出，用例据此显式失败，而不是误杀别的进程后静默变绿。
local STUB = [[#!/bin/sh
printf 'args=%s GIT_DIR=%s GIT_INDEX_FILE=%s\n' "$*" "${GIT_DIR-unset}" "${GIT_INDEX_FILE-unset}" >>"$STUB_BUSTED_LOG"
if [ -n "${STUB_BUSTED_SIGNAL-}" ]; then
  p=$PPID hook= n=0
  while [ "$n" -lt 8 ] && [ -n "$p" ] && [ "$p" -gt 1 ]; do
    case $(ps -o args= -p "$p") in
      *tools/hooks/pre-commit*) hook=$p ;;
      *) [ -n "$hook" ] && break ;;
    esac
    p=$(ps -o ppid= -p "$p" | tr -d ' ')
    n=$((n + 1))
  done
  if [ -z "$hook" ]; then
    echo "父进程链上找不到命令行含 tools/hooks/pre-commit 的 hook 进程（shim 不再 exec sh \"\$f\"？）" >"$STUB_ERROR_LOG"
    exit 97
  fi
  kill -s "$STUB_BUSTED_SIGNAL" "$hook"
fi
echo "stub busted: 9 successes / 0 failures / 0 errors / 0 pending : 0.1 seconds"
exit "${STUB_BUSTED_RC-0}"
]]

-- 新仓库：首个提交只含 README（及按需复制的 hook），shim 装在 hooks 目录。
local function seed(opts)
  opts = opts or {}
  rmrf(ROOT)
  write_file(STUB_DIR .. "/busted", STUB)
  code_of("chmod +x " .. q(STUB_DIR .. "/busted"))
  write_repo("README.md", "# 夹具\n")
  if opts.with_script ~= false then
    write_repo("tools/hooks/pre-commit", assert(slurp(HOOK)))
  end
  code_of("mkdir -p " .. q(FAKE))
  local _, code = sh("git init -q . && git add -A && " .. GIT .. "commit -q -m init")
  assert(code == 0, "临时仓库初始化失败")
  write_repo(".git/hooks/pre-commit", SHIM)
  code_of("chmod +x " .. q(FAKE .. "/.git/hooks/pre-commit"))
end

local function busted_calls()
  local log = slurp(BUSTED_LOG) or ""
  local calls = {}
  for line in log:gmatch("[^\n]+") do calls[#calls + 1] = line end
  return calls
end

-- hook 的工作目录建在 git 目录下（pre-commit.XXXXXX），退出后必须已删除。
local function leftover_workdirs()
  local out = sh("ls -d .git/pre-commit.* 2>/dev/null || true")
  return out
end

describe("TestPreCommitHook", function()
  before_each(function()
    seed()
  end)
  after_each(function()
    rmrf(ROOT)
  end)

  -- 报错指向暂存路径（含空格与中文），而不是 hook 工作目录里的临时 blob 名。
  it("test_staged_syntax_error_blocks_with_staged_path", function()
    write_repo("common/探针 坏.lua", "local x =\nreturn x\n")
    stage("common/探针 坏.lua")
    local out, code = commit()
    assert.are_not.equal(0, code, out)
    assert.matches("loadfile 失败: common/探针 坏.lua:2:", out, 1, true)
    assert.is_nil(out:find("blob", 1, true), out)
    assert.matches("提交已拦下", out, 1, true)
    assert.are.equal(1, commit_count())
    assert.are.equal(0, #busted_calls())
    assert.are.equal("", leftover_workdirs())
  end)

  it("test_broken_worktree_with_good_stage_passes", function()
    write_repo("a.lua", "return 1\n")
    stage("a.lua")
    write_repo("a.lua", "return return\n")
    local out, code = commit()
    assert.are.equal(0, code, out)
    assert.are.equal(2, commit_count())
  end)

  it("test_broken_stage_with_good_worktree_blocks", function()
    write_repo("a.lua", "return return\n")
    stage("a.lua")
    write_repo("a.lua", "return 1\n")
    local out, code = commit()
    assert.are_not.equal(0, code, out)
    assert.matches("loadfile 失败: a.lua:1:", out, 1, true)
    assert.are.equal(1, commit_count())
  end)

  it("test_docs_only_commit_skips_busted", function()
    write_repo("docs/note.md", "# 只改文档\n")
    stage("docs/note.md")
    local out, code = commit()
    assert.are.equal(0, code, out)
    assert.are.equal(0, #busted_calls(), out)
    assert.are.equal(2, commit_count())
  end)

  -- 跑的是 fast 车道，且 git 导出给 hook 的 GIT_DIR / GIT_INDEX_FILE 不漏给 busted。
  it("test_lua_change_runs_fast_lane_without_git_env", function()
    write_repo("a.lua", "return 1\n")
    stage("a.lua")
    local out, code = commit()
    assert.are.equal(0, code, out)
    assert.are.same({ "args=--run=fast GIT_DIR=unset GIT_INDEX_FILE=unset" }, busted_calls())
    assert.matches("9 successes / 0 failures", out, 1, true)
    assert.are.equal(2, commit_count())
  end)

  -- commit -a 时 git 把 GIT_INDEX_FILE 指向临时索引，最容易漏进子进程。
  it("test_commit_all_does_not_leak_index_to_busted", function()
    write_repo("a.lua", "return 1\n")
    stage("a.lua")
    assert.are.equal(0, select(2, commit()))
    write_repo("a.lua", "return 2\n")
    local out, code = sh(GIT .. "commit -q -a -m all")
    assert.are.equal(0, code, out)
    assert.are.equal("args=--run=fast GIT_DIR=unset GIT_INDEX_FILE=unset", busted_calls()[2])
  end)

  it("test_deleting_lua_runs_busted", function()
    write_repo("a.lua", "return 1\n")
    stage("a.lua")
    assert.are.equal(0, select(2, commit()))
    local out, code = sh("git rm -q a.lua && " .. GIT .. "commit -q -m rm")
    assert.are.equal(0, code, out)
    assert.are.equal(2, #busted_calls(), out)
  end)

  it("test_busted_config_change_runs_busted", function()
    write_repo(".busted", "return {}\n")
    stage(".busted")
    local out, code = commit()
    assert.are.equal(0, code, out)
    assert.are.equal(1, #busted_calls(), out)
  end)

  it("test_failing_fast_lane_blocks_with_output", function()
    write_repo("a.lua", "return 1\n")
    stage("a.lua")
    local out, code = commit({ stub = { rc = 1 } })
    assert.are_not.equal(0, code, out)
    assert.matches("stub busted:", out, 1, true)
    assert.matches("退出码 1", out, 1, true)
    assert.are.equal(1, commit_count())
    assert.are.equal("", leftover_workdirs())
  end)

  it("test_missing_busted_blocks", function()
    -- PATH 去掉桩目录与所有带 busted 的目录，其余（git、sh、lua5.4）照旧。
    local dirs = {}
    for dir in (os.getenv("PATH") or ""):gmatch("[^:]+") do
      if not exists(dir .. "/busted") then dirs[#dirs + 1] = dir end
    end
    write_repo("a.lua", "return 1\n")
    stage("a.lua")
    local out, code = commit({ path = table.concat(dirs, ":") })
    assert.are_not.equal(0, code, out)
    assert.matches("找不到 busted", out, 1, true)
    assert.are.equal(1, commit_count())
  end)

  -- 旧写法 `trap 'rm -rf "$work"' EXIT HUP INT TERM` 收到信号只清理、不退出，脚本接着跑完以 0 放行（3cfadae 修复）。
  for _, sig in ipairs({ "INT", "TERM" }) do
    it("test_signal_" .. sig .. "_aborts_commit_and_cleans_workdir", function()
      write_repo("a.lua", "return 1\n")
      stage("a.lua")
      local out, code = commit({ stub = { signal = sig } })
      assert.is_nil(slurp(STUB_ERROR), slurp(STUB_ERROR))
      assert.are.equal(1, #busted_calls(), out)
      assert.are_not.equal(0, code, out)
      assert.are.equal(1, commit_count(), out)
      assert.are.equal("", leftover_workdirs())
    end)
  end
end)

describe("TestPreCommitShim", function()
  after_each(function()
    rmrf(ROOT)
  end)

  -- 旧分支、并行 worktree 里没有 tools/hooks/pre-commit：一行式 shim 直接放行，连坏 Lua 也不查。
  it("test_shim_passes_when_branch_has_no_script", function()
    seed({ with_script = false })
    write_repo("a.lua", "return return\n")
    stage("a.lua")
    local out, code = commit()
    assert.are.equal(0, code, out)
    assert.are.equal(2, commit_count())
    assert.are.equal(0, #busted_calls())
  end)
end)
