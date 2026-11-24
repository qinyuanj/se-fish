-- acceptance 子命令（#243）：验收矩阵的校验、索引生成与基线更新。
-- 判定全在 tools/acceptance.lua（纯扫描 + 纯判定），这里只做落盘与打印。
-- 用法：acceptance / acceptance --check（缺省）| --write | --update-baseline。
-- 退出码：0 通过或已写入 / 1 有违反项（--check 的 findings）/ 2 用法错误或棘轮拒绝下调
--         / 3 仓库内关键文件不可用。--write 只重写 README 的生成块，--update-baseline 只朝单向写。
local acceptance = require('tools.acceptance')
local exit_code = require('tools.exit_code')

local M = {}

local MODES = { ['--check'] = 'check', ['--write'] = 'write', ['--update-baseline'] = 'baseline',
  ['--infer'] = 'infer' }

function M.usage()
  return table.concat({
    '用法: lua tools/cli.lua acceptance [--check|--write|--update-baseline|--infer]',
    '',
    '把 docs/acceptance/ 的条款矩阵当账来核：19 节分片覆盖、条款 ID 连续、禁用措辞、索引生成块',
    '与分片一致、证据文件不引用已删条款，以及已取证只增的棘轮。状态不再手写，从 spec、probes',
    '与 evidence/*/session.md 的正文反推。',
    '',
    '  --check（缺省）  跑全部校验，逐条打印违反项；全绿打印计数摘要。有违反项退 1。',
    '  --write         按分片重写 README 的生成块（幂等）。',
    '  --update-baseline  把基线抬到当前值；只许 evidenced 抬，反方向退 2。',
    '  --infer         列出反推出的「条款 → 证据路径 → 状态」与孤儿条款号；有孤儿号退 1。',
    '',
    '退出码：0 通过 / 1 有违反项 / 2 用法错误或棘轮拒绝 / 3 关键文件不可用。',
  }, '\n') .. '\n'
end

local function parse(args)
  local opts = { mode = 'check' }
  for _, item in ipairs(args or {}) do
    if item == '--help' or item == '-h' then
      opts.help = true
    elseif MODES[item] then
      if opts.chosen and opts.chosen ~= item then
        return nil, '只能指定一个动作: ' .. opts.chosen .. ' 与 ' .. item
      end
      opts.mode, opts.chosen = MODES[item], item
    else
      return nil, '未知参数: ' .. item
    end
  end
  return opts
end

local function summary(result)
  local counts, matrix = result.counts, result.matrix
  local lines = {
    string.format('验收矩阵：%d 份分片 / %d 条条款', #matrix.shards, counts.total),
    string.format('  evidenced %d  blocked %d  unverified %d（状态由证据文件反推）',
      counts.status.evidenced, counts.status.blocked, counts.status.unverified),
    string.format('  已取证 %d / %d；缺口密度 %.0f%%', counts.evidenced, counts.total, counts.gap * 100),
  }
  if matrix.baseline then
    lines[#lines + 1] = string.format('  基线：evidenced %s（updated %s）',
      tostring(matrix.baseline.evidenced), tostring(matrix.baseline.updated))
  end
  return table.concat(lines, '\n')
end

local function print_findings(findings)
  for _, item in ipairs(findings) do
    local where = item.path or ''
    if item.line then where = where .. ':' .. tostring(item.line) end
    io.stdout:write(string.format('[%s] %s  %s\n', item.kind, where, item.message or ''))
  end
end

local function write_file(root, relative, body)
  local handle, err = io.open(root .. '/' .. relative, 'wb')
  if not handle then return nil, err or ('写不了 ' .. relative) end
  handle:write(body)
  handle:close()
  return true
end

-- 内部函数以「nil, 原因」报错时走这里：原因印到 stderr，退出码由调用方定，绝不静默退 1。
-- 关键文件读不出来或写不下去都属于「前提不可用」（退出码 3），不是「矩阵校验不通过」（1）。
local function failed(message, code)
  io.stderr:write('acceptance: ' .. tostring(message) .. '\n')
  return code
end

local function run_check(root)
  local result = acceptance.verify(root)
  if not result.ok then
    print_findings(result.findings)
    io.stdout:write(string.format('\n%d 项违反：验收矩阵未通过\n', #result.findings))
    return exit_code.FAILURE
  end
  io.stdout:write(summary(result) .. '\n\n验收矩阵校验通过\n')
  return exit_code.OK
end

local function run_write(root)
  local matrix = acceptance.scan(root)
  if not matrix.index.body then
    return failed('读不到 ' .. acceptance.INDEX, exit_code.UNAVAILABLE)
  end
  local block = acceptance.render(matrix)
  if matrix.index.block == block then
    io.stdout:write('README 生成块已是最新，无需改动\n')
    return exit_code.OK
  end
  local body, err = acceptance.rewrite(matrix.index.body, block)
  if not body then return failed(err, exit_code.UNAVAILABLE) end
  local written, write_err = write_file(root, acceptance.INDEX, body)
  if not written then return failed(write_err, exit_code.UNAVAILABLE) end
  io.stdout:write(string.format('已重写 %s 的生成块（%d 份分片 / %d 条条款）\n',
    acceptance.INDEX, #matrix.shards, matrix.counts.total))
  return exit_code.OK
end

local function run_baseline(root)
  local matrix = acceptance.scan(root)
  local text, code, reason = acceptance.next_baseline(matrix)
  if not text then
    io.stderr:write('acceptance: ' .. tostring(reason) .. '\n')
    return code == 'refuse' and exit_code.USAGE or exit_code.UNAVAILABLE
  end
  local written, err = write_file(root, acceptance.BASELINE, text)
  if not written then return failed(err, exit_code.UNAVAILABLE) end
  io.stdout:write(string.format('已重写 %s：evidenced %d\n',
    acceptance.BASELINE, matrix.counts.evidenced))
  return exit_code.OK
end

-- 反推报告（#326）：状态是人不再手写的第一列，这里把它连同证据路径一起列出来。
local function run_infer(root)
  local matrix = acceptance.scan(root)
  local inferred = matrix.inference
  local status, total = {}, 0
  for _, shard in ipairs(matrix.shards) do
    for _, clause in ipairs(shard.clauses) do
      total = total + 1
      local value = inferred.status[clause.id] or 'unverified'
      status[value] = (status[value] or 0) + 1
    end
  end
  io.stdout:write(string.format('反推：%d 条条款；evidenced %d  blocked %d  unverified %d\n',
    total, status.evidenced or 0, status.blocked or 0, status.unverified or 0))
  for _, item in ipairs(inferred.exceptions) do
    io.stdout:write(string.format('  例外 %s（命中 %d 个文件）：%s\n', item.id, item.hits, item.reason))
  end
  for _, item in ipairs(inferred.orphans) do
    io.stdout:write(string.format('[orphan_clause] %s  证据文件里出现矩阵没有的条款号 %s\n',
      item.path, item.id))
  end
  if #inferred.orphans > 0 then
    io.stdout:write(string.format('\n%d 处孤儿条款号：证据文件引用了矩阵里没有的条款\n', #inferred.orphans))
    return exit_code.FAILURE
  end
  io.stdout:write('反推完成，没有孤儿条款号\n')
  return exit_code.OK
end

function M.main(args, env)
  local opts, err = parse(args)
  if not opts then
    io.stderr:write('acceptance: ' .. err .. '\n\n' .. M.usage())
    return exit_code.USAGE
  end
  if opts.help then
    io.stdout:write(M.usage())
    return exit_code.OK
  end
  local root = (env and env.repo_root) or '.'
  local runner = ({ check = run_check, write = run_write, baseline = run_baseline, infer = run_infer })[opts.mode]
  local ok, code = pcall(runner, root)
  if not ok then
    io.stderr:write('acceptance: ' .. tostring(code) .. '\n')
    return exit_code.FAILURE
  end
  -- 动作函数一律返回退出码；返回 nil 是漏了 return，当成前提不可用报出来，别静默变成 1。
  if type(code) ~= 'number' then
    return failed('内部错误：' .. opts.mode .. ' 没有返回退出码', exit_code.UNAVAILABLE)
  end
  return code
end

return M
