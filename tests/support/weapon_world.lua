--
local GameCfg = require('common.game_cfg')
local SpokeClock = require('common.spoke_clock')
local spoke = require('common.packages.spoke.api')
local PlayerData = require('server.data.player_data')
local SwingRegistry = require('server.swing_registry')
local PlayerWeapon = require('server.world_host.player_weapon')

local M = {}
M.__index = M

--- 建一个空世界壳；调用方随后 :set_up() 搭世界、:tear_down() 拆除
--- （与 revive_world 同一构造/拆除入口名）。
--- opts.players = { { player, data? }, ... } 可指定世界内玩家；缺省 42 / 43 两名玩家。
function M.new(opts)
    return setmetatable({ opts = type(opts) == 'table' and opts or {} }, M)
end

--- 引擎边界玩家替身：只给存档 Sync 需要的 SetAttribute 与武器会话读的角色位姿。
function M.player(id)
    return {
        UserId = id,
        SetAttribute = function() end,
        Character = {
            Position = { x = 0, y = 2, z = 0 },
            Rotation = { GetForward = function() return { x = 0, y = 0, z = 1 } end },
        },
    }
end

local function state(name, value)
    return spoke.State.new('WeaponWorld.' .. name, value)
end

function M:set_up()
    local ctx = self
    ctx.saved_print = rawget(_G, 'print')
    ctx.now = 1000
    ctx.clock = SpokeClock.new(ctx.now)
    ctx.replies, ctx.applied, ctx.spawnedFish, ctx.visuals = {}, {}, {}, {}
    ctx.casts, ctx.effects, ctx.rays = {}, {}, {}
    ctx.order = 0
    ctx.rayHit, ctx.lastRay, ctx.create_unit, ctx.random = nil, nil, nil, nil
    ctx.applyOk = true
    ctx.sessions, ctx.players = {}, {}
    ctx.save = ctx.opts.save

    ctx.remote = {
        get_re = function(_, name)
            return { FireClient = function(_, player, payload)
                ctx.replies[#ctx.replies + 1] = { name = name, player = player, payload = payload }
            end }
        end,
    }
    ctx.ability = {
        cast_ability = function(unit, index)
            ctx.casts[#ctx.casts + 1] = { unit = unit, index = index }
            return true
        end,
    }
    ctx.physics = { Raycast = function(self, origin, direction, _)
        assert(self == ctx.physics, 'PhysicsService:Raycast 必须使用冒号调用')
        ctx.lastRay = { o = origin, d = direction }
        ctx.rays[#ctx.rays + 1] = ctx.lastRay
        if type(ctx.rayHit) == 'function' then
            return ctx.rayHit(origin, direction, #ctx.rays)
        end
        return ctx.rayHit
    end }
    ctx.players_service = {
        GetPlayers = function() return ctx.players end,
        GetPlayerFromCharacter = function(_, unit)
            for _, player in ipairs(ctx.players) do
                if player.Character == unit then return player end
            end
            return nil
        end,
    }
    ctx.world_service = {
        CreateUnit = function(_, unitType, values)
            if ctx.create_unit then return ctx.create_unit(unitType, values) end
            local unit = { destroyCount = 0, Position = { x = 0, y = 0, z = 0 } }
            unit.Destroy = function() unit.destroyCount = unit.destroyCount + 1 end
            ctx.visuals[#ctx.visuals + 1] = {
                unitType = unitType, name = values and values.Name, unit = unit,
            }
            return unit
        end,
    }
    ctx.fish_unit = {
        Fish = {},
        spawn_blast_fish = function(_, fishId, mult, pos, owner)
            ctx.order = ctx.order + 1
            ctx.spawnedFish[#ctx.spawnedFish + 1] = {
                order = ctx.order, fishId = fishId, mult = mult, pos = pos, owner = owner,
            }
            local id = 1000 + #ctx.spawnedFish
            ctx.fish_unit.Fish[id] = { Id = id, carrier = { body = { Position = pos } } }
            return { Id = id }
        end,
    }
    ctx.fish_carrier = { resolve_carrier = function() return nil end }

    SwingRegistry.set_clock(function() return ctx.clock.now() end)

    local specs = ctx.opts.players
    if type(specs) == 'table' and #specs > 0 then
        for _, spec in ipairs(specs) do ctx:_add(spec.player, spec.data) end
        ctx.player = specs[1].player
        ctx.other = specs[2] and specs[2].player or nil
    else
        ctx.player = ctx.opts.player or M.player(42)
        ctx.other = ctx.opts.other or M.player(43)
        ctx:_add(ctx.player, ctx.opts.data)
        ctx:_add(ctx.other)
    end
    ctx.data = ctx.sessions[ctx.player] and ctx.sessions[ctx.player].data or nil
end

function M:tear_down()
    for _, session in pairs(self.sessions or {}) do
        if session.spokeTree then
            pcall(function() session.spokeTree:dispose() end)
        end
        session.spokeTree = nil
    end
    self.sessions = {}
    SwingRegistry.set_clock(nil)
    if self.saved_print ~= nil then _G.print = self.saved_print end
    if self.savedWaterZones ~= nil then
        GameCfg.Water.Zones = self.savedWaterZones
        self.savedWaterZones = nil
    end
end

--- 注册一名玩家会话并挂载真实 PlayerWeapon；data 缺省时按真实存档新建。
function M:_add(player, data)
    local ctx = self
    local dataInst = data or PlayerData.new(player)
    if not dataInst.inited then dataInst:Init() end
    local tree = {
        player = player,
        data = dataInst,
        clock = ctx.clock,
        states = {
            held = state('held', { kind = nil, id = nil, slot = nil }),
            selected_weapon = state('selected_weapon', nil),
            weapons = state('weapons', {}),
        },
        memos = {
            can_act = state('can_act', true),
            weapon_damage_scales = state('scales', { melee = 1, ranged = 1, explosive = 1 }),
        },
        get_item_bar_snapshot = function() return dataInst:GetItemBarSnapshot() end,
    }
    local session = {
        player = player,
        data = dataInst,
        tree = tree,
        opts = {
            remote = ctx.remote,
            save = ctx.save,
            physics = ctx.physics,
            players_service = ctx.players_service,
            ability = ctx.ability,
            fish_unit = ctx.fish_unit,
            fish_carrier = ctx.fish_carrier,
            world = ctx.world_service,
            random = function(a, b)
                local fn = ctx.random or math.random
                return fn(a, b)
            end,
            new_hit = function(source, category)
                ctx.order = ctx.order + 1
                return { id = ctx.order, source = source, category = category }
            end,
            apply_hit = function(hit, target, amount)
                ctx.order = ctx.order + 1
                ctx.applied[#ctx.applied + 1] = {
                    order = ctx.order, hit = hit, target = target, amount = amount,
                }
                return ctx.applyOk ~= false, amount
            end,
            apply_effect = function(source, target, kind)
                ctx.effects[#ctx.effects + 1] = { source = source, target = target, kind = kind }
                return true
            end,
        },
    }
    ctx.sessions[player] = session
    ctx.players[#ctx.players + 1] = player
    ctx:sync(player)
    ctx:_mount(session)
    return session
end

function M:_mount(session)
    session.spokeTree = spoke.SpokeTree.spawn(spoke.Effect.new('WeaponWorld', function(scope)
        session.handle = PlayerWeapon.mount(scope, session.tree, session.opts)
    end))
end

--- 把存档最新字段投影进树状态：武器/选中/held 与三类伤害倍率（真源取 PlayerData:weapon_damage_scale，
--- 与 PlayerEffects 的 AttrModel 派生同源）。
function M:sync(player)
    local session = assert(self.sessions[player], '未注册的玩家')
    local snap = session.data:GetItemBarSnapshot()
    session.tree.states.held:set(snap and snap.held or { kind = nil, id = nil, slot = nil })
    session.tree.states.selected_weapon:set(snap and snap.selectedWeapon or nil)
    session.tree.states.weapons:set(snap and snap.weapons or {})
    local scales = {}
    for _, kind in ipairs({ 'melee', 'ranged', 'explosive' }) do
        scales[kind] = session.data:weapon_damage_scale(kind)
    end
    session.tree.memos.weapon_damage_scales:set(scales)
end

--- 推进世界时钟：投掷飞行、换弹与射速都以它为准。
function M:advance(seconds)
    self.now = self.now + seconds
    self.clock:advance(seconds)
end

--- 发放并装备一把武器（存档真源 → 下一次 sync 时投影进树）。
function M:equip(player, weaponId)
    local data = assert(self.sessions[player], '未注册的玩家').data
    assert(data:GrantWeapon(weaponId, 1), '发放武器失败')
    assert(data:HoldWeapon(weaponId), '装备武器失败')
end

--- 公开入口：先同步存档投影，再驱动 PlayerWeapon 的 handle。
function M:handle(player, payload)
    self:sync(player)
    return assert(self.sessions[player], '未注册的玩家').handle:handle(payload)
end

function M:attack(player, payload)
    local message = { action = 'attack' }
    for key, value in pairs(payload or {}) do message[key] = value end
    self:handle(player, message)
    return M.last_reply(self, player)
end

function M:throw(player, slot, target, extra)
    local payload = { action = 'throw', slot = slot, target = target }
    for key, value in pairs(extra or {}) do payload[key] = value end
    self:handle(player, payload)
    return M.last_reply(self, player)
end

function M:reload(player)
    self:handle(player, { action = 'reload' })
    return M.last_reply(self, player)
end

function M:guard(player, unit, index)
    return assert(self.sessions[player], '未注册的玩家').handle:guard(unit, index)
end

--- 玩家离场：销毁其作用域（与 PlayerTree dispose 同一清理路径），并从 Players 服务列表移除。
function M:remove_player(player)
    local session = assert(self.sessions[player], '未注册的玩家')
    if session.spokeTree then session.spokeTree:dispose() end
    session.spokeTree = nil
    for index, entry in ipairs(self.players) do
        if entry == player then
            table.remove(self.players, index)
            break
        end
    end
end

--- 用新的挂载参数重建该玩家的武器会话（例如注入存档协议桩）。
function M:remount(player, patch)
    local session = assert(self.sessions[player], '未注册的玩家')
    for key, value in pairs(patch or {}) do session.opts[key] = value end
    if session.spokeTree then session.spokeTree:dispose() end
    self:_mount(session)
end

--- 给某名玩家的道具栏发一件爆炸物并选中它，返回槽位。失败才拼消息（避免每次通过都付拼接）。
function M:give_explosive(player, itemId, count)
    local data = assert(self.sessions[player], '未注册的玩家').data
    for _ = 1, count or 1 do
        if not data:AddItem(itemId) then error('道具栏放不下 ' .. tostring(itemId), 2) end
    end
    local snap = data:GetItemBarSnapshot()
    local slot
    for index, entry in pairs(snap.slots) do
        if entry.itemId == itemId then slot = index break end
    end
    if slot == nil then error('道具栏里没有 ' .. tostring(itemId), 2) end
    if data.data.selected_slot ~= slot and not data:SelectSlot(slot) then
        error('选中爆炸物失败: ' .. tostring(slot), 2)
    end
    return slot
end

--- 替换水区表（投掷落水判定与保底鱼来源），tear_down 时恢复。
function M:set_water_zones(zones)
    if self.savedWaterZones == nil then self.savedWaterZones = GameCfg.Water.Zones end
    GameCfg.Water.Zones = zones or {}
end

function M.last_reply(ctx, player)
    for index = #ctx.replies, 1, -1 do
        local record = ctx.replies[index]
        if record.player == player then return record.payload end
    end
    return nil
end

return M
