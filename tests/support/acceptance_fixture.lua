-- 验收矩阵夹具（#243）：在临时目录里拼一份最小可用的假仓库，供 tests/native/guards/acceptance_matrix_test.lua
-- 逐项改坏再验红。夹具只写磁盘，不碰真实 docs/acceptance/；生成块与基线由 tools.acceptance 自己算，
-- 保证夹具起点就是绿的（改坏了才红，红的不是夹具本身）。
local fs = require('tests.support.fs_fixture')
local Acceptance = require('tools.acceptance')

local M = {}

M.SPEC_CLAUSE = '夹具条款'
-- 证据路径：夹具里真实存在，删它或写不存在的路径就该判红。
M.EVIDENCE = 'tests/native/spec/demo_test.lua'

-- 会被 fast ∪ full 发现、且不属于 spec 车道的遗留测试（两条）。
M.LEGACY = { 'tests/native/alpha_test.lua', 'tests/native/slow/beta_test.lua' }

function M.shard(section)
  return string.format('%s/%02d-fixture.md', Acceptance.DIR, section)
end

local function spec_body()
  local lines = { '# 夹具规格', '', '> 夹具：19 个小节，每个「## N. 」一行标题。', '' }
  for number = 1, Acceptance.SPEC_SECTIONS do
    lines[#lines + 1] = string.format('## %d. 夹具小节%d', number, number)
    lines[#lines + 1] = ''
    lines[#lines + 1] = '正文。'
    lines[#lines + 1] = ''
  end
  return table.concat(lines, '\n')
end

-- 每节一条 unverified；第 1 节再加一条 blocked 与一个「## C 级」小节（C 级条款只许住这里）、
-- 第 2 节一条 out-of-scope、第 3 节一条 evidenced。C 小节只有第 1 节有：门禁不许要求每份分片都带 C 小节。
local function shard_body(section)
  local lines = {
    string.format('# %d. 夹具小节%d', section, section),
    '',
    '> 夹具分片：七列与 TEMPLATE.md 一致。',
    '',
    '| ID | 条款 | 组 | 执行者 | 证据等级 | 状态 | 证据 / 理由 |',
    '| --- | --- | --- | --- | --- | --- | --- |',
    string.format('| %d-01 | %s：第 %d 节第一条 | 规则 | agent | A | unverified | — |',
      section, M.SPEC_CLAUSE, section),
  }
  if section == 1 then
    lines[#lines + 1] = '| 1-02 | 夹具条款：卡在外部依赖的那条 | 契约 | 人 | B | blocked | 卡在：夹具外部依赖 |'
  elseif section == 2 then
    lines[#lines + 1] = '| 2-02 | 夹具条款：划出范围的那条 | 功能 | agent | A | out-of-scope | 理由：夹具划出范围 |'
  elseif section == 3 then
    lines[#lines + 1] = string.format(
      '| 3-02 | 夹具条款：有证据的那条 | 规则 | agent | A | evidenced | %s |', M.EVIDENCE)
  end
  if section == 1 then
    lines[#lines + 1] = ''
    lines[#lines + 1] = '## C 级（试玩取证）'
    lines[#lines + 1] = ''
    lines[#lines + 1] = '| ID | 条款 | 组 | 执行者 | 证据等级 | 状态 | 证据 / 理由 |'
    lines[#lines + 1] = '| --- | --- | --- | --- | --- | --- | --- |'
    lines[#lines + 1] = '| 1-03 | 夹具条款：只能试玩的那条 | 规则 | 试玩 | C | blocked | 卡在：夹具试玩场次 |'
  end
  lines[#lines + 1] = ''
  return table.concat(lines, '\n')
end

local function busted_body()
  return table.concat({
    '-- 夹具车道定义：与根目录 .busted 同形（_all 的 pattern 与 recursive、四个车道任务）。',
    'return {',
    '  _all = { pattern = "_test", recursive = false },',
    '  default = { ROOT = { "tests/native", "tests/native/slow", "tests/native/spec" } },',
    '  fast = { ROOT = { "tests/native" } },',
    '  full = { ROOT = { "tests/native", "tests/native/slow", "tests/native/spec" } },',
    '  spec = { ROOT = { "tests/native/spec" } },',
    '}',
    '',
  }, '\n')
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
  fs.write_file(root .. '/' .. Acceptance.SPEC, spec_body())
  for section = 1, Acceptance.SPEC_SECTIONS do
    fs.write_file(root .. '/' .. M.shard(section), shard_body(section))
  end
  fs.write_file(root .. '/' .. Acceptance.INDEX, readme_body())
  fs.write_file(root .. '/' .. Acceptance.BUSTED, busted_body())
  for _, path in ipairs(M.LEGACY) do
    fs.write_file(root .. '/' .. path, '-- 夹具遗留测试：不跑，只用来数发现结果。\n')
  end
  fs.write_file(root .. '/' .. M.EVIDENCE, '-- 夹具证据文件：存在即可。\n')
  fs.write_file(root .. '/tests/native/helper.lua', '-- 夹具助手：不是测试文件。\n')
  fs.write_file(root .. '/tests/native/notes.md', '不是测试文件。\n')
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
  local values = { evidenced = matrix.counts.evidenced, legacyTests = #matrix.lanes.legacy,
    updated = '2026-11-20' }
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
