-- test 子命令的命令边界（#145 接缝二）：给定参数与环境，入口拼出什么 busted 命令行、
-- 何时拒绝执行、退出码是否透传。沿用 blender_cli_test 的做法，WSL 接缝层的 which / execute
-- 用桩替换，不真起 busted；真实经 CLI 跑 fast 由 pre-commit hook 的提交证明。
local seam = require("tools.wsl_seam")
local test_cmd = require("tools.test")

local ROOT = "/home/u/se-fish 副本"
local BUSTED = "/home/u/.luarocks/bin/busted"

local world
local saved = {}

local function fake_stream()
  local s = { text = "" }
  function s:write(...)
    for _, v in ipairs({ ... }) do self.text = self.text .. tostring(v) end
    return self
  end
  return s
end

local function install_world()
  world = { busted = BUSTED, executed = {}, exit_code = 0 }
  saved.which, saved.execute = seam.which, seam.execute
  saved.stdout, saved.stderr = io.stdout, io.stderr
  seam.which = function(name)
    if name == "busted" then return world.busted end
    return nil
  end
  seam.execute = function(cmd)
    world.executed[#world.executed + 1] = cmd
    return world.exit_code
  end
  io.stdout, io.stderr = fake_stream(), fake_stream()
end

local function restore_world()
  seam.which, seam.execute = saved.which, saved.execute
  io.stdout, io.stderr = saved.stdout, saved.stderr
end

local function run(args)
  local code = test_cmd.main(args, { repo_root = ROOT, command = "test" })
  return code, io.stdout.text, io.stderr.text
end

-- 期望的命令行：在仓库根执行 busted，参数逐个经 sh 单引号引用。
local function expected_cmd(...)
  local parts = { "cd", seam.q(ROOT), "&&", seam.q(BUSTED) }
  for _, a in ipairs({ ... }) do parts[#parts + 1] = seam.q(a) end
  return table.concat(parts, " ")
end

describe("TestTestCliLanes", function()
  before_each(install_world)
  after_each(restore_world)

  it("test_default_lane_is_fast", function()
    assert.are.equal(0, (run({})))
    assert.are.same({ expected_cmd("--run=fast") }, world.executed)
  end)

  it("test_fast_lane", function()
    assert.are.equal(0, (run({ "fast" })))
    assert.are.same({ expected_cmd("--run=fast") }, world.executed)
  end)

  it("test_full_lane", function()
    assert.are.equal(0, (run({ "full" })))
    assert.are.same({ expected_cmd("--run=full") }, world.executed)
  end)

  it("test_args_after_double_dash_are_appended_verbatim", function()
    assert.are.equal(0, (run({ "full", "--", "--filter=鱼 竿", "tests/native/a_test.lua", "--", "-o", "it's" })))
    assert.are.same({ expected_cmd("--run=full", "--filter=鱼 竿", "tests/native/a_test.lua", "--", "-o", "it's") },
      world.executed)
  end)

  it("test_double_dash_without_lane_uses_fast", function()
    assert.are.equal(0, (run({ "--", "--list" })))
    assert.are.same({ expected_cmd("--run=fast", "--list") }, world.executed)
  end)
end)

describe("TestTestCliFailures", function()
  before_each(install_world)
  after_each(restore_world)

  it("test_unknown_lane_exits_2_and_lists_lanes", function()
    local code, _, err = run({ "slow" })
    assert.are.equal(2, code)
    assert.matches("未知车道: slow", err, 1, true)
    assert.matches("fast", err, 1, true)
    assert.matches("full", err, 1, true)
    assert.are.equal(0, #world.executed)
  end)

  it("test_unknown_option_before_double_dash_exits_2", function()
    local code, _, err = run({ "fast", "--filter=x" })
    assert.are.equal(2, code)
    assert.matches("--filter=x", err, 1, true)
    assert.are.equal(0, #world.executed)
  end)

  it("test_missing_busted_exits_3_with_install_hint", function()
    world.busted = nil
    local code, _, err = run({ "fast" })
    assert.are.equal(3, code)
    assert.matches("找不到 busted", err, 1, true)
    assert.matches("luarocks", err, 1, true)
    assert.matches("~/.luarocks/bin", err, 1, true)
    assert.are.equal(0, #world.executed)
  end)

  it("test_busted_exit_code_is_passed_through", function()
    world.exit_code = 1
    assert.are.equal(1, (run({ "fast" })))
    world.exit_code = 7
    assert.are.equal(7, (run({ "full" })))
  end)

  it("test_help_lists_lanes_without_running_busted", function()
    local code, out = run({ "--help" })
    assert.are.equal(0, code)
    assert.matches("lua5.4 tools/cli.lua test", out, 1, true)
    assert.matches("fast", out, 1, true)
    assert.matches("full", out, 1, true)
    assert.are.equal(0, #world.executed)
  end)
end)
