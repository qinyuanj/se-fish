-- screenshot 子命令的命令边界：给定参数与环境，入口用 seam.which 找 pwsh、
-- 用 seam.capture{argv} 执行 tools/screenshot_capture.ps1，断言 argv 形状与退出码。
-- 接缝的进程调用与文件系统探测全部用桩替换，不需要真屏幕；真实抓屏由人工在虚拟屏上验证。
local seam = require("tools.seam")
local shot = require("tools.screenshot")
local fs = require("tests.support.fs_fixture")

local REPO = fs.repo_root()
local PWSH = "C:/Program Files/PowerShell/7/pwsh.exe"

local world
local saved = {}
local SEAM_KEYS = { "which", "capture", "exists", "ensure_dir", "absolute" }

local function fake_stream()
  local s = { text = "" }
  function s:write(...)
    for _, v in ipairs({ ... }) do self.text = self.text .. tostring(v) end
    return self
  end
  return s
end

local function install_world()
  world = {
    pwsh = PWSH,
    files = { [REPO .. "/" .. shot.SCRIPT] = true },
    dirs = {},
    result = "RESULT=OK 100,200,800,600 client C:/out.png",
    exit_code = 0,
    calls = {},
  }
  for _, k in ipairs(SEAM_KEYS) do saved[k] = seam[k] end
  saved.stdout, saved.stderr = io.stdout, io.stderr

  seam.which = function(name)
    if name == "pwsh" then return world.pwsh end
    return nil
  end
  seam.exists = function(path) return world.files[path] == true end
  seam.ensure_dir = function(path) world.dirs[#world.dirs + 1] = path end
  seam.absolute = function(path)
    local p = seam.normalize(path)
    if p:match("^%a:/") or p:sub(1, 2) == "//" then return p end
    return REPO .. "/" .. p:gsub("^%./", "")
  end
  seam.capture = function(spec)
    world.calls[#world.calls + 1] = spec
    local out = spec.argv[6]
    if world.exit_code == 0 and world.file_created ~= false then world.files[out] = true end
    return world.exit_code, world.result
  end
  io.stdout, io.stderr = fake_stream(), fake_stream()
end

local function restore_world()
  for _, k in ipairs(SEAM_KEYS) do seam[k] = saved[k] end
  io.stdout, io.stderr = saved.stdout, saved.stderr
end

local function run(args, env)
  local code = shot.main(args, env or { repo_root = REPO })
  return code, io.stdout.text, io.stderr.text
end

local function argv_of()
  return world.calls[#world.calls].argv
end

describe("TestScreenshotParse", function()
  it("test_parse_rect_accepts_signed_origin", function()
    local rect = assert(shot.parse_rect("-10,20,800,600"))
    assert.are.same({ x = -10, y = 20, w = 800, h = 600 }, rect)
  end)

  it("test_parse_rect_rejects_bad_shape", function()
    assert.is_nil(shot.parse_rect("1,2,3"))
    assert.is_nil(shot.parse_rect("1,2,0,4"))
    assert.is_nil(shot.parse_rect("a,b,c,d"))
  end)

  it("test_framing_defaults_to_client_window", function()
    local frame = assert(shot.framing({}))
    assert.are.equal("-Window", frame.flag)
    assert.are.equal(shot.DEFAULT_WINDOW, frame.value)
  end)

  it("test_framing_rect_overrides_window", function()
    local frame = assert(shot.framing({ rect = "1,2,3,4", window = "other" }))
    assert.are.equal("-Rect", frame.flag)
    assert.are.equal("1,2,3,4", frame.value)
  end)
end)

describe("TestScreenshotCommand", function()
  before_each(install_world)
  after_each(restore_world)

  it("test_help_prints_usage_and_exits_0", function()
    local code, out, err = run({ "--help" })
    assert.are.equal(0, code, err)
    assert.matches("--window", out, 1, true)
    assert.are.equal(0, #world.calls)
  end)

  it("test_unknown_arg_exits_2", function()
    local code, _, err = run({ "--bogus" })
    assert.are.equal(2, code)
    assert.matches("未知参数", err, 1, true)
  end)

  it("test_bad_rect_exits_2_before_capture", function()
    local code, _, err = run({ "--rect", "1,2" })
    assert.are.equal(2, code)
    assert.matches("X,Y,W,H", err, 1, true)
    assert.are.equal(0, #world.calls)
  end)

  it("test_missing_pwsh_exits_3", function()
    world.pwsh = nil
    local code, _, err = run({})
    assert.are.equal(3, code)
    assert.matches("找不到 pwsh", err, 1, true)
  end)

  it("test_default_captures_client_window_into_tmp", function()
    local code, out, err = run({})
    assert.are.equal(0, code, err)
    local argv = argv_of()
    assert.are.equal(PWSH, argv[1])
    assert.are.equal("-NoProfile", argv[2])
    assert.are.equal("-File", argv[3])
    assert.matches(shot.SCRIPT, argv[4], 1, true)
    assert.are.equal("-Out", argv[5])
    assert.matches("/tmp/screenshot-", argv[6], 1, true)
    assert.are.equal("-Window", argv[7])
    assert.are.equal("client", argv[8])
    assert.are.equal(argv[6] .. "\n", out)
    assert.matches("取景 100,200,800,600 client", err, 1, true)
  end)

  it("test_window_and_out_are_forwarded", function()
    local code, out, err = run({ "--window", "钓鱼", "--out", "tmp/a.png" })
    assert.are.equal(0, code, err)
    local argv = argv_of()
    assert.are.equal(REPO .. "/tmp/a.png", argv[6])
    assert.are.equal("-Window", argv[7])
    assert.are.equal("钓鱼", argv[8])
    assert.are.equal(REPO .. "/tmp/a.png\n", out)
  end)

  it("test_rect_overrides_default_window", function()
    local code, _, err = run({ "--rect", "10,20,30,40" })
    assert.are.equal(0, code, err)
    local argv = argv_of()
    assert.are.equal("-Rect", argv[7])
    assert.are.equal("10,20,30,40", argv[8])
  end)

  it("test_info_reports_display_verdict", function()
    world.result = "INFO 屏幕 \\\\.\\DISPLAY2 1920,0 1920x1080 适配器=NVIDIA\r\nINFO 判定 非虚拟屏\r\nRESULT=OK INFO 非虚拟屏\r\n"
    local code, out, err = run({ "--info" })
    assert.are.equal(0, code, err)
    local argv = argv_of()
    assert.are.equal("-Info", argv[5])
    assert.are.equal("-Window", argv[6])
    assert.are.equal("client", argv[7])
    assert.matches("判定 非虚拟屏", out, 1, true)
    assert.are.equal("", err)
  end)

  it("test_info_rejects_rect", function()
    local code, _, err = run({ "--info", "--rect", "1,2,3,4" })
    assert.are.equal(2, code)
    assert.matches("--info 不能用 --rect", err, 1, true)
    assert.are.equal(0, #world.calls)
  end)

  it("test_info_failure_reports_reason_and_exits_1", function()
    world.exit_code = 1
    world.result = "RESULT=FAIL WINDOW_NOT_FOUND 没有标题包含「client」的可见窗口\r\n"
    local code, out, err = run({ "--info" })
    assert.are.equal(1, code)
    assert.matches("WINDOW_NOT_FOUND", err, 1, true)
    assert.are.equal("", out)
  end)

  it("test_capture_failure_reports_reason_and_exits_1", function()
    world.exit_code = 1
    world.result = "RESULT=FAIL WINDOW_NOT_FOUND 没有标题包含「client」的可见窗口\n"
    local code, out, err = run({})
    assert.are.equal(1, code)
    assert.matches("WINDOW_NOT_FOUND", err, 1, true)
    assert.are.equal("", out)
  end)

  it("test_success_without_file_exits_1", function()
    world.result = "RESULT=OK 1,2,3,4 rect C:/missing.png"
    world.file_created = false
    local code, _, err = run({})
    assert.are.equal(1, code)
    assert.matches("文件不存在", err, 1, true)
  end)
end)