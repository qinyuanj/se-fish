-- 部署的回归护栏（接缝 1）：断言都从 CLI 那一侧打进去——真 Lua 子进程 + EGGY_WORKSPACE
-- 指向 Windows %TEMP% 下的临时宿主目录，中间真实经过 WSL interop 与 robocopy /MIR。
-- 断言外部行为：回灌后的文件树、stale 删除、退出码、提示类别；不断言内部函数调用。
-- 临时仓库只含三端极小子树，LUA_PATH 指回本仓库，真仓库与真实宿主目录不被碰。
local interpreter = require("tests.support.interpreter")
local q = require("tests.support.sh_quote").q
local seam = require("tools.wsl_seam")

local function slurp(path)
  local f = io.open(path, "rb")
  if not f then return nil end
  local body = f:read("a")
  f:close()
  return body
end

local function code_of(cmd)
  local _, _, code = os.execute(cmd)
  return code
end

local function rmrf(path)
  code_of("rm -rf " .. q(path))
end

local function exists(path)
  return code_of("test -e " .. q(path)) == 0
end

local function write_file(path, body)
  local dir = path:match("^(.*)/[^/]*$")
  if dir then code_of("mkdir -p " .. q(dir)) end
  local f = assert(io.open(path, "wb"), path .. " 建不出来")
  f:write(body)
  f:close()
end

-- 本仓库根的绝对路径：LUA_PATH 与 cli.lua 的位置都从它拼。busted 从仓库根运行。
local REPO = assert(io.popen("pwd")):read("l")
local WINDOWS_TEMP = assert(seam.windows_temp(), "WSL interop 不可用：推不出 %TEMP%")

-- 宿主目录名同时覆盖中文、空格与全角「！」，按唯一前缀隔离，且不落在真实宿主目录里。
local HOST = WINDOWS_TEMP .. "/sefish-deploy-接缝 " .. tostring(os.time()) .. "-"
  .. tostring(math.random(100000, 999999)) .. "！"
local FAKE_REPO = REPO .. "/tmp/deploy-transport-test/repo"
local OUT = REPO .. "/tmp/deploy-transport-test.out"

local function lua_bin()
  return interpreter.path()
end

-- 真 CLI 子进程：cd 进假仓库再跑 deploy，拿回 stdout+stderr 与退出码。
-- path_override 用于模拟 interop 不可用（PATH 里没有 /mnt/c 的 Windows 目录）。
local function run_deploy(args, workspace, path_override)
  local env = "EGGY_WORKSPACE=" .. q(workspace)
  if path_override then env = "env PATH=" .. q(path_override) .. " " .. env end
  local cmd = "cd " .. q(FAKE_REPO) .. " && " .. env
    .. " LUA_PATH=" .. q(REPO .. "/?.lua;" .. REPO .. "/?/init.lua;;")
    .. " " .. q(lua_bin()) .. " " .. q(REPO .. "/tools/cli.lua") .. " deploy"
    .. (args and (" " .. args) or "")
    .. " > " .. q(OUT) .. " 2>&1"
  local code = code_of(cmd)
  return slurp(OUT) or "", code
end

-- 假仓库：三端一级子树各一小块内容，deploy 只看这三棵树。
local function seed_repo()
  rmrf(FAKE_REPO)
  write_file(FAKE_REPO .. "/client/UI/a.lua", "-- 客户端 A\n")
  write_file(FAKE_REPO .. "/client/UI/sub/b.lua", "-- 客户端 B\n")
  write_file(FAKE_REPO .. "/common/GameCfg.lua", "-- 共享配置\n")
  write_file(FAKE_REPO .. "/server/Mgr/c.lua", "-- 服务端 C\n")
end

-- 宿主目录：预置会被 /MIR 删掉的 stale 文件，以及不归本仓库管理的 unit_scripts/。
local function seed_host()
  rmrf(HOST)
  code_of("mkdir -p " .. q(HOST))
  write_file(HOST .. "/client/UI/stale.lua", "-- 宿主多余文件，应被 /MIR 删除\n")
  write_file(HOST .. "/unit_scripts/keep.lua", "-- 宿主自有内容，不动\n")
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
    rmrf(OUT)
    out, code = nil, nil
  end)

  it("test_extra_argument_is_a_usage_error", function()
    out, code = run_deploy("extra", HOST)
    assert.are.equal(2, code, out)
    assert.matches("未知参数", out, 1, true)
  end)

  it("test_help_is_a_success", function()
    out, code = run_deploy("--help", HOST)
    assert.are.equal(0, code, out)
    assert.matches("deploy", out, 1, true)
  end)

  -- 主证据：真 interop + robocopy /MIR，字节到目标侧，stale 删除，宿主自有内容不动。
  it("test_deploy_mirrors_bytes_and_removes_stale_files", function()
    out, code = run_deploy(nil, HOST)
    assert.are.equal(0, code, out)
    assert.matches("deploy ok", out, 1, true)
    assert.matches("编辑器收尾跳过", out, 1, true) -- 临时宿主没有 eggy.json
    assert.are.equal("-- 客户端 A\n", slurp(HOST .. "/client/UI/a.lua"))
    assert.are.equal("-- 客户端 B\n", slurp(HOST .. "/client/UI/sub/b.lua"))
    assert.are.equal("-- 共享配置\n", slurp(HOST .. "/common/GameCfg.lua"))
    assert.are.equal("-- 服务端 C\n", slurp(HOST .. "/server/Mgr/c.lua"))
    assert.is_false(exists(HOST .. "/client/UI/stale.lua"), "宿主多余文件应被 /MIR 删除")
    assert.are.equal("-- 宿主自有内容，不动\n", slurp(HOST .. "/unit_scripts/keep.lua"))
  end)

  -- 连跑两次：第二次 robocopy 无变化仍成功（防 9P 时间戳导致的误判）。
  it("test_second_deploy_is_a_no_op_success", function()
    out, code = run_deploy(nil, HOST)
    assert.are.equal(0, code, out)
    out, code = run_deploy(nil, HOST)
    assert.are.equal(0, code, out)
    assert.are.equal("-- 客户端 A\n", slurp(HOST .. "/client/UI/a.lua"))
  end)

  -- EGGY_WORKSPACE 接受 C:\... 形式：同一宿主目录用 Windows 形式再跑一次。
  it("test_windows_form_workspace_is_accepted", function()
    local pipe = assert(io.popen("wslpath -w " .. q(HOST)))
    local win_host = (pipe:read("l") or ""):gsub("%s+$", "")
    pipe:close()
    assert.is_truthy(win_host:match("^%a:"), "wslpath -w 没有给出 Windows 路径: " .. win_host)
    out, code = run_deploy(nil, win_host)
    assert.are.equal(0, code, out)
    assert.are.equal("-- 客户端 A\n", slurp(HOST .. "/client/UI/a.lua"))
  end)

  -- interop 不可用：镜像之前就以非零退出码失败，宿主目录一个文件都没写。
  it("test_missing_interop_fails_before_mirroring", function()
    local fresh = HOST .. "-no-interop"
    rmrf(fresh)
    out, code = run_deploy(nil, fresh, "/usr/bin:/bin")
    assert.are_not.equal(0, code, out)
    assert.matches("interop 不可用", out, 1, true)
    assert.is_false(exists(fresh), "interop 失败时不应创建宿主目录")
  end)

  -- EGGY_WORKSPACE="" 当作未设置：不能把 /MIR 写到文件系统根。
  it("test_empty_workspace_never_targets_the_filesystem_root", function()
    local root_client_before = exists("/client")
    out, code = run_deploy(nil, "", "/usr/bin:/bin")
    assert.are_not.equal(0, code, out)
    assert.matches("interop 不可用", out, 1, true)
    assert.are.equal(root_client_before, exists("/client"), "空宿主路径不应写到文件系统根")
  end)

  -- 隔离断言：临时宿主必须在 %TEMP% 的唯一前缀内，且不等于真实宿主目录。
  it("test_temporary_host_is_isolated_from_the_real_workspace", function()
    assert.are.equal(WINDOWS_TEMP, HOST:sub(1, #WINDOWS_TEMP), "临时宿主必须在 %TEMP% 下")
    local real = seam.default_workspace()
    assert.is_true(real == nil or real ~= HOST)
  end)
end)
