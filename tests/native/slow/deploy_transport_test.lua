-- 部署的回归护栏（接缝 1）：断言都从 CLI 那一侧打进去——真 Lua 子进程 + EGGY_WORKSPACE
-- 指向 Windows %TEMP% 下的临时宿主目录，中间真实经过 tools.seam 与 robocopy /MIR。
-- 断言外部行为：镜像后的文件树、stale 删除、退出码、提示类别；不断言内部函数调用。
-- 临时仓库只含三端极小子树，真仓库与真实宿主目录不被碰（ADR-0017：Windows 原生单环境）。
local interpreter = require("tests.support.interpreter")
local fs = require("tests.support.fs_fixture")
local seam = require("tools.seam")

local slurp, exists, rmrf, write_file = fs.slurp, fs.exists, fs.rmrf, fs.write_file

-- 本仓库根的绝对路径：cli.lua 的位置与 LUA_PATH 都从它拼。busted 从仓库根运行。
local REPO = fs.repo_root()
local WINDOWS_TEMP = assert(seam.windows_temp(), "读不到 %TEMP%，无法隔离临时宿主目录")

-- 宿主目录名同时覆盖中文、空格与全角「！」，按唯一前缀隔离，且不落在真实宿主目录里。
local HOST = WINDOWS_TEMP .. "/sefish-deploy-接缝 " .. tostring(os.time()) .. "-"
  .. tostring(math.random(100000, 999999)) .. "！"
local FAKE_REPO = REPO .. "/tmp/deploy-transport-test/repo"
-- PATH 里不含 System32 的「空 bin」：用它模拟 robocopy 缺失。
local EMPTY_BIN = REPO .. "/tmp/deploy-transport-test/empty-bin"
local OUT = REPO .. "/tmp/deploy-transport-test.out"
-- 真入口按脚本自身位置推仓库根，所以传绝对路径、cwd 仍是假仓库（deploy 按当前目录读写）。
local CLI = REPO .. "/tools/cli.lua"

-- 真 CLI 子进程：以假仓库为 cwd 跑 deploy，拿回 stdout+stderr 与退出码。
-- env_override 用于模拟 robocopy 缺失（PATH 指向不含 System32 的目录）。
local function run_deploy(args, workspace, env_override)
  local env = { EGGY_WORKSPACE = workspace }
  for k, v in pairs(env_override or {}) do env[k] = v end
  local argv = { interpreter.path(), CLI, "deploy" }
  if args then argv[#argv + 1] = args end
  fs.mkdirp(REPO .. "/tmp")
  os.remove(OUT)
  local code = seam.spawn({ argv = argv, cwd = FAKE_REPO, env = env, stdout = OUT, stderr = OUT })
  return slurp(OUT) or "", code
end

-- 假仓库：三端一级子树各一小块内容，deploy 只看这三棵树。
local function seed_repo()
  rmrf(FAKE_REPO)
  fs.mkdirp(FAKE_REPO)
  write_file(FAKE_REPO .. "/client/UI/a.lua", "-- 客户端 a\n")
  write_file(FAKE_REPO .. "/client/UI/sub/b.lua", "-- 客户端 b\n")
  write_file(FAKE_REPO .. "/common/game_cfg.lua", "-- 共享配置\n")
  write_file(FAKE_REPO .. "/server/mgr/c.lua", "-- 服务端 C\n")
end

-- 宿主目录：预置会被 /MIR 删掉的 stale 文件、仓库已删的端根散文件与整棵子树（#167），
-- 以及不归本仓库管理的 unit_scripts/、temp/。
local function seed_host()
  rmrf(HOST)
  fs.mkdirp(HOST)
  write_file(HOST .. "/client/UI/stale.lua", "-- 宿主多余文件，应被 /MIR 删除\n")
  write_file(HOST .. "/client/AttrAPI.lua", "-- 仓库已删的端根散文件\n")
  write_file(HOST .. "/server/Proto/water.lua", "-- 仓库已删的子树\n")
  write_file(HOST .. "/unit_scripts/keep.lua", "-- 宿主自有内容，不动\n")
  write_file(HOST .. "/temp/keep.lua", "-- 编辑器生成物，不动\n")
end

describe("TestDeployCli", function()
  local out, code
  before_each(function()
    seed_repo()
    seed_host()
    out, code = nil, nil
  end)
  after_each(function()
    rmrf(HOST)
    rmrf(FAKE_REPO)
    rmrf(EMPTY_BIN)
    rmrf(REPO .. "/tmp/deploy-transport-test")
    os.remove(OUT)
    out, code = nil, nil
  end)

  -- 主证据：真接缝 + robocopy /MIR，字节到目标侧，stale 删除，宿主自有内容不动。
  it("test_deploy_mirrors_bytes_and_removes_stale_files", function()
    out, code = run_deploy(nil, HOST)
    assert.are.equal(0, code, out)
    assert.matches("deploy ok", out, 1, true)
    assert.matches("编辑器收尾跳过", out, 1, true) -- 临时宿主没有 eggy.json
    assert.are.equal("-- 客户端 a\n", slurp(HOST .. "/client/UI/a.lua"))
    assert.are.equal("-- 客户端 b\n", slurp(HOST .. "/client/UI/sub/b.lua"))
    assert.are.equal("-- 共享配置\n", slurp(HOST .. "/common/game_cfg.lua"))
    assert.are.equal("-- 服务端 C\n", slurp(HOST .. "/server/mgr/c.lua"))
    assert.is_false(exists(HOST .. "/client/UI/stale.lua"), "宿主多余文件应被 /MIR 删除")
    assert.is_false(exists(HOST .. "/client/AttrAPI.lua"), "仓库已删的端根散文件应被删除")
    assert.is_false(exists(HOST .. "/server/Proto"), "仓库已删的子树应被删除")
    assert.matches("删除宿主残留: client/AttrAPI.lua", out, 1, true)
    assert.are.equal("-- 宿主自有内容，不动\n", slurp(HOST .. "/unit_scripts/keep.lua"))
    assert.are.equal("-- 编辑器生成物，不动\n", slurp(HOST .. "/temp/keep.lua"))
  end)

  -- 连跑两次：第二次 robocopy 无变化仍成功（防时间戳导致的误判）。
  it("test_second_deploy_is_a_no_op_success", function()
    out, code = run_deploy(nil, HOST)
    assert.are.equal(0, code, out)
    out, code = run_deploy(nil, HOST)
    assert.are.equal(0, code, out)
    assert.are.equal("-- 客户端 a\n", slurp(HOST .. "/client/UI/a.lua"))
  end)

  -- 路径只有一种形式（正斜杠+盘符），反斜杠形式进接缝即归一：同一宿主目录用反斜杠再跑一次。
  it("test_backslash_workspace_is_accepted", function()
    local backslash_host = HOST:gsub("/", function() return "\\" end)
    assert.is_truthy(backslash_host:match("^%a:\\"), "临时宿主应是 Windows 路径: " .. backslash_host)
    out, code = run_deploy(nil, backslash_host)
    assert.are.equal(0, code, out)
    assert.are.equal("-- 客户端 a\n", slurp(HOST .. "/client/UI/a.lua"))
  end)

  -- 反面用例：robocopy 缺失 → preflight 失败、退出码 3、宿主目录一个文件都没建。
  -- PATH 指向不含 System32 的空目录，lua 仍按绝对路径启动，所以失败只可能来自 preflight。
  it("test_missing_robocopy_fails_before_mirroring", function()
    local fresh = HOST .. "-no-robocopy"
    rmrf(fresh)
    fs.mkdirp(EMPTY_BIN)
    out, code = run_deploy(nil, fresh, { PATH = EMPTY_BIN })
    assert.are.equal(3, code, out) -- 外部工具不可用（#145）
    assert.matches("部署工具不可用", out, 1, true)
    assert.is_false(exists(fresh), "preflight 失败时不应创建宿主目录")
    assert.is_false(exists(fresh .. "/client"), "preflight 失败时不应写入任何文件")
  end)

  -- EGGY_WORKSPACE="" 当作未设置（fast 车道的 seam 测试已钉住这一解析）：
  -- 这里在 robocopy 缺失的子进程里再证一次不会把 /MIR 写到文件系统根。
  it("test_empty_workspace_never_targets_the_filesystem_root", function()
    local drive_root = WINDOWS_TEMP:match("^(%a:)/") or "C:"
    local root_client = drive_root .. "/client"
    local root_client_before = exists(root_client)
    fs.mkdirp(EMPTY_BIN)
    out, code = run_deploy(nil, "", { PATH = EMPTY_BIN })
    assert.are.equal(3, code, out) -- 外部工具不可用（#145）
    assert.matches("部署工具不可用", out, 1, true)
    assert.are.equal(root_client_before, exists(root_client), "空宿主路径不应写到文件系统根")
  end)

  -- 隔离断言：临时宿主必须在 %TEMP% 的唯一前缀内，且不等于真实宿主目录。
  it("test_temporary_host_is_isolated_from_the_real_workspace", function()
    assert.are.equal(WINDOWS_TEMP, HOST:sub(1, #WINDOWS_TEMP), "临时宿主必须在 %TEMP% 下")
    assert.is_false(exists(HOST .. "/eggy.json"), "临时宿主不得有 eggy.json，否则会走进真实编辑器收尾")
    local real = seam.default_workspace()
    assert.is_true(real == nil or real ~= HOST)
  end)
end)
