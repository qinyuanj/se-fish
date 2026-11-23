-- 条款 19-12（docs/acceptance/19-acceptance-criteria.md）：
-- 多人行为由本地连接夹具证明加入、离开与共享世界状态的完整代码路径；
-- 真实多人结论作为生产开关单列，不用夹具结论替代。
-- 所以本文件只断言**代码路径**：8 条以上虚拟连接同时在线时，小队、PK、他人抢救与共享地面实例
-- 各自走通，并且连接进出不会让这些状态错位。真实多人环境（真机、真网络、真并发）不在断言范围。
--
-- 只走业务入口：本地连接夹具 tests/support/local_link.lua 复现 server/main.lua 的连接生命周期，
-- 小隊与抢救都经登记的 RemoteEvent（PartyAction / InteractAction），伤害走统一入口 MgrVitals:ApplyHit，
-- 共享世界状态读 MgrLoot 的快照。引擎边界用替身。
-- 失败方式（先列后写）：
--   1. 8 条连接下，同队免伤或野外 PK 只剩单对用例里的效果（过滤读的是连接时刻的快照）；
--   2. 鱼塘安全区只对部分连接生效；
--   3. 共享地面实例只对生成它的连接可见，或有人离开就消失；
--   4. 两个人抢同一份只结算一次这条在多人连接下变成两份；
--   5. 施救者断线后抢救照样结算，或重连后又补一次；
--   6. 被救者恢复量不是自己的上限 10%。
local GameCfg = require('common.GameCfg')
local Link = assert(loadfile('tests/support/local_link.lua'))()

local POND = { x = 6.26, y = 5.01, z = -0.71 }
local ARENA = { x = 241, y = 6, z = 0 }

local function at(base, dz)
  return { x = base.x, y = base.y, z = base.z + dz }
end

describe('条款 19-12 本地连接夹具下的多人代码路径', function()
  local link

  before_each(function() link = Link.open() end)
  after_each(function() if link then link:Close() end end)

  -- 连接身份必须唯一：同一 UserId 再连一次等于换了一个玩家对象，会盖掉前一条连接。
  local function joinMany(count, position, firstId)
    local players = {}
    for index = 1, count do
      players[index] = link:Join((firstId or 5000) + index, { position = position or at(ARENA, index) })
    end
    return players
  end

  local function squad(a, b)
    link:Party(a, { action = 'Invite', targetUserId = b.UserId })
    link:Party(b, { action = 'Accept' })
    assert.is_true(link.managers.Party:SameParty(a, b), '小队没有建立')
  end

  local function down(player)
    assert.is_true(link:Hit(nil, player, 'fishAttack', GameCfg.Vitals.MaxHealth + 10))
    assert.same('downed', link:Phase(player), player.UserId .. ' 没有进入濒死')
  end

  local function rescue(rescuer, target, seq)
    link:Interact(rescuer, { target = 'downedPlayer', action = 'Rescue',
      targetUserId = target.UserId, seq = seq or 1 })
  end

  it('19-12 八条以上连接同时在线时，小队免伤与野外 PK 各自成立', function()
    local players = joinMany(8)
    assert.same(8, link:Count(), '八条连接没有同时在线')
    squad(players[1], players[2])

    local okFriendly = link:Hit(players[1], players[2], 'weapon', 30)
    assert.is_false(okFriendly, '同队伤害没有免掉')
    assert.same(GameCfg.Vitals.MaxHealth, players[2].Character.Controller.Health)

    local okEnemy, actual = link:Hit(players[1], players[4], 'weapon', 30)
    assert.is_true(okEnemy, '野外 PK 没有结算')
    assert.same(30, actual)
    assert.same(GameCfg.Vitals.MaxHealth - 30, players[4].Character.Controller.Health)

    -- 队伍在第 3、第 4 条连接身上也一致：不是只对建立队伍的那一对生效
    squad(players[3], players[4])
    assert.is_false(link:Hit(players[3], players[4], 'weapon', 30))
    assert.is_true(link:Hit(players[1], players[3], 'weapon', 30), '两队之间互相打应当结算')
  end)

  it('19-12 鱼塘安全区约束玩家间伤害，鱼攻击等非玩家来源照常结算', function()
    local players = joinMany(8, POND)
    squad(players[1], players[2])
    assert.is_false(link:Hit(players[1], players[3], 'weapon', 30), '鱼塘里不该有玩家间伤害')
    assert.is_true(link:Hit(nil, players[3], 'fishAttack', 30), '鱼攻击在安全区也要结算')
    assert.same(GameCfg.Vitals.MaxHealth - 30, players[3].Character.Controller.Health)

    players[1].Character.Position = at(ARENA, 0)
    players[3].Character.Position = at(ARENA, 1)
    assert.is_true(link:Hit(players[1], players[3], 'weapon', 30), '走出鱼塘后玩家间伤害应当结算')
  end)

  it('19-12 共享地面实例对所有连接同一份，进出不改它，两人抢同一份只结算一次', function()
    local players = joinMany(8)
    local loot = assert(link:Loot('bass', at(ARENA, 0)), '共享地面实例没生成')
    assert.same(1, #link:LootSnapshot())
    local seen = joinMany(1, at(ARENA, 0), 5100)
    assert.same(1, #link:LootSnapshot(), '新连接看不到已有的共享实例')
    assert.is_true(link:Leave(seen[1]))
    assert.same(1, #link:LootSnapshot(), '一条连接离开把共享实例带走了')

    players[1].Character.Position = at(ARENA, 0)
    players[2].Character.Position = at(ARENA, 0.5)
    assert.is_true(link:Pickup(players[1], loot.id or loot.Id), '第一个人拾取失败')
    assert.is_false(link:Pickup(players[2], loot.Id), '第二个人还能拾到同一份')
    assert.same(0, #link:LootSnapshot())
    local okCount = 0
    for _, message in ipairs(link.sent.LootResult or {}) do
      if message.payload and message.payload.ok == true then okCount = okCount + 1 end
    end
    assert.same(1, okCount, '同一份地面实例结算了不止一次')
  end)

  it('19-12 八连接下抢救走到恢复，施救者断线则中止且重连后不补结算', function()
    local players = joinMany(8)
    local downed = players[5]
    down(downed)
    players[6].Character.Position = at(downed.Character.Position, 1)
    rescue(players[6], downed)
    link:Advance(GameCfg.Rescue.DurationSec + 0.1)
    local expected = math.floor(GameCfg.Vitals.MaxHealth * GameCfg.Survival.ReviveHealthPercent / 100)
    assert.same('alive', link:Phase(downed), '抢救没有把被救者拉起来')
    assert.same(expected, downed.Character.Controller.Health, '恢复量不是被救者上限的比例')

    local target = players[7]
    down(target)
    players[8].Character.Position = at(target.Character.Position, 1)
    rescue(players[8], target, 2)
    assert.same('rescuing', link:Phase(target), '抢救没有开始')
    assert.is_true(link:Leave(players[8]))
    link:Advance(GameCfg.Rescue.DurationSec + 0.1)
    assert.same('downed', link:Phase(target), '施救者断线后抢救仍结算了')
    local health = target.Character.Controller.Health

    local back = link:Join(5008, { position = at(target.Character.Position, 1) })
    link:Advance(GameCfg.Rescue.DurationSec + 0.1)
    assert.same('downed', link:Phase(target), '重连把中断的抢救补结算了')
    assert.same(health, target.Character.Controller.Health, '重连改了被救者的血量')

    players[6].Character.Position = at(target.Character.Position, 1)
    rescue(players[6], target, 3)
    link:Advance(GameCfg.Rescue.DurationSec + 0.1)
    assert.same('alive', link:Phase(target), '重连后由别人重新发起仍然救不起来')
    local online = link:Online(back)
    assert.is_true(online, '重连的连接没有回到在线')
  end)
end)