-- 验收矩阵的唯一扫描与判定入口（#243）：把 docs/acceptance/ 的条款矩阵变成可校验的账。
-- 形状照 tools/arch_policy.lua：声明 → 扫描（只读仓库）→ 纯函数判定 → 违反项列表，便于用夹具测。
-- 落盘（改写 README 生成块、重写基线）归 tools/acceptance_cli.lua，本模块只读。
-- 本模块不得 require tests.*（tools/arch_policy.lua 的 no_test_imports 覆盖 tools/）。
local lfs = require('lfs')

local M = {}

M.DIR = 'docs/acceptance'
M.INDEX = 'docs/acceptance/README.md'
M.BASELINE = 'docs/acceptance/baseline.lua'

M.BEGIN_MARK = '<!-- BEGIN GENERATED: acceptance-counts -->'
M.END_MARK = '<!-- END GENERATED: acceptance-counts -->'

-- GameSpec 的小节数：分片必须与它一一对应（节号 1..19），少一份、多一份、缺号都判红。
-- 口径是「恰好覆盖规格的 19 个小节」，不是「当前有多少份分片」；规格加小节时同时加分片并改这里，
-- 不靠放宽门禁去迁就中间状态。
M.SPEC_SECTIONS = 19

-- 条款只剩两列：ID 与文案，证据等级写成文案的行尾后缀（如「收线进度从 50% 起步（A）」）。
-- 组、执行者、状态、证据路径都不再由人写：前两者删掉，后两者从证据文件反推（见 M.infer）。
M.LEVELS = { 'A', 'B', 'C' }
-- 反推出的三种状态：有证据即 evidenced；没有证据的 C 级条款一律 blocked；其余 unverified。
M.STATUS = { 'evidenced', 'blocked', 'unverified' }

-- 证据面：条款走到哪一步不再由人写，从三类文件反推（#326）。
-- 断言面按条款号出现即算；C 级条款只有试玩会话的 ✅ 行才算取证。
M.ASSERTION_LANES = { 'tests/native/spec', 'tests/probes' }
M.EVIDENCE_DIR = 'evidence'
M.SESSION_FILE = 'session.md'
M.SESSION_MARK = '✅'
-- 例外：正文提到条款号、却不构成该条整体取证的两处。机器分不出「只取证了一段」与
-- 「注释里写着不归本单」，只能显式记在这里；guard 用例盯着每条例外仍然有命中。
-- keepEvidence 表示这条例外仍然记下证据路径（部分取证），不带则连路径也不记。
M.INFER_EXCEPTIONS = {
  ['9-05'] = { reason = 'spec 只断言抢救一段，伤害与队伍变更两段未取证', keepEvidence = true },
  ['11-20'] = { reason = 'spec 只在注释里写明「金豆入口不归本单」，没有断言' },
}

-- 禁用措辞（TEMPLATE 6.1）：这些词把「判不了」伪装成断言。
-- 只认**独立成句**的用法——词后紧跟句读或到结尾才算命中；「正常流程」「可行走」这类构词不算，
-- 否则会误伤既有条款（1-18 就写着「连通可行走」）。
M.VAGUE_WORDS = { '正确', '合理', '符合预期', '手感要好', '可行', '正常' }
local CLAUSE_PUNCT = ' 	，。；、：！？（）「」'

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

-- 条款号的前后边界：前置或后置的字符不能是数字或连字符。
-- 词字符边界挡不住日期与版本串——2026-11-04 里的 11-04 前后都是连字符。
local function clause_boundary(body, first, last)
  local before = first > 1 and body:sub(first - 1, first - 1) or ''
  local after = body:sub(last + 1, last + 1)
  if before ~= '' and (before:match('%d') or before == '-') then return false end
  if after ~= '' and (after:match('%d') or after == '-') then return false end
  return true
end

-- 证据文件里有没有这条条款：要求完整的条款号，前后都不能再贴词字符。
-- 只比路径前缀证明不了「断言的是这一条」——9-12 不能靠 19-12 或 9-120 蒙过去。
function M.clause_mentioned(body, id)
  if type(body) ~= 'string' or body == '' or type(id) ~= 'string' or id == '' then return false end
  local escaped = id:gsub('[%W]', '%%%0')
  local from = 1
  while true do
    local first, last = body:find('%f[%w]' .. escaped .. '%f[%W]', from)
    if not first then return false end
    if clause_boundary(body, first, last) then return true end
    from = last + 1
  end
end

-- 正文里出现的全部条款号（去重、按出现顺序）：用来找证据文件里指向已删条款的孤儿号。
-- 条款号的形状是「1~2 位节号-两位序号」，三位的 249-10 是工单/评审引用，不是条款。
function M.clause_ids(body)
  local out, seen = {}, {}
  if type(body) ~= 'string' then return out end
  local from = 1
  while true do
    local first, last = body:find('%f[%w]%d%d?%-%d%d%f[%W]', from)
    if not first then break end
    if clause_boundary(body, first, last) and not seen[body:sub(first, last)] then
      seen[body:sub(first, last)] = true
      out[#out + 1] = body:sub(first, last)
    end
    from = last + 1
  end
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

-- 条款行 = 表格行且首格形如 'N-NN'；表头、分隔行与别处的表都不算条款行。
-- 条款只有两格：ID 与文案。证据等级写成文案的行尾后缀「（A）」；组、执行者、状态与
-- 证据路径都不再写进分片——状态由 M.infer 从证据文件反推。
function M.parse_shard(body, path, section)
  local shard = { path = path, section = section, title = nil, clauses = {}, heading_number = nil }
  each_line(body, function(number, line)
    local heading_number, heading_title = line:match('^# (%d+)%. (.+)$')
    if heading_number and not shard.heading_number then
      shard.heading_number, shard.title = tonumber(heading_number), trim(heading_title)
    end
    if line:match('^%s*|') then
      local cells = cells_of(line)
      if cells and cells[1] and cells[1]:match('^%d+%-%d+$') then
        local text = cells[2] or ''
        local level = text:match('（([ABC])）$')
        if level then text = trim((text:gsub('（[ABC]）$', ''))) end
        local clause = { id = cells[1], path = path, line = number, cell_count = #cells,
          text = text, level = level }
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

-- 证据文件：断言面（spec 与 probes 的 .lua）加试玩会话记录（evidence/*/session.md）。
-- 顺序固定，反推出的路径与计数才幂等。
function M.evidence_files(root)
  local out = {}
  for _, dir in ipairs(M.ASSERTION_LANES) do
    for _, name in ipairs(list_dir(root, dir)) do
      if name:match('%.lua$') then out[#out + 1] = { path = dir .. '/' .. name, assertion = true } end
    end
  end
  for _, name in ipairs(list_dir(root, M.EVIDENCE_DIR)) do
    local path = M.EVIDENCE_DIR .. '/' .. name .. '/' .. M.SESSION_FILE
    if exists(root, path) then out[#out + 1] = { path = path, session = true } end
  end
  return out
end

-- 试玩会话里标成 ✅ 的条款号：只有这些行说明「这一场真的取证了」。
-- 同一节可能有 ✅（复核）与 ⛔（观察到不符）两行，✅ 一旦出现就保留；回归是缺陷，不是状态回退。
function M.session_covered(body)
  local covered = {}
  each_line(body, function(_, line)
    local id, mark = line:match('^%s*|%s*(%d+%-%d%d)%s*|%s*([^|]*)')
    if id and mark:find(M.SESSION_MARK, 1, true) then covered[id] = true end
  end)
  return covered
end

-- 反推：条款 → 证据路径 → 状态。
-- 断言面：A/B 条款的条款号出现即算；C 级条款只认试玩会话的 ✅ 行。
-- 没有证据的 C 级条款一律 blocked（唯一合法阻塞），其余 unverified。
-- 同时找出证据文件里出现、矩阵里却没有的条款号（孤儿号），供门禁判红。
function M.infer(matrix, root)
  local known, non_standard = {}, {}
  for _, shard in ipairs(matrix.shards) do
    for _, clause in ipairs(shard.clauses) do
      if not known[clause.id] then
        known[clause.id] = clause
        if not clause.id:match('^%d%d?%-%d%d$') then non_standard[#non_standard + 1] = clause end
      end
    end
  end

  local hits, orphans, seen_orphans = {}, {}, {}
  for id in pairs(known) do hits[id] = {} end
  for _, file in ipairs(M.evidence_files(root)) do
    local body = read_text(root, file.path)
    if body then
      local ids = M.clause_ids(body)
      if file.session then
        for id in pairs(M.session_covered(body)) do
          if known[id] then hits[id][#hits[id] + 1] = file.path end
        end
      else
        for _, id in ipairs(ids) do
          local clause = known[id]
          if clause and clause.level ~= 'C' then
            hits[id][#hits[id] + 1] = file.path
          end
        end
        for _, clause in ipairs(non_standard) do
          if clause.level ~= 'C' and M.clause_mentioned(body, clause.id) then
            hits[clause.id][#hits[clause.id] + 1] = file.path
          end
        end
      end
      for _, id in ipairs(ids) do
        local key = id .. '\0' .. file.path
        if not known[id] and not seen_orphans[key] then
          seen_orphans[key] = true
          orphans[#orphans + 1] = { id = id, path = file.path }
        end
      end
    end
  end

  local result = { status = {}, paths = {}, exceptions = {}, orphans = orphans }
  for id, clause in pairs(known) do
    local paths = hits[id]
    table.sort(paths)
    local exception = M.INFER_EXCEPTIONS[id]
    if exception then
      result.exceptions[#result.exceptions + 1] = { id = id, hits = #paths, reason = exception.reason }
      if not exception.keepEvidence then paths = {} end
      result.status[id] = 'unverified'
    elseif #paths > 0 then
      result.status[id] = 'evidenced'
    elseif clause.level == 'C' then
      result.status[id] = 'blocked'
    else
      result.status[id] = 'unverified'
    end
    result.paths[id] = paths
  end
  table.sort(result.orphans, function(a, b)
    if a.id ~= b.id then return a.id < b.id end
    return a.path < b.path
  end)
  return result
end

-- 分片文件：docs/acceptance/NN-*.md；README、TEMPLATE、evidence-levels 等不带两位数字前缀的不是分片。
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

-- 基线文件是纯 Lua 表，可 dofile：load 到空环境执行，不信任输入。
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

local function index_block(body)
  local first = body:find(M.BEGIN_MARK, 1, true)
  if not first then return nil end
  local stop = body:find(M.END_MARK, first, true)
  if not stop then return nil end
  return body:sub(first, stop + #M.END_MARK - 1)
end

-- 各状态计数与每节缺口密度：状态来自 M.infer，分片里不再手写。
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
      local status = matrix.inference.status[clause.id] or 'unverified'
      entry.status[status] = entry.status[status] + 1
      counts.status[status] = counts.status[status] + 1
      entry.total = entry.total + 1
      counts.total = counts.total + 1
    end
    entry.gap = ratio(entry.status.unverified + entry.status.blocked, entry.total)
    counts.sections[#counts.sections + 1] = entry
  end
  counts.evidenced = counts.status.evidenced
  counts.gap = ratio(counts.status.unverified + counts.status.blocked, counts.total)
  return counts
end

-- 扫描：只读仓库，不判红。判红全部在 M.check，夹具才能拿同一份扫描结果换输入反复判定。
function M.scan(root)
  local matrix = { root = root, shards = {}, by_section = {}, problems = {} }
  local function problem(kind, message, path, line)
    matrix.problems[#matrix.problems + 1] = M.finding(kind, message, path, line)
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
    end
  end

  local index_body = read_text(root, M.INDEX)
  matrix.index = { path = M.INDEX, body = index_body, block = index_body and index_block(index_body) or nil }
  if not index_body then problem('index_unreadable', '读不到 ' .. M.INDEX, M.INDEX) end

  -- 状态与证据路径从证据文件反推（#326）：扫描只做一次，计数与门禁都读它。
  matrix.inference = M.infer(matrix, root)
  matrix.baseline, matrix.baseline_error = M.read_baseline(root)
  matrix.counts = M.counts(matrix)
  return matrix
end

-- 结构与 ID：19 个小节各恰好一份分片；每份核标题、两格、ID 连续、等级后缀与禁用措辞。
-- 组、执行者、状态、证据四列已删（#326）：等级是文案的行尾后缀，状态从证据文件反推。
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

  for _, shard in ipairs(matrix.shards) do
    if shard.heading_number and shard.heading_number ~= shard.section then
      add('shard_title', string.format('%s 的标题是第 %d 节，文件名是第 %d 节',
        shard.path, shard.heading_number, shard.section), shard.path, 1)
    end
    local ids, serials = {}, {}
    for _, clause in ipairs(shard.clauses) do
      if clause.cell_count ~= 2 then
        add('clause_cells', string.format('%s 的 %s 有 %d 格，条款行必须恰好两格：ID 与文案',
          shard.path, clause.id, clause.cell_count), shard.path, clause.line)
      end
      if not in_vocabulary(M.LEVELS, clause.level) then
        add('clause_level', string.format('%s 的 %s 没有证据等级后缀：文案末尾写（A）（B）或（C）',
          shard.path, clause.id), shard.path, clause.line)
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

      -- 禁用措辞（TEMPLATE 6.1）：判不了真假的词不该当成断言，命中即判红。
      for _, word in ipairs(M.vague_hits(clause.text)) do
        add('vague_wording', string.format('%s 的条款用了不可判的措辞「%s」：改写成可观察的条件与结果',
          clause.id, word), shard.path, clause.line)
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

-- 证据面：证据文件只能引用矩阵里有的条款号；反推例外不能长期漂着。
local function check_evidence(matrix, add)
  local known = {}
  for _, shard in ipairs(matrix.shards) do
    for _, clause in ipairs(shard.clauses) do known[clause.id] = true end
  end
  for _, item in ipairs(matrix.inference.orphans) do
    add('orphan_clause', string.format('证据文件里出现矩阵没有的条款号 %s：删掉这处引用或补回条款',
      item.id), item.path)
  end
  for id in pairs(M.INFER_EXCEPTIONS) do
    if not known[id] then
      add('inference_exception_unknown', string.format('反推例外 %s 不是矩阵里的条款：删掉这条例外', id), M.DIR)
    end
  end
  for _, item in ipairs(matrix.inference.exceptions) do
    if item.hits == 0 then
      add('inference_exception_stale', string.format('反推例外 %s 已经没有任何证据文件命中：删掉这条例外',
        item.id), M.DIR)
    end
  end
end

-- 棘轮：已取证只增；基线本身读不出来也是红。
local function check_ratchet(matrix, add)
  local baseline = matrix.baseline
  if not baseline then
    add('baseline_unreadable', matrix.baseline_error or ('读不到 ' .. M.BASELINE), M.BASELINE)
  else
    local evidenced = baseline.evidenced
    if type(evidenced) ~= 'number' or evidenced ~= math.floor(evidenced) or evidenced < 0 then
      add('baseline_shape', M.BASELINE .. ' 的 evidenced 必须是 0 以上的整数', M.BASELINE)
    elseif matrix.counts.evidenced < evidenced then
      add('ratchet_evidenced', string.format('已取证条款数从基线 %d 降到 %d：evidenced 只许增',
        evidenced, matrix.counts.evidenced), M.BASELINE)
    end
  end
end

-- 门禁总判：五类规则各在自己的函数里，这里只编排、最后统一排序。
-- 五项：ID 与结构、禁用措辞（同在上面的结构检查里）、索引一致、证据文件覆盖条款号、已取证只增。
-- finding 的 kind 字符串是对外契约（夹具按它精确断言、文档按它引用），名字一个都不许改。
function M.check(matrix)
  local findings = {}
  local function add(kind, message, path, line)
    findings[#findings + 1] = M.finding(kind, message, path, line)
  end

  for _, item in ipairs(matrix.problems) do
    findings[#findings + 1] = M.finding(item.kind, item.message, item.path, item.line)
  end
  check_shards(matrix, add)
  check_index(matrix, add)
  check_evidence(matrix, add)
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

-- 生成块：只由分片与证据文件算出（标题取分片的一级标题，状态取反推结果），所以幂等。
function M.render(matrix)
  local counts = matrix.counts or M.counts(matrix)
  local lines = {
    M.BEGIN_MARK,
    '> 本表由 `lua tools/cli.lua acceptance --write` 从 `docs/acceptance/NN-*.md` 与证据文件生成，勿手改；',
    '> 手改会被 `lua tools/cli.lua acceptance --check`（fast 车道门禁）判红。',
    '',
    '| 节 | 标题 | 条款数 | evidenced | blocked | unverified | 缺口密度 |',
    '| --- | --- | --- | --- | --- | --- | --- |',
  }
  for _, entry in ipairs(counts.sections) do
    lines[#lines + 1] = string.format('| [%d](%s) | %s | %d | %d | %d | %d | %s |',
      entry.section, file_name(entry.path), entry.title or '—', entry.total,
      entry.status.evidenced, entry.status.blocked, entry.status.unverified, percent(entry.gap))
  end
  lines[#lines + 1] = string.format('| 合计 | — | %d | %d | %d | %d | %s |',
    counts.total, counts.status.evidenced, counts.status.blocked, counts.status.unverified, percent(counts.gap))
  lines[#lines + 1] = ''
  lines[#lines + 1] = string.format(
    '已取证 %d / %d；缺口密度 %s =（unverified + blocked）÷ 条款数。',
    counts.evidenced, counts.total, percent(counts.gap))
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
    '-- 已取证棘轮的基线（#326）：由 `lua tools/cli.lua acceptance --update-baseline` 写入，只许单向调整。',
    '-- evidenced（从 spec、probes 与 evidence/*/session.md 反推出的已取证条款数）只增：',
    '-- 调低就是悄悄丢掉已验收的能力；反方向的 --update-baseline 直接拒绝并退 2。',
    'return {',
    '  evidenced = ' .. tostring(values.evidenced) .. ',',
    '  updated = "' .. tostring(values.updated) .. '",',
    '}',
    '',
  }, '\n')
end

-- 基线只能朝单向改：evidenced 抬。返回文本或 nil, 'refuse'|'unsupported', 原因。
function M.next_baseline(matrix)
  local baseline = matrix.baseline
  if not baseline then return nil, 'unsupported', matrix.baseline_error or ('读不到 ' .. M.BASELINE) end
  local evidenced = matrix.counts.evidenced
  if type(baseline.evidenced) == 'number' and evidenced < baseline.evidenced then
    return nil, 'refuse', string.format('已取证 %d 条 < 基线 %d 条：棘轮只许增，拒绝下调',
      evidenced, baseline.evidenced)
  end
  return M.render_baseline({
    evidenced = evidenced,
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