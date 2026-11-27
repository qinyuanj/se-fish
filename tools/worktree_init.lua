-- worktree-init（#141）：把新 worktree 补齐到能跑 full 车道。
-- 现在只安装/升级本地 pre-commit（美术工作流的上游 blender-* skill 复制已随美术工作流移除，
-- 保留在 tag art-workflow-archive-v1）。幂等。
-- 不为质量工具做任何准备（#146）：质量工具由 dsh-uml-viewer 插件自带，项目里无需安装。
local seam = require("tools.seam")
local git_hooks = require("tools.git_hooks")

local M = {}

function M.usage()
  return table.concat({
    "用法: lua tools/cli.lua worktree-init [--root <检出根>]",
    "  把 worktree 补齐到能跑 lua tools/cli.lua test full；重复执行只跳过已有条目。",
    "  --root         目标检出根，默认当前目录",
    "  安装/升级提交前运行 test guards、size 与 emmylua 的 pre-commit；已有其他 hook 时拒绝覆盖。",
    "  不为质量工具做准备；质量工具由 dsh-uml-viewer 插件自带。",
  }, "\n") .. "\n"
end

local function parse(args)
  local opts = {}
  local i = 1
  while i <= #args do
    local a = args[i]
    if a == "--help" or a == "-h" then return { help = true } end
    if a ~= "--root" or args[i + 1] == nil then return nil, "无法识别的参数: " .. tostring(a) end
    opts.root = args[i + 1]
    i = i + 2
  end
  return opts
end

function M.run(opts)
  local hook, result, code = git_hooks.install(opts.root)
  if not hook then
    io.stderr:write("worktree-init: " .. tostring(result) .. "\n")
    return code or 1
  end
  local hook_label = result == "unchanged" and "跳过 pre-commit（已安装）: "
    or (result == "updated" and "升级 pre-commit: " or "安装 pre-commit: ")
  io.stdout:write(hook_label .. hook .. "\n")
  return 0
end

function M.main(args)
  local opts, err = parse(args or {})
  if not opts then
    io.stderr:write("worktree-init: " .. err .. "\n" .. M.usage())
    return 2
  end
  if opts.help then
    io.stdout:write(M.usage())
    return 0
  end
  local root, rerr = seam.absolute(opts.root or ".")
  if not root then
    io.stderr:write("worktree-init: 检出根无效: " .. tostring(rerr) .. "\n")
    return 1
  end
  opts.root = root
  return M.run(opts)
end

return M
