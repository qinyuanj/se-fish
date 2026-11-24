-- 第 12 节「精英与首领行为」近战与范围组逐招断言（#257）。
-- 覆盖 12-07 / 12-08 / 12-09 / 12-10 / 12-11 / 12-15 / 12-16 / 12-17 / 12-18 / 12-19。
--
-- 取证缝（用户指定）：MgrFishUnit:SpawnLanded + Drop 放下，逐帧 Update 推进服务端时钟；
-- 只观察玩家可见的三面：玩家血量、服务端 GarBiteNotice 预警载荷、鱼的战斗状态字。
-- 服务端权威结算；客户端 LocalGarBite 只消费这份载荷，不参与判定。
--
-- 失败方式（编码前列出）：
--   1. 逐招表四列与服务端实际伤害 / 节拍 / 预警形状不一致；
--   2. 预警先于命中不足，或预警形状被写死、不来自表；
--   3. 头部区判定失效（绕后仍咬中）/ 表外招式被排进循环；
--   4. 活动 15 / 30 秒后的眩晕窗口被抬后或不生效。

local Cfg = require('common.game_cfg')
local Islet = require('tests.support.isle_combat')
local BossMoves = require('common.cfg.boss_moves')
local GarBiteNotice = require('common.gar_bite_notice')

local function need(cond, fmt, ...)
    if not cond then error(string.format(fmt, ...), 2) end
end

local function idOf(combat)
    for id, species in pairs(Cfg.Fish) do
        if species.Combat == combat then return id end
    end
    error('逐招表的 Combat 标签没有对应鱼种：' .. combat)
end

describe('第 12 节 逐招表（近战与范围组）', function()
    local env, savedAbility, hp

    before_each(function()
        savedAbility = package.loaded['server.ability_api']
        env = Islet.new(1)
        env.player.Character.Controller.Health = 100000 -- 长时间节拍断言不被 300 血上限截断
        package.loaded['server.ability_api'] = nil
        hp = function() return env.player.Character.Controller.Health end
    end)

    after_each(function()
        env:tearDown()
        package.loaded['server.ability_api'] = savedAbility
    end)

    local function dropNear(id, distance)
        local fish = env:drop(id)
        local p = fish.Carrier.Body.Position
        env.player.Character.Position = env.vec(p.x, p.y, p.z + (distance or 1.5))
        return fish
    end

    local function locks(move)
        local out = {}
        for _, notice in ipairs(env.notices) do
            if notice.kind == 'lock' and notice.move == move then out[#out + 1] = notice end
        end
        return out
    end

    -- 预警载荷三件套必须就是逐招表那一行；命中结算走 MgrVitals，与形状无关。
    local function warningIsRow(move)
        local list = locks(move)
        local row = BossMoves.Get(env.moveFish, move)
        assert.truthy(#list > 0, move .. ' 没有预警广播')
        for _, notice in ipairs(list) do
            assert.same(row.Warning.Kind, notice.shape, move .. ' 预警形状与表不一致')
            assert.same(row.Warning.WindupSec, notice.duration, move .. ' 预警时长与表不一致')
            assert.same(row.Range, notice.range, move .. ' 预警范围与表不一致')
            if row.Warning.Width then
                assert.same(row.Warning.Width, notice.width, move .. ' 线形预警宽度与表不一致')
            end
            assert.is_true(GarBiteNotice.Valid(notice), move .. ' 载荷不满足客户端协议')
        end
        return list
    end

    -- 表外招式断言：服务端广播过的招式名都在该鱼的逐招表行集合里。
    local function noMovesOutsideTable(fishKey)
        local allowed = {}
        for _, row in ipairs(BossMoves.ForFish(fishKey)) do allowed[row.Move] = true end
        for _, notice in ipairs(env.notices) do
            if notice.kind == 'lock' then
                assert.truthy(allowed[notice.move], '表外招式：' .. tostring(notice.move))
            end
        end
    end

    it('条款 12-07：电鳗 6 移速、5 米内每秒 10 伤害，5 次后睡 10 秒且睡眠中可受击', function()
        local row = BossMoves.Get('eel', 'discharge')
        assert.same(6, Cfg.Fish.eel.Speed)
        assert.same(5, row.Range)
        assert.same(10, row.Damage.Value)
        assert.same(1, row.Schedule.Sec)
        assert.same(5, row.Schedule.DurationSec / row.Schedule.Sec)
        assert.same(10, row.Schedule.RestSec)
        -- 引擎点火（CastFish）在夹具里代替，伤害仍走真实 MgrVitals 与逐招表数值。
        env.mgr.Ability = {
            EquipFish = function() end,
            RemoveFish = function() end,
            CastFish = function(fish)
                local hit = env.vitals:NewHit(fish, 'fishAttack')
                env.vitals:ApplyHit(hit, env.player, row.Damage.Value)
                return true
            end,
        }
        env.moveFish, savedAbility = 'eel', env.mgr.Ability
        local start = hp()
        local attackStart = env.now
        local fish = dropNear('eel', 4) -- 5 米放电圈内
        -- 夹具的 Rotation 没有 __mul；侧躺表现只需要一次可乘的旋转值。
        local rotMt = getmetatable(fish.CombatRotation) or {}
        rotMt.__mul = function(a) return a end
        setmetatable(fish.CombatRotation, rotMt)
        env:advance(4.7)
        assert.same(start - 5 * 10, hp(), '放电不是每秒 10、共 5 次')
        assert.same(5, fish.Discharges)
        warningIsRow('discharge')
        env:advance(5.2)
        assert.same('sleeping', fish.State)
        need(math.abs((fish.WakeAt - attackStart) - 15) < 0.4,
            '放电 5 秒后应睡眠 10 秒，实际窗口 %s', fish.WakeAt - attackStart)
        need(math.abs((fish.WakeAt - env.now) - 10) < 0.4,
            '入睡后应保持 10 秒，实际 %s', fish.WakeAt - env.now)
        assert.same(start - 50, hp(), '睡眠期间不应继续放电')
        -- 「睡眠中可受击」：服务端受击/死亡入口在睡眠态仍然成立。
        assert.is_not_nil(env.mgr:TakeKilled(fish))
        noMovesOutsideTable('eel')
    end)

    it('条款 12-08：鳄雀鳝头部追咬 30、间隔 1.5 秒', function()
        local row = BossMoves.Get('gar', 'bite')
        local id = idOf('gar')
        assert.same(30, row.Damage.Value)
        assert.same(1.5, row.Schedule.Sec)
        env.moveFish = 'gar'
        local start = hp()
        dropNear(id, 1.5)
        env:advance(3.2)
        assert.same(start - 2 * 30, hp(), '追咬不是每 1.5 秒 30')
        local notices = warningIsRow('bite')
        assert.same(3, #notices, '3.2 秒内应按 1.5 秒间隔起咬三次')
        noMovesOutsideTable('gar')
    end)

    it('条款 12-09：绕到后身咬空，只有头部区结算命中', function()
        local id = idOf('gar')
        env.moveFish = 'gar'
        local start = hp()
        local fish = dropNear(id, 1.5)
        env:advance(0.2) -- 已锁定朝向并起咬
        local p = fish.Carrier.Body.Position
        env.player.Character.Position = env.vec(p.x, p.y, p.z - 1.5) -- 绕到后身，仍在咬距内
        local before = hp()
        env:advance(1.6)
        assert.same(before, hp(), '后身不应结算咬伤')
        assert.same(start, before, '起咬预警阶段不应提前扣血')
        local clears = {}
        for _, notice in ipairs(env.notices) do
            if notice.kind == 'clear' and notice.reason == 'miss' then clears[#clears + 1] = notice end
        end
        assert.truthy(#clears >= 1, '绕后咬空没有走 miss 清算')
    end)

    it('条款 12-10：虾霸两下蟹钳接尾刺击飞，基础攻击 20、节拍 2 秒', function()
        local claw, tail = BossMoves.Get('shrimp', 'claw'), BossMoves.Get('shrimp', 'tail')
        assert.same(20, claw.Damage.Value)
        assert.same(20, tail.Damage.Value)
        assert.same(2, claw.Schedule.Sec)
        env.moveFish = 'shrimp'
        local start = hp()
        dropNear('fish15Elite', 1.5)
        env:advance(6.2)
        assert.same(start - 3 * 20, hp(), '三下伤害不是 20')
        local names = {}
        for _, notice in ipairs(env.notices) do
            if notice.kind == 'lock' then names[#names + 1] = notice.move end
        end
        assert.same({ 'claw', 'claw', 'tail' }, names, '双击后接尾刺的组合不对')
        warningIsRow('claw')
        warningIsRow('tail')
        noMovesOutsideTable('shrimp')
    end)

    it('条款 12-11：虾霸活动 15 秒眩晕 5 秒，取代旧 20 秒', function()
        local row = BossMoves.Get('shrimp', 'claw')
        assert.same(15, row.Schedule.ActivitySec)
        assert.same(5, row.Schedule.StunSec)
        env.moveFish = 'shrimp'
        local fish = dropNear('fish15Elite', 1.5)
        env:advance(15.1)
        assert.same('stunned', fish.State)
        need(math.abs(fish.WakeAt - 20) < 1e-6, '虾霸应到 20 秒醒来，实际 %s', fish.WakeAt)
        local before = hp()
        env:advance(19.9)
        assert.same(before, hp(), '眩晕期间不应出招')
        env:advance(20.1)
        assert.same('combat', fish.State, '5 秒后没有醒来')
    end)

    it('条款 12-15：帝王蟹每 5 秒左右各 3 下、每下 0.2 秒 15 伤害', function()
        local row = BossMoves.Get('kingCrab', 'jab')
        assert.same(15, row.Damage.Value)
        assert.same(5, row.Schedule.Sec)
        assert.same(6, row.Schedule.Count)
        assert.same(0.2, row.Schedule.StepSec)
        env.moveFish = 'kingCrab'
        local start = hp()
        dropNear('fish23Elite', 1.5)
        env:advance(1.8)
        assert.same(start - 6 * 15, hp(), '一轮乱刺不是左右各三下、每下 15')
        warningIsRow('jab')
        env:advance(6.2)
        assert.truthy(start - hp() >= 7 * 15, '5 秒后没有第二轮乱刺')
        noMovesOutsideTable('kingCrab')
    end)

    it('条款 12-16：帝王蟹活动 30 秒眩晕 5 秒', function()
        local row = BossMoves.Get('kingCrab', 'jab')
        assert.same(30, row.Schedule.ActivitySec)
        assert.same(5, row.Schedule.StunSec)
        env.moveFish = 'kingCrab'
        local fish = dropNear('fish23Elite', 1.5)
        env:advance(30.1)
        assert.same('stunned', fish.State)
        need(math.abs(fish.WakeAt - 35) < 1e-6, '帝王蟹应到 35 秒醒来，实际 %s', fish.WakeAt)
        local before = hp()
        env:advance(34.9)
        assert.same(before, hp(), '眩晕期间不应乱刺')
        env:advance(35.1)
        assert.same('combat', fish.State)
    end)

    it('条款 12-17：蟹老板正面双击 20、冷却 4 秒', function()
        local row = BossMoves.Get('crabBoss', 'pinch')
        assert.same(20, row.Damage.Value)
        assert.same(4, row.Schedule.Sec)
        env.moveFish = 'crabBoss'
        local start = hp()
        dropNear('fish24Boss', 1.5)
        env:advance(1)
        assert.same(start - 2 * 20, hp(), '双击不是每下 20')
        warningIsRow('pinch')
        env:advance(4.8)
        assert.truthy(start - hp() >= 3 * 20, '4 秒冷却后没有再双击')
        noMovesOutsideTable('crabBoss')
    end)

    it('条款 12-18：蟹老板每 30 秒冲撞一次，线形预警先于命中', function()
        local row = BossMoves.Get('crabBoss', 'charge')
        assert.same(30, row.Schedule.Sec)
        assert.same(20, row.Damage.Value)
        env.moveFish = 'crabBoss'
        local fish = dropNear('fish24Boss', 1.5)
        fish.PinchAt, fish.SpecialAt = math.huge, math.huge -- 只观察冲撞，压住同鱼其它招
        local before = hp()
        env:advance(29.9)
        assert.same(0, #locks('charge'), '冲撞提前发动')
        env:advance(30.1)
        assert.same(before, hp(), '冲撞起手帧不应先结算')
        warningIsRow('charge')
        env:advance(30.7)
        assert.same(before - 20, hp(), '冲撞命中不是 20')
    end)

    it('条款 12-19：蟹老板每 25 秒旋转 5 秒、碰触 30，圆形预警先于首段', function()
        local row = BossMoves.Get('crabBoss', 'spin')
        assert.same(25, row.Schedule.Sec)
        assert.same(5, row.Schedule.DurationSec)
        assert.same(30, row.Damage.Value)
        env.moveFish = 'crabBoss'
        local fish = dropNear('fish24Boss', 1.5)
        fish.PinchAt, fish.ChargeAt = math.huge, math.huge -- 只观察旋转，压住同鱼其它招
        env:advance(24.9)
        assert.same(0, #locks('spin'), '旋转提前发动')
        local before = hp()
        env:advance(25.1)
        assert.same(before, hp(), '旋转预警帧不应先结算')
        warningIsRow('spin')
        env:advance(30.2)
        assert.same(before - 5 * 30, hp(), '旋转不是每秒 30、持续 5 秒')
    end)
end)
