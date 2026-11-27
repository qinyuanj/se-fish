-- 文档所有权登记：每个受控文档必须落到唯一信息类（#351）。
-- 这是「新增文档前先回答它属于哪一类」的机器落点；正文约定见 AGENTS.md 的按任务读取。
local fs = require('tests.support.fs_fixture')
local seam = require('tools.seam')

-- 信息类 -> 受控路径模式（相对仓库根，正斜杠）。新增目录先在这里登记，否则下面的用例会红。
local CLASSES = {
  { name = '入口', patterns = { '^AGENTS%.md$' } },
  { name = '术语', patterns = { '^GLOSSARY%.md$' } },
  { name = '规范', patterns = { '^CODING_STANDARDS%.md$' } },
  { name = '源数据', patterns = { '^docs/design/' } },
  { name = '决策', patterns = { '^docs/adr/' } },
  { name = '验收', patterns = { '^docs/acceptance/' } },
  { name = '操作', patterns = {
    '^docs/agents/',
  } },
  { name = '规格', patterns = { '^docs/GameSpec%.md$' } },
  { name = '架构', patterns = { '^docs/architecture%.md$' } },
  { name = '状态', patterns = {
    '^docs/art%-asset%-overview%.md$',
    '^docs/packages%-reference%.md$',
    '^docs/engine%-keys%.md$',
  } },
  { name = '调研', patterns = { '^docs/research/' } },
  { name = '生成物', patterns = { '^docs/uml/' } },
}

local ROOT_FILES = { ['AGENTS.md'] = true, ['CODING_STANDARDS.md'] = true, ['GLOSSARY.md'] = true }

local function tracked_documents()
  local git = assert(seam.which('git'), 'PATH 上找不到 git')
  local code, output = seam.capture({
    argv = { git, '-c', 'core.quotepath=false', 'ls-files' },
    cwd = fs.repo_root(),
  })
  assert(code == 0, 'git ls-files 失败: ' .. tostring(output))
  local documents = {}
  for line in (output .. '\n'):gmatch('([^\n]+)\n') do
    local path = line:gsub('\r$', '')
    if ROOT_FILES[path] or path:match('^docs/') then
      documents[#documents + 1] = path
    end
  end
  table.sort(documents)
  return documents
end

local function classes_of(path)
  local matched = {}
  for _, class in ipairs(CLASSES) do
    for _, pattern in ipairs(class.patterns) do
      if path:match(pattern) then
        matched[#matched + 1] = class.name
        break
      end
    end
  end
  return matched
end

describe('文档所有权登记', function()
  it('test_every_tracked_document_is_classified', function()
    local bad = {}
    for _, path in ipairs(tracked_documents()) do
      local matched = classes_of(path)
      if #matched ~= 1 then
        bad[#bad + 1] = path .. ' -> ' .. (#matched == 0 and '未登记' or table.concat(matched, ' / '))
      end
    end
    assert.same({}, bad, '每个受控文档必须恰好属于一个信息类（#351）')
  end)

  it('test_every_class_matches_at_least_one_document', function()
    local documents = tracked_documents()
    local bad = {}
    for _, class in ipairs(CLASSES) do
      local found = false
      for _, path in ipairs(documents) do
        if classes_of(path)[1] == class.name then
          found = true
          break
        end
      end
      if not found then bad[#bad + 1] = class.name end
    end
    assert.same({}, bad, '空的信息类说明模式写错或落点已删（#351）')
  end)

end)
