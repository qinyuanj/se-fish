-- 迁移自 tests/gameplay/reel_client_test.lua（#85）。
-- 被测接缝：client.LocalReelIn（客户端收线本地状态机 + 批次上报）。
-- it 名字沿用旧方法名，注册顺序 = LuaUnit sortedPairs 的实际执行顺序。
-- setUp/tearDown 逐例化为 before_each/after_each：旧 runner 每个方法都跑一次夹具。
-- #231：RE / World / Heartbeat 换成 tests/support/reel_env 的适配器——断开真实生效，
-- 存活订阅数与合批心跳连接数对用例可读（#234 / #232 的验收点依赖这两点）。
-- #234：启停与入站订阅由 LocalReelIn 持有的 Auto 树负责，断言一律走夹具的存活计数与
-- 公共接口，不断言 Connection / UpdateConnection 这类内部字段。

local Reel = require('tests.support.reel_env')
-- 故障会经 SpokeError.log 打整段 trace；用例内静音，用例后还原，避免污染车道输出。
local SpokeError = require('common.packages.spoke.runtime.spoke_error')

describe('客户端收线状态机（LocalReelIn）', function()
  -- ctx 承载旧 self 的字段；after_each 对未完成的 before_each 幂等。
  local ctx
  local restore
  local defaultLog

  before_each(function()
    defaultLog = SpokeError.log
    -- 先抓快照再动任何全局：夹具中途失败时 after_each 才有得还原。
    restore = { client = package.loaded['client.LocalReelIn'] }
    ctx = Reel.new('client')
    ctx:setUp()
    package.loaded['client.LocalReelIn'] = nil
    ctx.client = require('client.LocalReelIn')
    ctx.client:Start()
    ctx.now = 0
  end)

  after_each(function()
    -- 每例结束时销毁本用例的树：泄漏的 Auto 树会在同文件后续用例里继续跑。
    if ctx and ctx.client then ctx.client:Stop() end
    SpokeError.log = defaultLog
    package.loaded['client.LocalReelIn'] = restore and restore.client or nil
    if ctx then ctx:tearDown() end
    ctx = nil
    restore = nil
    defaultLog = nil
  end)

  it('test_ended_session_ignores_late_started_echo', function()
    -- 会话真结束后，迟到的 started 回声不能再把界面拉回收线中
    ctx.client:SetSession('s1')
    ctx.client:Clear('s1')
    ctx.events.ReelInRE.OnClientEvent:Fire({ action = 'started', session = 's1', progress = 50 })
    assert.is_nil(ctx.client.SessionId)
  end)

  it('test_heartbeat_collects_after_hundred_ms', function()
    ctx.client:SetSession('s1')
    ctx.client:Click()
    ctx.now = 0.09
    ctx.heartbeat:Fire()
    assert.same(0, #ctx.sent)
    ctx.now = 0.11
    ctx.heartbeat:Fire()
    assert.same({ name = 'ReelInRE', payload = { s = 's1', n = 1, q = 1 } }, ctx.sent[1])
  end)

  it('test_hook_while_screen_is_hidden_is_kept_and_usable_after_reopen', function()
    ctx.client:Suspend()
    ctx.events.ReelInRE.OnClientEvent:Fire({ action = 'started', session = 's1', progress = 50 })
    assert.same(0, #ctx.sent)
    assert.same('s1', ctx.client.SessionId)
    ctx.client:Click()
    ctx.now = 0.1
    ctx.heartbeat:Fire()
    assert.same({ name = 'ReelInRE', payload = { s = 's1', n = 1, q = 1 } }, ctx.sent[#ctx.sent])
  end)

  it('test_restart_does_not_stack_listeners_or_leave_pending_clicks', function()
    local subscriptions = ctx:subscriptionCount('ReelInRE')
    local beats = ctx:heartbeatCount()
    ctx.client:Start()
    -- 重复 Start 不叠监听：存活订阅数与心跳连接数都不变
    assert.same(subscriptions, ctx:subscriptionCount('ReelInRE'))
    assert.same(beats, ctx:heartbeatCount())
    -- #232：合批心跳归会话 Phase 所有，还没有会话时一条都不该有
    assert.same(0, ctx:heartbeatCount())
    ctx.client:SetSession('s1')
    -- 设置会话返回时心跳已同步挂上
    assert.same(1, ctx:heartbeatCount())
    ctx.client:Click()
    ctx.client:Stop()
    assert.is_nil(ctx.client.SessionId)
    assert.same({ name = 'CloseReelIn', payload = { session = 's1' } }, ctx.sent[#ctx.sent])
    -- Stop 的断开真实生效：旧 RE / 心跳回调不再送达，存活连接归零
    assert.same(0, ctx:subscriptionCount('ReelInRE'))
    assert.same(0, ctx:heartbeatCount())
    local sent = #ctx.sent
    ctx.heartbeat:Fire()
    ctx.events.ReelInRE.OnClientEvent:Fire({ action = 'started', session = 'late', progress = 50 })
    assert.same(sent, #ctx.sent)
    assert.is_nil(ctx.client.SessionId)
    -- 重启得到一条全新的订阅；心跳则要等会话重新出现（#232）
    ctx.client:Start()
    assert.same(1, ctx:subscriptionCount('ReelInRE'))
    assert.same(0, ctx:heartbeatCount())
  end)

  it('test_stop_then_start_rebuilds_the_session_from_clean_input', function()
    -- 旧树与旧订阅不复活：Stop 之后 Start 得到一棵新树、一条新订阅
    local firstTree = ctx.client.Tree
    assert.is_not_nil(firstTree)
    ctx.client:SetSession('s1')
    ctx.client:Click()
    ctx.client:Stop()
    assert.is_nil(ctx.client.Tree)
    assert.same(0, ctx:subscriptionCount('ReelInRE'))
    local sent = #ctx.sent
    ctx.client:Start()
    assert.are_not.equal(firstTree, ctx.client.Tree)
    assert.same(1, ctx:subscriptionCount('ReelInRE'))
    -- 新订阅可用：重启后第一条入站事件照常建立会话
    ctx.events.ReelInRE.OnClientEvent:Fire({ action = 'started', session = 's2', progress = 50 })
    assert.same('s2', ctx.client.SessionId)
    -- 首个批次从干净输入状态开始：旧会话的 pending 不会跟着回来
    ctx.client:Click()
    ctx.now = 0.11
    ctx.heartbeat:Fire()
    assert.same({ name = 'ReelInRE', payload = { s = 's2', n = 1, q = 1 } }, ctx.sent[sent + 1])
    assert.same(sent + 1, #ctx.sent)
  end)

  it('test_inbound_error_surfaces_as_tree_fault', function()
    -- 无宿主侧 pcall：处理块里的执行期错误沿 spoke 的树级故障呈现，不甩回事件回调。
    -- 注入手法：只让 SetSession 对这条载荷抛错，错误位置就在树的 Effect 块里；
    -- 树已 fault 也不能毒到后续用例——用例结束由 after_each 的 Stop 销毁这棵树。
    local tree = ctx.client.Tree
    assert.is_not_nil(tree)
    assert.is_nil(tree.fault)
    local setSession = ctx.client.SetSession
    ctx.client.SetSession = function(self, id)
      if id == 'boom' then error('boom-in-block', 0) end
      return setSession(self, id)
    end
    SpokeError.log = function() end
    ctx.events.ReelInRE.OnClientEvent:Fire({ action = 'started', session = 'boom', progress = 50 })
    assert.is_not_nil(tree.fault)
    -- 区分执行期错误（Tick）与启动期错误（Init）
    assert.are.equal('Tick', tree.fault.phase)
    assert.are.equal('boom-in-block', tree.fault.cause)
    -- 故障没有再往宿主甩：没有上行，也没有把会话建起来
    assert.same(0, #ctx.sent)
    assert.is_nil(ctx.client.SessionId)
  end)

  it('test_snapshot_does_not_reset_pending_and_close_flushes_first', function()
    local client = ctx.client
    client:SetSession('s1')
    client:Click()
    client:SetSession('s1')
    client:Close()
    assert.same({
      { name = 'ReelInRE', payload = { s = 's1', n = 1, q = 1 } },
      { name = 'CloseReelIn', payload = { session = 's1' } },
    }, ctx.sent)
    client:Close()
    assert.same(2, #ctx.sent)
  end)

  it('test_suspend_flushes_pending_and_keeps_the_session', function()
    -- #133：界面被遮挡只影响表现——不主动收线、不重置计时，待发批次先送出去
    ctx.client:SetSession('s1')
    ctx.client:Click()
    ctx.client:Suspend()
    assert.same({ { name = 'ReelInRE', payload = { s = 's1', n = 1, q = 1 } } }, ctx.sent)
    assert.same('s1', ctx.client.SessionId)
    assert.is_not_nil(ctx.client.Display)
    -- #232：Suspend 只 flush，会话与合批心跳都还在，之后的点击仍能按窗口上行
    assert.same(1, ctx:heartbeatCount())
    ctx.client:Click()
    ctx.now = 0.11
    ctx.heartbeat:Fire()
    assert.same({ name = 'ReelInRE', payload = { s = 's1', n = 1, q = 2 } }, ctx.sent[#ctx.sent])
  end)

  it('test_no_batching_heartbeat_until_a_live_session_exists', function()
    -- #232：合批心跳由会话 Phase 拥有——没有有效会话时不存在这条逐帧回调，空闲不承担逐帧开销
    assert.same(0, ctx:heartbeatCount())
    ctx.now = 0.5
    ctx.client:Click()
    ctx.heartbeat:Fire()
    assert.same(0, #ctx.sent)
    -- started 返回时心跳已同步挂上：紧随其后的一次点击在同一帧内就能被收拢，到窗口照常上行
    ctx.events.ReelInRE.OnClientEvent:Fire({ action = 'started', session = 's1', progress = 50, q = 0 })
    assert.same(1, ctx:heartbeatCount())
    ctx.client:Click()
    ctx.now = 0.61
    ctx.heartbeat:Fire()
    assert.same({ name = 'ReelInRE', payload = { s = 's1', n = 1, q = 1 } }, ctx.sent[1])
    assert.same(1, #ctx.sent)
  end)

  it('test_replacing_the_session_remounts_a_single_heartbeat_from_clean_input', function()
    ctx.client:SetSession('s1')
    assert.same(1, ctx:heartbeatCount())
    ctx.client:Click()                       -- s1 的待发点击
    ctx.client:SetSession('s2')
    -- 先清旧再挂新：同一时刻最多一条，不是两条叠加
    assert.same(1, ctx:heartbeatCount())
    ctx.now = 0.2
    ctx.heartbeat:Fire()
    assert.same(0, #ctx.sent)                -- 待发点击不继承给新会话
    ctx.client:Click()
    ctx.now = 0.31
    ctx.heartbeat:Fire()
    assert.same({ name = 'ReelInRE', payload = { s = 's2', n = 1, q = 1 } }, ctx.sent[1])
    assert.same(1, #ctx.sent)
  end)

  it('test_every_ending_path_takes_the_batching_heartbeat_with_it', function()
    local function hook(id)
      ctx.events.ReelInRE.OnClientEvent:Fire({ action = 'started', session = id, progress = 50, q = 0 })
      assert.same(1, ctx:heartbeatCount())
      ctx.client:Click()
    end
    -- 上岸
    hook('a')
    ctx.events.ReelInRE.OnClientEvent:Fire({ action = 'landed', session = 'a', progress = 100, q = 1 })
    assert.same(0, ctx:heartbeatCount())
    -- 脱钩
    hook('b')
    ctx.events.ReelInRE.OnClientEvent:Fire({ action = 'unhooked', session = 'b', progress = 0, q = 0 })
    assert.same(0, ctx:heartbeatCount())
    -- 清理
    hook('c')
    ctx.client:Clear('c')
    assert.same(0, ctx:heartbeatCount())
    -- 关闭
    hook('d')
    ctx.client:Close()
    assert.same(0, ctx:heartbeatCount())
    -- 四条路径之后都不再有任何上行
    local sent = #ctx.sent
    ctx.now = 5
    ctx.client:Click()
    ctx.heartbeat:Fire()
    assert.same(sent, #ctx.sent)
    assert.is_nil(ctx.client.SessionId)
  end)

  it('test_close_without_pending_sends_no_empty_batch', function()
    ctx.client:SetSession('s1')
    ctx.client:Close()
    -- 无待发点击时不伪造空批次，仍然只发关闭请求
    assert.same({ { name = 'CloseReelIn', payload = { session = 's1' } } }, ctx.sent)
  end)
end)
