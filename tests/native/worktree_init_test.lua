-- worktree-init 子命令的外部行为（#141，#146 收窄）：在临时目录里搭出「资源库 skill 目录 +
-- 新 worktree」，经 main(args) 调用，断言落盘结果、幂等与缺来源时的报错。
-- #146 起质量工具交给标准工具（现由 dsh-uml-viewer 插件自带），worktree-init 不再为
-- 质量工具建父目录链接或提示 .toolcache；#147 删除 acceptance4lua 后同样不为其准备缓存。
-- Windows 原生（#191）：临时目录用 fs_fixture.temp_dir（仓库 tmp/），落盘/枚举/删除走纯 Lua；
-- 复制失败的注入用 seam.list_entries 桩（fast 车道整模块桩接缝的口径，不靠 chmod）。
local init = require("tools.worktree_init")
local seam = require("tools.seam")
local fs = require("tests.support.fs_fixture")
local write_file, slurp, exists = fs.write_file, fs.slurp, fs.exists

local ROOT = fs.temp_dir()
local LIB = ROOT .. "/library"
local WT_PARENT = ROOT .. "/wt-parent"
local WT = WT_PARENT .. "/se-fish"

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
  local ok, code = pcall(init.main, extra or { "--root", WT, "--skills-from", LIB })
  io.stdout, io.stderr = saved_out, saved_err
  assert(ok, tostring(code))
  return code
end

local function entries(dir) return fs.list_dir(dir) end

describe("TestWorktreeInit", function()
  before_each(function()
    saved_out, saved_err = io.stdout, io.stderr
    saved_seam = { list_entries = seam.list_entries, magpie_library = seam.magpie_library }
    fs.rmrf(ROOT)
    for _, name in ipairs({ "blender-core", "blender-rendering", "tdd" }) do
      write_file(LIB .. "/" .. name .. "/SKILL.md", name .. "\n")
    end
    write_file(LIB .. "/blender-core/scripts/run_in_blender.py", "print('runner')\n")
    fs.mkdirp(WT)
  end)
  after_each(function()
    io.stdout, io.stderr = saved_out, saved_err
    for k, v in pairs(saved_seam) do seam[k] = v end
    fs.rmrf(ROOT)
  end)

  it("test_fresh_worktree_gets_blender_skills", function()
    assert.are.equal(0, run(), err.text)
    assert.are.equal("print('runner')\n",
      slurp(WT .. "/.agents/skills/blender-core/scripts/run_in_blender.py"))
    assert.are.equal("blender-rendering\n", slurp(WT .. "/.agents/skills/blender-rendering/SKILL.md"))
    -- 只复制 blender-*，资源库里的其他 skill 不进来。
    assert.is_false(exists(WT .. "/.agents/skills/tdd"))
  end)

  -- 质量工具交给 dsh-uml-viewer 插件自带的标准工具后，新 worktree 不需要任何质量工具准备：
  -- 不读质量配置、不在父目录建工具链接、不提示 .toolcache 或项目质量入口；
  -- acceptance4lua 已删除（#147），也不为它准备缓存。
  it("test_prepares_nothing_for_quality_or_deleted_tools", function()
    assert.are.equal(0, run(), err.text)
    assert.are.same({ "se-fish" }, entries(WT_PARENT))
    assert.are.same({ ".agents" }, entries(WT))
    assert.is_nil(out.text:find(".toolcache", 1, true))
    assert.is_nil(out.text:find("tools/quality", 1, true))
    assert.is_nil(out.text:find("acceptance4lua", 1, true))
    assert.are.equal("", err.text)
  end)

  it("test_second_run_is_noop_and_keeps_existing_entries", function()
    assert.are.equal(0, run(), err.text)
    -- 已存在的条目跳过：skill 内的本地文件不被覆盖。
    write_file(WT .. "/.agents/skills/blender-core/local.txt", "keep\n")
    assert.are.equal(0, run(), err.text)
    assert.are.equal("keep\n", slurp(WT .. "/.agents/skills/blender-core/local.txt"))
    assert.matches("跳过", out.text, 1, true)
    assert.are.equal("", err.text)
  end)

  -- 中途复制失败时不留下 <名>.partial（否则只能人去清）。
  -- 注入方式：让 seam.list_entries 对某个源目录多报一个不存在的文件，复制到它时 io.open 失败。
  it("test_failed_skill_copy_removes_partial", function()
    local real = saved_seam.list_entries
    seam.list_entries = function(dir)
      local list = real(dir)
      if dir == LIB .. "/blender-rendering" then
        list[#list + 1] = { name = "phantom-missing.txt", dir = false }
      end
      return list
    end
    assert.are.equal(1, run())
    assert.matches("blender-rendering", err.text, 1, true)
    assert.is_false(exists(WT .. "/.agents/skills/blender-rendering.partial"))
    assert.is_false(exists(WT .. "/.agents/skills/blender-rendering"))
  end)

  it("test_missing_skills_source_fails_before_writing", function()
    local code = run({ "--root", WT, "--skills-from", ROOT .. "/nope" })
    assert.are.equal(1, code)
    assert.matches(ROOT .. "/nope", err.text, 1, true)
    assert.matches("上游 blender-* skill", err.text, 1, true)
    assert.is_false(exists(WT .. "/.agents"))
  end)

  -- 默认来源：skill 取 magpie 资源库。
  it("test_default_skills_source_is_magpie_library", function()
    seam.magpie_library = function() return LIB end
    assert.are.equal(0, run({ "--root", WT }), err.text)
    assert.are.equal("blender-core\n", slurp(WT .. "/.agents/skills/blender-core/SKILL.md"))
  end)

  -- 退出码约定（#145）：magpie 资源库由 USERPROFILE 推导，推不出属外部工具不可用，退 3。
  it("test_magpie_library_derivation_failure_exits_3", function()
    seam.magpie_library = function() return nil, "环境变量 USERPROFILE 未设置" end
    assert.are.equal(3, run({ "--root", WT }))
    assert.matches("USERPROFILE", err.text, 1, true)
    assert.matches("--skills-from", err.text, 1, true)
    assert.is_false(exists(WT .. "/.agents"))
  end)

  it("test_usage_errors_and_help", function()
    assert.are.equal(2, run({ "--bogus" }))
    assert.matches("用法", err.text, 1, true)
    -- 工具链接已移除，--tools-from 不再是参数。
    assert.are.equal(2, run({ "--root", WT, "--tools-from", ROOT }))
    assert.matches("--tools-from", err.text, 1, true)
    assert.are.equal(0, run({ "--help" }))
    assert.matches("worktree-init", out.text, 1, true)
    -- 帮助里的车道口径与 CLI 一致（#147）：收尾命令是 test full，不再是裸 busted。
    assert.matches("lua tools/cli.lua test full", out.text, 1, true)
    assert.is_nil(out.text:find("busted --run", 1, true))
    assert.is_nil(out.text:find(".toolcache", 1, true))
    assert.is_nil(out.text:find("tools-from", 1, true))
    assert.is_nil(out.text:find("tools/quality", 1, true))
  end)
end)
