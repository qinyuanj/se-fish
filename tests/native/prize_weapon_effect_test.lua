-- #90 迁移：武器大奖特效挂载（原 tests/gameplay/prize_weapon_effect_test.lua，3 类 6 例）。
-- describe / it 名沿用旧类名与方法名；注册顺序 = 旧套件实际执行顺序（LuaUnit 按 `类名.方法名` 字典序，
-- 故 TestMeleeHitEffect → TestPrizeWeaponEffect → TestSwingEffectPassthrough）。
-- #139 T18 大奖成长切片 5：武器特效挂载（毒匕/炽焰战斧近战、霜之新星/雷霆之力枪械）。
-- 失败方式（先列后写）：
--   1. 特效武器命中后不挂效果（毒匕挥中不中毒）：swing 载荷丢 effect、枪械命中不调应用口；
--   2. 未命中也挂效果 / 无特效武器也挂效果 / 命中被统一入口拒绝（安全区）仍挂效果；
--   3. 近战命中盒重放（同一目标重复进盒）导致效果重复叠加超过一次判定段语义。
--
-- 技能包替身只提供本案例需要的施法接口，每例还原模块缓存。
local Weapon = require('tests.support.weapon_world')
local SwingRegistry = require('server.swing_registry')
local VENDOR = 'server.packages.ability_system.api'

-- 只替换包内 CastAbility，保持业务守卫的真实实现。
local function stubPackageApi(castAbility)
    local impl = {}
    impl.CastAbility = castAbility or function() return true end
    return impl
end

local function vec(x, y, z)
    return setmetatable({ x = x, y = y, z = z }, { __add = function(a, b)
        return vec(a.x + b.x, a.y + b.y, a.z + b.z)
    end })
end

local function sig()
    local s = { handlers = {} }
    function s:Connect(fn) self.handlers[#self.handlers + 1] = fn return { Disconnect = function() end } end
    function s:Fire(...) for _, h in ipairs(self.handlers) do h(...) end end
    return s
end

describe('TestMeleeHitEffect', function()
    -- ===== 3. melee_hit 行为：命中成功后直接经 MgrModifier 挂特效 =====
    local ctx
    local saved
    before_each(function()
        saved = { game = rawget(_G, 'game'), Vector3 = rawget(_G, 'Vector3'),
            Quaternion = rawget(_G, 'Quaternion'),
            carrier = package.loaded['server.world_host.fish_carrier'],
            gm = package.loaded['server.world_host.player_gm'],
            ability = package.loaded['server.fish_ability'],
            api = package.loaded['server.ability_api'], swing = package.loaded['server.swing_registry'] }
        ctx = { effects = {}, hitsApplied = {} }
        ctx.owner = { UnitId = 1, Position = vec(0, 0, 0) }
        ctx.player = { UserId = 13931, Character = ctx.owner }
        ctx.target = { UnitId = 2, UnitType = 'EggyUnit', Position = vec(0, 0, 2) }
        ctx.swing = { damage = 15, range = 3, effect = { Kind = 'poison' }, at = 1000 }
        ctx.applyOk = true
        _G.Vector3 = { New = vec }
        _G.Quaternion = { FromEulerAngles = function() return {} end }
        ctx.vitals = {
            NewHit = function(_, source, category) return { id = 1, source = source, category = category,
                targets = {} } end,
            ApplyHit = function(_, hit, target, amount)
                ctx.hitsApplied[#ctx.hitsApplied + 1] = { target = target, amount = amount }
                return ctx.applyOk
            end,
        }
        package.loaded['server.world_host.fish_carrier'] = { ResolveCarrier = function() return nil end }
        package.loaded['server.world_host.player_gm'] = { GetMeleeDamage = function(_, _, d) return d end }
        package.loaded['server.fish_ability'] = { ApplyWeaponEffect = function()
            error('近战特效不应再经 MgrAbility 转发')
        end }
        local modifierStub = { ApplyWeaponEffect = function(_, source, target, effect)
            ctx.effects[#ctx.effects + 1] = { source = source, target = target, effect = effect }
            return true
        end }
        package.loaded['server.ability_api'] = {}
        package.loaded['server.swing_registry'] = { TakeSwing = function()
            local s = ctx.swing; ctx.swing = nil; return s
        end }
        ctx.services = { Vitals = ctx.vitals,
            FishCarrier = package.loaded['server.world_host.fish_carrier'], GM = package.loaded['server.world_host.player_gm'],
            Modifier = modifierStub }
        for _, name in ipairs({ 'server.world_host.fish_carrier', 'server.world_host.player_gm' }) do
            package.loaded[name] = setmetatable({}, { __index = function()
                error('近战行为不应再加载上层管理器: ' .. name) end })
        end
        ctx.anchorStart = sig()
        local anchor = {
            Destroying = sig(),
            GetAttribute = function(_, name)
                if name == 'Duration' then return 0.3 end
                return nil
            end,
            FindFirstChild = function(_, name)
                if name == 'AnchorStart' then return ctx.anchorStart end
                return nil
            end,
        }
        local abilityScript = { Parent = nil }
        local manager = { Parent = ctx.owner }
        abilityScript.Parent = manager
        anchor.Parent = abilityScript
        _G.game = { GetService = function(_, name)
            if name == 'RunService' then return { IsServer = function() return true end } end
            if name == 'Players' then return { GetPlayerFromCharacter = function(_, unit)
                if unit == ctx.owner then return ctx.player end
                if unit == ctx.target then return nil end -- 目标不是玩家角色
            end } end
            if name == 'World' then return { CreateUnit = function(_, unitType, opts)
                if unitType == 'TriggerUnit' then
                    ctx.hitBox = { UnitId = 99, OnTriggerEnter = sig() }
                    return ctx.hitBox
                end
                return nil
            end, GetServerTime = function() return 1000 end } end
            if name == 'PhysicsService' then return { GetPartsInPart = function() return {} end } end
            return nil
        end }
        ctx.behavior = assert(loadfile('server/ability_behaviors/melee_hit.lua'))()
        ctx.behaviour = ctx.behavior.Attach(anchor, ctx.services)
        assert.is_nil(ctx.behaviour.root.fault)
    end)
    after_each(function()
        _G.game = saved.game
        _G.Vector3 = saved.Vector3
        _G.Quaternion = saved.Quaternion
        package.loaded['server.world_host.fish_carrier'] = saved.carrier
        package.loaded['server.world_host.player_gm'] = saved.gm
        package.loaded['server.fish_ability'] = saved.ability
        package.loaded['server.ability_api'] = saved.api
        package.loaded['server.swing_registry'] = saved.swing
    end)

    -- 把 Players 服务换成能认出 victim 的版本（保留其余服务）
    local function swapPlayers(victim, victimPlayer)
        _G.game.GetService = function(_, name)
            if name == 'RunService' then return { IsServer = function() return true end } end
            if name == 'Players' then return { GetPlayerFromCharacter = function(_, unit)
                if unit == ctx.owner then return ctx.player end
                if unit == victim then return victimPlayer end
            end } end
            if name == 'World' then return { CreateUnit = function(_, unitType)
                if unitType == 'TriggerUnit' then
                    ctx.hitBox = ctx.hitBox or { UnitId = 99, OnTriggerEnter = sig() }
                    return ctx.hitBox
                end
                return nil
            end, GetServerTime = function() return 1000 end } end
            if name == 'PhysicsService' then return { GetPartsInPart = function() return {} end } end
            return nil
        end
    end

    -- 伤害被统一入口拒绝（安全区等）：不挂特效、不击退
    it('test_effect_skipped_when_damage_rejected', function()
        ctx.applyOk = false
        local victim = { UnitId = 3, UnitType = 'EggyUnit', Position = vec(0, 0, 2) }
        local victimPlayer = { UserId = 13932, Character = victim }
        swapPlayers(victim, victimPlayer)
        ctx.anchorStart:Fire()
        ctx.hitBox.OnTriggerEnter:Fire(victim)
        assert.same(1, #ctx.hitsApplied)
        assert.same(0, #ctx.effects)
    end)

    -- 毒匕命中：伤害结算成功后挂毒；同一目标重复进盒不重复（hit_map 去重）
    it('test_effect_applied_after_successful_damage_once_per_swing', function()
        ctx.anchorStart:Fire()
        assert.message('登记挥砍后应建命中盒').is_not_nil(ctx.hitBox)
        -- 目标是玩家角色才会走 ApplyHit 玩家分支；这里目标不是玩家也不是鱼 → 不结算不挂
        ctx.hitBox.OnTriggerEnter:Fire(ctx.target)
        assert.same(0, #ctx.hitsApplied)
        assert.same(0, #ctx.effects)
        -- 目标换成另一玩家角色：命中成功 → 挂毒一次
        local victim = { UnitId = 3, UnitType = 'EggyUnit', Position = vec(0, 0, 2) }
        local victimPlayer = { UserId = 13932, Character = victim }
        swapPlayers(victim, victimPlayer)
        ctx.hitBox.OnTriggerEnter:Fire(victim)
        assert.same(1, #ctx.hitsApplied)
        assert.same(1, #ctx.effects)
        assert.same(ctx.player, ctx.effects[1].source)
        assert.same(victim, ctx.effects[1].target)
        assert.same({ Kind = 'poison' }, ctx.effects[1].effect)
        -- 同一目标再次进盒：去重，不重复结算也不重复挂
        ctx.hitBox.OnTriggerEnter:Fire(victim)
        assert.same(1, #ctx.hitsApplied)
        assert.same(1, #ctx.effects)
    end)
end)

describe('TestPrizeWeaponEffect', function()
    local ctx
    before_each(function()
        ctx = Weapon.new()
        ctx:setUp()
    end)
    after_each(function()
        ctx:tearDown()
    end)

    -- 命中被统一入口拒绝（ApplyHit false，如安全区）时不挂效果
    it('test_effect_not_applied_when_damage_rejected', function()
        ctx.applyOk = false
        ctx:equip(ctx.player, 'item163')
        ctx.rayHit = { Instance = ctx.other.Character, Position = { x = 0, y = 2, z = 5 } }
        assert.is_true(ctx:attack(ctx.player).ok)
        assert.same(0, #ctx.effects)
    end)

    -- 霜之新星命中挂霜冻；脱靶/无特效枪不挂
    it('test_gun_hit_applies_effect_only_on_hit', function()
        ctx:equip(ctx.player, 'item163')
        ctx.rayHit = { Instance = ctx.other.Character, Position = { x = 0, y = 2, z = 5 } }
        assert.is_true(ctx:attack(ctx.player).ok)
        assert.same(1, #ctx.effects)
        assert.same(ctx.player, ctx.effects[1].source)
        assert.message("枪击目标已由 GetPlayerFromCharacter 解析为玩家").same(ctx.other, ctx.effects[1].target)
        assert.same('frost', ctx.effects[1].kind)
        -- 脱靶：不挂
        ctx.rayHit = nil
        ctx:advance(1.1)
        assert.is_true(ctx:attack(ctx.player).ok)
        assert.same(1, #ctx.effects)
        -- 雷霆之力（麻痹）同样挂载
        ctx:equip(ctx.player, 'item164')
        ctx.rayHit = { Instance = ctx.other.Character, Position = { x = 0, y = 2, z = 5 } }
        ctx:advance(1.1)
        assert.is_true(ctx:attack(ctx.player).ok)
        assert.same('paralyze', ctx.effects[2].kind)
        -- 沙漠之鹰（无特效）命中也不挂
        ctx:equip(ctx.player, 'item162')
        ctx:advance(1.1)
        assert.is_true(ctx:attack(ctx.player).ok)
        assert.same(2, #ctx.effects)
    end)

    -- 毒匕挥砍：登记载荷带毒特效；商店匕首不带
    it('test_melee_swing_carries_weapon_effect', function()
        ctx:equip(ctx.player, 'item152')
        assert.is_true(ctx:attack(ctx.player).ok)
        local swing = SwingRegistry.PeekSwing(ctx.player.UserId)
        assert.same(15, swing.damage)
        assert.same({ Kind = 'poison' }, swing.effect)
        ctx:advance(0.6)
        ctx:equip(ctx.player, 'item135')
        assert.is_true(ctx:attack(ctx.player).ok)
        assert.message('无特效武器不挂 effect').is_nil(SwingRegistry.PeekSwing(ctx.player.UserId).effect)
        ctx:advance(0.5)
        ctx.data.Extra.inventory.selection.held = { kind = nil, id = nil, slot = nil }
        ctx.data.Data.SelectedWeapon = nil
        ctx:attack(ctx.player)
        assert.is_nil(SwingRegistry.PeekSwing(ctx.player.UserId).effect)
    end)
end)

describe('TestSwingEffectPassthrough', function()
    -- ===== 1. 挥砍登记载荷携带 effect（真实 AbilityAPI 业务入口 + 施法包桩）=====
    local ctx
    local saved
    before_each(function()
        saved = { game = rawget(_G, 'game'), preload = package.preload[VENDOR],
            vendor = package.loaded[VENDOR], api = package.loaded['server.ability_api'], swing = package.loaded['server.swing_registry'] }
        package.preload[VENDOR] = function() return stubPackageApi() end
        package.loaded[VENDOR] = nil
        ctx = { now = 1000 }
        _G.game = { GetService = function(_, name)
            if name == 'World' then return { GetServerTime = function() return ctx.now end } end
            return nil
        end }
        ctx.api = assert(loadfile('server/swing_registry.lua'))()
    end)
    after_each(function()
        _G.game = saved.game
        package.preload[VENDOR] = saved.preload
        package.loaded[VENDOR] = saved.vendor
        package.loaded['server.ability_api'] = saved.api
        package.loaded['server.swing_registry'] = saved.swing
    end)

    it('test_swing_carries_effect_through_stage_and_take', function()
        ctx.api.StageSwing(7, { damage = 15, range = 3, effect = { Kind = 'poison' } })
        local swing = ctx.api.TakeSwing(7)
        assert.same(15, swing.damage)
        assert.same({ Kind = 'poison' }, swing.effect)
        -- 无特效挥砍：effect 字段为 nil（不残留上一次登记）
        ctx.api.StageSwing(7, { damage = 5, range = 2 })
        assert.is_nil(ctx.api.TakeSwing(7).effect)
    end)
end)
