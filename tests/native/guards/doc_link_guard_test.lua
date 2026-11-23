-- Markdown 相对链接必须在当前 checkout 可定位；外部 URL、页内锚点与显式 gitignored 路径不查。
local fs = require('tests.support.fs_fixture')
local lfs = require('lfs')

local function normalize(path)
  local parts = {}
  for part in path:gmatch('[^/]+') do
    if part == '..' then
      if #parts > 0 then table.remove(parts) end
    elseif part ~= '.' then
      parts[#parts + 1] = part
    end
  end
  return table.concat(parts, '/')
end

local function ignored_roots()
  local roots = {}
  local ignore = assert(fs.slurp('.gitignore'))
  for line in (ignore .. '\n'):gmatch('([^\n]*)\n') do
    line = line:match('^(.-)%s*$')
    if line:match('^/') and not line:match('[!*?]') then
      roots[#roots + 1] = line:sub(2):gsub('/$', '')
    end
  end
  return roots
end

local function is_ignored(path, roots)
  for _, root in ipairs(roots) do
    if path == root or path:sub(1, #root + 1) == root .. '/' then return true end
  end
  return false
end

describe('文档相对链接守卫', function()
  it('test_agent_documentation_links_resolve', function()
    local files = { 'AGENTS.md', 'CODING_STANDARDS.md' }
    for _, name in ipairs(fs.list_dir('docs/agents')) do
      if name:match('%.md$') then files[#files + 1] = 'docs/agents/' .. name end
    end
    local roots, bad = ignored_roots(), {}
    for _, file in ipairs(files) do
      local src = assert(fs.slurp(file), '读不到文档 ' .. file)
      local dir = file:match('^(.*)/[^/]+$') or ''
      for target in src:gmatch('%[[^]]*%]%(([^)]+)%)') do
        local path = target:match('^<([^>]+)>') or target:match('^(%S+)')
        path = path and path:match('^([^#]*)')
        if path and path ~= '' and not path:match('^%a[%w+.-]*:') and not path:match('^//')
            and not path:match('^[/\\]') then
          path = path:gsub('%%(%x%x)', function(hex) return string.char(tonumber(hex, 16)) end)
          local resolved = normalize((dir == '' and '' or dir .. '/') .. path)
          if not is_ignored(resolved, roots) and not lfs.attributes(resolved) then
            local position = assert(src:find(target, 1, true))
            local line = select(2, src:sub(1, position):gsub('\n', '')) + 1
            bad[#bad + 1] = file .. ':' .. line .. ' -> ' .. target
          end
        end
      end
    end
    table.sort(bad)
    assert.same({}, bad)
  end)
end)
