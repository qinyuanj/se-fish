-- 验收矩阵夹具（#326）：在临时目录里拼一份最小可用的假仓库，供 tests/native/guards/acceptance_matrix_test.lua
-- 逐项改坏再验红。夹具只写磁盘，不碰真实 docs/acceptance/；生成块与基线由 tools.acceptance 自己算，
-- 保证夹具起点就是绿的（改坏了才红，红的不是夹具本身）。
local fs = require('tests.support.fs_fixture')
local Acceptance = require('tools.acceptance')

local M = {}

M.SPEC_CLAUSE = '夹具条款'
-- 证据路径：夹具里真实存在，删它或改成别的路径就该判红。
M.EVIDENCE = 'tests/native/spec/demo_test.lua'

function M.shard(section)
  return string.format('%s/%02d-fixture.md', Acceptance.DIR, section)
end

-- 每节一条 unverified；第 1 节再加一条 B 级与一条 C 级（C 级没有会话记录，反推 blocked），
-- 第 3 节一条由 spec 正文取证；第 9、11 节补齐到 9-05 与 11-20，
-- 让工具里的两条反推例外在夹具里也有对应条款可查。
local CLAUSE_COUNTS = { [3] = 2, [9] = 5, [11] = 20 }

local function shard_body(section)
  local lines = {
    string.format('# %d. 夹具小节%d', section, section),
    '',
    '> 夹具分片：两列与 TEMPLATE.md 一致，等级写成文案的行尾后缀。',
    '',
    '| ID | 条款 |',
    '| --- | --- |',
  }
  local count = CLAUSE_COUNTS[section] or 1
  for serial = 1, count do
    local level = (section == 1 and serial == 3) and 'C' or 'A'
    lines[#lines + 1] = string.format('| %d-%02d | %s：第 %d 节第 %d 条（%s） |',
      section, serial, M.SPEC_CLAUSE, section, serial, level)
  end
  if section == 1 then
    -- 1-02 换成 B 级：等级后缀可跨三档，不要求都是 A。
    lines[#lines + 1] = '| 1-02 | 夹具条款：有第二级证据的那条（B） |'
    lines[#lines + 1] = ''
    lines[#lines + 1] = '## C 级（试玩取证）'
    lines[#lines + 1] = ''
    lines[#lines + 1] = '| ID | 条款 |'
    lines[#lines + 1] = '| --- | --- |'
    lines[#lines + 1] = '| 1-03 | 夹具条款：只能试玩的那条（C） |'
  end
  lines[#lines + 1] = ''
  return table.concat(lines, '\n')
end

local function readme_body()
  return table.concat({
    '# 夹具验收矩阵索引',
    '',
    '> 夹具：生成块由 tools.acceptance 写入。',
    '',
    '## 计数（脚本生成）',
    '',
    Acceptance.BEGIN_MARK,
    '（占位）',
    Acceptance.END_MARK,
    '',
  }, '\n')
end

-- 拼一份最小可用的假仓库：起点全绿。
function M.build(root)
  fs.rmrf(root)
  fs.mkdirp(root)
  for section = 1, Acceptance.SPEC_SECTIONS do
    fs.write_file(root .. '/' .. M.shard(section), shard_body(section))
  end
  fs.write_file(root .. '/' .. Acceptance.INDEX, readme_body())
  -- 证据文件正文要带条款号：反推除了看文件在哪，还看正文里有没有这条条款的 ID。
  fs.write_file(root .. '/' .. M.EVIDENCE, '-- 夹具证据文件：条款 3-02 的断言落在这里。\n')
  -- 两条反推例外的条款（9-05 部分取证、11-20 只在注释里出现）也要有命中，否则例外会被判失效。
  fs.write_file(root .. '/tests/native/spec/exceptions_test.lua',
    '-- 夹具：条款 9-05 与 11-20 在这里被提到。\n')
  -- 生成块与基线由扫描结果算出来，夹具起步即幂等、即全绿。
  M.sync_index(root)
  M.sync_baseline(root)
  return root
end

function M.sync_index(root)
  local matrix = Acceptance.scan(root)
  local body, err = Acceptance.rewrite(matrix.index.body or readme_body(), Acceptance.render(matrix))
  assert(body, err)
  fs.write_file(root .. '/' .. Acceptance.INDEX, body)
  return body
end

function M.sync_baseline(root, override)
  local matrix = Acceptance.scan(root)
  local values = { evidenced = matrix.counts.evidenced, updated = '2026-11-20' }
  for key, value in pairs(override or {}) do values[key] = value end
  fs.write_file(root .. '/' .. Acceptance.BASELINE, Acceptance.render_baseline(values))
  return values
end

-- 按纯文本替换改坏一份夹具文件（Lua 模式里的元字符不参与匹配）。
function M.patch(root, relative, from, to)
  local path = root .. '/' .. relative
  local body = assert(fs.slurp(path), '夹具读不到 ' .. relative)
  local first, last = body:find(from, 1, true)
  assert(first, string.format('夹具里找不到要替换的片段 %q（%s）', from, relative))
  fs.write_file(path, body:sub(1, first - 1) .. to .. body:sub(last + 1))
end

return M
