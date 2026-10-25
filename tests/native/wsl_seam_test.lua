-- WSL 接缝层的纯逻辑：sh 引用、Windows 环境变量推导的结果解析、部署端路径推导。
-- 捕获入口（seam.capture）用桩替换，不启动 cmd.exe；真实 interop 往返由
-- tests/native/slow/deploy_transport_test.lua 在 CLI 进程边界证明。
local seam = require("tools.wsl_seam")

describe("TestWslSeamQuote", function()
  it("test_single_quote_wraps_and_escapes", function()
    assert.are.equal("'abc'", seam.q("abc"))
    assert.are.equal("'a b'", seam.q("a b"))
    assert.are.equal("'a'\\''b'", seam.q("a'b"))
    assert.are.equal("'melee_hit 要求 > 0'", seam.q("melee_hit 要求 > 0"))
  end)
end)

-- Windows 形式判定是接缝的唯一口径，blender 子命令据此决定是否经 wslpath 转换。
describe("TestWslSeamWindowsPathForm", function()
  it("test_drive_and_unc_forms_are_windows", function()
    assert.is_true(seam.is_windows_path("C:\\Program Files\\Blender Foundation"))
    assert.is_true(seam.is_windows_path("d:/Blender/blender.exe"))
    assert.is_true(seam.is_windows_path("\\\\wsl.localhost\\Ubuntu\\home\\x"))
  end)

  it("test_linux_and_relative_forms_are_not_windows", function()
    assert.is_false(seam.is_windows_path("/mnt/c/Program Files"))
    assert.is_false(seam.is_windows_path("./tmp/a.blend"))
    assert.is_false(seam.is_windows_path("blender.exe"))
    assert.is_false(seam.is_windows_path("C:relative"))
  end)
end)

describe("TestWslSeamWindowsEnv", function()
  local saved
  before_each(function()
    saved = { capture = seam.capture, to_linux = seam.to_linux }
    seam.to_linux = function(raw)
      assert.are.equal("C:\\Users\\fixture", raw)
      return "/mnt/c/Users/fixture"
    end
  end)
  after_each(function()
    seam.capture, seam.to_linux = saved.capture, saved.to_linux
  end)

  -- cmd.exe 在 Linux cwd 下会先打一段 UNC 警告；推导必须只取真正的值。
  it("test_unc_warning_does_not_pollute_the_value", function()
    seam.capture = function()
      return 0, "CMD.EXE was started with the above path as the current directory.\n"
        .. "UNC paths are not supported.  Defaulting to Windows directory.\n"
        .. "C:\\Users\\fixture\r\n"
    end
    assert.are.equal("/mnt/c/Users/fixture", seam.windows_env("USERPROFILE"))
  end)

  -- 未定义变量会被 cmd 原样回显成 %NAME%，不能当路径用。
  it("test_undefined_variable_is_a_failure", function()
    seam.capture = function() return 0, "%NOPE%\r\n" end
    local value, err = seam.windows_env("NOPE")
    assert.is_nil(value)
    assert.matches("未定义", err, 1, true)
    assert.matches("NOPE", err, 1, true)
  end)

  it("test_nonzero_capture_is_a_failure", function()
    seam.capture = function() return 1, "denied" end
    local value, err = seam.windows_env("USERPROFILE")
    assert.is_nil(value)
    assert.matches("退出码 1", err, 1, true)
  end)
end)

describe("TestWslSeamDeployPaths", function()
  local saved
  before_each(function()
    saved = seam.windows_env
  end)
  after_each(function()
    seam.windows_env = saved
  end)

  it("test_default_workspace_is_derived_from_windows_profile", function()
    seam.windows_env = function(name)
      assert.are.equal("USERPROFILE", name)
      return "/mnt/c/Users/fixture"
    end
    assert.are.equal("/mnt/c/Users/fixture/Desktop/dev/eggy/LuaSource_钓鱼怎么这么危险啊喂！",
      seam.default_workspace())
  end)

  it("test_default_workspace_surfaces_derivation_failure", function()
    seam.windows_env = function() return nil, "找不到 cmd.exe" end
    local path, err = seam.default_workspace()
    assert.is_nil(path)
    assert.matches("找不到 cmd.exe", err, 1, true)
  end)

  it("test_editor_cli_lives_under_the_windows_profile", function()
    seam.windows_env = function() return "/mnt/c/Users/fixture" end
    assert.are.equal("/mnt/c/Users/fixture/.eggitor/cli/editor-cli.exe", seam.editor_cli())
  end)
end)

describe("TestWslSeamWorkspaceResolve", function()
  local saved_env, saved_seam
  before_each(function()
    saved_env = os.getenv
    saved_seam = {
      default_workspace = seam.default_workspace,
      to_linux = seam.to_linux,
    }
    seam.default_workspace = function() return "/mnt/c/Users/fixture/Desktop/dev/eggy/host" end
    seam.to_linux = function(path)
      if path:match("^%a:[/\\]") then return "/mnt/c/converted", "转换" end
      return path
    end
  end)
  after_each(function()
    os.getenv = saved_env
    seam.default_workspace = saved_seam.default_workspace
    seam.to_linux = saved_seam.to_linux
  end)

  local workspace = require("tools.eggy_workspace")

  it("test_empty_value_is_treated_as_unset", function()
    os.getenv = function(name)
      if name == "EGGY_WORKSPACE" then return "" end
      return saved_env(name)
    end
    assert.are.equal("/mnt/c/Users/fixture/Desktop/dev/eggy/host", workspace.resolve())
  end)

  it("test_windows_form_is_converted_to_linux", function()
    os.getenv = function(name)
      if name == "EGGY_WORKSPACE" then return "C:\\Users\\fixture\\host" end
      return saved_env(name)
    end
    assert.are.equal("/mnt/c/converted", workspace.resolve())
  end)

  it("test_linux_form_is_used_as_is", function()
    os.getenv = function(name)
      if name == "EGGY_WORKSPACE" then return "/mnt/c/Users/fixture/host" end
      return saved_env(name)
    end
    assert.are.equal("/mnt/c/Users/fixture/host", workspace.resolve())
  end)

  it("test_relative_override_is_rejected", function()
    os.getenv = function(name)
      if name == "EGGY_WORKSPACE" then return "relative/host" end
      return saved_env(name)
    end
    local path, err = workspace.resolve()
    assert.is_nil(path)
    assert.matches("绝对路径", err, 1, true)
  end)
end)
