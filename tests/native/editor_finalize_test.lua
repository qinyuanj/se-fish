-- 编辑器收尾的命令边界：用响应队列验证失败关闭，不启动真实编辑器。
-- 部署端 exe 的定位（USERPROFILE 推导）也用桩替换；真实 interop 往返由 slow 车道证明。
local finalize = require("tools.editor_finalize")
local shell = require("tools.wsl_seam")

local WORKSPACE = "C:/workspace"
local EXE = "C:/fixture/.eggitor/cli/editor-cli.exe"

-- 编辑器侧编出来的地图独有文件（三端外），deploy 永远保留。
local FOREIGN = { "temp/Script_map___preset_u0.lua", "unit_scripts/World/a.lua" }

-- 仿 `code diff` 文本：changelist 行 + 每个地图独有文件一行（CRLF，与真 CLI 一致）。
-- map_only 缺省为 FOREIGN；count_override 用来造计数与清单对不上的输出。
local function diff(local_count, differs, channel, map_only, count_override)
  map_only = map_only or FOREIGN
  local lines = { "codec=mm channel=" .. (channel or "online"),
    "changelist: only-local=" .. local_count .. " differs=" .. differs
      .. " only-on-map=" .. (count_override or #map_only) .. " unchanged=3" }
  for _, path in ipairs(map_only) do lines[#lines + 1] = "  only-on-map  " .. path end
  return table.concat(lines, "\r\n") .. "\r\n"
end

describe("TestEditorFinalize", function()
  local saved, responses, commands, messages, exists
  before_each(function()
    saved = {
      capture = shell.capture, exists = shell.exists,
      editor_cli = shell.editor_cli, to_windows = shell.to_windows,
      print = print,
    }
    responses, commands, messages = {}, {}, {}
    exists = { [EXE] = true, [WORKSPACE .. "/eggy.json"] = true }
    shell.editor_cli = function() return EXE end
    shell.to_windows = function(path) return path end
    shell.exists = function(path) return exists[path] == true end
    shell.capture = function(command)
      commands[#commands + 1] = command
      local response = table.remove(responses, 1)
      assert.is_not_nil(response, "出现未预期的编辑器命令")
      return response[1], response[2]
    end
    _G.print = function(message) messages[#messages + 1] = message end
  end)
  after_each(function()
    shell.capture, shell.exists = saved.capture, saved.exists
    shell.editor_cli, shell.to_windows = saved.editor_cli, saved.to_windows
    _G.print = saved.print
  end)

  local function ready_for_push(last_code, last_output)
    responses = { { 0, "validate: OK" }, { 0, diff(1, 1) }, { 0, "push: OK" },
      { last_code, last_output } }
  end

  it("test_unchanged_does_not_push_and_keeps_map_only_files", function()
    responses = { { 0, "validate: OK" }, { 0, diff(0, 0) } }
    assert.is_true(finalize.run(WORKSPACE))
    assert.are.equal(2, #commands)
    assert.is_truthy(messages[#messages]:find("多出 2 个三端外", 1, true))
  end)

  -- 本地已删的三端文件：带 --delete --yes 推送，复核时三端独有文件必须清零。
  it("test_owned_map_only_files_are_deleted_by_push", function()
    local stale = { "client/AttrAPI.lua", "server/ProtoWater.lua" }
    responses = { { 0, "validate: OK" }, { 0, diff(0, 0, nil, { stale[1], stale[2], FOREIGN[1] }) },
      { 0, "push: OK" }, { 0, diff(0, 0) } }
    local ok, err = finalize.run(WORKSPACE)
    assert.is_nil(ok)
    assert.is_truthy(err:find("三端外", 1, true), "三端内外混杂时不应推送")
    assert.are.equal(2, #commands)

    commands, messages = {}, {}
    responses = { { 0, "validate: OK" }, { 0, diff(0, 0, nil, stale) },
      { 0, "push: OK" }, { 0, diff(0, 0, nil, {}) } }
    assert.is_true(finalize.run(WORKSPACE))
    assert.are.equal(4, #commands)
    assert.is_truthy(commands[3]:find("code push --delete --yes", 1, true))
  end)

  it("test_push_without_owned_map_only_files_never_deletes", function()
    ready_for_push(0, diff(0, 0))
    assert.is_true(finalize.run(WORKSPACE))
    assert.is_truthy(commands[3]:find("code push", 1, true))
    assert.is_nil(commands[3]:find("--delete", 1, true))
  end)

  it("test_owned_map_only_left_after_push_is_a_failure", function()
    responses = { { 0, "validate: OK" }, { 0, diff(0, 0, nil, { "client/AttrAPI.lua" }) },
      { 0, "push: OK" }, { 0, diff(0, 0, nil, { "client/AttrAPI.lua" }) } }
    local ok, err = finalize.run(WORKSPACE)
    assert.is_nil(ok)
    assert.is_truthy(err:find("client/AttrAPI.lua", 1, true))
  end)

  -- 计数与逐行清单对不上就分不清删除候选，失败关闭、不推送。
  it("test_map_only_count_mismatch_fails_closed", function()
    responses = { { 0, "validate: OK" }, { 0, diff(0, 0, nil, { "client/AttrAPI.lua" }, 3) } }
    local ok, err = finalize.run(WORKSPACE)
    assert.is_nil(ok)
    assert.is_truthy(err:find("only-on-map", 1, true))
    assert.are.equal(2, #commands)
  end)

  it("test_realm_prefix_must_be_a_directory", function()
    local owned, foreign = finalize.split_map_only({ "client/a.lua", "clientx/b.lua", "server" })
    assert.same({ "client/a.lua" }, owned)
    assert.same({ "clientx/b.lua", "server" }, foreign)
  end)

  it("test_push_is_followed_by_online_verification", function()
    ready_for_push(0, diff(0, 0))
    assert.is_true(finalize.run(WORKSPACE))
    assert.are.equal(4, #commands)
    assert.is_truthy(commands[3]:find("code push", 1, true))
    assert.is_truthy(commands[4]:find("code diff", 1, true))
    for _, command in ipairs(commands) do
      assert.is_truthy(command:find("--workspace", 1, true))
    end
  end)

  it("test_push_failure_stops_verification", function()
    responses = { { 0, "validate: OK" }, { 0, diff(1, 0) }, { 1, "push rejected" } }
    local ok, err = finalize.run(WORKSPACE)
    assert.is_nil(ok)
    assert.is_truthy(err:find("code push 失败", 1, true))
    assert.are.equal(3, #commands)
  end)

  for _, case in ipairs({
    { "offline", 0, diff(0, 0, "offline"), "离线" },
    { "failed", 1, diff(0, 0), "复核失败" },
    { "missing_changelist", 0, "editor disconnected", "读不到 changelist" },
    { "remaining_changes", 0, diff(1, 0), "仍有 1" },
  }) do
    it("test_verification_rejects_" .. case[1], function()
      ready_for_push(case[2], case[3])
      local ok, err = finalize.run(WORKSPACE)
      assert.is_nil(ok)
      assert.is_truthy(err:find(case[4], 1, true))
      for _, message in ipairs(messages) do
        assert.is_nil(message:find("编辑器: 已同步", 1, true))
      end
    end)
  end

  it("test_initial_offline_diff_skips_push_without_claiming_sync", function()
    responses = { { 0, "validate: OK" }, { 0, diff(1, 0, "offline") } }
    assert.is_true(finalize.run(WORKSPACE))
    assert.are.equal(2, #commands)
    assert.is_truthy(messages[#messages]:find("未校验编辑器内代码", 1, true))
  end)

  -- 环境坏了（interop 或 USERPROFILE 推导失败）必须报错，不能当成「编辑器没开」跳过。
  it("test_editor_cli_derivation_failure_is_an_error", function()
    shell.editor_cli = function() return nil, "PATH 上找不到 cmd.exe（WSL interop 不可用）" end
    local ok, err = finalize.run(WORKSPACE)
    assert.is_nil(ok)
    assert.is_truthy(err:find("interop 不可用", 1, true))
    assert.are.equal(0, #commands)
  end)

  it("test_missing_editor_cli_is_a_skip", function()
    exists[EXE] = false
    assert.is_true(finalize.run(WORKSPACE))
    assert.are.equal(0, #commands)
    assert.is_truthy(messages[#messages]:find("未找到 editor-cli.exe", 1, true))
  end)

  it("test_unbound_workspace_is_a_skip", function()
    exists[WORKSPACE .. "/eggy.json"] = false
    assert.is_true(finalize.run(WORKSPACE))
    assert.are.equal(0, #commands)
    assert.is_truthy(messages[#messages]:find("没有 eggy.json", 1, true))
  end)

  it("test_workspace_conversion_failure_is_an_error", function()
    shell.to_windows = function() return nil, "wslpath -w 失败" end
    local ok, err = finalize.run(WORKSPACE)
    assert.is_nil(ok)
    assert.is_truthy(err:find("wslpath -w 失败", 1, true))
    assert.are.equal(0, #commands)
  end)
end)
