-- blender 子命令的命令边界（#125；ADR-0017 Windows native）：给定参数与环境，
-- 入口用 seam.which 找 python、用 seam.spawn{argv, env} 起上游 run_in_blender.py，
-- 断言 argv 形状、BLENDER_EXE 经 env 传入、--which 只输出一条正斜杠 Windows 路径。
-- 接缝的进程调用与文件系统探测全部用桩替换，不需要真 Blender；真实往返由
-- tests/native/art/blender_transport_test.lua 证明。
local seam = require("tools.seam")
local blender = require("tools.blender")
local fs = require("tests.support.fs_fixture")
local interpreter = require("tests.support.interpreter")

local REPO = fs.repo_root()
local PF = "C:/Program Files"
local LAD = "C:/Users/dev/AppData/Local"
local PYTHON = "C:/Users/dev/AppData/Local/Programs/Python/Python312/python.exe"

-- 假文件系统与 Windows 环境：files 是存在的路径集合，dirs 是「目录 → 一级条目名」。
local world
local saved = {}
local SEAM_KEYS = { "which", "spawn", "windows_env", "list_entries", "exists", "absolute" }

local function fake_stream()
  local s = { text = "" }
  function s:write(...)
    for _, v in ipairs({ ... }) do self.text = self.text .. tostring(v) end
    return self
  end
  return s
end

local function write(path, body)
  local f = assert(io.open(path, "wb"), path .. " 建不出来")
  f:write(body)
  f:close()
end

local function install_world()
  world = {
    env = {},
    win_env = { ProgramFiles = PF, LOCALAPPDATA = LAD },
    files = { [blender.RUNNER] = true },
    dirs = {},
    python = PYTHON,
    python_version = "Python 3.12.10\r\n",
    blender_version = "Blender 5.2.1 LTS\n\tbuild date: 2026-08-25\n",
    calls = {},
    runs = {},
    exit_code = 0,
  }
  for _, k in ipairs(SEAM_KEYS) do saved[k] = seam[k] end
  saved.getenv, saved.stdout, saved.stderr = os.getenv, io.stdout, io.stderr

  seam.which = function(name)
    if name == "python" then return world.python end
    return nil
  end
  seam.windows_env = function(name) return world.win_env[name] end
  seam.list_entries = function(dir)
    local out = {}
    for _, name in ipairs(world.dirs[dir] or {}) do out[#out + 1] = { name = name, dir = true } end
    return out
  end
  seam.exists = function(path) return world.files[path] == true end
  seam.absolute = function(path)
    local p = seam.normalize(path)
    if p:match("^%a:/") or p:sub(1, 2) == "//" then return p end
    return REPO .. "/" .. p:gsub("^%./", "")
  end
  seam.spawn = function(spec)
    world.calls[#world.calls + 1] = spec
    local argv = spec.argv
    if argv[2] == "--version" then
      local body = (argv[1] == world.python) and world.python_version or world.blender_version
      if spec.stdout then write(spec.stdout, body) end
      return 0
    end
    world.runs[#world.runs + 1] = spec
    return world.exit_code
  end
  os.getenv = function(name)
    if world.env[name] ~= nil then return world.env[name] end
    if name == "BLENDER_EXE" then return nil end
    return saved.getenv(name)
  end
  io.stdout, io.stderr = fake_stream(), fake_stream()
end

local function restore_world()
  for _, k in ipairs(SEAM_KEYS) do seam[k] = saved[k] end
  os.getenv, io.stdout, io.stderr = saved.getenv, saved.stdout, saved.stderr
end

-- 装一个 Blender：<root>/Blender Foundation/Blender <ver>/blender.exe。
local function install_blender(root, ver)
  local base = root .. "/Blender Foundation"
  world.dirs[base] = world.dirs[base] or {}
  table.insert(world.dirs[base], "Blender " .. ver)
  local exe = base .. "/Blender " .. ver .. "/blender.exe"
  world.files[exe] = true
  return exe
end

-- 与 CLI 入口一致：把仓库根作为 env.repo_root 传进去（RUNNER 是相对仓库根的路径）。
local function run(args)
  local code = blender.main(args, { repo_root = REPO, command = "blender" })
  return code, io.stdout.text, io.stderr.text
end

describe("TestBlenderCliPreflight", function()
  before_each(install_world)
  after_each(restore_world)

  it("test_blender_not_found_hints_blender_exe", function()
    world.files[REPO .. "/a.py"] = true
    local code, _, err = run({ "a.py" })
    assert.are.equal(3, code) -- 外部工具不可用（#145）
    assert.matches("BLENDER_EXE", err, 1, true)
    assert.matches("C:/", err, 1, true)
    assert.are.equal(0, #world.runs)
  end)

  it("test_blender_exe_pointing_nowhere_is_rejected", function()
    world.env.BLENDER_EXE = "C:/nope/blender.exe"
    install_blender(PF, "5.2") -- 显式指定时不回退到自动定位
    local code, _, err = run({ "--which" })
    assert.are.equal(3, code)
    assert.matches("BLENDER_EXE", err, 1, true)
    assert.matches("C:/nope/blender.exe", err, 1, true)
    assert.are.equal(0, #world.calls)
  end)

  it("test_relative_blender_exe_is_rejected", function()
    world.env.BLENDER_EXE = "blender.exe"
    local code, _, err = run({ "--which" })
    assert.are_not.equal(0, code)
    assert.matches("绝对", err, 1, true)
  end)

  it("test_missing_upstream_runner_fails_before_blender_starts", function()
    install_blender(PF, "5.2")
    world.files[blender.RUNNER] = nil
    world.files[REPO .. "/a.py"] = true
    local code, _, err = run({ "a.py" })
    assert.are.equal(3, code)
    assert.matches("blender-core", err, 1, true)
    assert.matches("docs/agents/art-pipeline.md", err, 1, true)
    -- 报错指向的小节标题须真实存在于文档，防止文档改名后报错指向空处。
    local section = err:match("docs/agents/art%-pipeline%.md 的「(.-)」")
    assert.is_not_nil(section, "报错未按「小节名」引用 art-pipeline.md")
    local f = assert(io.open("docs/agents/art-pipeline.md", "r"))
    local doc = f:read("a")
    f:close()
    local found = false
    for line in doc:gmatch("[^\n]+") do
      if line:match("^#+%s+(.-)%s*$") == section then found = true end
    end
    assert.is_true(found, "art-pipeline.md 中没有标题「" .. section .. "」")
    assert.are.equal(0, #world.runs)
  end)

  it("test_missing_python_fails_before_blender_starts", function()
    install_blender(PF, "5.2")
    world.python = nil
    world.files[REPO .. "/a.py"] = true
    local code, _, err = run({ "a.py" })
    assert.are.equal(3, code)
    assert.matches("python", err, 1, true)
    assert.are.equal(0, #world.runs)
  end)

  it("test_python_major_version_must_be_3", function()
    install_blender(PF, "5.2")
    world.files[REPO .. "/a.py"] = true
    world.python_version = "Python 2.7.18\r\n"
    local code, _, err = run({ "a.py" })
    assert.are.equal(3, code)
    assert.matches("Python 3", err, 1, true)
    assert.are.equal(0, #world.runs)
  end)

  it("test_unreadable_python_version_fails", function()
    install_blender(PF, "5.2")
    world.files[REPO .. "/a.py"] = true
    world.python_version = ""
    local code, _, err = run({ "a.py" })
    assert.are.equal(3, code)
    assert.matches("版本", err, 1, true)
    assert.are.equal(0, #world.runs)
  end)

  it("test_missing_script_fails_before_blender_starts", function()
    install_blender(PF, "5.2")
    local code, _, err = run({ "nope.py" })
    assert.are_not.equal(0, code)
    assert.matches("nope.py", err, 1, true)
    assert.are.equal(0, #world.runs)
  end)
end)

describe("TestBlenderCliLocate", function()
  before_each(install_world)
  after_each(restore_world)

  it("test_forward_slash_blender_exe_is_used_as_is", function()
    world.env.BLENDER_EXE = "D:/Blender/blender.exe"
    world.files["D:/Blender/blender.exe"] = true
    install_blender(PF, "9.9")
    local code, out = run({ "--which" })
    assert.are.equal(0, code)
    assert.matches("blender: D:/Blender/blender.exe", out, 1, true)
  end)

  it("test_backslash_blender_exe_is_normalized", function()
    world.env.BLENDER_EXE = "D:\\Blender\\blender.exe"
    world.files["D:/Blender/blender.exe"] = true
    local code, out = run({ "--which" })
    assert.are.equal(0, code)
    assert.matches("blender: D:/Blender/blender.exe", out, 1, true)
  end)

  it("test_empty_blender_exe_is_treated_as_unset", function()
    world.env.BLENDER_EXE = ""
    local exe = install_blender(PF, "5.2")
    local code, out = run({ "--which" })
    assert.are.equal(0, code)
    assert.matches("blender: " .. exe, out, 1, true)
  end)

  it("test_unset_picks_newest_version_numerically", function()
    install_blender(PF, "5.9")
    install_blender(PF, "4.2")
    local newest = install_blender(LAD .. "/Programs", "5.10")
    local code, out = run({ "--which" })
    assert.are.equal(0, code)
    assert.matches("blender: " .. newest, out, 1, true)
  end)

  it("test_version_dir_without_exe_is_skipped", function()
    local exe = install_blender(PF, "5.2")
    install_blender(PF, "6.0")
    world.files[PF .. "/Blender Foundation/Blender 6.0/blender.exe"] = nil
    local code, out = run({ "--which" })
    assert.are.equal(0, code)
    assert.matches("blender: " .. exe, out, 1, true)
  end)

  it("test_blender_path_is_not_consulted", function()
    world.env.BLENDER_PATH = "D:/Blender/blender.exe"
    world.files["D:/Blender/blender.exe"] = true
    local code, _, err = run({ "--which" })
    assert.are_not.equal(0, code)
    assert.matches("BLENDER_EXE", err, 1, true)
  end)

  it("test_which_prints_one_forward_slash_path_and_version", function()
    local exe = install_blender(PF, "5.2")
    local code, out = run({ "--which" })
    assert.are.equal(0, code)
    assert.matches("blender: " .. exe, out, 1, true)
    assert.matches("version: 5.2.1 LTS", out, 1, true)
    assert.is_nil(out:find("windows:", 1, true), out)
    assert.is_nil(out:find("\\", 1, true), "路径不得含反斜杠: " .. out)
    assert.are.equal(1, #world.calls)
    assert.are.same({ exe, "--version" }, world.calls[1].argv)
    assert.are.equal(0, #world.runs)
  end)

  it("test_which_fails_when_version_query_fails", function()
    install_blender(PF, "5.2")
    world.blender_version = ""
    local code, _, err = run({ "--which" })
    assert.are_not.equal(0, code)
    assert.matches("读取 Blender 版本失败", err, 1, true)
  end)
end)

describe("TestBlenderCliCommand", function()
  local exe
  before_each(function()
    install_world()
    exe = install_blender(PF, "5.2")
    world.files[REPO .. "/tools/x/step.py"] = true
    world.files[REPO .. "/tmp/in 鱼.blend"] = true
  end)
  after_each(restore_world)

  it("test_blender_exe_goes_through_env_and_script_is_absolute", function()
    local code = run({ "tools/x/step.py", "--blend", "tmp/in 鱼.blend" })
    assert.are.equal(0, code)
    assert.are.equal(1, #world.runs)
    local spec = world.runs[1]
    assert.are.same({
      PYTHON, blender.RUNNER,
      "--blend", REPO .. "/tmp/in 鱼.blend",
      REPO .. "/tools/x/step.py",
    }, spec.argv)
    assert.are.equal(exe, spec.env.BLENDER_EXE)
    assert.are.equal(REPO, spec.cwd, "run_in_blender.py 须在仓库根执行")
    -- BLENDER_EXE 不再拼在命令行前面。
    assert.is_nil(spec.argv[1]:find("BLENDER_EXE", 1, true))
  end)

  it("test_path_like_script_args_are_absolute", function()
    local code = run({ "tools/x/step.py", "--", "--objects", "Fish", "Fin/Top",
      "--save", "C:/Users/dev/AppData/Local/Temp/out.blend",
      "--out=C:/art/a.png", "--rel", "./tmp/b.blend" })
    assert.are.equal(0, code)
    assert.are.same({
      PYTHON, blender.RUNNER, REPO .. "/tools/x/step.py",
      "--", "--objects", "Fish", "Fin/Top",
      "--save", "C:/Users/dev/AppData/Local/Temp/out.blend",
      "--out=C:/art/a.png",
      "--rel", REPO .. "/tmp/b.blend",
    }, world.runs[1].argv)
  end)

  it("test_expr_is_passed_verbatim", function()
    local expr = "import bpy; print('C:/x -- y')"
    local code = run({ "--expr", expr })
    assert.are.equal(0, code)
    assert.are.same({ PYTHON, blender.RUNNER, "--expr", expr }, world.runs[1].argv)
  end)

  it("test_nonzero_exit_code_is_passed_through", function()
    world.exit_code = 1
    assert.are.equal(1, (run({ "tools/x/step.py" })))
    world.exit_code = 3
    assert.are.equal(3, (run({ "tools/x/step.py" })))
  end)

  it("test_missing_blend_fails_before_blender_starts", function()
    local code, _, err = run({ "tools/x/step.py", "--blend", "tmp/nope.blend" })
    assert.are_not.equal(0, code)
    assert.matches("nope.blend", err, 1, true)
    assert.are.equal(0, #world.runs)
  end)
end)

describe("TestBlenderCliUsage", function()
  before_each(install_world)
  after_each(restore_world)

  local cases = {
    { name = "no_arguments", args = {} },
    { name = "script_not_py", args = { "a.txt" } },
    { name = "blend_without_value", args = { "a.py", "--blend" } },
    { name = "expr_without_value", args = { "--expr" } },
    { name = "script_and_expr", args = { "a.py", "--expr", "1" } },
    { name = "two_scripts", args = { "a.py", "b.py" } },
    { name = "unknown_option", args = { "--nope", "a.py" } },
  }
  for _, c in ipairs(cases) do
    it("test_usage_error_" .. c.name, function()
      install_blender(PF, "5.2")
      local code = run(c.args)
      assert.are.equal(2, code)
      assert.are.equal(0, #world.runs)
    end)
  end

  it("test_help_describes_the_contract", function()
    local code, out = run({ "--help" })
    assert.are.equal(0, code)
    assert.matches("--which", out, 1, true)
    assert.matches("--expr", out, 1, true)
    assert.matches("--blend", out, 1, true)
    assert.matches("BLENDER_EXE", out, 1, true)
    assert.is_nil(out:find("lua5.4", 1, true), out)
    assert.is_nil(out:find("WSL", 1, true), out)
  end)
end)

describe("TestBlenderCliHelp", function()
  local dir
  after_each(function()
    fs.rmrf(dir)
    dir = nil
  end)

  it("test_cli_help_lists_blender_subcommand", function()
    dir = fs.temp_dir()
    local out = dir .. "/help.txt"
    local code = seam.spawn({
      argv = { interpreter.path(), REPO .. "/tools/cli.lua", "--help" },
      cwd = REPO, stdout = out, stderr = out,
    })
    assert.are.equal(0, code)
    assert.matches("\n  blender%s+%S", fs.slurp(out) or "")
  end)
end)
