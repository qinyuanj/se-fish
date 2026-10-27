-- 架构分层与源码图共用一份声明；扫描与判定均可脱离引擎运行。
local Arch = require('tools.arch_policy')

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

local function kinds(result)
  local out = {}
  for _, item in ipairs(result.violations) do out[#out + 1] = item.kind end
  table.sort(out)
  return out
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
    assert.same({ 'app.rules.a', 'app.rules.b', 'app.rules.c' }, Arch.requires([=[
      require
      -- 参数前允许注释
      ('app.rules.a')
      require [[app.rules.b]]
      require([==[app.rules.c]==])
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
      local A = require('common.Util')
      local B = require("server.Mgr.MgrPlayer")
      -- require('client.NotReal')
      local text = "require('server.NotReal')"
      obj.require('client.NotReal')
    ]])
    assert.same({ 'common.Util', 'server.Mgr.MgrPlayer' }, names)

    local graph = assert(Arch.scan('.', Arch.policy))
    assert.is_true(#graph.modules > 100)
    for _, id in ipairs(graph.modules) do
      assert.is_nil(id:match('^server%._trigger'))
    end
  end)

  it('真实业务模块全部分类且无反向依赖或循环', function()
    local graph = assert(Arch.scan('.', Arch.policy))
    local result = Arch.check(Arch.policy, graph)
    assert.is_true(result.ok, result.message)
  end)

  it('源码图 levels 与门禁声明一致且 packages 最底', function()
    local handle = assert(io.open('policy.edn', 'rb'))
    local text = handle:read('*a')
    handle:close()
    local expected = Arch.levels_edn(Arch.policy)
    assert.is_true(text:find(expected, 1, true) ~= nil, expected)
    assert.equals(':levels [[:client.packages :server.packages :common.packages]', expected:sub(1, 61))
  end)
end)
