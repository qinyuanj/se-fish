-- test 子命令的命令边界（#145 接缝二；ADR-0017 Windows native）：给定参数与环境，
-- 入口用 seam.which 找 busted、用 seam.spawn{argv,cwd} 在仓库根跑它，并断言 argv 形状、
-- cwd 与退出码映射。进程调用全部用桩替换，不真起 busted；真 CLI 驱动由 slow 用例与
-- pre-commit hook 的提交证明。
local seam = require("tools.seam")
local test_cmd = require("tools.test")

local ROOT = "D:/fixture/se-fish"
local BUSTED = "C:/Users/dev/AppData/Roaming/luarocks/bin/busted.bat"

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
  world = { busted = BUSTED, spawns = {}, code = 0 }
  saved.which, saved.spawn = seam.which, seam.spawn
  saved.stdout, saved.stderr = io.stdout, io.stderr
  seam.which = function(name)
    if name == "busted" then return world.busted end
    return nil
  end
  seam.spawn = function(spec)
    world.spawns[#world.spawns + 1] = spec
    return world.code
  end
  io.stdout, io.stderr = fake_stream(), fake_stream()
end

local function restore_world()
  seam.which, seam.spawn = saved.which, saved.spawn
  io.stdout, io.stderr = saved.stdout, saved.stderr
end

local function run(args)
  local code = test_cmd.main(args, { repo_root = ROOT, command = "test" })
  return code, io.stdout.text, io.stderr.text
end

-- 期望的 argv：busted 绝对路径 + --run=<车道> + 透传参数。
local function expected_argv(...)
  local argv = { BUSTED }
  for _, a in ipairs({ ... }) do argv[#argv + 1] = a end
  return argv
end

describe("TestTestCliLanes", function()
  before_each(install_world)
  after_each(restore_world)

  it("test_default_lane_is_fast", function()
    assert.are.equal(0, (run({})))
    assert.are.equal(1, #world.spawns)
    assert.are.same({ expected_argv("--run=fast") }, { world.spawns[1].argv })
    assert.are.equal(ROOT, world.spawns[1].cwd)
  end)

  it("test_fast_lane", function()
    assert.are.equal(0, (run({ "fast" })))
    assert.are.same(expected_argv("--run=fast"), world.spawns[1].argv)
  end)

  it("test_full_lane", function()
    assert.are.equal(0, (run({ "full" })))
    assert.are.same(expected_argv("--run=full"), world.spawns[1].argv)
  end)

  it("test_args_after_double_dash_are_appended_verbatim", function()
    assert.are.equal(0, (run({ "full", "--", "--filter=鱼 竿", "tests/native/a_test.lua", "--", "-o", "it's" })))
    assert.are.same(
      expected_argv("--run=full", "--filter=鱼 竿", "tests/native/a_test.lua", "--", "-o", "it's"),
      world.spawns[1].argv)
  end)

  it("test_double_dash_without_lane_uses_fast", function()
    assert.are.equal(0, (run({ "--", "--list" })))
    assert.are.same(expected_argv("--run=fast", "--list"), world.spawns[1].argv)
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
    assert.are.equal(0, #world.spawns)
  end)

  it("test_unknown_option_before_double_dash_exits_2", function()
    local code, _, err = run({ "fast", "--filter=x" })
    assert.are.equal(2, code)
    assert.matches("--filter=x", err, 1, true)
    assert.are.equal(0, #world.spawns)
  end)

  it("test_missing_busted_exits_3_with_install_hint", function()
    world.busted = nil
    local code, _, err = run({ "fast" })
    assert.are.equal(3, code)
    assert.matches("找不到 busted", err, 1, true)
    assert.matches("luarocks", err, 1, true)
    assert.is_truthy(err:find("%APPDATA%\\luarocks\\bin", 1, true), err)
    assert.are.equal(0, #world.spawns)
  end)

  -- busted 退出码是失败数加错误数；恰好 3 个失败不能被当成「busted 不可用」的 3。
  it("test_busted_failure_exits_1_even_when_busted_returns_3", function()
    world.code = 1
    assert.are.equal(1, (run({ "fast" })))
    world.code = 3
    assert.are.equal(1, (run({ "full" })))
  end)

  it("test_help_lists_lanes_without_running_busted", function()
    local code, out = run({ "--help" })
    assert.are.equal(0, code)
    assert.matches("lua tools/cli.lua test", out, 1, true)
    assert.matches("fast", out, 1, true)
    assert.matches("full", out, 1, true)
    assert.are.equal(0, #world.spawns)
  end)
end)
