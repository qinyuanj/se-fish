-- 条款 12-13 / 12-14 / 12-21 / 12-24 / 12-26 / 12-28 / 12-30 / 12-31 / 12-32 / 12-33 / 12-34
-- 远程与俯冲组逐招表（spec #249 / ticket #258）。
--
-- 被测入口：FishTree:spawn_landed + drop 放下鱼，逐帧 update 推进服务端权威时钟；
-- 只观察玩家可观察的三个面：玩家血量（MgrVitals 结算）、GarBiteNotice 广播载荷（客户端只画预警）、
-- 逐招表公开行（common/cfg/boss_moves.lua）。测试进程不加载任何客户端命中代码：
-- 伤害仍然落地，证明远程投射物命中判定不依赖客户端。
--
-- 失败方式（编码前列出）：
--   1. 远程 / 俯冲段缺行、落点与范围不可辨、预警形状与表不一致；
--   2. 服务端仍读 GameCfg 的旧数值，改表不改伤害（表外还有第二份数值）；
--   3. 预警未先于命中，或结算不落在预警锁定的落点；
--   4. 风神翼龙投掷 100 / 俯冲 260 的映射被静默丢弃。

local Cfg = require('common.game_cfg')
local Islet = require('tests.support.isle_combat')
local BossMoves = require('common.cfg.boss_moves')
local GarBiteNotice = require('common.gar_bite_notice')

local function need(cond, ...)
    if not cond then error(string.format(...), 2) end
end

-- 逐招表里的远程 / 俯冲段：投送方式四类 + 落点口径 + 条款 ID。
local GROUP = {
    { key = 'dragon', id = 'fish16Boss', zone = 2,
      moves = { { name = 'rain', delivery = 'projectile', landing = 'self', clause = '12-13' },
                { name = 'dive', delivery = 'diveLine', landing = 'target', clause = '12-14' } } },
    { key = 'swordfish', id = 'fish31Elite', zone = 4,
      moves = { { name = 'jump', delivery = 'diveArea', landing = 'random', clause = '12-21' } } },
    { key = 'shark', id = 'fish32Boss', zone = 4,
      moves = { { name = 'jump', delivery = 'diveArea', landing = 'random', clause = '12-24' } } },
    { key = 'walrus', id = 'fish39Elite', zone = 5,
      moves = { { name = 'charge', delivery = 'sweep', landing = 'target', clause = '12-26' } } },
    { key = 'orca', id = 'fish40Boss', zone = 5,
      moves = { { name = 'roar', delivery = 'projectile', landing = 'target', clause = '12-28' },
                { name = 'jump', delivery = 'diveArea', landing = 'random', clause = '12-30' } } },
    { key = 'fish47Elite', id = 'fish47Elite', zone = 6,
      moves = { { name = 'dive', delivery = 'diveLine', landing = 'target', clause = '12-31' } } },
    { key = 'fish48Boss', id = 'fish48Boss', zone = 6,
      moves = { { name = 'throw', delivery = 'projectile', landing = 'target', clause = '12-32' },
                { name = 'dive', delivery = 'diveLine', landing = 'target', clause = '12-33' } } },
}

-- 每只鱼 §12 的全部招式；远程 / 俯冲段只是在这份集合上补映射，不许添招（12-05）。
local ALL_MOVES = {
    dragon = { 'dive', 'peck', 'rain' }, swordfish = { 'jump', 'swing' },
    shark = { 'jump', 'roll', 'sweep' }, walrus = { 'charge', 'swing' },
    orca = { 'claw', 'jump', 'roar', 'tail' }, fish47Elite = { 'dive' },
    fish48Boss = { 'dive', 'throw' },
}

describe('第 12 节 远程与俯冲组逐招表', function()
    local env, restore, hits, savedAbility

    before_each(function()
        restore, hits = {}, {}
        savedAbility = package.loaded['server.ability_api']
        package.loaded['server.ability_api'] = nil
    end)

    after_each(function()
        for index = #restore, 1, -1 do restore[index]() end
        if env then env:tear_down() end
        package.loaded['server.ability_api'] = savedAbility
        env = nil
    end)

    -- 放下一条鱼；同一用例换鱼时先拆掉的上一份世界，避免多个服务端时钟同时推进。
    local function drop(id, zone)
        if env then env:tear_down() end
        env = Islet.new(zone)
        env.player.Character.Controller.Health = 100000
        local p = Islet.shore_dry_point(zone)
        env.player.Character.Position = env.vec(p.x, p.y, p.z)
        local controller = env.player.Character.Controller
        local take = controller.TakeDamage
        controller.TakeDamage = function(self, damage)
            hits[#hits + 1] = { at = env.now, damage = damage }
            return take(self, damage)
        end
        return env:drop(id)
    end

    local function lockOf(move)
        for _, notice in ipairs(env.notices) do
            if notice.kind == 'lock' and notice.move == move then return notice end
        end
        return nil
    end

    local function untilLock(move, limit)
        while env.now < limit and not lockOf(move) do env:advance(env.now + 0.05) end
        local notice = lockOf(move)
        need(notice ~= nil, '招式 %s 在 %s 秒内没有起手预警', move, tostring(limit))
        return notice
    end

    local function hasHit(value, since)
        for _, hit in ipairs(hits) do
            if hit.damage == value and (not since or hit.at >= since) then return true end
        end
        return false
    end

    -- 把逐招表的一格改成哨兵值：服务端若真以表为准，落地伤害必须跟着变。
    local function sentinel(key, move, value)
        local row = BossMoves.get(key, move)
        need(row ~= nil, '逐招表漏了 %s.%s', key, move)
        local old = row.Damage.Value
        row.Damage.Value = value
        restore[#restore + 1] = function() row.Damage.Value = old end
    end

    local function near(a, b, eps)
        return type(a) == 'number' and type(b) == 'number' and math.abs(a - b) <= (eps or 1e-6)
    end

    it('条款 12-04 / 12-05：七只鱼的远程与俯冲段逐招表投送方式、落点与范围可辨，表外不新增招式', function()
        local deliveries = { projectile = true, sweep = true, diveLine = true, diveArea = true }
        local landings = { self = true, target = true, random = true }
        for _, group in ipairs(GROUP) do
            local names = {}
            for _, row in ipairs(BossMoves.for_fish(group.key)) do names[#names + 1] = row.Move end
            table.sort(names)
            assert.same(ALL_MOVES[group.key], names, group.key .. ' 的招式集合与 §12 不符')
            for _, entry in ipairs(group.moves) do
                local row = BossMoves.get(group.key, entry.name)
                need(row ~= nil, '逐招表漏了 %s.%s', group.key, entry.name)
                need(row.Clause == entry.clause, '%s.%s 的条款 ID 应为 %s', group.key, entry.name, entry.clause)
                need(deliveries[row.Delivery], '%s.%s 的投送方式不可辨', group.key, entry.name)
                need(landings[row.Landing], '%s.%s 的落点口径不可辨', group.key, entry.name)
                need(row.Damage and type(row.Damage.From) == 'string', '%s.%s 缺伤害出处', group.key, entry.name)
                need(type(row.Range) == 'number' and row.Range > 0, '%s.%s 缺命中范围', group.key, entry.name)
                need(row.Warning and row.Warning.WindupSec > 0, '%s.%s 缺起手预警', group.key, entry.name)
                need(row.Dodge and row.Dodge.Kind ~= 'none', '%s.%s 缺单人躲避窗口', group.key, entry.name)
            end
        end
        -- 表 → 服务端参数的映射必须是公开入口；改表数值必须能改到服务端结算用的字段。
        need(type(BossMoves.combat_params) == 'function', '逐招表缺少 CombatParams 映射入口')
        local params = BossMoves.combat_params({}, 'dragon')
        assert.is_true(near(params.RainRadius, BossMoves.get('dragon', 'rain').Range))
        assert.is_true(near(params.RainDamage, BossMoves.get('dragon', 'rain').Damage.Value))
    end)

    it('条款 12-13 / 12-14：小白龙雨云与俯冲分别按表结算，预警锁定落点后才命中', function()
        sentinel('dragon', 'rain', 73)
        sentinel('dragon', 'dive', 47)
        local fish = drop('fish16Boss', 2)
        local rainLock = untilLock('rain', 31)
        local rainRow = BossMoves.get('dragon', 'rain')
        assert.same('circle', rainLock.shape)
        assert.same(rainRow.Range, rainLock.range)
        assert.is_true(GarBiteNotice.valid(rainLock))
        assert.is_false(hasHit(73), '雨云预警未发就先结算了伤害')
        env:advance(env.now + 1.2)
        assert.is_true(hasHit(73), '雨云伤害没有按表内数值结算')

        local diveLock = untilLock('dive', 38)
        local diveRow = BossMoves.get('dragon', 'dive')
        assert.same(diveRow.Range, diveLock.range, '俯冲预警范围与表不符')
        local dest = fish.Move and fish.Move.destination
        need(dest ~= nil, '俯冲没有锁定落点')
        assert.is_true(near(dest.x, diveLock.position.x))
        assert.is_true(near(dest.z, diveLock.position.z))
        env.player.Character.Position = env.vec(dest.x, dest.y, dest.z)
        env:advance(env.now + 2.2)
        assert.is_true(hasHit(47), '俯冲没有按表内数值在锁定落点结算')
    end)

    it('条款 12-21 / 12-24：剑鱼与三头鲨的落地范围按各自的表行结算，落点即预警点', function()
        for _, group in ipairs({ GROUP[2], GROUP[3] }) do
            local key, id, zone, mark = group.key, group.id, group.zone,
                (group.key == 'swordfish' and 101 or 201)
            sentinel(key, 'jump', mark)
            local fish = drop(id, zone)
            local notice = untilLock('jump', 55)
            local row = BossMoves.get(key, 'jump')
            assert.same('circle', notice.shape)
            assert.same(row.Range, notice.range)
            assert.is_false(hasHit(mark), '高跃预警未发就先结算了落地伤害')
            local dest = fish.Move and fish.Move.destination
            need(dest ~= nil, '高跃没有锁定落点')
            assert.is_true(near(dest.x, notice.position.x))
            assert.is_true(near(dest.z, notice.position.z))
            env.player.Character.Position = env.vec(dest.x, dest.y, dest.z)
            env:advance(env.now + 1.7)
            assert.is_true(hasHit(mark), key .. ' 的落地伤害没有按表内数值结算')
        end
    end)

    it('条款 12-26：海象直线突击的走廊预警与命中伤害均取自逐招表', function()
        sentinel('walrus', 'charge', 121)
        local fish = drop('fish39Elite', 5)
        local notice = untilLock('charge', 41)
        local row = BossMoves.get('walrus', 'charge')
        assert.same(row.Warning.Kind, notice.shape, '直线突击的预警形状与表不符')
        assert.same(row.Schedule.Distance, notice.range, '走廊长度与表不符')
        assert.is_false(hasHit(121), '突击起手帧不得结算')
        local facing = fish.facing or { x = 0, z = 1 }
        env.player.Character.Position = env.vec(notice.position.x + facing.x * 10,
            notice.position.y, notice.position.z + facing.z * 10)
        env:advance(env.now + 3.2)
        assert.is_true(hasHit(121), '突击没有按表内数值在走廊上结算')
    end)

    it('条款 12-28 / 12-30：虎鲸虎啸与鲸跃各自映射伤害，服务端独立结算', function()
        sentinel('orca', 'roar', 31)
        sentinel('orca', 'jump', 241)
        drop('fish40Boss', 5)
        local roar = untilLock('roar', 11)
        local roarRow = BossMoves.get('orca', 'roar')
        assert.same(roarRow.Range, roar.range)
        assert.is_false(hasHit(31), '虎啸预警未发就先结算')
        env:advance(env.now + 1.2)
        assert.is_true(hasHit(31), '虎啸没有按表内数值结算')

        local jump = untilLock('jump', 27)
        local jumpRow = BossMoves.get('orca', 'jump')
        assert.same(jumpRow.Range, jump.range)
        assert.is_false(hasHit(241), '鲸跃预警未发就先结算')
        env.player.Character.Position = env.vec(jump.position.x, jump.position.y, jump.position.z)
        env:advance(env.now + 1.7)
        assert.is_true(hasHit(241), '鲸跃没有按表内数值在落点结算')
    end)

    it('条款 12-31 / 12-32 / 12-33 / 12-34：白头鹰俯冲与风神翼龙投掷 / 追踪俯冲的独立伤害不丢映射', function()
        -- 12-31 / 12-32：这两只鱼声明了 Combat 标签，但逐招表按鱼种 Id 登记；
        -- 反查必须落回表里的行，否则预警形状与范围会静默退回默认值。
        assert.same('fish47Elite', BossMoves.key_of({ Combat = 'eagle' }, 'fish47Elite'))
        assert.same('fish48Boss', BossMoves.key_of({ Combat = 'pterosaur' }, 'fish48Boss'))
        assert.same('eel', BossMoves.key_of({ Combat = 'eel' }, 'fish22Elite'))
        assert.same(100, BossMoves.get('fish48Boss', 'throw').Damage.Value, '12-32 的正文投掷伤害丢失')
        assert.same(260, BossMoves.get('fish48Boss', 'dive').Damage.Value, '12-34 的正文俯冲伤害不得静默丢弃')
        sentinel('fish47Elite', 'dive', 31)
        drop('fish47Elite', 6)
        local notice = untilLock('airDive', 21)
        local row = BossMoves.get('fish47Elite', 'dive')
        assert.same(row.Range, notice.range)
        assert.is_false(hasHit(31), '白头鹰俯冲预警未发就先结算')
        env:advance(env.now + 2)
        assert.is_true(hasHit(31), '白头鹰俯冲没有按表内数值结算')
    end)

    it('条款 12-32 / 12-34：风神翼龙投掷 100 与俯冲 260 分别走各自的落点与范围', function()
        sentinel('fish48Boss', 'throw', 101)
        sentinel('fish48Boss', 'dive', 261)
        drop('fish48Boss', 6)
        local thrown = untilLock('airThrow', 5)
        local throwRow = BossMoves.get('fish48Boss', 'throw')
        assert.same(throwRow.Range, thrown.range)
        assert.is_false(hasHit(101), '投掷预警未发就先结算')
        env:advance(env.now + 1.3)
        assert.is_true(hasHit(101), '投掷伤害没有按表内数值结算')

        local dove = untilLock('airDive', 21)
        local diveRow = BossMoves.get('fish48Boss', 'dive')
        assert.same(diveRow.Range, dove.range)
        assert.is_false(hasHit(261), '俯冲预警未发就先结算')
        env.player.Character.Position = env.vec(dove.position.x, dove.position.y, dove.position.z)
        env:advance(env.now + 2)
        assert.is_true(hasHit(261), '追踪俯冲伤害没有按表内数值结算')
    end)

    it('条款 12-06：普通来源精英与首领在待举/举起时不战斗，首次放下进入战斗且爆破鱼不进战斗', function()
        local function checkLiftToCombat(id)
            if env then env:tear_down() end
            env = Islet.new(5)
            local p = Islet.shore_dry_point(5)
            env.player.Character.Position = env.vec(p.x, p.y, p.z)
            local fish = assert(env.mgr:spawn_landed(env.player, { fishId = id, mult = 1 }, env.player.Character.Position))
            assert.same(env.mgr.State.await_lift, fish.State, id .. ' 上岸后应处于待举起状态')
            env:advance(env.now + 0.5)
            assert.same(env.mgr.State.await_lift, fish.State, id .. ' 待举起期间不得进入战斗')

            fish.carrier.body.OnLiftedBegin:Fire(env.player.Character)
            assert.same(env.mgr.State.held, fish.State, id .. ' 举起后应处于持有状态')
            env:advance(env.now + 0.5)
            assert.same(env.mgr.State.held, fish.State, id .. ' 举起期间不得进入战斗')

            assert.is_true(env.mgr:drop(env.player), id .. ' 放下失败')
            assert.same(env.mgr.State.Combat, fish.State, id .. ' 首次放下后应进入战斗')
        end

        checkLiftToCombat('fish39Elite')
        checkLiftToCombat('fish40Boss')

        local blast = assert(env.mgr:spawn_blast_fish('fish39Elite', 1, env.player.Character.Position, env.player))
        assert.same(env.mgr.State.wild, blast.State, '爆破鱼生成后应处于 wild 状态')
        env:advance(env.now + 1.0)
        assert.is_not_equal(env.mgr.State.Combat, blast.State, '爆破鱼不得进入战斗状态')
    end)

    it('条款 12-29：虎鲸甩尾无目标不空放且保留至目标出现，周期、范围与伤害均以逐招表为准', function()
        -- ① 无有效目标推进超 10 秒不空放，目标出现后受招式互斥约束并立即在下次可攻击时触发。
        drop('fish40Boss', 5)
        env.player.Character.Controller.Health = 0
        env:advance(12)
        assert.is_nil(lockOf('roar'), '无有效目标时虎啸不得空放')
        assert.is_nil(lockOf('tail'), '无有效目标时甩尾不得空放')

        env.player.Character.Controller.Health = 100000
        env:advance(env.now + 0.1)
        assert.is_not_nil(lockOf('roar'), '目标出现后优先级更高的虎啸应先起手')
        assert.is_nil(lockOf('tail'), '招式互斥期间甩尾不得同时起手')
        local tailNotice = untilLock('tail', env.now + 2)
        assert.is_not_nil(tailNotice, '虎啸结束后保留的甩尾应立即起手')

        -- ② 哨兵篡改逐招表 Damage.Value / Range / Schedule.Sec，验证首次/后续周期、范围与伤害均以表为准。
        local tailRow = BossMoves.get('orca', 'tail')
        local roarRow = BossMoves.get('orca', 'roar')
        local oldDamage, oldRange, oldTailSec, oldRoarSec =
            tailRow.Damage.Value, tailRow.Range, tailRow.Schedule.Sec, roarRow.Schedule.Sec
        tailRow.Damage.Value = 167
        tailRow.Range = 7
        tailRow.Schedule.Sec = 6
        roarRow.Schedule.Sec = 99
        restore[#restore + 1] = function()
            tailRow.Damage.Value = oldDamage
            tailRow.Range = oldRange
            tailRow.Schedule.Sec = oldTailSec
            roarRow.Schedule.Sec = oldRoarSec
        end

        hits = {}
        local fish = drop('fish40Boss', 5)
        env:advance(5.5)
        assert.is_nil(lockOf('tail'), '未到篡改后的首次周期 6 秒不得提前起手')
        local firstTail = untilLock('tail', 6.5)
        assert.same(7, firstTail.range, '甩尾预警范围应以逐招表为准')

        local facing = fish.facing or { x = 0, z = 1 }
        local fpos = fish.carrier.body.Position
        env.player.Character.Position = env.vec(fpos.x - facing.x * 5.5, fpos.y, fpos.z - facing.z * 5.5)
        env:advance(env.now + 1.0)
        assert.is_true(hasHit(167), '甩尾应按逐招表扩展后的范围与伤害命中后方目标')

        local function tailCount()
            local count = 0
            for _, notice in ipairs(env.notices) do
                if notice.kind == 'lock' and notice.move == 'tail' then count = count + 1 end
            end
            return count
        end
        assert.same(1, tailCount())
        env:advance(11.5)
        assert.same(1, tailCount(), '未到篡改后的后续周期不得提前二次起手')
        env:advance(12.5)
        assert.same(2, tailCount(), '后续甩尾周期应以逐招表为准')
    end)
end)
