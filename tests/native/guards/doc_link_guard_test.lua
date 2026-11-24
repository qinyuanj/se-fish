-- Markdown 相对链接必须在当前 checkout 可定位，锚点必须能在目标文档里解析；外部 URL 与显式 gitignored 路径不查。
local fs = require('tests.support.fs_fixture')
local seam = require('tools.seam')
local doc_anchor = require('tests.support.doc_anchor')

local function normalize(path)
  local parts = {}
  for part in path:gmatch('[^/]+') do
    if part == '..' then
      if #parts == 0 or parts[#parts] == '..' then return nil end
      table.remove(parts)
    elseif part ~= '.' then
      parts[#parts + 1] = part
    end
  end
  return table.concat(parts, '/')
end

-- Windows CI 的 LuaFileSystem 走系统 ANSI 代码页，不能稳定打开 UTF-8 中文路径；
-- 以 Git index 为仓库事实，同时拒绝未提交、大小写不一致或遗漏的链接目标。
local tracked_memo
local function tracked_paths()
  if tracked_memo then return tracked_memo end
  local git = assert(seam.which('git'), 'PATH 上找不到 git')
  local code, output = seam.capture({
    argv = { git, '-c', 'core.quotepath=false', 'ls-files' },
    cwd = fs.repo_root(),
  })
  assert(code == 0, 'git ls-files 失败: ' .. tostring(output))
  local files, dirs = {}, {}
  for line in (output .. '\n'):gmatch('([^\n]+)\n') do
    local tracked = line:gsub('\r$', '')
    files[tracked] = true
    local parent = tracked:match('^(.*)/[^/]+$')
    while parent do
      dirs[parent] = true
      parent = parent:match('^(.*)/[^/]+$')
    end
  end
  tracked_memo = { files = files, dirs = dirs }
  return tracked_memo
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
  it('test_markdown_links_and_anchors_resolve', function()
    local tracked, roots = tracked_paths(), ignored_roots()
    local files = {}
    for path in pairs(tracked.files) do
      if path:match('%.md$') then files[#files + 1] = path end
    end
    table.sort(files)
    local bad = {}
    for _, file in ipairs(files) do
      local src = assert(doc_anchor.read(file), '读不到文档 ' .. file)
      local dir = file:match('^(.*)/[^/]+$') or ''
      for position, target in src:gmatch('()%[[^]]*%]%(([^)]+)%)') do
        local link = target:match('^<([^>]+)>') or target:match('^(%S+)')
        link = link and link:gsub('%%(%x%x)', function(hex) return string.char(tonumber(hex, 16)) end)
        local path = link and link:match('^([^#]*)')
        path = path and path:gsub(':%d+$', '')
        local anchor = link and link:match('#(.+)$')
        local flagged, reason = false, ''
        if path == '' then
          if anchor and anchor ~= '' and not doc_anchor.exists(src, anchor) then
            flagged, reason = true, '（锚点不存在）'
          end
        elseif path and not path:match('^%a[%w+.-]*:') and not path:match('^//')
            and not path:match('^[/\\]') then
          local resolved = normalize((dir == '' and '' or dir .. '/') .. path)
          local exists = resolved and (tracked.files[resolved] or tracked.dirs[resolved])
          if not resolved or (not is_ignored(resolved, roots) and not exists) then
            flagged = true
          elseif anchor and anchor ~= '' and tracked.files[resolved] then
            local body = doc_anchor.read(resolved)
            if not body or not doc_anchor.exists(body, anchor) then
              flagged, reason = true, '（锚点不存在）'
            end
          end
        end
        if flagged then
          local line = select(2, src:sub(1, position - 1):gsub('\n', '')) + 1
          bad[file .. ':' .. line .. ' -> ' .. target .. reason] = true
        end
      end
    end
    local list = {}
    for entry in pairs(bad) do list[#list + 1] = entry end
    table.sort(list)
    assert.same({}, list)
  end)

  -- 反向守卫：docs/research/ 里放的是跨轮复用的调研，没人指向它等于不存在。
  -- 失败方式先列：结论写进一个零引用的文件，下一轮 agent 重新调研一遍（2026-11-24 的调查曾处于零引用状态，
  -- 没有任何入口能让人找到它）。
  -- 口径是「有没有被别的 markdown 提到」而不是「链接是否可达」：本仓 AGENTS.md 的指针多写成代码路径，
  -- 所以按文件名匹配；提到它的是不是一条好指针由人负责，这里只兜住零引用。
  it('test_research_documents_are_referenced', function()
    local tracked, docs, corpus = tracked_paths(), {}, {}
    for path in pairs(tracked.files) do
      if path:match('%.md$') then docs[#docs + 1] = path end
    end
    table.sort(docs)
    for _, path in ipairs(docs) do
      local handle = io.open(path, 'r')
      if handle then
        corpus[path] = handle:read('*a')
        handle:close()
      end
    end
    local bad = {}
    for _, doc in ipairs(docs) do
      local name = doc:match('^docs/research/([^/]+)$')
      if name then
        local cited = false
        for _, other in ipairs(docs) do
          if other ~= doc and corpus[other] and corpus[other]:find(name, 1, true) then
            cited = true
            break
          end
        end
        if not cited then bad[#bad + 1] = doc end
      end
    end
    assert.same({}, bad, 'docs/research/ 下的文档零引用（从 AGENTS.md、docs/agents/ 或 ADR 留一条指针）')
  end)
end)
