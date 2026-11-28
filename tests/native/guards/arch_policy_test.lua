-- 架构分层与源码图共用一份声明；扫描与判定均可脱离引擎运行。
local Arch = require('tools.arch_policy')
local fs = require('tests.support.fs_fixture')

local function fixture_policy()
  return {
    levels = {
      { ids = { 'app.packages' } },
      { ids = { 'app.rules' } },
      { ids = { 'app.entry' } },
    },
    forbidden = {
      { name = 'no_entry_in_shared', from = { '^app%.rules' }, to = { '^app%.entry' } },
    },
  }
end

-- 真实仓库扫描只做一次：Arch.scan 只读仓库、每次返回新表，三个用例共享同一张图。
local scanned
local function scan_real()
  if not scanned then scanned = assert(Arch.scan('.', Arch.policy)) end
  return scanned
end

local function kinds(result)
  local out = {}
  for _, item in ipairs(result.violations) do out[#out + 1] = item.kind end
  table.sort(out)
  return out
end

local function is_business(id)
  return (id:match('^client%.') or id:match('^common%.') or id:match('^server%.'))
    and not id:match('^server%._trigger%.')
end

local function declared_levels()
  local handle = assert(io.open('policy.edn', 'rb'))
  local text = handle:read('*a')
  handle:close()
  local groups = {}
  for group in assert(text:match(':levels%s+%[(.*)%]}')):gmatch('%[([^%]]*)%]') do
    local ids = {}
    for id in group:gmatch(':([%w_%.%-]+)') do ids[#ids + 1] = id end
    groups[#groups + 1] = ids
  end
  return groups
end

local function level_of(groups, id)
  for rank, ids in ipairs(groups) do
    for _, prefix in ipairs(ids) do
      if id == prefix or id:sub(1, #prefix + 1) == prefix .. '.' then return rank - 1 end
    end
  end
end

describe('架构分层门禁', function()
  it('解码静态字符串转义并排除带空白的成员调用', function()
    assert.same({ 'app.rules.a', 'app.rules.b', 'app.rules.c', 'app.rules.d' }, Arch.requires([=[
      require('app.\x72ules.a')
      require("app.\114ules.b")
      local s = '' .. require('app.rules.c')
      local t = ''..require('app.rules.d')
      obj. require('app.entry.fake')
      obj :
        require('app.entry.fake2')
    ]=]))
  end)

  it('识别换行注释与长字符串参数，忽略字符串内的伪调用', function()
    assert.same({ 'app.rules.a', 'app.rules.b', 'app.rules.c', 'app.rules.d' }, Arch.requires([=[
      require
      -- 参数前允许注释
      ('app.rules.a')
      require [[app.rules.b]]
      require([==[app.rules.c]==])
      local ok, module = pcall(require, 'app.rules.d')
      other(require, 'app.entry.fake')
      local text = [[require('app.entry.fake')]]
    ]=]))
  end)

  it('拒绝模块直接加载自身', function()
    local result = Arch.check(fixture_policy(), {
      modules = { 'app.rules.a' },
      edges = { { from = 'app.rules.a', to = 'app.rules.a' } },
    })
    assert.is_false(result.ok)
    assert.same({ 'dependency_cycle' }, kinds(result))
  end)

  it('允许高层依赖低层并拒绝反向依赖和未分类模块', function()
    local policy = fixture_policy()
    local accepted = Arch.check(policy, {
      modules = { 'app.entry', 'app.rules.fish', 'app.rules.calc', 'app.packages.api' },
      edges = {
        { from = 'app.entry', to = 'app.rules.fish' },
        { from = 'app.rules.fish', to = 'app.packages.api' },
        { from = 'app.rules.calc', to = 'app.packages.api' },
      },
    })
    assert.is_true(accepted.ok, accepted.message)

    local rejected = Arch.check(policy, {
      modules = { 'app.rules.fish', 'app.entry', 'app.unknown' },
      edges = { { from = 'app.rules.fish', to = 'app.entry' } },
    })
    assert.is_false(rejected.ok)
    assert.same({ 'forbidden_dependency', 'layer_violation', 'unclassified_module' }, kinds(rejected))
  end)

  it('拒绝同层循环依赖和显式跨端禁向', function()
    local cyclic = Arch.check(fixture_policy(), {
      modules = { 'app.rules.a', 'app.rules.b' },
      edges = {
        { from = 'app.rules.a', to = 'app.rules.b' },
        { from = 'app.rules.b', to = 'app.rules.a' },
      },
    })
    assert.is_false(cyclic.ok)
    assert.same({ 'dependency_cycle' }, kinds(cyclic))

    local policy = fixture_policy()
    policy.forbidden = {
      { name = 'common_not_client', from = { '^app%.rules' }, to = { '^app%.entry' } },
    }
    local result = Arch.check(policy, {
      modules = { 'app.rules.a', 'app.entry' },
      edges = { { from = 'app.rules.a', to = 'app.entry' } },
    })
    assert.is_false(result.ok)
    assert.same({ 'forbidden_dependency', 'layer_violation' }, kinds(result))
  end)

  it('发现模块无环但命名空间投影成环的反向协作', function()
    local result = Arch.check(fixture_policy(), {
      modules = { 'app.rules.a.one', 'app.rules.a.two', 'app.rules.b.one', 'app.rules.b.two' },
      edges = {
        { from = 'app.rules.a.one', to = 'app.rules.b.one' },
        { from = 'app.rules.b.two', to = 'app.rules.a.two' },
      },
    })
    assert.is_false(result.ok)
    assert.same({ 'dependency_cycle' }, kinds(result))
  end)

  it('扫描真实 require，忽略注释字符串和 _trigger', function()
    local names = Arch.requires([[
      local A = require('common.util')
      local B = require("server.ability_api")
      -- require('client.NotReal')
      local text = "require('server.NotReal')"
      obj.require('client.NotReal')
    ]])
    assert.same({ 'common.util', 'server.ability_api' }, names)

    local graph = scan_real()
    assert.is_true(#graph.modules > 100)
    for _, id in ipairs(graph.modules) do
      assert.is_nil(id:match('^server%._trigger'))
    end
  end)

  it('真实业务模块全部分类且无反向依赖或循环', function()
    local graph = scan_real()
    local result = Arch.check(Arch.policy, graph)
    assert.is_true(result.ok, result.message)
  end)

  it('列出源码中已不存在的分层声明', function()
    local policy = fixture_policy()
    policy.levels[2].modules = { 'app.gone', 'app.kept' }
    assert.same({ 'app.entry', 'app.gone' }, Arch.stale(policy, {
      modules = { 'app.packages', 'app.rules.fish', 'app.kept' },
    }))
  end)

  it('真实分层声明的模块与命名空间都在源码中', function()
    assert.same({}, Arch.stale(Arch.policy, scan_real()))
  end)

  it('三端与 tools 不得 require 测试代码', function()
    local result = Arch.check(Arch.policy, {
      modules = { 'common.util' },
      edges = {
        { from = 'common.util', to = 'tests.support.baseline' },
        { from = 'tools.gen_config_anchor_probe', to = 'tests.support.zone_fixtures' },
        { from = 'tests.support.baseline', to = 'tests.support.zone_fixtures' },
      },
    })
    assert.is_false(result.ok)
    local found = {}
    for _, item in ipairs(result.violations) do found[#found + 1] = item.rule .. ': ' .. item.from end
    assert.same({ 'no_test_imports: common.util', 'no_test_imports: tools.gen_config_anchor_probe' }, found)
  end)

  describe('扫描 tools 对测试代码的依赖', function()
    local root = fs.repo_root() .. '/tmp/arch-policy-test'
    after_each(function() fs.rmrf(root) end)

    it('tools 只贡献依赖边，不进分层名单', function()
      fs.rmrf(root)
      fs.mkdirp(root .. '/client')
      fs.mkdirp(root .. '/server')
      fs.write_file(root .. '/common/util.lua', 'return {}\n')
      fs.write_file(root .. '/tools/probes/gen.lua',
        "local Fixtures = require('tests.support.zone_fixtures')\nlocal Util = require('common.util')\n")
      local result = Arch.check(Arch.policy, assert(Arch.scan(root, Arch.policy)))
      assert.is_false(result.ok)
      assert.equals('forbidden_dependency: tools.probes.gen -> tests.support.zone_fixtures', result.message)
    end)
  end)

  it('源码图 levels 与门禁声明一致且 packages 最底', function()
    local handle = assert(io.open('policy.edn', 'rb'))
    local text = handle:read('*a')
    handle:close()
    local expected = Arch.levels_edn(Arch.policy)
    assert.is_true(text:find(expected, 1, true) ~= nil, expected)
    assert.equals(':levels [[:client.packages :server.packages :common.packages]', expected:sub(1, 61))
  end)

  it('docs/uml/se-fish.edn 的模块、层级与依赖边与声明保持同步', function()
    local handle = assert(io.open('docs/uml/se-fish.edn', 'rb'))
    local text = handle:read('*a')
    handle:close()

    local uml_ids = {}
    for id in text:gmatch(':id%s+:([%w_%.%-]+)') do
      uml_ids[id] = true
    end

    local source_modules = {}
    local missing = {}
    for _, id in ipairs(scan_real().modules) do
      if is_business(id) then
        source_modules[id] = true
        if not uml_ids[id] then
          missing[#missing + 1] = id
        end
      end
    end
    table.sort(missing)
    assert.same({}, missing)

    local extra = {}
    for id in pairs(uml_ids) do
      if is_business(id) and not source_modules[id] then
        extra[#extra + 1] = id
      end
    end
    table.sort(extra)
    assert.same({}, extra)

    local levels = declared_levels()
    local drifted = {}
    for id, level in text:gmatch(':id%s+:([%w_%.%-]+)[^}]-:level%s+(%d+)') do
      local expected = level_of(levels, id)
      if expected ~= tonumber(level) then
        drifted[#drifted + 1] = id .. ': EDN ' .. level .. ' / policy.edn ' .. tostring(expected)
      end
    end
    table.sort(drifted)
    assert.same({}, drifted)

    local source_edges, uml_edges = {}, {}
    for _, edge in ipairs(scan_real().edges) do
      if is_business(edge.from) and is_business(edge.to) then
        source_edges[#source_edges + 1] = edge.from .. ' -> ' .. edge.to
      end
    end
    for from, kind, to in text:gmatch('{:from%s+:([%w_%.%-]+)%s+:kind%s+:(%a+)%s+:to%s+:([%w_%.%-]+)}') do
      if (kind == 'dependency' or kind == 'inheritance') and is_business(from) and is_business(to) then
        uml_edges[#uml_edges + 1] = from .. ' -> ' .. to
      end
    end
    table.sort(source_edges)
    table.sort(uml_edges)
    assert.same(source_edges, uml_edges)
  end)
end)
