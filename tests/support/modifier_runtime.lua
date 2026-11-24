-- modifier_system 离线边界：驱动真实 SpokeClock + PlayerTree + PlayerEffects + ModifierLeaf
-- （含活鱼 entity_store）与真实官方包 modifier_system.api；仅引擎单位、事件与 Timer 为替身。
local GameCfg = require('common.game_cfg')
local SpokeClock = require('common.spoke_clock')
local PlayerTree = require('server.world_host.player_tree')
local ModifierLeaf = require('server.world_host.modifier_leaf')

local Runtime = {}

local function make_dummy_data(player)
    return {
        Player = player,
        inited = true,
        load_state = 'ready',
        data = { FishCoin = 0, Zone = 'fishPond', containers = { itemBar = {}, backpack = {} }, Bait = {}, weapons = {} },
        extra = {
            inventory = { weapons = {}, selection = { held = {} } },
            growth = { potions = {}, upgrades = {} },
            survival = {},
            cooldowns = {},
        },
    }
end

function Runtime.new(clock)
    local start_now = clock or 100
    local e = { now = start_now, units = {}, timers = {}, spoke_clock = SpokeClock.new(start_now), step_hooks = {} }
    local function signal()
        local tokens = {}
        return {
            Connect = function(_, fn)
                local token = { fn = fn, active = true }
                tokens[#tokens + 1] = token
                return { Disconnect = function() token.active = false end }
            end,
            Fire = function(_, ...)
                for _, token in ipairs(tokens) do
                    if token.active then token.fn(...) end
                end
            end,
        }
    end
    function e.unit(name)
        local u = { Name = name, UnitId = #e.units + 1, attrs = {}, Destroying = signal() }
        e.units[#e.units + 1] = u
        function u:GetAttribute(k) return self.attrs[k] end
        function u:SetAttribute(k, v) self.attrs[k] = v end
        function u:get_component() return nil end
        function u:IsA(kind) return kind == 'BindableEvent' end
        function u:GetChildren()
            local result = {}
            for _, child in ipairs(e.units) do
                if child.Parent == self and not child.destroyed then result[#result + 1] = child end
            end
            return result
        end
        function u:FindFirstChild(name)
            for _, child in ipairs(self:GetChildren()) do
                if child.Name == name then return child end
            end
        end
        function u:Destroy()
            if self.destroyed then return end
            self.destroyed = true
            self.Destroying:Fire()
            for _, child in ipairs(self:GetChildren()) do child:Destroy() end
        end
        local event = signal()
        function u:Connect(fn) return event:Connect(fn) end
        function u:Fire(...) event:Fire(...) end
        return u
    end
    e.world = {
        GetServerTime = function() return e.now end,
        CreateAsset = function(_, key) return { e.unit(key) } end,
    }
    e.timerService = { CreateTimer = function(_, _, duration, _, callback)
        local t = { due = e.now + duration, callback = callback }
        function t:Cancel() self.cancelled = true end
        e.timers[#e.timers + 1] = t
        return t
    end }
    e.game = {
        GetService = function(_, name)
            if name == 'World' then return e.world end
            if name == 'TimerService' then return e.timerService end
            if name == 'RunService' then return { IsServer = function() return true end } end
            return {}
        end,
        CreateUnit = function(_, _, props)
            local u = e.unit(props.Name)
            return u
        end,
    }
    e.remote = { New = function() return { OnServerEvent = signal(), FireAllClients = function() end } end }

    local function advance_spoke_to(target_now)
        if target_now < e.spoke_clock.now() then
            e.spoke_clock = SpokeClock.new(target_now)
        elseif target_now > e.spoke_clock.now() then
            local dt = target_now - e.spoke_clock.now()
            e.spoke_clock:step(dt, target_now)
        end
        for _, fn in ipairs(e.step_hooks) do fn(target_now) end
    end

    function e.wait(seconds)
        local target = e.now + seconds
        while true do
            local nextTimer
            for _, t in ipairs(e.timers) do
                if not t.cancelled and t.due <= target and (not nextTimer or t.due < nextTimer.due) then
                    nextTimer = t
                end
            end
            if not nextTimer then break end
            e.now = nextTimer.due
            nextTimer.cancelled = true
            nextTimer.callback()
            advance_spoke_to(e.now)
        end
        e.now = target
        advance_spoke_to(e.now)
    end

    function e.load_modifier()
        local loaded = {}
        local env = setmetatable({ game = e.game, RemoteEvent = e.remote }, { __index = _G })
        env.require = function(name)
            if name:find('modifier_system', 1, true) then
                if not loaded[name] then
                    loaded[name] = assert(loadfile(name:gsub('%.', '/') .. '.lua', 't', env))()
                end
                return loaded[name]
            end
            return require(name)
        end
        local modifierAPI = env.require('server.packages.modifier_system.api')

        local mgr = {
            ModifierAPI = modifierAPI,
            Presets = {
                poison = 'test:poison',
                burn = 'test:burn',
                frost = 'test:frost',
                paralyze = 'test:paralyze',
                weak = 'test:weak',
            },
            PlayerTrees = {},
            Departing = {},
        }

        local function apply_dot(target, damage, source)
            if mgr.Vitals and mgr.Vitals.new_hit and mgr.Vitals.apply_hit then
                local hit = mgr.Vitals:new_hit(source, 'dot')
                mgr.Vitals:apply_hit(hit, target, damage)
            end
        end

        local preset_proxy = setmetatable({}, {
            __index = function(_, k)
                local src = mgr.Presets or GameCfg.Ability.ModifierPresets or {}
                return src[k]
            end,
        })

        local entity_store = ModifierLeaf.create_entity_store({
            modifier_api = modifierAPI,
            presets = preset_proxy,
            now = function() return e.now end,
            on_dot_tick = function(target, _kind, damage, source)
                local ref = type(target) == 'table' and target.Ref or target
                apply_dot(ref, damage, source)
            end,
        })
        mgr.EntityStore = entity_store

        e.step_hooks[#e.step_hooks + 1] = function(now)
            entity_store:step(now)
        end

        local function resolve_player(target)
            if not target then return nil end
            if type(target) == 'table' and target.UserId ~= nil then return target end
            local players = _G.game and _G.game.GetService and _G.game:GetService('Players')
            if players and players.GetPlayerFromCharacter then
                local ok, found = pcall(players.GetPlayerFromCharacter, players, target) -- 兼容替身 Players
                if ok and found then return found end
            end
            return nil
        end

        local function resolve_entity(target)
            if type(target) ~= 'table' then return target end
            if target.carrier then return target end
            if mgr.Vitals and mgr.Vitals.FishCarrier and mgr.Vitals.FishCarrier.resolve_carrier then
                local carrier = mgr.Vitals.FishCarrier:resolve_carrier(target)
                if carrier then return { carrier = carrier, Ref = target } end
            end
            return target
        end

        local function ensure_player_tree(player)
            local existing = mgr.PlayerTrees[player.UserId]
            if existing and existing.player == player and not existing:is_disposed() then
                if existing.states.character:now() ~= player.Character then
                    existing:set_character(player.Character)
                end
                return existing
            end
            if existing and not existing:is_disposed() then
                existing:dispose()
            end
            local pt = PlayerTree.spawn({
                player = player,
                data = make_dummy_data(player),
                clock = e.spoke_clock,
                effects = {
                    on_dot_tick = function(tree, _kind, damage, source)
                        apply_dot(tree.player, damage, source)
                    end,
                    on_mount_modifier_leaf = ModifierLeaf.make_slot_mounter({
                        modifier_api = modifierAPI,
                        presets = preset_proxy,
                    }),
                },
                mounts = {
                    attributes = function(s2, tree)
                        local initialized = false
                        s2:effect('TestSpeedRefresh', function(es)
                            local _ = es:d(tree.memos.move_multiplier)
                            if not initialized then
                                initialized = true
                                return
                            end
                            if not mgr.Departing[player.UserId] and mgr.Ability and mgr.Ability.refresh_move_speed then
                                mgr.Ability:refresh_move_speed(player)
                            end
                        end)
                    end,
                },
            })
            mgr.PlayerTrees[player.UserId] = pt
            return pt
        end

        function mgr:apply(source, target, kind, seconds)
            local player = resolve_player(target)
            if player then
                if not player.Character then return false, 'no-effect-owner' end
                local presets = self.Presets or GameCfg.Ability.ModifierPresets or {}
                local preset = presets[kind]
                if type(preset) ~= 'string' or preset == '' then
                    return false, 'modifier-preset-missing:' .. tostring(kind)
                end
                local pt = ensure_player_tree(player)
                local prev_mult = pt.memos.move_multiplier:now()
                local ok, err = pt:apply_modifier(kind, { duration = seconds, source = source })
                if ok and pt.memos.move_multiplier:now() == prev_mult
                    and not self.Departing[player.UserId] and self.Ability and self.Ability.refresh_move_speed then
                    self.Ability:refresh_move_speed(player)
                end
                return ok, err
            end
            local ent = resolve_entity(target)
            if type(ent) ~= 'table' or not ent.carrier then
                return false, 'no-effect-owner'
            end
            return entity_store:apply(source, ent, kind, seconds)
        end

        function mgr:apply_weapon_effect(source, target, effect)
            return self:apply(source, target, type(effect) == 'table' and effect.Kind or nil)
        end

        function mgr:get_remaining(target, kind)
            local player = resolve_player(target)
            if player then
                local pt = self.PlayerTrees[player.UserId]
                if not pt or pt:is_disposed() then return 0 end
                return pt:get_modifier_remaining(kind)
            end
            return entity_store:get_remaining(resolve_entity(target), kind)
        end

        function mgr:is_controlled(target)
            local player = resolve_player(target)
            if player then
                local pt = self.PlayerTrees[player.UserId]
                return pt ~= nil and not pt:is_disposed() and pt.states.is_paralyzed:now() == true
            end
            return entity_store:is_controlled(resolve_entity(target))
        end

        function mgr:get_move_multiplier(target)
            local player = resolve_player(target)
            if player then
                local pt = self.PlayerTrees[player.UserId]
                if not pt or pt:is_disposed() then return 1 end
                return pt.memos.move_multiplier:now()
            end
            return entity_store:get_move_multiplier(resolve_entity(target))
        end

        function mgr:clear(target, kind)
            local player = resolve_player(target)
            if player then
                local pt = self.PlayerTrees[player.UserId]
                if pt and not pt:is_disposed() then
                    pt:clear_modifier(kind)
                end
                return
            end
            entity_store:clear(resolve_entity(target), kind)
        end

        function mgr:clear_target(target, keepWeak)
            local player = resolve_player(target)
            if player then
                local pt = self.PlayerTrees[player.UserId]
                if pt and not pt:is_disposed() then
                    pt:clear_all_modifiers(keepWeak)
                end
                return
            end
            entity_store:clear_target(resolve_entity(target))
        end

        function mgr:update()
            advance_spoke_to(e.now)
            entity_store:step(e.now)
        end

        function mgr:on_character_removing(player)
            self.Departing[player.UserId] = true
            local pt = self.PlayerTrees[player.UserId]
            if pt and not pt:is_disposed() then
                pt:set_character(nil)
            end
        end

        function mgr:on_character_added(player)
            self.Departing[player.UserId] = nil
            local pt = self.PlayerTrees[player.UserId]
            if pt and not pt:is_disposed() then
                pt:set_character(player.Character)
                -- 若原角色直接替换（未经过 on_character_removing），确保非 weak 效果被清理
                pt:clear_all_modifiers(true)
            end
        end

        function mgr:on_player_added(player)
            self.Departing[player.UserId] = nil
            ensure_player_tree(player)
        end

        function mgr:on_player_removing(player)
            self.Departing[player.UserId] = true
            local pt = self.PlayerTrees[player.UserId]
            if pt then
                self.PlayerTrees[player.UserId] = nil
                if not pt:is_disposed() then pt:dispose() end
            end
            for _, other in pairs(self.PlayerTrees) do
                if other and not other:is_disposed() then
                    other:clear_modifiers_by_source(player)
                end
            end
            entity_store:clear_by_source(player)
        end

        function mgr:start() end
        return mgr
    end

    return e
end

-- 旧生存测试接入真实 SpokeClock + PlayerEffects + ModifierLeaf；速度投影是可观测边界，不复制效果计时。
function Runtime.attach_survival(survival, now)
    local e = Runtime.new(now())
    local modifier = e.load_modifier()
    local syncing = false
    local function sync(player)
        if not syncing then
            syncing = true
            if now() < e.now then e.now = now() end
            e.wait(math.max(0, now() - e.now))
            syncing = false
        end
        if player and player.Character and not player.Character.GetAttribute then
            local unit = e.unit('character')
            for k, v in pairs(unit) do if player.Character[k] == nil then player.Character[k] = v end end
        end
    end
    local apply, left = modifier.Apply, modifier.get_remaining
    function modifier:apply(source, target, kind, seconds) sync(target); return apply(self, source, target, kind, seconds) end
    function modifier:get_remaining(target, kind) sync(target); return left(self, target, kind) end
    local bases = {}
    survival.Modifier = modifier
    survival.SpeedWriter = { refresh_move_speed = function(_, player)
        local controller = player.Character and player.Character.Controller
        if not controller then return false end
        bases[player.UserId] = bases[player.UserId] or controller.WalkSpeed
        controller.WalkSpeed = bases[player.UserId] * modifier:get_move_multiplier(player)
        return true
    end }
    modifier.Ability = { refresh_move_speed = function(_, player) return survival.SpeedWriter:refresh_move_speed(player) end }
    return modifier
end

return Runtime
