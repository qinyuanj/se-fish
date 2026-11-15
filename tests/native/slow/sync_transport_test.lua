-- 回同步的回归护栏：断言都从 CLI 那一侧（真 Lua 子进程 + EGGY_WORKSPACE 指向临时
-- 宿主目录）打进去，断言外部行为——回灌后的文件树、行尾归一、stale 删除、退出码；
-- 不断言内部函数调用。目的地是「当前目录=仓库根」，所以子进程统一以临时假仓库为 cwd，
-- 入口按自身绝对位置定位仓库模块，真仓库不被碰。
-- 迁移自 tests/tooling/slow/sync_transport_test.lua（#92，LuaUnit → 原生 Busted）。
-- ADR-0017 起只有 Windows 原生环境（#189）：子进程经 tools.seam 发起，夹具用 fs_fixture。
-- sync 自身不调 robocopy，所以这批案例只证明回灌逻辑正确，不证明 robocopy 可用。
local interpreter = require("tests.support.interpreter")
local fs = require("tests.support.fs_fixture")
local seam = require("tools.seam")

local slurp, exists, rmrf, write_file = fs.slurp, fs.exists, fs.rmrf, fs.write_file

-- 本仓库根的绝对路径：假仓库与输出文件都挂在仓库 tmp/ 下。busted 从仓库根运行。
local REPO = fs.repo_root()
local ROOT = REPO .. "/tmp/sync-transport-test"
-- 宿主目录名同时覆盖中文、空格与全角「！」，与 deploy 用例同口径。
local HOST = ROOT .. "/宿主 目录！"
local FAKE_REPO = ROOT .. "/repo"
local OUT = ROOT .. ".out"
-- 真入口按脚本自身位置推仓库根，所以传绝对路径、cwd 仍是假仓库（sync 按当前目录落盘）。
local CLI = REPO .. "/tools/cli.lua"

local function write_host(rel, body)
  write_file(HOST .. "/" .. rel, body)
end

local function write_repo(rel, body)
  write_file(FAKE_REPO .. "/" .. rel, body)
end

-- 真 CLI 子进程：以假仓库为 cwd 跑 sync，拿回 stdout+stderr 与退出码。
local function run_sync(args, cwd)
  fs.mkdirp(ROOT)
  fs.mkdirp(FAKE_REPO)
  os.remove(OUT)
  local argv = { interpreter.path(), CLI, "sync" }
  if args then argv[#argv + 1] = args end
  local code = seam.spawn({
    argv = argv,
    cwd = cwd or FAKE_REPO,
    env = { EGGY_WORKSPACE = HOST },
    stdout = OUT,
    stderr = OUT,
  })
  return slurp(OUT) or "", code
end

-- 临时宿主目录：eggy.json、两份存根 + data/（含嵌套子目录）全是 CRLF；eggy.json 与
-- unit_scripts/ 是宿主侧非回同步内容。临时假仓库：eggy.json 是仓库自有内容，EggyAPI.lua 与宿主归一后
-- 一致（造「未变」），data/ 里有旧内容、有 stale，server/ 是仓库自有内容。
local function seed_and_sync()
  rmrf(ROOT)
  fs.mkdirp(FAKE_REPO)
  write_host("eggy.json", '{\r\n  "projectName": "fixture"\r\n}\r\n')
  write_host("EggyAPI.lua", "-- 宿主目录里的 API 存根\r\n")
  write_host("EggyEditorAPI.lua", "-- 宿主目录里的编辑时 API 存根\r\n")
  write_host("data/FontData.lua", "-- 字体\r\n")
  write_host("data/Prefab.lua", "-- 预制\r\n")
  write_host("data/sub/Nested.lua", "-- 嵌套\r\n")
  write_host("unit_scripts/keep.lua", "-- 只活在宿主目录里\r\n")
  write_repo("eggy.json", "old-binding\n")
  write_repo("EggyAPI.lua", "-- 宿主目录里的 API 存根\n")
  write_repo("data/Prefab.lua", "-- 旧预制\n")
  write_repo("data/Stale.lua", "-- 宿主侧已经删了\n")
  write_repo("server/main.lua", "-- 仓库自有内容\n")
  return run_sync(nil)
end

describe("TestSyncCli", function()
  local out, code
  before_each(function()
    rmrf(ROOT)
    fs.mkdirp(FAKE_REPO)
  end)
  after_each(function()
    rmrf(ROOT)
    os.remove(OUT)
    out, code = nil, nil
  end)

  it("test_extra_argument_is_a_usage_error", function()
    out, code = run_sync("extra")
    assert.are.equal(2, code, out)
    assert.matches("未知参数", out, 1, true)
  end)

  it("test_help_is_a_success", function()
    out, code = run_sync("--help")
    assert.are.equal(0, code, out)
    assert.matches("sync", out, 1, true)
  end)

  -- 宿主目录不存在是业务失败（1），不是用法错误（2）。
  it("test_missing_workspace_is_a_business_failure", function()
    out, code = run_sync(nil, nil)
    assert.are.equal(1, code, out)
    assert.matches("编辑器宿主目录不存在", out, 1, true)
  end)
end)

describe("TestSyncIdempotent", function()
  local out, code
  before_each(function()
    seed_and_sync()
    out, code = run_sync(nil)
  end)
  after_each(function()
    rmrf(ROOT)
    os.remove(OUT)
    out, code = nil, nil
  end)

  -- 幂等：内容没变时不产生改动，第二轮没有写入也没有删除。
  it("test_second_run_changes_nothing", function()
    assert.are.equal(0, code, "sync 输出:\n" .. out)
    assert.matches("0 写入, 0 删除,", out, 1, true)
    assert.is_nil(out:find("write ", 1, true))
    assert.is_nil(out:find("delete ", 1, true))
  end)
end)

-- 缺一个源就整体不写：错误可读，仓库侧保持原样。
describe("TestSyncMissingSource", function()
  local out, code
  before_each(function()
    rmrf(ROOT)
    fs.mkdirp(FAKE_REPO)
    write_host("eggy.json", "{}\r\n")
    write_host("EggyAPI.lua", "-- 存根\r\n")
    write_host("data/FontData.lua", "-- 字体\r\n")
    write_repo("eggy.json", "sentinel\n")
    write_repo("data/Stale.lua", "-- 还活着\n")
    out, code = run_sync(nil)
  end)
  after_each(function()
    rmrf(ROOT)
    os.remove(OUT)
    out, code = nil, nil
  end)

  it("test_missing_source_is_a_business_failure", function()
    assert.are.equal(1, code, out)
    assert.matches("EggyEditorAPI.lua", out, 1, true)
  end)

  it("test_nothing_is_written", function()
    assert.are.equal("sentinel\n", slurp(FAKE_REPO .. "/eggy.json"))
    assert.is_false(exists(FAKE_REPO .. "/data/FontData.lua"), "缺源还落了半截")
    assert.is_true(exists(FAKE_REPO .. "/data/Stale.lua"), "缺源还删了文件")
  end)
end)

-- 三端官方包由仓库管理：sync 不回灌，--packages 已移除。
describe("TestSyncPackages", function()
  local out, code
  before_each(function()
    seed_and_sync()
    write_repo("eggy.json", "sentinel\n")
    for _, side in ipairs({ "server", "client", "common" }) do
      write_host(side .. "/packages/fixture/api.lua", "-- 官方包\r\nreturn {}\r\n")
      write_repo(side .. "/packages/old/stale.lua", "-- 旧包\n")
    end
  end)
  after_each(function()
    rmrf(ROOT)
    os.remove(OUT)
    out, code = nil, nil
  end)

  it("test_default_sync_does_not_touch_packages", function()
    out, code = run_sync(nil)
    assert.are.equal(0, code, out)
    assert.is_nil(slurp(FAKE_REPO .. "/server/packages/fixture/api.lua"))
    assert.are.equal("-- 旧包\n", slurp(FAKE_REPO .. "/server/packages/old/stale.lua"))
  end)

  it("test_packages_flag_is_a_usage_error", function()
    out, code = run_sync("--packages")
    assert.are.equal(2, code, out)
    assert.matches("未知参数", out, 1, true)
    assert.is_nil(slurp(FAKE_REPO .. "/server/packages/fixture/api.lua"))
    assert.are.equal("-- 旧包\n", slurp(FAKE_REPO .. "/server/packages/old/stale.lua"))
  end)
end)

describe("TestSyncTransport", function()
  local out, code
  before_each(function()
    out, code = seed_and_sync()
  end)
  after_each(function()
    rmrf(ROOT)
    os.remove(OUT)
    out, code = nil, nil
  end)

  -- 宿主侧是 CRLF 的产物落进仓库后是 LF，git status 才不会有行尾噪音。
  it("test_crlf_is_normalized_to_lf", function()
    for _, rel in ipairs({ "EggyEditorAPI.lua", "data/FontData.lua" }) do
      assert.is_nil((slurp(FAKE_REPO .. "/" .. rel) or ""):find("\r", 1, true), rel .. " 里还有 CR")
    end
  end)

  it("test_data_dir_is_mirrored_recursively", function()
    assert.are.equal("-- 字体\n", slurp(FAKE_REPO .. "/data/FontData.lua"))
    assert.are.equal("-- 预制\n", slurp(FAKE_REPO .. "/data/Prefab.lua"))
    assert.are.equal("-- 嵌套\n", slurp(FAKE_REPO .. "/data/sub/Nested.lua"))
  end)

  -- 宿主目录是源，sync 一个字节都不许往回写；非回同步内容（unit_scripts/ 等）不进仓库。
  it("test_host_side_is_untouched", function()
    assert.are.equal('{\r\n  "projectName": "fixture"\r\n}\r\n', slurp(HOST .. "/eggy.json"))
    assert.is_true(exists(HOST .. "/unit_scripts/keep.lua"))
    assert.is_false(exists(FAKE_REPO .. "/unit_scripts"), "宿主侧非回同步内容进了仓库")
  end)

  it("test_root_files_are_synced", function()
    assert.are.equal("-- 宿主目录里的编辑时 API 存根\n", slurp(FAKE_REPO .. "/EggyEditorAPI.lua"))
  end)

  -- #166：宿主 eggy.json 带宿主侧绑定信息，不回灌；仓库那份原样保留（只留 isSEMap，由守卫把关）。
  it("test_eggy_json_is_not_synced", function()
    assert.are.equal("old-binding\n", slurp(FAKE_REPO .. "/eggy.json"))
    assert.is_nil(out:find("write eggy.json", 1, true))
  end)

  it("test_stale_repo_files_are_deleted", function()
    assert.is_false(exists(FAKE_REPO .. "/data/Stale.lua"), "stale 文件没被抹掉")
    assert.matches("delete data/Stale.lua", out, 1, true)
  end)

  it("test_sync_succeeds", function()
    assert.are.equal(0, code, "sync 输出:\n" .. out)
    assert.matches("sync ok", out, 1, true)
  end)

  it("test_unrelated_repo_content_is_untouched", function()
    assert.are.equal("-- 仓库自有内容\n", slurp(FAKE_REPO .. "/server/main.lua"))
  end)

  it("test_write_is_reported", function()
    assert.matches("write data/Prefab.lua", out, 1, true)
  end)
end)
