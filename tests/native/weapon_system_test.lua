-- #90 迁移：武器系统（原 tests/gameplay/weapon_system_test.lua，9 类 40 例）。
-- describe / it 名沿用旧类名与方法名；注册顺序 = 旧套件实际执行顺序
-- （LuaUnit 按 `类名.方法名` 字节字典序收集全局类与方法，故
--  TestAbilitySwingRegistry → TestMainWeaponWiring → TestMgrFishUnitBlastFish → TestMgrWeapon →
--  TestMgrWeaponThrow → TestMgrWeaponUpgrade → TestPressGesture → TestWeaponConfig → TestWeaponPersistence）。
-- #129 失败方式先列：见 .scratch/129/progress.md。
-- 验收锁定：数值与商店表/票面一致（空手 5/0.5/2，不再 25）；挥砍登记驱动命中盒与伤害；
-- 服务端射速/弹量/换弹（2 秒）权威，切枪与重连不绕过；霰弹 5×20、火箭筒 500+5 米 100；
-- 投掷一发一件走 #123 协议（重放不重复扣）、20 米钳制、落水 3–5 条当地 1 级普通鱼后算伤害、
-- 5 米爆炸、普通投掷召唤不出首领；装备/选中重进恢复、弹匣按满匣恢复。
--
-- 每例只替换包内 CastAbility，并在 after_each 还原 preload 与模块缓存。
local weapon = require('tests.support.weapon_world')
local game_cfg = require('common.game_cfg')
local player_data = require('server.data.player_data')
local swing_registry = require('server.swing_registry')
local VENDOR = 'server.packages.ability_system.api'

local function fail(fmt, ...)
    assert.is_true(false, string.format(fmt, ...))
end

-- ===== 挥砍登记（ability_api） =====
describe('TestAbilitySwingRegistry', function()
    local ctx
    local saved
    before_each(function()
        saved = { game = rawget(_G, 'game'), preload = package.preload[VENDOR],
            vendor = package.loaded[VENDOR], api = package.loaded['server.ability_api'] }
        package.preload[VENDOR] = function() return { CastAbility = function() return true end } end
        package.loaded[VENDOR] = nil
        ctx = { now = 1000 }
        _G.game = { GetService = function(_, name)
            if name == 'World' then return { GetServerTime = function() return ctx.now end } end
            return nil
        end }
        ctx.api = assert(loadfile('server/ability_api.lua'))()
    end)
    after_each(function()
        _G.game = saved.game
        package.preload[VENDOR] = saved.preload
        package.loaded[VENDOR] = saved.vendor
        package.loaded['server.ability_api'] = saved.api
    end)

    it('test_add_cast_guard_chains_after_base_guard', function()
        local baseCalls, extraCalls = 0, 0
        ctx.api.SetCastGuard(function() baseCalls = baseCalls + 1 return true end)
        ctx.api.AddCastGuard(function(unit, index)
            extraCalls = extraCalls + 1
            return index ~= 2 -- 近战槽无登记时拒绝
        end)
        assert.is_true(ctx.api.CastAbility({}, 0))  -- 非近战槽不受追加守卫影响
        assert.is_false(ctx.api.CastAbility({}, 2)) -- 追加守卫拒绝
        assert.same({ 2, 2 }, { baseCalls, extraCalls })
    end)

    it('test_expired_or_future_swing_rejected', function()
        ctx.swing = assert(loadfile('server/swing_registry.lua'))()
        ctx.swing.StageSwing(7, { damage = 5, range = 2 })  -- at=1000
        ctx.now = 1000 + 1.6                              -- TTL 1.5 秒
        assert.is_nil(ctx.swing.PeekSwing(7))
        assert.is_nil(ctx.swing.TakeSwing(7))
        ctx.now = 1000
        ctx.swing.StageSwing(8, { damage = 5, range = 2 })
        ctx.now = 500                                     -- 登记在未来（时钟回拨）视为过期
        assert.is_nil(ctx.swing.TakeSwing(8))
    end)

    it('test_stage_take_once_and_overwrite', function()
        ctx.swing = assert(loadfile('server/swing_registry.lua'))()
        assert.is_true(ctx.swing.StageSwing(7, { damage = 5, range = 2 }))
        assert.same(5, ctx.swing.PeekSwing(7).damage)
        assert.same({ damage = 5, range = 2, at = 1000 }, ctx.swing.TakeSwing(7))
        assert.is_nil(ctx.swing.TakeSwing(7))
        -- 重复登记覆盖旧的（换武器不串档）
        ctx.swing.StageSwing(7, { damage = 40, range = 4 })
        ctx.swing.StageSwing(7, { damage = 10, range = 2 })
        assert.same(10, ctx.swing.TakeSwing(7).damage)
    end)

    it('时钟异常时拒绝登记和消费，恢复后不复活旧登记', function()
        local swing = assert(loadfile('server/swing_registry.lua'))()
        assert.is_true(swing.StageSwing(7, { damage = 5 }))
        ctx.now = math.huge
        assert.is_false(swing.StageSwing(7, { damage = 40 }))
        ctx.now = 1000
        assert.is_nil(swing.TakeSwing(7))
        assert.is_true(swing.StageSwing(8, { damage = 5 }))
        ctx.now = nil
        assert.is_nil(swing.PeekSwing(8))
        ctx.now = 1000
        assert.is_nil(swing.TakeSwing(8))
        _G.game = { GetService = function() error('clock-denied') end }
        assert.is_false(swing.StageSwing(9, { damage = 5 }))
    end)

    it('过期登记读取后清除，不随时钟回拨复活', function()
        local swing = assert(loadfile('server/swing_registry.lua'))()
        swing.StageSwing(7, { damage = 5 })
        ctx.now = 1002
        assert.is_nil(swing.PeekSwing(7))
        ctx.now = 1000
        assert.is_nil(swing.PeekSwing(7))
    end)

    it('玩家退出清除未消费的挥砍登记', function()
        local world = weapon.new()
        world:setUp()
        local ok, err = pcall(function()
            assert.is_true(swing_registry.StageSwing(world.player.UserId, { damage = 5 }))
            world:removePlayer(world.player)
            assert.is_nil(swing_registry.TakeSwing(world.player.UserId))
        end)
        world:tearDown()
        if not ok then error(err, 0) end
    end)

    it('施法拒绝或异常时清除登记并回复失败', function()
        local world = weapon.new()
        world:setUp()
        local ok, err = pcall(function()
            for _, cast in ipairs({
                function() return false end,
                function() error('cast-denied') end,
            }) do
                world.ability.CastAbility = cast
                world:advance(2)
                world:attack(world.player)
                assert.is_nil(swing_registry.PeekSwing(world.player.UserId))
                assert.is_false(weapon.lastReply(world, world.player).ok)
            end
        end)
        world:tearDown()
        if not ok then error(err, 0) end
    end)
end)

-- ===== main.lua 接线守卫 =====
describe('TestMainWeaponWiring', function()
    local function readSource(path)
        local parts = {}
        for line in io.lines(path) do parts[#parts + 1] = line end
        return table.concat(parts, '\n')
    end

    it('test_main_registers_and_wires_mgr_weapon', function()
        local src = readSource('server/main.lua')
        assert.matches('bind_weapon_action = function(dispatch)', src, nil, true)
        assert.matches('function runtime:damage_fish', readSource('server/world_host/server_runtime.lua'), nil, true)
        assert.matches('bind_party_action = function(dispatch)', src, nil, true)
        assert.matches('pk_damage_filter.make', readSource('server/world_host/server_runtime.lua'), nil, true)
        assert.matches('register_cast_guard = registerCastGuard', src, nil, true)
    end)
end)

describe('TestMgrFishUnitBlastFish', function()
    local ctx
    local saved
    before_each(function()
        saved = { game = rawget(_G, 'game'), carrier = package.loaded['server.world_host.fish_carrier'] }
        ctx = { now = 3000, despawned = {}, spawnOpts = {} }
        package.loaded['server.world_host.fish_carrier'] = {
            Spawn = function(_, opts)
                ctx.spawnOpts[#ctx.spawnOpts + 1] = opts
                return { Body = { Position = opts.Position }, Receiver = { Controller = {} } }, nil
            end,
            Despawn = function(_, carrier) ctx.despawned[#ctx.despawned + 1] = carrier end,
            Attach = function() end,
        }
        _G.game = { GetService = function(_, name)
            if name == 'World' then return { GetServerTime = function() return ctx.now end } end
            if name == 'Players' then return { GetPlayers = function() return {} end } end
            return nil
        end }
        ctx.mgr = assert(loadfile('server/world_host/fish_tree.lua'))()
        ctx.owner = { UserId = 55 }
    end)
    after_each(function()
        _G.game = saved.game
        package.loaded['server.world_host.fish_carrier'] = saved.carrier
    end)

    it('test_spawn_wild_fish_with_ttl_and_owner', function()
        local fish = ctx.mgr:SpawnBlastFish('tilapia', 1, { x = 1, y = 2, z = 3 }, ctx.owner)
        assert.is_not_nil(fish)
        assert.same(ctx.mgr.State.Wild, fish.State)
        assert.same(ctx.owner, fish.Owner)
        assert.same(3000 + game_cfg.Ability.Throw.FishTtlSec, fish.WildUntil)
        assert.same(fish, ctx.mgr.Fish[fish.Id])
        assert.same('tilapia', ctx.spawnOpts[1].FishId)
        assert.same({ x = 1, y = 2, z = 3 }, ctx.spawnOpts[1].Position)
        assert.same(game_cfg.Fish.tilapia.Health, ctx.spawnOpts[1].MaxHealth)
        -- Wild 鱼不接抓举：不会发起 Lift（没有 Conns/RequestLift 副作用）
        assert.is_nil(fish.Conns)
    end)

    it('test_wild_fish_can_be_killed_for_loot', function()
        local fish = ctx.mgr:SpawnBlastFish('bass', 1, { x = 0, y = 2, z = 0 }, ctx.owner)
        local killed = ctx.mgr:TakeKilled(fish)
        assert.same('bass', killed.fishId)
        assert.same(1, killed.mult)
        assert.is_nil(ctx.mgr.Fish[fish.Id]) -- 只会成功一次
        assert.is_nil(ctx.mgr:TakeKilled(fish))
    end)

    it('test_wild_fish_expire_after_ttl', function()
        local fish = ctx.mgr:SpawnBlastFish('carp', 2, { x = 0, y = 2, z = 0 }, ctx.owner)
        ctx.now = 3000 + game_cfg.Ability.Throw.FishTtlSec - 1
        ctx.mgr:Update()
        assert.same(fish, ctx.mgr.Fish[fish.Id]) -- 未到期保留
        ctx.now = 3000 + game_cfg.Ability.Throw.FishTtlSec
        ctx.mgr:Update()
        assert.is_nil(ctx.mgr.Fish[fish.Id])     -- 到期移除
        assert.same(1, #ctx.despawned)
    end)
end)

describe('TestMgrWeapon', function()
    local ctx
    before_each(function()
        ctx = weapon.new()
        ctx:setUp()
    end)
    after_each(function()
        ctx:tearDown()
    end)


    -- #37 失败方式：客户端俯仰丢失；方向尺度扩大射程；NaN/inf/零向量消耗弹药；
    -- 客户端声称命中绕过墙；正常攻击按钮/武器栏入口未带相机瞄准。
    it('test_attack_payload_aims_up_with_authoritative_origin_and_range', function()
        ctx:equip(ctx.player, 'item141')
        ctx:attack(ctx.player, { aim = { x = 0, y = 30, z = 40 } })
        assert.near(game_cfg.Ability.GunShared.Range * 0.6, ctx.lastRay.d.y, 1e-6)
        assert.near(game_cfg.Ability.GunShared.Range * 0.8, ctx.lastRay.d.z, 1e-6)
        assert.same({ x = 0, y = 3, z = 0 }, ctx.lastRay.o)
        -- 首命中墙，客户端的伪造目标不会绕过它；已发一枪仍只扣票面一发。
        ctx:advance(2)
        ctx.rayHit = { Instance = {}, Position = { x = 0, y = 4, z = 2 } }
        ctx:attack(ctx.player, { aim = { x = 0, y = 3, z = 4 }, target = ctx.other })
        assert.same(0, #ctx.applied)
        local ammo = weapon.lastReply(ctx, ctx.player).ammo
        for _, bad in ipairs({ false, {}, { x = 0, y = 0, z = 0 }, { x = 0, y = 0 / 0, z = 1 },
            { x = 0, y = math.huge, z = 1 }, { x = '0', y = 1, z = 1 }, { x = 1e308, y = 1, z = 1 } }) do
            ctx:advance(2)
            ctx:attack(ctx.player, { aim = bad })
            assert.same('bad-aim', weapon.lastReply(ctx, ctx.player).reason)
        end
        ctx:advance(2)
        ctx:attack(ctx.player, { aim = { x = 0, y = 3, z = 4 } })
        assert.same(ammo - 1, weapon.lastReply(ctx, ctx.player).ammo)
    end)

    it('test_camera_aim_payload_uses_normalized_viewport_center', function()
        local prior = _G.game
        _G.game = { GetService = function(_, name)
            if name == 'CameraService' then return { ViewportPointToRay = function(_, x, y)
                assert.same({ 0.5, 0.5 }, { x, y })
                return { Direction = { x = 0, y = 0.6, z = 0.8 } }
            end } end
        end }
        local ok, payload = pcall(function() return require('client.weapon_aim'):AttackPayload() end)
        _G.game = prior
        assert.is_true(ok, tostring(payload))
        assert.same({ action = 'attack', aim = { x = 0, y = 0.6, z = 0.8 } }, payload)
    end)

    it('test_cast_guard_requires_staged_swing_for_melee_only', function()
        local meleeIndex
        for _, entry in ipairs(game_cfg.Ability.InitialAbilities or {}) do
            if entry.AnchorBehavior == 'melee_hit' then meleeIndex = entry.Index end
        end
        assert.is_not_nil(meleeIndex)
        swing_registry.StageSwing(ctx.player.UserId, { damage = 5, range = 2 })
        assert.is_true(ctx:guard(ctx.player, ctx.player.Character, meleeIndex))
        swing_registry.ClearSwing(ctx.player.UserId)
        assert.is_false(ctx:guard(ctx.player, ctx.player.Character, meleeIndex))
        assert.is_true(ctx:guard(ctx.player, ctx.player.Character, 1))
        assert.is_true(ctx:guard(ctx.player, { UnitId = 5 }, meleeIndex))
    end)

    it('test_fire_rate_enforced_server_side', function()
        ctx:equip(ctx.player, 'item139')
        assert.is_true(ctx:attack(ctx.player).ok)
        ctx:advance(0.1)
        assert.same('cooldown', ctx:attack(ctx.player).reason)
        ctx:advance(0.06)
        assert.is_true(ctx:attack(ctx.player).ok)
    end)

    it('test_gun_magazine_empties_then_auto_reload_two_seconds', function()
        ctx:equip(ctx.player, 'item137')
        for i = 1, 10 do
            ctx:advance(1)
            assert.is_true(ctx:attack(ctx.player).ok)
        end
        assert.same(0, weapon.lastReply(ctx, ctx.player).ammo)
        ctx:advance(1)
        local reply = ctx:attack(ctx.player)
        assert.is_false(reply.ok)
        assert.same('empty', reply.reason)
        assert.is_true(reply.autoReload)
        -- 换弹中发射被拒
        assert.same('reloading', ctx:attack(ctx.player).reason)
        -- 手动换弹不重置/不叠加
        assert.same('reloading', ctx:reload(ctx.player).reason)
        -- 2 秒到期惰性补满；备弹无限（再打 10 发仍合法）
        ctx:advance(2.01)
        assert.is_true(ctx:attack(ctx.player).ok)
        assert.same(9, weapon.lastReply(ctx, ctx.player).ammo)
    end)

    it('test_gun_ray_miss_applies_nothing', function()
        ctx:equip(ctx.player, 'item137')
        ctx.rayHit = nil -- 未命中任何物体
        assert.is_true(ctx:attack(ctx.player).ok)
        assert.same(0, #ctx.applied)
        ctx.rayHit = { Instance = { UnitId = 999, UnitType = 'WorldUnit', PhysicsActive = true },
            Position = { x = 0, y = 2, z = 3 } } -- 墙：不解析出玩家/鱼
        ctx:advance(1)
        assert.is_true(ctx:attack(ctx.player).ok)
        assert.same(0, #ctx.applied)
    end)

    it('test_manual_reload_two_seconds_not_bypassed_by_switching', function()
        ctx:equip(ctx.player, 'item137')
        assert.is_true(ctx.data:GrantWeapon('item141', 1))
        assert.is_true(ctx:attack(ctx.player).ok)
        assert.is_true(ctx:reload(ctx.player).ok)
        assert.same('reloading', ctx:reload(ctx.player).reason)
        -- 切到狙击打一发再切回：手枪仍在换弹
        assert.is_true(ctx.data:HoldWeapon('item141'))
        ctx:advance(1)
        assert.is_true(ctx:attack(ctx.player).ok)
        assert.is_true(ctx.data:HoldWeapon('item137'))
        assert.same('reloading', ctx:attack(ctx.player).reason)
        ctx:advance(1.01)
        assert.is_true(ctx:attack(ctx.player).ok)
        assert.same(9, weapon.lastReply(ctx, ctx.player).ammo)
    end)

    it('test_melee_interval_enforced_per_weapon_and_switching', function()
        ctx:equip(ctx.player, 'item136')
        assert.is_true(ctx.data:GrantWeapon('item135', 1))
        ctx:attack(ctx.player)
        assert.same(40, swing_registry.PeekSwing(ctx.player.UserId).damage)
        ctx:attack(ctx.player)
        assert.same('cooldown', weapon.lastReply(ctx, ctx.player).reason)
        assert.same(1, #ctx.casts)
        ctx:advance(0.5)
        assert.is_true(ctx.data:HoldWeapon('item135'))
        ctx:attack(ctx.player)
        assert.same(15, swing_registry.PeekSwing(ctx.player.UserId).damage)
        assert.same(2, #ctx.casts)
        assert.is_true(ctx.data:HoldWeapon('item136'))
        ctx:attack(ctx.player)
        assert.same('cooldown', weapon.lastReply(ctx, ctx.player).reason)
        ctx:advance(0.51)
        ctx:attack(ctx.player)
        assert.same(3, #ctx.casts)
    end)

    it('test_rocket_direct_500_and_splash_5m_excludes_shooter', function()
        ctx:equip(ctx.player, 'item142')
        ctx.other.Character.Position = { x = 0, y = 2, z = 4 }   -- 落点 5 米内
        ctx.rayHit = { Instance = ctx.other.Character, Position = { x = 0, y = 2, z = 4 } }
        ctx:attack(ctx.player)
        local direct, splash = 0, {}
        for _, a in ipairs(ctx.applied) do
            if a.amount == 500 then direct = direct + 1 else splash[#splash + 1] = a end
        end
        assert.same(1, direct) -- 直伤一次
        -- 直伤目标被溅射跳过（不双算），投掷者不炸自己
        for _, a in ipairs(splash) do
            assert.same(100, a.amount)
            assert.is_not.same(ctx.other, a.target)
            assert.is_not.same(ctx.player, a.target)
        end
        assert.same(0, weapon.lastReply(ctx, ctx.player).ammo)
    end)

    it('test_shotgun_five_pellets_one_shell', function()
        ctx:equip(ctx.player, 'item138')
        ctx.rayHit = { Instance = ctx.other.Character, Position = { x = 0, y = 2, z = 5 } }
        ctx:attack(ctx.player)
        assert.same(5, #ctx.applied)
        for _, a in ipairs(ctx.applied) do assert.same(20, a.amount) end
        assert.same(ctx.other, ctx.applied[1].target)
        assert.same(1, weapon.lastReply(ctx, ctx.player).ammo)
    end)

    it('test_unarmed_attack_stages_cfg_swing_and_casts_melee', function()
        ctx:attack(ctx.player)
        local swing = swing_registry.PeekSwing(ctx.player.UserId)
        assert.same(5, swing.damage)
        assert.same(2, swing.range)
        assert.same(1, #ctx.casts)
        assert.same(0, ctx.casts[1].index) -- game_cfg 挥砍槽位
        assert.same(ctx.player.Character, ctx.casts[1].unit)
        assert.is_true(weapon.lastReply(ctx, ctx.player).ok)
    end)
end)

-- ===== 投掷 / 爆炸 =====
describe('TestMgrWeaponThrow', function()
    local ctx
    before_each(function()
        ctx = weapon.new()
        ctx:setUp()
    end)
    after_each(function()
        ctx:tearDown()
    end)

    local FlightSec = function() return game_cfg.Ability.Throw.FlightSec end

    local function waterZones(centerZ)
        return { { Id = 'WaterCircle2', Center = { x = -11.75, y = 1.05, z = centerZ },
            HalfXZ = 6, SurfaceY = 2.183 } }
    end

    local function standAtWater()
        ctx:setWaterZones(waterZones(-12.25))
        ctx.player.Character.Position = { x = -11.75, y = 2, z = -28 }
    end

    local function pickFishRoll(a, b)
        if a and b then return a end
        return 0.5
    end

    it('test_blast_candidates_exclude_boss_elite_rare_and_high_rod', function()
        local excluded = false
        for _, row in ipairs(game_cfg.Casting.Zones['shrimpPond.water']) do
            local species = game_cfg.Fish[row.Id]
            if species.Grade ~= 'normal' or row.RodLevel ~= 1 then excluded = true end
        end
        assert.is_true(excluded, '虾池鱼表里没有应被排除的条目，断言会空转')

        local function sweep(zoneId, center, playerZ)
            ctx:setWaterZones({ { Id = zoneId, Center = { x = center.x, y = center.y - 1, z = center.z },
                HalfXZ = 6, SurfaceY = center.y } })
            ctx.player.Character.Position = { x = center.x, y = 2, z = playerZ }
            local seen = {}
            for _, roll in ipairs({ 0, 0.34, 0.67, 0.99 }) do
                local slot = ctx:giveExplosive(ctx.player, 'item143')
                ctx.random = function(a, b) if a and b then return b end return roll end
                assert.is_true(ctx:throw(ctx.player, slot, center).ok)
                ctx:advance(FlightSec() + 0.01)
                for _, fish in ipairs(ctx.spawnedFish) do
                    local species = game_cfg.Fish[fish.fishId]
                    assert.same('normal', species.Grade)
                    assert.same(1, species.RodLevel)
                    seen[fish.fishId] = true
                end
            end
            return seen
        end

        local seen = sweep('shrimpPond.water', { x = 100, y = 2.183, z = 100 }, 112)
        assert.is_true(seen.shrimp and seen.riverShrimp and seen.crayfish,
            '扫过随机序列后仍应见到三个合规候选')
        sweep('WaterCircle2', { x = -11.75, y = 2.183, z = -12.25 }, -28)
    end)

    it('test_land_detonation_5m_radius_no_fish_skips_thrower', function()
        local slot = ctx:giveExplosive(ctx.player, 'item144')
        ctx.other.Character.Position = { x = 0, y = 2, z = 14.9 }  -- 4.9 米内
        local far = weapon.player(79)
        far.Character.Position = { x = 0, y = 2, z = 16.1 }        -- 6.1 米外
        ctx.players[#ctx.players + 1] = far
        assert.is_true(ctx:throw(ctx.player, slot, { x = 0, y = 2, z = 10 }).ok)
        ctx:advance(FlightSec() + 0.01)
        assert.same(0, #ctx.spawnedFish)
        local hitNear, hitFar, hitSelf = false, false, false
        for _, a in ipairs(ctx.applied) do
            assert.same(100, a.amount)
            if a.target == ctx.other then hitNear = true end
            if a.target == far then hitFar = true end
            if a.target == ctx.player then hitSelf = true end
        end
        assert.is_true(hitNear)
        assert.is_false(hitFar)
        assert.is_false(hitSelf)
    end)

    it('test_projectile_flies_then_detonates_in_water', function()
        standAtWater()
        local slot = ctx:giveExplosive(ctx.player, 'item143')
        ctx.random = pickFishRoll
        assert.is_true(ctx:throw(ctx.player, slot, { x = -11.75, y = 2.183, z = -12.25 }).ok)
        assert.same(1, #ctx.visuals)
        assert.same(0, ctx.data:ItemCount('item143'))
        ctx:advance(FlightSec() + 0.01)
        assert.same(3, #ctx.spawnedFish)
    end)

    it('test_expiry_destroy_failure_logs_and_settles_once', function()
        standAtWater()
        ctx.other.Character.Position = { x = -11.75, y = 2.183, z = -12.25 }
        local slot = ctx:giveExplosive(ctx.player, 'item143')
        ctx.random = pickFishRoll
        ctx:throw(ctx.player, slot, { x = -11.75, y = 2.183, z = -12.25 })
        local visual = ctx.visuals[1].unit
        visual.Destroy = function()
            visual.destroyCount = visual.destroyCount + 1
            error('destroy-denied')
        end
        local logs = {}
        _G.print = function(...)
            local fields = {}
            for i = 1, select('#', ...) do fields[i] = tostring(select(i, ...)) end
            logs[#logs + 1] = table.concat(fields, '\t')
        end

        ctx:advance(FlightSec() + 0.01)
        local fishAfterExpiry, hitsAfterExpiry = #ctx.spawnedFish, #ctx.applied
        ctx:advance(1)

        assert.same(1, visual.destroyCount)
        assert.same(3, fishAfterExpiry)
        assert.is_true(hitsAfterExpiry > 0)
        assert.same(fishAfterExpiry, #ctx.spawnedFish)
        assert.same(hitsAfterExpiry, #ctx.applied)
        local log = table.concat(logs, '\n')
        assert.is_truthy(log:find('[player_weapon]', 1, true))
        assert.is_truthy(log:find('视觉销毁失败', 1, true))
        assert.is_truthy(log:find('42', 1, true))
        assert.is_truthy(log:find('item143', 1, true))
        assert.is_truthy(log:find('destroy-denied', 1, true))
    end)

    it('test_visual_creation_failure_still_settles_once', function()
        standAtWater()
        ctx.other.Character.Position = { x = -11.75, y = 2.183, z = -12.25 }
        local slot = ctx:giveExplosive(ctx.player, 'item143')
        ctx.random = pickFishRoll
        local function failCreate(createUnit)
            ctx.create_unit = createUnit
            ctx.spawnedFish, ctx.applied = {}, {}
            assert.is_true(ctx:throw(ctx.player, slot, { x = -11.75, y = 2.183, z = -12.25 }).ok)
            ctx:advance(FlightSec() - 0.01)
            assert.same(0, #ctx.spawnedFish)
            assert.same(0, #ctx.applied)
            ctx:advance(0.02)
            local fishAfterExpiry, hitsAfterExpiry = #ctx.spawnedFish, #ctx.applied
            ctx:advance(1)
            assert.same(3, fishAfterExpiry)
            assert.is_true(hitsAfterExpiry > 0)
            assert.same(fishAfterExpiry, #ctx.spawnedFish)
            assert.same(hitsAfterExpiry, #ctx.applied)
            slot = ctx:giveExplosive(ctx.player, 'item143')
        end
        failCreate(function() return nil end)
        failCreate(function() error(setmetatable({ message = 'create-denied' },
            { __tostring = function(e) return e.message end })) end)
    end)

    it('test_removed_thrower_keeps_original_flight_isolated', function()
        standAtWater()
        ctx.other.Character.Position = { x = -11.75, y = 2, z = -28 }
        ctx.random = pickFishRoll
        local playerSlot = ctx:giveExplosive(ctx.player, 'item143')
        local otherSlot = ctx:giveExplosive(ctx.other, 'item143')
        ctx:throw(ctx.player, playerSlot, { x = -11.75, y = 2.183, z = -12.25 })
        ctx:throw(ctx.other, otherSlot, { x = -11.75, y = 2.183, z = -12.25 })

        ctx:removePlayer(ctx.player)
        assert.same(1, ctx.visuals[1].unit.destroyCount)
        assert.same(0, ctx.visuals[2].unit.destroyCount)

        ctx:advance(FlightSec() - 0.01)
        assert.same(0, #ctx.spawnedFish)
        assert.same(0, #ctx.applied)
        assert.same(0, ctx.visuals[2].unit.destroyCount)

        ctx:advance(0.02)
        local fishAfterExpiry, hitsAfterExpiry = #ctx.spawnedFish, #ctx.applied
        ctx:advance(1)
        assert.same(3, fishAfterExpiry)
        assert.same(3, hitsAfterExpiry)
        for _, hit in ipairs(ctx.applied) do
            assert.same(50, hit.amount)
            assert.is_not.same(ctx.other, hit.target)
            assert.is_not.same(ctx.player, hit.target)
        end
        assert.same(1, ctx.visuals[2].unit.destroyCount)
        assert.same(fishAfterExpiry, #ctx.spawnedFish)
        assert.same(hitsAfterExpiry, #ctx.applied)
    end)

    it('test_failed_blast_fish_does_not_roll_back_or_retry_damage', function()
        standAtWater()
        ctx.other.Character.Position = { x = -11.75, y = 2.183, z = -12.25 }
        local slot = ctx:giveExplosive(ctx.player, 'item143')
        ctx.fish_unit.SpawnBlastFish = function() error('blast-fish-denied') end
        ctx:throw(ctx.player, slot, { x = -11.75, y = 2.183, z = -12.25 })
        ctx:advance(FlightSec() + 0.01)
        local hitsAfterExpiry = #ctx.applied
        ctx:advance(1)
        assert.same(0, #ctx.spawnedFish)
        assert.is_true(hitsAfterExpiry > 0)
        assert.same(hitsAfterExpiry, #ctx.applied)
        assert.same(1, ctx.visuals[1].unit.destroyCount)
    end)

    -- #212：同屏两发在飞时，投掷物名字必须各自可区分。原来全服都叫 ThrowProjectile，
    -- 按名 FindFirstChild 拿到哪一发不确定，排查与定点回收都做不到。
    it('test_concurrent_projectiles_get_distinct_names', function()
        local landing = { x = 0, y = 2, z = 10 }
        local playerSlot = ctx:giveExplosive(ctx.player, 'item143')
        local otherSlot = ctx:giveExplosive(ctx.other, 'item143')
        ctx:throw(ctx.player, playerSlot, landing)
        ctx:throw(ctx.other, otherSlot, landing)
        assert.same(2, #ctx.visuals)
        assert.same('TriggerUnit', ctx.visuals[1].unitType)
        assert.is_not.same(ctx.visuals[1].name, ctx.visuals[2].name)
        local firstName, secondName = tostring(ctx.visuals[1].name), tostring(ctx.visuals[2].name)
        if not string.find(firstName, '42', 1, true) then
            fail('名字要带投掷者标识：%s', firstName)
        end
        if not string.find(secondName, '43', 1, true) then
            fail('名字要带投掷者标识：%s', secondName)
        end
    end)

    it('test_target_clamped_to_20m', function()
        local slot = ctx:giveExplosive(ctx.player, 'item144')
        ctx.other.Character.Position = { x = 0, y = 2, z = 19.9 }
        local far = weapon.player(79)
        far.Character.Position = { x = 0, y = 2, z = 25.1 }
        ctx.players[#ctx.players + 1] = far
        assert.is_true(ctx:throw(ctx.player, slot, { x = 0, y = 2, z = 100 }).ok)
        ctx:advance(game_cfg.Ability.Throw.FlightSec / 2)
        assert.near(10, ctx.visuals[1].unit.Position.z, 1e-9)
        ctx:advance(game_cfg.Ability.Throw.FlightSec / 2 + 0.01)
        assert.same(1, #ctx.applied)
        assert.same(ctx.other, ctx.applied[1].target)
    end)

    it('test_throw_consumes_exactly_one_without_save', function()
        local slot = ctx:giveExplosive(ctx.player, 'item143', 2)
        local reply = ctx:throw(ctx.player, slot, { x = 0, y = 2, z = 5 })
        assert.is_true(reply.ok)
        assert.same('throw', reply.action)
        assert.same(1, ctx.data:ItemCount('item143'))
        assert.same(1, #ctx.visuals)
    end)

    it('test_throw_rejects_non_explosive_and_bad_slot', function()
        local slot = ctx:giveExplosive(ctx.player, 'item143', 1)
        assert.same('bad-slot', ctx:throw(ctx.player, 0, { x = 0, y = 2, z = 5 }).reason)
        assert.same('bad-throwable', ctx:throw(ctx.player, 9, { x = 0, y = 2, z = 5 }).reason)
        local rodSlot
        for index, entry in pairs(ctx.data:GetItemBarSnapshot().slots) do
            if entry.itemId == game_cfg.Items.Id.StarterRod then rodSlot = index end
        end
        assert.is_not_nil(rodSlot)
        assert.same('bad-throwable', ctx:throw(ctx.player, rodSlot, { x = 0, y = 2, z = 5 }).reason)
        assert.same(1, ctx.data:ItemCount('item143'))
        assert.same(slot, ctx.data:GetItemBarSnapshot().selectedSlot)
    end)

    it('test_throw_replay_does_not_consume_or_launch_again', function()
        local executions = 0
        local save = {
            ResolveRequest = function(_, player, data, kind, requestId)
                assert.same('throw', kind)
                if requestId == 7 and ctx.replayed then
                    return { id = '42:1', sequence = 1, kind = 'throw', requestKey = 'k' }, 'replay'
                end
                return { id = '42:1', sequence = 1, kind = 'throw', requestKey = 'k' }, 'new'
            end,
            Execute = function(_, player, data, operation, transform, done)
                if ctx.replayed then
                    done(true, { ok = true, action = 'throw', itemId = 'item143', slot = 2 })
                    return true
                end
                local draft = player_data.New(weapon.player(42))
                draft:Init()
                assert.is_true(draft:ApplySave(data:Serialize()))
                local result = transform(draft)
                if result then
                    assert.is_true(data:ApplySave(draft:Serialize()))
                    done(true, result)
                else
                    done(false, 'rejected')
                end
                executions = executions + 1
                return true
            end,
        }
        ctx:remount(ctx.player, { save = save })
        local slot = ctx:giveExplosive(ctx.player, 'item143', 2)
        ctx:throw(ctx.player, slot, { x = 0, y = 2, z = 5 }, { seq = 7 })
        assert.same(1, ctx.data:ItemCount('item143'))
        assert.same(1, #ctx.visuals)
        ctx.replayed = true
        ctx:throw(ctx.player, slot, { x = 0, y = 2, z = 5 }, { seq = 7 })
        assert.same(1, ctx.data:ItemCount('item143')) -- 不重复扣
        assert.same(1, #ctx.visuals)
        assert.same(1, executions)
    end)

    it('test_water_detonation_spawns_3_to_5_fish_before_damage', function()
        standAtWater()
        local slot = ctx:giveExplosive(ctx.player, 'item143')
        ctx.random = function(a, b)
            if a and b then return b end -- 数量取上限，候选取最后一个（确定性）
            return 0.999
        end
        assert.is_true(ctx:throw(ctx.player, slot, { x = -11.75, y = 2.183, z = -12.25 }).ok)
        ctx:advance(FlightSec() + 0.01)
        assert.same(game_cfg.Ability.Throw.FishMax, #ctx.spawnedFish)
        assert.is_true(#ctx.spawnedFish >= game_cfg.Ability.Throw.FishMin)
        for _, f in ipairs(ctx.spawnedFish) do
            assert.same(ctx.player, f.owner)
            assert.same(1, f.mult)
            local species = game_cfg.Fish[f.fishId]
            assert.same('normal', species.Grade) -- 普通投掷召唤不出首领/精英/极品
            assert.same(1, species.RodLevel)
            -- 保底鱼在伤害之前生成
            for _, a in ipairs(ctx.applied) do assert.is_true(a.order > f.order) end
        end
        assert.is_true(#ctx.applied > 0) -- 随后按 5 米半径结算爆炸
    end)
end)

-- ===== #130 升级加成消费 =====
-- 失败方式：加成买了不生效/生效错对象（火箭筒溅射双加成、空手被加成）、
-- 弹容没向上取整、按复利算。
describe('TestMgrWeaponUpgrade', function()
    local ctx
    before_each(function()
        ctx = weapon.new()
        ctx:setUp()
    end)
    after_each(function()
        ctx:tearDown()
    end)


    it('test_explosive_max_level_scales_detonation', function()
        ctx.data.Extra.growth.upgrades.explosive = 3
        local slot = ctx:giveExplosive(ctx.player, 'item144')
        ctx.other.Character.Position = { x = 0, y = 2, z = 14.9 }
        assert.is_true(ctx:throw(ctx.player, slot, { x = 0, y = 2, z = 10 }).ok)
        ctx:advance(game_cfg.Ability.Throw.FlightSec + 0.01)
        assert.is_true(#ctx.applied >= 1)
        for _, a in ipairs(ctx.applied) do
            assert.near(160, a.amount, 1e-9)
        end
    end)

    -- 弹容满级 +150% 向上取整：狙击 5→13（7.5→8 逐级验证在配置层），第 14 发才空匣
    it('test_magazine_max_level_rounds_up_and_extends_ammo', function()
        ctx.data.Extra.growth.upgrades.magazine = 3
        ctx:equip(ctx.player, 'item141')
        for i = 1, 13 do
            ctx:advance(2)
            assert.is_true(ctx:attack(ctx.player).ok)
        end
        assert.same(0, weapon.lastReply(ctx, ctx.player).ammo)
        ctx:advance(2)
        local reply = ctx:attack(ctx.player)
        assert.same('empty', reply.reason) -- 第 14 发才触发空匣换弹
        assert.is_true(reply.autoReload)
    end)

    -- 近战满级 +70%：斧头 40→68 登记进挥砍；空手不吃武器加成
    it('test_melee_max_level_scales_staged_swing', function()
        ctx.data.Extra.growth.upgrades.melee = 7
        ctx:equip(ctx.player, 'item136')
        ctx:attack(ctx.player)
        local swing = swing_registry.PeekSwing(ctx.player.UserId)
        assert.near(68, swing.damage, 1e-9)
        assert.same(4, swing.range)
        ctx.data.Extra.inventory.selection.held = { kind = nil, id = nil, slot = nil } -- 回到空手
        ctx.data.data.SelectedWeapon = nil
        ctx:advance(2)
        ctx:attack(ctx.player)
        assert.same(5, swing_registry.PeekSwing(ctx.player.UserId).damage)
    end)

    -- 远程满级 +50%：每发弹丸乘算（霰弹 20→30）
    it('test_ranged_max_level_scales_each_pellet', function()
        ctx.data.Extra.growth.upgrades.ranged = 5
        ctx:equip(ctx.player, 'item138')
        ctx.rayHit = { Instance = ctx.other.Character, Position = { x = 0, y = 2, z = 5 } }
        ctx:attack(ctx.player)
        assert.same(5, #ctx.applied)
        for _, a in ipairs(ctx.applied) do assert.near(30, a.amount, 1e-9) end
    end)

    -- 火箭筒两段只归远程：直击 500→750；溅射 100→150，且不吃爆炸物加成（不双加成）
    it('test_rocket_two_stages_only_ranged_no_double_bonus', function()
        ctx.data.Extra.growth.upgrades.ranged = 5
        ctx.data.Extra.growth.upgrades.explosive = 3
        ctx:equip(ctx.player, 'item142')
        ctx.other.Character.Position = { x = 0, y = 2, z = 4 }
        ctx.rayHit = { Instance = ctx.other.Character, Position = { x = 0, y = 2, z = 4 } }
        ctx:attack(ctx.player)
        local direct = 0
        for _, a in ipairs(ctx.applied) do
            if a.target == ctx.other then
                direct = direct + 1
                assert.near(750, a.amount, 1e-9) -- 直击只吃远程
            else
                assert.near(150, a.amount, 1e-9) -- 溅射只吃远程：100×1.5，不乘爆炸物 1.6
                assert.is_not.same(ctx.player, a.target)
            end
        end
        assert.same(1, direct)
    end)

    -- 无升级时行为与 #129 基线完全一致（0 级不加成、弹容取基础值）
    it('test_zero_level_matches_129_baseline', function()
        ctx:equip(ctx.player, 'item136')
        ctx:attack(ctx.player)
        assert.same(40, swing_registry.PeekSwing(ctx.player.UserId).damage)
        assert.is_true(ctx.data:GrantWeapon('item141', 1))
        assert.is_true(ctx.data:HoldWeapon('item141'))
        ctx:advance(2)
        assert.is_true(ctx:attack(ctx.player).ok)
        assert.same(4, weapon.lastReply(ctx, ctx.player).ammo)
    end)
end)

-- ===== 客户端手势状态机 =====
describe('TestPressGesture', function()
    it('test_tap_and_long_press_and_move_cancel', function()
        local gesture = require('client.press_gesture')
        local g = gesture.New({ LongPressSec = 0.35 })
        g:Begin(10, { x = 100, y = 100 })
        assert.same('tap', g:End(10.1, { x = 103, y = 101 }))
        g:Begin(20, { x = 100, y = 100 })
        assert.is_false(g:Update(20.2))
        assert.is_true(g:Update(20.4)) -- 长按触发选点
        assert.same('long', g:End(20.5, { x = 300, y = 300 }))
        g:Begin(30, { x = 100, y = 100 })
        assert.is_nil(g:End(30.1, { x = 200, y = 100 })) -- 滑出容差：既不是点按也不是长按
    end)
end)

-- ===== 数值与表一致性 =====
describe('TestWeaponConfig', function()
    it('test_gun_shared_reload_two_seconds', function()
        assert.same(2, game_cfg.Ability.GunShared.ReloadSec)
        assert.is_true(game_cfg.Ability.GunShared.Range > 0)
    end)

    -- 商店表 R24—R19：手枪 10/1s/10、霰弹 5×20/1.5s/2、冲锋 13/0.15s/30、
    -- 自动步枪 20/0.2s/30、狙击 200/1.5s/5、火箭筒 500/1 发/周围 5 米 100
    -- 出手动作 Anim（#172）是表现字段，由 attack_animation_test 管，钉表只比数值
    local function numbers(row)
        local copy = {}
        for key, value in pairs(row) do
            if key ~= 'Anim' then copy[key] = value end
        end
        return copy
    end
    it('test_guns_match_shop_table', function()
        local g = {}
        for id, row in pairs(game_cfg.Ability.Guns) do g[id] = numbers(row) end
        assert.same({ Damage = 10, IntervalSec = 1.0, Magazine = 10 }, g.item137)
        assert.same({ Damage = 20, Pellets = 5, IntervalSec = 1.5, Magazine = 2 }, g.item138)
        assert.same({ Damage = 13, IntervalSec = 0.15, Magazine = 30, Auto = true }, g.item139)
        assert.same({ Damage = 20, IntervalSec = 0.2, Magazine = 30, Auto = true }, g.item140)
        assert.same({ Damage = 200, IntervalSec = 1.5, Magazine = 5 }, g.item141)
        assert.same({ Damage = 500, IntervalSec = 2.0, Magazine = 1,
            Splash = { Damage = 100, Radius = 5 } }, g.item142)
    end)

    -- 商店表 R27/R26/R25：指虎 10/0.5、匕首 15/0.5、斧头 40/1.0；#129 票面射程 2/3/4 米
    it('test_melee_weapons_match_design_table', function()
        local m = {}
        for id, row in pairs(game_cfg.Ability.MeleeWeapons) do m[id] = numbers(row) end
        assert.same({ Damage = 10, IntervalSec = 0.5, Range = 2 }, m.item134)
        assert.same({ Damage = 15, IntervalSec = 0.5, Range = 3 }, m.item135)
        assert.same({ Damage = 40, IntervalSec = 1.0, Range = 4 }, m.item136)
    end)

    -- 商店表 R18/R17/R16：鞭炮 50、手雷 100、炸药 150；票面：直接 20 米、5 米爆炸、保底 3–5 条
    it('test_throwables_and_throw_ticket', function()
        local e = game_cfg.Ability.Explosives
        assert.same(50, e.item143.Damage)
        assert.same(100, e.item144.Damage)
        assert.same(150, e.item145.Damage)
        local t = game_cfg.Ability.Throw
        assert.same(20, t.Range)
        assert.same(5, t.ExplosionRadius)
        assert.same(3, t.FishMin)
        assert.same(5, t.FishMax)
    end)

    it('test_unarmed_uses_ticket_values_not_25', function()
        local u = game_cfg.Ability.Unarmed
        assert.is_not_nil(u)
        assert.same(5, u.Damage)
        assert.same(0.5, u.IntervalSec)
        assert.same(2, u.Range)
        assert.is_not.same(25, u.Damage)
    end)

    -- 全量商品表（game_cfg.Shop.Goods 是已接入白名单，武器购买归 #130）
    -- #139 起武器来源不止商店：抽奖武器大奖（weaponChoice 组）也进同两张表，
    -- 口径改为「每件武器要么在商店武器页、要么是抽奖大奖」，且物品表分类正确。
    it('test_weapon_ids_registered_in_shop_and_items', function()
        local shopGoods = {}
        for _, goods in ipairs(game_cfg.Content.Shop.Goods) do
            if goods.page == '武器' and goods.itemKey then shopGoods[goods.itemKey] = true end
        end
        local lotteryPrizes = {}
        for _, entry in ipairs(game_cfg.Content.Lottery.Patterns) do
            if entry.tripleReward and entry.tripleReward.kind == 'weaponChoice' then
                for _, itemKey in ipairs(entry.tripleReward.itemKeys) do lotteryPrizes[itemKey] = true end
            end
        end
        local function checkSource(id, wantType)
            assert.is_true(shopGoods[id] or lotteryPrizes[id], id .. ' 既不在商店武器页也不是抽奖大奖')
            assert.same(wantType, game_cfg.Items.Definitions[id].Type)
        end
        for id, _ in pairs(game_cfg.Ability.MeleeWeapons) do checkSource(id, '近战武器') end
        for id, _ in pairs(game_cfg.Ability.Guns) do checkSource(id, '远程武器') end
        for id, _ in pairs(game_cfg.Ability.Explosives) do
            assert.is_true(shopGoods[id], id .. ' 不在商店武器页')
            assert.same('爆炸物', game_cfg.Items.Definitions[id].Type)
        end
    end)
end)

-- ===== 重进恢复 =====
describe('TestWeaponPersistence', function()
    it('test_rejoin_restores_equipment_and_full_magazine', function()
        local player = weapon.player(129)
        local data = player_data.New(player)
        data:Init()
        assert.is_true(data:GrantWeapon('item137', 1))
        assert.is_true(data:SelectWeapon('item137'))
        local snapshot = data:Serialize()
        local re = player_data.New(player)
        re:Init()
        assert.is_true(re:ApplySave(snapshot))

        local world = weapon.new({ players = { { player = player, data = re } } })
        world:setUp()
        local ok, err = pcall(function()
            local reply = world:attack(player, { action = 'attack', aim = { x = 0, y = 0, z = 1 } })
            assert.same('item137', reply.weapon)
            assert.same(game_cfg.Ability.Guns.item137.Magazine - 1, reply.ammo)
            local saved2 = re:Serialize()
            assert.is_nil(saved2.ammo)
            assert.same(1, re:WeaponCount('item137'))
        end)
        world:tearDown()
        if not ok then error(err, 0) end
    end)
end)
