-- #326 验收矩阵门禁（fast 车道）：分片结构与 ID、禁用措辞、索引一致、证据文件覆盖条款号、已取证只增。
-- 真实仓库扫描只做一次，再叠一组夹具用例：夹具在临时目录里拼一份最小可用的假仓库，
-- 每次只改坏一处，断言门禁**只**因为那一处判红（kinds 精确比对，避免一处坏了别处顶着）。
-- 失败方式（先列后写）：
--   1. 真实矩阵不绿（分片缺、ID 不连续、索引与分片不一致、棘轮被反向推动、证据文件引用孤儿号）；
--   2. 改坏一处却不红（门禁睡着了），或红的地方不对（判错的规则）；
--   3. 反推把不该算取证的条款算成 evidenced（正文提到不等于断言了这条）。
local Acceptance = require('tools.acceptance')
local fs = require('tests.support.fs_fixture')
local fixture = require('tests.support.acceptance_fixture')

-- 真实仓库只扫一次：Arch.scan 那样的惯例，用例共享同一份结果。
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
    assert.same(Acceptance.SPEC_SECTIONS, #matrix.shards)
    for number = 1, Acceptance.SPEC_SECTIONS do
      local list = matrix.by_section[number]
      assert.is_not_nil(list, '第 ' .. number .. ' 节没有分片')
      assert.same(1, #list, '第 ' .. number .. ' 节有多份分片')
      assert.same(number, list[1].section)
    end
    assert.is_true(matrix.counts.total > 0, '条款总数为 0：分片解析没生效')
  end)

  it('状态由证据文件反推，且已取证数不低于基线', function()
    local matrix = real_matrix()
    assert.is_not_nil(matrix.baseline, matrix.baseline_error)
    local inferred, total = 0, 0
    for _, shard in ipairs(matrix.shards) do
      for _, clause in ipairs(shard.clauses) do
        total = total + 1
        if matrix.inference.status[clause.id] == 'evidenced' then inferred = inferred + 1 end
      end
    end
    assert.same(total, matrix.counts.total)
    assert.same(inferred, matrix.counts.evidenced)
    assert.is_true(matrix.counts.evidenced >= matrix.baseline.evidenced)
  end)

  it('反推例外仍然命中证据文件，例外不会悄悄失效', function()
    local matrix = real_matrix()
    for _, item in ipairs(matrix.inference.exceptions) do
      assert.is_true(item.hits > 0, string.format('例外 %s 已经没有任何证据文件命中，删掉这条例外', item.id))
    end
  end)

  it('证据文件里没有指向已删条款的孤儿号', function()
    local matrix = real_matrix()
    local found = {}
    for _, item in ipairs(matrix.inference.orphans) do
      found[#found + 1] = string.format('%s 里的 %s', item.path, item.id)
    end
    assert.same({}, found, '孤儿条款号：' .. table.concat(found, '；'))
  end)

  it('条款号的前后边界不认日期、版本与工单引用', function()
    assert.is_false(Acceptance.clause_mentioned('-- 2026-11-04 实测', '11-04'))
    assert.is_true(Acceptance.clause_mentioned('-- 条款 11-04：倒计时', '11-04'))
    assert.same({ '11-04' }, Acceptance.clause_ids('-- 2026-11-04 实测 11-04'))
    assert.same({}, Acceptance.clause_ids('review #249-10'))
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

    it('反推：3-02 由 spec 正文取证，C 级 1-03 没有会话记录所以 blocked', function()
      local matrix = Acceptance.scan(root)
      assert.same('evidenced', matrix.inference.status['3-02'])
      assert.same({ fixture.EVIDENCE }, matrix.inference.paths['3-02'])
      assert.same('blocked', matrix.inference.status['1-03'])
    end)

    it('C 级条款只有会话 ✅ 行才算取证', function()
      local dir = root .. '/evidence/2026-11-20-demo'
      fs.mkdirp(dir)
      fs.write_file(dir .. '/session.md', table.concat({
        '| 条款 | 结果 | 依据 |',
        '| --- | --- | --- |',
        '| 1-03 | ⏸ | 本场未覆盖 |',
      }, '\n'))
      assert.same('blocked', Acceptance.scan(root).inference.status['1-03'])
      fs.write_file(dir .. '/session.md', '| 1-03 | ✅ | 打开面板可读 |\n')
      local matrix = Acceptance.scan(root)
      assert.same('evidenced', matrix.inference.status['1-03'])
      assert.same({ 'evidence/2026-11-20-demo/session.md' }, matrix.inference.paths['1-03'])
    end)

    it('条款行不是恰好两格就红', function()
      fixture.patch(root, fixture.shard(3), '| 3-02 | 夹具条款：第 3 节第 2 条（A） |',
        '| 3-02 | 夹具条款：第 3 节第 2 条（A） | 多余 |')
      local ok, found, text = verify()
      assert.is_false(ok)
      assert.same({ 'clause_cells' }, found, text)
    end)

    it('条款没有证据等级后缀就红', function()
      fixture.patch(root, fixture.shard(4), '第 4 节第 1 条（A）', '第 4 节第 1 条')
      local ok, found, text = verify()
      assert.is_false(ok)
      assert.same({ 'clause_level' }, found, text)
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

    it('条款写成不可判的措辞就红', function()
      fixture.patch(root, fixture.shard(5), '第 5 节第 1 条（A）', '第 5 节第 1 条，结果正常。（A）')
      local ok, found, text = verify()
      assert.is_false(ok)
      assert.same({ 'vague_wording' }, found, text)
    end)

    it('证据文件引用矩阵没有的条款号就红', function()
      fs.write_file(root .. '/tests/native/spec/stale_test.lua', '-- 旧条款 99-01 的断言。\n')
      local ok, found, text = verify()
      assert.is_false(ok)
      assert.same({ 'orphan_clause' }, found, text)
    end)

    it('已取证计数低于基线就红', function()
      fixture.sync_baseline(root, { evidenced = 2 })
      local ok, found, text = verify()
      assert.is_false(ok)
      assert.same({ 'ratchet_evidenced' }, found, text)
    end)

    it('基线字段不是 0 以上整数就红', function()
      fixture.sync_baseline(root, { evidenced = 1.5 })
      local ok, found, text = verify()
      assert.is_false(ok)
      assert.same({ 'baseline_shape' }, found, text)
    end)

    it('手改 README 生成块里的一个数字就红', function()
      -- 改合计行的数字：条款数一变，手改的串也不跟着变，用例才稳。
      fixture.patch(root, Acceptance.INDEX, '| 合计 | — |', '| 合计 | — | 9')
      local ok, found, text = verify()
      assert.is_false(ok)
      assert.same({ 'index_stale' }, found, text)
    end)

    it('新增条款后不重跑 --write 就红，重跑后恢复且幂等', function()
      fixture.patch(root, fixture.shard(4), '| 4-01 | 夹具条款：第 4 节第 1 条（A） |',
        '| 4-01 | 夹具条款：第 4 节第 1 条（A） |\n| 4-02 | 夹具条款：新加的一条（A） |')
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

    it('README 缺少生成块标记就红', function()
      fixture.patch(root, Acceptance.INDEX, Acceptance.BEGIN_MARK, '')
      local ok, found, text = verify()
      assert.is_false(ok)
      assert.same({ 'index_markers' }, found, text)
    end)

    it('少一份分片就红', function()
      os.remove(root .. '/' .. fixture.shard(19))
      fixture.sync_index(root)
      local ok, found, text = verify()
      assert.is_false(ok)
      assert.same({ 'shard_missing' }, found, text)
    end)

    it('多一份同节分片就红', function()
      fs.write_file(root .. '/' .. Acceptance.DIR .. '/07-second.md',
        fs.slurp(root .. '/' .. fixture.shard(7)))
      fixture.sync_index(root)
      local ok, found, text = verify()
      assert.is_false(ok)
      assert.same({ 'shard_duplicate' }, found, text)
    end)

    it('分片节号超出规格小节数就红', function()
      fs.write_file(root .. '/' .. fixture.shard(Acceptance.SPEC_SECTIONS + 1), table.concat({
        '# ' .. (Acceptance.SPEC_SECTIONS + 1) .. '. 夹具小节外多出的一节',
        '',
        '| ID | 条款 |',
        '| --- | --- |',
        string.format('| %d-01 | 夹具条款：超出规格的那条（A） |', Acceptance.SPEC_SECTIONS + 1),
        '',
      }, '\n'))
      fixture.sync_index(root)
      local ok, found, text = verify()
      assert.is_false(ok)
      assert.same({ 'shard_unknown' }, found, text)
    end)
  end)
end)
