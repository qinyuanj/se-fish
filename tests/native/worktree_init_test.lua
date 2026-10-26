-- worktree-init 子命令的外部行为（#141，#146 收窄）：在真实临时目录里搭出「资源库 skill 目录 +
-- 新 worktree」，经 main(args) 调用，断言落盘结果、幂等与缺来源时的报错。
-- #146 起质量工具交给 uml-viewer 标准工具（由人经 get-uml-viewer 安装），worktree-init 不再为
-- 质量工具建父目录链接或提示 .toolcache；#147 删除 acceptance4lua 后同样不为其准备缓存。
-- 来源默认用 --skills-from 显式给出；默认推导的用例只桩掉 WSL 接缝层的 magpie_library，不碰 interop。
local init = require("tools.worktree_init")
local seam = require("tools.wsl_seam")
local q = require("tests.support.sh_quote").q
local fs = require("tests.support.sh_fs")
local code_of, slurp, write_file, lexists = fs.code_of, fs.slurp, fs.write_file, fs.lexists

local ROOT = "tmp/worktree-init-test"
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
  assert(ok, code)
  return code
end

local function entries(dir)
  local h = io.popen("ls -A " .. q(dir) .. " 2>/dev/null")
  local names = {}
  for line in h:lines() do names[#names + 1] = line end
  h:close()
  table.sort(names)
  return names
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
    fs.mkdirp(WT)
  end)
  after_each(function()
    io.stdout, io.stderr = saved_out, saved_err
    for k, v in pairs(saved_seam) do seam[k] = v end
    code_of("chmod -R u+rwX " .. q(ROOT) .. " 2>/dev/null; rm -rf " .. q(ROOT))
  end)

  it("test_fresh_worktree_gets_blender_skills", function()
    assert.are.equal(0, run(), err.text)
    assert.are.equal("print('runner')\n",
      slurp(WT .. "/.agents/skills/blender-core/scripts/run_in_blender.py"))
    assert.are.equal("blender-rendering\n", slurp(WT .. "/.agents/skills/blender-rendering/SKILL.md"))
    -- 只复制 blender-*，资源库里的其他 skill 不进来。
    assert.is_false(lexists(WT .. "/.agents/skills/tdd"))
  end)

  -- 质量工具交给 uml-viewer 标准工具后，新 worktree 不需要任何质量工具准备：
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
  it("test_failed_skill_copy_removes_partial", function()
    write_file(LIB .. "/blender-rendering/secret.txt", "x\n")
    code_of("chmod 000 " .. q(LIB .. "/blender-rendering/secret.txt"))
    assert.are.equal(1, run())
    assert.matches("blender-rendering", err.text, 1, true)
    assert.is_false(lexists(WT .. "/.agents/skills/blender-rendering.partial"))
    assert.is_false(lexists(WT .. "/.agents/skills/blender-rendering"))
  end)

  it("test_missing_skills_source_fails_before_writing", function()
    local code = run({ "--root", WT, "--skills-from", ROOT .. "/nope" })
    assert.are.equal(1, code)
    assert.matches(ROOT .. "/nope", err.text, 1, true)
    assert.matches("上游 blender-* skill", err.text, 1, true)
    assert.is_false(lexists(WT .. "/.agents"))
  end)

  -- 默认来源：skill 取 magpie 资源库。
  it("test_default_skills_source_is_magpie_library", function()
    seam.magpie_library = function() return LIB end
    assert.are.equal(0, run({ "--root", WT }), err.text)
    assert.are.equal("blender-core\n", slurp(WT .. "/.agents/skills/blender-core/SKILL.md"))
  end)

  -- 退出码约定（#145）：magpie 资源库要经 WSL interop 推导，推不出属平台不可用，退 3。
  it("test_magpie_library_derivation_failure_exits_3", function()
    seam.magpie_library = function() return nil, "PATH 上找不到 cmd.exe（WSL interop 不可用）" end
    assert.are.equal(3, run({ "--root", WT }))
    assert.matches("interop 不可用", err.text, 1, true)
    assert.matches("--skills-from", err.text, 1, true)
    assert.is_false(lexists(WT .. "/.agents"))
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
    assert.matches("lua5.4 tools/cli.lua test full", out.text, 1, true)
    assert.is_nil(out.text:find("busted --run", 1, true))
    assert.is_nil(out.text:find(".toolcache", 1, true))
    assert.is_nil(out.text:find("tools-from", 1, true))
    assert.is_nil(out.text:find("tools/quality", 1, true))
  end)
end)
