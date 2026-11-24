-- 验收矩阵夹具（#243）：在临时目录里拼一份最小可用的假仓库，供 tests/native/guards/acceptance_matrix_test.lua
-- 逐项改坏再验红。夹具只写磁盘，不碰真实 docs/acceptance/；生成块与基线由 tools.acceptance 自己算，
-- 保证夹具起点就是绿的（改坏了才红，红的不是夹具本身）。
local fs = require('tests.support.fs_fixture')
local acceptance = require('tools.acceptance')

local M = {}

M.SPEC_CLAUSE = '夹具条款'
-- 证据路径：夹具里真实存在，删它或写不存在的路径就该判红。
M.EVIDENCE = 'tests/native/spec/demo_test.lua'

-- 会被 fast ∪ full 发现、且不属于 spec 车道的遗留测试（两条）。
M.LEGACY = { 'tests/native/alpha_test.lua', 'tests/native/slow/beta_test.lua' }

-- 实现覆盖表（ADR-0029 第五节）：夹具登记第 1 节的两条非试玩条款（1-01 a、1-02 b），
-- 1-03 是试玩条款，按设计不登记。落点与关联测试都真实存在，起点即绿。
M.COVERAGE_LANDING = 'server/platform_host.lua'
M.COVERAGE_TEST = M.LEGACY[1]

function M.shard(section)
  return string.format('%s/%02d-fixture.md', acceptance.DIR, section)
end

local function spec_body()
  local lines = { '# 夹具规格', '', '> 夹具：19 个小节，每个「## n. 」一行标题。', '' }
  for number = 1, acceptance.SPEC_SECTIONS do
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
    string.format('| %d-01 | %s：第 %d 节第一条 | 规则 | agent | a | unverified | — |',
      section, M.SPEC_CLAUSE, section),
  }
  if section == 1 then
    lines[#lines + 1] = '| 1-02 | 夹具条款：卡在外部依赖的那条 | 契约 | 人 | b | blocked | 卡在：夹具外部依赖 |'
  elseif section == 2 then
    lines[#lines + 1] = '| 2-02 | 夹具条款：划出范围的那条 | 功能 | agent | a | out-of-scope | 理由：夹具划出范围 |'
  elseif section == 3 then
    lines[#lines + 1] = string.format(
      '| 3-02 | 夹具条款：有证据的那条 | 规则 | agent | a | evidenced | %s |', M.EVIDENCE)
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

local function coverage_body(bodies)
  local lines = {
    '# 夹具实现覆盖表',
    '',
    '> 夹具：八列与 docs/acceptance/coverage.md 一致。',
    '',
    '| 条款 | 代码落点 | 关联测试 | 正常流程 | 失败流程 | 退出重进 | 存档恢复 | 等级 |',
    '| --- | --- | --- | --- | --- | --- | --- | --- |',
  }
  -- 覆盖表从分片正文派生：已贯通小节里每条非试玩条款都要有一行，等级照抄分片那一格。
  -- 这样「改坏分片的 ID」这类用例不会顺带把覆盖表也判红——门禁仍然只报被改坏的那一类；
  -- 新增已贯通小节也不必再改夹具，节号取 acceptance.COVERAGE_SECTIONS。
  local seen = {}
  for _, section in ipairs(acceptance.COVERAGE_SECTIONS) do
    -- 传了 bodies 就以它为准：缺的那份（例如这一节的分片被删掉）按空处理，不拿模板补回来。
    local body = bodies and (bodies[section] or '') or shard_body(section)
    for line in body:gmatch('[^\n]+') do
      local cells = {}
      for cell in line:gmatch('[^|]+') do cells[#cells + 1] = cell:match('^%s*(.-)%s*$') end
      local id, executor, level, status = cells[1], cells[4], cells[5], cells[6]
      if id and id:match('^%d+%-%d%d$') and executor ~= '试玩' and not seen[id] then
        seen[id] = true
        -- 卡在外部依赖或划出范围的条款没有可跑的关联测试，按格式写全角破折号。
        local tests = (status == 'blocked' or status == 'out-of-scope') and '—' or M.COVERAGE_TEST
        lines[#lines + 1] = string.format('| %s | %s | %s | 缺 | 缺 | 缺 | 缺 | %s |',
          id, M.COVERAGE_LANDING, tests, level)
      end
    end
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
    acceptance.BEGIN_MARK,
    '（占位）',
    acceptance.END_MARK,
    '',
  }, '\n')
end

-- 拼一份最小可用的假仓库：起点全绿。
function M.build(root)
  fs.rmrf(root)
  fs.mkdirp(root)
  fs.write_file(root .. '/' .. acceptance.SPEC, spec_body())
  for section = 1, acceptance.SPEC_SECTIONS do
    fs.write_file(root .. '/' .. M.shard(section), shard_body(section))
  end
  fs.write_file(root .. '/' .. acceptance.INDEX, readme_body())
  fs.write_file(root .. '/' .. acceptance.BUSTED, busted_body())
  for _, path in ipairs(M.LEGACY) do
    fs.write_file(root .. '/' .. path, '-- 夹具遗留测试：不跑，只用来数发现结果。\n')
  end
  -- 证据文件正文要带条款号：门禁除了看路径在不在 spec 车道，还看文件里有没有这条条款的 ID。
  fs.write_file(root .. '/' .. M.EVIDENCE, '-- 夹具证据文件：条款 3-02 的断言落在这里。\n')
  fs.write_file(root .. '/' .. acceptance.COVERAGE, coverage_body())
  fs.write_file(root .. '/' .. M.COVERAGE_LANDING, '-- 夹具代码落点：存在即算有落点。\n')
  fs.write_file(root .. '/tests/native/helper.lua', '-- 夹具助手：不是测试文件。\n')
  fs.write_file(root .. '/tests/native/notes.md', '不是测试文件。\n')
  -- 生成块与基线由扫描结果算出来，夹具起步即幂等、即全绿。
  M.sync_index(root)
  M.sync_baseline(root)
  return root
end

function M.sync_index(root)
  local matrix = acceptance.scan(root)
  local body, err = acceptance.rewrite(matrix.index.body or readme_body(), acceptance.render(matrix))
  assert(body, err)
  fs.write_file(root .. '/' .. acceptance.INDEX, body)
  return body
end

--- 按现存分片重派生覆盖表：删掉某节分片后同步一次，免得「条款不在矩阵里」盖住「缺分片」那一类。
function M.sync_coverage(root)
  local bodies = {}
  for _, section in ipairs(acceptance.COVERAGE_SECTIONS) do
    bodies[section] = fs.slurp(root .. '/' .. M.shard(section))
  end
  fs.write_file(root .. '/' .. acceptance.COVERAGE, coverage_body(bodies))
end

function M.sync_baseline(root, override)
  local matrix = acceptance.scan(root)
  local values = { evidenced = matrix.counts.evidenced, legacyTests = #matrix.lanes.legacy,
    updated = '2026-11-20' }
  for key, value in pairs(override or {}) do values[key] = value end
  fs.write_file(root .. '/' .. acceptance.BASELINE, acceptance.render_baseline(values))
  return values
end

-- 按纯文本替换改坏一份夹具文件（Lua 模式里的元字符不参与匹配）。
function M.patch(root, relative, from, to)
  local path = root .. '/' .. relative
  local body = assert(fs.slurp(path), '夹具读不到 ' .. relative)
  local first, last = body:find(from, 1, true)
  assert(first, string.format('夹具里找不到要替换的片段 %q（%s）', from, relative))
  fs.write_file(path, body:sub(1, first - 1) .. to .. body:sub(last + 1))
  -- 改的是分片正文就把覆盖表按改后的分片重派生：否则改坏条款 ID 会顺带触发覆盖表的
  -- 「条款不在矩阵里 / 已贯通小节缺条款」，被改坏的那一类反而淹没在噪声里。
  if relative:match('^docs/acceptance/%d%d%-') then
    local bodies = {}
    for _, section in ipairs(acceptance.COVERAGE_SECTIONS) do
      bodies[section] = assert(fs.slurp(root .. '/' .. M.shard(section)))
    end
    fs.write_file(root .. '/' .. acceptance.COVERAGE, coverage_body(bodies))
  end
end

return M
