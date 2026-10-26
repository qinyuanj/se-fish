-- worktree-init 子命令的外部行为（#141）：在真实临时目录里搭出「资源库 skill 目录 +
-- 主检出旁的工具检出 + 新 worktree」，经 main(args) 调用，断言落盘结果、幂等与缺来源时的报错。
-- 来源默认用 --skills-from / --tools-from 显式给出；默认推导的用例只桩掉 WSL 接缝层
-- 的 magpie_library 与 git 调用，不碰 interop 与真实 git。
local init = require("tools.worktree_init")
local seam = require("tools.wsl_seam")
local q = require("tests.support.sh_quote").q
local fs = require("tests.support.sh_fs")
local code_of, slurp, write_file, lexists = fs.code_of, fs.slurp, fs.write_file, fs.lexists

local ROOT = "tmp/worktree-init-test"
local LIB = ROOT .. "/library"
local TOOLS = ROOT .. "/main-parent"
local WT_PARENT = ROOT .. "/wt-parent"
local WT = WT_PARENT .. "/se-fish"
local TOOL_NAMES = { "uml-viewer", "crapper", "mutator", "dryer" }

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

local saved_out, saved_err, saved_seam
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

-- 把 git worktree list 换成给定结果，其余命令（realpath 等）照常执行。
local function stub_git_worktree_list(code, text)
  local real = seam.capture
  seam.capture = function(cmd)
    if cmd:find("worktree list --porcelain", 1, true) then return code, text end
    return real(cmd)
  end
end

describe("TestWorktreeInit", function()
  before_each(function()
    saved_out, saved_err = io.stdout, io.stderr
    saved_seam = { capture = seam.capture, magpie_library = seam.magpie_library }
    code_of("rm -rf " .. q(ROOT))
    for _, name in ipairs({ "blender-core", "blender-rendering", "tdd" }) do
      write_file(LIB .. "/" .. name .. "/SKILL.md", name .. "\n")
    end
    write_file(LIB .. "/blender-core/scripts/run_in_blender.py", "print('runner')\n")
    for _, t in ipairs(TOOL_NAMES) do fs.mkdirp(TOOLS .. "/" .. t) end
    -- tools 节外的 "../<名>" 不算工具（只认 tools.*.source）。
    write_file(WT .. "/tools/quality/project.json", [[{
  "lua_tools": {"stray": {"source": "../not-a-tool"}},
  "tools": {
    "viewer": {"directory": "uml-viewer", "source": "../uml-viewer", "commit": "a"},
    "crapper": {"directory": "crapper", "source": "../crapper", "commit": "b", "patches": ["x"]},
    "mutator": {"directory": "mutator", "source": "../mutator", "commit": "c"},
    "dryer": {"directory": "dryer", "source": "../dryer", "commit": "d"}
  },
  "later": {"source": "../also-not-a-tool"}
}
]])
  end)
  after_each(function()
    io.stdout, io.stderr = saved_out, saved_err
    for k, v in pairs(saved_seam) do seam[k] = v end
    code_of("chmod -R u+rwX " .. q(ROOT) .. " 2>/dev/null; rm -rf " .. q(ROOT))
  end)

  it("test_fresh_worktree_gets_blender_skills_and_parent_tool_links", function()
    assert.are.equal(0, run(), err.text)
    assert.are.equal("print('runner')\n",
      slurp(WT .. "/.agents/skills/blender-core/scripts/run_in_blender.py"))
    assert.are.equal("blender-rendering\n", slurp(WT .. "/.agents/skills/blender-rendering/SKILL.md"))
    -- 只复制 blender-*，资源库里的其他 skill 不进来。
    assert.is_false(lexists(WT .. "/.agents/skills/tdd"))
    for _, t in ipairs(TOOL_NAMES) do
      -- symlink 建在 worktree 的父目录，指向工具检出的绝对路径；根内不建。
      assert.are.equal(abs(TOOLS .. "/" .. t), readlink(WT_PARENT .. "/" .. t))
      assert.is_false(lexists(WT .. "/" .. t))
    end
    -- 只取 tools 节的 source。
    assert.is_false(lexists(WT_PARENT .. "/not-a-tool"))
    assert.is_false(lexists(WT_PARENT .. "/also-not-a-tool"))
  end)

  it("test_second_run_is_noop_and_keeps_existing_entries", function()
    assert.are.equal(0, run(), err.text)
    -- 已存在的条目跳过：skill 内的本地文件不被覆盖，父目录里的真实目录（如主检出旁）不动。
    write_file(WT .. "/.agents/skills/blender-core/local.txt", "keep\n")
    code_of("rm " .. q(WT_PARENT .. "/dryer") .. " && mkdir " .. q(WT_PARENT .. "/dryer"))
    assert.are.equal(0, run(), err.text)
    assert.are.equal("keep\n", slurp(WT .. "/.agents/skills/blender-core/local.txt"))
    assert.is_nil(readlink(WT_PARENT .. "/dryer"))
    assert.matches("跳过", out.text, 1, true)
    assert.are.equal("", err.text)
  end)

  -- 幂等不等于盲跳：已有 symlink 指错地方时报出并失败，不改动它，也不写入别的东西。
  it("test_existing_link_with_wrong_target_fails_and_is_left_alone", function()
    local other = abs(ROOT .. "/elsewhere/crapper")
    fs.mkdirp(other)
    fs.mkdirp(WT_PARENT)
    code_of("ln -s " .. q(other) .. " " .. q(WT_PARENT .. "/crapper"))
    assert.are.equal(1, run())
    assert.matches(WT_PARENT .. "/crapper", err.text, 1, true)
    assert.matches(other, err.text, 1, true)
    assert.matches(abs(TOOLS .. "/crapper"), err.text, 1, true)
    assert.matches("删掉", err.text, 1, true)
    assert.are.equal(other, readlink(WT_PARENT .. "/crapper"))
    assert.is_false(lexists(WT .. "/.agents"))
    assert.is_false(lexists(WT_PARENT .. "/dryer"))
  end)

  -- 中途复制失败时不留下 <名>.partial（否则只能人去清）。
  it("test_failed_skill_copy_removes_partial", function()
    write_file(LIB .. "/blender-rendering/secret.txt", "x\n")
    code_of("chmod 000 " .. q(LIB .. "/blender-rendering/secret.txt"))
    assert.are.equal(1, run())
    assert.matches("blender-rendering", err.text, 1, true)
    assert.is_false(lexists(WT .. "/.agents/skills/blender-rendering.partial"))
    assert.is_false(lexists(WT .. "/.agents/skills/blender-rendering"))
  end)

  it("test_missing_skills_source_fails_before_writing", function()
    local code = run({ "--root", WT, "--skills-from", ROOT .. "/nope", "--tools-from", TOOLS })
    assert.are.equal(1, code)
    assert.matches(ROOT .. "/nope", err.text, 1, true)
    assert.matches("上游 blender-* skill", err.text, 1, true)
    assert.is_false(lexists(WT .. "/.agents"))
    assert.is_false(lexists(WT_PARENT .. "/crapper"))
  end)

  it("test_missing_tool_checkout_fails_before_writing", function()
    code_of("rm -rf " .. q(TOOLS .. "/mutator"))
    local code = run()
    assert.are.equal(1, code)
    assert.matches(TOOLS .. "/mutator", err.text, 1, true)
    assert.is_false(lexists(WT .. "/.agents"))
    assert.is_false(lexists(WT_PARENT .. "/crapper"))
  end)

  -- 默认来源：skill 取 magpie 资源库，工具取 git worktree list 首条（主检出）的父目录。
  it("test_default_sources_use_magpie_library_and_main_worktree_parent", function()
    seam.magpie_library = function() return LIB end
    local main = abs(TOOLS .. "/se-fish")
    stub_git_worktree_list(0, "worktree " .. main .. "\nHEAD abc\nbranch refs/heads/main\n\n"
      .. "worktree " .. abs(WT) .. "\nHEAD def\nbranch refs/heads/impl/x\n\n")
    assert.are.equal(0, run({ "--root", WT }), err.text)
    assert.are.equal("blender-core\n", slurp(WT .. "/.agents/skills/blender-core/SKILL.md"))
    for _, t in ipairs(TOOL_NAMES) do
      assert.are.equal(abs(TOOLS .. "/" .. t), readlink(WT_PARENT .. "/" .. t))
    end
  end)

  it("test_main_worktree_derivation_failure_names_root_cause", function()
    seam.magpie_library = function() return LIB end
    stub_git_worktree_list(128, "fatal: not a git repository\n")
    assert.are.equal(1, run({ "--root", WT }))
    assert.matches("worktree list --porcelain", err.text, 1, true)
    assert.matches("fatal: not a git repository", err.text, 1, true)
    assert.matches("--tools-from", err.text, 1, true)
    assert.is_false(lexists(WT .. "/.agents"))
  end)

  -- 退出码约定（#145）：magpie 资源库要经 WSL interop 推导，推不出属平台不可用，退 3。
  it("test_magpie_library_derivation_failure_exits_3", function()
    seam.magpie_library = function() return nil, "PATH 上找不到 cmd.exe（WSL interop 不可用）" end
    assert.are.equal(3, run({ "--root", WT, "--tools-from", TOOLS }))
    assert.matches("interop 不可用", err.text, 1, true)
    assert.matches("--skills-from", err.text, 1, true)
    assert.is_false(lexists(WT .. "/.agents"))
  end)

  it("test_never_runs_quality_install_and_names_toolcache_owner", function()
    assert.are.equal(0, run(), err.text)
    assert.is_false(lexists(WT .. "/.toolcache"))
    assert.matches("tools/quality/project install", out.text, 1, true)
  end)

  it("test_usage_errors_and_help", function()
    assert.are.equal(2, run({ "--bogus" }))
    assert.matches("用法", err.text, 1, true)
    assert.are.equal(0, run({ "--help" }))
    assert.matches("worktree-init", out.text, 1, true)
  end)
end)
