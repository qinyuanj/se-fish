-- 迁移自 tests/gameplay/reel_client_test.lua（#85）。
-- 被测接缝：client.LocalReelIn（客户端收线本地状态机 + 批次上报）。
-- it 名字沿用旧方法名，注册顺序 = LuaUnit sortedPairs 的实际执行顺序。
-- setUp/tearDown 逐例化为 before_each/after_each：旧 runner 每个方法都跑一次夹具。
-- #231：RE / World / Heartbeat 换成 tests/support/reel_env 的适配器——断开真实生效，
-- 存活订阅数与合批心跳连接数对用例可读（#234 / #232 的验收点依赖这两点）。

local Reel = require('tests.support.reel_env')

describe('客户端收线状态机（LocalReelIn）', function()
  -- ctx 承载旧 self 的字段；after_each 对未完成的 before_each 幂等。
  local ctx
  local restore

  before_each(function()
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
    package.loaded['client.LocalReelIn'] = restore and restore.client or nil
    if ctx then ctx:tearDown() end
    ctx = nil
    restore = nil
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
    local first = ctx.client.Connection
    local update = ctx.client.UpdateConnection
    local subscriptions = ctx:subscriptionCount('ReelInRE')
    local beats = ctx:heartbeatCount()
    ctx.client:Start()
    assert.are.equal(first, ctx.client.Connection)
    assert.are.equal(update, ctx.client.UpdateConnection)
    -- 重复 Start 不叠监听：存活订阅数与心跳连接数都不变
    assert.same(subscriptions, ctx:subscriptionCount('ReelInRE'))
    assert.same(beats, ctx:heartbeatCount())
    ctx.client:SetSession('s1')
    ctx.client:Click()
    ctx.client:Stop()
    assert.is_nil(ctx.client.SessionId)
    assert.is_nil(ctx.client.Connection)
    assert.same({ name = 'CloseReelIn', payload = { session = 's1' } }, ctx.sent[#ctx.sent])
    -- Stop 的断开真实生效：旧 RE / 心跳回调不再送达，存活连接归零
    assert.same(0, ctx:subscriptionCount('ReelInRE'))
    assert.same(0, ctx:heartbeatCount())
    local sent = #ctx.sent
    ctx.heartbeat:Fire()
    ctx.events.ReelInRE.OnClientEvent:Fire({ action = 'started', session = 'late', progress = 50 })
    assert.same(sent, #ctx.sent)
    assert.is_nil(ctx.client.SessionId)
    ctx.client:Start()
    assert.are_not.equal(first, ctx.client.Connection)
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
  end)
end)
