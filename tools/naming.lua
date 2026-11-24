-- tools/naming.lua —— 命名改名的唯一入口（#337）。
-- 用法：
--   lua tools/cli.lua naming --recon [--layer l3a|l3b|all] [--root DIR] [--json] [--summary] [--verbose]
--   lua tools/cli.lua naming --apply [--layer l3a|l3b|all] [--root DIR]
--   lua tools/cli.lua naming --check [--root DIR]
-- recon/apply 的扫描与替换在 tools/naming/engine.py（Python 3）里，数据在 tools/naming/data/；
-- check 是旧名字符串守卫（纯 Lua），与 tests/native/guards/naming_string_keys_test.lua 共用一份规则。
-- 退出码：0 成功 / 1 守卫或引擎业务失败 / 2 用法错误 / 3 缺可用的 Python 3。
local seam = require("tools.seam")
local guard = require("tools.naming_guard")

local M = {}

local USAGE = [[
用法：
  lua tools/cli.lua naming --recon [--layer l3a|l3b|all] [--root DIR] [--json] [--summary] [--verbose]
  lua tools/cli.lua naming --apply [--layer l3a|l3b|all] [--root DIR]
  lua tools/cli.lua naming --check [--root DIR]

  --recon   只列将要改的位置（默认全层；--summary 只看计数，--json 给机器读）
  --apply   按映射落盘改名；目标必须是干净的 git 工作区（只用于父提交 worktree），默认先 l3a 后 l3b
  --check   扫描 client/common/server 的旧名字符串，报文件:行号
  --layer   只跑某一层：l3a（449 个标识符）/ l3b（45 个方法名）/ all
  --root    目标仓库根，默认当前 worktree（用于在父提交 worktree 上重放）
]]

local function usage(message)
  if message then io.stderr:write(message .. "\n") end
  io.stderr:write(USAGE)
  return 2
end

function M.main(args, env)
  local mode
  local layer = "all"
  local root = env.repo_root
  local json, summary, verbose = false, false, false
  local i = 1
  while i <= #args do
    local arg = args[i]
    if arg == "--help" or arg == "-h" then
      io.write(USAGE)
      return 0
    elseif arg == "--recon" or arg == "--apply" or arg == "--check" then
      if mode then return usage("一次只能给一个模式：" .. mode .. " / " .. arg) end
      mode = arg:sub(3)
    elseif arg == "--layer" then
      i = i + 1
      layer = args[i]
      if layer ~= "l3a" and layer ~= "l3b" and layer ~= "all" then
        return usage("--layer 只收 l3a / l3b / all")
      end
    elseif arg == "--root" then
      i = i + 1
      if not args[i] or args[i] == "" then return usage("--root 需要目录") end
      root = args[i]
    elseif arg == "--json" then
      json = true
    elseif arg == "--summary" then
      summary = true
    elseif arg == "--verbose" then
      verbose = true
    else
      return usage("未知参数：" .. arg)
    end
    i = i + 1
  end
  if not mode then return usage("缺模式：--recon / --apply / --check") end
  if mode ~= "recon" and (json or summary or verbose) then
    return usage("--json / --summary / --verbose 只用于 --recon")
  end

  local target, err = seam.absolute(root)
  if not target then return usage(err) end
  local tmp_dir = env.repo_root .. "/tmp"

  if mode == "apply" then
    local git = seam.which("git")
    if not git then
      io.stderr:write("naming: PATH 上找不到可用的 git，无法检查目标工作区\n")
      return 3
    end
    local code, out = seam.capture({
      argv = { git, "-C", target, "status", "--porcelain" },
      tmp_dir = tmp_dir,
    })
    if code ~= 0 then
      io.stderr:write("naming: 无法读取目标 git 状态（--apply 只用于 git worktree）：" .. tostring(out) .. "\n")
      return 2
    end
    if out:gsub("%s", "") ~= "" then
      io.stderr:write("naming: 目标工作区不干净，拒绝 --apply：\n" .. out)
      return 1
    end
  end

  if mode == "check" then
    local ok, bad, reason = pcall(guard.scan, target, env.repo_root)
    if not ok then
      io.stderr:write(string.format("naming: guard.scan(%s) 失败：%s\n", target, tostring(bad)))
      return 2
    end
    if not bad then
      io.stderr:write(string.format("naming: guard.scan(%s) 失败：%s\n", target, tostring(reason)))
      return 2
    end
    for _, item in ipairs(bad) do
      io.write(string.format("%s  %q -> %s（%s）\n", item.where, item.literal, item.new_name, item.why))
    end
    if #bad == 0 then
      io.write("OK：业务源码没有未豁免的旧名字符串\n")
      return 0
    end
    io.write(string.format("FAIL：%d 处旧名字符串\n", #bad))
    return 1
  end

  local python = seam.which("python")
  if not python then
    io.stderr:write("naming 需要 Python 3；PATH 上找不到 python\n")
    return 3
  end
  local version_code, version_out = seam.capture({ argv = { python, "--version" }, tmp_dir = tmp_dir })
  local major = version_out and version_out:match("Python%s+(%d+)%.")
  if version_code ~= 0 or tonumber(major) ~= 3 then
    io.stderr:write("naming 需要 Python 3，当前 python 不可用：" .. tostring(version_out) .. "\n")
    return 3
  end
  local script = env.repo_root .. "/tools/naming/engine.py"
  local argv = { python, "-I", script, "--" .. mode, "--root", target, "--layer", layer }
  if json then argv[#argv + 1] = "--json" end
  if summary then argv[#argv + 1] = "--summary" end
  if verbose then argv[#argv + 1] = "--verbose" end
  local code, output = seam.capture({ argv = argv, cwd = target, tmp_dir = tmp_dir })
  if output and output ~= "" then io.write(output) end
  return code
end

return M
