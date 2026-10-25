-- blender 子命令的回归护栏（#125）：真 CLI 子进程 + 真 WSL interop + 真 blender.exe，
-- 跑上游 blender-core 的环境报告与 blender-asset-qa 的 QA 检查，断言 stdout 只有脚本 JSON、
-- 退出码透传。产物只落在 Windows %TEMP% 下的唯一目录（名字含中文与空格，顺带覆盖路径转换）。
-- 需要部署端装有 Blender（或设 BLENDER_EXE）与上游 blender-* skill；命令边界的桩测试见
-- tests/native/blender_cli_test.lua。
local interpreter = require("tests.support.interpreter")
local q = require("tests.support.sh_quote").q
local seam = require("tools.wsl_seam")

local fs = require("tests.support.sh_fs")
local slurp, code_of, rmrf, mkdirp, exists = fs.slurp, fs.code_of, fs.rmrf, fs.mkdirp, fs.exists

local REPO = assert(io.popen("pwd")):read("l")
local WINDOWS_TEMP = assert(seam.windows_temp(), "WSL interop 不可用：推不出 %TEMP%")
local WORK = WINDOWS_TEMP .. "/sefish-blender-接缝 " .. tostring(os.time()) .. "-"
  .. tostring(math.random(100000, 999999))
local OUT = REPO .. "/tmp/blender-transport-test.out"
local ERR = REPO .. "/tmp/blender-transport-test.err"

local ENV_REPORT = ".agents/skills/blender-core/scripts/env_report.py"
local QA_CHECK = ".agents/skills/blender-asset-qa/scripts/qa_check.py"

-- 真 CLI 子进程；stdout 与 stderr 分开落盘，证明 stdout 不夹带 Blender 启动日志。
local function run_blender(args)
  mkdirp(REPO .. "/tmp")
  local cmd = q(interpreter.path()) .. " tools/cli.lua blender " .. args
    .. " > " .. q(OUT) .. " 2> " .. q(ERR)
  local code = code_of(cmd)
  return slurp(OUT) or "", code, slurp(ERR) or ""
end

-- stdout 的非空行：每一行都必须是 JSON 对象（脚本结果），不能有启动横幅。
local function json_lines(out)
  local lines = {}
  for line in out:gmatch("[^\r\n]+") do
    assert.matches("^{.*}$", line, nil, false, "stdout 混入了非 JSON 行: " .. line)
    lines[#lines + 1] = line
  end
  return lines
end

describe("TestBlenderCli", function()
  before_each(function()
    rmrf(WORK)
    mkdirp(WORK)
  end)
  after_each(function()
    rmrf(WORK)
    rmrf(OUT)
    rmrf(ERR)
  end)

  it("test_env_report_returns_blender_version_json", function()
    local out, code, err = run_blender(q(ENV_REPORT))
    assert.are.equal(0, code, err)
    local lines = json_lines(out)
    assert.are.equal(1, #lines, out)
    assert.matches('"ok":true', lines[1], 1, true)
    assert.matches('"blender":"%d+%.%d+', lines[1])
    assert.matches('"background":true', lines[1], 1, true)
  end)

  -- QA 检查：先用 --expr 在临时目录自建最小网格，再以开发端路径形式把 .blend 交给入口。
  it("test_qa_check_on_minimal_mesh_returns_structured_result", function()
    local blend = WORK .. "/最小 网格.blend"
    local expr = table.concat({
      "import bpy, bmesh",
      "me = bpy.data.meshes.new('SefishProbe')",
      "bm = bmesh.new()",
      "bmesh.ops.create_cube(bm, size=1.0)",
      "bm.to_mesh(me)",
      "bm.free()",
      "bpy.context.scene.collection.objects.link(bpy.data.objects.new('SefishProbe', me))",
      "bpy.ops.wm.save_as_mainfile(filepath=" .. string.format("%q", assert(seam.to_windows(blend))) .. ")",
    }, "; ")
    local _, code, err = run_blender("--expr " .. q(expr))
    assert.are.equal(0, code, err)
    assert.is_true(exists(blend), "--expr 没有存下最小网格: " .. blend)

    local out
    out, code, err = run_blender(q(QA_CHECK) .. " --blend " .. q(blend) .. " -- --objects SefishProbe")
    assert.are.equal(0, code, err)
    local lines = json_lines(out)
    assert.are.equal(1, #lines, out)
    assert.matches('"ok":true', lines[1], 1, true)
    assert.matches('"SefishProbe":{', lines[1], 1, true)
    assert.matches('"tris":12', lines[1], 1, true)
    assert.matches('"nonmanifold_edges":0', lines[1], 1, true)
  end)

  -- 脚本失败：非零退出码透传，stdout 仍是结构化 JSON。
  it("test_script_failure_exit_code_is_passed_through", function()
    local out, code, err = run_blender(q(QA_CHECK) .. " -- --objects SefishNoSuchObject")
    assert.are_not.equal(0, code, err)
    local lines = json_lines(out)
    assert.are.equal(1, #lines, out)
    assert.matches('"ok":false', lines[1], 1, true)
    assert.matches("SefishNoSuchObject", lines[1], 1, true)
  end)

  it("test_temporary_work_dir_is_under_windows_temp", function()
    assert.are.equal(WINDOWS_TEMP, WORK:sub(1, #WINDOWS_TEMP), "slow 用例产物必须落在 %TEMP% 下")
  end)
end)
