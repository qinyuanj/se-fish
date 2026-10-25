-- blender 子命令的命令边界（#125）：给定参数与环境，入口拼出什么命令行、何时拒绝执行、
-- 输出与退出码是否透传。WSL 接缝的进程调用（interop 预检、wslpath、cmd.exe 取值、执行）
-- 全部用桩替换，不需要 Blender 与 interop；真实往返由 tests/native/slow/blender_transport_test.lua 证明。
local seam = require("tools.wsl_seam")
local blender = require("tools.blender")

local PF = "/mnt/c/Program Files"
local LAD = "/mnt/c/Users/u/AppData/Local"
local REPO = "/home/u/se-fish"

-- 假文件系统与 Windows 环境：files 是存在的路径集合，dirs 是「目录 → 一级条目名」。
local world
local saved = {}
local SEAM_KEYS = { "interop", "which", "windows_env", "list_entries", "exists", "to_windows",
  "to_linux", "absolute", "capture", "execute" }

local function fake_stream()
  local s = { text = "" }
  function s:write(...)
    for _, v in ipairs({ ... }) do self.text = self.text .. tostring(v) end
    return self
  end
  return s
end

local function to_win(path)
  if path:match("^%a:[/\\]") then return path end
  local drive, rest = path:match("^/mnt/(%a)/(.*)$")
  if drive then return drive:upper() .. ":\\" .. rest:gsub("/", "\\") end
  return "\\\\wsl.localhost\\Ubuntu" .. path:gsub("/", "\\")
end

local function install_world()
  world = {
    env = {},
    win_env = { ProgramFiles = PF, LOCALAPPDATA = LAD },
    files = { [blender.RUNNER] = true },
    dirs = {},
    interop = true,
    python = true,
    executed = {},
    exit_code = 0,
    version_out = "Blender 5.2.1 LTS\n\tbuild date: 2026-08-25\n",
  }
  for _, k in ipairs(SEAM_KEYS) do saved[k] = seam[k] end
  saved.getenv, saved.stdout, saved.stderr = os.getenv, io.stdout, io.stderr

  seam.interop = function()
    if world.interop then return true end
    return nil, "PATH 上找不到 cmd.exe（WSL interop 不可用）"
  end
  seam.which = function(name)
    if name == "python3" and world.python then return "/usr/bin/python3" end
    return nil
  end
  seam.windows_env = function(name)
    local v = world.win_env[name]
    if v then return v end
    return nil, "Windows 变量 " .. name .. " 未定义"
  end
  seam.list_entries = function(dir)
    local out = {}
    for _, name in ipairs(world.dirs[dir] or {}) do out[#out + 1] = { name = name, dir = true } end
    return out
  end
  seam.exists = function(path) return world.files[path] == true end
  seam.to_windows = function(path) return to_win(path) end
  seam.to_linux = function(path)
    local drive, rest = path:match("^(%a):\\(.*)$")
    return "/mnt/" .. drive:lower() .. "/" .. rest:gsub("\\", "/")
  end
  seam.absolute = function(path)
    if path:sub(1, 1) == "/" then return path end
    return REPO .. "/" .. path:gsub("^%./", "")
  end
  seam.capture = function(cmd)
    world.captured = cmd
    return 0, world.version_out
  end
  seam.execute = function(cmd)
    world.executed[#world.executed + 1] = cmd
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

local function run(args)
  local code = blender.main(args)
  return code, io.stdout.text, io.stderr.text
end

-- 拼出的命令行里某个经 sh 单引号引用的值。
local function quoted(value)
  return seam.q(value)
end

describe("TestBlenderCliPreflight", function()
  before_each(install_world)
  after_each(restore_world)

  it("test_missing_interop_fails_before_blender_starts", function()
    world.interop = false
    install_blender(PF, "5.2")
    world.files[REPO .. "/a.py"] = true
    local code, _, err = run({ "a.py" })
    assert.are_not.equal(0, code)
    assert.matches("interop 不可用", err, 1, true)
    assert.are.equal(0, #world.executed)
  end)

  it("test_blender_not_found_hints_blender_exe", function()
    world.files[REPO .. "/a.py"] = true
    local code, _, err = run({ "a.py" })
    assert.are_not.equal(0, code)
    assert.matches("BLENDER_EXE", err, 1, true)
    assert.matches("C:\\", err, 1, true)
    assert.matches("/mnt/c/", err, 1, true)
    assert.are.equal(0, #world.executed)
  end)

  it("test_blender_exe_pointing_nowhere_is_rejected", function()
    world.env.BLENDER_EXE = "/mnt/c/nope/blender.exe"
    install_blender(PF, "5.2") -- 显式指定时不回退到自动定位
    local code, _, err = run({ "--which" })
    assert.are_not.equal(0, code)
    assert.matches("BLENDER_EXE", err, 1, true)
    assert.matches("/mnt/c/nope/blender.exe", err, 1, true)
    assert.is_nil(world.captured)
  end)

  it("test_relative_blender_exe_is_rejected", function()
    world.env.BLENDER_EXE = "blender.exe"
    local code, _, err = run({ "--which" })
    assert.are_not.equal(0, code)
    assert.matches("绝对路径", err, 1, true)
  end)

  it("test_missing_upstream_runner_fails_before_blender_starts", function()
    install_blender(PF, "5.2")
    world.files[blender.RUNNER] = nil
    world.files[REPO .. "/a.py"] = true
    local code, _, err = run({ "a.py" })
    assert.are_not.equal(0, code)
    assert.matches("blender-core", err, 1, true)
    assert.matches("docs/agents/art-pipeline.md", err, 1, true)
    assert.are.equal(0, #world.executed)
  end)

  it("test_missing_python3_fails_before_blender_starts", function()
    install_blender(PF, "5.2")
    world.python = false
    world.files[REPO .. "/a.py"] = true
    local code, _, err = run({ "a.py" })
    assert.are_not.equal(0, code)
    assert.matches("python3", err, 1, true)
    assert.are.equal(0, #world.executed)
  end)

  it("test_missing_script_fails_before_blender_starts", function()
    install_blender(PF, "5.2")
    local code, _, err = run({ "nope.py" })
    assert.are_not.equal(0, code)
    assert.matches("nope.py", err, 1, true)
    assert.are.equal(0, #world.executed)
  end)
end)

describe("TestBlenderCliLocate", function()
  before_each(install_world)
  after_each(restore_world)

  it("test_linux_form_blender_exe_is_used_as_is", function()
    world.env.BLENDER_EXE = "/mnt/d/Blender/blender.exe"
    world.files["/mnt/d/Blender/blender.exe"] = true
    install_blender(PF, "9.9")
    local code, out = run({ "--which" })
    assert.are.equal(0, code)
    assert.matches("/mnt/d/Blender/blender.exe", out, 1, true)
    assert.matches("D:\\Blender\\blender.exe", out, 1, true)
  end)

  it("test_windows_form_blender_exe_is_converted", function()
    world.env.BLENDER_EXE = "D:\\Blender\\blender.exe"
    world.files["/mnt/d/Blender/blender.exe"] = true
    local code, out = run({ "--which" })
    assert.are.equal(0, code)
    assert.matches("/mnt/d/Blender/blender.exe", out, 1, true)
  end)

  it("test_empty_blender_exe_is_treated_as_unset", function()
    world.env.BLENDER_EXE = ""
    install_blender(PF, "5.2")
    local code, out = run({ "--which" })
    assert.are.equal(0, code)
    assert.matches(PF .. "/Blender Foundation/Blender 5.2/blender.exe", out, 1, true)
  end)

  it("test_unset_picks_newest_version_numerically", function()
    install_blender(PF, "5.9")
    install_blender(PF, "4.2")
    local newest = install_blender(LAD .. "/Programs", "5.10")
    local code, out = run({ "--which" })
    assert.are.equal(0, code)
    assert.matches(newest, out, 1, true)
  end)

  it("test_version_dir_without_exe_is_skipped", function()
    local exe = install_blender(PF, "5.2")
    install_blender(PF, "6.0")
    world.files[PF .. "/Blender Foundation/Blender 6.0/blender.exe"] = nil
    local code, out = run({ "--which" })
    assert.are.equal(0, code)
    assert.matches(exe, out, 1, true)
  end)

  it("test_blender_path_is_not_consulted", function()
    world.env.BLENDER_PATH = "/mnt/d/Blender/blender.exe"
    world.files["/mnt/d/Blender/blender.exe"] = true
    local code, _, err = run({ "--which" })
    assert.are_not.equal(0, code)
    assert.matches("BLENDER_EXE", err, 1, true)
  end)

  it("test_which_prints_path_and_version_without_running_a_script", function()
    local exe = install_blender(PF, "5.2")
    local code, out = run({ "--which" })
    assert.are.equal(0, code)
    assert.matches(exe, out, 1, true)
    assert.matches("C:\\Program Files\\Blender Foundation\\Blender 5.2\\blender.exe", out, 1, true)
    assert.matches("5.2.1 LTS", out, 1, true)
    assert.matches(quoted(exe) .. " --version", world.captured, 1, true)
    assert.are.equal(0, #world.executed)
  end)

  it("test_which_fails_when_version_query_fails", function()
    install_blender(PF, "5.2")
    seam.capture = function() return 1, "boom" end
    local code, _, err = run({ "--which" })
    assert.are_not.equal(0, code)
    assert.matches("boom", err, 1, true)
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

  it("test_script_and_blend_are_converted_to_windows_form", function()
    local code = run({ "tools/x/step.py", "--blend", "tmp/in 鱼.blend" })
    assert.are.equal(0, code)
    local cmd = world.executed[1]
    assert.matches("BLENDER_EXE=" .. quoted(exe), cmd, 1, true)
    assert.matches("python3 " .. quoted(blender.RUNNER), cmd, 1, true)
    assert.matches("--blend " .. quoted(to_win(REPO .. "/tmp/in 鱼.blend")), cmd, 1, true)
    assert.matches(quoted(to_win(REPO .. "/tools/x/step.py")), cmd, 1, true)
  end)

  it("test_path_like_script_args_are_converted", function()
    local code = run({ "tools/x/step.py", "--", "--objects", "Fish", "Fin/Top",
      "--save", "/mnt/c/Users/u/AppData/Local/Temp/out.blend",
      "--out=/home/u/art/a.png", "--rel", "./tmp/b.blend" })
    assert.are.equal(0, code)
    local cmd = world.executed[1]
    local tail = cmd:sub((cmd:find(" '--' ", 1, true)))
    assert.matches(" '--objects' 'Fish' 'Fin/Top' ", tail, 1, true)
    assert.matches("'--save' " .. quoted("C:\\Users\\u\\AppData\\Local\\Temp\\out.blend"), tail, 1, true)
    assert.matches(quoted("--out=" .. to_win("/home/u/art/a.png")), tail, 1, true)
    assert.matches("'--rel' " .. quoted(to_win(REPO .. "/tmp/b.blend")), tail, 1, true)
  end)

  it("test_expr_is_passed_verbatim", function()
    local code = run({ "--expr", "import bpy; print('/home/u -- x')" })
    assert.are.equal(0, code)
    local cmd = world.executed[1]
    assert.matches("--expr " .. quoted("import bpy; print('/home/u -- x')"), cmd, 1, true)
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
    assert.are.equal(0, #world.executed)
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
      assert.are.equal(0, #world.executed)
    end)
  end

  it("test_help_describes_the_contract", function()
    local code, out = run({ "--help" })
    assert.are.equal(0, code)
    assert.matches("--which", out, 1, true)
    assert.matches("--expr", out, 1, true)
    assert.matches("--blend", out, 1, true)
    assert.matches("BLENDER_EXE", out, 1, true)
  end)
end)

describe("TestBlenderCliHelp", function()
  it("test_cli_help_lists_blender_subcommand", function()
    local interpreter = require("tests.support.interpreter")
    local pipe = assert(io.popen(seam.q(interpreter.path()) .. " tools/cli.lua --help"))
    local out = pipe:read("a")
    pipe:close()
    assert.matches("\n  blender%s+%S", out)
  end)
end)
