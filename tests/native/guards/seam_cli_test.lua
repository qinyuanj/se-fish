-- seam.editor_cli 的解析优先级门禁：EGGITOR_CLI → 默认路径 → PATH → 可操作错误。
-- 用注入的 env/exists 钉住四种情况，不依赖本机是否装了 editor-cli。
local seam = require("tools.seam")

describe("EditorCliResolution", function()
  local HOME = "C:/Users/fixture"
  local DEFAULT = HOME .. "/" .. seam.EDITOR_CLI_REL
  local EXPLICIT = "D:/tools/editor-cli.exe"
  local ON_PATH = "E:/bin/editor-cli.exe"

  local function deps(env, files)
    local present = {}
    for _, path in ipairs(files or {}) do present[path] = true end
    return {
      env = function(name) return env[name] end,
      exists = function(path) return present[path] == true end,
    }
  end

  it("test_default_install_path_hits", function()
    local path, err = seam.editor_cli(deps({ USERPROFILE = HOME }, { DEFAULT }))
    assert.is_nil(err)
    assert.are.equal(DEFAULT, path)
  end)

  it("test_eggitor_cli_overrides_default_path", function()
    local path, err = seam.editor_cli(deps({
      [seam.EDITOR_CLI_ENV] = EXPLICIT,
      USERPROFILE = HOME,
    }, { EXPLICIT, DEFAULT }))
    assert.is_nil(err)
    assert.are.equal(EXPLICIT, path)
  end)

  it("test_eggitor_cli_to_missing_file_falls_through_to_default", function()
    local path = seam.editor_cli(deps({
      [seam.EDITOR_CLI_ENV] = EXPLICIT,
      USERPROFILE = HOME,
    }, { DEFAULT }))
    assert.are.equal(DEFAULT, path)
  end)

  it("test_path_lookup_prefers_executable", function()
    local path = seam.editor_cli(deps({
      USERPROFILE = HOME,
      PATH = 'C:/Windows;"E:/bin";F:/nothing',
    }, { ON_PATH, "E:/bin/editor-cli" }))
    assert.are.equal(ON_PATH, path)
  end)

  it("test_missing_everywhere_reports_actionable_error", function()
    local path, err = seam.editor_cli(deps({ USERPROFILE = HOME, PATH = "C:/Windows" }, {}))
    assert.is_nil(path)
    assert.is_truthy(err:find(seam.EDITOR_CLI_ENV, 1, true))
    assert.is_truthy(err:find("启动一次蛋仔 PC 编辑器", 1, true))
    assert.is_truthy(err:find(DEFAULT, 1, true))
  end)
end)
