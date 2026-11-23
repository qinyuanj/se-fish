-- worktree-init（#141）：把新 worktree 补齐到能跑 full 车道。
-- 从 magpie 资源库把上游 blender-* skill 复制到 <根>/.agents/skills/（gitignored，
-- 来源口径见 docs/agents/art-pipeline.md「上游 blender-* skill」）。
-- 已存在的条目跳过（幂等），不覆盖；来源缺失时在写入前失败。
-- 不为质量工具做任何准备（#146）：质量工具由 dsh-uml-viewer 插件自带，项目里无需安装。
-- acceptance4lua 已删除（#147），.toolcache 不再有使用者，这里也不准备。
--
-- Windows 原生（#191）：目录探测/枚举/建目录/删除走 tools.seam（纯 Lua），复制目录是纯 Lua
-- （lfs+io 递归），不再调用 cp -R / mv / rm。
local seam = require("tools.seam")
local exit_code = require("tools.exit_code")
local git_hooks = require("tools.git_hooks")

local M = {}

M.SKILLS_REL = ".agents/skills"
local SKILL_DOC = "docs/agents/art-pipeline.md 的「上游 blender-* skill」"

function M.usage()
  return table.concat({
    "用法: lua tools/cli.lua worktree-init [--root <检出根>] [--skills-from <目录>]",
    "  把 worktree 补齐到能跑 lua tools/cli.lua test full；重复执行只跳过已有条目。",
    "  --root         目标检出根，默认当前目录",
    "  --skills-from  上游 skill 来源，默认宿主侧 magpie 资源库（由 USERPROFILE 推导）",
    "  同时安装提交前运行 test guards 的 pre-commit；已有其他 hook 时拒绝覆盖。",
    "  不为质量工具做准备；质量工具由 dsh-uml-viewer 插件自带。",
  }, "\n") .. "\n"
end

local function parse(args)
  local opts = {}
  local flags = { ["--root"] = "root", ["--skills-from"] = "skills_from" }
  local i = 1
  while i <= #args do
    local a = args[i]
    if a == "--help" or a == "-h" then return { help = true } end
    local key = flags[a]
    if not key or args[i + 1] == nil then return nil, "无法识别的参数: " .. tostring(a) end
    opts[key] = args[i + 1]
    i = i + 2
  end
  return opts
end

local function default_skills_from()
  local dir, err = seam.magpie_library()
  if not dir then
    return nil, "推导 magpie 资源库失败（" .. tostring(err) .. "）；可用 --skills-from 指定"
  end
  return dir
end

-- 预检全部来源并列出待办；有任何问题都返回错误，此时不写入任何东西。
local function plan(opts)
  if not seam.is_dir(opts.skills_from) then
    return nil, "上游 skill 来源目录不存在: " .. opts.skills_from .. "（来源见 " .. SKILL_DOC .. "）"
  end
  local skills = {}
  for _, e in ipairs(seam.list_entries(opts.skills_from)) do
    if e.dir and e.name:match("^blender%-") then skills[#skills + 1] = e.name end
  end
  if #skills == 0 then
    return nil, opts.skills_from .. " 下没有 blender-* 目录（来源见 " .. SKILL_DOC .. "）"
  end
  return { skills = skills }
end

-- 单文件复制；读失败或写失败返回 false。
local function copy_file(src, dst)
  local fin = io.open(src, "rb")
  if not fin then return false end
  local body = fin:read("a")
  fin:close()
  if body == nil then return false end
  local fout = io.open(dst, "wb")
  if not fout then return false end
  fout:write(body)
  fout:close()
  return true
end

-- 递归复制目录（目录由 ensure_dir 逐层建出）；任何一步失败返回 false。
local function copy_dir(src, dst)
  seam.ensure_dir(dst)
  for _, e in ipairs(seam.list_entries(src)) do
    local s, d = src .. "/" .. e.name, dst .. "/" .. e.name
    if e.dir then
      if not copy_dir(s, d) then return false end
    else
      if not copy_file(s, d) then return false end
    end
  end
  return true
end

-- 先复制到临时名再改名：中途失败不会留下半个目录被下次当成「已存在」跳过；失败时把临时目录
-- 也清掉，不留给人收拾。
local function copy_skill(src, dst)
  local partial = dst .. ".partial"
  if seam.exists(partial) then seam.remove({ dir = true, dst = partial }) end
  if not copy_dir(src, partial) then
    seam.remove({ dir = true, dst = partial })
    return false
  end
  local renamed = os.rename(partial, dst)
  if not renamed then
    seam.remove({ dir = true, dst = partial })
    return false
  end
  return true
end

function M.run(opts)
  local todo, err = plan(opts)
  if not todo then
    io.stderr:write("worktree-init: " .. err .. "\n")
    return 1
  end
  local skills_dir = opts.root .. "/" .. M.SKILLS_REL
  for _, name in ipairs(todo.skills) do
    local dst = skills_dir .. "/" .. name
    if seam.exists(dst) then
      io.stdout:write("跳过 skill（已存在）: " .. dst .. "\n")
    else
      seam.ensure_dir(skills_dir)
      if not copy_skill(opts.skills_from .. "/" .. name, dst) then
        io.stderr:write("worktree-init: 复制 skill 失败: " .. name .. "（已清掉 " .. dst .. ".partial）\n")
        return 1
      end
      io.stdout:write("复制 skill: " .. dst .. "\n")
    end
  end
  local hook, result, code = git_hooks.install(opts.root)
  if not hook then
    io.stderr:write("worktree-init: " .. tostring(result) .. "\n")
    return code or 1
  end
  io.stdout:write((result == "unchanged" and "跳过 pre-commit（已安装）: " or "安装 pre-commit: ") .. hook .. "\n")
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
  if not opts.skills_from then
    opts.skills_from, err = default_skills_from()
    if not opts.skills_from then
      -- 推导要读 USERPROFILE：推不出属外部工具不可用（#145 退出码 3）。
      io.stderr:write("worktree-init: " .. err .. "\n")
      return exit_code.UNAVAILABLE
    end
  end
  return M.run(opts)
end

return M
