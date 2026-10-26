-- worktree-init（#141）：把新 worktree 补齐到能跑 full 车道。
-- 从 magpie 资源库把上游 blender-* skill 复制到 <根>/.agents/skills/（gitignored，
-- 来源口径见 docs/agents/art-pipeline.md「上游 blender-* skill」）。
-- 已存在的条目跳过（幂等），不覆盖；来源缺失时在写入前失败。
-- 不为质量工具做任何准备（#146）：质量工具是 uml-viewer 的标准工具，由人按 uml-viewer 文档安装。
local seam = require("tools.wsl_seam")

local M = {}

M.SKILLS_REL = ".agents/skills"
local SKILL_DOC = "docs/agents/art-pipeline.md 的「上游 blender-* skill」"

function M.usage()
  return table.concat({
    "用法: lua5.4 tools/cli.lua worktree-init [--root <检出根>] [--skills-from <目录>]",
    "  把 worktree 补齐到能跑 busted --run=full；重复执行只跳过已有条目。",
    "  --root         目标检出根，默认当前目录",
    "  --skills-from  上游 skill 来源，默认部署端 magpie 资源库（经 WSL interop 推导）",
    "  不为质量工具做准备；质量工具由人按 uml-viewer 文档安装。",
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

-- 先复制到临时名再改名：中途失败不会留下半个目录被下次当成「已存在」跳过；
-- 失败时把临时目录也清掉，不留给人收拾。
local function copy_skill(src, dst)
  local partial = dst .. ".partial"
  seam.execute("rm -rf " .. seam.q(partial))
  if seam.execute("cp -R " .. seam.q(src) .. " " .. seam.q(partial)) == 0
    and seam.execute("mv " .. seam.q(partial) .. " " .. seam.q(dst)) == 0 then
    return true
  end
  seam.execute("rm -rf " .. seam.q(partial))
  return false
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
    if seam.lexists(dst) then
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
      -- 推导要经 WSL interop：推不出属平台不可用（#145 退出码 3）。
      io.stderr:write("worktree-init: " .. err .. "\n")
      return 3
    end
  end
  return M.run(opts)
end

return M
