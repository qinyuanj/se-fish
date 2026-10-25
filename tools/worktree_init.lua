-- worktree-init（#141）：把新 worktree 补齐到能跑 full 车道。
--   1. 从 magpie 资源库把上游 blender-* skill 复制到 <根>/.agents/skills/（gitignored，
--      来源口径见 docs/agents/art-pipeline.md「上游 blender-* skill」）；
--   2. 按 tools/quality/project.json 的 tools.*.source（"../<工具>"）在根的**父目录**建
--      symlink，指向主检出旁的真实工具检出（docs/agents/workflow.md「worktree 起手式」）。
-- 已存在的条目一律跳过（幂等），不覆盖、不改指向；任一来源缺失时在写入前失败。
-- 不执行 tools/quality/project install：.toolcache 与 .uml-viewer 由人在 worktree 里独立安装。
local seam = require("tools.wsl_seam")

local M = {}

M.SKILLS_REL = ".agents/skills"
M.LIBRARY_REL = ".config/magpie/library/skills"
M.PROJECT_JSON = "tools/quality/project.json"
local SKILL_DOC = "docs/agents/art-pipeline.md 的「上游 blender-* skill」"

function M.usage()
  return table.concat({
    "用法: lua5.4 tools/cli.lua worktree-init [--root <检出根>] [--skills-from <目录>] [--tools-from <目录>]",
    "  把 worktree 补齐到能跑 busted --run=full；重复执行只跳过已有条目。",
    "  --root         目标检出根，默认当前目录",
    "  --skills-from  上游 skill 来源，默认部署端 %USERPROFILE%/" .. M.LIBRARY_REL .. "（经 WSL interop 推导）",
    "  --tools-from   工具检出所在目录，默认主检出的父目录（经 git --git-common-dir 推导）",
    "  不执行 tools/quality/project install；.toolcache 缺失时由人执行该命令。",
  }, "\n") .. "\n"
end

local function trim(text)
  return (tostring(text):gsub("^%s+", ""):gsub("%s+$", ""))
end

local function parent(path)
  return path:match("^(.*)/[^/]+/*$") or "."
end

-- 是否已有条目（含断开的 symlink：它也占着名字，不能当成空位去覆盖）。
local function occupied(path)
  return seam.execute("test -e " .. seam.q(path) .. " || test -L " .. seam.q(path)) == 0
end

local function parse(args)
  local opts = {}
  local flags = { ["--root"] = "root", ["--skills-from"] = "skills_from", ["--tools-from"] = "tools_from" }
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

-- 从 project.json 读 tools.*.source 里形如 "../<名字>" 的工具目录名（与 install 同一来源）。
local function tool_names(root)
  local f = io.open(root .. "/" .. M.PROJECT_JSON, "rb")
  if not f then return nil, "读不到 " .. root .. "/" .. M.PROJECT_JSON end
  local text = f:read("a")
  f:close()
  local names = {}
  for name in text:gmatch('"source"%s*:%s*"%.%./([^"/]+)"') do names[#names + 1] = name end
  if #names == 0 then return nil, M.PROJECT_JSON .. " 里没有 \"../<工具>\" 形式的 tools.*.source" end
  return names
end

local function default_skills_from()
  local home, err = seam.windows_env("USERPROFILE")
  if not home then
    return nil, "推导 magpie 资源库失败（" .. tostring(err) .. "）；可用 --skills-from 指定"
  end
  return home .. "/" .. M.LIBRARY_REL
end

-- 主检出的父目录：git-common-dir 是主检出的 .git，往上两级。
local function default_tools_from(root)
  local code, out = seam.capture("git -C " .. seam.q(root) .. " rev-parse --path-format=absolute --git-common-dir")
  local dir = trim(out)
  if code ~= 0 or dir:sub(1, 1) ~= "/" then
    return nil, "推导主检出失败（git rev-parse 退出码 " .. code .. "）；可用 --tools-from 指定"
  end
  return parent(parent(dir))
end

-- 预检全部来源并列出待办；有任何问题都返回错误，此时不写入任何东西。
local function plan(opts)
  local names, err = tool_names(opts.root)
  if not names then return nil, err end
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
  local tools = {}
  for _, name in ipairs(names) do
    local target = opts.tools_from .. "/" .. name
    if not seam.is_dir(target) then
      return nil, "工具检出不存在: " .. target .. "（worktree 起手式要求指向主检出旁的真实检出）"
    end
    tools[#tools + 1] = { name = name, target = target }
  end
  return { skills = skills, tools = tools }
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
    if occupied(dst) then
      io.stdout:write("跳过 skill（已存在）: " .. dst .. "\n")
    else
      -- 先复制到临时名再改名：中途失败不会留下半个目录被下次当成「已存在」跳过。
      local partial = dst .. ".partial"
      local cmd = "mkdir -p " .. seam.q(skills_dir) .. " && rm -rf " .. seam.q(partial)
        .. " && cp -R " .. seam.q(opts.skills_from .. "/" .. name) .. " " .. seam.q(partial)
        .. " && mv " .. seam.q(partial) .. " " .. seam.q(dst)
      if seam.execute(cmd) ~= 0 then
        io.stderr:write("worktree-init: 复制 skill 失败: " .. name .. "\n")
        return 1
      end
      io.stdout:write("复制 skill: " .. dst .. "\n")
    end
  end
  local link_dir = parent(opts.root)
  for _, t in ipairs(todo.tools) do
    local link = link_dir .. "/" .. t.name
    if occupied(link) then
      io.stdout:write("跳过工具链接（已存在）: " .. link .. "\n")
    elseif seam.execute("ln -s " .. seam.q(t.target) .. " " .. seam.q(link)) ~= 0 then
      io.stderr:write("worktree-init: 建立 symlink 失败: " .. link .. "\n")
      return 1
    else
      io.stdout:write("工具链接: " .. link .. " -> " .. t.target .. "\n")
    end
  end
  if not occupied(opts.root .. "/.toolcache") then
    io.stdout:write("提示: 缺 .toolcache（full 里 quality_report_test 会失败），需人执行 tools/quality/project install\n")
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
  if not opts.tools_from then
    opts.tools_from, err = default_tools_from(root)
  else
    opts.tools_from, err = seam.absolute(opts.tools_from)
  end
  if not opts.tools_from then
    io.stderr:write("worktree-init: " .. tostring(err) .. "\n")
    return 1
  end
  if not opts.skills_from then
    opts.skills_from, err = default_skills_from()
    if not opts.skills_from then
      io.stderr:write("worktree-init: " .. err .. "\n")
      return 1
    end
  end
  return M.run(opts)
end

return M
