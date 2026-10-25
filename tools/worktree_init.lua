-- worktree-init（#141）：把新 worktree 补齐到能跑 full 车道。
--   1. 从 magpie 资源库把上游 blender-* skill 复制到 <根>/.agents/skills/（gitignored，
--      来源口径见 docs/agents/art-pipeline.md「上游 blender-* skill」）；
--   2. 按 tools/quality/project.json 的 tools.*.source（"../<工具>"）在根的**父目录**建
--      symlink，指向主检出旁的真实工具检出（docs/agents/workflow.md「worktree 起手式」）。
-- 已存在的条目跳过（幂等），不覆盖、不改指向；但已有 symlink 指向别处时报出并失败。
-- 任一来源缺失或链接指向不符时在写入前失败。
-- 不执行 tools/quality/project install：.toolcache 与 .uml-viewer 由人在 worktree 里独立安装。
local seam = require("tools.wsl_seam")

local M = {}

M.SKILLS_REL = ".agents/skills"
M.PROJECT_JSON = "tools/quality/project.json"
local SKILL_DOC = "docs/agents/art-pipeline.md 的「上游 blender-* skill」"

function M.usage()
  return table.concat({
    "用法: lua5.4 tools/cli.lua worktree-init [--root <检出根>] [--skills-from <目录>] [--tools-from <目录>]",
    "  把 worktree 补齐到能跑 busted --run=full；重复执行只跳过已有条目。",
    "  --root         目标检出根，默认当前目录",
    "  --skills-from  上游 skill 来源，默认部署端 magpie 资源库（经 WSL interop 推导）",
    "  --tools-from   工具检出所在目录，默认主检出的父目录（取 git worktree list 首条）",
    "  不执行 tools/quality/project install；.toolcache 缺失时由人执行该命令。",
  }, "\n") .. "\n"
end

local function parent(path)
  return path:match("^(.*)/[^/]+/*$") or "."
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

-- 第一个 "<key>": { ... } 对象的原文（按括号配对，跳过字符串内容）。
-- 仓库里没有不依赖 .toolcache 的 JSON 解析器（acceptance4lua.json 在 .toolcache 里，新 worktree
-- 还没有），所以只做到这一步；project.json 里 "tools" 只出现在顶层，第一个就是它。
local function object_text(text, key)
  local _, start = text:find('"' .. key .. '"%s*:%s*{')
  if not start then return nil end
  local depth, in_str, i = 0, false, start
  while i <= #text do
    local c = text:sub(i, i)
    if in_str then
      if c == "\\" then i = i + 1 elseif c == '"' then in_str = false end
    elseif c == '"' then
      in_str = true
    elseif c == "{" then
      depth = depth + 1
    elseif c == "}" then
      depth = depth - 1
      if depth == 0 then return text:sub(start, i) end
    end
    i = i + 1
  end
  return nil
end

-- 从 project.json 的 tools 节读各工具 source 里形如 "../<名字>" 的目录名（与 install 同一来源）；
-- 其他节（如 lua_tools）里的 source 不算。
local function tool_names(root)
  local f = io.open(root .. "/" .. M.PROJECT_JSON, "rb")
  if not f then return nil, "读不到 " .. root .. "/" .. M.PROJECT_JSON end
  local text = f:read("a")
  f:close()
  local tools = object_text(text, "tools")
  if not tools then return nil, M.PROJECT_JSON .. " 里没有 tools 节" end
  local names = {}
  for name in tools:gmatch('"source"%s*:%s*"%.%./([^"/]+)"') do names[#names + 1] = name end
  if #names == 0 then return nil, M.PROJECT_JSON .. " 里没有 \"../<工具>\" 形式的 tools.*.source" end
  return names
end

local function default_skills_from()
  local dir, err = seam.magpie_library()
  if not dir then
    return nil, "推导 magpie 资源库失败（" .. tostring(err) .. "）；可用 --skills-from 指定"
  end
  return dir
end

-- 主检出的父目录。主检出取 `git worktree list --porcelain` 的首条：git 保证首条是主 worktree，
-- 不依赖 .git 的位置（--separate-git-dir、子模块下 git-common-dir 不在主检出里）。
local function default_tools_from(root)
  local cmd = "git -C " .. seam.q(root) .. " worktree list --porcelain"
  local code, out = seam.capture(cmd)
  local first = (out .. "\n\n"):match("^(.-)\n\n") or ""
  local main = first:match("^worktree (/[^\n]*)")
  local why
  if code ~= 0 then
    why = "退出码 " .. code
  elseif not main then
    why = "首条不是绝对路径的 worktree 行"
  elseif first:find("\nbare", 1, true) then
    why = "首条是裸仓库 " .. main .. "，没有主检出"
  end
  if why then
    return nil, "推导主检出失败：`" .. cmd .. "` " .. why .. "，输出: " .. seam.trim(out)
      .. "；可用 --tools-from 指定"
  end
  return seam.absolute(parent(main))
end

-- 已有 symlink 的实际指向与期望不符时返回说明；不是 symlink（如主检出旁的真实检出）不算不符。
local function link_mismatch(link, target)
  local raw = seam.readlink(link)
  if not raw then return nil end
  if seam.absolute(link) == seam.absolute(target) then return nil end
  return link .. " -> " .. raw .. "（应为 " .. target .. "）"
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
  local tools, wrong = {}, {}
  local link_dir = parent(opts.root)
  for _, name in ipairs(names) do
    local target = opts.tools_from .. "/" .. name
    if not seam.is_dir(target) then
      return nil, "工具检出不存在: " .. target .. "（worktree 起手式要求指向主检出旁的真实检出）"
    end
    local link = link_dir .. "/" .. name
    wrong[#wrong + 1] = link_mismatch(link, target)
    tools[#tools + 1] = { name = name, target = target, link = link }
  end
  if #wrong > 0 then
    return nil, "已有工具链接指向不符，未改动: " .. table.concat(wrong, "；")
      .. "。删掉这些链接后重跑 worktree-init"
  end
  return { skills = skills, tools = tools }
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
  for _, t in ipairs(todo.tools) do
    local link = t.link
    if seam.lexists(link) then
      io.stdout:write("跳过工具链接（已存在）: " .. link .. "\n")
    elseif seam.execute("ln -s " .. seam.q(t.target) .. " " .. seam.q(link)) ~= 0 then
      io.stderr:write("worktree-init: 建立 symlink 失败: " .. link .. "\n")
      return 1
    else
      io.stdout:write("工具链接: " .. link .. " -> " .. t.target .. "\n")
    end
  end
  if not seam.lexists(opts.root .. "/.toolcache") then
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
