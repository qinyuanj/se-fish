-- 安装仓库的本地 pre-commit；Git 自己解析 hooksPath，兼容普通 checkout 与 worktree。
local seam = require('tools.seam')
local exit_code = require('tools.exit_code')

local M = {}

M.HOOK_BODY = table.concat({
  '#!/bin/sh',
  '# 由 lua tools/cli.lua git-hook-init 安装；不同内容的既有 hook 不会被覆盖。',
  'repo_root=$(git rev-parse --show-toplevel) || exit 1',
  'cd "$repo_root" || exit 1',
  'exec lua tools/cli.lua test guards',
  '',
}, '\n')

function M.usage()
  return table.concat({
    '用法: lua tools/cli.lua git-hook-init [--root <检出根>]',
    '  安装本地 pre-commit，提交前运行 lua tools/cli.lua test guards。',
    '  --root  目标检出根，默认当前仓库；重复执行幂等，不覆盖其他 hook。',
  }, '\n') .. '\n'
end

local function trim(text)
  return (tostring(text or ''):match('^%s*(.-)%s*$'))
end

function M.hook_path(root)
  local git = seam.which('git')
  if not git then return nil, 'PATH 上找不到 git', exit_code.UNAVAILABLE end
  local code, output = seam.capture({
    argv = { git, 'rev-parse', '--path-format=absolute', '--git-path', 'hooks/pre-commit' },
    cwd = root,
  })
  if code ~= 0 then
    return nil, 'git rev-parse 解析 pre-commit 路径失败: ' .. trim(output), 1
  end
  local path = trim(output)
  if path == '' then return nil, 'git rev-parse 返回了空 pre-commit 路径', 1 end
  return seam.normalize(path)
end

local function read_file(path)
  local file = io.open(path, 'rb')
  if not file then return nil end
  local body = file:read('a')
  file:close()
  return body
end

function M.install(root)
  local path, err, code = M.hook_path(root)
  if not path then return nil, err, code end
  local existing = read_file(path)
  if existing ~= nil then
    if existing == M.HOOK_BODY then return path, 'unchanged', 0 end
    return nil, '已有不同的 pre-commit，拒绝覆盖: ' .. path, 1
  end
  seam.ensure_dir(path:match('^(.*)/[^/]+$'))
  local partial = path .. '.partial'
  local file = io.open(partial, 'wb')
  if not file then return nil, '无法写入 pre-commit 临时文件: ' .. partial, 1 end
  local write_ok, write_err = file:write(M.HOOK_BODY)
  local close_ok, close_err = file:close()
  if not write_ok or close_ok == nil then
    os.remove(partial)
    return nil, '写入 pre-commit 失败: ' .. tostring(write_err or close_err), 1
  end
  local ok, rename_err = os.rename(partial, path)
  if not ok then
    os.remove(partial)
    return nil, '安装 pre-commit 失败: ' .. tostring(rename_err), 1
  end
  return path, 'installed', 0
end

function M.main(args, env)
  args, env = args or {}, env or {}
  local root
  local i = 1
  while i <= #args do
    local arg = args[i]
    if arg == '--help' or arg == '-h' then
      io.stdout:write(M.usage())
      return 0
    elseif arg == '--root' and args[i + 1] then
      root = args[i + 1]
      i = i + 2
    else
      io.stderr:write('git-hook-init: 无法识别的参数: ' .. tostring(arg) .. '\n' .. M.usage())
      return 2
    end
  end
  local absolute, err = seam.absolute(root or env.repo_root or '.')
  if not absolute then
    io.stderr:write('git-hook-init: 检出根无效: ' .. tostring(err) .. '\n')
    return 1
  end
  local path, result, code = M.install(absolute)
  if not path then
    io.stderr:write('git-hook-init: ' .. tostring(result) .. '\n')
    return code or 1
  end
  io.stdout:write((result == 'unchanged' and '跳过 pre-commit（已安装）: ' or '安装 pre-commit: ') .. path .. '\n')
  return 0
end

return M
