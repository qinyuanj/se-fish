local EconomyWorld = require('tests.support.economy_world')
-- 条款 18（docs/acceptance/18-save-and-recovery.md）：会话 fencing、版本校验、重连落点与虚弱恢复、
-- 个人/共享状态隔离、旧档升级，以及摆渡结算的可重试操作身份。
-- 四类证据：正常（交票落账）、失败（写档失败不扣票）、退出重进（旧会话回调失效 + 落点/虚弱恢复）、
-- 重放（同一 operation 只结算一次）。B 级时序证据另见 tests/native/ferry_test.lua 与 save_test.lua。
-- 失败方式（先列后写）：
--   1. 旧会话的迟到快照还能写进存档，或外部改过 revision 后当前会话照样盖过去；
--   2. 写档失败仍先扣船票 / 开航班 / 回成功包，或同一 operation 重放再扣一次；
--   3. 退出重进后未结算操作不恢复、重放旧身份又结算一次；
--   4. 非法记录落点不回同区安全点，或重连后虚弱剩余时间丢失；
--   5. v1 旧档升级丢财产 / 新字段没有默认值，未知版本读档被写成空档；
--   6. 共享世界（活鱼、地面物品）混进个人存档；存档未就绪就放行可变操作。
local function vec(x, y, z) return { x = x, y = y, z = z } end
local function signal()
  local slots = {}
  return {
    Connect = function(_, fn) slots[#slots + 1] = fn return { Disconnect = function() end } end,
    Fire = function(_, ...) local result for _, fn in ipairs(slots) do result = fn(...) end return result end,
  }
end

local function new_player(userId, position)
  local player = { UserId = userId, teleports = 0 }
  player.Character = { Position = position,
    SetPosition = function(self, pos) self.Position = pos player.teleports = player.teleports + 1 end }
  player.CharacterAdded = signal()
  player.CharacterRemoving = signal()
  player.SetAttribute = function() end
  return player
end

describe('条款 18 存档会话与结算身份', function()
  local env

  local function drain()
    for _ = 1, 200 do
      if #env.queue == 0 then return end
      table.remove(env.queue, 1)()
    end
    error('Task 队列未收敛')
  end

  local function replies(name)
    return env.sent[name] or {}
  end

  local function last_reply(name)
    local list = replies(name)
    return list[#list]
  end

  local function seedSnapshot(uid)
    local seed = env.player_data.new(new_player(uid, vec(0, 0, 0)))
    seed:Init()
    return seed:Serialize()
  end

  local function storeSnapshot(uid)
    return env.values[env.cfg.Save.KeyPrefix .. tostring(uid)]
  end

  local function ready(uid, position, snapshot)
    local player = new_player(uid, position or vec(0, 5, 0))
    local originalSet = player.Character.SetPosition
    player.Character.SetPosition = function(self, pos)
      env.savedLanding = { x = pos.x, y = pos.y, z = pos.z }
      originalSet(self, pos)
    end
    if snapshot then env.values[env.cfg.Save.KeyPrefix .. tostring(uid)] = snapshot end
    env.players:on_player_added(player)
    drain()
    return player, env.players:get_data_inst(player)
  end

  before_each(function()
    env = { cfg = require('tests.support.zone_fixtures').load() }
    env.cfg.Debug = { Enabled = false }
    env.savedWorldModules = {}
    for name, value in pairs(package.loaded) do
      if name:match('^server%.world_host%.') then
        env.savedWorldModules[name] = value
        package.loaded[name] = nil
      end
    end
    env.cfg.Save.QaSlot = ''
    env.values, env.queue, env.sent, env.events = {}, {}, {}, {}
    env.now, env.writeFailure = 100, false
    env.savedGame, env.savedVector, env.savedRE = rawget(_G, 'game'), rawget(_G, 'Vector3'), rawget(_G, 'REUtil')
    _G.Vector3 = { New = vec }
    _G.game = { GetService = function(_, name)
      if name == 'Task' then
        return { Spawn = function(_, fn) env.queue[#env.queue + 1] = fn end, Wait = function() end }
      end
      if name == 'DataStoreService' then
        return { GetDataStore = function() return {
          GetAsync = function(_, key) return env.values[key] end,
          SetAsync = function(_, key, value) env.values[key] = value end,
          UpdateAsync = function(_, key, transform)
            if env.writeFailure then error('写档失败') end
            local value = transform(env.values[key])
            if value then env.values[key] = value end
            return value
          end,
        } end }
      end
      if name == 'World' then return { GetServerTime = function() return env.now end } end
      if name == 'Players' then return { GetPlayers = function() return {} end } end
      if name == 'RunService' then return { IsServer = function() return false end } end
    end }

    local reStub = {
      get_re = function(_, name)
        env.sent[name] = env.sent[name] or {}
        if not env.events[name] then
          env.events[name] = {
            FireClient = function(_, player, value)
              env.sent[name][#env.sent[name] + 1] = { userId = player.UserId, payload = value }
            end,
            FireAllClients = function() end,
            OnServerEvent = signal(),
          }
        end
        return env.events[name]
      end,
      check_recd = function() return false end,
    }
    package.loaded['common.re_util'] = reStub
    _G.REUtil = reStub
    package.loaded['server.data.player_data'] = nil
    env.player_data = require('server.data.player_data')
    env.save = assert(loadfile('server/save_host.lua'))()
    env.players = assert(loadfile('server/player_data_host.lua'))()
    env.players.Save, env.save.player_data = env.save, env.players
    env.ferry = { online_players = function() return {} end }
    env.anchors = {}
    for _, zone in ipairs(env.cfg.Zones) do
      for _, entity in ipairs(zone.Scene.Entities) do
        if entity.role == 'Ferry' then
          env.anchors[entity.Name] = { Position = vec(entity.Position.x, entity.Position.y, entity.Position.z) }
        end
      end
    end
    env.interact = {
      in_range = function(_, player, point)
        local anchor = env.anchors[point.AnchorName]
        local pos = player.Character and player.Character.Position
        if not anchor or not pos then return nil end
        local dx, dz = pos.x - anchor.Position.x, pos.z - anchor.Position.z
        return math.sqrt(dx * dx + dz * dz) <= point.Radius + point.Slack and anchor or nil
      end,
      find_anchor = function(_, name) return env.anchors[name] end,
    }
    env.route = env.cfg.Ferry.Routes[1]
    local ServerRuntime = require('server.world_host.server_runtime')
    env.runtime = ServerRuntime.new({
      initial_now = env.now, zones = env.cfg.Zones, remote = reStub,
      player_data = env.players, save = env.save, interact = env.interact,
      players_service = { GetPlayers = function() return env.ferry.online_players() end },
      world_service = _G.game:GetService('World'),
      bind_ferry_action = function(dispatch)
        reStub:get_re('FerryAction').OnServerEvent:Connect(function(player, payload)
          return dispatch(player, payload)
        end)
      end,
    })
    function env.ferry:update()
      local dt = math.max(0, env.now - env.runtime.clock.now())
      env.runtime:step(dt, env.now)
    end
    function env.ferry:handle(player, payload)
      self:update()
      return reStub:get_re('FerryAction').OnServerEvent:Fire(player, payload) == true
    end
    env.runtime:start()
    env.runtime:mark_started()
  end)

  after_each(function()
    if env then
      if env.runtime then env.runtime:shutdown() end
      for name in pairs(package.loaded) do
        if name:match('^server%.world_host%.') then package.loaded[name] = nil end
      end
      for name, value in pairs(env.savedWorldModules or {}) do package.loaded[name] = value end
      _G.game = env.savedGame
      _G.Vector3 = env.savedVector
      _G.REUtil = env.savedRE
      env = nil
    end
  end)

  -- 条款 18-20（旧会话的异步回调不覆盖新会话存档）、18-21（写档不只以 UpdateAsync 返回的快照为准）、
  -- 18-22（每次写档校验会话与版本，不一致时拒绝写入）。
  it('旧会话快照与未知版本都不得覆盖新会话存档', function()
    local uid = 5201
    local old = seedSnapshot(uid)
    local player, data = ready(uid, nil, old)
    assert.same('ready', env.save:status(uid).loadState)

    data:AddCoin(20)
    assert.is_true(env.save:Save(uid, data:Serialize(), 'test'))
    drain()
    assert.same(20, storeSnapshot(uid).coin)

    -- 同 UserId 重进：旧会话被替换，其快照从业务入口再次写入必须被拒。
    local rejoined = new_player(uid, vec(1, 5, 1))
    env.players:on_player_added(rejoined)
    drain()
    assert.is_false(env.save:Save(uid, old, 'late-callback'))
    assert.same(20, storeSnapshot(uid).coin)

    -- 版本校验：外部把 revision 改掉后，当前会话的写入也不能盖过去。
    local stored = storeSnapshot(uid)
    stored.meta.revision = stored.meta.revision + 5
    local fresh = env.players:get_data_inst(rejoined)
    assert.is_true(env.save:Save(uid, fresh:Serialize(), 'version-check'))
    drain()
    assert.is_true(env.save:is_paused(uid), '会话与版本冲突必须关闭写入屏障')
    assert.same(stored.meta.revision, storeSnapshot(uid).meta.revision)
  end)

  -- 条款 18-23（扣费操作带可重试的操作身份，重放不重复扣费）、
  -- 18-24（结算操作带可重试的操作身份，重放不重复发奖：航班与 operation 记账只落一次）。
  it('船票结算的正常、失败与重放只落一次账', function()
    local uid = 5202
    local player, data = ready(uid)
    assert.is_true(data:AddItem(env.route.Outbound.Ticket))
    local anchor = env.anchors[env.route.Outbound.AnchorName].Position
    player.Character.Position = vec(anchor.x, anchor.y, anchor.z)
    local before = #storeSnapshot(uid).meta.operations

    assert.is_true(env.ferry:handle(player, { action = 'Board', route_id = env.route.Id, seq = 1 }))
    drain()
    local first = last_reply('FerryResult').payload
    assert.is_true(first.ok, tostring(first.reason))
    assert.is_not_nil(first.operation)
    assert.same(0, data:ItemCount(env.route.Outbound.Ticket))
    assert.same(before + 1, #storeSnapshot(uid).meta.operations)

    assert.is_true(env.ferry:handle(player, { action = 'Board', route_id = env.route.Id, seq = 2,
      requestId = first.operation }))
    drain()
    local replay = last_reply('FerryResult').payload
    assert.is_true(replay.ok)
    assert.same(first.operation.id, replay.operation.id)
    assert.same(0, data:ItemCount(env.route.Outbound.Ticket))
    assert.same(before + 1, #storeSnapshot(uid).meta.operations, '重放不得再次扣票或记账')
  end)

  -- 条款 18-23 / 18-24 的失败流程：写档失败时船票不扣、航班不开、不回成功包，两边都不落地。
  it('写档失败时不扣船票、不开航班，也不回成功包', function()
    local uid = 5203
    local player, data = ready(uid)
    assert.is_true(data:AddItem(env.route.Outbound.Ticket))
    local anchor = env.anchors[env.route.Outbound.AnchorName].Position
    player.Character.Position = vec(anchor.x, anchor.y, anchor.z)
    assert.is_true(env.save:Save(uid, data:Serialize(), 'test'))
    drain()
    env.writeFailure = true
    env.ferry:handle(player, { action = 'Board', route_id = env.route.Id, seq = 1 })
    drain()
    -- 会话被写失败关闭后内存实例不再可读；以持久快照判断船票有没有被先扣。
    local persisted = storeSnapshot(uid)
    assert.same(env.route.Outbound.Ticket, persisted.bar[1].id, '写档失败不能先扣票')
    local failed = last_reply('FerryResult')
    assert.is_false(failed ~= nil and failed.ok == true)
  end)

  -- 条款 18-13（尚未结算的操作在重进后据此恢复结算）、18-23 / 18-24 的退出重进流程
  -- （重放旧 operation 只回执，不重复扣费也不重复发奖）。
  it('退出重进后重放旧操作只回执不重复结算', function()
    local uid = 5204
    local player, data = ready(uid)
    assert.is_true(data:AddItem(env.route.Outbound.Ticket))
    local anchor = env.anchors[env.route.Outbound.AnchorName].Position
    player.Character.Position = vec(anchor.x, anchor.y, anchor.z)
    env.ferry:handle(player, { action = 'Board', route_id = env.route.Id, seq = 1 })
    drain()
    local operation = last_reply('FerryResult').payload.operation
    assert.is_not_nil(operation)

    env.players:on_player_removing(player)
    local rejoined, fresh = ready(uid, vec(0, 5, 0))
    env.ferry.online_players = function() return { rejoined } end
    env.now = env.now + 1
    env.ferry:update()
    drain()
    assert.same(1, fresh:ItemCount(env.route.Outbound.Ticket), '未完成的船票应回退一次')

    local before = #storeSnapshot(uid).meta.operations
    assert.is_true(env.ferry:handle(rejoined, { action = 'Board', route_id = env.route.Id, seq = 2,
      requestId = operation }))
    drain()
    assert.same(1, fresh:ItemCount(env.route.Outbound.Ticket))
    assert.same(before, #storeSnapshot(uid).meta.operations)
    assert.same(0, rejoined.teleports)
  end)

  -- 18-24（review #249-4）：发奖走同一条持久操作协议，同一身份重试只补回执、不再发一次。
  it('发奖重放只回执、只发一次', function()
    local shop = EconomyWorld.new()
    local uid = shop.player.UserId
    local itemId = env.cfg.Platform.Goods.adrenaline1.itemId
    local function snapshot() return shop.values[env.cfg.Save.KeyPrefix .. tostring(uid)] end
    local before = #snapshot().meta.operations

    env.cfg.Debug = { Enabled = true }
    env.cfg.Platform.Placeholder.Enabled = false
    assert.is_true(shop:platform_action({ action = 'Purchase', goods = 'adrenaline1', seq = 1 }))
    local opened = shop:last_result('PlatformResult')
    assert.is_not_nil(opened, '购买必须有支付回包')
    assert.same('TestFlow', opened.action, tostring(opened.reason))
    assert.is_true(opened.open)
    shop:resolve_platform('success')
    local first = shop:last_result('PlatformResult')
    assert.is_true(first.ok, tostring(first.reason))
    assert.is_not_nil(first.requestId, '回执要带可重试的请求身份')
    assert.same(1, first.granted)
    assert.same(1, shop.data:ItemCount(itemId))
    assert.same(before + 3, #snapshot().meta.operations, '支付意图、已支付与发奖各落一笔')

    shop:clear_events()
    assert.is_true(shop:platform_action({ action = 'Query', seq = 2, requestId = first.requestId }))
    local replay = shop:last_result('PlatformResult')
    assert.is_true(replay.ok)
    assert.same(first.requestId, replay.requestId, '重放认得原请求身份')
    assert.same(1, replay.granted, '回执仍是原来那一次发放')
    assert.same(1, shop.data:ItemCount(itemId), '重放不得重复发奖')
    assert.same(before + 3, #snapshot().meta.operations, '重放不得再记一笔发放')
    shop:tear_down()
  end)


  -- 条款 18-04（升级/购买/药水次数）、18-05（血量与饥饿）、18-06（濒死与死亡标记）、
  -- 18-07（图鉴个人重量）、18-08（任务进度与剧情已读）、18-09（到达集合）、
  -- 18-11（盲盒保底计数）、18-12（成就及其进度）：逐项经写档、读档往返后仍成立。

  it('个人持久状态逐项保存与恢复', function()
    local uid = 5209
    local snapshot = seedSnapshot(uid)
    local safe = env.cfg.Zones[1].Scene.SafePoint
    snapshot.extra.travel.safePoint = { x = safe.x, y = safe.y, z = safe.z }
    snapshot.extra.survival.health = 210
    snapshot.extra.survival.hunger = 140
    snapshot.extra.survival.dying = true
    snapshot.extra.survival.dead = true
    snapshot.extra.survival.dyingRemaining = 12
    snapshot.extra.survival.deadRemaining = 25
    snapshot.extra.growth.upgrades.backpack = 1
    snapshot.extra.growth.purchases['33'] = 2
    snapshot.extra.growth.potions.item167 = 1
    snapshot.extra.collection.weights.goldfish = 0.2
    snapshot.extra.collection.unlocked.goldfish = true
    snapshot.extra.quest = { step = 3, count = 2 }
    snapshot.extra.story.read.opening = true
    snapshot.extra.travel.arrived[2] = 1
    snapshot.extra.lottery.pity = 5
    snapshot.extra.achievements.final = true

    local _, data = ready(uid, vec(safe.x, safe.y, safe.z), snapshot)
    assert.same(210, data.extra.survival.health)
    assert.same(140, data.extra.survival.hunger)
    assert.is_true(data.extra.survival.dying)
    assert.is_true(data.extra.survival.dead)
    assert.same(12, data.extra.survival.dyingRemaining)
    assert.same(25, data.extra.survival.deadRemaining)
    assert.same(1, data.extra.growth.upgrades.backpack)
    assert.same(2, data.extra.growth.purchases['33'])
    assert.same(1, data.extra.growth.potions.item167)
    assert.same(0.2, data.extra.collection.weights.goldfish)
    assert.is_true(data.extra.collection.unlocked.goldfish)
    assert.same({ step = 3, count = 2 }, data.extra.quest)
    assert.is_true(data.extra.story.read.opening)
    assert.same(1, data.extra.travel.arrived[2])
    assert.same(5, data.extra.lottery.pity)
    assert.is_true(data.extra.achievements.final)

    local restored = data:Serialize()
    assert.same(210, restored.extra.survival.health)
    assert.same(140, restored.extra.survival.hunger)
    assert.same(0.2, restored.extra.collection.weights.goldfish)
    assert.same(5, restored.extra.lottery.pity)
    assert.is_true(restored.extra.achievements.final)
  end)

  -- 条款 18-01（金币与全部库存条目，含鱼饵）、18-02（每件物品的实例倍率与烤制状态）、
  -- 18-10（当前钓鱼区与安全落点：落点写回 extra.travel.safePoint，非法落点回退到同区安全点）、
  -- 18-16（v1 旧档升级为新版结构且保留已有财产）、18-17（新增字段按明确默认值填充）、
  -- 18-05 的重连分支（虚弱剩余时间经 MgrSurvival 公开入口继续生效）、18-31（记录落点不合法时恢复到同区安全点）。
  it('重进恢复合法落点与虚弱剩余时间，旧档升级保留财产补默认值', function()
    local uid = 5205
    local snapshot = seedSnapshot(uid)
    snapshot.v = 1
    snapshot.extra, snapshot.meta = nil, nil
    snapshot.coin = 321
    snapshot.bar = { { i = 1, id = 'starterRod', n = 1, m = 1.5, k = 1.2 } }
    snapshot.bp = { { i = 1, id = 'shrimpTicket', n = 1 }, { i = 2, id = 'shrimpTicket', n = 1 } }
    snapshot.bait = { worm = 2, sausage = 1 }
    local _, data = ready(uid, vec(99999, 5, 99999), snapshot)
    assert.same(321, data.data.FishCoin, 'v1 旧档财产必须保留')
    assert.same(1, data:ItemCount('starterRod'))
    assert.same(2, data:ItemCount('shrimpTicket'))
    assert.same(2, data.data.Bait.worm, 'v1 鱼饵计数必须保留')
    assert.same(1, data.data.Bait.sausage)
    local roundtrip = data:Serialize()
    assert.same(1.5, roundtrip.bar[1].m, 'v1 实例倍率必须保留')
    assert.same(1.2, roundtrip.bar[1].k, 'v1 烤制状态必须保留')
    assert.same(env.cfg.Vitals.MaxHealth, data.extra.survival.health, '新增血量字段按默认值填充')
    assert.same(env.cfg.Vitals.MaxHunger, data.extra.survival.hunger, '新增饥饿字段按默认值填充')
    assert.same(0, data.extra.survival.weakRemaining, '新增虚弱字段按默认值填充')
    assert.is_table(data.extra.travel.safePoint)
    assert.is_table(data.extra.recovery)
    assert.same(0, #data:Serialize().meta.operations)
    local safe = env.cfg.Zones[1].Scene.SafePoint
    assert.same(vec(safe.x, safe.y, safe.z), env.savedLanding, '非法记录落点须回到同区安全点')
    assert.same(vec(safe.x, safe.y, safe.z), data.extra.travel.safePoint)

    local v2 = seedSnapshot(uid)
    v2.extra.survival.weakRemaining = 37
    v2.extra.travel.safePoint = { x = safe.x, y = safe.y, z = safe.z }
    local player, data = ready(uid, vec(safe.x, safe.y, safe.z), v2)
    local host = require('tests.support.life_host').start({
      now = env.now, player_data = env.players, save = env.save,
    })
    host:add(player, data)
    local tree = host:tree(player)
    assert.is_true(tree:get_modifier_remaining('weak') > 36, '重连后虚弱剩余时间继续生效')
    assert.is_true(tree:get_modifier_remaining('weak') <= 37)
    host:shutdown()
  end)

  -- 条款 18-18（版本未知或读取失败时保留原档、不写空档）、18-19（存档就绪前的可变操作被拒）。
  it('未知版本读档保留原档，不写空档；未就绪前结算请求被拒', function()
    local uid = 5207
    local broken = seedSnapshot(uid)
    broken.v, broken.coin = 99, 77
    env.values[env.cfg.Save.KeyPrefix .. tostring(uid)] = broken
    local player = new_player(uid, vec(0, 5, 0))
    env.players:on_player_added(player)
    drain()
    assert.same('failed', env.save:status(uid).loadState)
    assert.same(77, storeSnapshot(uid).coin, '坏档必须原样保留')
    assert.same(99, storeSnapshot(uid).v)
    assert.is_false(env.save:Save(uid, seedSnapshot(uid), 'bad-write'))

    -- 存档尚未就绪时，摆渡结算入口直接拒绝，不扣票也不动其他财产。
    local uid2 = 5208
    local pending = new_player(uid2, vec(0, 5, 0))
    env.players:on_player_added(pending)
    assert.same('pending', env.save:status(uid2).loadState)
    assert.is_false(env.ferry:handle(pending,
      { action = 'Board', route_id = env.route.Id, seq = 1 }))
    assert.is_nil(last_reply('FerryResult')) -- 未就绪不回成功包
    drain()
  end)

  -- 条款 18-27（共享的活鱼与地面物品不进入个人存档）。
  it('共享世界状态不进入个人存档', function()
    local uid = 5206
    local player, data = ready(uid)
    -- 世界侧活鱼与地面物品（共享对象）不是玩家财产。
    local world = { liveFish = { { id = 'fishA' } }, ground_items = { { id = 'dropA' } } }
    env.players.Loot = { Items = world.ground_items, Fish = world.liveFish }
    data:AddCoin(9)
    assert.is_true(env.save:Save(uid, data:Serialize(), 'test'))
    drain()
    local stored = storeSnapshot(uid)
    assert.same(9, stored.coin)
    assert.is_nil(stored.liveFish)
    assert.is_nil(stored.ground_items)
    assert.is_nil(stored.world)
    assert.is_nil(stored.extra.world)
    assert.same('table', type(stored.extra.recovery), '个人会话恢复记录独立存在')
  end)
end)
