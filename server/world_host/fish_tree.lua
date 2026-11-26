local EngineRead = require('common.engine_read'); local GameCfg = require('common.game_cfg')
local Number = require('common.number')
local FishCatch = require('common.fish_catch')
local MathWaterJudge = require('common.math_water_judge')
local MgrFishCarrier = require('server.world_host.fish_carrier')
local GarBiteNotice = require('common.gar_bite_notice')
local WildPhase = require('server.world_host.fish_phases.wild')
local LiftedPhase = require('server.world_host.fish_phases.lifted')
local EscapingPhase = require('server.world_host.fish_phases.escaping')
local CombatPhase = require('server.world_host.fish_phases.combat')
local BossPhase = require('server.world_host.fish_phases.boss')
local Spoke = require('common.packages.spoke.api')
local SpokeTree, Effect, State = Spoke.SpokeTree, Spoke.Effect, Spoke.State; local validate_clock ---@type fun(clock: any, caller?: string): table
local FishBehaviorKit = require('server.fish_behaviors.kit')
local function abilityApi(self)
    return self.ability_api
end

---@class FishTreeZone
---@field Id string
---@field Scene? FishTreeScene

---@class FishTreeScene
---@field Boundary? FishTreeBoundary
---@field Waters? table

---@class FishTreeBoundary
---@field MinX number
---@field MaxX number
---@field MinZ number
---@field MaxZ number

---@class FishTreeHost
---@field Fish table<integer, table>
---@field next_id integer
---@field held table
---@field links table
---@field clock table
---@field World? table
---@field CreateUnit? function
---@field ability_api? table
---@field ai? table
---@field ai_projection? table
---@field logger? table
---@field Ability? table
---@field Quest? table
---@field cast? table
---@field combat_request_conn? table
---@field get_player_tree? function
---@field on_state_changed? function
---@field on_killed? function
---@field request_lift function
---@field on_lifted function
---@field release function
---@field escaping function
---@field set_heading function
---@field end_air_attacks function
---@field end_boss_attack function
---@field release_carried function
---@field end_bite function
---@field end_move function
---@field publish_bite function
---@field publish_combat function
---@field start_combat_channel function
local Mgr = { Fish = {}, next_id = 0, held = {}, links = {} }

local function service(name)
    local host = rawget(_G, 'game')
    if not host then return nil end
    return host:GetService(name)
end

local function createUnit(self, kind, props)
    if self.CreateUnit then return self.CreateUnit(kind, props) end
    local world = self.World or service('World')
    if not world then return nil end
    return world:CreateUnit(kind, props)
end

Mgr.State = { await_lift = 'awaitLift', held = 'held', escaping = 'escaping',
    Combat = 'combat', attacking = 'attacking', sleeping = 'sleeping', wild = 'wild',
    flying = 'flying' }

local function cfg()
    return GameCfg.FishUnit
end

local distanceSq = FishBehaviorKit.distance_sq

function Mgr:now()
    local clock = rawget(self, 'clock')
    if type(clock) == 'table' and type(clock.now) == 'function' then return clock.now() end
    local world = self.World or service('World'); if not world or type(world.GetServerTime) ~= 'function' then error('FishTree:now 缺少注入时钟或 World', 2) end; return world:GetServerTime()
end

local readPosition = FishBehaviorKit.read_position
local flatDirection = FishBehaviorKit.flat_direction

local function towardWater(pos)
    local waters = GameCfg.Water.Zones
    for _, zone in ipairs(GameCfg.Zones) do
        ---@cast zone FishTreeZone
        local scene = zone.Scene
        local bounds = scene and scene.Boundary
        if scene and bounds and scene.Waters and #scene.Waters > 0
            and pos.x > bounds.MinX and pos.x < bounds.MaxX and pos.z > bounds.MinZ and pos.z < bounds.MaxZ then
            waters = scene.Waters
            break
        end
    end
    return MathWaterJudge.toward(waters, pos)
end

-- 入水只看 (x,z)：岸上鱼的 y 高于水面（V4 实测 2.15 > SurfaceY），按 y 判会永远判不进
local function inWater(pos)
    for _, zone in ipairs(GameCfg.Water.Zones) do
        if MathWaterJudge.in_zone(zone, { x = pos.x, y = zone.SurfaceY, z = pos.z }) then return zone end
    end
end

local function resetCrabRhythm(fish, now, params)
    if params.ActiveSec then fish.ActiveUntil = now + params.ActiveSec end
    fish.JabAt = -1
    fish.PinchAt = -1
    fish.SpecialAt = now + (params.SpinSec or 0)
    fish.ChargeAt = now + (params.ChargeSec or 0)
end

local function publishBite(self, payload)
    local ok, err = pcall(self.publish_bite, self, payload)
    if not ok then print('[FishTree] 首领咬预警推送失败', payload.kind, 'fish=' .. tostring(payload.fishId), tostring(err)) end
end

LiftedPhase.install(Mgr, {
    cfg = cfg, service = service, createUnit = createUnit, readPosition = readPosition,
})
EscapingPhase.install(Mgr, {
    cfg = cfg, service = service, readPosition = readPosition, distanceSq = distanceSq,
    flatDirection = flatDirection, towardWater = towardWater, inWater = inWater,
    resetCrabRhythm = resetCrabRhythm,
})
CombatPhase.install(Mgr, {
    distanceSq = distanceSq,
    readPosition = readPosition,
    flatDirection = flatDirection,
    towardWater = towardWater,
    inWater = inWater,
    resetCrabRhythm = resetCrabRhythm,
    publishBite = publishBite,
})

local function noCollide(unit, other)
    if unit and other and unit ~= other and unit.AddNoCollisionPairWithUnit then
        pcall(unit.AddNoCollisionPairWithUnit, unit, other)
    end
end

function Mgr:isolate(fish)
    local body = fish.carrier.body
    for _, player in ipairs(self:players()) do noCollide(body, player.Character) end
    for _, other in pairs(self.Fish) do
        if other ~= fish and other.carrier then
            noCollide(body, other.carrier.body)
            noCollide(body, other.carrier.receiver)
            noCollide(other.carrier.body, fish.carrier.receiver)
        end
    end
end

function Mgr:isolate_character(character)
    for _, fish in pairs(self.Fish) do
        if fish.carrier then noCollide(fish.carrier.body, character) end
    end
end

function Mgr.players(_)
    local players = service('Players')
    return players and players:GetPlayers() or {}
end

function Mgr:set_state(fish, value)
    fish.State = value
    if fish.state_signal and fish.state_signal:now() ~= value then
        fish.state_signal:set(value)
    end
    if type(self.on_state_changed) == 'function' then
        self.on_state_changed(fish)
    end
end

function Mgr:frame_clock()
    -- 时钟须显式注入
    -- 禁止隐式创建共享 Trigger
    local clock = rawget(self, 'clock')
    return validate_clock(clock, 'FishTree:frame_clock')
end

local function lifePhase(state)
    if state == Mgr.State.await_lift or state == Mgr.State.held then return 'lifted' end
    if state == Mgr.State.escaping then return 'escaping' end
    if state == Mgr.State.wild then return 'wild' end
    return 'combat'
end

function Mgr:begin_phase_frame(fish, now)
    if self.Fish[fish.Id] ~= fish then return nil end
    now = now or self:now()
    if self.ai and not MgrFishCarrier:sync_ai_position(fish.carrier) then
        self:remove(fish)
        return nil
    end
    local controlled = self:ai_controlled(fish, now)
    local canUpdate = not controlled or (fish.flee_at ~= nil and now >= fish.flee_at)
    if not canUpdate then return nil end
    return now
end

BossPhase.install(Mgr, {
    cfg = cfg,
    readPosition = readPosition,
    abilityApi = abilityApi,
    flatDirection = flatDirection,
    towardWater = towardWater,
    inWater = inWater,
    publishBite = publishBite,
})

function Mgr:mount_ai_projection(fish, s, phase)
    local projection = self.ai_projection
    if not projection then return end
    local active = s:memo('OfficialAiActive', function(ms)
        local value = ms:d(phase)
        return value == 'combat' or value == 'escaping'
    end)
    s:effect('OfficialAiLeaf', function(es)
        if not es:d(active) then return end
        local started = false
        local function start()
            if started or self.Fish[fish.Id] ~= fish then return end
            local ok, result = pcall(projection.start, projection, fish.Id)
            if ok and result == true then
                started = true
                return
            end
            local err = ok and 'start returned false' or result
            if self.logger and type(self.logger.error) == 'function' then
                self.logger.error('[FishTree] operation=AiStart', 'fish=' .. tostring(fish.Id), tostring(err))
            else
                print('[FishTree] operation=AiStart', 'fish=' .. tostring(fish.Id), tostring(err))
            end
        end
        start()
        es:subscribe(self:frame_clock().on_frame, start)
        es:on_cleanup(function()
            if not started or type(projection.stop) ~= 'function' then return end
            local ok, err = pcall(projection.stop, projection, fish.Id)
            if not ok then
                if self.logger and type(self.logger.error) == 'function' then
                    self.logger.error('[FishTree] operation=AiStop', 'fish=' .. tostring(fish.Id), tostring(err))
                else
                    print('[FishTree] operation=AiStop', 'fish=' .. tostring(fish.Id), tostring(err))
                end
            end
        end)
    end)
end

function Mgr:spawn_tree(fish)
    fish.state_signal = State.new('FishState:' .. tostring(fish.Id), fish.State)
    fish.holder_tree_state = State.new('HolderTree:' .. tostring(fish.Id), fish.holder_tree)
    local host = self
    local root = Effect.new('FishTree:' .. tostring(fish.Id), function(s)
        -- 根清理最先声明、最后执行：相位与 AI 叶子拆完后，再统一回收载体和宿主信号。
        s:on_cleanup(function() host:cleanup_fish(fish) end)
        local phase = s:memo('FishLifePhase', function(ms)
            return lifePhase(ms:d(fish.state_signal))
        end)
        local lifted = s:memo('IsLifted', function(ms) return ms:d(phase) == 'lifted' end)
        local combat = s:memo('IsCombat', function(ms) return ms:d(phase) == 'combat' end)
        local escaping = s:memo('IsEscaping', function(ms) return ms:d(phase) == 'escaping' end)
        local wild = s:memo('IsWild', function(ms) return ms:d(phase) == 'wild' end)

        s:phase('LiftedPhase', lifted, function(ps)
            LiftedPhase.mount(host, fish, ps)
        end)
        s:phase('CombatPhase', combat, function(ps)
            CombatPhase.mount(host, fish, ps)
        end)
        s:phase('EscapingPhase', escaping, function(ps)
            EscapingPhase.mount(host, fish, ps)
        end)
        s:phase('WildPhase', wild, function(ps)
            WildPhase.mount(host, fish, ps)
        end)
        fish.fault_dock = s:dock('FaultDock:' .. tostring(fish.Id))
        host:mount_ai_projection(fish, s, phase)
    end)
    local services = self.logger and { logger = self.logger } or nil
    fish.tree = SpokeTree.spawn('FishTree:' .. tostring(fish.Id), root, services)
    return fish.tree
end

function Mgr:spawn_landed(player, catch, position)
    local species = catch and GameCfg.Fish[catch.fishId]
    if not player or not species or type(catch.mult) ~= 'number' then return nil, 'bad-catch' end
    local carrier, err = MgrFishCarrier:spawn({
        CreateUnit = self.CreateUnit,
        Position = position,
        fish_id = catch.fishId,
        MaxHealth = species.Health,
        model_id = species.Model,
        Player = player,
        GravityEnabled = false,
        LinearDamping = cfg().LinearDamping,
        AngularDamping = cfg().AngularDamping,
    })
    if not carrier then return nil, err end
    self.next_id = self.next_id + 1
    local holder_tree = self.get_player_tree and self:get_player_tree(player) or nil
    local fish = { Id = self.next_id, Owner = player, fish_id = catch.fishId, mult = catch.mult,
        carrier = carrier, State = Mgr.State.await_lift, Anchor = position, LiftAttempts = 0,
        threat = {}, holder_tree = holder_tree }
    self.Fish[fish.Id] = fish
    if carrier.receiver and carrier.receiver.Controller then
        pcall(function() carrier.receiver.Controller.LiftedEnabled = false end)
    end
    self:isolate(fish)
    self:spawn_tree(fish)
    local body = carrier.body
    if body and body.OnLiftedBegin then
        local beginConn = body.OnLiftedBegin:Connect(function(liftunit) self:on_lifted(fish, liftunit) end)
        fish.conns = { beginConn }
        if body.OnLiftedEnd then
            fish.conns[#fish.conns + 1] = body.OnLiftedEnd:Connect(function() self:release(fish, 'liftEnd') end)
        end
    end
    self:request_lift(fish)
    if type(self.on_state_changed) == 'function' then self.on_state_changed(fish) end
    return fish
end

function Mgr:spawn_blast_fish(fishId, mult, position, owner)
    local species = GameCfg.Fish[fishId]
    if not species or type(mult) ~= 'number' or not position then return nil, 'bad-fish' end
    local carrier, err = MgrFishCarrier:spawn({
        CreateUnit = self.CreateUnit,
        Position = position,
        fish_id = fishId,
        MaxHealth = species.Health,
        model_id = species.Model,
        Player = owner,
        GravityEnabled = false,
        LinearDamping = cfg().LinearDamping,
        AngularDamping = cfg().AngularDamping,
    })
    if not carrier then return nil, err end
    self.next_id = self.next_id + 1
    local ttl = (GameCfg.Ability.Throw and GameCfg.Ability.Throw.FishTtlSec) or 60
    local fish = { Id = self.next_id, Owner = owner, fish_id = fishId, mult = mult,
        carrier = carrier, State = Mgr.State.wild, Anchor = position,
        wild_until = self:now() + ttl, threat = {} }
    self.Fish[fish.Id] = fish
    if carrier.receiver and carrier.receiver.Controller then
        pcall(function() carrier.receiver.Controller.LiftedEnabled = false end)
    end
    self:isolate(fish)
    self:spawn_tree(fish)
    if type(self.on_state_changed) == 'function' then self.on_state_changed(fish) end
    return fish
end

local function trimOldest(self, list, extra, keep, why)
    for _, fish in ipairs(list) do
        if extra <= 0 then return end
        if fish ~= keep then
            print('[FishTree] 在逃超出' .. why .. '，清最旧', 'fish=' .. tostring(fish.Id))
            self:remove(fish)
            extra = extra - 1
        end
    end
end

function Mgr:enforce_escape_cap(trigger, keep)
    local c = cfg()
    if trigger then
        local own = {}
        for _, fish in ipairs(self:escaping()) do
            if fish.escape_by == trigger then own[#own + 1] = fish end
        end
        trimOldest(self, own, #own - c.PerPlayerEscapeCap, keep, '每人上限')
    end
    local list = self:escaping()
    trimOldest(self, list, #list - #self:players() * c.GlobalEscapePerPlayer, keep, '全局上限')
end

function Mgr:find_by_carrier(carrier)
    for _, fish in pairs(self.Fish) do
        if fish.carrier == carrier then return fish end
    end
end

function Mgr:take_killed(fish)
    if not fish or self.Fish[fish.Id] ~= fish then return nil end
    local holder = fish.State == Mgr.State.held and fish.holder or nil
    local pos = holder and holder.Character and readPosition(holder.Character)
        or readPosition(fish.carrier.body) or fish.Anchor
    self:remove(fish)
    print('[FishTree] 被打死', fish.fish_id, fish.mult, holder and ('held by ' .. tostring(holder.UserId)) or fish.State,
        'fish=' .. tostring(fish.Id))
    if holder and self.cast then self.cast:PushState(holder) end
    if fish.Owner and self.Quest then
        self.Quest:notify('Kill', fish.Owner, { itemId = fish.fish_id, eventId = 'kill:' .. tostring(fish.Id) })
    end
    return { fishId = fish.fish_id, mult = fish.mult, position = pos }
end

function Mgr:get_fish(player)
    local list = {}
    for _, fish in pairs(self.Fish) do
        if fish.Owner == player then list[#list + 1] = fish end
    end
    table.sort(list, function(a, b) return a.Id < b.Id end)
    return list
end

function Mgr.weight(_, fish)
    return FishCatch.weight(GameCfg.Fish[fish.fish_id], fish.mult)
end

function Mgr.Price(_, fish)
    return FishCatch.Price(GameCfg.Fish[fish.fish_id], fish.mult)
end

function Mgr:cleanup_fish(fish)
    if not fish or fish.cleaned then return end
    fish.cleaned = true
    self:end_boss_attack(fish, 'gone')
    self:end_air_attacks(fish, 'gone')
    if self.ai then self.ai:remove(fish) end
    if fish.Carry then self:release_carried(fish, nil, 'died') end
    self:end_bite(fish, 'gone')
    if fish.discharge_at then publishBite(self, GarBiteNotice.clear(fish.Id, 'gone')) end
    self:end_move(fish, 'gone')
    fish.wake_at, fish.MoveName = nil, nil
    self.Fish[fish.Id] = nil
    self:publish_combat(fish, true)
    if self.Ability then self.Ability:remove_fish(fish) end
    for _, conn in ipairs(fish.conns or {}) do conn:Disconnect() end
    fish.conns = nil
    if fish.holder and self.held[fish.holder.UserId] == fish then self.held[fish.holder.UserId] = nil end
    MgrFishCarrier:despawn(fish.carrier)
    if fish.mount then pcall(function() fish.mount:Destroy() end) end
    fish.mount = nil
end

function Mgr:on_carrier_died(carrier)
    local fish = self:find_by_carrier(carrier)
    if not fish then return false end
    local killed = self:take_killed(fish)
    if killed and type(self.on_killed) == 'function' then
        self.on_killed({
            fishId = killed.fishId,
            mult = killed.mult,
            zoneId = GameCfg.Fish[killed.fishId] and GameCfg.Fish[killed.fishId].ZoneId or nil,
            position = killed.position,
        })
    end
    return killed ~= nil
end

function Mgr:remove(fish)
    if not fish or fish.cleaned then return end
    self.Fish[fish.Id] = nil
    if fish.tree and fish.tree.is_detached ~= true then fish.tree:dispose() end
    self:cleanup_fish(fish)
    if type(self.on_state_changed) == 'function' then self.on_state_changed(fish) end
end

function Mgr:start()
    if self.ai then self.ai:start() end
    self.World = service('World')
    local now = self:now()
    for _, fish in pairs(self.Fish) do
        if fish.Flight and not fish.air_attacks and GameCfg.Fish[fish.fish_id].ZoneId == 'reefIsland' then
            local profile = fish.Flight.profile
            fish.air_attacks = {}
            fish.NextReefDiveAt = now + (profile.DiveIntervalSec or math.huge)
            fish.NextThrowAt = now + (profile.ThrowIntervalSec or math.huge)
            fish.flight_at = now
        end
    end
    self:start_combat_channel()
end

function Mgr:clear_links(player)
    local links = self.links[player.UserId]
    if not links then return end
    if links.Added then links.Added:Disconnect() end
    if links.Died then links.Died:Disconnect() end
    self.links[player.UserId] = nil
end

function Mgr:stop()
    for _, fish in pairs(self.Fish) do
        self:end_air_attacks(fish, 'stop')
        self:end_boss_attack(fish, 'stop')
        if fish.Aquatic then fish.Aquatic.leap=nil; fish.Aquatic.head_at=nil end
        if fish.Carry then self:release_carried(fish, nil, 'stop') end
    end
    if self.ai then
        self.ai:stop()
        for _, fish in pairs(self.Fish) do
            self:end_bite(fish, 'stop')
            self:end_move(fish, 'stop')
            if fish.Carry then self:release_carried(fish, nil, 'stop') end
        end
    end
    for _, links in pairs(self.links) do
        if links.Added then links.Added:Disconnect() end
        if links.Died then links.Died:Disconnect() end
    end
    self.links = {}
    if self.combat_request_conn then self.combat_request_conn:Disconnect() end
    self.combat_request_conn = nil
end

function Mgr:on_died(player)
    for _, fish in pairs(self.Fish) do
        if fish.boss_warn and fish.boss_warn.Target == player then
            self:end_boss_attack(fish,'gone')
            if fish.Aquatic then fish.Aquatic.leap=nil; fish.Aquatic.head_at=nil end
        end
        if fish.Carry and fish.Carry.target_player == player then self:release_carried(fish,nil,'gone') end
    end
    if self.ai then
        for _, current in pairs(self.Fish) do
            self.ai:custom(current)
            if current.heading then self:set_heading(current, current.heading.x, current.heading.z) end
            if current.Carry and current.Carry.target_player == player then self:release_carried(current, nil, 'gone') end
            if current.bite_aim and current.bite_aim.Target == player then self:end_bite(current, 'gone') end
            if current.Move and current.Move.Target == player then self:end_move(current, 'gone') end
        end
    end
    if self.cast and self.cast.abort then self.cast:abort(player) end
end

function Mgr:watch_character(player, character)
    local links = self.links[player.UserId]
    if links.Died then links.Died:Disconnect() end
    links.Died = nil
    if not character then return end
    self:isolate_character(character)
    local controller = character.Controller
    if controller and controller.Died then
        links.Died = controller.Died:Connect(function() self:on_died(player) end)
    end
end

function Mgr:on_player_added(player)
    self:clear_links(player)
    local links = {}
    self.links[player.UserId] = links
    links.Added = player.CharacterAdded:Connect(function(character)
        self:watch_character(player, character)
    end)
    self:watch_character(player, player.Character)
end

function Mgr:on_player_removing(player)
    self:clear_links(player)
    for _, fish in pairs(self.Fish) do
        if self.ai then
            self.ai:custom(fish)
            if fish.heading then self:set_heading(fish, fish.heading.x, fish.heading.z) end
        end
        if fish.Carry and fish.Carry.target_player == player then self:release_carried(fish, nil, 'gone') end
        if fish.boss_warn and fish.boss_warn.Target == player then
            self:end_boss_attack(fish,'gone')
            if fish.Aquatic then fish.Aquatic.leap=nil; fish.Aquatic.head_at=nil end
        end
        if fish.bite_aim and fish.bite_aim.Target == player then self:end_bite(fish, 'gone') end
        if fish.Move and fish.Move.Target == player then self:end_move(fish, 'gone') end
        if fish.threat then fish.threat[player] = nil end
        if fish.target_override == player then fish.target_override = nil end
    end
    for _, fish in ipairs(self:get_fish(player)) do
        if fish.State == Mgr.State.await_lift then
            local species = GameCfg.Fish[fish.fish_id]
            self:set_state(fish, Mgr.State.escaping)
            fish.escape_at = self:now()
            fish.flee_at = self:now() + (species and species.EscapeSec or 1)
            fish.Owner = nil
            fish.holder = nil
        end
    end
end

function Mgr:ai_controlled(fish, now)
    if not self.ai then return false end
    local controlled = self.ai.Stopped == true
    if self.Ability and self.Ability.fish_paralyzed then
        local ok, value = pcall(self.Ability.fish_paralyzed, self.Ability, fish)
        if not ok then print('[FishTree] 控制读取失败', fish.Id, tostring(value)); controlled = true
        else controlled = controlled or value == true end
    end
    if controlled then
        if not fish.control_at then
            fish.control_at = now
            fish.official_roll_from, fish.roll_from = nil, nil
            if fish.Phase then fish.Phase.pending = nil end
            self:end_boss_attack(fish, 'controlled')
            if fish.Aquatic then
                fish.Aquatic.leap,fish.Aquatic.head_at,fish.Aquatic.head_center=nil,nil,nil
                fish.Aquatic.last_at=now
            end
            if fish.Flight then fish.Flight.Phase = 'cruise'; fish.dive_active = false end
            self:end_bite(fish, 'controlled')
            self:end_move(fish, 'controlled')
            self:end_air_attacks(fish, 'controlled')
            if fish.Flight then fish.air_attacks = {} end
            if fish.Carry then self:release_carried(fish, nil, 'controlled') end
        end
        self.ai:pause(fish, true)
        fish.carrier.body.LinearVelocity = Vector3.New(0, 0, 0)
        fish.combat_step_at, fish.flight_at, fish.phase_at = now, now, now
        return true
    end
    if fish.control_at then
        local elapsed = now - fish.control_at
        for _, key in ipairs({ 'ActiveUntil', 'SpecialAt', 'JabAt', 'PinchAt', 'ChargeAt',
            'JumpAt', 'RoarAt', 'TailAt', 'ClawAt', 'NextDischargeAt', 'WakeAt',
            'NextReefDiveAt', 'NextThrowAt' }) do
            if fish[key] then fish[key] = fish[key] + elapsed end
        end
        if fish.Phase then
            for key, at in pairs(fish.Phase.cooldown) do fish.Phase.cooldown[key] = at + elapsed end
        end
        if fish.Flight then fish.Flight.next_dive_at = fish.Flight.next_dive_at + elapsed end
        if fish.Aquatic then
            fish.Aquatic.next_leap_at=fish.Aquatic.next_leap_at+elapsed
            fish.Aquatic.last_at=now
        end
        fish.control_at = nil
        self.ai:pause(fish, false)
        if fish.heading then self:set_heading(fish, fish.heading.x, fish.heading.z) end
    end
    return false
end

function Mgr:update()
    self:frame_clock().on_frame:invoke({ dt = 0, now = self:now() })
    self:enforce_escape_cap(nil)
end

function Mgr.new(opts)
  local clock = type(opts) == 'table' and opts.clock or nil; validate_clock(clock, 'FishTree.new')
  return setmetatable({ Fish = {}, next_id = 0, held = {}, links = {}, clock = clock }, { __index = Mgr })
end

function Mgr:damage_fish(fish, amount)
  if type(fish) ~= 'table' or self.Fish[fish.Id] ~= fish then return false, 'invalid-fish' end
  if not Number.is_finite_number(amount) or amount <= 0 then return false, 'invalid-amount' end
  local carrier = fish.carrier
  if not carrier then return false, 'missing-carrier' end
  local logger = rawget(self, 'logger')
  local ctx = { context = 'FishTree.damage_fish (fish=' .. tostring(fish.Id) .. ')', logger = logger }
  local function log_fail(stage, err)
    local msg = string.format('[FishTree] damage_fish %s失败 fish=%s error=%s', stage, tostring(fish.Id), tostring(err))
    if logger and type(logger.error) == 'function' then
      pcall(logger.error, logger, msg)
    else
      print(msg)
    end
  end
  local ok_cur, cur_health, reason_cur = EngineRead.read_field(carrier, 'Health', ctx)
  if not ok_cur then
    if reason_cur ~= 'missing' then
      log_fail('读取载体血量', reason_cur)
      return false, reason_cur
    end
    cur_health = 0
  elseif not Number.is_finite_number(cur_health) then
    log_fail('读取载体血量', 'non-finite:' .. tostring(cur_health))
    return false, 'invalid-health'
  end
  local health = cur_health - amount
  if health < 0 then health = 0 end
  local ok_ctrl, controller, reason_ctrl = EngineRead.read_field(carrier, 'Controller', ctx)
  if not ok_ctrl and reason_ctrl ~= 'missing' then
    log_fail('读取控制器', reason_ctrl)
    return false, reason_ctrl
  end
  local prev_ctrl_health = nil
  if ok_ctrl and controller then
    local ok_ch, ch_val = EngineRead.read_field(controller, 'Health', ctx)
    if ok_ch then prev_ctrl_health = ch_val end
    local ok_cw, _, reason_cw = EngineRead.write_field(controller, 'Health', health, ctx)
    if not ok_cw then
      log_fail('写入控制器血量', reason_cw)
      return false, reason_cw
    end
  end
  local ok_hw, _, reason_hw = EngineRead.write_field(carrier, 'Health', health, ctx)
  if not ok_hw then
    if ok_ctrl and controller and prev_ctrl_health ~= nil then
      EngineRead.write_field(controller, 'Health', prev_ctrl_health, ctx)
    end
    log_fail('写入载体血量', reason_hw)
    return false, reason_hw
  end
  local on_state_changed = rawget(self, 'on_state_changed')
  if health <= 0 then
    local ok_died, died_res = pcall(self.on_carrier_died, self, carrier)
    if not ok_died or died_res == false then
      local err = not ok_died and tostring(died_res) or 'on-carrier-died-failed'
      log_fail('写入击杀状态', err)
      return false, err
    end
  elseif type(on_state_changed) == 'function' then
    local ok_chg, chg_err = pcall(on_state_changed, fish)
    if not ok_chg then
      log_fail('通知状态变更', chg_err)
      return false, tostring(chg_err)
    end
  end
  return true
end

function Mgr:fault(fish, reason)
  if type(fish) ~= 'table' or self.Fish[fish.Id] ~= fish then return false end
  if not fish.fault_dock or not fish.tree or fish.tree.is_detached == true then return false end
  fish.fault_dock:effect('fault', function()
    error(tostring(reason or 'fish'), 0)
  end)
  return fish.tree.fault ~= nil
end

validate_clock = function(clock, caller)
  if type(clock) ~= 'table' or type(clock.now) ~= 'function' or type(clock.on_frame) ~= 'table' then
    error(tostring(caller or 'FishTree') .. ' 缺少有效的注入时钟（需包含 now 与 on_frame）', 3)
  end
  return clock
end

return Mgr
