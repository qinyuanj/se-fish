-- 条款 6-13（docs/acceptance/06-combat-and-growth.md，#293）：
-- 爆炸落在水域时，先随机生成 3 到 5 条当地 1 级竿可钓的鱼（排除首领专用饵的强制召唤行），再结算爆炸伤害。
--
-- 业务入口：tests/support/weapon_world.lua（ctx:throw + ctx:advance），只观察 ctx.spawnedFish、ctx.applied 等外部结果。
--
-- 失败方式（编码前列出）：
--   1. 候选池额外限制 Grade == "normal"，错误排除当地 1 级竿可钓的极品与精英鱼；
--   2. 高竿级行（RodLevel > 1）漏入候选池；
--   3. 首领专用饵强制召唤行仅靠 Grade ~= "boss" 隐含排除，若首领行或强召行品质为 normal 时漏出；
--   4. 权重抽取边界错位或数量未落在 3–5 区间；
--   5. 爆炸伤害先于保底鱼生成结算，或新生成的鱼未被随后的爆炸伤害命中；
--   6. 无合法候选鱼时抛错导致爆炸伤害未结算。

local Weapon = require('tests.support.weapon_world')
local GameCfg = require('common.game_cfg')

local function fail(fmt, ...)
    assert.is_true(false, string.format(fmt, ...))
end

local function flight_sec()
    return GameCfg.Ability.Throw.FlightSec
end

describe('条款 6-13：水中爆炸候选鱼生成与先鱼后伤', function()
    local ctx
    local saved_zones
    local saved_fish

    local function set_zone(zone_id, center)
        ctx:set_water_zones({ {
            Id = zone_id,
            Center = { x = center.x, y = center.y - 1, z = center.z },
            HalfXZ = 6,
            SurfaceY = center.y,
        } })
        ctx.player.Character.Position = { x = center.x, y = 2, z = center.z - 8 }
    end

    local function throw_at(center, roll)
        local slot = ctx:give_explosive(ctx.player, 'item143')
        ctx.random = function(a, b)
            if a and b then return a end
            return roll
        end
        local before = #ctx.spawnedFish
        local reply = ctx:throw(ctx.player, slot, center)
        if not (reply and reply.ok) then
            fail('投掷爆炸物失败: %s', tostring(reply and reply.reason))
        end
        ctx:advance(flight_sec() + 0.01)
        local spawned = {}
        for i = before + 1, #ctx.spawnedFish do
            spawned[#spawned + 1] = ctx.spawnedFish[i]
        end
        return spawned
    end

    before_each(function()
        ctx = Weapon.new()
        ctx:set_up()
        saved_zones = {}
        saved_fish = {}
    end)

    after_each(function()
        for zone_id, value in pairs(saved_zones) do
            GameCfg.Casting.Zones[zone_id] = value == false and nil or value
        end
        for fish_id, snapshot in pairs(saved_fish) do
            if snapshot == false then
                GameCfg.Fish[fish_id] = nil
            else
                GameCfg.Fish[fish_id].Grade = snapshot.Grade
            end
        end
        ctx:tear_down()
    end)

    it('条款 6-13：鱼塘 1 级竿普通、极品、精英鱼均可入池且权重抽取语义不变', function()
        local center = { x = -11.75, y = 2.183, z = -12.25 }
        set_zone('WaterCircle2', center)

        -- WaterCircle2 总权重 = 130：
        -- tilapia(8)=8, carp(8)=16, knifeFish(8)=24, bass(32)=56, catfish(24)=80, goldfish(16)=96,
        -- eel(10)=106, item7(2)=108, item8(2)=110, item9(2)=112, item10(8)=120, item11(6)=126, item12(4)=130
        local probes = {
            { roll = 4 / 130, expected_id = 'tilapia', expected_grade = 'normal' },
            { roll = 40 / 130, expected_id = 'bass', expected_grade = 'normal' },
            { roll = 101 / 130, expected_id = 'eel', expected_grade = 'elite' },
            { roll = 107 / 130, expected_id = 'item7', expected_grade = 'rare' },
            { roll = 128 / 130, expected_id = 'item12', expected_grade = 'rare' },
        }

        local seen_grades = {}
        for _, probe in ipairs(probes) do
            local spawned = throw_at(center, probe.roll)
            if #spawned ~= GameCfg.Ability.Throw.FishMin then
                fail('预期生成 %d 条鱼，实际=%d', GameCfg.Ability.Throw.FishMin, #spawned)
            end
            for _, fish in ipairs(spawned) do
                if fish.fishId ~= probe.expected_id then
                    fail('roll=%.4f 预期抽中 %s，实际=%s', probe.roll, probe.expected_id, tostring(fish.fishId))
                end
                local species = GameCfg.Fish[fish.fishId]
                if not species or species.Grade ~= probe.expected_grade then
                    fail('鱼种 %s 品质预期 %s，实际=%s', tostring(fish.fishId), probe.expected_grade,
                        tostring(species and species.Grade))
                end
                seen_grades[species.Grade] = true
            end
        end

        if not (seen_grades.normal and seen_grades.rare and seen_grades.elite) then
            fail('普通/极品/精英未全部覆盖: normal=%s rare=%s elite=%s',
                tostring(seen_grades.normal), tostring(seen_grades.rare), tostring(seen_grades.elite))
        end
    end)

    it('条款 6-13：虾池覆盖 1 级竿普通与极品鱼并排除所有高竿级行', function()
        local center = { x = 100, y = 2.183, z = 100 }
        set_zone('shrimpPond.water', center)

        -- shrimpPond.water 1 级竿共 6 条（总权重 30）：
        -- shrimp(8), riverShrimp(8), crayfish(8), rareShrimp(2), rareRiverShrimp(2), rareCrayfish(2)
        local seen = {}
        for _, roll in ipairs({ 0.05, 0.35, 0.65, 0.82, 0.90, 0.98 }) do
            local spawned = throw_at(center, roll)
            for _, fish in ipairs(spawned) do
                local species = GameCfg.Fish[fish.fishId]
                if not species or species.RodLevel ~= 1 then
                    fail('不应抽出高竿级鱼: %s (RodLevel=%s)',
                        tostring(fish.fishId), tostring(species and species.RodLevel))
                end
                seen[fish.fishId] = true
            end
        end

        for _, expected_id in ipairs({ 'shrimp', 'riverShrimp', 'crayfish', 'rareShrimp', 'rareRiverShrimp', 'rareCrayfish' }) do
            if not seen[expected_id] then
                fail('虾池 1 级竿候选缺少 %s', expected_id)
            end
        end
    end)

    it('条款 6-13：首领专用饵强制召唤行被明确排除且不依赖品质', function()
        local zone_id = 'blastBossFilterProbe.water'
        local center = { x = 160, y = 2.183, z = 160 }
        saved_zones[zone_id] = false
        saved_fish.alligatorGar = { Grade = GameCfg.Fish.alligatorGar.Grade }
        saved_fish.tmpBossBaitNormal = false

        -- 构造品质为 normal 但使用首领专用饵的临时鱼种，以及临时改回 normal 品质的 alligatorGar
        GameCfg.Fish.tmpBossBaitNormal = {
            Id = 'tmpBossBaitNormal',
            Name = '测试首领饵普通品质鱼',
            Grade = 'normal',
            Bait = 'duck',
            RodLevel = 1,
        }
        GameCfg.Fish.alligatorGar.Grade = 'normal'

        GameCfg.Casting.Zones[zone_id] = {
            { Id = 'tilapia', Bait = 0, RodLevel = 1, DrawWeight = 1 },
            -- (a) 真实首领行（带首领专用饵）
            { Id = 'fish16Boss', Bait = 'item121', RodLevel = 1, DrawWeight = 10000 },
            -- (b1) 品质改为 normal 且行上带首领专用饵
            { Id = 'tmpBossBaitNormal', Bait = 'duck', RodLevel = 1, DrawWeight = 10000 },
            -- (b2) 品质改为 normal、行上未写 Bait，由鱼种与首领目录识别
            { Id = 'alligatorGar', RodLevel = 1, DrawWeight = 10000 },
        }
        set_zone(zone_id, center)

        for _, roll in ipairs({ 0, 0.01, 0.25, 0.5, 0.75, 0.99, 0.9999 }) do
            local spawned = throw_at(center, roll)
            if #spawned ~= GameCfg.Ability.Throw.FishMin then
                fail('应生成 %d 条合规鱼，实际=%d', GameCfg.Ability.Throw.FishMin, #spawned)
            end
            for _, fish in ipairs(spawned) do
                if fish.fishId ~= 'tilapia' then
                    fail('首领专用饵强制召唤行不应入池，实际抽到=%s (roll=%.4f)', tostring(fish.fishId), roll)
                end
            end
        end
    end)

    it('条款 6-13：水中爆炸生成 3 到 5 条鱼且全部先于爆炸伤害生成并受爆炸伤害', function()
        local center = { x = -11.75, y = 2.183, z = -12.25 }
        set_zone('WaterCircle2', center)
        ctx.other.Character.Position = { x = center.x + 1, y = 2, z = center.z }

        -- 下限 3 条：核对数量、时序与新鱼受爆炸伤害
        local slot_min = ctx:give_explosive(ctx.player, 'item143')
        ctx.random = function(a, b)
            if a and b then return a end
            return 0.9
        end
        local min_reply = ctx:throw(ctx.player, slot_min, center)
        assert.is_true(min_reply and min_reply.ok)
        ctx:advance(flight_sec() + 0.01)

        if #ctx.spawnedFish ~= GameCfg.Ability.Throw.FishMin then
            fail('下限预期 %d 条鱼，实际=%d', GameCfg.Ability.Throw.FishMin, #ctx.spawnedFish)
        end
        if #ctx.applied == 0 then
            fail('水区爆炸未结算伤害')
        end
        for _, fish in ipairs(ctx.spawnedFish) do
            for _, hit in ipairs(ctx.applied) do
                if fish.order >= hit.order then
                    fail('鱼生成顺序(%d)必须严格早于伤害(%d)', fish.order, hit.order)
                end
            end
        end

        local hit_targets = {}
        for _, hit in ipairs(ctx.applied) do
            hit_targets[hit.target] = (hit_targets[hit.target] or 0) + 1
            if hit.amount ~= 50 then
                fail('爆炸伤害预期 50，实际=%s', tostring(hit.amount))
            end
        end
        if not hit_targets[ctx.other] then
            fail('范围内其他玩家应受到爆炸伤害')
        end
        for _, entry in pairs(ctx.fish_unit.Fish) do
            if not hit_targets[entry.carrier] then
                fail('新生成的鱼载体 %s 应受到随后的爆炸伤害', tostring(entry.Id))
            end
        end

        -- 上限 5 条
        local before_max_fish = #ctx.spawnedFish
        local slot_max = ctx:give_explosive(ctx.player, 'item143')
        ctx.random = function(a, b)
            if a and b then return b end
            return 0.1
        end
        local max_reply = ctx:throw(ctx.player, slot_max, center)
        assert.is_true(max_reply and max_reply.ok)
        ctx:advance(flight_sec() + 0.01)

        local max_count = #ctx.spawnedFish - before_max_fish
        if max_count ~= GameCfg.Ability.Throw.FishMax then
            fail('上限预期 %d 条鱼，实际=%d', GameCfg.Ability.Throw.FishMax, max_count)
        end
    end)

    it('条款 6-13：水区仅有高竿级行与首领召唤行时不生成鱼且正常结算爆炸伤害', function()
        local zone_id = 'blastEmptyPoolProbe.water'
        local center = { x = 220, y = 2.183, z = 220 }
        saved_zones[zone_id] = false
        GameCfg.Casting.Zones[zone_id] = {
            { Id = 'bostonLobster', Bait = 'sausage', RodLevel = 2, DrawWeight = 32 },
            { Id = 'alligatorGar', Bait = 'duck', RodLevel = 1, DrawWeight = 100 },
        }
        set_zone(zone_id, center)
        ctx.other.Character.Position = { x = center.x + 2, y = 2, z = center.z }

        local spawned = throw_at(center, 0.5)
        if #spawned ~= 0 then
            fail('无合法候选时应生成 0 条鱼，实际=%d', #spawned)
        end
        local hit_other = false
        for _, hit in ipairs(ctx.applied) do
            if hit.target == ctx.other and hit.amount == 50 then
                hit_other = true
            end
        end
        if not hit_other then
            fail('无候选鱼时爆炸伤害仍应正常结算')
        end
    end)
end)
