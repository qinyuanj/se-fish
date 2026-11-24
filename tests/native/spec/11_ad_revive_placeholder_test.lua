-- 条款 11 广告满血复活（占位广告位与濒死路径）：docs/acceptance/11-downed-death-revive.md
-- 方法（PlatformRevive / FullRevive / Update 的暂停分支）；客户端入口走 ScreenSurvival 的 SurvivalState
-- 广播渲染（EUI 替身）。复活动作只有 FullRevive 一个落点，广告不另造复活路径。
-- 失败方式（先列后写）：
--   1. 广告位未交付时广告复活直接回 unavailable，占位路径没接上（11-38）；
--   2. 濒死界面没有广告入口，只能等 15 秒死亡后才出现（11-19）；
--   3. 广告流程在飞时倒计时照走，玩家在看广告的途中被判死亡（11-28）；
--   4. 取消 / 失败 / 超时后倒计时没平移，复活被提前或玩家卡在界面上（11-29）；
--   5. 广告成功与免费倒计时各结算一次，一轮死亡复活两次（11-30）；
--   6. 取消 / 失败扣了金豆或发了权益（11-31）；
--   7. 重复点击与迟到回调产生第二次复活、第二次回包（11-32）；
--   8. 满血复活后带虚弱、血量不是上限、饥饿低于 10%（11-21、11-22）；
--   9. 占位成功当成平台结论（发真实权益 / 真实信号被当成已支付）（11-37、11-38）。
local function vec(x, y, z) return { x = x, y = y, z = z } end
local game_cfg = require('common.game_cfg')

local WIRING = {
  'platform = platform_host',
  'save = save_host',
  'player_data = player_data_host',
  'local fishHost = WorldRuntime.fish_host',
}
local function assert_wiring()
  local handle = assert(io.open('server/main.lua', 'rb'), '读不到 server/main.lua')
  local source = handle:read('a')
  handle:close()
  for _, line in ipairs(WIRING) do
    assert.is_truthy(source:find(line, 1, true), 'server/main.lua 里找不到接线：' .. line)
  end
end

local function signal()
  local slots = {}
  return {
    Connect = function(_, fn) slots[#slots + 1] = fn return { Disconnect = function() end } end,
    Fire = function(_, ...) for _, fn in ipairs(slots) do fn(...) end end,
  }
end

local function newPlayer(userId, x)
  local controller = { Health = game_cfg.vitals.MaxHealth, MaxHealth = game_cfg.vitals.MaxHealth,
    WalkSpeed = 10, HealthChanged = signal(), Died = signal(), OnReborn = signal() }
  function controller:TakeDamage(amount)
    self.Health = math.max(0, self.Health - amount)
    self.HealthChanged:Fire(self.Health)
    if self.Health <= 0 then self.Died:Fire() end
  end
  local player = { UserId = userId, Name = 'p' .. userId, attrs = {},
    Character = { Controller = controller, Position = vec(x or 0, 0, 0), Size = { y = 2 } },
    CharacterAdded = signal(), CharacterRemoving = signal() }
  function player:SetAttribute(key, value) self.attrs[key] = value end
  function player:GetAttribute(key) return self.attrs[key] end
  return player
end

describe('条款 11 广告满血复活（占位广告位）', function()
  local env

  local function drain()
    for _ = 1, 200 do
      if #env.queue == 0 then return end
      table.remove(env.queue, 1)()
    end
    error('Task 队列未收敛')
  end

  local function sentOf(name)
    return env.sent[name] or {}
  end

  local function lastPayload(name)
    local list = sentOf(name)
    return list[#list] and list[#list].payload or nil
  end

  local function countPayload(name, predicate)
    local n = 0
    for _, row in ipairs(sentOf(name)) do
      if predicate(row.payload) then n = n + 1 end
    end
    return n
  end

  local function survival(player, payload)
    env.re.SurvivalAction.OnServerEvent:Fire(player, payload)
    drain()
  end

  local function platformAction(player, payload)
    env.re.PlatformAction.OnServerEvent:Fire(player, payload)
    drain()
  end

  local function join(userId)
    local player = newPlayer(userId)
    env.players:OnPlayerAdded(player)
    env.lifeHost:add(player, env.players:GetDataInst(player))
    drain()
    return player
  end

  local function down(player)
    env.v:ApplyHit(env.v:NewHit(nil, 'fishAttack'), player, game_cfg.vitals.MaxHealth + 10)
    assert.same('downed', env.s:Phase(player))
  end

  local function advance(seconds)
    env.lifeHost:advance(seconds)
    env.now = env.lifeHost.clock.now()
    drain()
  end

  local function adRequest(player, seq)
    survival(player, { action = 'FullRevive', mode = 'ad', seq = seq })
  end

  local function goodsRequest(player, seq)
    survival(player, { action = 'FullRevive', mode = 'goods', seq = seq })
  end

  local function confirm(player, outcome)
    local accepted = env.platform:HasFlow(player)
    platformAction(player, { action = 'PlaceholderOutcome', outcome = outcome })
    return accepted
  end

  -- 占位广告通道打开的回包（服务端 notifyPlaceholder 的 open=true）
  local function flowOpen()
    local list = sentOf('PlatformResult')
    for i = #list, 1, -1 do
      local payload = list[i].payload
      if payload.action == 'PlaceholderFlow' and payload.open == true then return payload end
    end
  end

  -- 某个玩家收到过几次「满血复活成功」回包（按玩家分开数，循环里换人不串账）
  local function reviveResultsFor(player)
    local n = 0
    for _, row in ipairs(sentOf('SurvivalResult')) do
      local payload = row.payload
      if row.userId == player.UserId and payload.action == 'FullRevive' and payload.ok == true then
        n = n + 1
      end
    end
    return n
  end

  local function ctrl(player)
    return player.Character.Controller
  end

  local function hunger(player)
    return player:GetAttribute('Hunger')
  end

  local function minHunger()
    return math.floor(game_cfg.vitals.MaxHunger * game_cfg.Survival.ReviveHungerPercent / 100)
  end

  before_each(function()
    assert_wiring()
    env = { now = 100, queue = {}, sent = {}, re = {}, values = {} }
    -- #249 占位闸门：占位广告位只在调试构建（或发布构建显式 AllowInPublish）下可用。
    -- 本文件显式打开调试开关，证的是「占位广告路径可用」，不是「发布构建可用」；
    -- 发布构建默认关闭的那条断言在本文件的「发布构建闸门」用例里。
    env.cfg = game_cfg
    env.saved = { cfgDebug = game_cfg.Debug, qaSlot = game_cfg.Save.QaSlot,
      placeholderEnabled = game_cfg.Platform.Placeholder.Enabled,
      placeholderAllowInPublish = game_cfg.Platform.Placeholder.AllowInPublish,
      placeholderAd = game_cfg.Platform.Placeholder.Ads.revive,
      game = rawget(_G, 'game'), Vector3 = rawget(_G, 'Vector3'),
      Vector2 = rawget(_G, 'Vector2'), Color = rawget(_G, 'Color'),
      re_util = rawget(_G, 're_util'), reutil = package.loaded['common.re_util'] }
    env.cfg.Debug = { Enabled = true }
    env.cfg.Save.QaSlot = ''
    env.cfg.Platform.Placeholder.Enabled = true
    _G.Vector3 = { New = vec }
    _G.Vector2 = { New = function(x, y) return { x = x, y = y } end }
    _G.Color = { New = function(...) return { ... } end }
    _G.game = { GetService = function(_, name)
      if name == 'Task' then
        return { Spawn = function(_, fn) env.queue[#env.queue + 1] = fn end, Wait = function() end }
      end
      if name == 'DataStoreService' then
        return { GetDataStore = function() return {
          GetAsync = function(_, key) return env.values[key] end,
          SetAsync = function(_, key, value) env.values[key] = value end,
          UpdateAsync = function(_, key, transform)
            local value = transform(env.values[key])
            if value then env.values[key] = value end
            return value
          end,
        } end }
      end
      if name == 'World' then return { GetServerTime = function() return env.now end } end
      if name == 'Players' then return { GetPlayers = function() return {} end } end
      if name == 'RunService' then return { IsServer = function() return true end,
        IsClient = function() return false end, Heartbeat = signal() } end
    end }
    local function reStub(name)
      env.sent[name] = env.sent[name] or {}
      if not env.re[name] then
        env.re[name] = {
          OnServerEvent = signal(), OnClientEvent = signal(),
          FireClient = function(_, player, value)
            env.sent[name][#env.sent[name] + 1] = { userId = player.UserId, payload = value }
          end,
          FireAllClients = function(_, value)
            env.sent[name][#env.sent[name] + 1] = { userId = nil, payload = value }
          end,
          FireServer = function(_, payload)
            env.sent[name][#env.sent[name] + 1] = { userId = nil, payload = payload }
          end,
        }
      end
      return env.re[name]
    end
    local re = { GetRE = function(_, name) return reStub(name) end, CheckRECD = function() return false end }
    package.loaded['common.re_util'] = re
    _G.re_util = re

    package.loaded['server.data.player_data'] = nil
    env.player_data = require('server.data.player_data')
    env.save = assert(loadfile('server/save_host.lua'))()
    env.players = assert(loadfile('server/player_data_host.lua'))()
    env.platform = assert(loadfile('server/platform_host.lua'))()
    env.players.Save, env.save.player_data = env.save, env.players
    env.platform.Save, env.platform.player_data = env.save, env.players
    env.platform.Now = function() return env.now end
    env.lifeHost = require('tests.support.life_host').start({
      now = env.now or 100, remote = re, player_data = env.players, save = env.save,
      platform = env.platform,
      before_advance = function() drain() end,
    })
    env.v = env.lifeHost.runtime.life
    env.s = env.v
    env.platform:Start()
  end)

  after_each(function()
    if not env then return end
    local saved = env.saved
    game_cfg.Debug = saved.cfgDebug
    game_cfg.Save.QaSlot = saved.qaSlot
    game_cfg.Platform.Placeholder.Enabled = saved.placeholderEnabled
    game_cfg.Platform.Placeholder.AllowInPublish = saved.placeholderAllowInPublish
    game_cfg.Platform.Placeholder.Ads.revive = saved.placeholderAd
    _G.game = saved.game
    _G.Vector3 = saved.Vector3
    _G.Vector2 = saved.Vector2
    _G.Color = saved.Color
    _G.re_util = saved.re_util
    package.loaded['common.re_util'] = saved.reutil
    env = nil
  end)

  -- #249 占位闸门（ADR-0029 第四节第 9 项；条款 19-13「发布前检查」）：
  -- 关闭调试且 AllowInPublish=false 时，广告复活经 SurvivalAction 业务入口被拒绝，
  -- 不拉起占位广告通道、不复活、不发任何权益，回执说明「未开放」。
  -- 失败方式：闸门失位（发布构建里没打开开关也能看广告复活，玩家没看广告就复活），
  -- 或被拒后回执静默 / 措辞含糊，玩家不知道是「未开放」。
  it('19-13 发布构建未显式打开 AllowInPublish 时广告复活被拒且不发权益', function()
    game_cfg.Debug.Enabled = false
    game_cfg.Platform.Placeholder.Enabled = true
    game_cfg.Platform.Placeholder.AllowInPublish = false
    local player = join(7101)
    down(player)
    local beforeHunger = hunger(player)
    local health = player.Character.Controller.Health
    adRequest(player, 1)
    local refused = lastPayload('SurvivalResult')
    assert.is_not_nil(refused, '被闸门挡下的广告复活必须明确回包')
    assert.is_false(refused.ok)
    assert.same('not_open', refused.reason, '闸门关闭必须给出「未开放」这一原因')
    assert.is_truthy(tostring(refused.text):find('未开放', 1, true) ~= nil, '回执没说明未开放')
    assert.is_nil(flowOpen(), '闸门关闭时不得拉起占位广告通道')
    assert.is_false(env.platform:HasFlow(player), '闸门关闭时不得建平台 flow')
    assert.same('downed', env.s:Phase(player), '闸门关闭时不得复活')
    assert.same(health, player.Character.Controller.Health, '闸门关闭时不得回血')
    assert.same(beforeHunger, hunger(player), '闸门关闭时不得补饥饿')
  end)

  -- 重开侧（与上一条闸门用例配对）：发布构建显式打开 AllowInPublish 后，广告复活恢复可用——
  -- 经 SurvivalAction 业务入口能拉起占位广告 flow，看完广告满血复活。
  -- 失败方式：闸门打开后广告复活仍被拒、或不复活 / 不回血。
  it('19-13 发布构建显式打开 AllowInPublish 后广告复活恢复可用', function()
    game_cfg.Debug.Enabled = false
    game_cfg.Platform.Placeholder.Enabled = true
    game_cfg.Platform.Placeholder.AllowInPublish = true
    local player = join(7103)
    down(player)
    adRequest(player, 1)
    local flow = flowOpen()
    assert.is_not_nil(flow, '显式开放后广告复活应能拉起占位广告流程')
    assert.same('ad', flow.kind)
    assert.same(game_cfg.Platform.Placeholder.Ads.revive, flow.goodsId,
      '广告位参数必须来自共享配置的占位广告位')
    assert.is_true(confirm(player, 'success'))
    assert.same('alive', env.s:Phase(player), '显式开放后广告成功要复活')
    assert.same(game_cfg.vitals.MaxHealth, ctrl(player).Health, '满血复活必须是血量上限')
    local result = lastPayload('SurvivalResult')
    assert.is_true(result.ok)
    assert.same('FullRevive', result.action)
    assert.same('ad', result.mode)
  end)

  -- 11-19：濒死与死亡两个相位都能发起广告满血复活；入口只经可替换广告适配层，活动相位拒绝。
  it('11-19 濒死与死亡相位都能发起占位广告复活，活动相位被拒', function()
    local player = join(7101)
    adRequest(player, 1)
    assert.is_nil(flowOpen(), '活动相位不该拉起广告通道')
    local refused = lastPayload('SurvivalResult')
    assert.is_not_nil(refused, '活动相位的广告复活请求必须明确回包')
    assert.is_false(refused.ok)
    assert.same('not-revivable', refused.reason)

    down(player)
    adRequest(player, 2)
    local downedFlow = flowOpen()
    assert.is_not_nil(downedFlow, '濒死相位的广告入口没有拉起占位广告流程')
    assert.same('ad', downedFlow.kind)
    assert.same('revive', downedFlow.key)
    assert.same('revive', downedFlow.purpose)
    assert.same(game_cfg.Platform.Placeholder.Ads.revive, downedFlow.goodsId,
      '广告位参数必须来自共享配置的占位广告位')
    assert.same('ad', lastPayload('SurvivalState').platformPending)

    assert.is_true(confirm(player, 'cancel'))
    assert.same('downed', env.s:Phase(player), '取消后仍在濒死相位')

    advance(game_cfg.Survival.DownedSec)
    assert.same('dead', env.s:Phase(player))
    adRequest(player, 3)
    local deadFlow = flowOpen()
    assert.is_not_nil(deadFlow, '死亡相位的广告入口没有拉起占位广告流程')
    assert.same(game_cfg.Platform.Placeholder.Ads.revive, deadFlow.goodsId)
  end)

  -- 11-21 / 11-22：广告满血复活原地满血、饥饿至少 10%、不带虚弱，从濒死与死亡入口各走一次。
  it('11-21/11-22 广告复活后原地满血、饥饿至少 10%、不带虚弱', function()
    for _, entry in ipairs({ 'downed', 'dead' }) do
      local player = join(7102 + (entry == 'dead' and 1 or 0)) -- 每个入口一名玩家，各走一轮死亡
      down(player)
      if entry == 'dead' then advance(game_cfg.Survival.DownedSec) end
      assert.same(entry, env.s:Phase(player))
      assert.is_true(env.v:SetHunger(player, 0))
      adRequest(player, 1)
      assert.is_not_nil(flowOpen(), entry .. ' 入口没有拉起广告流程')
      confirm(player, 'success')
      assert.same('alive', env.s:Phase(player), entry .. ' 入口的广告成功没有复活')
      assert.same(game_cfg.vitals.MaxHealth, ctrl(player).Health, '满血复活必须是血量上限而不是 10%')
      assert.is_true(hunger(player) >= minHunger(), '复活后饥饿低于上限的 10%')
      assert.is_nil(lastPayload('SurvivalState').weakUntil, '满血复活不带虚弱')
      assert.same(10, ctrl(player).WalkSpeed, '满血复活不减移速')
      local result = lastPayload('SurvivalResult')
      assert.is_true(result.ok)
      assert.same('FullRevive', result.action)
      assert.same('ad', result.mode)
      -- 复活后免费倒计时不再结算第二次
      local healthAfter = ctrl(player).Health
      advance(game_cfg.Survival.DeadSec + 0.1)
      assert.same('alive', env.s:Phase(player))
      assert.same(healthAfter, ctrl(player).Health)
      assert.same(1, reviveResultsFor(player))
    end
  end)

  -- 11-28：广告流程在飞时，濒死倒计时与免费复活倒计时都暂停（否则玩家在看广告途中被判死亡）。
  it('11-28 广告流程在飞时濒死与免费复活倒计时暂停', function()
    local downedPlayer = join(7110)
    down(downedPlayer)
    adRequest(downedPlayer, 1)
    advance(game_cfg.Survival.DownedSec + 5)
    assert.same('downed', env.s:Phase(downedPlayer), '广告播放期间濒死倒计时没暂停')
    assert.same(1, ctrl(downedPlayer).Health)

    local deadPlayer = join(7111)
    down(deadPlayer)
    advance(game_cfg.Survival.DownedSec)
    assert.same('dead', env.s:Phase(deadPlayer))
    adRequest(deadPlayer, 1)
    advance(game_cfg.Survival.DeadSec + 10)
    assert.same('dead', env.s:Phase(deadPlayer), '广告播放期间免费复活倒计时没暂停')
    assert.same(1, ctrl(deadPlayer).Health, '暂停期间不得虚弱复活')

    -- 金豆支付同一条契约（同一处暂停分支）
    local paidPlayer = join(7112)
    down(paidPlayer)
    advance(game_cfg.Survival.DownedSec)
    goodsRequest(paidPlayer, 1)
    advance(game_cfg.Survival.DeadSec + 10)
    assert.same('dead', env.s:Phase(paidPlayer))
  end)

  -- 广告流程的三种非成功结局：取消 / 失败直接结算，超时由适配层兜底
  local function spendFlow(player, outcome)
    local function catchUp(delta)
      env.lifeHost:advance(delta)
      env.now = env.lifeHost.clock.now()
    end
    if outcome == 'timeout' then
      catchUp(game_cfg.Platform.FlowTimeoutSec)
      env.platform:Update()
      drain()
    else
      catchUp(7)
      platformAction(player, { action = 'PlaceholderOutcome', outcome = outcome })
    end
  end

  -- 11-29：广告关闭 / 失败 / 超时后倒计时恢复，并从暂停处继续（平移，不重置也不提前）。
  it('11-29 取消、失败或超时后倒计时按暂停时长恢复', function()
    for _, outcome in ipairs({ 'cancel', 'fail', 'timeout' }) do
      local player = join(7120 + #outcome)
      down(player)
      adRequest(player, 1)
      spendFlow(player, outcome)
      local result = lastPayload('SurvivalResult')
      assert.is_false(result.ok)
      assert.same(outcome, result.reason)
      assert.same('downed', env.s:Phase(player), outcome .. '：非成功结局后应立即回到濒死相位')
      -- 濒死倒计时平移暂停时长：恢复那一刻起还有完整的 15 秒
      advance(game_cfg.Survival.DownedSec - 1)
      assert.same('downed', env.s:Phase(player), outcome .. '：濒死倒计时没有平移（提前死亡）')
      advance(1.1)
      print('DBG after', outcome, env.s:Phase(player), env.lifeHost.clock.now())
      assert.same('dead', env.s:Phase(player), outcome .. '：濒死倒计时没有恢复')
      -- 死亡相位的免费倒计时同样平移
      adRequest(player, 2)
      spendFlow(player, outcome)
      advance(game_cfg.Survival.DeadSec - 1)
      assert.same('dead', env.s:Phase(player), outcome .. '：免费复活倒计时没有平移（提前复活）')
      advance(1.1)
      assert.same('alive', env.s:Phase(player), outcome .. '：免费复活倒计时没有恢复')
      assert.same(math.floor(game_cfg.vitals.MaxHealth * game_cfg.Survival.ReviveHealthPercent / 100),
        ctrl(player).Health, '恢复后仍按免费虚弱复活结算')
    end
  end)

  -- 11-30：广告成功、金豆成功与免费倒计时到期三条路径互斥结算，同一轮死亡只复活一次。
  it('11-30 广告、金豆与免费倒计时三条复活路径互斥', function()
    -- 广告成功后免费倒计时不再复活，血量也不被改回 10%
    local adPlayer = join(7130)
    down(adPlayer)
    adRequest(adPlayer, 1)
    confirm(adPlayer, 'success')
    assert.same('alive', env.s:Phase(adPlayer))
    advance(game_cfg.Survival.DeadSec + 0.1)
    assert.same(game_cfg.vitals.MaxHealth, ctrl(adPlayer).Health)
    assert.same(1, reviveResultsFor(adPlayer))

    -- 金豆成功后广告入口不再受理
    local goodsPlayer = join(7131)
    down(goodsPlayer)
    advance(game_cfg.Survival.DownedSec)
    goodsRequest(goodsPlayer, 1)
    confirm(goodsPlayer, 'success')
    assert.same('alive', env.s:Phase(goodsPlayer))
    assert.same(game_cfg.vitals.MaxHealth, ctrl(goodsPlayer).Health)
    adRequest(goodsPlayer, 2)
    assert.same('not-revivable', lastPayload('SurvivalResult').reason)

    -- 免费倒计时先到期（虚弱复活）之后，广告入口不再受理、血量不被改成满血
    local freePlayer = join(7132)
    down(freePlayer)
    advance(game_cfg.Survival.DownedSec) -- 濒死到期转死亡
    assert.same('dead', env.s:Phase(freePlayer))
    advance(game_cfg.Survival.DeadSec + 0.1) -- 免费倒计时到期虚弱复活
    assert.same('alive', env.s:Phase(freePlayer))
    local weakHealth = ctrl(freePlayer).Health
    assert.same(math.floor(game_cfg.vitals.MaxHealth * game_cfg.Survival.ReviveHealthPercent / 100),
      weakHealth)
    adRequest(freePlayer, 1)
    assert.same('not-revivable', lastPayload('SurvivalResult').reason)
    assert.same(weakHealth, ctrl(freePlayer).Health)
  end)

  -- 11-31：广告或支付取消、失败时不扣金豆、不改库存（占位通道也不发权益）。
  it('11-31 取消或失败不扣金豆、不发权益', function()
    local player = join(7140)
    down(player)
    local data = env.players:GetDataInst(player)
    local coinBefore = data.data.FishCoin
    local itemsBefore = data:ItemCount(game_cfg.Survival.AdrenalineItemId)
    for _, outcome in ipairs({ 'cancel', 'fail' }) do
      adRequest(player, #outcome)
      confirm(player, outcome)
    end
    advance(game_cfg.Survival.DownedSec) -- 金豆满血复活仍只在死亡相位：先走到死亡
    assert.same('dead', env.s:Phase(player))
    goodsRequest(player, 9)
    confirm(player, 'cancel')
    assert.same(coinBefore, data.data.FishCoin, '取消 / 失败不得改动金豆或金币')
    assert.same(itemsBefore, data:ItemCount(game_cfg.Survival.AdrenalineItemId), '取消 / 失败不得发物品')
    assert.same(0, countPayload('PlatformResult', function(payload)
      return payload.action == 'Grant' or payload.action == 'CoinGrant'
    end), '取消 / 失败不得发货或到账')
  end)

  -- 11-32：重复点击只发起一次请求；多次回调只结算一次。
  it('11-32 重复点击只发起一次请求，多次回调只结算一次', function()
    local player = join(7150)
    down(player)
    adRequest(player, 1)
    local first = flowOpen()
    assert.is_not_nil(first)
    adRequest(player, 2)
    local busy = lastPayload('SurvivalResult')
    assert.is_false(busy.ok)
    assert.same('busy', busy.reason)
    assert.same(1, countPayload('PlatformResult', function(payload)
      return payload.action == 'PlaceholderFlow' and payload.open == true
    end), '重复点击又开了一条广告通道')
    assert.is_true(confirm(player, 'success'))
    assert.same('alive', env.s:Phase(player))
    local resultCount = #sentOf('SurvivalResult')
    assert.is_false(confirm(player, 'success'), '没有在飞通道时确认必须被拒')
    assert.is_false(confirm(player, 'timeout'))
    assert.same(resultCount, #sentOf('SurvivalResult'), '迟到回调不得再回包')
    assert.same(1, reviveResultsFor(player))
    assert.same(game_cfg.vitals.MaxHealth, ctrl(player).Health)
  end)

  -- 11-37 / 11-38：编辑器内只经可替换广告适配层；占位成功不发真实付费权益，真实平台信号一律忽略；
  -- 广告位参数集中在共享配置，换参数不改判定。
  it('11-37/11-38 广告复活只经适配层、占位不发真实权益、真实信号被忽略', function()
    local player = join(7160)
    down(player)
    adRequest(player, 1)
    local opened = flowOpen()
    assert.is_not_nil(opened)
    assert.is_truthy(opened.goodsId:find('^placeholder%.ad%.') ~= nil,
      '占位广告位必须以 placeholder.ad. 前缀标识，实际：' .. tostring(opened.goodsId))
    assert.is_truthy((opened.notice or ''):find('不发放真实付费权益', 1, true) ~= nil,
      '占位广告通道必须注明不发放真实付费权益')

    -- 真实平台购买完成信号没有可信交付身份：不得当成已支付来结算复活
    env.platform:OnGoodsPurchaseCompleted(opened.goodsId, 1, player)
    assert.same('downed', env.s:Phase(player), '真实平台信号不能结算占位广告复活')

    confirm(player, 'success')
    assert.same('alive', env.s:Phase(player))
    local data = env.players:GetDataInst(player)
    assert.same(0, data:ItemCount(game_cfg.Survival.AdrenalineItemId), '占位广告成功不得发平台权益')
    assert.same(0, countPayload('PlatformResult', function(payload)
      return payload.action == 'Grant' or payload.action == 'CoinGrant'
    end), '占位广告成功不得发货或到账')

    -- 换广告位参数只改共享配置：判定与回包结构不变
    game_cfg.Platform.Placeholder.Ads.revive = 'placeholder.ad.revive.next'
    local nextPlayer = join(7161)
    down(nextPlayer)
    adRequest(nextPlayer, 1)
    assert.same('placeholder.ad.revive.next', flowOpen().goodsId,
      '广告位参数必须从共享配置读取')
    confirm(nextPlayer, 'success')
    assert.same('alive', env.s:Phase(nextPlayer))
    assert.same(game_cfg.vitals.MaxHealth, ctrl(nextPlayer).Health)
  end)

  -- 11-38 失败路径：真实广告位与占位广告位都没交付时明确不可用，且不暂停倒计时。
  it('11-38 占位广告通道关闭时明确不可用且不暂停倒计时', function()
    -- 生产口径：调试构建的测试驱动器也关掉，真实与占位两条通道都没有
    game_cfg.Debug.Enabled = false
    game_cfg.Platform.Placeholder.Enabled = false
    game_cfg.Platform.Placeholder.AllowInPublish = false
    local player = join(7170)
    down(player)
    adRequest(player, 1)
    local result = lastPayload('SurvivalResult')
    assert.is_false(result.ok)
    assert.same('unavailable', result.reason)
    assert.is_nil(lastPayload('SurvivalState').platformPending, '不可用时不得进入倒计时暂停')
    assert.is_nil(flowOpen(), '不可用时不得开占位广告通道')
    advance(game_cfg.Survival.DownedSec + 0.1)
    assert.same('dead', env.s:Phase(player), '不可用时濒死倒计时照常走')
    advance(game_cfg.Survival.DeadSec + 0.1)
    assert.same('alive', env.s:Phase(player))
  end)
end)

describe('条款 11 广告复活入口（客户端）', function()
  local ctx

  local function signal()
    local listeners = {}
    return {
      Connect = function(_, fn)
        listeners[#listeners + 1] = fn
        return { Disconnect = function() end }
      end,
      Fire = function(_, ...) for _, fn in ipairs(listeners) do fn(...) end end,
    }
  end

  before_each(function()
    ctx = { now = 1000, nodes = {}, requests = {}, events = {}, notices = {},
      heartbeats = signal(), saved = {
        game = rawget(_G, 'game'), Vector2 = rawget(_G, 'Vector2'), Color = rawget(_G, 'Color'),
        LocalMsgNotice = rawget(_G, 'LocalMsgNotice'), reutil = package.loaded['common.re_util'] } }
    local env = ctx
    _G.LocalMsgNotice = function(msg) env.notices[#env.notices + 1] = msg end
    _G.Vector2 = { New = function(x, y) return { x = x, y = y } end }
    _G.Color = { New = function(...) return { ... } end }
    local world = {
      CreateUnit = function(_, kind, props)
        local node = { Kind = kind, Visible = true, OnClicked = signal() }
        for key, value in pairs(props) do node[key] = value end
        node.Destroy = function(me) me.Destroyed = true end
        env.nodes[node.Name] = node
        return node
      end,
      GetServerTime = function() return env.now or 1000 end,
    }
    _G.game = { GetService = function(_, name)
      if name == 'World' then return world end
      if name == 'Players' then return { LocalPlayer = { PlayerGui = { EuiManager = {
        GetRootNode = function() return {} end,
        GetDeviceResolution = function() return { x = 1920, y = 1080 } end,
      } } } } end
      if name == 'RunService' then return { Heartbeat = env.heartbeats } end
    end }
    local client_store = require('client.store.client_store')
    local root_view = require('client.views.root_view')
    local survival_overlay_view = require('client.views.survival_overlay_view')
    ctx.store, ctx.writer = client_store.new({ initial_now = ctx.now })
    ctx.events.SurvivalState = { OnClientEvent = { Fire = function(_, state)
      ctx.writer:ingest_event('SurvivalState', state)
    end } }
    ctx.view = root_view.mount({ Name = 'UIRoot', Destroying = signal() }, ctx.store, {
      overlays = { survival = survival_overlay_view.spec() },
      services = {
        send_survival = function(payload) ctx.requests[#ctx.requests + 1] = payload end,
        now = function() return ctx.now end,
        notify = function(text) ctx.notices[#ctx.notices + 1] = text end,
        resolution = { x = 1920, y = 1080 },
      },
      create_node = function(kind, props)
        local node = { Kind = kind, Visible = true, OnClicked = signal(), Text = '' }
        for key, value in pairs(props or {}) do node[key] = value end
        node.Destroy = function(me) me.Destroyed = true end
        ctx.nodes[node.Name] = node
        return node
      end,
    })
  end)

  after_each(function()
    if not ctx then return end
    local saved = ctx.saved
    package.loaded['common.re_util'] = saved.reutil
    _G.game = saved.game
    _G.Vector2 = saved.Vector2
    _G.Color = saved.Color
    _G.LocalMsgNotice = saved.LocalMsgNotice
    ctx = nil
  end)

  -- 11-19：濒死与死亡界面都显示「看广告满血复活」入口；金豆入口仍只在死亡相位（11-20 不归本单）。
  it('11-19 濒死与死亡界面都显示广告满血复活入口', function()
    ctx.events.SurvivalState.OnClientEvent:Fire({ phase = 'downed', endsAt = 1015 })
    assert.is_true(ctx.nodes['SurvivalAdRevive'].Visible, '濒死界面缺少广告满血复活入口')
    assert.same(game_cfg.Survival.AdReviveText, ctx.nodes['SurvivalAdReviveText'].Text)
    assert.is_false(ctx.nodes['SurvivalPaidRevive'].Visible)
    ctx.events.SurvivalState.OnClientEvent:Fire({ phase = 'dead', endsAt = 1040 })
    assert.is_true(ctx.nodes['SurvivalAdRevive'].Visible)
    assert.is_true(ctx.nodes['SurvivalPaidRevive'].Visible)
    ctx.events.SurvivalState.OnClientEvent:Fire({ phase = 'alive' })
    assert.is_true(ctx.nodes['SurvivalAdRevive'].Destroyed, '活着时广告入口必须拆掉')
    assert.is_true(ctx.nodes['SurvivalPaidRevive'].Destroyed, '活着时金豆入口必须拆掉')
  end)

  -- 11-19 / 11-28：广告入口上行仍是既有的 SurvivalAction{action='FullRevive'}，播放期间按钮收起并显示等待文案。
  it('11-19 广告入口复用 FullRevive 上行，播放期间收起并暂停提示', function()
    ctx.events.SurvivalState.OnClientEvent:Fire({ phase = 'downed', endsAt = 1015 })
    assert.is_true(ctx.nodes['SurvivalAdRevive'].Visible)
    ctx.nodes['SurvivalAdRevive'].OnClicked:Fire()
    assert.same({ action = 'FullRevive', mode = 'ad', seq = 1 }, ctx.requests[1])
    ctx.events.SurvivalState.OnClientEvent:Fire({ phase = 'downed', endsAt = 1015, platformPending = 'ad' })
    assert.is_false(ctx.nodes['SurvivalAdRevive'].Visible, '广告播放期间入口必须收起')
    assert.same(game_cfg.Survival.PlatformWaitText, ctx.nodes['SurvivalTitle'].Text)
    ctx.events.SurvivalState.OnClientEvent:Fire({ phase = 'downed', endsAt = 1022 })
    assert.is_true(ctx.nodes['SurvivalAdRevive'].Visible)
  end)
end)
