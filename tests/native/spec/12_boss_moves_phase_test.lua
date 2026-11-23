-- 条款 12-35 / 12-36 / 12-37 / 12-38 / 12-45（第 12 节「阶段与复合组」，#259）。
--
-- 业务入口：MgrFishUnit:SpawnLanded + Drop 把沧龙（fish55Elite）/ 哥斯拉（fish56Boss）放下，
-- 逐帧 Update 推进服务端权威时钟；只观察玩家看得见的三个面：
--   1. 玩家血量（Controller.Health，所有伤害都走 MgrVitals）；
--   2. 广播给客户端的 GarBiteNotice 预警载荷（client/LocalGarBite 消费的同一份契约）；
--   3. 服务端权威的巡航 / 携带 / 阶段态（fish.Aquatic、fish.Carry、fish.Phase、CombatPayload）。
-- 逐招表与阶段表（common/cfg/BossMoves.lua）只做结构断言：阶段表引用的招式必须已经出现在普通招式表里
-- （12-05 不新增表外招式），阶段阈值不是招式行。
--
-- 失败方式（编码前列出）：
--   1. 绕岛不移动、单帧位移超过表内移速 13（瞬移）；
--   2. 跃起砸击与落地甩头缺一行，或服务端用的数值与表内那行不一致；
--   3. 咬中的 300 与叼走过程接触的 150 被合并成一段（同帧扣两次或多加一段）；
--   4. 叼人不选离岛中心最近的玩家，或把玩家带不进真正的水域；
--   5. 阶段阈值被普通招式循环压住：同一帧该切阶段却先放了爪击。

local Cfg = require('common.GameCfg')
local Islet = require('tests.support.isle_combat')
local BossMoves = require('common.cfg.BossMoves')

local function need(cond, ...)
    if not cond then error(string.format(...), 2) end
end

local function mosasaurRow(move)
    local row = BossMoves.Get('mosasaur', move)
    need(row ~= nil, '逐招表缺沧龙的 %s 行', move)
    return row
end

describe('第 12 节 阶段与复合组（沧龙 / 哥斯拉）', function()
    local env
    local savedExtra

    before_each(function()
        savedExtra = { ability = package.loaded['server.AbilityAPI'] }
        env = Islet.new(7)
        package.loaded['server.AbilityAPI'] = nil
        local p = Islet.shoreDryPoint(7)
        env.player.Character.Position = env.vec(p.x, p.y, p.z)
        env.player.Character.Controller.Health = 100000
    end)

    after_each(function()
        env:tearDown()
        package.loaded['server.AbilityAPI'] = savedExtra.ability
    end)

    local function health()
        return env.player.Character.Controller.Health
    end

    local function noticesBy(move)
        local out = {}
        for _, notice in ipairs(env.notices) do
            if notice.move == move then out[#out + 1] = notice end
        end
        return out
    end

    -- 额外玩家：只用来观察「离岛中心最近的玩家」和落地甩头，不替换夹具里的主玩家。
    local function joinPeer(position)
        local controller = { Health = 100000 }
        function controller:TakeDamage(amount)
            self.Health = math.max(0, self.Health - amount)
        end
        local peer = { UserId = 3803, SetAttribute = function() end,
            Character = { Controller = controller, Position = position } }
        env.players[2] = peer
        env.lifeHost:add(peer)
        controller.Health = 100000
        return peer
    end

    local function dropPeer()
        local peer = env.players[2]
        if peer then env.lifeHost.runtime:on_player_removing(peer) end
        env.players[2] = nil
    end

    it('条款 12-35：沧龙移速按表 13，绕岛巡航逐帧不瞬移', function()
        local fish = env:drop('fish55Elite')
        assert.same(13, Cfg.Fish.fish55Elite.Speed)
        local dt, last, moved = 0.05, fish.Carrier.Body.Position, 0
        for _ = 1, 20 do
            env.now = env.now + dt
            env.mgr:Update()
            local p = fish.Carrier.Body.Position
            local step = math.sqrt((p.x - last.x) ^ 2 + (p.z - last.z) ^ 2)
            need(step <= 13 * dt + 1e-6, '巡航单帧位移 %s 超过表内移速 13', step)
            moved, last = moved + step, p
        end
        assert.truthy(moved > 1, '绕岛巡航一秒内几乎没有位移（' .. tostring(moved) .. ' 米）')
    end)

    it('条款 12-36：每 15 秒跃起砸击，落地后甩头，数值取自逐招表', function()
        local fish = env:drop('fish55Elite')
        local leap, head = mosasaurRow('leap'), mosasaurRow('head')
        assert.same(15, leap.Schedule.Sec)
        assert.same(35, leap.Damage.Value)
        assert.same(35, head.Damage.Value)
        assert.same(2.5, head.Range)
        local peer = joinPeer(env.player.Character.Position) -- 落点旁：吃砸击与甩头，不被叼走
        env:advance(15.1)
        local warning = noticesBy('mosasaurLeap')[1]
        assert.is_not_nil(warning, '15 秒没有跃起预警')
        assert.same(leap.Range, warning.range)
        assert.same(Cfg.Ability.Aquatic.LeapWindupSec + Cfg.Ability.Aquatic.LeapSec, warning.duration)
        assert.is_nil(warning.damage, '预警载荷带了伤害：客户端不得承担结算')
        assert.is_true(require('common.GarBiteNotice').Valid(warning))
        env:advance(17.6) -- 15.0 起手 + 1.0 预警 + 1.5 滞空
        assert.same(100000 - leap.Damage.Value - 300, health(), '砸击与咬中没有各结算一次')
        assert.same(100000 - leap.Damage.Value, peer.Character.Controller.Health)
        assert.is_not_nil(noticesBy('mosasaurHead')[1], '落地后没有甩头预警')
        local headWarning = noticesBy('mosasaurHead')[1]
        assert.same(head.Range, headWarning.range)
        assert.same(head.Warning.WindupSec, headWarning.duration)
        env:advance(18.45) -- 甩头 0.8 秒起手到期，早于携带段第一次 1 秒接触
        assert.same(100000 - leap.Damage.Value - head.Damage.Value,
            peer.Character.Controller.Health, '落地甩头没有结算')
        assert.is_not_nil(fish.Aquatic, '甩头结算后水域态丢失')
        dropPeer()
    end)

    it('条款 12-37：绕岛巡航，咬离岛中心最近的玩家，并叼走入海', function()
        local scene = Cfg.Zones[7].Scene
        local water = scene.Waters[1]
        local fish = env:drop('fish55Elite')
        env:advance(5)
        local function radius()
            local p = fish.Carrier.Body.Position
            return math.sqrt((p.x - water.Center.x) ^ 2 + (p.z - water.Center.z) ^ 2)
        end
        local r1, p1 = radius(), fish.Carrier.Body.Position
        env:advance(10)
        local r2, p2 = radius(), fish.Carrier.Body.Position
        need(math.abs(r1 - r2) < 3, '绕岛半径在漂移（%s → %s）', r1, r2)
        need(math.sqrt((p2.x - p1.x) ^ 2 + (p2.z - p1.z) ^ 2) > 5, '绕岛巡航没有绕行')

        -- 离岛中心 5 米的旁观者比岸上的主玩家更近：沧龙必须咬他而不是咬岸边玩家。
        local center = scene.SafePoint
        local peer = joinPeer(env.vec(center.x, center.y, center.z + 5))
        env:advance(15.1)
        env:advance(17.6)
        assert.is_not_nil(fish.Carry, '咬中后没有叼走玩家')
        assert.same(peer, fish.Carry.TargetPlayer, '叼走的不是离岛中心最近的玩家')
        assert.same(100000, health(), '没有目标资格的岸边玩家被错伤')
        assert.same(100000 - 35 - 300, peer.Character.Controller.Health)
        local MathWater = require('common.MathWaterJudge')
        env:advance(30)
        assert.is_not_nil(MathWater.HitZone(Cfg.Water.Zones, peer.Character.Position),
            '被叼走的玩家没有进入水域')
        dropPeer()
    end)

    it('条款 12-38：咬中 300 与叼走过程接触 150 分属两段，不合并', function()
        local bite, contact = mosasaurRow('bite'), mosasaurRow('contact')
        assert.same('hit', bite.Segment)
        assert.same('carry', contact.Segment)
        assert.same(300, bite.Damage.Value)
        assert.same(150, contact.Damage.Value)
        assert.truthy(contact.Damage.From:find('150', 1, true) ~= nil, '过程接触的伤害来源没写清')
        local fish = env:drop('fish55Elite')
        env:advance(15.1)
        env:advance(17.6)
        -- 命中段：落地砸击 35 + 咬中 300，落地这一帧只扣一次 300。
        assert.same(100000 - 35 - 300, health())
        -- 被叼走后离开落点，落地甩头不再命中他；携带段从下一秒起算，不重复扣咬中的 300。
        env:advance(18.45)
        assert.same(100000 - 35 - 300, health(), '过程接触提前或甩头重复结算')
        env:advance(19.65)
        assert.same(100000 - 35 - 300 - 2 * contact.Damage.Value, health(),
            '过程接触不是每秒 150 的独立判定段')
        env:advance(20.65)
        -- 鱼叼着玩家入水后即释放；携带段结束后不得继续补 150，也不得在同一秒结算两次。
        if fish.Carry then
            assert.same(100000 - 35 - 300 - 3 * contact.Damage.Value, health(),
                '过程接触每秒重复结算了多次')
        else
            assert.same(100000 - 35 - 300 - 2 * contact.Damage.Value, health(),
                '叼走解除后仍在补过程接触伤害')
        end
    end)

    it('条款 12-45：阶段表与普通招式表分开表达，阈值同帧优先于普通招式循环', function()
        local phase = BossMoves.Phases.godzilla
        assert.is_not_nil(phase, '逐招表没有独立的哥斯拉阶段表')
        assert.is_not_nil(phase.Thresholds and phase.AttackSets)
        assert.same(phase.Thresholds, Cfg.Ability.BossPhase.Thresholds)
        assert.same(phase.AttackSets, Cfg.Ability.BossPhase.AttackSets)
        for _, set in pairs(phase.AttackSets) do
            for _, move in ipairs(set) do
                need(BossMoves.Get('godzilla', move) ~= nil, '阶段表引用了表外招式 %s', move)
            end
        end
        assert.is_nil(BossMoves.Get('godzilla', 'threshold'), '阶段阈值被写成了招式行')
        assert.is_true(#phase.Thresholds[1].PhaseName > 0, '阶段切换没有可读的阶段名')

        local fish = env:drop('fish56Boss')
        local p = fish.Carrier.Body.Position
        env.player.Character.Position = env.vec(p.x, p.y, p.z + 2)
        env:advance(1.98)
        local before = 0
        for _, attack in ipairs(fish.Phase.AttackLog) do
            if attack.Name == 'claw' then before = before + 1 end
        end
        fish.Carrier.Health = 14000 -- 56%：与 2 秒到期的爪击同一帧跌破 60%
        env:advance(2.02)
        assert.same('water', fish.Phase.Phase, '阈值没有在同一帧生效')
        local after = 0
        for _, attack in ipairs(fish.Phase.AttackLog) do
            if attack.Name == 'claw' then after = after + 1 end
        end
        assert.same(before, after, '切阶段的同一帧仍落了普通招式')
        assert.same('water', env.mgr:CombatPayload(fish).phase, '阶段切换没有发布给客户端表现')
    end)
end)
