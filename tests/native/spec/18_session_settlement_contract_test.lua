-- 条款 18（docs/acceptance/18-save-and-recovery.md）：会话 fencing、版本校验、重连落点与虚弱恢复、
-- 个人/共享状态隔离、旧档升级，以及摆渡结算的可重试操作身份。
-- 只走业务入口：进入的是 server/main.lua 的 MgrMap 注册管理器——MgrPlayerData / MgrSave / MgrFerry /
-- MgrSurvival；引擎边界（DataStore、Task、RE、World、角色）用替身。不执行 main.lua 本体。
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
    Fire = function(_, ...) for _, fn in ipairs(slots) do fn(...) end end,
  }
end

-- 前提守卫：本文件复现的是 main.lua 的接线，接线一改先红。
local WIRING = {
  'MgrMap.MgrSave.PlayerData = MgrMap.MgrPlayerData',
  'MgrMap.MgrFerry.PlayerData = MgrMap.MgrPlayerData',
  'MgrMap.MgrFerry.Save = MgrMap.MgrSave',
  'MgrMap.MgrSurvival.Save = MgrMap.MgrSave',
}
local function assert_wiring()
  local handle = assert(io.open('server/main.lua', 'rb'), '读不到 server/main.lua')
  local source = handle:read('a')
  handle:close()
  for _, line in ipairs(WIRING) do
    assert.is_truthy(source:find(line, 1, true), 'server/main.lua 里找不到接线：' .. line)
  end
end

local function newPlayer(userId, position)
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

  local function lastReply(name)
    local list = replies(name)
    return list[#list]
  end

  local function seedSnapshot(uid)
    local seed = env.PlayerData.New(newPlayer(uid, vec(0, 0, 0)))
    seed:Init()
    return seed:Serialize()
  end

  local function storeSnapshot(uid)
    return env.values[env.cfg.Save.KeyPrefix .. tostring(uid)]
  end

  local function ready(uid, position, snapshot)
    local player = newPlayer(uid, position or vec(0, 5, 0))
    local originalSet = player.Character.SetPosition
    player.Character.SetPosition = function(self, pos)
      env.savedLanding = { x = pos.x, y = pos.y, z = pos.z }
      originalSet(self, pos)
    end
    if snapshot then env.values[env.cfg.Save.KeyPrefix .. tostring(uid)] = snapshot end
    env.players:OnPlayerAdded(player)
    drain()
    return player, env.players:GetDataInst(player)
  end

  before_each(function()
    assert_wiring()
    env = { cfg = require('tests.support.zone_fixtures').Load() }
    env.cfg.Debug = { Enabled = false }
    env.cfg.Save.QaSlot = ''
    env.values, env.queue, env.sent = {}, {}, {}
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
    end, CreateRemoteEvent = function() return signal() end }

    local reStub = {
      GetRE = function(_, name)
        env.sent[name] = env.sent[name] or {}
        return {
          FireClient = function(_, player, value)
            env.sent[name][#env.sent[name] + 1] = { userId = player.UserId, payload = value }
          end,
          FireAllClients = function() end,
          OnServerEvent = signal(),
        }
      end,
      CheckRECD = function() return false end,
    }
    package.loaded['common.REUtil'] = reStub
    _G.REUtil = reStub
    package.loaded['server.Data.PlayerData'] = nil
    env.PlayerData = require('server.Data.PlayerData')
    env.save = assert(loadfile('server/Mgr/MgrSave.lua'))()
    env.players = assert(loadfile('server/Mgr/MgrPlayerData.lua'))()
    env.ferry = assert(loadfile('server/Mgr/MgrFerry.lua'))()
    env.survival = assert(loadfile('server/Mgr/MgrSurvival.lua'))()
    env.players.Save, env.save.PlayerData = env.save, env.players
    env.ferry.Save, env.ferry.PlayerData = env.save, env.players
    env.survival.Save, env.survival.PlayerData = env.save, env.players
    env.ferry.World = { GetServerTime = function() return env.now end }
    env.ferry.OnlinePlayers = function() return {} end
    env.anchors = {}
    for _, zone in ipairs(env.cfg.Zones) do
      for _, entity in ipairs(zone.Scene.Entities) do
        if entity.Role == 'Ferry' then
          env.anchors[entity.Name] = { Position = vec(entity.Position.x, entity.Position.y, entity.Position.z) }
        end
      end
    end
    env.ferry.Interact = {
      InRange = function(_, player, point)
        local anchor = env.anchors[point.AnchorName]
        local pos = player.Character and player.Character.Position
        if not anchor or not pos then return nil end
        local dx, dz = pos.x - anchor.Position.x, pos.z - anchor.Position.z
        return math.sqrt(dx * dx + dz * dz) <= point.Radius + point.Slack and anchor or nil
      end,
      FindAnchor = function(_, name) return env.anchors[name] end,
    }
    env.route = env.cfg.Ferry.Routes[1]
  end)

  after_each(function()
    if env then
      _G.game = env.savedGame
      _G.Vector3 = env.savedVector
      _G.REUtil = env.savedRE
      env = nil
    end
  end)

  it('旧会话快照与未知版本都不得覆盖新会话存档', function()
    local uid = 5201
    local old = seedSnapshot(uid)
    local player, data = ready(uid, nil, old)
    assert.same('ready', env.save:Status(uid).loadState)

    data:AddCoin(20)
    assert.is_true(env.save:Save(uid, data:Serialize(), 'test'))
    drain()
    assert.same(20, storeSnapshot(uid).coin)

    -- 同 UserId 重进：旧会话被替换，其快照从业务入口再次写入必须被拒。
    local rejoined = newPlayer(uid, vec(1, 5, 1))
    env.players:OnPlayerAdded(rejoined)
    drain()
    assert.is_false(env.save:Save(uid, old, 'late-callback'))
    assert.same(20, storeSnapshot(uid).coin)

    -- 版本校验：外部把 revision 改掉后，当前会话的写入也不能盖过去。
    local stored = storeSnapshot(uid)
    stored.meta.revision = stored.meta.revision + 5
    local fresh = env.players:GetDataInst(rejoined)
    assert.is_true(env.save:Save(uid, fresh:Serialize(), 'version-check'))
    drain()
    assert.is_true(env.save:IsPaused(uid), '会话与版本冲突必须关闭写入屏障')
    assert.same(stored.meta.revision, storeSnapshot(uid).meta.revision)
  end)

  it('船票结算的正常、失败与重放只落一次账', function()
    local uid = 5202
    local player, data = ready(uid)
    assert.is_true(data:AddItem(env.route.Outbound.Ticket))
    local anchor = env.anchors[env.route.Outbound.AnchorName].Position
    player.Character.Position = vec(anchor.x, anchor.y, anchor.z)
    local before = #storeSnapshot(uid).meta.operations

    assert.is_true(env.ferry:Handle(player, { action = 'Board', routeId = env.route.Id, seq = 1 }))
    drain()
    local first = lastReply('FerryResult').payload
    assert.is_true(first.ok, tostring(first.reason))
    assert.is_not_nil(first.operation)
    assert.same(0, data:ItemCount(env.route.Outbound.Ticket))
    assert.same(before + 1, #storeSnapshot(uid).meta.operations)

    assert.is_true(env.ferry:Handle(player, { action = 'Board', routeId = env.route.Id, seq = 2,
      requestId = first.operation }))
    drain()
    local replay = lastReply('FerryResult').payload
    assert.is_true(replay.ok)
    assert.same(first.operation.id, replay.operation.id)
    assert.same(0, data:ItemCount(env.route.Outbound.Ticket))
    assert.same(before + 1, #storeSnapshot(uid).meta.operations, '重放不得再次扣票或记账')
  end)

  it('写档失败时不扣船票、不开航班，也不回成功包', function()
    local uid = 5203
    local player, data = ready(uid)
    assert.is_true(data:AddItem(env.route.Outbound.Ticket))
    local anchor = env.anchors[env.route.Outbound.AnchorName].Position
    player.Character.Position = vec(anchor.x, anchor.y, anchor.z)
    assert.is_true(env.save:Save(uid, data:Serialize(), 'test'))
    drain()
    env.writeFailure = true
    env.ferry:Handle(player, { action = 'Board', routeId = env.route.Id, seq = 1 })
    drain()
    -- 会话被写失败关闭后内存实例不再可读；以持久快照判断船票有没有被先扣。
    local persisted = storeSnapshot(uid)
    assert.same(env.route.Outbound.Ticket, persisted.bar[1].id, '写档失败不能先扣票')
    local failed = lastReply('FerryResult')
    assert.is_false(failed ~= nil and failed.ok == true)
  end)

  it('退出重进后重放旧操作只回执不重复结算', function()
    local uid = 5204
    local player, data = ready(uid)
    assert.is_true(data:AddItem(env.route.Outbound.Ticket))
    local anchor = env.anchors[env.route.Outbound.AnchorName].Position
    player.Character.Position = vec(anchor.x, anchor.y, anchor.z)
    env.ferry:Handle(player, { action = 'Board', routeId = env.route.Id, seq = 1 })
    drain()
    local operation = lastReply('FerryResult').payload.operation
    assert.is_not_nil(operation)

    env.players:OnPlayerRemoving(player)
    local rejoined, fresh = ready(uid, vec(0, 5, 0))
    env.ferry.OnlinePlayers = function() return { rejoined } end
    env.ferry:Update()
    drain()
    assert.same(1, fresh:ItemCount(env.route.Outbound.Ticket), '未完成的船票应回退一次')

    local before = #storeSnapshot(uid).meta.operations
    assert.is_true(env.ferry:Handle(rejoined, { action = 'Board', routeId = env.route.Id, seq = 2,
      requestId = operation }))
    drain()
    assert.same(1, fresh:ItemCount(env.route.Outbound.Ticket))
    assert.same(before, #storeSnapshot(uid).meta.operations)
    assert.same(0, rejoined.teleports)
  end)

  it('重进恢复合法落点与虚弱剩余时间，旧档升级保留财产补默认值', function()
    local uid = 5205
    local snapshot = seedSnapshot(uid)
    snapshot.v = 1
    snapshot.extra, snapshot.meta = nil, nil
    snapshot.coin = 321
    snapshot.bar = { { i = 1, id = 'starterRod', n = 1 } }
    snapshot.bait = { worm = 2 }
    local _, data = ready(uid, vec(99999, 5, 99999), snapshot)
    assert.same(321, data.Data.FishCoin, 'v1 旧档财产必须保留')
    assert.same(1, data:ItemCount('starterRod'))
    assert.same(2, data.Data.Bait.worm, 'v1 鱼饵计数必须保留')
    assert.same(0, data.Extra.survival.weakRemaining, '新增虚弱字段按默认值填充')
    assert.is_table(data.Extra.travel.safePoint)
    assert.is_table(data.Extra.recovery)
    assert.same(0, #data:Serialize().meta.operations)
    local safe = env.cfg.Zones[1].Scene.SafePoint
    assert.same(vec(safe.x, safe.y, safe.z), env.savedLanding, '非法记录落点须回到同区安全点')
    assert.same(vec(safe.x, safe.y, safe.z), data.Extra.travel.safePoint)

    -- v2 档的虚弱剩余时间经 MgrSurvival 的公开入口恢复。
    local v2 = seedSnapshot(uid)
    v2.extra.survival.weakRemaining = 37
    v2.extra.travel.safePoint = { x = safe.x, y = safe.y, z = safe.z }
    local player = ready(uid, vec(safe.x, safe.y, safe.z), v2)
    local applied
    env.survival.Modifier = {
      Apply = function(_, _, _, _, seconds) applied = seconds return true end,
      GetRemaining = function() return applied or 0 end,
      Clear = function() end,
      ClearTarget = function() end,
    }
    env.survival.SpeedWriter = { RefreshMoveSpeed = function() end }
    env.survival:OnPlayerAdded(player)
    assert.same(37, applied, '重连后虚弱剩余时间继续生效')
  end)

  it('未知版本读档保留原档，不写空档；未就绪前结算请求被拒', function()
    local uid = 5207
    local broken = seedSnapshot(uid)
    broken.v, broken.coin = 99, 77
    env.values[env.cfg.Save.KeyPrefix .. tostring(uid)] = broken
    local player = newPlayer(uid, vec(0, 5, 0))
    env.players:OnPlayerAdded(player)
    drain()
    assert.same('failed', env.save:Status(uid).loadState)
    assert.same(77, storeSnapshot(uid).coin, '坏档必须原样保留')
    assert.same(99, storeSnapshot(uid).v)
    assert.is_false(env.save:Save(uid, seedSnapshot(uid), 'bad-write'))

    -- 存档尚未就绪时，摆渡结算入口直接拒绝，不扣票也不动其他财产。
    local uid2 = 5208
    local pending = newPlayer(uid2, vec(0, 5, 0))
    env.players:OnPlayerAdded(pending)
    assert.same('pending', env.save:Status(uid2).loadState)
    assert.is_false(env.ferry:Handle(pending,
      { action = 'Board', routeId = env.route.Id, seq = 1 }))
    assert.is_nil(lastReply('FerryResult')) -- 未就绪不回成功包
    drain()
  end)

  it('共享世界状态不进入个人存档', function()
    local uid = 5206
    local player, data = ready(uid)
    -- 世界侧活鱼与地面物品（共享对象）不是玩家财产。
    local world = { liveFish = { { id = 'fishA' } }, groundItems = { { id = 'dropA' } } }
    env.players.Loot = { Items = world.groundItems, Fish = world.liveFish }
    data:AddCoin(9)
    assert.is_true(env.save:Save(uid, data:Serialize(), 'test'))
    drain()
    local stored = storeSnapshot(uid)
    assert.same(9, stored.coin)
    assert.is_nil(stored.liveFish)
    assert.is_nil(stored.groundItems)
    assert.is_nil(stored.world)
    assert.is_nil(stored.extra.world)
    assert.same('table', type(stored.extra.recovery), '个人会话恢复记录独立存在')
  end)
end)