-- worktree-init 子命令的外部行为（#141）：在真实临时目录里搭出「资源库 skill 目录 +
-- 主检出旁的工具检出 + 新 worktree」，经 main(args) 调用，断言落盘结果、幂等与缺来源时的报错。
-- 来源用 --skills-from / --tools-from 显式给出，不碰 interop 与真实 git。
local init = require("tools.worktree_init")
local q = require("tests.support.sh_quote").q

local ROOT = "tmp/worktree-init-test"
local LIB = ROOT .. "/library"
local TOOLS = ROOT .. "/main-parent"
local WT_PARENT = ROOT .. "/wt-parent"
local WT = WT_PARENT .. "/se-fish"
local TOOL_NAMES = { "uml-viewer", "crapper", "mutator", "dryer" }

local function sh(cmd)
  local _, _, code = os.execute(cmd)
  return code
end

local function write(path, body)
  local f = assert(io.open(path, "wb"))
  f:write(body)
  f:close()
end

local function read(path)
  local f = io.open(path, "rb")
  if not f then return nil end
  local body = f:read("a")
  f:close()
  return body
end

local function exists(path) return sh("test -e " .. q(path) .. " || test -L " .. q(path)) == 0 end

local function readlink(path)
  local h = io.popen("readlink " .. q(path))
  local out = h:read("l")
  h:close()
  return out
end

local function abs(path)
  local h = io.popen("realpath -m -- " .. q(path))
  local out = h:read("l")
  h:close()
  return out
end

local function stream()
  local s = { text = "" }
  function s:write(...)
    for _, v in ipairs({ ... }) do self.text = self.text .. tostring(v) end
    return self
  end
  return s
end

local saved_out, saved_err
local out, err

local function run(extra)
  out, err = stream(), stream()
  io.stdout, io.stderr = out, err
  local ok, code = pcall(init.main, extra or {
    "--root", WT, "--skills-from", LIB, "--tools-from", TOOLS,
  })
  io.stdout, io.stderr = saved_out, saved_err
  assert(ok, code)
  return code
end

describe("TestWorktreeInit", function()
  before_each(function()
    saved_out, saved_err = io.stdout, io.stderr
    sh("rm -rf " .. q(ROOT))
    for _, name in ipairs({ "blender-core", "blender-rendering", "tdd" }) do
      sh("mkdir -p " .. q(LIB .. "/" .. name .. "/scripts"))
      write(LIB .. "/" .. name .. "/SKILL.md", name .. "\n")
    end
    write(LIB .. "/blender-core/scripts/run_in_blender.py", "print('runner')\n")
    for _, t in ipairs(TOOL_NAMES) do sh("mkdir -p " .. q(TOOLS .. "/" .. t)) end
    sh("mkdir -p " .. q(WT .. "/tools/quality"))
    write(WT .. "/tools/quality/project.json", [[{
  "tools": {
    "viewer": {"directory": "uml-viewer", "source": "../uml-viewer", "commit": "a"},
    "crapper": {"directory": "crapper", "source": "../crapper", "commit": "b"},
    "mutator": {"directory": "mutator", "source": "../mutator", "commit": "c"},
    "dryer": {"directory": "dryer", "source": "../dryer", "commit": "d"}
  }
}
]])
  end)
  after_each(function()
    io.stdout, io.stderr = saved_out, saved_err
    sh("rm -rf " .. q(ROOT))
  end)

  it("test_fresh_worktree_gets_blender_skills_and_parent_tool_links", function()
    assert.are.equal(0, run(), err.text)
    assert.are.equal("print('runner')\n",
      read(WT .. "/.agents/skills/blender-core/scripts/run_in_blender.py"))
    assert.are.equal("blender-rendering\n", read(WT .. "/.agents/skills/blender-rendering/SKILL.md"))
    -- 只复制 blender-*，资源库里的其他 skill 不进来。
    assert.is_false(exists(WT .. "/.agents/skills/tdd"))
    for _, t in ipairs(TOOL_NAMES) do
      -- symlink 建在 worktree 的父目录，指向工具检出的绝对路径；根内不建。
      assert.are.equal(abs(TOOLS .. "/" .. t), readlink(WT_PARENT .. "/" .. t))
      assert.is_false(exists(WT .. "/" .. t))
    end
  end)

  it("test_second_run_is_noop_and_keeps_existing_entries", function()
    assert.are.equal(0, run(), err.text)
    -- 已存在的条目一律跳过：skill 内的本地文件不被覆盖，已有 symlink 不被改指向。
    write(WT .. "/.agents/skills/blender-core/local.txt", "keep\n")
    sh("rm " .. q(WT_PARENT .. "/dryer") .. " && mkdir " .. q(WT_PARENT .. "/dryer"))
    assert.are.equal(0, run(), err.text)
    assert.are.equal("keep\n", read(WT .. "/.agents/skills/blender-core/local.txt"))
    assert.is_nil(readlink(WT_PARENT .. "/dryer"))
    assert.matches("跳过", out.text, 1, true)
    assert.are.equal("", err.text)
  end)

  it("test_missing_skills_source_fails_before_writing", function()
    local code = run({ "--root", WT, "--skills-from", ROOT .. "/nope", "--tools-from", TOOLS })
    assert.are.equal(1, code)
    assert.matches(ROOT .. "/nope", err.text, 1, true)
    assert.matches("上游 blender-* skill", err.text, 1, true)
    assert.is_false(exists(WT .. "/.agents"))
    assert.is_false(exists(WT_PARENT .. "/crapper"))
  end)

  it("test_missing_tool_checkout_fails_before_writing", function()
    sh("rm -rf " .. q(TOOLS .. "/mutator"))
    local code = run()
    assert.are.equal(1, code)
    assert.matches(TOOLS .. "/mutator", err.text, 1, true)
    assert.is_false(exists(WT .. "/.agents"))
    assert.is_false(exists(WT_PARENT .. "/crapper"))
  end)

  it("test_never_runs_quality_install_and_names_toolcache_owner", function()
    assert.are.equal(0, run(), err.text)
    assert.is_false(exists(WT .. "/.toolcache"))
    assert.matches("tools/quality/project install", out.text, 1, true)
  end)

  it("test_usage_errors_and_help", function()
    assert.are.equal(2, run({ "--bogus" }))
    assert.matches("用法", err.text, 1, true)
    assert.are.equal(0, run({ "--help" }))
    assert.matches("worktree-init", out.text, 1, true)
  end)
end)
