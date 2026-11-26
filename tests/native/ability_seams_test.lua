-- #90 迁移：服务端技能接缝（原 tests/gameplay/ability_seams_test.lua，2 类 11 例）。
-- describe / it 名沿用旧类名与方法名；注册顺序 = 旧套件实际执行顺序（LuaUnit 按 `类名.方法名` 字典序）。
-- #132 T11：职责分两块——1) AbilityAPI 防腐层（ACL：非法倍率净化、异常转结构化结果、挂点净空）；
-- 2) FishTree / FishAbility 跨引擎接缝驱动（启用点：before_each 注入 _G 引擎替身与字段替身）。
--
-- 失败方式（先列后写）：
--   1. 体型防腐层把 NaN/非法倍率写进单位，或单位不支持 SetScale 时直接抛错把调用方打断；
--   2. 挂点防腐层建出来的位移没净空（挂件陷进宿主）；无挂点名也能建；销毁失败还返回成功；
--   3. 飞行驱动不写回引擎，或写回时越过本区围栏（借飞行跨区）；
--   4. 空中受击不改变索敌：被打的鱼不找打它的玩家，只按最近挑人；
--   5. 阶段首领的招式不结算伤害、咬中不叼人；携带跟随不写回玩家位置、超时不放下。
--
-- 官方包边界（不改动 vendor）：本文件走的是「真实 server.ability_api」，它转发到
-- server.packages.ability_system.api。迁移只把这份真模块在 after_each 里放回快照（含 nil），
-- 不给 vendor 打桩、不写 package.preload，因此不会把桩泄漏给同进程的其他 spec。
-- 加载真包 api 需要全局 game 已就位（包内 sub_ability 在加载期读 game），故 before_each 先摆引擎替身再 require。
local GameCfg = require('common.game_cfg')

local function vec(x, y, z)
    return { x = x, y = y, z = z }
end

describe('TestAbilitySeams', function()
    -- 真实 AbilityAPI 防腐层；启用点：before_each 注入 _G.game / Vector3 替身
    local ctx
    local saved
    before_each(function()
        saved = { Vector3 = rawget(_G, 'Vector3'), Quaternion = rawget(_G, 'Quaternion'),
            game = rawget(_G, 'game'), api = package.loaded['server.ability_api'],
            vendor = package.loaded['server.packages.ability_system.api'] }
        ctx = { created = {} }
        _G.Vector3 = { New = vec }
        _G.Quaternion = { New = function(x, y, z, w) return { x = x, y = y, z = z, w = w } end }
        ctx.world = {
            CreateUnit = function(_, unitType, options)
                local unit = { UnitType = unitType, Destroyed = false }
                for k, v in pairs(options) do unit[k] = v end
                function unit:Destroy() self.Destroyed = true end
                ctx.created[#ctx.created + 1] = unit
                return unit
            end,
        }
        _G.game = { GetService = function(_, name)
            if name == 'RunService' then return { IsServer = function() return false end } end
            if name == 'World' then return ctx.world end
            return {}
        end }
        package.loaded['server.ability_api'] = nil
        ctx.api = require('server.ability_api')
    end)
    after_each(function()
        _G.Vector3 = saved.Vector3
        _G.Quaternion = saved.Quaternion
        _G.game = saved.game
        package.loaded['server.ability_api'] = saved.api
        package.loaded['server.packages.ability_system.api'] = saved.vendor
    end)

    it('test_attach_to_socket_creates_a_cleared_mount', function()
        local host = { Name = 'fish56Boss' }
        local attached = ctx.api.attach_to_socket(ctx.world, nil, host, 'LiftSocket', vec(0, 0.1, 0.1))
        assert.is_true(attached.Ok)
        assert.same('SkeletalSocketMount', attached.mount.UnitType)
        assert.same(host, attached.mount.Parent)
        assert.same('LiftSocket', attached.mount.SocketName)
        -- 贴脸位移必须被推出去（挂点不穿出）
        assert.is_true(attached.Offset.z >= 0.1)
        assert.is_true(attached.mount.SocketOffset.x == 0)
        -- 无挂点名 / 无宿主一律拒绝，不建孤儿单位
        assert.same('no-socket', ctx.api.attach_to_socket(ctx.world, nil, host, nil, nil).Error)
        assert.same('no-host', ctx.api.attach_to_socket(ctx.world, nil, nil, 'LiftSocket', nil).Error)
        assert.same(1, #ctx.created)
    end)

    it('test_detach_destroys_the_mount_only_once', function()
        local attached = ctx.api.attach_to_socket(ctx.world, nil, { Name = 'boss' }, 'LiftSocket', vec(0, 2, 0))
        assert.is_true(ctx.api.detach_from_socket(attached.mount))
        assert.is_true(attached.mount.Destroyed)
        assert.is_false(ctx.api.detach_from_socket(nil))
    end)

    it('test_set_body_scale_reports_failure_instead_of_throwing', function()
        assert.same('no-unit', ctx.api.set_body_scale(nil, 2).Error)
        local noScale = ctx.api.set_body_scale({}, 2)
        assert.is_false(noScale.Ok)
        assert.same('no-set-scale', noScale.Error)
        local broken = ctx.api.set_body_scale({ SetScale = function() error('引擎拒绝') end }, 2)
        assert.is_false(broken.Ok)
        assert.same(2, broken.Scale)
    end)

    it('test_set_body_scale_sanitizes_and_writes_a_uniform_scale', function()
        local written = nil
        local unit = { SetScale = function(_, scale) written = scale end }
        local applied = ctx.api.set_body_scale(unit, 3)
        assert.is_true(applied.Ok)
        assert.same(3, applied.Scale)
        assert.same(vec(3, 3, 3), written)
        assert.same(6, applied.derived.CapsuleHeight) -- 胶囊高随倍率放大
        -- 非法倍率净化成 1 倍，绝不把 NaN 写进单位
        for _, bad in ipairs({ 0 / 0, math.huge, -1, 0, 'x', nil }) do
            written = nil
            local result = ctx.api.set_body_scale(unit, bad)
            assert.message(tostring(bad)).is_true(result.Ok)
            assert.message(tostring(bad)).same(vec(1, 1, 1), written)
        end
    end)
end)

-- FishAbility / FishTree 驱动：启用点为注入的引擎与依赖替身（World/Players/Vitals/AbilityAPI）
describe('TestFishAbilitySeams', function()
    local function newFish(id, fishId, position)
        local body = { UnitId = id, Position = vec(position.x, position.y, position.z), BodyType = 4,
            Parent = nil, LinearVelocity = vec(0, 0, 0), Rotation = nil }
        return { Id = id, fish_id = fishId, Owner = nil, Anchor = vec(position.x, position.y, position.z),
            carrier = { body = body, Health = GameCfg.Fish[fishId].Health,
                MaxHealth = GameCfg.Fish[fishId].Health, dead = false }, threat = {} }
    end

    local function new_player(userId, position)
        return { UserId = userId, Character = { Position = vec(position.x, position.y, position.z),
            Controller = { Health = 100, MaxHealth = 100 } } }
    end

    local ctx
    local saved
    before_each(function()
        saved = { Vector3 = rawget(_G, 'Vector3'), Quaternion = rawget(_G, 'Quaternion'),
            RaycastParams = rawget(_G, 'RaycastParams'), game = rawget(_G, 'game'),
            carrier = package.loaded['server.world_host.fish_carrier'],
            ability = package.loaded['server.world_host.fish_tree'],
            api = package.loaded['server.ability_api'] }
        ctx = { now = 100, players = {}, hits = {}, mounts = {}, detached = {} }
        _G.Vector3 = { New = vec }
        _G.Quaternion = { New = function() return {} end, FromEulerAngles = function() return {} end }
        _G.RaycastParams = { new = function() return {} end }
        _G.game = { GetService = function(_, name)
            if name == 'World' then return { GetServerTime = function() return ctx.now end } end
            if name == 'Players' then return { GetPlayers = function() return ctx.players end } end
            return {}
        end }
        package.loaded['server.world_host.fish_carrier'] = { spawn = function() return nil end, despawn = function() end,
            sync_position = function() end }
        package.loaded['server.ability_api'] = {
            attach_to_socket = function(_, unit, host, socketName, offset)
                local mount = { UnitType = 'SkeletalSocketMount', Parent = host, SocketName = socketName,
                    SocketOffset = offset, Destroyed = false }
                function mount:Destroy() self.Destroyed = true end
                ctx.mounts[#ctx.mounts + 1] = mount
                return { Ok = true, mount = mount, Offset = offset }
            end,
            detach_from_socket = function(mount)
                ctx.detached[#ctx.detached + 1] = mount
                return true
            end,
        }
        package.loaded['server.world_host.fish_tree'] = nil
        ctx.mgr = assert(loadfile('server/world_host/fish_tree.lua'))()
        ctx.mgr.ability_api = package.loaded['server.ability_api']
        -- 目标裁决适配层按生产接线（server/main.lua）注入
        ctx.mgr.AiTarget = require('server.world_host.fish_ai_target')
        ctx.mgr.World = _G.game:GetService('World')
        ctx.mgr.Vitals = {
            can_take_damage = function() return true end,
            new_hit = function(_, source, category) return { source = source, category = category, targets = {} } end,
            apply_hit = function(_, hit, target, amount)
                ctx.hits[#ctx.hits + 1] = { target = target, amount = amount, category = hit.category }
                return true
            end,
        }
    end)
    after_each(function()
        _G.Vector3 = saved.Vector3
        _G.Quaternion = saved.Quaternion
        _G.RaycastParams = saved.RaycastParams
        _G.game = saved.game
        package.loaded['server.world_host.fish_carrier'] = saved.carrier
        package.loaded['server.world_host.fish_tree'] = saved.ability
        package.loaded['server.ability_api'] = saved.api
    end)

    -- 失败方式 4：空中受击改变索敌（威胁优先），攻击者死亡后仇恨失效回落最近
    it('test_air_strike_focuses_the_attacker_then_the_nearest_one', function()
        local fish = newFish(2, 'fish47Elite', { x = 0, y = 14, z = 0 })
        ctx.mgr.Fish[fish.Id] = fish
        local far = new_player(1, { x = 40, y = 0, z = 0 })
        local near = new_player(2, { x = 1, y = 0, z = 0 })
        ctx.players = { far, near }
        local pos = fish.carrier.body.Position
        -- 没被打过：取最近的
        local target = ctx.mgr:choose_target(fish, pos, { AggroRange = 60 })
        assert.same(near, target)
        -- 空中被远处的玩家打中：威胁优先，改盯打它的人
        ctx.mgr:note_damage(fish, far, 500)
        target = ctx.mgr:choose_target(fish, pos, { AggroRange = 60 })
        assert.message('空中受击后应改盯攻击者').same(far, target)
        -- 攻击者死亡：仇恨立即失效，回落最近目标
        far.Character.Controller.Health = 0
        target = ctx.mgr:choose_target(fish, pos, { AggroRange = 60 })
        assert.same(near, target)
        assert.message('失效目标要从仇恨表里清掉').is_nil(fish.threat[far])
    end)

    -- 失败方式 5：阶段首领入水咬中结算伤害并叼走玩家
    it('test_boss_phase_bite_lands_damage_and_grabs_the_player', function()
        local safe = GameCfg.Zones[7].Scene.SafePoint
        local fish = newFish(3, 'fish56Boss', { x = safe.x, y = safe.y, z = safe.z })
        ctx.mgr.Fish[fish.Id] = fish
        local player = new_player(9, { x = safe.x + 1, y = safe.y, z = safe.z })
        ctx.players = { player }
        -- 50%：入水阶段（咬中 1000）
        fish.carrier.Health, fish.carrier.MaxHealth = 5000, 10000
        fish.Phase = require('common.boss_phase').new(GameCfg.Ability.BossPhase, ctx.now, fish.carrier.body.Position)
        fish.phase_at = ctx.now
        fish.Yaw = 0
        for _ = 1, 355 do -- #38 正文沧龙式：15秒跃起，1秒预警+1.5秒腾空后咬中
            ctx.now = ctx.now + 0.05
            ctx.mgr:update_boss_phase(fish, ctx.now, fish.carrier.body.Position)
        end
        assert.same('water', fish.Phase.Phase)
        assert.same(2, #ctx.hits)
        assert.same(35, ctx.hits[1].amount)
        assert.same(1000, ctx.hits[2].amount)
        assert.same('fishAttack', ctx.hits[2].category)
        assert.same(player, ctx.hits[2].target)
        -- 咬中即叼走：挂点建出来了，玩家归到携带态
        assert.is_not_nil(fish.Carry)
        assert.is_not_nil(fish.carry_mount)
        assert.same(GameCfg.Ability.Carry.Socket, fish.carry_mount.SocketName)
        assert.same(player, fish.Carry.target_player)
    end)

    -- 失败方式 5：携带跟随容差内不写回、被甩开则钳回挂点、超时放下并销毁挂点
    it('test_carry_follows_snaps_and_releases_with_the_mount', function()
        local fish = newFish(4, 'fish56Boss', { x = 0, y = 0, z = 0 })
        ctx.mgr.Fish[fish.Id] = fish
        local player = new_player(9, { x = 1, y = 0, z = 0 })
        ctx.players = { player }
        local CarryMount = require('common.carry_mount')
        local cfg = GameCfg.Ability.Carry
        fish.Carry = CarryMount.new(cfg, { x = 0, y = 0, z = 0 }, 0, ctx.now)
        fish.Carry.ground_y = 2
        fish.Carry.target_player = player
        fish.Carry.last_step_at = ctx.now
        assert.is_true(CarryMount.attach(fish.Carry, { x = 1, y = 0, z = 0 }, ctx.now).Ok)
        fish.carry_mount = ctx.mounts[#ctx.mounts + 1] or { Destroyed = false, Destroy = function() end }
        -- 容差内不写回（避免每帧纠正抖动）
        local before = vec(player.Character.Position.x, player.Character.Position.y, player.Character.Position.z)
        ctx.mgr:update_carry(fish, ctx.now + 0.05)
        assert.same(before.x, player.Character.Position.x)
        -- 被甩开：整段钳回挂点坐标
        player.Character.Position = vec(999, 0, 999)
        ctx.mgr:update_carry(fish, ctx.now + 0.1)
        local mount = CarryMount.mount_point(fish.Carry.host, fish.Carry.Offset, 0)
        assert.near(mount.x, player.Character.Position.x, 1e-9)
        assert.near(mount.z, player.Character.Position.z, 1e-9)
        assert.same(1, fish.Carry.stats.snaps)
        -- 超时：放下玩家、销毁挂点、清携带态
        ctx.mgr:update_carry(fish, ctx.now + cfg.MaxCarrySec + 1)
        assert.is_nil(fish.Carry)
        assert.is_nil(fish.carry_mount)
        assert.same(1, #ctx.detached)
        assert.near(2 + cfg.DropHeight, player.Character.Position.y, 1e-9)
        assert.near(cfg.DropForward, player.Character.Position.z, 1e-9)
    end)

    -- 失败方式 3：飞行边界先取本区场景，未知鱼种回落兜底围栏且仍是有限值
    it('test_flight_bounds_come_from_the_zone_scene_then_the_fallback', function()
        local zone = nil
        for _, entry in ipairs(GameCfg.Zones) do
            if entry.Id == 'reefIsland' then zone = entry.Scene end
        end
        local bounds = ctx.mgr:flight_bounds('fish47Elite')
        assert.same(zone.Boundary.MinX, bounds.MinX)
        assert.same(zone.SafePoint.y + GameCfg.Ability.Flight.MaxHeight, bounds.ceiling_y)
        -- 未知鱼种用兜底围栏，仍然是有限边界
        local fallback = ctx.mgr:flight_bounds('noSuchFish')
        assert.same(GameCfg.Ability.Flight.FallbackBounds.MaxX, fallback.MaxX)
        assert.is_not.same(math.huge, fallback.ceiling_y)
    end)

    -- 失败方式 3：驱动帧写回的位置必须在围栏内，越界要被钳制并计数
    it('test_flying_writes_back_a_position_inside_the_fence', function()
        local fish = newFish(1, 'fish47Elite', { x = 0, y = 14, z = 0 })
        ctx.mgr.Fish[fish.Id] = fish
        local bounds = ctx.mgr:flight_bounds(fish.fish_id)
        -- 起点故意放到围栏外：驱动一帧必须把它夹回本区
        fish.carrier.body.Position = vec(bounds.MaxX + 200, bounds.ceiling_y + 50, bounds.MaxZ + 200)
        assert.is_true(ctx.mgr:start_flight(fish, ctx.now))
        assert.same('flying', fish.State)
        for _ = 1, 60 do
            ctx.now = ctx.now + 0.05
            ctx.mgr:update_flying(fish, ctx.now)
        end
        local pos = fish.carrier.body.Position
        assert.message('x ' .. tostring(pos.x)).is_true(pos.x <= bounds.MaxX and pos.x >= bounds.MinX)
        assert.message('z ' .. tostring(pos.z)).is_true(pos.z <= bounds.MaxZ and pos.z >= bounds.MinZ)
        assert.message('y ' .. tostring(pos.y)).is_true(pos.y <= bounds.ceiling_y)
        assert.message('越界必须被钳制并计数').is_true(fish.Flight.stats.clamps > 0)
        assert.is_true(#fish.Flight.clamp_log > 0)
    end)

    -- 失败方式 5：remove 必须先放下携带中的玩家，再清鱼
    it('test_remove_drops_a_carried_player_before_clearing_the_fish', function()
        local fish = newFish(5, 'fish56Boss', { x = 0, y = 0, z = 0 })
        ctx.mgr.Fish[fish.Id] = fish
        local player = new_player(9, { x = 1, y = 0, z = 0 })
        local CarryMount = require('common.carry_mount')
        fish.Carry = CarryMount.new(GameCfg.Ability.Carry, { x = 0, y = 0, z = 0 }, 0, ctx.now)
        fish.Carry.ground_y = 2
        fish.Carry.target_player = player
        CarryMount.attach(fish.Carry, { x = 1, y = 0, z = 0 }, ctx.now)
        ctx.mgr:remove(fish)
        assert.is_nil(fish.Carry)
        assert.is_nil(ctx.mgr.Fish[fish.Id])
        assert.near(2 + GameCfg.Ability.Carry.DropHeight, player.Character.Position.y, 1e-9)
    end)

    it('test_species_registry_routes_flight_and_boss', function()
        assert.same(20, ctx.mgr:flight_profile('fish47Elite').DiveIntervalSec)
        assert.same('leap', ctx.mgr:flight_profile('fish55Elite').Mode)
        assert.same(260, ctx.mgr:flight_profile('fish48Boss').DiveDamage)
        assert.is_nil(ctx.mgr:flight_profile('eel'))
        assert.is_true(ctx.mgr:boss_phase_enabled('fish56Boss'))
        assert.is_false(ctx.mgr:boss_phase_enabled('fish47Elite'))
    end)
end)
