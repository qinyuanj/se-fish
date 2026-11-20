-- 条款 9（docs/acceptance/09-multiplayer-rules.md）：小队是只由服务端维护的权威状态——
-- 邀请距离与超时、3 人上限、离线自动离队、不足 2 人解散、主动离队即刻生效、归属入档与重连恢复。
-- 只走业务入口：server/main.lua 的 MgrMap 注册管理器 MgrParty / MgrPlayerData / MgrSave，
-- 客户端请求一律经 PartyAction 的 OnServerEvent 进服务端；引擎边界（DataStore、Task、RE、World、
-- Players、角色）用替身，不执行 main.lua 本体。条款 ID 标在每条用例里。
-- 失败方式（先列后写）：
--   1. 客户端请求里自带的 partyId / members 能改写归属，或能替别人接受邀请（9-02）；
--   2. 第 4 名玩家还能进队，或 3 人上限只在邀请端判定、接受端放行（9-06）；
--   3. 2 米外的邀请照样建出待处理邀请（9-07）；
--   4. 10 秒后接受仍进队，或超时不按拒绝结算（9-08）；
--   5. 队员离线后名单里还留着他，人数不重算（9-09）；
--   6. 只剩 1 人时不解散，剩余玩家仍带着队伍身份（9-10）；
--   7. 主动离队后仍算同队，或离队不落回无队伍（9-11）；
--   8. 队伍归属不进存档，或重连后既不恢复也不给明确的解散结果（9-22）。
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
  'MgrParty = require("server.Mgr.MgrParty")',
  'MgrMap.MgrParty.PlayerData = MgrMap.MgrPlayerData',
  'MgrMap.MgrParty.Save = MgrMap.MgrSave',
  'MgrMap.MgrParty.Vitals = MgrMap.MgrVitals',
}
local function assert_wiring()
  local handle = assert(io.open('server/main.lua', 'rb'), '读不到 server/main.lua')
  local source = handle:read('a')
  handle:close()
  for _, line in ipairs(WIRING) do
    assert.is_truthy(source:find(line, 1, true), 'server/main.lua 里找不到接线：' .. line)
  end
end

local function newPlayer(userId, position, name)
  local player = { UserId = userId, Name = name or ('p' .. userId), attrs = {} }
  player.Character = { Position = position or vec(0, 0, 0),
    SetPosition = function(self, pos) self.Position = pos end }
  player.CharacterAdded = signal()
  player.CharacterRemoving = signal()
  player.SetAttribute = function(self, key, value) self.attrs[key] = value end
  player.GetAttribute = function(self, key) return self.attrs[key] end
  return player
end

describe('条款 9 小队权威状态', function()
  local env

  local function drain()
    for _ = 1, 200 do
      if #env.queue == 0 then return end
      table.remove(env.queue, 1)()
    end
    error('Task 队列未收敛')
  end

  local function lastReply(name)
    local list = env.sent[name] or {}
    return list[#list]
  end

  -- 客户端收到的最后一份小队状态：推送里的 notice 是一次性事件，只能从收到的包上看。
  local function lastState(player)
    local list = env.sent.PartyState or {}
    for index = #list, 1, -1 do
      if list[index].userId == player.UserId then return list[index].payload end
    end
  end

  local function storeSnapshot(userId)
    return env.values[env.cfg.Save.KeyPrefix .. tostring(userId)]
  end

  local function saveNow(player)
    assert.is_true(env.save:Save(player.UserId, env.players:GetDataInst(player):Serialize(), 'test'))
    drain()
  end

  -- 客户端入口：只经服务端登记的 RE 上抛请求，不带任何“直接调管理器”的捷径。
  local function request(player, payload)
    env.re.PartyAction.OnServerEvent:Fire(player, payload)
    drain()
  end

  local function join(userId, position, name)
    local player = newPlayer(userId, position, name)
    env.players:OnPlayerAdded(player)
    drain()
    env.party:OnPlayerAdded(player)
    drain()
    return player
  end

  local function leave(player)
    -- main.lua 的顺序：先 MgrPlayerData（离场快照落账），再其它管理器的 OnPlayerRemoving。
    env.players:OnPlayerRemoving(player)
    env.party:OnPlayerRemoving(player)
    drain()
  end

  before_each(function()
    assert_wiring()
    env = { cfg = require('tests.support.zone_fixtures').Load() }
    env.cfg.Debug = { Enabled = false }
    env.cfg.Save.QaSlot = ''
    env.values, env.queue, env.sent, env.re = {}, {}, {}, {}
    env.now, env.health = 100, {}
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

    local function reStub(name)
      env.sent[name] = env.sent[name] or {}
      if not env.re[name] then
        env.re[name] = {
          OnServerEvent = signal(),
          OnClientEvent = signal(),
          FireClient = function(_, player, value)
            env.sent[name][#env.sent[name] + 1] = { userId = player.UserId, payload = value }
          end,
          FireAllClients = function() end,
          FireServer = function() end,
        }
      end
      return env.re[name]
    end
    local re = { GetRE = function(_, name) return reStub(name) end, CheckRECD = function() return false end }
    package.loaded['common.REUtil'] = re
    _G.REUtil = re
    package.loaded['server.Data.PlayerData'] = nil
    env.PlayerData = require('server.Data.PlayerData')
    env.save = assert(loadfile('server/Mgr/MgrSave.lua'))()
    env.players = assert(loadfile('server/Mgr/MgrPlayerData.lua'))()
    env.party = assert(loadfile('server/Mgr/MgrParty.lua'))()
    env.players.Save, env.save.PlayerData = env.save, env.players
    env.party.PlayerData, env.party.Save = env.players, env.save
    -- 血量只作快照转手：真源是 MgrVitals:SnapshotHealth（main.lua 注入），这里给可控值。
    env.party.Vitals = { SnapshotHealth = function(_, player)
      local row = env.health[player.UserId]
      return row and row[1] or 300, row and row[2] or 300
    end }
    env.party:Start()
  end)

  after_each(function()
    if env then
      _G.game = env.savedGame
      _G.Vector3 = env.savedVector
      _G.REUtil = env.savedRE
      env = nil
    end
  end)

  -- 9-19 + 9-06：组队主路径与 3 人上限（第 4 名玩家走邀请或接受都加不进）。
  it('9-19 9-06 组队最多三人，第四人邀请与接受都被服务端拒绝', function()
    local a = join(6301, vec(0, 0, 0), '甲')
    local b = join(6302, vec(1, 0, 0), '乙')
    local c = join(6303, vec(0, 1, 0), '丙')
    local d = join(6304, vec(1, 1, 0), '丁')

    request(a, { action = 'Invite', targetUserId = b.UserId })
    request(b, { action = 'Accept' })
    request(a, { action = 'Invite', targetUserId = c.UserId })
    request(c, { action = 'Accept' })
    assert.same(3, #env.party:Members(a), '三人小队')

    request(a, { action = 'Invite', targetUserId = d.UserId })
    assert.same('full', lastReply('PartyResult').payload.reason, '队伍已满时邀请被拒')
    assert.same(3, #env.party:Members(a))
    assert.is_nil(env.party:PartyIdOf(d))

    -- 接受端同样判定：邀请发出时队伍只有 2 人，接受时已被填满，第 4 人加不进。
    request(c, { action = 'Leave' })
    assert.same(2, #env.party:Members(a), '主动离队后剩两人，队伍仍在')
    request(a, { action = 'Invite', targetUserId = d.UserId })
    assert.is_true(lastReply('PartyResult').payload.ok, '两人的队伍还有空位，邀请发出')
    local e = join(6305, vec(2, 0, 0), '戊')
    request(a, { action = 'Invite', targetUserId = e.UserId })
    request(e, { action = 'Accept' })
    assert.same(3, #env.party:Members(a), '队伍重新填满三人')
    request(d, { action = 'Accept' })
    assert.same('full', lastReply('PartyResult').payload.reason, '接受邀请时队伍已满，第 4 人加不进')
    assert.is_nil(env.party:PartyIdOf(d), '第 4 人仍未入队')
    assert.same('party', env.party:SnapshotOf(a).state)
    assert.same(3, #env.party:SnapshotOf(a).members)
  end)

  -- 9-07：2 米内才能邀请，超距不产生待处理邀请（距离按场景平面距离，高度差不计入）。
  it('9-07 只允许 2 米内的邀请，超距邀请不建立待处理邀请', function()
    local a = join(6401, vec(0, 0, 0), '甲')
    local b = join(6402, vec(2, 0, 0), '乙')
    local c = join(6403, vec(0, 0, 2.5), '丙')
    request(a, { action = 'Invite', targetUserId = b.UserId })
    assert.is_true(lastReply('PartyResult').payload.ok, '正好 2 米可以邀请')
    assert.is_truthy(env.party:SnapshotOf(b).invite, '2 米内建立待处理邀请')

    request(a, { action = 'Invite', targetUserId = c.UserId })
    assert.same('too-far', lastReply('PartyResult').payload.reason, '超出 2 米的邀请被拒绝')
    assert.is_nil(env.party:SnapshotOf(c).invite, '超距邀请不产生待处理邀请')

    c.Character.Position = vec(0, 0, 1.9)
    request(a, { action = 'Invite', targetUserId = c.UserId })
    assert.is_true(lastReply('PartyResult').payload.ok, '走进 2 米内邀请成立')
    assert.is_truthy(env.party:SnapshotOf(c).invite)
  end)

  -- 9-08：邀请 10 秒内有效，到点按拒绝结算，超时后接受不生效、队伍组成不变。
  it('9-08 邀请 10 秒未处理按拒绝结算，超时后再接受不生效', function()
    local a = join(6411, vec(0, 0, 0), '甲')
    local b = join(6412, vec(1, 0, 0), '乙')
    local c = join(6413, vec(0, 0, 1), '丙')
    local d = join(6414, vec(1, 0, 1), '丁')
    request(a, { action = 'Invite', targetUserId = b.UserId })
    assert.same(10, env.party:SnapshotOf(b).invite.expiresInSec, '邀请带 10 秒倒计时')

    env.now = env.now + 9.5
    env.party:Update()
    assert.is_truthy(env.party:SnapshotOf(b).invite, '未到 10 秒仍在待处理')
    request(b, { action = 'Accept' })
    assert.is_true(lastReply('PartyResult').payload.ok, '10 秒内接受生效')
    assert.is_not_nil(env.party:PartyIdOf(b))

    request(c, { action = 'Invite', targetUserId = d.UserId })
    assert.is_truthy(env.party:SnapshotOf(d).invite)
    env.now = env.now + 10
    env.party:Update()
    assert.is_nil(env.party:SnapshotOf(d).invite, '到 10 秒按拒绝结算，邀请消失')
    request(d, { action = 'Accept' })
    assert.same('no-invite', lastReply('PartyResult').payload.reason, '超时后接受不生效')
    assert.is_nil(env.party:PartyIdOf(d), '超时后队伍组成不变')
    assert.is_nil(env.party:PartyIdOf(c))
  end)

  -- 9-09 + 9-10：离线自动离队、人数重算；少于 2 人解散并给出明确的解散结果。
  it('9-09 9-10 队员离线自动离队，少于两人自动解散', function()
    local a = join(6421, vec(0, 0, 0), '甲')
    local b = join(6422, vec(1, 0, 0), '乙')
    local c = join(6423, vec(0, 0, 1), '丙')
    request(a, { action = 'Invite', targetUserId = b.UserId })
    request(b, { action = 'Accept' })
    request(a, { action = 'Invite', targetUserId = c.UserId })
    request(c, { action = 'Accept' })
    assert.same(3, #env.party:SnapshotOf(a).members)

    leave(c)
    assert.is_nil(env.party:PartyIdOf(c), '离线玩家自动退出小队')
    assert.same(2, #env.party:Members(a), '人数按减一重算')
    local names = {}
    for _, row in ipairs(env.party:SnapshotOf(a).members) do names[row.name] = true end
    assert.is_nil(names['丙'], '名单里不再保留离线玩家')
    assert.is_true(env.party:SameParty(a, b), '留下的两人仍是队友')

    leave(b)
    assert.is_nil(env.party:PartyIdOf(a), '少于 2 人自动解散，剩余玩家回到无队伍')
    assert.same('none', env.party:SnapshotOf(a).state)
    assert.same('disbanded', lastState(a).notice, '解散结果对剩余玩家是明确的')
  end)

  -- 9-11：主动离队立即生效，归属与队友判定同步更新。
  it('9-11 主动离队后归属立即更新', function()
    local a = join(6431, vec(0, 0, 0), '甲')
    local b = join(6432, vec(1, 0, 0), '乙')
    local c = join(6433, vec(0, 0, 1), '丙')
    request(a, { action = 'Invite', targetUserId = b.UserId })
    request(b, { action = 'Accept' })
    request(a, { action = 'Invite', targetUserId = c.UserId })
    request(c, { action = 'Accept' })
    assert.is_true(env.party:SameParty(a, c))

    request(c, { action = 'Leave' })
    assert.is_true(lastReply('PartyResult').payload.ok)
    assert.is_nil(env.party:PartyIdOf(c), '主动离队后立刻不再属于小队')
    assert.is_false(env.party:SameParty(a, c), '离队后立即不再享有该小队的免伤口径')
    assert.is_true(env.party:SameParty(a, b), '留下的两人仍是队友')
    assert.same('none', env.party:SnapshotOf(c).state)
    assert.same(2, #env.party:SnapshotOf(a).members)
  end)

  -- 9-02：归属只由服务端维护，请求里自带的 partyId / members / owner 一律不读。
  it('9-02 客户端无法用请求改写自己或他人的队伍归属', function()
    local a = join(6441, vec(0, 0, 0), '甲')
    local b = join(6442, vec(1, 0, 0), '乙')
    local c = join(6443, vec(0, 0, 1), '丙')
    local d = join(6444, vec(1, 0, 1), '丁')

    request(a, { action = 'Invite', targetUserId = b.UserId })
    request(b, { action = 'Accept', partyId = 9999, members = { d.UserId }, owner = b.UserId })
    assert.is_true(lastReply('PartyResult').payload.ok)
    local id = env.party:PartyIdOf(a)
    assert.is_not_nil(id)
    assert.same(id, env.party:PartyIdOf(b), '接受后与邀请人同队')
    assert.is_true(id ~= 9999, '客户端自报的小队号不被采用')
    assert.is_nil(env.party:PartyIdOf(d), '客户端自报的名单不改写他人归属')

    -- 没有待处理邀请时，凭空带上别人的 partyId / fromUserId 也塞不进队伍。
    request(d, { action = 'Accept', partyId = id, fromUserId = a.UserId })
    assert.same('no-invite', lastReply('PartyResult').payload.reason)
    assert.is_nil(env.party:PartyIdOf(d))

    request(d, { action = 'SetParty', partyId = id })
    assert.same('unknown-action', lastReply('PartyResult').payload.reason, '未登记的动作不改归属')
    assert.is_nil(env.party:PartyIdOf(d))

    -- 替别人接受：服务端只认请求者自己的邀请记录，被冒名者的邀请原封不动。
    request(a, { action = 'Invite', targetUserId = c.UserId })
    request(d, { action = 'Accept', fromUserId = a.UserId, targetUserId = c.UserId })
    assert.same('no-invite', lastReply('PartyResult').payload.reason)
    assert.is_nil(env.party:PartyIdOf(d), '他人无法替第三名玩家入队')
    request(c, { action = 'Accept' })
    assert.same(id, env.party:PartyIdOf(c), '被邀请者用自己的邀请入队')
  end)

  -- 9-22：归属进存档；重连能回到原小队，原小队已散时给出明确的解散结果。
  it('9-22 队伍归属进存档，重连恢复或给出明确的解散结果', function()
    local a = join(6451, vec(0, 0, 0), '甲')
    local b = join(6452, vec(1, 0, 0), '乙')
    local c = join(6453, vec(0, 0, 1), '丙')
    request(a, { action = 'Invite', targetUserId = b.UserId })
    request(b, { action = 'Accept' })
    request(a, { action = 'Invite', targetUserId = c.UserId })
    request(c, { action = 'Accept' })
    local id = env.party:PartyIdOf(a)
    assert.is_not_nil(id)

    for _, player in ipairs({ a, b, c }) do
      assert.same(id, env.players:GetDataInst(player).Extra.party.id, '归属写进存档扩展字段')
      saveNow(player)
      assert.same(id, storeSnapshot(player.UserId).extra.party.id, '存档里带着小队号')
    end

    -- 丙断线：三人队剩两人，丙离场快照在他离队之前落账，因此存档仍带着小队号。
    leave(c)
    assert.same(id, storeSnapshot(c.UserId).extra.party.id, '离线保留归属，重连才谈得上恢复')
    assert.same(2, #env.party:Members(a))

    local back = newPlayer(6453, vec(0, 0, 1), '丙')
    env.players:OnPlayerAdded(back)
    drain()
    env.party:OnPlayerAdded(back)
    drain()
    assert.same(id, env.party:PartyIdOf(back), '重连回到原小队')
    assert.is_true(env.party:SameParty(back, a))
    assert.same(3, #env.party:Members(a), '恢复后人数回到三人')
    assert.same('restored', lastState(back).notice, '恢复结果对玩家是明确的')
    assert.same(id, env.players:GetDataInst(back).Extra.party.id)

    -- 乙先离线（存档保留小队号），随后甲离线把剩下的两人队减到一人：小队解散。
    leave(b)
    assert.same(id, storeSnapshot(b.UserId).extra.party.id, '离线时存档仍带着小队号')
    leave(a)
    assert.is_nil(env.party:PartyIdOf(back), '不足两人后小队解散')
    local again = newPlayer(6452, vec(1, 0, 0), '乙')
    env.players:OnPlayerAdded(again)
    drain()
    env.party:OnPlayerAdded(again)
    drain()
    assert.is_nil(env.party:PartyIdOf(again), '原小队已散，不恢复到不存在的小队')
    assert.same('disbanded', lastState(again).notice, '给出明确的解散结果')
    assert.same(0, env.players:GetDataInst(again).Extra.party.id, '归属落回无队伍')
  end)
end)
