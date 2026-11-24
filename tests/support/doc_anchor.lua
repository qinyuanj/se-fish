-- 文档锚点解析：两个文档守卫共用，规则只写一份。
-- 支持五种形态：<a id="X">、GitHub 标题 slug、数字节号（#15）、节号加对象名（#8.1-鱼塘）、表格行 id（| Q10 |）。
local fs = require('tests.support.fs_fixture')
local seam = require('tools.seam')

local M = {}
local cache = {}

-- 读文档正文。Windows 上 fopen 走系统 ANSI 代码页，中文路径可能打不开，回退到 git 索引。
function M.read(path)
  if cache[path] ~= nil then return cache[path] or nil end
  local handle = io.open(path, 'rb')
  if handle then
    local body = handle:read('a')
    handle:close()
    cache[path] = body
    return body
  end
  local git = seam.which('git')
  if not git then
    cache[path] = false
    return nil
  end
  local code, output = seam.capture({ argv = { git, 'show', ':' .. path }, cwd = fs.repo_root() })
  if code ~= 0 then
    cache[path] = false
    return nil
  end
  cache[path] = output
  return output
end

local function headings(text)
  local list = {}
  for hashes, body in text:gmatch('\n(#+)%s+([^\n]+)') do
    list[#list + 1] = { level = #hashes, text = (body:gsub('%s+$', '')) }
  end
  return list
end

-- GitHub 标题 slug：去掉标点，空格换连字符，转小写；中文原样保留。
function M.github_slug(text)
  local slug = text:gsub('^%s+', ''):gsub('%s+$', '')
  slug = slug:gsub('[*_~`%[%]%(%){}<>|\\/!%?%.,:;%\'"@#$%%^&+=]', '')
  slug = slug:gsub('%s', '-')
  return slug:lower()
end

-- 节号对应的正文，从该标题下一行到下一个同级或更高级标题之前。
function M.section_body(text, number)
  local lines = {}
  for line in (text .. '\n'):gmatch('([^\n]*)\n') do lines[#lines + 1] = line end
  local escaped = number:gsub('%.', '%%.')
  for i, line in ipairs(lines) do
    local hashes, body = line:match('^(#+)%s+(.+)$')
    if hashes then
      local trimmed = body:gsub('%s+$', '')
      if trimmed:match('^' .. escaped .. '[%s%.]') or trimmed == number then
        local buffer = {}
        for j = i + 1, #lines do
          local next_hashes = lines[j]:match('^(#+)%s+')
          if next_hashes and #next_hashes <= #hashes then break end
          buffer[#buffer + 1] = lines[j]
        end
        return table.concat(buffer, '\n')
      end
    end
  end
  return nil
end

-- opts.table_rows 与 opts.section_objects 只对代码里的锚点开放；Markdown 链接按 GitHub 规则解析。
function M.exists(source, anchor, opts)
  opts = opts or {}
  local text = '\n' .. source
  if text:find('<a id="' .. anchor .. '"', 1, true) then return true end
  local list = headings(text)
  for _, heading in ipairs(list) do
    if M.github_slug(heading.text) == anchor then return true end
  end
  for _, heading in ipairs(list) do
    local number = heading.text:match('^(%d+%.%d+)[%s%.]') or heading.text:match('^(%d+)%.%s')
    if number == anchor then return true end
  end
  local section, name = anchor:match('^(%d+%.%d+)%-(.+)$')
  if opts.section_objects and section and name ~= '' then
    local body = M.section_body(text, section)
    if body and body:find(name, 1, true) then return true end
  end
  if opts.table_rows and text:find('| ' .. anchor .. ' |', 1, true) then return true end
  return false
end

return M
