-- tools.seam 自测（接缝模块本身）：路径归一、cmd 引用、PATH 解析与真实调用验证、
-- spawn 参数拼装与 8191 断言、递归删除、robocopy 镜像。
-- 断言只看外部行为：返回值、退出码、文件树、子进程回显的 argv；不碰内部实现。
local seam = require("tools.seam")
local fs = require("tests.support.fs_fixture")

local BS = string.char(92)
local CRLF = string.char(13) .. string.char(10)

-- 一行式 Lua：把 argv 按 "序号::值" 逐行回显；用 string.char(10) 规避转义。
local function echo_argv_script()
  return [[local t = {}
for i = 1, #arg do t[i] = i .. "::" .. arg[i] end
io.write(table.concat(t, string.char(10)))]]
end

describe("TestSeamNormalize", function()
  it("folds backslashes to forward slashes", function()
    assert.are.equal("C:/Users/x/a b",
      seam.normalize("C:" .. BS .. "Users" .. BS .. "x" .. BS .. "a b"))
    assert.are.equal("a/b/c", seam.normalize("a/b/c"))
    assert.are.equal("a/b", seam.normalize("a" .. BS .. "b"))
  end)
end)

describe("TestSeamFilesystemProbes", function()
  it("enumerates entries and files, ensures dirs and absolutizes", function()
    local dir = fs.temp_dir()
    fs.write_file(dir .. "/root.txt", "r")
    fs.write_file(dir .. "/sub/a.txt", "a")
    fs.write_file(dir .. "/sub/deep/b.txt", "b")
    assert.is_true(seam.exists(dir .. "/root.txt"))
    assert.is_true(seam.lexists(dir .. "/root.txt"))
    -- Windows 上 lfs.symlinkattributes 对目录会抛错（#191 实测），lexists 必须兜住并判为占名。
    assert.is_true(seam.lexists(dir .. "/sub"))
    assert.is_false(seam.lexists(dir .. "/missing.txt"))
    assert.is_false(seam.exists(dir .. "/missing.txt"))
    assert.is_true(seam.is_dir(dir .. "/sub"))
    assert.is_false(seam.is_dir(dir .. "/root.txt"))
    assert.are.same({
      { name = "root.txt", dir = false },
      { name = "sub", dir = true },
    }, seam.list_entries(dir))
    assert.are.same({ "root.txt", "sub/a.txt", "sub/deep/b.txt" }, seam.list_files(dir))
    assert.is_nil(seam.list_files(dir .. "/nope"))
    seam.ensure_dir(dir .. "/made/deep")
    assert.is_true(seam.is_dir(dir .. "/made/deep"))
    seam.ensure_dir(dir .. "/made/deep")
    local abs = seam.absolute("tmp")
    assert.is_truthy(abs)
    assert.is_nil(abs:find(BS, 1, true))
    assert.is_truthy(abs:match("^%a:/") ~= nil or abs:sub(1, 2) == "//")
  end)
end)

describe("TestCmdQuote", function()
  it("matches the seam cmd quoting rules on sample values", function()
    local cmd_quote = require("tests.support.cmd_quote")
    for _, v in ipairs({ "abc", "a b", 'say "hi"', "中文", "a&b", "！" }) do
      assert.are.equal(seam.quote(v), cmd_quote.q(v), v)
    end
  end)
end)

describe("TestSeamQuote", function()
  it("wraps cmd arguments and escapes embedded quotes", function()
    assert.are.equal([["abc"]], seam.quote("abc"))
    assert.are.equal([["a b"]], seam.quote("a b"))
    assert.are.equal([["say ""hi"""]], seam.quote('say "hi"'))
    assert.are.equal([["中文"]], seam.quote("中文"))
    assert.are.equal([["a&b"]], seam.quote("a&b"))
    assert.are.equal([["！"]], seam.quote("！"))
  end)
end)

describe("TestSeamWhich", function()
  it("accepts a real interpreter found on PATH", function()
    local path = seam.which("lua")
    assert.is_not_nil(path)
    assert.is_nil(path:find(BS, 1, true), "返回路径应已归一为正斜杠")
    assert.is_truthy(path:lower():find("lua", 1, true))
  end)

  it("rejects a fake shell that prints nothing, accepts one that prints a version", function()
    local dir = fs.temp_dir()
    fs.write_file(dir .. "/foo.bat", "@echo off" .. CRLF)
    fs.write_file(dir .. "/bar.bat", "@echo off" .. CRLF .. "echo 9.9.9" .. CRLF)
    local saved = os.getenv
    os.getenv = function(name)
      if name == "PATH" then return dir end
      return saved(name)
    end
    local ok, err = pcall(function()
      assert.is_nil(seam.which("foo"), "什么都不输出的假壳应判不可用")
      assert.is_not_nil(seam.which("bar"), "有版本输出的假壳应判可用")
    end)
    os.getenv = saved
    if not ok then error(err, 0) end
  end)
end)

describe("TestSeamSpawn", function()
  it("passes arguments verbatim through cmd quoting", function()
    local lua = fs.find_on_path("lua")
    assert.is_not_nil(lua, "PATH 上应有 lua")
    local dir = fs.temp_dir()
    local script = dir .. "/echo_argv.lua"
    fs.write_file(script, echo_argv_script())
    local out = dir .. "/args.txt"
    local code = seam.spawn({
      argv = { lua, script, "a b", 'say "hi"', "中文", "！" },
      stdout = out,
    })
    assert.are.equal(0, code)
    local body = fs.slurp(out) or ""
    assert.is_truthy(body:find("1::a b", 1, true), body)
    assert.is_truthy(body:find([[2::say "hi"]], 1, true), body)
    assert.is_truthy(body:find("3::中文", 1, true), body)
    assert.is_truthy(body:find("4::！", 1, true), body)
  end)

  it("sets env vars and working directory for the child", function()
    local lua = fs.find_on_path("lua")
    local dir = fs.temp_dir()
    fs.write_file(dir .. "/marker.txt", "here")
    local out = dir .. "/env.txt"
    local probe = 'io.write((os.getenv("SEAM_PROBE") or "nil") .. "|" .. (io.open("marker.txt") and "cwd-ok" or "cwd-bad"))'
    local code = seam.spawn({ argv = { lua, "-e", probe }, cwd = dir, env = { SEAM_PROBE = "值 带空格" }, stdout = out })
    assert.are.equal(0, code)
    assert.are.equal("值 带空格|cwd-ok", fs.slurp(out))
  end)

  it("asserts the 8191-character cmd line limit", function()
    local lua = fs.find_on_path("lua")
    local huge = string.rep("x", 9000)
    local ok, err = pcall(function()
      seam.spawn({ argv = { lua, "-e", "print(1)", huge } })
    end)
    assert.is_false(ok)
    assert.is_truthy(tostring(err):find("8191", 1, true), tostring(err))
  end)
end)

describe("TestSeamRemove", function()
  it("recursively removes a directory tree and tolerates a missing target", function()
    local dir = fs.temp_dir()
    local tree = dir .. "/tree"
    fs.write_file(tree .. "/a.txt", "a")
    fs.write_file(tree .. "/sub/b.txt", "b")
    fs.write_file(tree .. "/sub/deeper/c.txt", "c")
    seam.remove({ dir = true, dst = tree })
    assert.is_false(fs.exists(tree))
    assert.is_false(fs.exists(tree .. "/sub/deeper/c.txt"))
    seam.remove({ dir = true, dst = tree })
    assert.is_false(fs.exists(tree))
  end)
end)

describe("TestSeamMirror", function()
  it("reports deployment tools ready when robocopy exists", function()
    local ok, reason = seam.preflight()
    assert.is_true(ok, reason)
  end)

  it("mirrors a directory tree with robocopy", function()
    local root = fs.temp_dir()
    local src = root .. "/src"
    local dst = root .. "/dst"
    fs.write_file(src .. "/a.txt", "hello")
    fs.write_file(src .. "/sub/b.txt", "world")
    local ok, info = seam.mirror({ dir = true, src = src, dst = dst })
    assert.is_true(ok, type(info) == "table" and (info.cmd or "") or tostring(info))
    assert.are.equal("hello", fs.slurp(dst .. "/a.txt"))
    assert.are.equal("world", fs.slurp(dst .. "/sub/b.txt"))
  end)

  it("builds a readable mirror command that names the target", function()
    local cmd = seam.mirror_cmd({ dir = true, src = "client/UI", dst = "C:/host/client/UI" })
    assert.is_truthy(cmd:lower():find("robocopy", 1, true))
    assert.is_truthy(cmd:find("/MIR", 1, true))
    assert.is_truthy(cmd:find("client/UI", 1, true))
  end)
end)
