-- tools/cli.lua 的进程边界（#145 接缝一）：真实以子进程执行 `lua5.4 tools/cli.lua`，不打桩，
-- 只断言退出码与 stdout / stderr 的关键文案。子进程清掉 LUA_PATH，证明模块搜索路径来自
-- 入口脚本自己推导的仓库根，而不是调用方的环境或当前目录。
local q = require("tests.support.sh_quote").q
local fs = require("tests.support.sh_fs")
local slurp, code_of, rmrf, mkdirp = fs.slurp, fs.code_of, fs.rmrf, fs.mkdirp

-- busted 从仓库根运行。
local REPO = assert(io.popen("pwd")):read("l")
local CLI = REPO .. "/tools/cli.lua"
local ROOT = REPO .. "/tmp/cli-entry-test"
local OUT, ERR = ROOT .. "/out", ROOT .. "/err"

-- 在 dir 里跑 `<lua> <cli> args...`，返回退出码、stdout、stderr。
local function cli(args, opts)
  opts = opts or {}
  local parts = {}
  for i, a in ipairs(args) do parts[i] = q(a) end
  mkdirp(ROOT)
  local cmd = "cd " .. q(opts.dir or REPO)
    .. " && env -u LUA_PATH -u LUA_PATH_5_4 -u LUA_INIT -u LUA_INIT_5_4 "
    .. q(opts.lua or "lua5.4") .. " " .. q(opts.cli or CLI) .. " " .. table.concat(parts, " ")
    .. " </dev/null >" .. q(OUT) .. " 2>" .. q(ERR)
  local code = code_of(cmd)
  return code, slurp(OUT) or "", slurp(ERR) or ""
end

describe("TestCliEntryInterpreter", function()
  after_each(function() rmrf(ROOT) end)

  -- WSL 上裸 lua 可能是 5.1：入口在做任何事之前就拒绝，并告诉人该用哪个解释器。
  local has_51 = code_of("command -v lua5.1 >/dev/null 2>&1") == 0
  local case = has_51 and it or pending
  case("test_non_54_interpreter_exits_1_with_hint", function()
    local code, out, err = cli({ "--help" }, { lua = "lua5.1" })
    assert.are.equal(1, code, out .. err)
    assert.matches("请用 lua5.4", err, 1, true)
    assert.are.equal("", out)
  end)
end)

-- --help 里「子命令」段每行形如「  <名字>  <说明>」，到空行结束。
local function help_commands(text)
  local names, inside = {}, false
  for line in (text .. "\n"):gmatch("([^\n]*)\n") do
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
  after_each(function() rmrf(ROOT) end)

  it("test_help_lists_exactly_the_routed_commands", function()
    local code, out, err = cli({ "--help" })
    assert.are.equal(0, code, err)
    local expected = {}
    for i, c in ipairs(routes) do expected[i] = c.name end
    assert.are.same(expected, help_commands(out))
    assert.matches("lua5.4 tools/cli.lua <子命令>", out, 1, true)
  end)

  it("test_help_states_exit_code_contract", function()
    local _, out = cli({ "-h" })
    for _, code in ipairs({ "0", "1", "2", "3" }) do
      assert.matches("\n  " .. code .. " ", out, 1, true)
    end
    assert.matches("平台或工具不可用", out, 1, true)
  end)

  it("test_test_subcommand_is_routed", function()
    local code, out, err = cli({ "test", "--help" }, { dir = REPO .. "/tools" })
    assert.are.equal(0, code, err)
    assert.matches("lua5.4 tools/cli.lua test [fast|full]", out, 1, true)
  end)

  it("test_unknown_lane_exits_2_through_the_entry", function()
    local code, out, err = cli({ "test", "slow" })
    assert.are.equal(2, code, out .. err)
    assert.matches("可用车道: fast, full", err, 1, true)
  end)

  it("test_unknown_subcommand_exits_2", function()
    local code, out, err = cli({ "nope" })
    assert.are.equal(2, code, out .. err)
    assert.matches("未知子命令: nope", err, 1, true)
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
  after_each(function() rmrf(ROOT) end)

  it("test_subcommand_loads_from_a_subdirectory", function()
    local code, out, err = cli({ "blender", "--help" }, { dir = REPO .. "/docs" })
    assert.are.equal(0, code, err)
    assert.matches("lua5.4 tools/cli.lua blender", out, 1, true)
  end)

  -- 另一个目录里用相对路径指向入口（如从别的 worktree 调本检出的 CLI）。
  it("test_relative_entry_path_from_another_directory", function()
    mkdirp(ROOT .. "/elsewhere")
    local code, out, err = cli({ "worktree-init", "--help" },
      { dir = ROOT .. "/elsewhere", cli = "../../../tools/cli.lua" })
    assert.are.equal(0, code, err)
    assert.matches("worktree-init", out, 1, true)
  end)
end)
