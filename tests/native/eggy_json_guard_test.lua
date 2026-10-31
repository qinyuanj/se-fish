-- 仓库根 eggy.json 守卫（#166）：只允许 isSEMap 一个布尔键。
-- 宿主那份带 projectID / playerNid / serverPort / mapDir 等部署端信息，回流进工作树时本车道判红。
local guard = require("tools.eggy_json_guard")

describe("TestEggyJsonGuard", function()
  it("test_only_is_se_map_true_is_accepted", function()
    assert.same({}, guard.check('{"isSEMap": true}\n'))
    assert.same({}, guard.check('{\n  "isSEMap": true\n}\n'))
  end)

  it("test_is_se_map_false_is_accepted", function()
    assert.same({}, guard.check('{"isSEMap": false}'))
  end)

  -- 宿主那份原样回流：每个多余键都点名，按字典序。
  it("test_host_side_fields_are_rejected", function()
    local host = '{\n  "projectID": "6aab",\n  "serverPort": 27962,\n  "isSEMap": true,\n'
      .. '  "playerNid": "1",\n  "mapDir": "C:\\\\x"\n}\n'
    assert.same({
      "eggy_json_guard: disallowed key: mapDir",
      "eggy_json_guard: disallowed key: playerNid",
      "eggy_json_guard: disallowed key: projectID",
      "eggy_json_guard: disallowed key: serverPort",
    }, guard.check(host))
  end)

  it("test_non_boolean_is_se_map_is_rejected", function()
    assert.same({ "eggy_json_guard: isSEMap must be a boolean" }, guard.check('{"isSEMap": "true"}'))
  end)

  it("test_missing_is_se_map_is_rejected", function()
    assert.same({ "eggy_json_guard: isSEMap must be a boolean" }, guard.check("{}"))
  end)

  it("test_non_object_is_rejected", function()
    assert.same({ "eggy_json_guard: top level must be a JSON object" }, guard.check("[true]"))
  end)

  -- 守卫看的是工作树里那份真文件。
  it("test_repo_eggy_json_passes", function()
    local f = assert(io.open("eggy.json", "rb"), "仓库根缺 eggy.json（SessionStart hook 靠它判 SE）")
    local text = f:read("a")
    f:close()
    assert.same({}, guard.check(text))
  end)
end)
