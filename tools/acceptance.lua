-- 验收矩阵的唯一扫描与判定入口（#243）：把 docs/acceptance/ 的条款矩阵变成可校验的账。
-- 形状照 tools/arch_policy.lua：声明 → 扫描（只读仓库）→ 纯函数判定 → 违反项列表，便于用夹具测。
-- 落盘（改写 README 生成块、重写基线）归 tools/acceptance_cli.lua，本模块只读。
-- 本模块不得 require tests.*（tools/arch_policy.lua 的 no_test_imports 覆盖 tools/）。
local lfs = require('lfs')

local M = {}

M.SPEC = 'docs/GameSpec.md'
M.DIR = 'docs/acceptance'
M.INDEX = 'docs/acceptance/README.md'
M.BASELINE = 'docs/acceptance/baseline.lua'
M.BUSTED = '.busted'

M.BEGIN_MARK = '<!-- BEGIN GENERATED: acceptance-counts -->'
M.END_MARK = '<!-- END GENERATED: acceptance-counts -->'

-- GameSpec 的小节数：分片必须与它一一对应（节号 1..19），少一份、多一份、缺号都判红。
-- 口径是「恰好覆盖规格的 19 个小节」，不是「当前有多少份分片」；规格加小节时同时加分片并改这里，
-- 不靠放宽门禁去迁就中间状态。
M.SPEC_SECTIONS = 19

-- 条款断言车道：这些车道里的文件是「条款取证」，不是「实现自检」，不计入遗留测试。
-- ROOT 仍从 .busted 读，不另写一套目录规则；新增这类车道时在这里登记一行。
M.NON_LEGACY_LANES = { 'spec' }

-- 四列取值是封闭词表（docs/acceptance/TEMPLATE.md 第三节）。
M.VOCABULARY = {
  group = { '契约', '规则', '功能' },
  executor = { 'agent', '人', '试玩', '平台' },
  level = { 'A', 'B', 'C' },
  status = { 'unverified', 'evidenced', 'accepted', 'blocked', 'out-of-scope' },
}
-- 状态词表再暴露一份：计数、缺口密度与棘轮都按它逐项列。
M.STATUS = M.VOCABULARY.status

-- 禁用措辞（TEMPLATE 6.1）：这些词把「判不了」伪装成断言。
-- 只认**独立成句**的用法——词后紧跟句读或到结尾才算命中；「正常流程」「可行走」这类构词不算，
-- 否则会误伤既有条款（1-18 就写着「连通可行走」）。
M.VAGUE_WORDS = { '正确', '合理', '符合预期', '手感要好', '可行', '正常' }
local CLAUSE_PUNCT = ' 	，。；、：！？（）「」'

-- accepted 的证据列必须带人签署（TEMPLATE 第四节）：路径（签署：@用户名 YYYY-MM-DD）。
M.SIGNATURE = '（签署：@%S+ %d%d%d%d%-%d%d%-%d%d）'

-- 实现覆盖表（ADR-0029 第五节）：把每条非试玩条款接到它的代码落点、关联测试、四类证据与证据等级。
-- 它是文档与代码之间的静态缝隙，不是运行时入口；空落点、落点路径不存在、条款 ID 不在矩阵里、
-- 等级与矩阵不一致都判红，随 acceptance --check 进 fast 车道。
M.COVERAGE = 'docs/acceptance/coverage.md'
-- 已贯通小节：这些节的每条非试玩条款都必须在覆盖表里登记。逐节扩大——加一节就补齐该节落点。
M.COVERAGE_SECTIONS = { 1, 5, 16, 18 }
-- 四类证据列只有两个取值（完成口径见 ADR-0028）。
M.COVERAGE_EVIDENCE = { '有', '缺' }
-- 覆盖表每行八格：条款、代码落点、关联测试、正常流程、失败流程、退出重进、存档恢复、等级。
M.COVERAGE_COLUMNS = 8

-- 工单编号的四种常见写法：规格与分片都不得出现，台账按设计带历史单号（它不是分片，另算）。
-- 注意别误伤 Markdown 标题：'## 1. 概述' 的井号后面跟着另一个井号，'%s#%s%d+' 不成立。
M.ISSUE_PATTERNS = {
  { pattern = '#%d+' },
  { pattern = '%s#%s%d+' },
  { pattern = '工单%s*#?%s*%d+' },
  { pattern = 'issue%s*#?%s*%d+', lower = true },
}

-- 列的语义固定：条款行必须恰好七格，顺序与表头一致。
local COLUMNS = {
  { key = 'text', label = '条款' },
  { key = 'group', label = '组' },
  { key = 'executor', label = '执行者' },
  { key = 'level', label = '证据等级' },
  { key = 'status', label = '状态' },
  { key = 'evidence', label = '证据 / 理由' },
}

local function read_text(root, relative)
  local handle = io.open(root .. '/' .. relative, 'rb')
  if not handle then return nil end
  local body = handle:read('a')
  handle:close()
  return body
end

local function exists(root, relative)
  return lfs.attributes(root .. '/' .. relative) ~= nil
end

local function trim(text)
  return (text:match('^%s*(.-)%s*$'))
end

-- 违反项的唯一构造点：kind 是对外契约（夹具与文档按它断言、引用），四处手拼容易拼漏字段。
function M.finding(kind, message, path, line)
  return { kind = kind, message = message, path = path, line = line }
end

local function in_vocabulary(list, value)
  for _, item in ipairs(list) do
    if item == value then return true end
  end
  return false
end

-- 逐行遍历：回调拿到 1 起的行号与去掉行尾回车的一行。
local function each_line(body, fn)
  local number = 0
  for line in (body .. '\n'):gmatch('([^\n]*)\n') do
    number = number + 1
    fn(number, (line:gsub('\r$', '')))
  end
end

-- 按竖线切一格表格行：反斜杠转义的竖线不切（TEMPLATE 第六节允许写成 \| 保留竖线）。
local function cells_of(line)
  local body = line:match('^%s*|(.*)|%s*$')
  if not body then return nil end
  local cells, buffer, index = {}, {}, 1
  while index <= #body do
    local char = body:sub(index, index)
    if char == '\\' then
      buffer[#buffer + 1] = body:sub(index + 1, index + 1)
      index = index + 2
    elseif char == '|' then
      cells[#cells + 1] = trim(table.concat(buffer))
      buffer = {}
      index = index + 1
    else
      buffer[#buffer + 1] = char
      index = index + 1
    end
  end
  cells[#cells + 1] = trim(table.concat(buffer))
  return cells
end

local function file_name(path)
  return (path:match('([^/]+)$') or path)
end

local function percent(value)
  return string.format('%.0f%%', value * 100)
end

local function ratio(part, total)
  if not total or total == 0 then return 0 end
  return part / total
end

local function list_dir(root, relative)
  local names = {}
  local ok, iter, state, ctrl = pcall(lfs.dir, root .. '/' .. relative)
  if not ok then return names end
  for name in iter, state, ctrl do
    if name ~= '.' and name ~= '..' then names[#names + 1] = name end
  end
  table.sort(names)
  return names
end

-- 证据列里的仓库相对路径：只认「带目录分隔符且末段带扩展名」的串，避免把中文说明当路径。
function M.evidence_paths(cell)
  local out = {}
  if type(cell) ~= 'string' then return out end
  for token in cell:gmatch('[%w_%-%./]+') do
    local path = (token:gsub('/+$', ''))
    if path:find('/') and path:match('%.%w+$') then out[#out + 1] = path end
  end
  return out
end

-- GameSpec 的小节：只看 '## N. 标题' 这一种标题；别的层级不算小节。
function M.spec_sections(body)
  local sections = {}
  each_line(body, function(number, line)
    local id, title = line:match('^## (%d+)%. (.+)$')
    if id then
      sections[#sections + 1] = { number = tonumber(id), title = trim(title), line = number }
    end
  end)
  return sections
end

-- 工单编号：规格与分片都不许出现（写单号等于把待办留在单据里，矩阵才是唯一待办面）。
-- 四种写法见 M.ISSUE_PATTERNS；同一处被两种模式同时命中时只报一次。
function M.issue_refs(body)
  local out = {}
  each_line(body, function(number, line)
    local covered = {}
    local lower = line:lower()
    for _, entry in ipairs(M.ISSUE_PATTERNS) do
      local text = entry.lower and lower or line
      local from = 1
      while true do
        local first, last = text:find(entry.pattern, from)
        if not first then break end
        local overlapped = false
        for _, span in ipairs(covered) do
          if first <= span[2] and last >= span[1] then
            overlapped = true
            break
          end
        end
        if not overlapped then
          covered[#covered + 1] = { first, last }
          out[#out + 1] = { line = number, text = trim(line:sub(first, last)) }
        end
        from = last + 1
      end
    end
  end)
  return out
end

-- 禁用措辞命中：只认独立成句（后接句读或到结尾），见 M.VAGUE_WORDS 的注释。
function M.vague_hits(cell)
  local hits = {}
  if type(cell) ~= 'string' then return hits end
  for _, word in ipairs(M.VAGUE_WORDS) do
    local from = 1
    while true do
      local first, last = cell:find(word, from, true)
      if not first then break end
      local following = cell:sub(last + 1, last + 1)
      if following == '' or CLAUSE_PUNCT:find(following, 1, true) then
        hits[#hits + 1] = word
        break
      end
      from = last + 1
    end
  end
  return hits
end

-- accepted 的人签署：证据列里必须有一段「（签署：@用户名 YYYY-MM-DD）」。
function M.signed(cell)
  return type(cell) == 'string' and cell:find(M.SIGNATURE) ~= nil
end

-- 条款行 = 表格行且首格形如 'N-NN'；表头、分隔行与别处的表都不算条款行。
-- 首格形如数字-数字却不是「节号 + 两位序号」的，单独记 clause_id 违规，不静默跳过。
-- 条款所属小节 = 它上方最近的 '## ' 标题：分片可以有任意张小表、任意个小节，
-- 只要求「## C 级」小节里的条款等级是 C、「## C 级」以外的条款不是 C（正文见 TEMPLATE 2.1）。
function M.parse_shard(body, path, section)
  local shard = { path = path, section = section, title = nil, clauses = {}, heading_number = nil }
  local subsection
  each_line(body, function(number, line)
    local heading_number, heading_title = line:match('^# (%d+)%. (.+)$')
    if heading_number and not shard.heading_number then
      shard.heading_number, shard.title = tonumber(heading_number), trim(heading_title)
    end
    local h2 = line:match('^## (.+)$')
    if h2 then subsection = trim(h2) end
    if line:match('^%s*|') then
      local cells = cells_of(line)
      if cells and cells[1] and cells[1]:match('^%d+%-%d+$') then
        local clause = { id = cells[1], path = path, line = number, cell_count = #cells, subsection = subsection }
        for index, column in ipairs(COLUMNS) do
          clause[column.key] = cells[index + 1]
        end
        local id_section, serial = cells[1]:match('^(%d%d?)%-(%d%d)$')
        if id_section then
          clause.section, clause.serial = tonumber(id_section), tonumber(serial)
        end
        shard.clauses[#shard.clauses + 1] = clause
      end
    end
  end)
  return shard
end

-- 分片文件：docs/acceptance/NN-*.md；README、TEMPLATE、evidence-levels 等不带两位数字前缀的不是分片。
-- 覆盖表里的一格可以写多个路径，用顿号分隔（模板见 docs/acceptance/coverage.md）。
-- 只取「像路径」的串：路径全为 ASCII，中文说明与破折号自然不算落点，也不会被多字节分隔符切碎。
local function coverage_tokens(cell)
  local out = {}
  if type(cell) ~= 'string' then return out end
  for token in cell:gmatch('[%w_%-%./]+') do
    out[#out + 1] = token
  end
  return out
end

-- 落点必须是仓库里的一个**文件**：目录、通配符、中文说明都不算落点。
local function is_file(root, relative)
  local attr = lfs.attributes(root .. '/' .. relative)
  return attr ~= nil and attr.mode == 'file'
end

-- 覆盖表 = 若干张八列表，首格形如 '9-07' 的行才算登记行；表头与分隔行不算。
function M.parse_coverage(body, path)
  local coverage = { path = path, rows = {} }
  if not body then return coverage end
  each_line(body, function(number, line)
    local cells = cells_of(line)
    if not cells or #cells == 0 then return end
    local id = cells[1]
    if not id:match('^%d+%-%d%d$') then return end
    coverage.rows[#coverage.rows + 1] = {
      id = id, line = number, cells = cells, count = #cells,
      landing = cells[2], tests = cells[3],
      normal = cells[4], failure = cells[5], relogin = cells[6], restore = cells[7],
      level = cells[8],
    }
  end)
  return coverage
end

function M.shard_files(root)
  local out = {}
  for _, name in ipairs(list_dir(root, M.DIR)) do
    local section = name:match('^(%d%d)%-.*%.md$')
    if section then
      out[#out + 1] = { path = M.DIR .. '/' .. name, name = name, section = tonumber(section) }
    end
  end
  return out
end

-- 基线文件与 .busted 都是纯 Lua 表，可 dofile：load 到空环境执行，不信任输入。
-- 两处原本是同形的两份实现，合并到这里；读不到时的措辞由 missing 参数给（两处不同）。
local function read_lua_table(root, relative, missing)
  local body = read_text(root, relative)
  if not body then return nil, missing end
  local chunk, err = load(body, '@' .. relative, 't', {})
  if not chunk then return nil, relative .. ' 不是纯 Lua 数据文件: ' .. tostring(err) end
  local ok, values = pcall(chunk)
  if not ok or type(values) ~= 'table' then
    return nil, relative .. ' 求值失败: ' .. tostring(values)
  end
  return values
end

function M.read_baseline(root)
  return read_lua_table(root, M.BASELINE, '读不到 ' .. M.BASELINE)
end

function M.read_busted(root)
  return read_lua_table(root, M.BUSTED, '读不到根目录 ' .. M.BUSTED)
end

-- 车道参数与 busted 同口径：任务继承 _all；pattern 缺省 _spec、recursive 缺省 true。
function M.task_config(config, name)
  local task = {}
  for key, value in pairs(config._all or {}) do task[key] = value end
  for key, value in pairs(config[name] or {}) do task[key] = value end
  if task.pattern == nil then task.pattern = '_spec' end
  if task.recursive == nil then task.recursive = true end
  return task
end

local function patterns_of(task)
  if type(task.pattern) == 'table' then return task.pattern end
  return { task.pattern }
end

local function collect(root, relative, recursive, out)
  local attr = lfs.attributes(root .. '/' .. relative)
  if not attr then return end
  if attr.mode == 'file' then
    out[#out + 1] = relative
    return
  end
  if attr.mode ~= 'directory' then return end
  for _, name in ipairs(list_dir(root, relative)) do
    local path = relative .. '/' .. name
    local child = lfs.attributes(root .. '/' .. path)
    if child and child.mode == 'directory' then
      if recursive then collect(root, path, recursive, out) end
    elseif child and child.mode == 'file' then
      out[#out + 1] = path
    end
  end
end

-- 一个车道实际会发现的测试文件：ROOT 里按 recursive 列文件，basename 命中 pattern、扩展名 .lua。
-- 与 busted.modules.test_file_loader 的语义一致（basename:find(pattern)，非递归只列直接子文件）。
function M.lane_files(root, config, name)
  local task = M.task_config(config, name)
  local patterns = patterns_of(task)
  local files = {}
  for _, entry in ipairs(task.ROOT or {}) do
    local candidates = {}
    collect(root, entry, task.recursive == true, candidates)
    for _, path in ipairs(candidates) do
      local base = file_name(path)
      if base:match('%.lua$') then
        for _, pattern in ipairs(patterns) do
          if base:find(pattern) then
            files[#files + 1] = path
            break
          end
        end
      end
    end
  end
  table.sort(files)
  return files
end

-- 遗留测试：fast ∪ full 车道会发现的文件，剔除条款断言车道（M.NON_LEGACY_LANES）的 ROOT。
-- ROOT、pattern、recursive 全部来自 .busted，所以车道定义改一处这里就跟着变，不会各写一套。
function M.legacy_tests(root, config)
  local order, seen = {}, {}
  local function absorb(name)
    for _, path in ipairs(M.lane_files(root, config, name)) do
      if not seen[path] then
        seen[path] = true
        order[#order + 1] = path
      end
    end
  end
  absorb('fast')
  absorb('full')
  for _, name in ipairs(M.NON_LEGACY_LANES) do
    for _, path in ipairs(M.lane_files(root, config, name)) do seen[path] = nil end
  end
  local kept = {}
  for _, path in ipairs(order) do
    if seen[path] then kept[#kept + 1] = path end
  end
  table.sort(kept)
  return kept
end

local function index_block(body)
  local first = body:find(M.BEGIN_MARK, 1, true)
  if not first then return nil end
  local stop = body:find(M.END_MARK, first, true)
  if not stop then return nil end
  return body:sub(first, stop + #M.END_MARK - 1)
end

-- 各状态计数与每节缺口密度：只数词表内的状态，越界取值由 M.check 单独判红。
function M.counts(matrix)
  local counts = { total = 0, status = {}, sections = {} }
  for _, status in ipairs(M.STATUS) do counts.status[status] = 0 end
  local shards = {}
  for _, shard in ipairs(matrix.shards) do shards[#shards + 1] = shard end
  table.sort(shards, function(a, b) return a.path < b.path end)
  for _, shard in ipairs(shards) do
    local entry = { section = shard.section, path = shard.path, title = shard.title, total = 0, status = {} }
    for _, status in ipairs(M.STATUS) do entry.status[status] = 0 end
    for _, clause in ipairs(shard.clauses) do
      if in_vocabulary(M.STATUS, clause.status) then
        entry.status[clause.status] = entry.status[clause.status] + 1
        counts.status[clause.status] = counts.status[clause.status] + 1
        entry.total = entry.total + 1
        counts.total = counts.total + 1
      end
    end
    entry.evidenced = entry.status.evidenced + entry.status.accepted
    entry.gap = ratio(entry.status.unverified + entry.status.blocked + entry.status['out-of-scope'], entry.total)
    counts.sections[#counts.sections + 1] = entry
  end
  counts.evidenced = counts.status.evidenced + counts.status.accepted
  counts.gap = ratio(counts.status.unverified + counts.status.blocked + counts.status['out-of-scope'], counts.total)
  counts.outOfScope = ratio(counts.status['out-of-scope'], counts.total)
  return counts
end

-- 扫描：只读仓库，不判红。判红全部在 M.check，夹具才能拿同一份扫描结果换输入反复判定。
function M.scan(root)
  local matrix = { root = root, shards = {}, by_section = {}, problems = {}, shard_refs = {} }
  local function problem(kind, message, path, line)
    matrix.problems[#matrix.problems + 1] = M.finding(kind, message, path, line)
  end

  local spec_body = read_text(root, M.SPEC)
  if spec_body then
    matrix.spec = { sections = M.spec_sections(spec_body), refs = M.issue_refs(spec_body) }
  else
    matrix.spec = { sections = {}, refs = {} }
    problem('spec_unreadable', '读不到 ' .. M.SPEC, M.SPEC)
  end

  for _, entry in ipairs(M.shard_files(root)) do
    local body = read_text(root, entry.path)
    if not body then
      problem('shard_unreadable', '读不到 ' .. entry.path, entry.path)
    else
      local shard = M.parse_shard(body, entry.path, entry.section)
      matrix.shards[#matrix.shards + 1] = shard
      matrix.by_section[entry.section] = matrix.by_section[entry.section] or {}
      table.insert(matrix.by_section[entry.section], shard)
      -- 分片里也不许出现工单编号。legacy-ledger.md 按设计带历史单号，但它不带两位数字前缀，
      -- 本来就不是分片（见 M.shard_files），不在这里排除。
      for _, ref in ipairs(M.issue_refs(body)) do
        ref.path = entry.path
        matrix.shard_refs[#matrix.shard_refs + 1] = ref
      end
    end
  end

  local index_body = read_text(root, M.INDEX)
  matrix.index = { path = M.INDEX, body = index_body, block = index_body and index_block(index_body) or nil }
  if not index_body then problem('index_unreadable', '读不到 ' .. M.INDEX, M.INDEX) end

  -- 实现覆盖表：登记行只做扫描与统计，判红在 M.check 的 check_coverage。
  local coverage_body = read_text(root, M.COVERAGE)
  matrix.coverage = coverage_body and M.parse_coverage(coverage_body, M.COVERAGE) or nil

  matrix.baseline, matrix.baseline_error = M.read_baseline(root)

  local config, config_error = M.read_busted(root)
  matrix.lanes = { config = config, files = {} }
  if not config then
    problem('busted_unreadable', config_error, M.BUSTED)
  else
    for name in pairs(config) do
      if name ~= '_all' then
        matrix.lanes.files[name] = #M.lane_files(root, config, name)
      end
    end
    matrix.lanes.legacy = M.legacy_tests(root, config)
  end

  matrix.counts = M.counts(matrix)
  return matrix
end

local function status_expects_paths(status)
  return status == 'evidenced' or status == 'accepted'
end

local function is_c_section(heading)
  return type(heading) == 'string' and heading:find('C 级', 1, true) ~= nil
end

-- 规格：小节数与编号连续，且全篇不得出现工单编号。
local function check_spec(matrix, add)
  local sections = matrix.spec.sections
  if #sections ~= M.SPEC_SECTIONS then
    add('spec_sections', string.format('%s 应有 %d 个「## N. 」小节，实际 %d 个',
      M.SPEC, M.SPEC_SECTIONS, #sections), M.SPEC)
  end
  for index, section in ipairs(sections) do
    if section.number ~= index then
      add('spec_sections', string.format('小节编号不连续：第 %d 个标题是第 %d 节', index, section.number),
        M.SPEC, section.line)
    end
  end
  for _, ref in ipairs(matrix.spec.refs) do
    add('spec_issue_ref', '规格不得出现工单编号 ' .. ref.text, M.SPEC, ref.line)
  end
end

-- 分片：先核覆盖（每节恰好一份），再逐份核标题、七格、词表、ID 连续、证据列与措辞。
local function check_shards(matrix, add)
  for number = 1, M.SPEC_SECTIONS do
    local list = matrix.by_section[number]
    if not list or #list == 0 then
      add('shard_missing', string.format('第 %d 节没有条款分片（应有一份 %s/NN-*.md）', number, M.DIR), M.DIR)
    else
      for index = 2, #list do
        add('shard_duplicate', string.format('第 %d 节有多份分片：%s', number, list[index].path), list[index].path)
      end
    end
  end
  local extra = {}
  for number in pairs(matrix.by_section) do
    if number > M.SPEC_SECTIONS then extra[#extra + 1] = number end
  end
  table.sort(extra)
  for _, number in ipairs(extra) do
    for _, shard in ipairs(matrix.by_section[number]) do
      add('shard_unknown', string.format('分片 %s 的节号 %d 超出规格小节数 %d',
        shard.path, number, M.SPEC_SECTIONS), shard.path)
    end
  end

  -- 分片里也不得出现工单编号：条款的依据只能写在矩阵里，不靠单据号。
  for _, ref in ipairs(matrix.shard_refs) do
    add('spec_issue_ref', '分片不得出现工单编号 ' .. ref.text, ref.path, ref.line)
  end

  -- 每份分片：标题、条款七格、封闭词表、ID 连续不跳号不重复、证据列按状态。
  for _, shard in ipairs(matrix.shards) do
    if shard.heading_number and shard.heading_number ~= shard.section then
      add('shard_title', string.format('%s 的标题是第 %d 节，文件名是第 %d 节',
        shard.path, shard.heading_number, shard.section), shard.path, 1)
    end
    local ids, serials = {}, {}
    for _, clause in ipairs(shard.clauses) do
      if clause.cell_count ~= 7 then
        add('clause_cells', string.format('%s 的 %s 有 %d 格，条款行必须恰好七格', shard.path, clause.id,
          clause.cell_count), shard.path, clause.line)
      end
      if not clause.serial then
        add('clause_id', string.format('%s 的条款 ID %q 不合规：节号不带前导零、序号两位（如 9-07）',
          shard.path, clause.id), shard.path, clause.line)
      elseif clause.section ~= shard.section then
        add('clause_id', string.format('%s 的条款 %s 的节号与文件名第 %d 节不一致',
          shard.path, clause.id, shard.section), shard.path, clause.line)
      end
      if ids[clause.id] then
        add('id_sequence', string.format('%s 的条款 ID 重复：%s', shard.path, clause.id), shard.path, clause.line)
      end
      ids[clause.id] = true
      if clause.serial then serials[#serials + 1] = clause.serial end

      for _, column in ipairs(COLUMNS) do
        local list = M.VOCABULARY[column.key]
        if list and not in_vocabulary(list, clause[column.key]) then
          add('vocabulary', string.format('%s 的 %s 在「%s」列写了词表外的取值 %q',
            shard.path, clause.id, column.label, tostring(clause[column.key])), shard.path, clause.line)
        end
      end

      -- 禁用措辞（TEMPLATE 6.1）：判不了真假的词不该当成断言，命中即判红。
      for _, word in ipairs(M.vague_hits(clause.text)) do
        add('vague_wording', string.format('%s 的条款用了不可判的措辞「%s」：改写成可观察的条件与结果',
          clause.id, word), shard.path, clause.line)
      end

      -- 证据等级与所在小节对齐：C 级条款只住「## C 级」小节，C 级小节只装 C 级条款。
      -- 不要求 C 小节在文件末尾，也不要求每个分片都有 C 小节（第 18 节就没有）。
      if in_vocabulary(M.VOCABULARY.level, clause.level) then
        local tried = is_c_section(clause.subsection)
        if tried and clause.level ~= 'C' then
          add('level_section', string.format('%s 的 %s 在「%s」小节里，证据等级必须是 C，现写的是 %s',
            shard.path, clause.id, clause.subsection, tostring(clause.level)), shard.path, clause.line)
        elseif not tried and clause.level == 'C' then
          add('level_section', string.format('%s 的 %s 是 C 级条款，必须挪进「## C 级（试玩取证）」小节（当前小节：%s）',
            shard.path, clause.id, clause.subsection or '文件级表格'), shard.path, clause.line)
        end
      end

      local evidence = clause.evidence or ''
      if status_expects_paths(clause.status) then
        local paths = M.evidence_paths(evidence)
        if #paths == 0 then
          add('evidence_missing', string.format('%s 标为 %s 却没有仓库相对路径（现写的是 %q）',
            clause.id, clause.status, evidence), shard.path, clause.line)
        end
        for _, path in ipairs(paths) do
          if not exists(matrix.root, path) then
            add('evidence_missing', string.format('%s 的证据路径不存在：%s', clause.id, path),
              shard.path, clause.line)
          end
        end
        -- 条款断言车道：evidenced/accepted 的 agent 条款必须至少有一条 tests/native/spec 或 tests/probes 证据。
        if #paths > 0 and (clause.status == 'evidenced' or clause.status == 'accepted')
            and clause.executor == 'agent' then
          local clause_assertion = false
          for _, path in ipairs(paths) do
            if path:match('^tests/native/spec/') or path:match('^tests/probes/') then
              clause_assertion = true
              break
            end
          end
          if not clause_assertion then
            add('evidence_not_clause_assertion', string.format(
              '%s 标为 %s，但证据列没有 tests/native/spec/ 或 tests/probes/ 下的条款断言（现写的是 %q）',
              clause.id, clause.status, evidence), shard.path, clause.line)
          end
        end
        -- accepted 另要人背书：路径后面必须跟（签署：@用户名 YYYY-MM-DD）。
        if clause.status == 'accepted' and not M.signed(evidence) then
          add('accepted_signature', string.format(
            '%s 标为 accepted，证据列必须带人签署「（签署：@用户名 YYYY-MM-DD）」（现写的是 %q）',
            clause.id, evidence), shard.path, clause.line)
        end
      elseif clause.status == 'blocked' then
        local rest = evidence:match('^卡在：%s*(.*)$')
        if not rest or rest == '' then
          add('blocked_reason', string.format('%s 标为 blocked，证据列必须以「卡在：」开头并写明卡在谁（现写的是 %q）',
            clause.id, evidence), shard.path, clause.line)
        end
      elseif clause.status == 'out-of-scope' then
        local rest = evidence:match('^理由：%s*(.*)$')
        if not rest or rest == '' then
          add('out_of_scope_reason', string.format('%s 标为 out-of-scope，证据列必须以「理由：」开头并写明理由（现写的是 %q）',
            clause.id, evidence), shard.path, clause.line)
        end
      end
    end

    table.sort(serials)
    for index, serial in ipairs(serials) do
      if serial ~= index then
        add('id_sequence', string.format('%s 的条款序号不从 01 连续：第 %d 个序号是 %d',
          shard.path, index, serial), shard.path)
        break
      end
    end
  end
end

-- 索引：生成块必须与分片算出来的表一字不差；手改数字即判红。
local function check_index(matrix, add)
  if matrix.index.body then
    if not matrix.index.block then
      add('index_markers', string.format('%s 缺少生成块标记（%s / %s）',
        M.INDEX, M.BEGIN_MARK, M.END_MARK), M.INDEX)
    elseif matrix.index.block ~= M.render(matrix) then
      add('index_stale', 'README 的生成块与分片不一致：手改过，或分片改了没跑 `lua tools/cli.lua acceptance --write`',
        M.INDEX)
    end
  end
end

-- 双棘轮：已取证只增、遗留测试只减；基线本身读不出来也是红。
local function check_ratchet(matrix, add)
  local baseline = matrix.baseline
  if not baseline then
    add('baseline_unreadable', matrix.baseline_error or ('读不到 ' .. M.BASELINE), M.BASELINE)
  else
    local evidenced, legacy = baseline.evidenced, baseline.legacyTests
    if type(evidenced) ~= 'number' or evidenced ~= math.floor(evidenced) or evidenced < 0 then
      add('baseline_shape', M.BASELINE .. ' 的 evidenced 必须是 0 以上的整数', M.BASELINE)
    elseif matrix.counts.evidenced < evidenced then
      add('ratchet_evidenced', string.format('已取证条款数从基线 %d 降到 %d：evidenced+accepted 只许增',
        evidenced, matrix.counts.evidenced), M.BASELINE)
    end
    if type(legacy) ~= 'number' or legacy ~= math.floor(legacy) or legacy < 0 then
      add('baseline_shape', M.BASELINE .. ' 的 legacyTests 必须是 0 以上的整数', M.BASELINE)
    elseif matrix.lanes.legacy and #matrix.lanes.legacy > legacy then
      add('ratchet_legacy', string.format('遗留测试数从基线 %d 升到 %d：fast 与 full 只许减',
        legacy, #matrix.lanes.legacy), M.BUSTED)
    end
  end
end

-- 实现覆盖表：每条登记的条款都要有真实存在的代码落点；已贯通小节的非试玩条款一条都不能漏。
-- 覆盖表是「玩法实现」的台账（ADR-0029 第二节），它只证明代码落点在哪，不证明条款成立——
-- 条款转 evidenced 仍然只认矩阵证据列里那条走业务入口的断言。
local function check_coverage(matrix, add)
  local coverage = matrix.coverage
  if not coverage then
    add('coverage_unreadable', '读不到 ' .. M.COVERAGE, M.COVERAGE)
    return
  end

  -- 矩阵里的条款按 ID 建索引：覆盖表登记的 ID 必须在这里找得到，等级也要对得上。
  local clauses = {}
  for _, shard in ipairs(matrix.shards) do
    for _, clause in ipairs(shard.clauses) do
      clauses[clause.id] = clauses[clause.id] or clause
    end
  end

  local registered = {}
  for _, row in ipairs(coverage.rows) do
    local where = M.COVERAGE
    if row.count ~= M.COVERAGE_COLUMNS then
      add('coverage_cells', string.format('%s 的 %s 有 %d 格，覆盖表行必须恰好 %d 格',
        where, row.id, row.count, M.COVERAGE_COLUMNS), where, row.line)
    end
    if registered[row.id] then
      add('coverage_duplicate', string.format('%s 的条款 %s 被登记了不止一次', where, row.id),
        where, row.line)
    end
    registered[row.id] = true

    local clause = clauses[row.id]
    if not clause then
      add('coverage_clause_unknown', string.format('%s 登记的条款 %s 不在验收矩阵里', where, row.id),
        where, row.line)
    elseif clause.level ~= row.level then
      add('coverage_level', string.format('%s 的条款 %s 等级写的是 %s，矩阵里是 %s',
        where, row.id, tostring(row.level), tostring(clause.level)), where, row.line)
    end

    -- 代码落点：空、破折号、或路径不存在都判红——「没有落点」是这张表要拦住的第一件事。
    local landing = coverage_tokens(row.landing)
    if #landing == 0 then
      add('coverage_landing_missing', string.format('%s 的条款 %s 没有代码落点（现写的是 %q）',
        where, row.id, tostring(row.landing)), where, row.line)
    else
      for _, path in ipairs(landing) do
        if not is_file(matrix.root, path) then
          add('coverage_landing_path', string.format('%s 的条款 %s 的代码落点不存在或不是文件：%s',
            where, row.id, path), where, row.line)
        end
      end
    end

    -- 关联测试：允许写 —（还没有测试），写了路径就必须真实存在。
    if row.tests ~= '—' then
      local tests = coverage_tokens(row.tests)
      if #tests == 0 then
        add('coverage_test_missing', string.format('%s 的条款 %s 的关联测试列只能写 — 或仓库路径（现写的是 %q）',
          where, row.id, tostring(row.tests)), where, row.line)
      end
      for _, path in ipairs(tests) do
        if not is_file(matrix.root, path) then
          add('coverage_test_path', string.format('%s 的条款 %s 的关联测试不存在：%s',
            where, row.id, path), where, row.line)
        end
      end
    end

    -- 四类证据：只有「有 / 缺」两个取值，缺也要写出来，不允许留白。
    for _, key in ipairs({ 'normal', 'failure', 'relogin', 'restore' }) do
      if not in_vocabulary(M.COVERAGE_EVIDENCE, row[key]) then
        add('coverage_evidence', string.format('%s 的条款 %s 的四类证据列写了词表外的取值 %q（只能写 有 或 缺）',
          where, row.id, tostring(row[key])), where, row.line)
      end
    end
  end

  -- 已贯通小节：非试玩条款必须全部登记，漏一条就没有「无落点条款数为零」可言。
  for _, section in ipairs(M.COVERAGE_SECTIONS) do
    for _, shard in ipairs(matrix.by_section[section] or {}) do
      for _, clause in ipairs(shard.clauses) do
        if clause.executor ~= '试玩' and not registered[clause.id] then
          add('coverage_clause_missing', string.format('%s 里缺少第 %d 节的条款 %s：已贯通小节必须登记每条非试玩条款',
            M.COVERAGE, section, clause.id), M.COVERAGE)
        end
      end
    end
  end
end

-- 门禁总判：四类规则各在自己的函数里，这里只编排、最后统一排序。
-- finding 的 kind 字符串是对外契约（夹具按它精确断言、文档按它引用），名字一个都不许改。
function M.check(matrix)
  local findings = {}
  local function add(kind, message, path, line)
    findings[#findings + 1] = M.finding(kind, message, path, line)
  end

  for _, item in ipairs(matrix.problems) do
    findings[#findings + 1] = M.finding(item.kind, item.message, item.path, item.line)
  end
  check_spec(matrix, add)
  check_shards(matrix, add)
  check_index(matrix, add)
  check_coverage(matrix, add)
  check_ratchet(matrix, add)

  table.sort(findings, function(a, b)
    local left, right = a.path or '', b.path or ''
    if left ~= right then return left < right end
    local left_line, right_line = a.line or 0, b.line or 0
    if left_line ~= right_line then return left_line < right_line end
    if a.kind ~= b.kind then return a.kind < b.kind end
    return (a.message or '') < (b.message or '')
  end)
  return findings
end

-- 生成块：只由分片文件内容算出（标题取分片的一级标题，计数取条款行），所以幂等。
function M.render(matrix)
  local counts = matrix.counts or M.counts(matrix)
  local lines = {
    M.BEGIN_MARK,
    '> 本表由 `lua tools/cli.lua acceptance --write` 从 `docs/acceptance/NN-*.md` 的条款行生成，勿手改；',
    '> 手改会被 `lua tools/cli.lua acceptance --check`（fast 车道门禁）判红。',
    '',
    '| 节 | 标题 | 条款数 | unverified | evidenced | accepted | blocked | out-of-scope | 缺口密度 |',
    '| --- | --- | --- | --- | --- | --- | --- | --- | --- |',
  }
  for _, entry in ipairs(counts.sections) do
    lines[#lines + 1] = string.format('| [%d](%s) | %s | %d | %d | %d | %d | %d | %d | %s |',
      entry.section, file_name(entry.path), entry.title or '—', entry.total,
      entry.status.unverified, entry.status.evidenced, entry.status.accepted,
      entry.status.blocked, entry.status['out-of-scope'], percent(entry.gap))
  end
  lines[#lines + 1] = string.format('| 合计 | — | %d | %d | %d | %d | %d | %d | %s |',
    counts.total, counts.status.unverified, counts.status.evidenced, counts.status.accepted,
    counts.status.blocked, counts.status['out-of-scope'], percent(counts.gap))
  lines[#lines + 1] = ''
  lines[#lines + 1] = string.format(
    '已取证（evidenced + accepted）%d / %d；缺口密度 %s =（unverified + blocked + out-of-scope）÷ 条款数，'
      .. '其中 out-of-scope 占 %s。',
    counts.evidenced, counts.total, percent(counts.gap), percent(counts.outOfScope))
  lines[#lines + 1] = M.END_MARK
  return table.concat(lines, '\n')
end

-- 把生成块换进 README 正文；标记缺失返回 nil, 原因（不猜位置）。
function M.rewrite(body, block)
  local first = body:find(M.BEGIN_MARK, 1, true)
  if not first then return nil, '缺少 ' .. M.BEGIN_MARK end
  local stop = body:find(M.END_MARK, first, true)
  if not stop then return nil, '缺少 ' .. M.END_MARK end
  return body:sub(1, first - 1) .. block .. body:sub(stop + #M.END_MARK)
end

function M.render_baseline(values)
  return table.concat({
    '-- 双棘轮的基线（#243）：由 `lua tools/cli.lua acceptance --update-baseline` 写入，只许单向调整。',
    '-- evidenced（已取证条款数 = evidenced + accepted）只增：调低就是悄悄丢掉已验收的能力。',
    '-- legacyTests（fast 与 full 车道实际发现的测试文件数，剔除 spec 等条款断言车道）只减：清理不许停在半路。',
    '-- 调高 evidenced 或调低 legacyTests 之后才允许重写本文件；反方向的 --update-baseline 直接拒绝并退 2。',
    'return {',
    '  evidenced = ' .. tostring(values.evidenced) .. ',',
    '  legacyTests = ' .. tostring(values.legacyTests) .. ',',
    '  updated = "' .. tostring(values.updated) .. '",',
    '}',
    '',
  }, '\n')
end

-- 基线只能朝单向改：evidenced 抬、legacyTests 降。返回文本或 nil, 'refuse'|'unsupported', 原因。
function M.next_baseline(matrix)
  local baseline = matrix.baseline
  if not baseline then return nil, 'unsupported', matrix.baseline_error or ('读不到 ' .. M.BASELINE) end
  local legacy = matrix.lanes.legacy
  if not legacy then return nil, 'unsupported', '读不到车道定义，算不出遗留测试数' end
  local evidenced = matrix.counts.evidenced
  if type(baseline.evidenced) == 'number' and evidenced < baseline.evidenced then
    return nil, 'refuse', string.format('已取证 %d 条 < 基线 %d 条：棘轮只许增，拒绝下调',
      evidenced, baseline.evidenced)
  end
  if type(baseline.legacyTests) == 'number' and #legacy > baseline.legacyTests then
    return nil, 'refuse', string.format('遗留测试 %d 个 > 基线 %d 个：棘轮只许减，拒绝上调',
      #legacy, baseline.legacyTests)
  end
  return M.render_baseline({
    evidenced = evidenced,
    legacyTests = #legacy,
    updated = os.date('!%Y-%m-%d'),
  })
end

-- 门禁与 CLI 共用的总入口：一次跑完扫描与全部判定。
function M.verify(root)
  local matrix = M.scan(root)
  local findings = M.check(matrix)
  return { ok = #findings == 0, findings = findings, counts = matrix.counts, matrix = matrix }
end

return M