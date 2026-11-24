-- 条款 1-04（docs/acceptance/01-overview-and-scope.md）：
-- 8 人以上容量的代码路径由本地连接夹具证明：以 8 名以上虚拟连接连续加入与离开，服务端不丢状态；
-- 真实平台容量结论作为生产开关单列，夹具结论不替代它。
-- 所以本文件只断言**代码路径**：连接生命周期里读档、在线、离场、重连与服务端状态都不丢一份。
-- 真实容量（引擎连接数、带宽、平台并发）不在断言范围，也不得由本文件推出。
--
-- 只走业务入口：本地连接夹具 tests/support/local_link.lua 复现 server/main.lua 的加入与离场顺序，
-- 管理器公开方法与小隊请求通道就是生产入口；引擎边界用替身。
-- 失败方式（先列后写）：
--   1. 第 9、第 10 条连接读不到档、拿不到自己的存档键（容量路径只对少数人生效）；
--   2. 有人离开时把别人的状态一起清掉（小隊名单、血量、存档键）；
--   3. 离开的人把共享地面实例带走（世界状态跟着连接走）；
--   4. 离场未结算就重连，服务端留出第二份状态或丢掉第一份；
--   5. 反复进出后重连恢复不出原来的小隊归属。
local GameCfg = require('common.game_cfg')
local Link = assert(loadfile('tests/support/local_link.lua'))()

-- 鱼塘安全点（区夹具里的 Z1_Safe）与第二区野外点：两处都是场景里真实解析出的坐标。
local POND = { x = 6.26, y = 5.01, z = -0.71 }
local ARENA = { x = 241, y = 6, z = 0 }

describe('条款 1-04 八人以上容量的本地连接路径', function()
  local link

  before_each(function() link = Link.open() end)
  after_each(function() if link then link:Close() end end)

  local function joinMany(count, position)
    local players = {}
    for index = 1, count do
      players[index] = link:Join(3000 + index, { position = position or ARENA })
    end
    return players
  end

  local function squad(a, b, c)
    link:Party(a, { action = 'Invite', targetUserId = b.UserId })
    link:Party(b, { action = 'Accept' })
    if c then
      link:Party(a, { action = 'Invite', targetUserId = c.UserId })
      link:Party(c, { action = 'Accept' })
    end
  end

  it('1-04 十条虚拟连接连续加入，每条连接都独立读档就绪并落到自己的存档键', function()
    local players = joinMany(10)
    assert.same(10, link:Count(), '十条连接没有同时在线')
    local keys = {}
    for _, player in ipairs(players) do
      assert.is_not_nil(link:Data(player), player.UserId .. ' 没有读档就绪')
      assert.is_not_nil(link:Stored(player.UserId), player.UserId .. ' 没写出自己的存档键')
      local key = link.managers.Save:Key(player.UserId)
      assert.is_nil(keys[key], '两条连接共用了同一个存档键：' .. key)
      keys[key] = true
    end
    assert.same(10, (function()
      local count = 0
      for _ in pairs(keys) do count = count + 1 end
      return count
    end)())
  end)

  it('1-04 有人离开时留下的人不丢状态：小隊、血量、存档键与共享地面实例都在', function()
    local players = joinMany(10)
    squad(players[1], players[2], players[3])
    link:Save(players[1])
    -- 野外挨一刀，血量成为「这一份连接自己的状态」
    assert.is_true(link:Hit(players[4], players[5], 'weapon', 30))
    local health = players[5].Character.Controller.Health
    assert.same(GameCfg.Vitals.MaxHealth - 30, health)
    local loot = link:Loot('bass', { x = ARENA.x, y = ARENA.y, z = ARENA.z })
    assert.is_not_nil(loot, '共享地面实例没生成')
    assert.same(1, #link:LootSnapshot())

    -- 五个人连续离开：一个队里的人、一个挨过刀的人、一个纯路过的人
    for _, index in ipairs({ 3, 4, 5, 8, 9 }) do
      assert.is_true(link:Leave(players[index]))
    end
    assert.same(5, link:Count(), '离开五条连接后在线人数不对')

    assert.same(2, link.managers.Party:Count(players[1]), '剩下两名队员的小隊没了')
    assert.is_true(link.managers.Party:SameParty(players[1], players[2]))
    assert.same(GameCfg.Vitals.MaxHealth, players[1].Character.Controller.Health, '别人的离开改了留下的人的血量')
    assert.same(health, players[5].Character.Controller.Health, '离开的连接带走了自己的血量（读档会回来）')
    assert.is_not_nil(link:Stored(players[1].UserId), '留下的人的存档键被清掉了')
    assert.same(1, #link:LootSnapshot(), '有人离开把共享地面实例带走了')
    for _, index in ipairs({ 1, 2, 6, 7, 10 }) do
      assert.is_not_nil(link:Data(players[index]), players[index].UserId .. ' 的登录态在别人离开后没了')
    end
  end)

  it('1-04 连续两轮全员加入离开，存档键与服务端状态都不丢且不被复制', function()
    local players = joinMany(10)
    squad(players[1], players[2], players[3])
    for _, player in ipairs(players) do link:Save(player) end
    local keys = {}
    for _, player in ipairs(players) do keys[player.UserId] = link.managers.Save:Key(player.UserId) end
    for _, player in ipairs(players) do assert.is_true(link:Leave(player)) end
    assert.same(0, link:Count(), '第一轮没有全部离场')
    for userId, key in pairs(keys) do
      assert.is_not_nil(link.values[key], '离场把 ' .. userId .. ' 的存档键丢了')
    end

    local again = {}
    for _, index in ipairs({ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10 }) do
      again[index] = link:Join(3000 + index, { position = ARENA })
    end
    assert.same(10, link:Count(), '第二轮没有全部回来')
    for _, player in ipairs(again) do
      assert.same(keys[player.UserId], link.managers.Save:Key(player.UserId),
        player.UserId .. ' 重连换了一条存档键（状态被复制成第二份）')
      assert.is_not_nil(link:Data(player), player.UserId .. ' 重连没有读档就绪')
    end
    local values = 0
    for _ in pairs(link.values) do values = values + 1 end
    assert.same(10, values, '存档键数不等于连接数')
  end)

  it('1-04 离场未结算时重连：沿用同一条存档，不产生第二份状态', function()
    local players = joinMany(8)
    assert.is_true(link:Hit(players[1], players[2], 'weapon', 25))
    local before = link.managers.Save:Key(players[2].UserId)
    -- 先制造在途写入，再发出离场且不等它结算：这正是真实断线重连的时序
    local data = link:Data(players[2])
    assert.is_true(link.managers.Save:Save(players[2].UserId, data:Serialize(), 'test'))
    link:LeaveRaw(players[2])
    assert.is_not_nil(link.leaving[players[2].UserId], '离场没有进入结算中')

    local back = link:JoinRaw(3002, { position = ARENA })
    assert.same('pending', back:GetAttribute('SaveState'), '离场未结算时重连应当挂起读档')
    link:Advance(0)
    assert.is_true(link:WaitLeave(3002), '旧会话没有结算完')
    for _ = 1, 10 do link:Advance(0.05) end
    assert.is_not_nil(link:Data(back), '重连没有读档就绪')
    assert.is_true(link:Online(back), '重连没有进入在线')
    assert.same(before, link.managers.Save:Key(3002), '重连换了另一条存档键（等于第二份状态）')
    local values = 0
    for _ in pairs(link.values) do values = values + 1 end
    assert.same(8, values, '连接数没变，存档键数却变了')
  end)
end)