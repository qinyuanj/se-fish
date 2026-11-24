-- 条款 6-08（docs/acceptance/06-combat-and-growth.md）：
-- 霰弹枪每次击发打出 5 发弹丸，每发独立判定命中并各自结算伤害。
--
-- 业务入口：tests/support/weapon_world.lua（ctx:equip + ctx:attack + ctx:advance），
-- 只观察 ctx.rays、ctx.applied、回复 payload 等外部结果。

local Weapon = require('tests.support.weapon_world')
local GameCfg = require('common.game_cfg')

local atan2 = math.atan2 or math.atan

local function fail(fmt, ...)
    assert.is_true(false, string.format(fmt, ...))
end

local function ray_length(d)
    return math.sqrt(d.x * d.x + d.y * d.y + d.z * d.z)
end

local function yaw_deg_from_z(d)
    return math.deg(atan2(d.x, d.z))
end

local function total_damage_for(applied, target)
    local sum, count = 0, 0
    for _, entry in ipairs(applied) do
        if entry.target == target then
            sum = sum + entry.amount
            count = count + 1
        end
    end
    return sum, count
end

describe('条款 6-08：霰弹枪 5 发弹丸水平均匀扇形散布与独立命中结算', function()
    local ctx
    local playerA
    local playerB

    before_each(function()
        playerA = Weapon.player(43)
        playerB = Weapon.player(44)
        ctx = Weapon.new({
            players = {
                { player = Weapon.player(42) },
                { player = playerA },
                { player = playerB },
            },
        })
        ctx:set_up()
        ctx:equip(ctx.player, 'item138')
    end)

    after_each(function()
        ctx:tear_down()
    end)

    it('条款 6-08：朝 (0,0,1) 击发消耗 1 发弹药并发射 5 条等长水平均匀扇形射线（-6°/-3°/0°/+3°/+6°）', function()
        local reply = ctx:attack(ctx.player, { aim = { x = 0, y = 0, z = 1 } })
        if not (reply and reply.ok) then
            fail('霰弹枪击发失败: %s', tostring(reply and reply.reason))
        end
        assert.are.equal(1, reply.ammo)
        assert.are.equal(5, #ctx.rays)

        local expected_range = GameCfg.Ability.GunShared.Range
        local expected_angles = { -6, -3, 0, 3, 6 }
        for i = 1, 5 do
            local ray = ctx.rays[i]
            assert.near(expected_range, ray_length(ray.d), 1e-6)
            assert.near(0, ray.d.y, 1e-6)
            assert.near(expected_angles[i], yaw_deg_from_z(ray.d), 1e-6)
        end
    end)

    it('条款 6-08：同一击发中不同弹丸可命中不同目标且各生成独立 hit 结算', function()
        ctx.rayHit = function(_, _, idx)
            if idx == 1 or idx == 2 then
                return { Instance = playerA.Character }
            elseif idx == 4 or idx == 5 then
                return { Instance = playerB.Character }
            end
            return nil
        end

        local reply = ctx:attack(ctx.player, { aim = { x = 0, y = 0, z = 1 } })
        if not (reply and reply.ok) then
            fail('霰弹枪击发失败: %s', tostring(reply and reply.reason))
        end

        assert.are.equal(5, #ctx.rays)
        assert.are.equal(4, #ctx.applied)

        local sumA, countA = total_damage_for(ctx.applied, playerA)
        local sumB, countB = total_damage_for(ctx.applied, playerB)
        assert.are.equal(2, countA)
        assert.are.equal(40, sumA)
        assert.are.equal(2, countB)
        assert.are.equal(40, sumB)

        local seen_ids = {}
        for _, entry in ipairs(ctx.applied) do
            if seen_ids[entry.hit.id] then
                fail('发现重复 hit.id: %s', tostring(entry.hit.id))
            end
            seen_ids[entry.hit.id] = true
        end
    end)

    it('条款 6-08：部分弹丸命中、部分脱靶或命中墙体时仅对命中目标的弹丸结算伤害', function()
        local wall = { Name = 'Wall' }
        ctx.rayHit = function(_, _, idx)
            if idx == 2 or idx == 5 then
                return { Instance = playerA.Character }
            elseif idx == 3 then
                return { Instance = wall }
            end
            return nil
        end

        local reply = ctx:attack(ctx.player, { aim = { x = 0, y = 0, z = 1 } })
        if not (reply and reply.ok) then
            fail('霰弹枪击发失败: %s', tostring(reply and reply.reason))
        end

        assert.are.equal(5, #ctx.rays)
        assert.are.equal(2, #ctx.applied)
        local sumA, countA = total_damage_for(ctx.applied, playerA)
        assert.are.equal(2, countA)
        assert.are.equal(40, sumA)
    end)

    it('条款 6-08：5 发全中同一目标时各自结算，且远程满级（+50%）每发 30 伤共 150 伤', function()
        ctx.rayHit = { Instance = playerA.Character }

        local reply1 = ctx:attack(ctx.player, { aim = { x = 0, y = 0, z = 1 } })
        if not (reply1 and reply1.ok) then
            fail('第一次击发失败: %s', tostring(reply1 and reply1.reason))
        end
        local sum1, count1 = total_damage_for(ctx.applied, playerA)
        assert.are.equal(5, count1)
        assert.are.equal(100, sum1)

        ctx.applied = {}
        ctx.data.extra.growth.upgrades.ranged = 5
        ctx:advance(GameCfg.Ability.Guns.item138.IntervalSec)

        local reply2 = ctx:attack(ctx.player, { aim = { x = 0, y = 0, z = 1 } })
        if not (reply2 and reply2.ok) then
            fail('满级远程第二次击发失败: %s', tostring(reply2 and reply2.reason))
        end
        local sum2, count2 = total_damage_for(ctx.applied, playerA)
        assert.are.equal(5, count2)
        for _, entry in ipairs(ctx.applied) do
            assert.are.equal(30, entry.amount)
        end
        assert.are.equal(150, sum2)
    end)

    it('条款 6-08：全脱靶消耗弹药但 0 伤害；冷却期内与空匣自动换弹时不发射任何射线', function()
        ctx.rayHit = nil

        -- 第 1 发全脱靶：消耗 1 发弹药，0 伤害
        local r1 = ctx:attack(ctx.player, { aim = { x = 0, y = 0, z = 1 } })
        if not (r1 and r1.ok) then
            fail('第 1 次击发应成功: %s', tostring(r1 and r1.reason))
        end
        assert.are.equal(1, r1.ammo)
        assert.are.equal(5, #ctx.rays)
        assert.are.equal(0, #ctx.applied)

        -- 冷却期内击发被拒且不发射射线
        ctx.rays = {}
        local r_cd = ctx:attack(ctx.player, { aim = { x = 0, y = 0, z = 1 } })
        assert.is_false(r_cd.ok)
        assert.are.equal('cooldown', r_cd.reason)
        assert.are.equal(0, #ctx.rays)

        -- 冷却结束打空第 2 发
        ctx:advance(GameCfg.Ability.Guns.item138.IntervalSec)
        local r2 = ctx:attack(ctx.player, { aim = { x = 0, y = 0, z = 1 } })
        if not (r2 and r2.ok) then
            fail('第 2 次击发应成功: %s', tostring(r2 and r2.reason))
        end
        assert.are.equal(0, r2.ammo)

        -- 空匣再击发触发自动换弹且不发射射线
        ctx:advance(GameCfg.Ability.Guns.item138.IntervalSec)
        ctx.rays = {}
        local r_empty = ctx:attack(ctx.player, { aim = { x = 0, y = 0, z = 1 } })
        assert.is_false(r_empty.ok)
        assert.are.equal('empty', r_empty.reason)
        assert.is_true(r_empty.autoReload)
        assert.are.equal(0, #ctx.rays)
    end)
end)
