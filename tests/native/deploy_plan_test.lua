-- 部署计划护栏：三端 packages 与业务子树同属清单，镜像和 --clean 消费相同目标。
-- 所有目录枚举与传输均用夹具替代，不碰真实宿主目录、不启动编辑器。
local plan = require("tools.deploy_plan")

local WORKSPACE = "fixture-host"
local ENTRIES = {
  client = { { name = "UI", dir = true }, { name = "packages", dir = true } },
  common = { { name = "game_cfg.lua", dir = false }, { name = "packages", dir = true } },
  server = { { name = "Mgr", dir = true }, { name = "packages", dir = true } },
}
local EXPECTED = {
  { rel = "client/UI", dir = true, src = "client/UI", dst = WORKSPACE .. "/client/UI" },
  { rel = "client/packages", dir = true, src = "client/packages", dst = WORKSPACE .. "/client/packages" },
  { rel = "common/game_cfg.lua", dir = false, src = "common/game_cfg.lua", dst = WORKSPACE .. "/common/game_cfg.lua" },
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
  -- deploy 与 editor_finalize 都走同一个接缝 tools.seam（#189），桩一份就够。
  local MODULES = { "tools.deploy", "tools.eggy_workspace", "tools.seam", "tools.editor_finalize" }

  before_each(function()
    HOST_ENTRIES = same_as_repo()
    saved = { path = package.path, modules = {} }
    for _, name in ipairs(MODULES) do saved.modules[name] = package.loaded[name] end
    deployed, removed, finalized = {}, {}, 0
    package.loaded["tools.deploy"] = nil
    package.loaded["tools.eggy_workspace"] = { resolve = function() return WORKSPACE end }
    package.loaded["tools.seam"] = {
      preflight = function() return true end,
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
      mirror_cmd = function(target) return "robocopy " .. target.rel end,
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
    package.loaded["tools.seam"].remove = function() end
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

-- 退出码约定（#145）：robocopy 缺失属平台不可用，退 3；编辑器收尾找不到 editor-cli、编辑器没装、
-- 地图没开都只是跳过（退 0），用 editor_verified=false 标记与「已校验」区分。编辑器收尾走真实模块，
-- 只桩接缝层。
describe("TestDeployExitCodes", function()
  local saved, deploy, world, err_text, out_text
  -- 编辑器收尾走真实模块、只桩接缝层：deploy 与 editor_finalize 共用 tools.seam（#189）。
  local MODULES = { "tools.deploy", "tools.eggy_workspace", "tools.seam", "tools.editor_finalize" }
  local EXE = "C:/Users/fixture/.eggitor/cli/editor-cli.exe"

  before_each(function()
    HOST_ENTRIES = same_as_repo()
    saved = { modules = {}, print = print, stderr = io.stderr }
    for _, name in ipairs(MODULES) do saved.modules[name] = package.loaded[name] end
    world = { preflight = true, editor_cli = EXE, exe_exists = true, eggy_json = true }
    err_text, out_text = "", ""
    package.loaded["tools.deploy"] = nil
    package.loaded["tools.editor_finalize"] = nil
    package.loaded["tools.eggy_workspace"] = { resolve = function() return WORKSPACE end }
    package.loaded["tools.seam"] = {
      normalize = function(path) return path end,
      quote = function(v) return '"' .. tostring(v) .. '"' end,
      preflight = function()
        if world.preflight then return true end
        return nil, "PATH 上找不到 robocopy.exe（部署工具不可用）"
      end,
      editor_cli = function()
        if world.editor_cli then return world.editor_cli end
        return nil, "环境变量 USERPROFILE 未设置"
      end,
      is_dir = function() return true end,
      exists = function(path)
        if path == EXE then return world.exe_exists end
        if path == WORKSPACE .. "/eggy.json" then return world.eggy_json end
        return true
      end,
      -- 收尾的 code validate / code diff 输出：按用例给的清单顺序逐条返回。
      capture = function()
        local step = table.remove(world.captures or {}, 1)
        if not step then return 0, "" end
        return step[1], step[2]
      end,
      list_entries = list_entries,
      list_files = function() return {} end,
      mirror = function() return true, 0 end,
      mirror_cmd = function(target) return "robocopy " .. target.rel end,
      remove = function() end,
    }
    _G.print = function(...)
      for _, v in ipairs({ ... }) do out_text = out_text .. tostring(v) end
      out_text = out_text .. "\n"
    end
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

  -- robocopy 缺失属「外部工具不可用」（#145）：镜像之前退 3，一个文件都不写。
  it("test_missing_preflight_exits_3", function()
    world.preflight = false
    assert.are.equal(3, deploy.main({}))
    assert.matches("部署工具不可用", err_text, 1, true)
  end)

  -- editor-cli 解析不出来（seam.editor_cli() 返回 nil）不再算平台不可用：打印跳过 + 标记 false + 退 0。
  it("test_unresolvable_editor_cli_is_a_skip_with_exit_0", function()
    world.editor_cli = nil
    assert.are.equal(0, deploy.main({}))
    assert.matches("编辑器收尾跳过", out_text, 1, true)
    assert.is_truthy(out_text:find("\neditor_verified=false reason=missing-editor-cli\n", 1, true))
  end)

  -- 解析出的路径上文件不在了同样跳过：原因相同，退出码 0。
  it("test_missing_editor_cli_is_still_a_skip_with_exit_0", function()
    world.exe_exists = false
    assert.are.equal(0, deploy.main({}))
    assert.matches("编辑器收尾跳过", out_text, 1, true)
    assert.is_truthy(out_text:find("\neditor_verified=false reason=missing-editor-cli\n", 1, true))
    assert.is_nil(out_text:find("editor_verified=true", 1, true))
  end)

  -- 宿主没绑定 Lua 工程同样只跳过：原因换一个，标记仍独立成行、退出码 0。
  it("test_missing_eggy_json_skip_marker_names_the_reason", function()
    world.eggy_json = false
    assert.are.equal(0, deploy.main({}))
    assert.matches("编辑器收尾跳过", out_text, 1, true)
    assert.is_truthy(out_text:find("\neditor_verified=false reason=missing-eggy-json\n", 1, true))
  end)

  -- 收尾走通（validate 通过、diff 有 changelist 且无差异）：输出 editor_verified=true，退出码 0。
  it("test_editor_verified_true_after_finalize_succeeds", function()
    world.captures = {
      { 0, '{"ok":true,"data":{"valid":true,"issues":[],"warnings":[]},"meta":{"warnings":[]}}' },
      { 0, "changelist: only-local=0 differs=0 only-on-map=0 unchanged=2\n" },
    }
    assert.are.equal(0, deploy.main({}))
    assert.matches("编辑器: 已同步", out_text, 1, true)
    assert.is_truthy(out_text:find("\neditor_verified=true\n", 1, true))
    assert.is_nil(out_text:find("editor_verified=false", 1, true))
  end)
end)
