-- #90 迁移：战斗基座与施法闸（原 tests/gameplay/combat_base_test.lua，3 类 9 例）。
-- describe / it 名沿用旧类名与方法名；describe 顺序 = 旧套件实际执行顺序
-- （LuaUnit 按 `类名.方法名` 全局字典序，故本文件里 TestAbilityCastGuard 最先、TestMgrAbilityActionGuard 最后）。
-- #128：先列失败方式见 .scratch/128/progress.md；通过服务端公开伤害入口验证命中身份与隔离。
--
-- 迁移期必修的模块缓存问题（旧文件没做，Busted 单进程下必须做）：
--   TestAbilityCastGuard 往 package.preload['server.packages.ability_system.api'] 装桩，旧文件从不摘除。
--   LuaUnit 各文件同进程时这条泄漏被后来的 require 撞上（本批 damage_float 的 Color 泄漏是同一类问题）；
--   Busted 也是单进程，所以这里逐案例快照并在 after_each 原样写回 preload 与 package.loaded 的旧值
--   （含 nil→nil），保证桩不跨案例。这不改业务行为，只把夹具的恢复补全。

local function signal()
    local s = { handlers = {} }
    function s:Connect(fn)
        self.handlers[#self.handlers + 1] = fn
        return { Disconnect = function() end }
    end
    function s:Fire() for _, fn in ipairs(self.handlers) do fn() end end
    return s
end

local function player(id)
    local c = { Health = 300, HealthChanged = signal(), Died = signal(), calls = 0 }
    function c:TakeDamage(n)
        self.calls = self.calls + 1
        self.Health = math.max(0, self.Health - n)
        self.HealthChanged:Fire()
        if self.Health == 0 then self.Died:Fire() end
    end
    local p = { UserId = id, CharacterAdded = signal(), attrs = {},
        Character = { Controller = c, Position = { x = id, y = 0, z = 0 }, Size = { y = 2 } } }
    function p:SetAttribute(k, v) self.attrs[k] = v end
    return p
end

describe('TestAbilityCastGuard', function()
    -- 桩只在这个 describe 内存在：after_each 摘掉 preload 与已加载的包 api / 根 AbilityAPI。
    local saved
    local VENDOR = 'server.packages.ability_system.api'
    before_each(function()
        saved = { preload = package.preload[VENDOR], vendor = package.loaded[VENDOR],
            api = package.loaded['server.ability_api'] }
    end)
    after_each(function()
        package.preload[VENDOR] = saved.preload
        package.loaded[VENDOR] = saved.vendor
        package.loaded['server.ability_api'] = saved.api
    end)

    -- 根 AbilityAPI 必须先跑服务端守卫，再进 vendor 的包内 cast_ability；守卫拒绝时包完全不被调用。
    it('test_root_api_applies_server_guard_before_package_cast', function()
        local impl = {}
        local calls = {}
        impl.cast_ability = function(unit, index) calls[#calls + 1] = { unit, index } return true end
        package.preload[VENDOR] = function() return impl end
        package.loaded[VENDOR] = nil
        package.loaded['server.ability_api'] = nil
        local api = assert(loadfile('server/ability_api.lua'))()
        local allowed, unit = false, {}
        api.set_cast_guard(function(candidate, index)
            assert.same({ unit, 2 }, { candidate, index })
            return allowed
        end)
        assert.is_false(api.cast_ability(unit, 2))
        assert.same({}, calls)
        allowed = true
        assert.is_true(api.cast_ability(unit, 2))
        assert.same(1, #calls)
    end)
end)

describe('TestCombatBase', function()
    local self_
    before_each(function()
        local Host = require('tests.support.life_host')
        self_ = { notices = {} }
        self_.host = Host.start({
          now = 100,
          remote = {
            get_re = function(_, name)
              return {
                OnServerEvent = Host.signal(),
                FireClient = function() end,
                FireAllClients = function(_, payload)
                  if name == 'DamageNotice' then self_.notices[#self_.notices + 1] = payload end
                end,
              }
            end,
            check_recd = function() return false end,
          },
        })
        self_.v = self_.host.runtime.life
        self_.a, self_.b = player(1), player(2)
        self_.host:add(self_.a)
        self_.host:add(self_.b)
    end)

    it('test_fish_damage_uses_same_hit_identity_and_reports_actual_amount', function()
        local carrier = { Body = { UnitId = 91 }, Receiver = {}, Controller = {} }
        local damageCalls = {}
        local Host = require('tests.support.life_host')
        self_.host:shutdown()
        self_.host = Host.start({
          now = 100,
          fish_carrier = {
            resolve_carrier = function(_, target)
                if target == carrier or target == carrier.Receiver then return carrier, 'fish:91' end
            end,
            Damage = function(_, target, amount, hit)
                damageCalls[#damageCalls + 1] = { target, amount, hit }
                return true, math.min(amount, 7)
            end,
          },
        })
        self_.v = self_.host.runtime.life
        self_.host:add(self_.a)
        self_.host:add(self_.b)
        local hit = self_.v:new_hit(self_.a.Character, 'weapon')
        local ok, actual = self_.v:apply_hit(hit, carrier, 10)
        assert.is_true(ok)
        assert.same(7, actual)
        assert.is_false(self_.v:apply_hit(hit, carrier.Receiver, 10))
        assert.same(1, #damageCalls)
        assert.same(10, damageCalls[1][2])
        assert.same(self_.a, damageCalls[1][3].sourcePlayer)
        assert.same(300, self_.a.Character.Controller.Health)
    end)

    it('test_gm_health_reduction_uses_gm_category', function()
        assert.is_true(self_.v:set_health(self_.a, 200))
        assert.same(200, self_.a.Character.Controller.Health)
        assert.same('gm', self_.notices[#self_.notices].category)
    end)

    it('test_hunger_damage_carries_hunger_category', function()
        self_.v:set_hunger(self_.a, 0)
        self_.host:advance(1)
        assert.same('hunger', self_.notices[#self_.notices].category)
        assert.same(295, self_.a.Character.Controller.Health)
    end)

    it('test_negative_eat_is_blocked_while_downed', function()
        -- 濒死锁血：负食用同样不能绕过状态判定（can_eat 已用 can_act 互斥）
        self_.host:phase(self_.a, 'downed')
        assert.is_false(self_.v:can_eat(self_.a, 'item126'))
        assert.is_false(self_.v:eat(self_.a, 'item126'))
        assert.same(300, self_.a.Character.Controller.Health)
        assert.same(0, #self_.notices)
    end)

    it('test_negative_eat_uses_unified_damage_entry_with_eat_category', function()
        -- 负食用（如核废料桶 item126 EatPercent=-99）必须走 apply_damage 单点，携带 eat 类别，
        -- 跳字通知与实际扣血一致；旧路 SetControllerHealth 直扣不会产生通知
        assert.is_true(self_.v:eat(self_.a, 'item126'))
        assert.same('eat', self_.notices[#self_.notices].category)
        assert.same(3, self_.a.Character.Controller.Health)
        assert.same(1, #self_.notices)
        assert.same(297, self_.notices[1].amount)
    end)

    it('test_same_hit_is_once_per_target_and_actual_damage_matches_notice', function()
        local hit = self_.v:new_hit(nil, 'grill')
        local ok, amount = self_.v:apply_hit(hit, self_.a, 25)
        assert.is_true(ok)
        assert.same(25, amount)
        assert.is_false(self_.v:apply_hit(hit, self_.a.Character, 25))
        assert.is_true(self_.v:apply_hit(hit, self_.b, 25))
        assert.same({ 275, 275 }, { self_.a.Character.Controller.Health, self_.b.Character.Controller.Health })
        assert.same({ 2, 25, 25 }, { #self_.notices, self_.notices[1].amount, self_.notices[2].amount })
        assert.is_false(self_.v:apply_hit(hit, self_.a, 0 / 0))
    end)

    it('test_source_alias_life_hook_and_zone_filter_stay_in_entry', function()
        local hit = self_.v:new_hit(self_.b.Character, 'weapon')
        assert.same(self_.b, self_.v:resolve_hit_source(hit))
        local filtered = 0
        self_.v:set_damage_filter(function(incoming, target)
            filtered = filtered + 1
            assert.same(self_.b, incoming.sourcePlayer)
            return incoming.category ~= 'weapon'
        end)
        assert.is_false(self_.v:apply_hit(hit, self_.a, 10))
        assert.same(300, self_.a.Character.Controller.Health)
        self_.v:set_damage_filter(nil)
        assert.is_true(self_.v:apply_hit(hit, self_.a.Character, 10))

        self_.a.Character.Controller.Health = 5
        local lethal = self_.v:new_hit(self_.b, 'fishAttack')
        local ok, actual = self_.v:apply_hit(lethal, self_.a, 10)
        assert.is_true(ok)
        assert.same(4, actual)
        assert.is_true(self_.v:is_downed(self_.a))
        assert.is_false(self_.v:apply_hit(self_.v:new_hit(self_.b, 'fishAttack'), self_.a, 1))
        local rescued = self_.host:tree(self_.b):begin_rescue(self_.a)
        assert.is_true(rescued)
    end)
end)

describe('TestMgrAbilityActionGuard', function()
    -- 旧文件在测试体内自行存取 game 与 server.ability_api；这里保持同样的存取，
    -- 但把恢复挪进 after_each，使断言失败时也不把桩留给下一条案例。
    local saved
    before_each(function()
        saved = { game = rawget(_G, 'game'), vendorApi = package.loaded['server.packages.ability_system.api'],
            api = package.loaded['server.ability_api'] }
    end)
    after_each(function()
        _G.game = saved.game
        package.loaded['server.ability_api'] = saved.api
        package.loaded['server.packages.ability_system.api'] = saved.vendorApi
    end)

    it('test_player_cast_is_blocked_by_vitals_state', function()
        local guard
        package.loaded['server.packages.ability_system.api'] = {}
        local api = { set_cast_guard = function(fn) guard = fn end }
        package.loaded['server.ability_api'] = api
        _G.game = { GetService = function() return {} end }
        local mgr = assert(loadfile('server/fish_ability.lua'))()
        local blocked, free = player(1), player(2)
        local host = require('tests.support.life_host').start({ now = 100 })
        host:add(blocked)
        host:add(free)
        host:phase(blocked, 'downed')
        local vitals = host.runtime.life
        mgr.Vitals = vitals
        mgr.BehaviorServices = { Vitals = vitals }
        mgr:Start()
        assert.same(mgr.BehaviorServices, api.BehaviorServices)
        -- 装配完成后立刻放回真实环境：守卫闭包已捕获 vitals，后续断言不需要假 game
        _G.game = saved.game
        package.loaded['server.ability_api'] = saved.api
        package.loaded['server.packages.ability_system.api'] = saved.vendorApi
        assert.is_not_nil(guard)
        assert.is_false(mgr:can_cast(blocked))
        assert.is_false(guard(blocked, 0))
        assert.is_true(mgr:can_cast(free))
        assert.is_true(guard(free, 0))
    end)
end)
