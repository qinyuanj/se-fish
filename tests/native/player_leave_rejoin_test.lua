-- #88 迁移：玩家离场与重进（原 tests/gameplay/player_leave_rejoin_test.lua，6 例）。
-- #56 失败方式（先列后写）：
-- 任务事实/剧情已读未落账就替换会话；旧死亡状态和角色连接残留；最终离场快照被新认领取消；
-- 重复离场/迟到清理误删新会话；等待玩家已离开或被再次重进替换仍被接纳；跨玩家阻塞；失败后卡住。
-- it 按旧 LuaUnit 的方法名字典序注册，保持与旧套件一致的案例顺序。
-- assertIs(state.player, p) 要求对象身份：全仓无 __eq 元方法（已检索确认），故 Lua 的 == 即身份，映射 are.equal。
local GameCfg = require('common.game_cfg')

local function signal()
    local s = { handlers = {} }
    function s:Connect(fn)
        self.handlers[#self.handlers + 1] = fn
        return { Disconnect = function()
            for i, handler in ipairs(self.handlers) do
                if handler == fn then table.remove(self.handlers, i) return end
            end
        end }
    end
    function s:Fire(...)
        for _, fn in ipairs({ table.unpack(self.handlers) }) do fn(...) end
    end
    return s
end

local function player(id)
    local p = { UserId = id, attrs = {}, CharacterAdded = signal(), CharacterRemoving = signal() }
    function p:SetAttribute(key, value) self.attrs[key] = value end
    local c = { Health = 300, MaxHealth = 300, HealthChanged = signal(), Died = signal(), OnReborn = signal() }
    function c:TakeDamage(amount)
        self.Health = math.max(0, self.Health - amount)
        self.HealthChanged:Fire(self.Health)
        if self.Health == 0 then self.Died:Fire() end
    end
    p.Character = { Controller = c }
    return p
end

describe('TestPlayerLeaveRejoin', function()
    local env
    local saved = {}

    -- 类内辅助（旧 TestPlayerLeaveRejoin:join / :drain / :fact / :assertRejoined）改为接收 env 的本地函数，
    -- 避免在 describe 加载期就往尚未赋值的 env 上挂方法。
    local function join(id)
        local p = player(id)
        env.players.PlayerAdded:Fire(p)
        return p
    end

    local function drain()
        local count = 0
        while #env.tasks > 0 do
            count = count + 1
            assert(count < 100, '异步队列未收敛')
            table.remove(env.tasks, 1)()
        end
        assert.same({}, env.errors)
    end

    local function fact(id)
        assert.is_true(env.quest:notify('PickBait', env.a, { itemId = 'worm', eventId = id }))
    end

    local function assertRejoined(p)
        assert.same('ready', p.attrs.SaveState)
        assert.is_not_nil(env.data:get_data_inst(p))
        local life = env.runtime and env.runtime.life
        local state = life and life:get_state(p)
        assert.are.equal(p, state and state.player)
        assert.same('alive', life:life_status(p))
        assert.is_true(life:can_act(p))
    end

    -- 逐例夹具：旧 LuaUnit 每例跑 set_up/tear_down，这里同样用 before_each/after_each。
    -- 第一步把所有被改状态（4 个全局 + Debug + QaSlot）存进 saved，之后才改任何东西，
    -- 因此夹具中途抛错时 after_each 仍能完整还原，不把失败泄漏给后续案例。
    before_each(function()
        saved.game, saved.REUtil = rawget(_G, 'game'), rawget(_G, 'REUtil')
        saved.Vector3, saved.Color = rawget(_G, 'Vector3'), rawget(_G, 'Color')
        saved.Debug, saved.slot = GameCfg.Debug, GameCfg.Save.QaSlot
        GameCfg.Debug, GameCfg.Save.QaSlot = { Enabled = false }, ''
        _G.Vector3 = { New = function(x, y, z) return { x = x, y = y, z = z } end }
        _G.Color = { New = function(...) return { ... } end }
        env = { tasks = {}, values = {}, errors = {}, cleanups = {} }
        env.players = {
            PlayerAdded = signal(),
            PlayerRemoving = signal(),
            GetPlayers = function() return {} end,
            GetPlayerFromCharacter = function() return nil end,
        }
        env.heartbeat = signal()
        env.store = {
            GetAsync = function(_, key) return env.values[key] end,
            UpdateAsync = function(_, key, transform)
                local value = transform(env.values[key])
                if env.failWrite and value and value.meta.session == env.failedToken then error('测试写档失败') end
                if value then env.values[key] = value end
                return value
            end,
        }
        local function make_dummy_unit()
            local u = { attrs = {}, destroyed = false }
            function u:Destroy() self.destroyed = true end
            function u:SetAttribute(k, v) self.attrs[k] = v end
            function u:GetAttribute(k) return self.attrs[k] end
            function u:FindFirstChild() return nil end
            return u
        end
        _G.game = {
            BindToClose = function() end,
            GetService = function(_, name)
                if name == 'Task' then return {
                    Spawn = function(_, fn) env.tasks[#env.tasks + 1] = fn end, Wait = function() end,
                } end
                if name == 'Players' then return env.players end
                if name == 'RunService' then return { Heartbeat = env.heartbeat, IsServer = function() return true end, IsClient = function() return false end } end
                if name == 'World' then return {
                    GetServerTime = function() return 100 end,
                    CreateUnit = function() return make_dummy_unit() end,
                    CreateAsset = function() return { make_dummy_unit() } end,
                } end
                if name == 'DataStoreService' then return { GetDataStore = function() return env.store end } end
            end,
        }
        _G.REUtil = { get_re = function(_, name)
            env.remotes = env.remotes or {}
            if not env.remotes[name] then
                env.remotes[name] = { OnServerEvent = signal(), FireClient = function() end }
            end
            return env.remotes[name]
        end, check_recd = function() return false end }
        _G.RemoteEvent = { New = function() return {
            OnServerEvent = signal(), OnClientEvent = signal(),
            FireServer = function() end, FireClient = function() end,
        } end }
        local attr_api_stub = {
            Enums = { AttrComponentType = { Base = 1, BaseExtra = 2, Ratio = 3, Bonus = 4 } },
            Funcs = {
                GetAttrConfig = function() return nil end,
                GetAttrUnit = function() return nil end,
                EnsureAttrUnit = function() return make_dummy_unit() end,
                SetAttrComponent = function() return true end,
                GetAttr = function() return 0 end,
            },
        }
        local modifier_api_stub = {
            Enums = { CreateResult = { Added = 'Added', Reobtained = 'Reobtained' } },
            AddModifier = function() return 'Added' end,
            GetUnitModifiers = function() return {} end,
            RemoveModifier = function() end,
        }
        local ability_api_stub = {
            AddAbility = function() return { SetAttribute = function() end } end,
            StopAbility = function() end,
            CastAbility = function() return true end,
        }
        env.save = assert(loadfile('server/save_host.lua'))()
        env.data = assert(loadfile('server/player_data_host.lua'))()
        env.quest = {
            notify = function(_, kind, player, payload) return env.runtime:notify_quest(kind, player, payload) end,
            get_state = function(_, player) return env.data:get_data_inst(player).Extra.quest end,
        }
        local sandbox = setmetatable({
            print = function(...)
                local parts = { ... }
                if parts[1] == '[server.main]' then env.errors[#env.errors + 1] = parts end
            end,
            require = function(path)
                if path == 'server.MgrUtil' then return { Start = function() end } end
                if path == 'common.zone_markers' then return { start = function() end } end
                if path == 'server.packages.attr_rule.api' then return attr_api_stub end
                if path == 'server.packages.modifier_system.api' then return modifier_api_stub end
                if path == 'server.packages.ability_system.api' then return ability_api_stub end
                if path == 'server.save_host' then return env.save end
                if path == 'server.player_data_host' then return env.data end
                if path == 'server.platform_host' then return {} end
                if path == 'server.fish_ability' then return { start = function() end, update = function() end } end
                return require(path)
            end,
        }, { __index = _G })
        assert(loadfile('server/main.lua', 't', sandbox))()
        env.runtime = require('server.world_host.server_runtime').current()
        env.a = join(560)
        drain()
    end)
    after_each(function()
        _G.game, _G.REUtil = saved.game, saved.REUtil
        _G.Vector3, _G.Color = saved.Vector3, saved.Color
        GameCfg.Debug, GameCfg.Save.QaSlot = saved.Debug, saved.slot
        saved = {}
        env = nil
    end)

    it('test_dead_old_vitals_does_not_block_new_living_player', function()
        env.runtime.life:apply_hit(env.runtime.life:new_hit(nil, 'fishAttack'), env.a, 999)
        assert.is_false(env.runtime.life:can_act(env.a))
        fact('worm:dead')
        env.players.PlayerRemoving:Fire(env.a)
        local b = join(env.a.UserId)
        drain()
        assertRejoined(b)
        assert.is_true(env.runtime.life:can_act(b))
    end)

    it('test_final_leave_snapshot_is_drained_before_new_claim', function()
        env.data:get_data_inst(env.a):AddCoin(17)
        env.players.PlayerRemoving:Fire(env.a)
        local b = join(env.a.UserId)
        assert.same('pending', b.attrs.SaveState)
        drain()
        assertRejoined(b)
        assert.same(17, env.data:get_data_inst(b).Data.FishCoin)
        assert.same(17, env.values.u560.coin)
    end)

    it('test_quest_queue_keeps_old_session_until_committed_then_rebinds', function()
        fact('worm:1')
        fact('worm:2')
        local old = env.save.sessions[env.a.UserId]
        env.players.PlayerRemoving:Fire(env.a)
        local b = join(env.a.UserId)
        assert.are.equal(old, env.save.sessions[env.a.UserId])
        assert.same('pending', b.attrs.SaveState)
        drain()
        assertRejoined(b)
        assert.same(2, env.quest:get_state(b).count)
        assert.same(2, env.values.u560.extra.quest.count)
        local current = env.save.sessions[b.UserId]
        env.players.PlayerRemoving:Fire(env.a)
        assert.are.equal(current, env.save.sessions[b.UserId])
        assertRejoined(b)
    end)

    it('test_retry_failure_finishes_without_blocking_other_user', function()
        fact('worm:failure')
        env.failedToken = env.save.sessions[env.a.UserId].token
        env.players.PlayerRemoving:Fire(env.a)
        local b = join(env.a.UserId)
        env.failWrite = true
        drain()
        env.failWrite = false
        local other = join(561)
        drain()
        assert.same('ready', other.attrs.SaveState)
        assert.same('pending', b.attrs.SaveState)
        env.failWrite = true
        for _ = 1, 3 do env.save:update() drain() end
        env.failWrite = false
        drain()
        -- 旧写失败关闭屏障，新玩家仍可从最后确认的存档恢复。
        assertRejoined(b)
        assert.same(0, env.quest:get_state(b).count)
    end)

    it('test_story_read_waiting_for_quest_survives_rejoin', function()
        assert.same(1, #env.remotes.RequestStory.OnServerEvent.handlers)
        assert.same(1, #env.remotes.StoryRead.OnServerEvent.handlers)
        env.remotes.RequestStory.OnServerEvent:Fire(env.a, {})
        fact('worm:story')
        env.remotes.StoryRead.OnServerEvent:Fire(env.a, { action = 'read', readKey = GameCfg.Story.ReadKey or 'opening' })
        env.players.PlayerRemoving:Fire(env.a)
        local b = join(env.a.UserId)
        drain()
        assertRejoined(b)
        local restored = env.data:get_data_inst(b)
        assert.same(1, restored.Extra.quest.count)
        assert.is_true(restored.Extra.story.read[GameCfg.Story.ReadKey or 'opening'])
        assert.is_true(env.values.u560.extra.story.read[GameCfg.Story.ReadKey or 'opening'])
    end)

    it('test_waiting_player_removed_and_only_latest_rejoin_is_admitted', function()
        fact('worm:waiting')
        env.players.PlayerRemoving:Fire(env.a)
        local b = join(env.a.UserId)
        env.players.PlayerRemoving:Fire(b)
        drain()
        assert.is_nil(env.data:get_data_inst(b))
        assert.is_nil(env.save.sessions[b.UserId])
        assert.is_nil(env.runtime.life:get_state(b))
        local c = join(env.a.UserId)
        drain()
        env.a = c
        fact('worm:latest')
        env.players.PlayerRemoving:Fire(c)
        local d = join(c.UserId)
        local e = join(c.UserId)
        env.players.PlayerRemoving:Fire(d)
        drain()
        assertRejoined(e)
        assert.is_nil(env.data:get_data_inst(d))
        assert.same(2, env.quest:get_state(e).count)
    end)
end)

describe('远程事件公开创建入口（common/re_util）', function()
    local saved
    local MODULE = 'common.re_util'

    before_each(function()
        saved = {
            game = rawget(_G, 'game'), remote = rawget(_G, 'RemoteEvent'),
            reutil = rawget(_G, 'REUtil'), loaded = package.loaded[MODULE],
        }
        package.loaded[MODULE] = nil
        _G.game = { GetService = function(_, name)
            if name == 'World' then return { GetServerTime = function() return 1 end } end
            if name == 'RunService' then return { IsServer = function() return false end } end
        end }
    end)

    after_each(function()
        _G.game, _G.RemoteEvent, _G.REUtil = saved.game, saved.remote, saved.reutil
        package.loaded[MODULE] = saved.loaded
    end)

    it('test_creates_by_public_api_and_reuses_same_name', function()
        local calls, events = {}, {}
        _G.RemoteEvent = { New = function(name)
            calls[#calls + 1] = name
            events[name] = events[name] or { name = name }
            return events[name]
        end }
        local REUtil = require(MODULE)
        local first = REUtil:get_re('ShopResult')
        assert.are.equal(events['ShopResult'], first)
        assert.are.equal(first, REUtil:get_re('ShopResult'))
        assert.are.same({ 'ShopResult' }, calls)
    end)
end)

