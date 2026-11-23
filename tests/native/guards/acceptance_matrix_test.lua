-- #243 验收矩阵门禁（fast 车道）：spec-240 完成判据 2、4、5、6 的唯一硬门。
-- 真实仓库扫描只做一次，再叠一组夹具用例：夹具在临时目录里拼一份最小可用的假仓库，
-- 每次只改坏一处，断言门禁**只**因为那一处判红（kinds 精确比对，避免一处坏了别处顶着）。
-- 失败方式（先列后写）：
--   1. 真实矩阵不绿（分片缺、词表越界、证据路径不存在、索引与分片不一致、棘轮被反向推动）；
--   2. 改坏一处却不红（门禁睡着了），或红的地方不对（判错的规则）；
--   3. 条款断言车道被算进遗留测试（spec 断言一多，遗留棘轮就没法只减）。
-- 已知缺口（有 finding kind、但夹具还没逐条造坏过的）：spec_sections、spec_unreadable、
-- shard_unreadable、shard_title、clause_cells、index_unreadable、busted_unreadable、
-- baseline_unreadable。它们都由同一个 M.scan → M.check 管道产出，先靠真实矩阵与上面这些用例守着；
-- 补夹具时照本文件的写法：只改坏一处，断言 kinds 精确等于那一条。
local Acceptance = require('tools.acceptance')
local fs = require('tests.support.fs_fixture')
local fixture = require('tests.support.acceptance_fixture')

-- 真实仓库只扫一次：Arch.scan 那样的惯例，四个用例共享同一份结果。
local scanned, verified
local function real_matrix()
  if not scanned then scanned = Acceptance.scan('.') end
  return scanned
end
local function real_verify()
  if not verified then verified = Acceptance.verify('.') end
  return verified
end

local function kinds(findings)
  local out = {}
  for _, item in ipairs(findings) do out[#out + 1] = item.kind end
  table.sort(out)
  return out
end

local function messages(findings)
  local out = {}
  for _, item in ipairs(findings) do
    out[#out + 1] = string.format('[%s] %s %s', item.kind, item.path or '', item.message or '')
  end
  return table.concat(out, '\n')
end

describe('验收矩阵门禁', function()
  it('真实仓库的条款矩阵全绿', function()
    local result = real_verify()
    assert.is_true(result.ok, messages(result.findings))
  end)

  it('真实矩阵恰好覆盖规格的 19 个小节，节号连续', function()
    local matrix = real_matrix()
    assert.same(Acceptance.SPEC_SECTIONS, #matrix.spec.sections)
    assert.same(Acceptance.SPEC_SECTIONS, #matrix.shards)
    for number = 1, Acceptance.SPEC_SECTIONS do
      local list = matrix.by_section[number]
      assert.is_not_nil(list, '第 ' .. number .. ' 节没有分片')
      assert.same(1, #list, '第 ' .. number .. ' 节有多份分片')
      assert.same(number, list[1].section)
    end
    assert.is_true(matrix.counts.total > 0, '条款总数为 0：分片解析没生效')
  end)

  it('遗留测试数按 .busted 算，且不含条款断言车道', function()
    local matrix = real_matrix()
    local legacy = matrix.lanes.legacy
    assert.is_not_nil(legacy, '读不到车道定义')
    assert.is_true(#legacy > 0)
    local spec_lane = Acceptance.lane_files('.', matrix.lanes.config, 'spec')
    assert.is_true(#spec_lane > 0, 'spec 车道里没有文件：条款断言还没落地')
    local counted = {}
    for _, path in ipairs(legacy) do counted[path] = true end
    for _, path in ipairs(spec_lane) do
      assert.is_nil(counted[path], 'spec 车道的断言被算进遗留测试了: ' .. path)
    end
  end)

  it('真实实现覆盖表：已贯通小节的非试玩条款没有空落点', function()
    local matrix = real_matrix()
    assert.is_not_nil(matrix.coverage, '读不到实现覆盖表：' .. Acceptance.COVERAGE)
    local landed = {}
    for _, row in ipairs(matrix.coverage.rows) do
      assert.is_truthy(row.landing ~= nil and row.landing ~= '' and row.landing ~= '—',
        '覆盖表里的 ' .. row.id .. ' 没有代码落点')
      landed[row.id] = true
    end
    for _, section in ipairs(Acceptance.COVERAGE_SECTIONS) do
      for _, shard in ipairs(matrix.by_section[section] or {}) do
        for _, clause in ipairs(shard.clauses) do
          if clause.executor ~= '试玩' then
            assert.is_truthy(landed[clause.id],
              '第 ' .. section .. ' 节的 ' .. clause.id .. ' 是已贯通小节里的非试玩条款，却没登记代码落点')
          end
        end
      end
    end
  end)

  it('真实基线与当前值同向：已取证不低于基线，遗留测试不高于基线', function()
    local matrix = real_matrix()
    assert.is_not_nil(matrix.baseline, matrix.baseline_error)
    assert.is_true(matrix.counts.evidenced >= matrix.baseline.evidenced)
    assert.is_true(#matrix.lanes.legacy <= matrix.baseline.legacyTests)
    -- 本轮至少有一条真实条款通过 spec 车道转成 evidenced（完成判据 7 的证据侧）。
    assert.is_true(matrix.counts.evidenced >= 1)
  end)

  describe('夹具：逐项改坏必须判红', function()
    local root = fs.temp_dir()

    before_each(function() fixture.build(root) end)
    after_each(function() fs.rmrf(root) end)

    local function verify()
      local result = Acceptance.verify(root)
      return result.ok, kinds(result.findings), messages(result.findings)
    end

    it('起点合法：夹具本身不红', function()
      local ok, found, text = verify()
      assert.is_true(ok, text)
      assert.same({}, found)
    end)

    it('证据路径写成不存在的文件就红', function()
      fixture.patch(root, fixture.shard(3), fixture.EVIDENCE, 'tests/native/spec/gone_test.lua')
      local ok, found, text = verify()
      assert.is_false(ok)
      assert.same({ 'evidence_missing' }, found, text)
    end)

    it('evidenced 条款的证据在 spec 车道就绿', function()
      local ok, found, text = verify()
      assert.is_true(ok, text)
      assert.same({}, found)
    end)

    it('evidenced 条款只拿实现自检当证据就红', function()
      fixture.patch(root, fixture.shard(3), fixture.EVIDENCE, fixture.COVERAGE_TEST)
      local ok, found, text = verify()
      assert.is_false(ok)
      assert.same({ 'evidence_not_clause_assertion' }, found, text)
      assert.is_truthy(text:find('路径不符', 1, true), '没有 spec/probes 路径时消息要写清是路径不符：' .. text)
    end)

    it('spec 车道的证据文件正文里没有条款号就红', function()
      -- 路径落在 spec 车道、文件也存在，但正文里没有 3-02：路径前缀只是车道，内容才是证据。
      fs.write_file(root .. '/' .. fixture.EVIDENCE, '-- 夹具证据文件：正文里没写条款号。\n')
      local ok, found, text = verify()
      assert.is_false(ok)
      assert.same({ 'evidence_not_clause_assertion' }, found, text)
      assert.is_truthy(text:find('文件里没有条款号', 1, true),
        '文件存在但没有条款号时消息要写清是文件里没有条款号：' .. text)
    end)

    it('换成另一份正文带条款号的 spec 文件就绿', function()
      fs.write_file(root .. '/tests/native/spec/other_test.lua', '-- 夹具：条款 3-02 的断言。\n')
      fixture.patch(root, fixture.shard(3), fixture.EVIDENCE, 'tests/native/spec/other_test.lua')
      local ok, found, text = verify()
      assert.is_true(ok, text)
      assert.same({}, found)
    end)

    it('条款号按完整 ID 认：9-12 不认 19-12、09-12 与 9-120', function()
      assert.is_true(Acceptance.clause_mentioned('-- 条款 9-12：断言', '9-12'))
      assert.is_true(Acceptance.clause_mentioned('9-12 的断言', '9-12'))
      assert.is_false(Acceptance.clause_mentioned('-- 条款 19-12：断言', '9-12'))
      assert.is_false(Acceptance.clause_mentioned('-- 条款 09-12：断言', '9-12'))
      assert.is_false(Acceptance.clause_mentioned('-- 条款 9-120：断言', '9-12'))
    end)

    it('已取证计数低于基线就红', function()
      fixture.sync_baseline(root, { evidenced = 2 })
      local ok, found, text = verify()
      assert.is_false(ok)
      assert.same({ 'ratchet_evidenced' }, found, text)
    end)

    it('遗留测试计数高于基线就红', function()
      fixture.sync_baseline(root, { legacyTests = 1 })
      local ok, found, text = verify()
      assert.is_false(ok)
      assert.same({ 'ratchet_legacy' }, found, text)
    end)

    it('手改 README 生成块里的一个数字就红', function()
      -- 改合计行的数字：条款数一变，手改的串也不跟着变，用例才稳。
      fixture.patch(root, Acceptance.INDEX, '| 合计 | — |', '| 合计 | — | 9')
      local ok, found, text = verify()
      assert.is_false(ok)
      assert.same({ 'index_stale' }, found, text)
    end)

    it('新增条款后不重跑 --write 就红，重跑后恢复且幂等', function()
      fixture.patch(root, fixture.shard(4), '| 4-01 | 夹具条款：第 4 节第一条 | 规则 | agent | A | unverified | — |',
        '| 4-01 | 夹具条款：第 4 节第一条 | 规则 | agent | A | unverified | — |\n'
          .. '| 4-02 | 夹具条款：新加的一条 | 规则 | agent | A | unverified | — |')
      local ok, found, text = verify()
      assert.is_false(ok)
      assert.same({ 'index_stale' }, found, text)
      local first = fixture.sync_index(root)
      local second = fixture.sync_index(root)
      assert.same(first, second, '生成块必须幂等')
      local after_ok, after_found, after_text = verify()
      assert.is_true(after_ok, after_text)
      assert.same({}, after_found)
    end)

    it('覆盖表的代码落点写成破折号就红', function()
      fixture.patch(root, Acceptance.COVERAGE,
        '| 1-01 | server/PlatformHost.lua |', '| 1-01 | — |')
      local ok, found, text = verify()
      assert.is_false(ok)
      assert.same({ 'coverage_landing_missing' }, found, text)
    end)

    it('覆盖表的代码落点是不存在的文件就红', function()
      fixture.patch(root, Acceptance.COVERAGE,
        '| 1-02 | server/PlatformHost.lua |', '| 1-02 | server/Mgr/GonePlatform.lua |')
      local ok, found, text = verify()
      assert.is_false(ok)
      assert.same({ 'coverage_landing_path' }, found, text)
    end)

    it('已贯通小节里的非试玩条款漏登记就红', function()
      fixture.patch(root, Acceptance.COVERAGE,
        '\n| 1-02 | server/PlatformHost.lua | — | 缺 | 缺 | 缺 | 缺 | B |', '')
      local ok, found, text = verify()
      assert.is_false(ok)
      assert.same({ 'coverage_clause_missing' }, found, text)
    end)

    it('覆盖表的等级与矩阵不一致就红', function()
      fixture.patch(root, Acceptance.COVERAGE,
        '| 缺 | 缺 | 缺 | 缺 | B |', '| 缺 | 缺 | 缺 | 缺 | A |')
      local ok, found, text = verify()
      assert.is_false(ok)
      assert.same({ 'coverage_level' }, found, text)
    end)

    it('覆盖表的关联测试是不存在的文件就红', function()
      fixture.patch(root, Acceptance.COVERAGE, 'tests/native/alpha_test.lua',
        'tests/native/gone_test.lua')
      local ok, found, text = verify()
      assert.is_false(ok)
      assert.same({ 'coverage_test_path' }, found, text)
    end)

    it('blocked 少了「卡在：」就红', function()
      fixture.patch(root, fixture.shard(1), '卡在：夹具外部依赖', '夹具外部依赖')
      local ok, found, text = verify()
      assert.is_false(ok)
      assert.same({ 'blocked_reason' }, found, text)
    end)

    it('out-of-scope 少了「理由：」就红', function()
      fixture.patch(root, fixture.shard(2), '理由：夹具划出范围', '夹具划出范围')
      local ok, found, text = verify()
      assert.is_false(ok)
      assert.same({ 'out_of_scope_reason' }, found, text)
    end)

    it('GameSpec 里塞一个工单编号就红', function()
      fixture.patch(root, Acceptance.SPEC, '正文。', '正文（见 #123）。')
      local ok, found, text = verify()
      assert.is_false(ok)
      assert.same({ 'spec_issue_ref' }, found, text)
    end)

    -- 工单编号的四种写法都要认：井号加数字、空白夹着的 # 46、中文「工单46」、英文 issue 46。
    for _, sample in ipairs({ '#123', '# 46', '工单46', 'issue 46' }) do
      it('GameSpec 里的工单编号写法 ' .. sample .. ' 也判红', function()
        fixture.patch(root, Acceptance.SPEC, '正文。', '正文（见 ' .. sample .. '）。')
        local ok, found, text = verify()
        assert.is_false(ok)
        assert.same({ 'spec_issue_ref' }, found, text)
      end)
    end

    it('分片里塞一个工单编号也判红（台账不是分片，另有历史单号）', function()
      fixture.patch(root, fixture.shard(4), '夹具条款：第 4 节第一条', '夹具条款：第 4 节第一条（工单46）')
      local ok, found, text = verify()
      assert.is_false(ok)
      assert.same({ 'spec_issue_ref' }, found, text)
    end)

    it('Markdown 标题不是工单编号：## 1. 概述 与 # 12. 标题 都不命中', function()
      assert.same({}, Acceptance.issue_refs('## 1. 概述与范围'))
      assert.same({}, Acceptance.issue_refs('# 12. 精英与首领行为'))
      assert.same({}, Acceptance.issue_refs('| 9-07 | 只有距离 2 米内才能发起组队邀请 |'))
    end)

    it('条款写成不可判的措辞就红', function()
      fixture.patch(root, fixture.shard(5), '夹具条款：第 5 节第一条', '夹具条款：第 5 节第一条，结果正常。')
      local ok, found, text = verify()
      assert.is_false(ok)
      assert.same({ 'vague_wording' }, found, text)
    end)

    it('accepted 的证据列没有签署格式就红', function()
      fixture.patch(root, fixture.shard(3), '| A | evidenced |', '| A | accepted |')
      -- 生成块里 evidenced 与 accepted 是两列，改了状态要先同步索引，本用例只问签署这一条规则。
      fixture.sync_index(root)
      local ok, found, text = verify()
      assert.is_false(ok)
      assert.same({ 'accepted_signature' }, found, text)
    end)

    it('少一份分片就红', function()
      -- 用第 19 节：它的分片删掉后覆盖表也按现存分片重派生，否则已登记的 19-xx 会连带命中
      -- coverage_clause_unknown，就不再是单规则用例（#264 起第 1～19 节全部进了 COVERAGE_SECTIONS）。
      assert(fs.exists(root .. '/' .. fixture.shard(19)))
      os.remove(root .. '/' .. fixture.shard(19))
      fixture.sync_coverage(root)
      -- 索引跟着分片重算，避免同时命中 index_stale：本用例只问「缺分片」这一条规则。
      fixture.sync_index(root)
      local ok, found, text = verify()
      assert.is_false(ok)
      assert.same({ 'shard_missing' }, found, text)
    end)

    it('状态写成词表外的 done 就红', function()
      fixture.patch(root, fixture.shard(5), 'A | unverified |', 'A | done |')
      fixture.sync_index(root)
      local ok, found, text = verify()
      assert.is_false(ok)
      assert.same({ 'vocabulary' }, found, text)
    end)

    it('C 级小节里的条款写成 A 级就红', function()
      fixture.patch(root, fixture.shard(1), '| 规则 | 试玩 | C | blocked |', '| 规则 | 试玩 | A | blocked |')
      local ok, found, text = verify()
      assert.is_false(ok)
      assert.same({ 'level_section' }, found, text)
    end)

    it('C 级条款放在没有「## C 级」的正文表里就红', function()
      fixture.patch(root, fixture.shard(2), '| 功能 | agent | A | out-of-scope |',
        '| 功能 | agent | C | out-of-scope |')
      local ok, found, text = verify()
      assert.is_false(ok)
      assert.same({ 'level_section' }, found, text)
    end)

    it('条款 ID 跳号就红', function()
      fixture.patch(root, fixture.shard(19), '| 19-01 |', '| 19-03 |')
      local ok, found, text = verify()
      assert.is_false(ok)
      assert.same({ 'id_sequence' }, found, text)
    end)

    it('条款 ID 的节号与所在分片不一致就红', function()
      fixture.patch(root, fixture.shard(19), '| 19-01 |', '| 07-01 |')
      local ok, found, text = verify()
      assert.is_false(ok)
      assert.same({ 'clause_id' }, found, text)
    end)

    it('分片节号超出规格小节数就红', function()
      fs.write_file(root .. '/' .. fixture.shard(Acceptance.SPEC_SECTIONS + 1), table.concat({
        '# ' .. (Acceptance.SPEC_SECTIONS + 1) .. '. 夹具小节外多出的一节',
        '',
        '| ID | 条款 | 组 | 执行者 | 证据等级 | 状态 | 证据 / 理由 |',
        '| --- | --- | --- | --- | --- | --- | --- |',
        string.format('| %d-01 | 夹具条款：超出规格的那条 | 规则 | agent | A | unverified | — |',
          Acceptance.SPEC_SECTIONS + 1),
        '',
      }, '\n'))
      fixture.sync_index(root)
      local ok, found, text = verify()
      assert.is_false(ok)
      assert.same({ 'shard_unknown' }, found, text)
    end)

    it('README 缺少生成块标记就红', function()
      fixture.patch(root, Acceptance.INDEX, Acceptance.BEGIN_MARK, '')
      local ok, found, text = verify()
      assert.is_false(ok)
      assert.same({ 'index_markers' }, found, text)
    end)

    it('基线字段不是 0 以上整数就红', function()
      fixture.sync_baseline(root, { evidenced = 1.5 })
      local ok, found, text = verify()
      assert.is_false(ok)
      assert.same({ 'baseline_shape' }, found, text)
    end)

    it('多一份同节分片就红', function()
      fs.write_file(root .. '/' .. Acceptance.DIR .. '/07-second.md',
        fs.slurp(root .. '/' .. fixture.shard(7)))
      fixture.sync_index(root)
      local ok, found, text = verify()
      assert.is_false(ok)
      assert.same({ 'shard_duplicate' }, found, text)
    end)

    it('spec 车道的断言不计入遗留测试', function()
      local before = #Acceptance.scan(root).lanes.legacy
      fs.write_file(root .. '/tests/native/spec/two_test.lua', '-- 夹具：多一条条款断言。\n')
      local after = #Acceptance.scan(root).lanes.legacy
      assert.same(before, after, 'spec 新文件不该改变遗留测试数')
    end)
  end)
end)
