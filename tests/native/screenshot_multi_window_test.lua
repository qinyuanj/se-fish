-- tools/screenshot.lua 多窗口能力（ADR-0044 本地多人测试）：--list / --hwnd / --all 的参数解析、
-- 互斥与缺参报错，以及经替身 tools.seam 驱动的脚本调用与输出契约。不碰真实桌面窗口。
local ROOT = "D:/repo"
local SCRIPT = ROOT .. "/tools/screenshot_capture.ps1"

local function parse(args)
  package.loaded["tools.screenshot"] = nil
  return require("tools.screenshot").parse(args)
end

describe("TestScreenshotMultiParse", function()
  it("test_new_switches_parse", function()
    assert.same({ list = true }, parse({ "--list" }))
    assert.same({ list = true, window = "client" }, parse({ "--list", "--window", "client" }))
    assert.same({ all = true, screen = true, out = "a/b.png" },
      parse({ "--all", "--screen", "--out", "a/b.png" }))
    assert.same({ hwnd = 1311064, screen = true }, parse({ "--hwnd", "1311064", "--screen" }))
    assert.same({ hwnd = 0x1A0B2C }, parse({ "--hwnd", "0x1A0B2C" }))
    assert.same({ hwnd = 0x1A0B2C }, parse({ "--hwnd", "0X1a0b2c" }))
  end)

  it("test_hwnd_rejects_missing_or_malformed_values", function()
    local cases = {
      { { "--hwnd" }, "--hwnd 需要一个值" },
      { { "--hwnd", "--all" }, "--hwnd 需要一个值" },
      { { "--hwnd", "0" }, "--hwnd 需要正的" },
      { { "--hwnd", "abc" }, "--hwnd 需要正的" },
      { { "--hwnd", "0x" }, "--hwnd 需要正的" },
      { { "--hwnd", "12.5" }, "--hwnd 需要正的" },
    }
    for _, case in ipairs(cases) do
      local opts, err = parse(case[1])
      assert.is_nil(opts, table.concat(case[1], " "))
      assert.matches(case[2], err, 1, true)
    end
  end)

  it("test_conflicting_combinations_are_usage_errors", function()
    local cases = {
      { "--hwnd", "5", "--rect", "0,0,1,1" },
      { "--hwnd", "5", "--all" },
      { "--hwnd", "5", "--window", "client" },
      { "--all", "--rect", "0,0,1,1" },
      { "--all", "--info" },
      { "--list", "--all" },
      { "--list", "--hwnd", "5" },
      { "--list", "--info" },
      { "--list", "--rect", "0,0,1,1" },
      { "--list", "--screen" },
      { "--list", "--out", "x.png" },
    }
    for _, args in ipairs(cases) do
      local opts, err = parse(args)
      assert.is_nil(opts, table.concat(args, " "))
      assert.is_string(err)
    end
    -- 原有组合不受新互斥影响；--info --rect 仍由 info 分支报用法错误。
    assert.same({ info = true, rect = "0,0,1,1" }, parse({ "--info", "--rect", "0,0,1,1" }))
    assert.same({ help = true, all = true, rect = "x" }, parse({ "--help", "--all", "--rect", "x" }))
  end)

  it("test_indexed_out_inserts_suffix_before_extension", function()
    package.loaded["tools.screenshot"] = nil
    local shot = require("tools.screenshot")
    assert.are.equal("D:/a/foo-1.png", shot.indexed_out("D:/a/foo.png", 1))
    assert.are.equal("D:/a/foo-2", shot.indexed_out("D:/a/foo", 2))
    assert.are.equal("D:/a.b/foo-3", shot.indexed_out("D:/a.b/foo", 3))
    assert.are.equal("D:/a/.hidden-1", shot.indexed_out("D:/a/.hidden", 1))
    assert.are.equal("D:/a/foo-{n}.png", shot.indexed_out("D:/a/foo.png", "{n}"))
  end)
end)

describe("TestScreenshotMultiMain", function()
  local saved, shot, world, out_text, err_text

  before_each(function()
    saved = { seam = package.loaded["tools.seam"], stdout = io.stdout, stderr = io.stderr }
    world = { calls = {}, files = { [SCRIPT] = true }, replies = {} }
    out_text, err_text = "", ""
    package.loaded["tools.seam"] = {
      which = function() return "C:/pwsh/pwsh.exe" end,
      absolute = function() return ROOT end,
      normalize = function(p) return (tostring(p):gsub("\\", "/")) end,
      exists = function(p) return world.files[p] == true end,
      ensure_dir = function() return true end,
      capture = function(spec)
        world.calls[#world.calls + 1] = spec.argv
        local reply = table.remove(world.replies, 1) or { 1, "" }
        for _, path in ipairs(reply[3] or {}) do world.files[path] = true end
        return reply[1], reply[2]
      end,
    }
    local function sink(field)
      return { write = function(self, ...)
        for _, v in ipairs({ ... }) do
          if field == "out" then out_text = out_text .. tostring(v) else err_text = err_text .. tostring(v) end
        end
        return self
      end }
    end
    io.stdout, io.stderr = sink("out"), sink("err")
    package.loaded["tools.screenshot"] = nil
    shot = require("tools.screenshot")
  end)

  after_each(function()
    package.loaded["tools.seam"] = saved.seam
    package.loaded["tools.screenshot"] = nil
    io.stdout, io.stderr = saved.stdout, saved.stderr
  end)

  local function run(args)
    return shot.main(args, { repo_root = ROOT })
  end

  local function tail(argv, from)
    local rest = {}
    for i = from, #argv do rest[#rest + 1] = argv[i] end
    return rest
  end

  it("test_list_prints_ordered_window_records", function()
    world.replies = { { 0, table.concat({
      "WIN 1311064 4100 0,0,1280,720 client 蛋仔派对 - 编辑器",
      "WIN 2622128 5200 1280,0,960,540 client 蛋仔派对",
      "WIN 3933192 5300 -8,-8,800,600 ? ",
      "RESULT=OK LIST 3",
    }, "\r\n") } }
    assert.are.equal(0, run({ "--list", "--window", "蛋仔" }))
    assert.same({ "C:/pwsh/pwsh.exe", "-NoProfile", "-File", SCRIPT, "-List", "-Window", "蛋仔" },
      world.calls[1])
    assert.are.equal(table.concat({
      "1 hwnd=0x140158 pid=4100 rect=0,0,1280,720 proc=client title=蛋仔派对 - 编辑器",
      "2 hwnd=0x2802B0 pid=5200 rect=1280,0,960,540 proc=client title=蛋仔派对",
      "3 hwnd=0x3C0408 pid=5300 rect=-8,-8,800,600 proc= title=",
      "",
    }, "\n"), out_text)
  end)

  it("test_list_without_window_uses_auto_and_empty_is_ok", function()
    world.replies = { { 0, "RESULT=OK LIST 0\n" } }
    assert.are.equal(0, run({ "--list" }))
    assert.same({ "-List", "-Auto" }, tail(world.calls[1], 5))
    assert.are.equal("", out_text)
    assert.matches("没有匹配的可见窗口", err_text, 1, true)
  end)

  it("test_list_script_failure_exits_1", function()
    world.replies = { { 1, "RESULT=FAIL LIST_FAILED boom\n" } }
    assert.are.equal(1, run({ "--list" }))
    assert.matches("LIST_FAILED boom", err_text, 1, true)
  end)

  it("test_hwnd_passes_decimal_handle_and_verifies_file", function()
    local out = ROOT .. "/tmp/one.png"
    world.replies = { { 0, "RESULT=OK 0,0,800,600 蛋仔派对 screen " .. out .. "\n", { out } } }
    assert.are.equal(0, run({ "--hwnd", "0x2802B0", "--screen", "--out", "tmp/one.png" }))
    assert.same({ "-Out", out, "-Hwnd", "2622128", "-Screen" }, tail(world.calls[1], 5))
    assert.are.equal(out .. "\n", out_text)
    assert.matches("通道=桌面合成", err_text, 1, true)
  end)

  it("test_hwnd_missing_file_fails_even_if_script_claims_ok", function()
    local out = ROOT .. "/tmp/one.png"
    world.replies = { { 0, "RESULT=OK 0,0,800,600 x bg " .. out .. "\n" } }
    assert.are.equal(1, run({ "--hwnd", "42", "--out", out }))
    assert.are.equal("", out_text)
    assert.matches("文件不存在", err_text, 1, true)
  end)

  it("test_all_with_png_out_writes_indexed_paths", function()
    local p1, p2 = ROOT .. "/shots/foo-1.png", ROOT .. "/shots/foo-2.png"
    world.replies = { { 0, table.concat({
      "SHOT=OK 0,0,1280,720 蛋仔派对 - 编辑器 bg " .. p1,
      "SHOT=OK 1280,0,960,540 蛋仔派对 bg " .. p2,
      "RESULT=OK ALL 2",
    }, "\n"), { p1, p2 } } }
    assert.are.equal(0, run({ "--all", "--out", "shots/foo.png" }))
    assert.same({ "-All", "-Out", ROOT .. "/shots/foo-{n}.png", "-Auto" }, tail(world.calls[1], 5))
    assert.are.equal(p1 .. "\n" .. p2 .. "\n", out_text)
    assert.matches("取景[1]", err_text, 1, true)
    assert.matches("取景[2]", err_text, 1, true)
  end)

  it("test_all_without_extension_and_with_window_screen", function()
    local p1 = "E:/x/shot-1"
    world.replies = { { 0, "SHOT=OK 0,0,10,10 t screen " .. p1 .. "\nRESULT=OK ALL 1\n", { p1 } } }
    assert.are.equal(0, run({ "--all", "--window", "蛋仔", "--screen", "--out", "E:\\x\\shot" }))
    assert.same({ "-All", "-Out", "E:/x/shot-{n}", "-Window", "蛋仔", "-Screen" }, tail(world.calls[1], 5))
    assert.are.equal(p1 .. "\n", out_text)
  end)

  it("test_all_default_out_lands_in_tmp", function()
    world.replies = { { 0, "SHOT=OK 0,0,10,10 t bg p\nRESULT=OK ALL 1\n" } }
    local expected
    package.loaded["tools.seam"].exists = function(p)
      if p == SCRIPT then return true end
      expected = p
      return p:match("^" .. ROOT .. "/tmp/screenshot%-%d+%-1%.png$") ~= nil
    end
    assert.are.equal(0, run({ "--all" }))
    assert.matches("^" .. ROOT .. "/tmp/screenshot%-%d+%-{n}%.png$", world.calls[1][7])
    assert.are.equal(expected .. "\n", out_text)
  end)

  it("test_all_fails_when_any_file_missing_or_count_mismatch", function()
    local p1 = ROOT .. "/tmp/a-1.png"
    world.replies = {
      { 0, "SHOT=OK 0,0,1,1 t bg x\nSHOT=OK 0,0,1,1 t bg y\nRESULT=OK ALL 2\n", { p1 } },
      { 0, "SHOT=OK 0,0,1,1 t bg x\nRESULT=OK ALL 2\n", { p1 } },
      { 1, "RESULT=FAIL WINDOW_NOT_FOUND 找不到\n" },
    }
    assert.are.equal(1, run({ "--all", "--out", "tmp/a.png" }))
    assert.matches(ROOT .. "/tmp/a-2.png", err_text, 1, true)
    assert.are.equal(1, run({ "--all", "--out", "tmp/a.png" }))
    assert.are.equal(1, run({ "--all", "--out", "tmp/a.png" }))
    assert.matches("WINDOW_NOT_FOUND", err_text, 1, true)
    assert.are.equal("", out_text)
  end)

  it("test_usage_errors_exit_2_without_calling_script", function()
    assert.are.equal(2, run({ "--all", "--hwnd", "5" }))
    assert.are.equal(2, run({ "--hwnd", "zz" }))
    assert.are.equal(0, #world.calls)
  end)
end)
