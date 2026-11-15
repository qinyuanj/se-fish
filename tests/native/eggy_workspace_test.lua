-- eggy_workspace 宿主目录定位（#191）：Windows 原生口径。
-- EGGY_WORKSPACE 覆盖（空串当未设置），否则回落到 seam.default_workspace（由 USERPROFILE 推导）；
-- 返回值一律正斜杠绝对路径，不再有 to_linux / /mnt/c 概念。
local workspace = require("tools.eggy_workspace")
local seam = require("tools.seam")

local DEFAULT = "C:/Users/x/Desktop/dev/eggy/LuaSource_Host"

describe("TestEggWorkspaceResolve", function()
  local saved_env, saved_default
  before_each(function()
    saved_env = os.getenv
    saved_default = seam.default_workspace
  end)
  after_each(function()
    os.getenv = saved_env
    seam.default_workspace = saved_default
  end)

  local function with_env(value)
    os.getenv = function(name)
      if name == "EGGY_WORKSPACE" then return value end
      return saved_env(name)
    end
  end

  it("test_default_is_derived_from_user_profile", function()
    with_env(nil)
    seam.default_workspace = function() return DEFAULT end
    assert.are.equal(DEFAULT, workspace.resolve())
  end)

  it("test_empty_value_is_treated_as_unset", function()
    with_env("")
    seam.default_workspace = function() return DEFAULT end
    assert.are.equal(DEFAULT, workspace.resolve())
  end)

  it("test_override_normalizes_backslashes_to_forward_slashes", function()
    with_env("C:\\Users\\x\\host")
    assert.are.equal("C:/Users/x/host", workspace.resolve())
  end)

  it("test_relative_override_is_rejected", function()
    with_env("relative/host")
    local path, err = workspace.resolve()
    assert.is_nil(path)
    assert.matches("绝对路径", err, 1, true)
  end)
end)
