-- #264 本地连接夹具的 B 级时序探针（离线模拟，可重跑）。
-- 运行：仓库根执行 lua tests/probes/local_link_runtime.lua；退出码 0 = 全部通过。
--
-- 口径（ADR-0029 第三节第 10 行、条款 1-04 / 19-12）：只证明加入、离开、共享世界状态与小隊 / PK / 抢救
-- 的**代码路径**完整，不证明真实容量、不证明真实多人行为；那两项是生产开关，由平台/人另行签署。
--
-- 链路：10 条虚拟连接连续加入（每条独立读档）→ 小隊建立后同队免伤、野外 PK 结算 →
--       共享地面实例对所有连接同一份、两人抢同一份只结算一次 → 施救者断线时抢救中止 →
--       重连不补结算、由别人重新发起才救起来 → 再走两轮全员离开 / 回来，存档键不复制也不丢。
--
-- 失败方式（先列后写）：
--   1. 第 9、第 10 条连接读不到档，或两条连接共用同一条存档键；
--   2. 同队免伤 / 野外 PK 在 8 条连接下失效，或鱼塘安全区不约束玩家间伤害；
--   3. 共享地面实例只对生成它的连接可见，或被人抢成两份；
--   4. 施救者断线后抢救仍结算，或重连补一次；
--   5. 全员离开再回来后存档键翻倍（服务端留了第二份状态）。
package.path = table.concat({ './?.lua', './?/init.lua', package.path }, ';')

local ZoneFixtures = require('tests.support.zone_fixtures')
local GameCfg = require('common.game_cfg')
ZoneFixtures.apply(GameCfg)
local Link = assert(loadfile('tests/support/local_link.lua'))()

local MARK = 'LOCALLINK264'
local ARENA = { x = 241, y = 6, z = 0 }
local POND = { x = 6.26, y = 5.01, z = -0.71 }
local failures, checks = 0, 0

local function at(base, dz) return { x = base.x, y = base.y, z = base.z + dz } end

local function check(name, ok, detail)
    checks = checks + 1
    if not ok then failures = failures + 1 end
    print(string.format('%s %-46s %s%s', MARK, name, ok and 'PASS' or 'FAIL',
        detail and ('  # ' .. tostring(detail)) or ''))
end

local function run()
    local link = Link.open()
    local ok, err = pcall(function()
        local players = {}
        for index = 1, 10 do
            players[index] = link:join(7000 + index, { position = at(ARENA, index) })
        end
        check('10 条连接同时在线', link:Count() == 10, link:Count())
        local keys, seen, unique = {}, {}, true
        for _, player in ipairs(players) do
            local key = link.managers.Save:key(player.UserId)
            if seen[key] then unique = false end
            seen[key] = true
            keys[player.UserId] = key
            if not link:data(player) then unique = false end
        end
        check('每条连接独立读档且存档键唯一', unique)

        link:Party(players[1], { action = 'Invite', targetUserId = players[2].UserId })
        link:Party(players[2], { action = 'Accept' })
        check('小队建立', link.managers.Party:same_party(players[1], players[2]))
        check('同队免伤', link:hit(players[1], players[2], 'weapon', 30) == false)
        check('野外 PK 结算', link:hit(players[1], players[4], 'weapon', 30) == true)
        players[1].Character.Position = POND
        players[3].Character.Position = POND
        check('鱼塘安全区免伤', link:hit(players[1], players[3], 'weapon', 30) == false)

        local loot = assert(link:Loot('bass', ARENA))
        local seen = link:join(7101, { position = ARENA })
        check('共享地面实例对新连接可见', #link:loot_snapshot() == 1 and loot.Id == link:loot_snapshot()[1].id)
        link:leave(seen)
        check('有人离开后共享地面实例还在', #link:loot_snapshot() == 1)
        players[1].Character.Position = ARENA
        players[2].Character.Position = at(ARENA, 0.5)
        check('第一个人拾取成功', link:pickup(players[1], loot.Id) == true)
        check('第二个人抢不到同一份', link:pickup(players[2], loot.Id) == false)
        local okCount = 0
        for _, message in ipairs(link.sent.LootResult or {}) do
            if message.payload and message.payload.ok == true then okCount = okCount + 1 end
        end
        check('同一份地面实例只结算一次', okCount == 1, okCount)

        local target = players[7]
        link:hit(nil, target, 'fishAttack', GameCfg.Vitals.MaxHealth + 10)
        check('目标进入濒死', link:phase(target) == 'downed', link:phase(target))
        players[8].Character.Position = at(target.Character.Position, 1)
        link:Interact(players[8], { target = 'downedPlayer', action = 'Rescue',
            targetUserId = target.UserId, seq = 1 })
        check('抢救开始', link:phase(target) == 'rescuing', link:phase(target))
        link:leave(players[8])
        link:advance(GameCfg.Rescue.DurationSec + 0.1)
        check('施救者断线后抢救不结算', link:phase(target) == 'downed', link:phase(target))
        local health = target.Character.Controller.Health
        local back = link:join(7008, { position = at(target.Character.Position, 1) })
        link:advance(GameCfg.Rescue.DurationSec + 0.1)
        check('重连不补结算', link:phase(target) == 'downed' and target.Character.Controller.Health == health)
        players[6].Character.Position = at(target.Character.Position, 1)
        link:Interact(players[6], { target = 'downedPlayer', action = 'Rescue',
            targetUserId = target.UserId, seq = 2 })
        link:advance(GameCfg.Rescue.DurationSec + 0.1)
        local expected = math.floor(GameCfg.Vitals.MaxHealth * GameCfg.Survival.ReviveHealthPercent / 100)
        check('换人重新发起后救起', link:phase(target) == 'alive'
            and target.Character.Controller.Health == expected, target.Character.Controller.Health)
        local online = link:online(back)
        check('重连的连接在线', online)

        for round = 1, 2 do
            for index = 1, 10 do
                local player = link.online_players[7000 + index]
                if player then link:leave(player) end
            end
            local left = link:Count()
            local restored = 0
            for index = 1, 10 do
                local player = link:join(7000 + index, { position = at(ARENA, index) })
                if keys[player.UserId] == link.managers.Save:key(player.UserId)
                    and link:data(player) then restored = restored + 1 end
            end
            check('第 ' .. round .. ' 轮全员进出后全部恢复', left == 0 and restored == 10,
                'left=' .. left .. ' restored=' .. restored)
        end
        local values = 0
        for _ in pairs(link.values) do values = values + 1 end
        -- 10 条主连接 + 1 条中途加入又离开的旁观连接：各一条键，没有第二份状态
        check('存档键数等于连接过的身份数（没有复制第二份状态）', values == 11, values)
        print(string.format('%s 存档键=%d 在线=%d 地面实例=%d', MARK, values, link:Count(), #link:loot_snapshot()))
    end)
    link:close()
    if not ok then error(err, 0) end
end

run()
print(string.format('%s 结果：%d 项断言，%d 项失败', MARK, checks, failures))
os.exit(failures == 0 and 0 or 1)