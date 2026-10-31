-- 部署计划护栏：三端 packages 与业务子树同属清单，镜像和 --clean 消费相同目标。
-- 所有目录枚举与传输均用夹具替代，不碰真实宿主目录、不启动编辑器。
local plan = require("tools.deploy_plan")

local WORKSPACE = "fixture-host"
local ENTRIES = {
  client = { { name = "UI", dir = true }, { name = "packages", dir = true } },
  common = { { name = "GameCfg.lua", dir = false }, { name = "packages", dir = true } },
  server = { { name = "Mgr", dir = true }, { name = "packages", dir = true } },
}
local EXPECTED = {
  { rel = "client/UI", dir = true, src = "client/UI", dst = WORKSPACE .. "/client/UI" },
  { rel = "client/packages", dir = true, src = "client/packages", dst = WORKSPACE .. "/client/packages" },
  { rel = "common/GameCfg.lua", dir = false, src = "common/GameCfg.lua", dst = WORKSPACE .. "/common/GameCfg.lua" },
  { rel = "common/packages", dir = true, src = "common/packages", dst = WORKSPACE .. "/common/packages" },
  { rel = "server/Mgr", dir = true, src = "server/Mgr", dst = WORKSPACE .. "/server/Mgr" },
  { rel = "server/packages", dir = true, src = "server/packages", dst = WORKSPACE .. "/server/packages" },
}

-- 宿主三端根的一级条目；默认与仓库一致（没有残留），用例按需改写。
local HOST_ENTRIES

local function list_entries(path)
  local prefix = WORKSPACE .. "/"
  if path:sub(1, #prefix) == prefix then
    local realm = path:sub(#prefix + 1)
    return assert(HOST_ENTRIES[realm], "不应枚举宿主白名单之外的目录: " .. path)
  end
  return assert(ENTRIES[path], "不应枚举部署白名单之外的目录: " .. path)
end

local function same_as_repo()
  return { client = ENTRIES.client, common = ENTRIES.common, server = ENTRIES.server }
end

-- 宿主残留：仓库已删的端根散文件与整棵子树，同名条目不算残留。
local STALE_HOST = {
  client = { { name = "AttrAPI.lua", dir = false }, { name = "UI", dir = true },
    { name = "packages", dir = true } },
  common = ENTRIES.common,
  server = { { name = "Mgr", dir = true }, { name = "Proto", dir = true },
    { name = "packages", dir = true } },
}
local STALE = {
  { rel = "client/AttrAPI.lua", dir = false, dst = WORKSPACE .. "/client/AttrAPI.lua" },
  { rel = "server/Proto", dir = true, dst = WORKSPACE .. "/server/Proto" },
}

describe("TestDeployPlan", function()
  before_each(function() HOST_ENTRIES = same_as_repo() end)

  it("test_targets_include_packages_and_business_entries_in_all_realms", function()
    assert.same(EXPECTED, plan.targets(WORKSPACE, list_entries))
  end)

  it("test_custom_realms_limit_the_target_list", function()
    assert.same({ EXPECTED[5], EXPECTED[6] }, plan.targets(WORKSPACE, list_entries, { "server" }))
  end)

  it("test_stale_is_empty_when_host_matches_repo", function()
    assert.same({}, plan.stale(WORKSPACE, list_entries))
  end)

  it("test_stale_lists_host_realm_entries_missing_from_repo", function()
    HOST_ENTRIES = STALE_HOST
    assert.same(STALE, plan.stale(WORKSPACE, list_entries))
  end)

  it("test_stale_tolerates_missing_host_realm", function()
    HOST_ENTRIES = { client = {}, common = {}, server = {} }
    assert.same({}, plan.stale(WORKSPACE, list_entries))
  end)
end)

describe("TestDeployOwnedTargets", function()
  local saved, deployed, removed, finalized, deploy
  local MODULES = { "tools.deploy", "tools.eggy_workspace", "tools.wsl_seam", "tools.editor_finalize" }

  before_each(function()
    HOST_ENTRIES = same_as_repo()
    saved = { path = package.path, modules = {} }
    for _, name in ipairs(MODULES) do saved.modules[name] = package.loaded[name] end
    deployed, removed, finalized = {}, {}, 0
    package.loaded["tools.deploy"] = nil
    package.loaded["tools.eggy_workspace"] = { resolve = function() return WORKSPACE end }
    package.loaded["tools.wsl_seam"] = {
      interop = function() return true, { cmd = "cmd.exe", robocopy = "robocopy.exe" } end,
      is_dir = function() return true end,
      exists = function(path)
        for _, t in ipairs(removed) do
          if t.dst == path then return false end
        end
        return true
      end,
      list_entries = list_entries,
      list_files = function() return {} end,
      mirror = function(target)
        deployed[#deployed + 1] = target
        return true, 0
      end,
      remove = function(target) removed[#removed + 1] = target end,
    }
    package.loaded["tools.editor_finalize"] = {
      run = function(ws)
        assert.are.equal(WORKSPACE, ws)
        finalized = finalized + 1
        return true
      end,
    }
    deploy = require("tools.deploy")
  end)

  after_each(function()
    for _, name in ipairs(MODULES) do package.loaded[name] = saved.modules[name] end
    package.path = saved.path
    saved, deploy = nil, nil
  end)

  it("test_mirror_and_clean_consume_the_same_owned_targets", function()
    assert.are.equal(0, deploy.main({}))
    assert.same(EXPECTED, deployed)
    assert.same({}, removed)
    assert.are.equal(1, finalized)

    assert.are.equal(0, deploy.main({ "--clean" }))
    assert.same(EXPECTED, removed)
    assert.same(deployed, removed)
    assert.are.equal(1, finalized, "--clean 不应进入编辑器收尾")
  end)

  -- 宿主端根下仓库已删的条目在镜像前删掉，再照常镜像与收尾。
  it("test_deploy_removes_stale_host_entries_before_mirroring", function()
    HOST_ENTRIES = STALE_HOST
    assert.are.equal(0, deploy.main({}))
    assert.same(STALE, removed)
    assert.same(EXPECTED, deployed)
    assert.are.equal(1, finalized)
  end)

  it("test_stale_entry_that_survives_removal_fails_deploy", function()
    HOST_ENTRIES = STALE_HOST
    package.loaded["tools.wsl_seam"].remove = function() end
    local err = ""
    local saved_stderr = io.stderr
    io.stderr = { write = function(self, ...)
      for _, v in ipairs({ ... }) do err = err .. tostring(v) end
      return self
    end }
    local code = deploy.main({})
    io.stderr = saved_stderr
    assert.are.equal(1, code)
    assert.matches("client/AttrAPI.lua", err, 1, true)
    assert.same({}, deployed, "残留删不掉时不应开始镜像")
    assert.are.equal(0, finalized)
  end)
end)

-- 退出码约定（#145）：interop 或 editor-cli.exe 推导失败属平台不可用，退 3；
-- ADR 0008 的「编辑器没装 → 打印跳过」仍退 0。编辑器收尾走真实模块，只桩接缝层。
describe("TestDeployExitCodes", function()
  local saved, deploy, world, err_text
  local MODULES = { "tools.deploy", "tools.eggy_workspace", "tools.wsl_seam", "tools.editor_finalize" }
  local EXE = "/mnt/c/Users/u/.eggitor/cli/editor-cli.exe"

  before_each(function()
    HOST_ENTRIES = same_as_repo()
    saved = { modules = {}, print = print, stderr = io.stderr }
    for _, name in ipairs(MODULES) do saved.modules[name] = package.loaded[name] end
    world = { interop = true, editor_cli = EXE, exe_exists = true }
    err_text = ""
    package.loaded["tools.deploy"] = nil
    package.loaded["tools.editor_finalize"] = nil
    package.loaded["tools.eggy_workspace"] = { resolve = function() return WORKSPACE end }
    package.loaded["tools.wsl_seam"] = {
      q = function(v) return "'" .. tostring(v) .. "'" end,
      interop = function()
        if world.interop then return true end
        return nil, "PATH 上找不到 cmd.exe（WSL interop 不可用）"
      end,
      editor_cli = function()
        if world.editor_cli then return world.editor_cli end
        return nil, "PATH 上找不到 cmd.exe（WSL interop 不可用）"
      end,
      is_dir = function() return true end,
      exists = function(path)
        if path == EXE then return world.exe_exists end
        return true
      end,
      list_entries = list_entries,
      list_files = function() return {} end,
      mirror = function() return true, 0 end,
      remove = function() end,
    }
    _G.print = function() end
    io.stderr = { write = function(self, ...)
      for _, v in ipairs({ ... }) do err_text = err_text .. tostring(v) end
      return self
    end }
    deploy = require("tools.deploy")
  end)

  after_each(function()
    for _, name in ipairs(MODULES) do package.loaded[name] = saved.modules[name] end
    _G.print, io.stderr = saved.print, saved.stderr
    saved, deploy = nil, nil
  end)

  it("test_missing_interop_exits_3", function()
    world.interop = false
    assert.are.equal(3, deploy.main({}))
    assert.matches("interop 不可用", err_text, 1, true)
  end)

  it("test_editor_cli_derivation_failure_exits_3", function()
    world.editor_cli = nil
    assert.are.equal(3, deploy.main({}))
    assert.matches("编辑器收尾失败", err_text, 1, true)
  end)

  it("test_missing_editor_cli_is_still_a_skip_with_exit_0", function()
    world.exe_exists = false
    assert.are.equal(0, deploy.main({}))
  end)
end)
