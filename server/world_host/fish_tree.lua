local GameCfg = require('common.game_cfg')
local Number = require('common.number')
local FishCatch = require('common.fish_catch')
local MathWaterJudge = require('common.math_water_judge')
local MgrFishCarrier = require('server.world_host.fish_carrier')
local FlightPath = require('common.flight_path')
local CarryMount = require('common.carry_mount')
local BossPhase = require('common.boss_phase')
local GarBiteNotice = require('common.gar_bite_notice')
local BossMoves = require('common.cfg.boss_moves')
local FishBehaviors = require('server.fish_behaviors')
local Spoke = require('common.packages.spoke.api')
local SpokeTree, Effect, State = Spoke.SpokeTree, Spoke.Effect, Spoke.State

local function abilityApi(self)
    return self.ability_api
end

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

local function distanceSq(pos, cp)
    if not pos or not cp then return math.huge end
    return (cp.x - pos.x) * (cp.x - pos.x) + (cp.z - pos.z) * (cp.z - pos.z)
end

function Mgr:now()
    local world = self.World or service('World')
    return world:GetServerTime()
end

local function isBadNumber(v)
    return not Number.is_finite_number(v)
end

local function readPosition(unit)
    local ok, pos = pcall(function() return unit.Position end)
    if ok and pos and not isBadNumber(pos.x) and not isBadNumber(pos.y) and not isBadNumber(pos.z) then
        return pos
    end
end

local function resetCrabRhythm(fish, now, params)
    if params.ActiveSec then fish.ActiveUntil = now + params.ActiveSec end
    fish.JabAt = -1
    fish.PinchAt = -1
    fish.SpecialAt = now + (params.SpinSec or 0)
    fish.ChargeAt = now + (params.ChargeSec or 0)
end

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

function Mgr:players()
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
    if not self.clock then
        self.clock = { on_frame = Spoke.Trigger.new('FishHostFrame') }
    end
    return self.clock
end

local function lifePhase(state)
    if state == Mgr.State.await_lift or state == Mgr.State.held then return 'lifted' end
    if state == Mgr.State.escaping then return 'escaping' end
    if state == Mgr.State.wild then return 'wild' end
    return 'combat'
end

function Mgr:update_fish(fish, now)
    if self.Fish[fish.Id] ~= fish then return end
    now = now or self:now()
    if self.ai and not MgrFishCarrier:sync_ai_position(fish.carrier) then
        self:remove(fish)
        return
    end
    local controlled = self:ai_controlled(fish, now)
    local canUpdate = not controlled or (fish.flee_at ~= nil and now >= fish.flee_at)
    if not canUpdate then return end
    if fish.State == Mgr.State.await_lift then
        self:stabilize(fish)
        if fish.lift_at and now - fish.lift_at >= cfg().LiftConfirmSec then
            if not self:request_lift(fish) and fish.LiftAttempts >= cfg().LiftAttempts and not fish.lift_gave_up then
                fish.lift_gave_up = true
                print('[FishTree] 抓举未确认，放弃重试', fish.Owner.UserId, 'fish=' .. tostring(fish.Id))
            end
        end
    elseif fish.State == Mgr.State.wild then
        if fish.wild_until and now >= fish.wild_until then
            print('[FishTree] 爆炸保底鱼到期消失', fish.fish_id, 'fish=' .. tostring(fish.Id))
            self:remove(fish)
        end
    elseif fish.State == Mgr.State.escaping then
        self:update_escaping(fish, now)
    elseif fish.State == Mgr.State.flying then
        self:update_flying(fish, now)
    elseif fish.flee_at then
        self:update_combat(fish, now)
    end
end

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
            ps:effect('HolderAlive', function(es)
                local holder_tree = es:d(fish.holder_tree_state)
                fish.holder_tree = holder_tree
                if not holder_tree then return end
                if fish.State ~= Mgr.State.held and fish.State ~= Mgr.State.await_lift then return end
                local alive = holder_tree.memos and holder_tree.memos.is_alive
                local session = holder_tree.session_alive
                if not alive or not session then return end
                if not es:d(alive) or not es:d(session) then
                    local reason = session:now() == false and 'leave' or 'life'
                    if fish.State == Mgr.State.held then
                        host:release(fish, reason)
                    elseif fish.State == Mgr.State.await_lift then
                        host:release_await_lift(fish, reason)
                    end
                end
            end)
            ps:subscribe(host:frame_clock().on_frame, function(frame)
                host:update_fish(fish, frame and frame.now)
            end)
            ps:on_cleanup(function()
                if fish.mount then pcall(function() fish.mount:Destroy() end) end
                fish.mount = nil
            end)
        end)
        s:phase('CombatPhase', combat, function(ps)
            ps:subscribe(host:frame_clock().on_frame, function(frame)
                host:update_fish(fish, frame and frame.now)
            end)
            ps:on_cleanup(function()
                local gone = host.Fish[fish.Id] ~= fish
                local reason = gone and 'gone' or 'phase'
                host:end_boss_attack(fish, reason)
                host:end_air_attacks(fish, reason)
                host:end_bite(fish, reason)
                host:end_move(fish, reason)
                if fish.Carry then host:release_carried(fish, nil, gone and 'died' or 'phase') end
            end)
        end)
        s:phase('EscapingPhase', escaping, function(ps)
            ps:subscribe(host:frame_clock().on_frame, function(frame)
                host:update_fish(fish, frame and frame.now)
            end)
            ps:on_cleanup(function()
                host:end_move(fish, host.Fish[fish.Id] == fish and 'phase' or 'gone')
            end)
        end)
        s:phase('WildPhase', wild, function(ps)
            ps:subscribe(host:frame_clock().on_frame, function(frame)
                host:update_fish(fish, frame and frame.now)
            end)
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

function Mgr:request_lift(fish)
    local owner = fish.Owner
    if fish.State ~= Mgr.State.await_lift or self.held[owner.UserId]
        or fish.LiftAttempts >= cfg().LiftAttempts then return false end
    local controller = owner.Character and owner.Character.Controller
    if not controller then return false end
    fish.LiftAttempts = fish.LiftAttempts + 1
    fish.lift_at = self:now()
    -- SE 实测 Lift 的指定目标支持 WorldUnit；仍由原生 OnLiftedBegin 确认成功。
    local ok, err = pcall(function() controller:Lift(fish.carrier.body) end)
    if not ok then print('[FishTree] Lift 调用失败', owner.UserId, tostring(err)) end
    return ok
end

function Mgr:resolve_lifter(fish, liftunit)
    if liftunit == nil then return fish.lift_at and fish.Owner or nil end
    if fish.Owner.Character == liftunit then return fish.Owner end
    for _, player in ipairs(self:players()) do
        if player.Character == liftunit then return player end
    end
end

function Mgr:on_lifted(fish, liftunit)
    if self.Fish[fish.Id] ~= fish or fish.State ~= Mgr.State.await_lift then return end
    local holder = self:resolve_lifter(fish, liftunit)
    local character = holder and holder.Character
    if not character or self.held[holder.UserId] then
        print('[FishTree] 抓举回调找不到空手的抓举者', fish.Id)
        return
    end
    local offset = cfg().LiftSocketOffset
    local world = self.World or service('World')
    local ok, mount = pcall(createUnit, self, 'SkeletalSocketMount', {
        Name = 'FishMount_' .. tostring(fish.Id),
        Parent = character,
        SocketName = cfg().LiftSocket,
        SocketOffset = Vector3.New(offset.x, offset.y, offset.z),
    })
    if not ok or not mount then
        print('[FishTree] 顶鱼挂点创建失败', fish.Id, tostring(mount))
        return
    end
    fish.mount = mount
    fish.holder = holder
    self:set_state(fish, Mgr.State.held)
    fish.holder_tree = self.get_player_tree and self:get_player_tree(holder) or nil
    if fish.holder_tree_state then fish.holder_tree_state:set(fish.holder_tree) end
    self.held[holder.UserId] = fish
    pcall(function() fish.carrier.body.Parent = mount end)
    print('[FishTree] 举起', holder.UserId, fish.fish_id, fish.mult, 'fish=' .. tostring(fish.Id))
    if self.cast then self.cast:PushState(holder) end
end

function Mgr:get_held(player)
    return player and self.held[player.UserId] or nil
end

function Mgr:held_info(player)
    local fish = self:get_held(player)
    return fish and { fishId = fish.fish_id, mult = fish.mult } or nil
end

function Mgr:can_cast(player)
    return self:get_held(player) == nil
end

function Mgr:drop(player)
    local fish = self:get_held(player)
    return fish ~= nil and self:release(fish, 'drop')
end

local function flatDirection(x, z)
    local length = math.sqrt(x * x + z * z)
    if length < 0.01 then return nil end
    return x / length, z / length
end

local function towardWater(pos)
    local waters = GameCfg.Water.Zones
    for _, zone in ipairs(GameCfg.Zones) do
        local scene = zone.Scene
        local bounds = scene and scene.Boundary
        if bounds and scene.Waters and #scene.Waters > 0
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

function Mgr:speed(fish)
    local species = GameCfg.Fish[fish.fish_id]
    local speed = species and species.Speed or cfg().EscapeSpeed
    if self.Ability and self.Ability.fish_speed_factor then
        local ok, factor = pcall(self.Ability.fish_speed_factor, self.Ability, fish)
        if ok and type(factor) == 'number' and factor >= 0 and factor <= 1 then speed = speed * factor end
    end
    return speed
end

function Mgr:set_heading(fish, x, z)
    if not x then return end
    local speed = self:speed(fish)
    fish.heading = { x = x, z = z }
    if self.ai then
        local started = self.ai:move_direction(fish, Vector3.New(x, 0, z), speed)
        fish.applied_speed = speed
        return started
    end
    local ok, err = pcall(function() fish.carrier.body.LinearVelocity = Vector3.New(x * speed, 0, z * speed) end)
    if not ok then
        print("[FishTree] 逃跑速度写入失败", fish.Id, tostring(err))
        return false, tostring(err)
    end
    fish.applied_speed = speed
    return true
end

function Mgr:release_await_lift(fish, reason)
    if self.Fish[fish.Id] ~= fish or fish.State ~= Mgr.State.await_lift then return false end
    local owner = fish.Owner
    local body = fish.carrier and fish.carrier.body
    local pos = body and readPosition(body) or fish.Anchor
    local now = self:now()
    local species = GameCfg.Fish[fish.fish_id]
    if body then
        pcall(function()
            body.BodyType = 2
            body.AngularVelocity = Vector3.New(0, 0, 0)
        end)
    end
    self:set_state(fish, Mgr.State.escaping)
    fish.escape_at = now
    fish.escape_by = owner
    fish.turn_at = now + cfg().TurnSec
    fish.ray_at = now
    fish.flee_at = now + (species and species.EscapeSec or 1)
    if reason == 'leave' then
        fish.Owner = nil
        fish.holder = nil
    end
    if pos then
        self:set_heading(fish, towardWater(pos))
    end
    self:enforce_escape_cap(owner, fish)
    if self.cast and owner then self.cast:PushState(owner) end
    return true
end

function Mgr:release(fish, reason)
    if self.Fish[fish.Id] ~= fish or fish.State ~= Mgr.State.held then return false end
    if self.ai then self.ai:custom(fish) end
    local holder = fish.holder
    if holder and self.held[holder.UserId] == fish then self.held[holder.UserId] = nil end
    local body = fish.carrier.body
    local world = self.World or service('World')
    local character = holder and holder.Character
    local origin = character and readPosition(character) or readPosition(body)
    local fx, fz
    pcall(function()
        local forward = character.Rotation:GetForward()
        fx, fz = flatDirection(forward.x, forward.z)
    end)
    fx, fz = fx or 0, fz or 0
    pcall(function() body.Parent = world end)
    if fish.mount then pcall(function() fish.mount:Destroy() end) end
    fish.mount = nil
    if origin then
        local c = cfg()
        pcall(function()
            body.Position = Vector3.New(origin.x + fx * c.DropOffset, origin.y + c.DropHeight, origin.z + fz * c.DropOffset)
        end)
    end
    pcall(function()
        body.BodyType = 2
        body.AngularVelocity = Vector3.New(0, 0, 0)
    end)
    local now = self:now()
    self:set_state(fish, Mgr.State.escaping)
    fish.escape_at = now
    fish.escape_by = holder
    fish.turn_at = now + cfg().TurnSec
    fish.ray_at = now
    local pos = readPosition(body) or origin
    local species = GameCfg.Fish[fish.fish_id]
    if species.Grade ~= 'normal' and species.Grade ~= 'rare' and self:flight_profile(fish.fish_id) then
        fish.flee_at = now + (species.EscapeSec or 180)
        body.LinearVelocity = Vector3.New(0, 0, 0)
        if not self:start_flight(fish, now) then
            print('[FishTree] 飞行档案或边界缺失，回落普通逃脱', fish.fish_id, 'fish=' .. tostring(fish.Id))
            self:set_heading(fish, towardWater(pos))
        end
    elseif self:boss_phase_enabled(fish.fish_id) then
        self:set_state(fish, Mgr.State.Combat)
        fish.flee_at = now + (species.EscapeSec or 300)
        fish.combat_position = pos
        fish.combat_rotation = body.Rotation
        fish.Phase = BossPhase.new(GameCfg.Ability.BossPhase, now, pos)
        fish.phase_at = now
        fish.Yaw = 0
        body.LinearVelocity = Vector3.New(0, 0, 0)
    elseif species.Combat then
        self:set_state(fish, Mgr.State.Combat)
        fish.flee_at = now + species.EscapeSec
        fish.combat_position = pos
        fish.combat_rotation = body.Rotation
        body.LinearVelocity = Vector3.New(0, 0, 0)
        if GameCfg.FishCombat and GameCfg.FishCombat[species.Combat] then
            fish.bite_aim = nil
            if species.Combat == 'shrimp' or species.Combat == 'dragon' then
                local params = GameCfg.FishCombat[species.Combat]
                fish.ActiveUntil = now + (params.ActiveSec or params.SpecialSec)
                fish.SpecialAt = now + (params.SpecialSec or 0)
                fish.combo = 0
            elseif species.Combat == 'kingCrab' or species.Combat == 'crabBoss' then
                resetCrabRhythm(fish, now, GameCfg.FishCombat[species.Combat])
            elseif species.Combat == 'swordfish' or species.Combat == 'shark' then
                local params = GameCfg.FishCombat[species.Combat]
                fish.JumpAt = now + params.JumpIntervalSec
                fish.roll_slot = -1
            elseif species.Combat == 'walrus' then
                fish.ChargeAt = now + GameCfg.FishCombat[species.Combat].ChargeSec
            elseif species.Combat == 'orca' then
                local params = BossMoves.combat_params(GameCfg.FishCombat[species.Combat], BossMoves.key_of(species, fish.fish_id))
                fish.JumpAt = now + params.JumpIntervalSec
                fish.RoarAt = now + params.RoarSec
                fish.TailAt = now + params.TailSec
                fish.ClawAt = -1
            end
        elseif self.Ability then
            self.Ability:equip_fish(fish)
        end
        self:publish_combat(fish)
    elseif pos then
        self:set_heading(fish, towardWater(pos))
    end
    if reason == 'leave' then
        fish.flee_at = now + (species.EscapeSec or 1)
        fish.Owner = nil
        fish.holder = nil
    end
    print('[FishTree] 放下', holder and holder.UserId, reason, fish.fish_id, 'fish=' .. tostring(fish.Id))
    if reason == 'drop' and holder and self.Quest and not (pos and inWater(pos)) then
        self.next_fact_id = (self.next_fact_id or 0) + 1
        self.Quest:notify('DropShore', holder, { itemId = fish.fish_id,
            eventId = 'drop:' .. tostring(fish.Id) .. ':' .. tostring(self.next_fact_id) })
    end
    self:enforce_escape_cap(holder, fish)
    if self.cast and holder then self.cast:PushState(holder) end
    return true
end

function Mgr:escaping()
    local list = {}
    for _, fish in pairs(self.Fish) do
        if fish.State == Mgr.State.escaping then list[#list + 1] = fish end
    end
    table.sort(list, function(a, b)
        if a.escape_at ~= b.escape_at then return a.escape_at < b.escape_at end
        return a.Id < b.Id
    end)
    return list
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

function Mgr:ray_exclusions()
    local list = {}
    for _, player in ipairs(self:players()) do
        if player.Character then list[#list + 1] = player.Character end
    end
    for _, fish in pairs(self.Fish) do
        if fish.carrier then
            list[#list + 1] = fish.carrier.body
            if fish.carrier.receiver then list[#list + 1] = fish.carrier.receiver end
        end
    end
    return list
end

-- 射线会命中 TGUnitShop 这类 TriggerUnit（V4 实测），它们和不碰撞的物体都不算墙
local function passThrough(unit)
    if not unit then return true end
    local ok, trigger = pcall(function() return unit.IsA ~= nil and unit:IsA('TriggerUnit') end)
    if ok and trigger then return true end
    local okCollide, collide = pcall(function() return unit.CanCollide end)
    return okCollide and collide == false
end

function Mgr:wall_ahead(fish, pos)
    local heading = fish.heading
    if not heading or not RaycastParams then return false end
    local physics = service('PhysicsService')
    if not physics then return false end
    local distance = cfg().RayDistance
    local params = RaycastParams.New()
    local excluded = self:ray_exclusions()
    for _ = 1, cfg().RayRetries do
        params.FilterDescendantsInstances = excluded
        local ok, hit = pcall(physics.Raycast, physics, Vector3.New(pos.x, pos.y, pos.z),
            Vector3.New(heading.x * distance, 0, heading.z * distance), params)
        if not ok or not hit then return false end
        if not passThrough(hit.Instance) then
            return hit.Distance == nil or hit.Distance <= distance
        end
        excluded[#excluded + 1] = hit.Instance
    end
    return false
end

function Mgr:update_escaping(fish, now)
    if fish.flee_at and now >= fish.flee_at and not fish.straight_escape then
        self:remove(fish)
        return
    end
    local pos = readPosition(fish.carrier.body)
    if not pos then
        print('[FishTree] 在逃的鱼坐标异常，移除', 'fish=' .. tostring(fish.Id))
        self:remove(fish)
        return
    end
    local zone = inWater(pos)
    if zone then
        print('[FishTree] 逃回水里', zone.Id, fish.fish_id, 'fish=' .. tostring(fish.Id))
        self:remove(fish)
        return
    end
    if fish.heading and fish.applied_speed ~= self:speed(fish) then
        self:set_heading(fish, fish.heading.x, fish.heading.z)
    end
    if fish.straight_escape then return end
    if now >= fish.turn_at then
        fish.turn_at = now + cfg().TurnSec
        self:set_heading(fish, towardWater(pos))
    end
    if now >= fish.ray_at then
        fish.ray_at = now + 1 / cfg().RayHz
        if self:wall_ahead(fish, pos) then
            local h = fish.heading
            self:set_heading(fish, -h.z, h.x)
        end
    end
end

function Mgr:is_target_valid(player, pos, params)
    if not player or not self.Vitals or not self.Vitals:can_take_damage(player) then return false end
    local character = player.Character
    local controller = character and character.Controller
    local cp = controller and controller.Health and controller.Health > 0 and readPosition(character)
    if not cp then return false end
    if params and type(params.AggroRange) == 'number' and pos then
        local dx, dz = cp.x - pos.x, cp.z - pos.z
        if dx * dx + dz * dz > params.AggroRange * params.AggroRange then return false end
    end
    return true, cp
end

function Mgr:note_damage(fish, player, amount)
    if not fish or self.Fish[fish.Id] ~= fish or not player
        or type(amount) ~= 'number' or amount <= 0 or amount ~= amount then return false end
    fish.threat = fish.threat or {}
    fish.threat[player] = (fish.threat[player] or 0) + amount
    return true
end

function Mgr:set_target_override(fish, player)
    if not fish or self.Fish[fish.Id] ~= fish then return false end
    fish.target_override = player
    return true
end

function Mgr:choose_target(fish, pos, params)
    local adapter = self.AiTarget
    local override = fish.target_override
    if override then
        local valid, cp = self:is_target_valid(override, pos, params)
        if valid then
            adapter:set_focus(fish, override)
            return override, cp
        end
        fish.target_override = nil
    end
    local candidates, present = {}, {}
    for _, player in ipairs(self:players()) do
        present[player] = true
        local valid, cp = self:is_target_valid(player, pos, params)
        if valid then
            candidates[#candidates + 1] = { player = player, pos = cp,
                damage = fish.threat and fish.threat[player] or 0, distance = distanceSq(pos, cp) }
        end
    end
    if fish.threat then
        for player in pairs(fish.threat) do
            if not present[player] or not self:is_target_valid(player, pos, params) then
                fish.threat[player] = nil
            end
        end
    end
    local ranked = adapter:select(fish, candidates)
    local top = ranked[1]
    return top and top.player or nil, top and top.pos or nil
end

function Mgr.in_head_zone(pos, facing, tpos, params)
    local dx, dz = tpos.x - pos.x, tpos.z - pos.z
    local d2 = dx * dx + dz * dz
    if d2 > params.BiteRange * params.BiteRange then return false end
    if d2 < 1e-4 or not facing then return true end
    local limit = math.cos(math.rad(params.HeadHalfAngleDeg or 180))
    return (dx * facing.x + dz * facing.z) / math.sqrt(d2) > limit + 1e-9
end

local function withinBite(pos, tpos, params)
    local dx, dz = tpos.x - pos.x, tpos.z - pos.z
    return dx * dx + dz * dz <= params.BiteRange * params.BiteRange
end

local function segmentDistanceSq(px, pz, ax, az, bx, bz)
    local dx, dz = bx - ax, bz - az
    local lenSq = dx * dx + dz * dz
    if lenSq <= 1e-12 then
        local ex, ez = px - ax, pz - az
        return ex * ex + ez * ez
    end
    local t = ((px - ax) * dx + (pz - az) * dz) / lenSq
    if t < 0 then t = 0 elseif t > 1 then t = 1 end
    local ex, ez = px - (ax + t * dx), pz - (az + t * dz)
    return ex * ex + ez * ez
end

function Mgr:publish_bite(payload)
    GarBiteNotice.publish(payload)
end

local function publishBite(self, payload)
    local ok, err = pcall(self.publish_bite, self, payload)
    if not ok then print('[FishTree] 首领咬预警推送失败', payload.kind, 'fish=' .. tostring(payload.fishId), tostring(err)) end
end

function Mgr:face(fish, fx, fz, params)
    if not fx then return end
    fish.facing = { x = fx, z = fz }
    if not Quaternion then return end
    local yaw = math.atan(fx, fz) + ((params and params.ModelYawOffset) or 0)
    local ok, err = pcall(function() fish.carrier.body.Rotation = Quaternion.FromEulerAngles(0, yaw, 0) end)
    if not ok then print('[FishTree] 首领转向失败', 'fish=' .. tostring(fish.Id), tostring(err)) end
end

function Mgr:end_bite(fish, reason)
    if not fish.bite_aim then return end
    fish.bite_aim = nil
    publishBite(self, GarBiteNotice.clear(fish.Id, reason))
end

function Mgr:lock_bite(fish, target, pos, tpos, now, params)
    if self.ai then self.ai:custom(fish) end
    local fx, fz = flatDirection(tpos.x - pos.x, tpos.z - pos.z)
    if fx then self:face(fish, fx, fz, params) end
    fish.bite_aim = { Target = target, strike_at = now + params.BiteCooldownSec }
    local facing = fish.facing or { x = 0, z = 1 }
    local species = GameCfg.Fish[fish.fish_id]
    local warning = species and BossMoves.warning_of(BossMoves.key_of(species, fish.fish_id), 'bite') or nil
    local notice = GarBiteNotice.lock(fish.Id, pos, facing.x, facing.z, params.BiteRange,
        params.HeadHalfAngleDeg, params.BiteCooldownSec)
    notice.move = 'bite'
    if warning then
        notice.shape, notice.duration = warning.Shape, warning.WindupSec
        if warning.Notice then notice.notice = warning.Notice end
    end
    publishBite(self, notice)
    print('[FishTree] 首领起咬', fish.fish_id, 'target=' .. tostring(target.UserId),
        string.format('facing=%.2f,%.2f', facing.x, facing.z), 'fish=' .. tostring(fish.Id))
end

function Mgr:update_chase(fish, now, pos, params)
    local species = GameCfg.Fish[fish.fish_id]
    local body = fish.carrier.body
    local aim = fish.bite_aim
    if aim then
        local valid, apos = self:is_target_valid(aim.Target, pos, params)
        if not valid or not withinBite(pos, apos, params) then
            self:end_bite(fish, 'cancel')
        else
            pcall(function() body.LinearVelocity = Vector3.New(0, 0, 0) end)
            if now < aim.strike_at then return end
            if Mgr.in_head_zone(pos, fish.facing, apos, params) then
                self:end_bite(fish, 'bite')
                local hit = self.Vitals:new_hit(fish, 'fishAttack')
                self.Vitals:apply_hit(hit, aim.Target, species.Attack)
                print('[FishTree] 首领追咬', fish.fish_id, species.Attack, 'fish=' .. tostring(fish.Id))
            else
                self:end_bite(fish, 'miss')
                print('[FishTree] 首领咬空（绕后）', fish.fish_id, 'target=' .. tostring(aim.Target.UserId),
                    'fish=' .. tostring(fish.Id))
            end
        end
    end
    local target, tpos = self:choose_target(fish, pos, params)
    if not target then
        if self.ai then self.ai:custom(fish) end
        pcall(function() body.LinearVelocity = Vector3.New(0, 0, 0) end)
        return
    end
    if not withinBite(pos, tpos, params) then
        local ux, uz = flatDirection(tpos.x - pos.x, tpos.z - pos.z)
        local speed = self:speed(fish)
        self:face(fish, ux, uz, params)
        if self.ai then
            self.ai:Chase(fish, target.Character, speed, params.BiteRange, params.AggroRange)
            return
        end
        pcall(function() body.LinearVelocity = Vector3.New((ux or 0) * speed, 0, (uz or 0) * speed) end)
        return
    end
    pcall(function() body.LinearVelocity = Vector3.New(0, 0, 0) end)
    self:lock_bite(fish, target, pos, tpos, now, params)
end

function Mgr:end_move(fish, reason)
    if not fish.Move then return end
    fish.Move, fish.MoveName = nil, nil
    publishBite(self, GarBiteNotice.clear(fish.Id, reason))
    self:publish_combat(fish)
end

function Mgr:start_move(fish, name, pos, target, tpos, now, duration, range, shape)
    if self.ai and not self.ai:custom(fish) then return false end
    fish.official_roll_from, fish.roll_from = nil, nil
    self:end_move(fish, 'replace')
    local fx, fz
    if tpos then fx, fz = flatDirection(tpos.x - pos.x, tpos.z - pos.z) end
    self:face(fish, fx, fz)
    fish.Move = { Name = name, Target = target, at = now, strike_at = now + duration,
        Center = { x = pos.x, y = pos.y, z = pos.z },
        destination = tpos and { x = tpos.x, y = pos.y, z = tpos.z } }
    local facing = fish.facing or { x = 0, z = 1 }
    local warningPos = (name == 'dive' or name == 'jump') and fish.Move.destination or pos
    warningPos = warningPos or pos
    local species = GameCfg.Fish[fish.fish_id]
    local warning = species and BossMoves.warning_of(BossMoves.key_of(species, fish.fish_id), name) or nil
    local warningRange = warning and math.max(range or 0, warning.Range or 0) or range
    local warningSec = warning and warning.WindupSec and warning.WindupSec > 0 and warning.WindupSec or duration
    local payload = GarBiteNotice.lock(fish.Id, warningPos, facing.x, facing.z, warningRange, 90, warningSec)
    payload.move = name
    local shapeName = (warning and warning.Kind ~= 'none' and warning.Shape) or shape
    if shapeName == 'circle' or name == 'jump' then
        payload.shape, payload.halfAngleDeg = 'circle', 180
    elseif shapeName == 'line' then
        payload.shape = 'line'
        if warning and warning.Width then payload.width = warning.Width end
    elseif shapeName == 'cone' then
        payload.shape = 'cone'
    end
    if warning and warning.Notice then payload.notice = warning.Notice end
    local row = BossMoves.get(BossMoves.key_of(GameCfg.Fish[fish.fish_id], fish.fish_id), name)
    if row and row.Delivery and row.Warning.Kind ~= 'none' then
        payload.shape = row.Warning.Kind or payload.shape
        payload.notice, payload.delivery, payload.landing = row.Warning.Notice, row.Delivery, row.Landing
        payload.width = row.Warning.Width
        payload.landingPoint = fish.Move.destination or fish.Move.Center
    end
    publishBite(self, payload)
    fish.MoveName = name
    self:publish_combat(fish)
    print('[FishTree] 招式预警', fish.fish_id, name, 'fish=' .. tostring(fish.Id))
    return true
end

function Mgr:stun_fish(fish, now, params)
    if self.ai then self.ai:custom(fish) end
    self:end_move(fish, 'stun')
    fish.State, fish.wake_at, fish.MoveName = 'stunned', now + params.StunSec, nil
    fish.carrier.body.LinearVelocity = Vector3.New(0, 0, 0)
    self:publish_combat(fish)
    print('[FishTree] 眩晕', fish.fish_id, 'wakeAt=' .. tostring(fish.wake_at))
end

function Mgr:update_shrimp_combat(fish, now, pos, params, combat)
    local body = fish.carrier.body
    local dt = math.max(0, now - (fish.combat_step_at or now))
    fish.combat_step_at = now
    if fish.State == 'stunned' or fish.State == Mgr.State.sleeping then
        body.LinearVelocity = Vector3.New(0, 0, 0)
        if now < (fish.wake_at or math.huge) then return end
        fish.State, fish.wake_at = Mgr.State.Combat, nil
        fish.ActiveUntil, fish.combo = now + (params.ActiveSec or params.SpecialSec), 0
        dt = 0
        self:publish_combat(fish)
    end
    if combat == 'shrimp' and now >= fish.ActiveUntil then
        self:stun_fish(fish, now, params)
        return
    end
    local move = fish.Move
    if combat == 'dragon' and now >= fish.SpecialAt and (not move or move.Name == 'peck') then
        fish.SpecialAt = now + params.SpecialSec
        if not self:start_move(fish, 'rain', pos, nil, nil, now, params.RainSec, params.RainRadius) then return end
        fish.Move.last_tick = 0
        move = fish.Move
    end
    if move then
        dt = 0
        body.LinearVelocity = Vector3.New(0, 0, 0)
        if move.Name == 'rain' then
            local tick = math.min(params.RainSec, math.floor(now - move.at))
            if tick > move.last_tick then
                move.last_tick = tick
                for _, player in ipairs(self:players()) do
                    local valid, cp = self:is_target_valid(player, move.Center)
                    if valid and (cp.x - move.Center.x)^2 + (cp.z - move.Center.z)^2 <= params.RainRadius^2 then
                        self:hit(fish, player, params.RainDamage, 'rain')
                    end
                end
            end
            if now < move.strike_at then return end
            self:end_move(fish, 'rain-end')
            local target, tp = self:choose_target(fish, pos, params)
            self:start_move(fish, 'dive', pos, target, tp, now, params.DiveSec, params.DiveRadius)
            return
        elseif move.Name == 'dive' then
            local progress = math.min(1, math.max(0, (now - move.at) / params.DiveSec))
            local dest = move.destination or move.Center
            body.Position = Vector3.New(move.Center.x + (dest.x - move.Center.x) * progress,
                move.Center.y + math.sin(progress * math.pi) * params.DiveHeight,
                move.Center.z + (dest.z - move.Center.z) * progress)
            if now < move.strike_at then return end
            self:end_move(fish, 'dive-end')
            for _, player in ipairs(self:players()) do
                local valid, cp = self:is_target_valid(player, dest)
                if valid and (cp.x - dest.x)^2 + (cp.z - dest.z)^2 <= params.DiveRadius^2 then
                    self:hit(fish, player, params.DiveDamage, 'dive')
                end
            end
            self:stun_fish(fish, now, params)
            return
        end
        local valid, cp = self:is_target_valid(move.Target, pos, params)
        if not valid or not withinBite(pos, cp, params) then
            self:end_move(fish, 'cancel')
        elseif now < move.strike_at then return
        else
            self:end_move(fish, 'strike')
            if Mgr.in_head_zone(pos, fish.facing, cp, params) then
                local damage = move.Name == 'tail' and params.TailDamage
                    or (move.Name == 'peck' and params.PeckDamage or params.ClawDamage)
                local applied = self:hit(fish, move.Target, damage, move.Name)
                if applied and move.Name == 'tail' then
                    local f = fish.facing or { x = 0, z = 1 }
                    local ok, err = pcall(function()
                        move.Target.Character.Position = Vector3.New(cp.x + f.x * params.KnockHorizontal,
                            cp.y + params.KnockUp, cp.z + f.z * params.KnockHorizontal)
                    end)
                    if not ok then print('[FishTree] 尾刺击飞失败', fish.Id, tostring(err)) end
                end
            end
            fish.combo = ((fish.combo or 0) + 1) % 3
        end
    end
    local target, tp = self:choose_target(fish, pos, params)
    if not target then
        if self.ai then self.ai:custom(fish) end
        body.LinearVelocity = Vector3.New(0, 0, 0)
        return
    end
    if not withinBite(pos, tp, params) then
        local fx, fz = flatDirection(tp.x - pos.x, tp.z - pos.z)
        self:face(fish, fx, fz, params)
        if self.ai then
            self.ai:Chase(fish, target.Character, self:speed(fish), params.BiteRange, params.AggroRange)
            return
        end
        local distance = math.sqrt((tp.x - pos.x)^2 + (tp.z - pos.z)^2)
        local step = math.min(self:speed(fish) * dt, math.max(0, distance - params.BiteRange))
        body.LinearVelocity = Vector3.New(0, 0, 0)
        local moved, err = pcall(function()
            body.Position = Vector3.New(pos.x + (fx or 0) * step, pos.y, pos.z + (fz or 0) * step)
        end)
        if not moved then print('[FishTree] 虾池追击位移失败', fish.Id, tostring(err)) end
        return
    end
    body.LinearVelocity = Vector3.New(0, 0, 0)
    local name = combat == 'dragon' and 'peck' or ((fish.combo or 0) == 2 and 'tail' or 'claw')
    self:start_move(fish, name, pos, target, tp, now, params.BiteCooldownSec, params.BiteRange)
end

local function beginCombatFrame(fish, now)
    fish.carrier.body.LinearVelocity = Vector3.New(0, 0, 0)
    local dt = math.max(0, now - (fish.combat_step_at or now))
    fish.combat_step_at = now
    return dt
end

local function chaseStep(self, fish, pos, tpos, dt, params, label, skipIdle, plainId)
    if self.ai then
        local target = self:choose_target(fish, pos, params)
        if not target then self.ai:custom(fish); return false end
        self:face(fish, flatDirection(tpos.x - pos.x, tpos.z - pos.z))
        local previous = fish.official_roll_from
        fish.official_roll_from = { x = pos.x, y = pos.y, z = pos.z }
        fish.roll_from = previous
        self.ai:Chase(fish, target.Character, self:speed(fish), params.BiteRange, params.AggroRange)
        return previous ~= nil and (previous.x ~= pos.x or previous.z ~= pos.z)
    end
    local body = fish.carrier.body
    local fx, fz = flatDirection(tpos.x - pos.x, tpos.z - pos.z)
    self:face(fish, fx, fz, params)
    local distance = math.sqrt((tpos.x - pos.x)^2 + (tpos.z - pos.z)^2)
    local step = math.min(self:speed(fish) * dt, math.max(0, distance - params.BiteRange))
    if skipIdle and step <= 0 then return false end
    local moved, err = pcall(function()
        body.Position = Vector3.New(pos.x + (fx or 0) * step, pos.y, pos.z + (fz or 0) * step)
    end)
    if not moved then
        print('[FishTree] ' .. label .. '追击位移失败',
            plainId and fish.Id or ('fish=' .. tostring(fish.Id)), tostring(err))
    end
    return moved
end

local function advanceHeadMove(self, fish, move, now, pos, params, damage)
    local valid, tp = self:is_target_valid(move.Target, pos, params)
    if not valid or not withinBite(pos, tp, params) then
        self:end_move(fish, 'cancel')
        return false
    end
    if now < move.strike_at - 1e-9 then return true end
    self:end_move(fish, move.Name)
    if Mgr.in_head_zone(pos, fish.facing, tp, params) then
        self:hit(fish, move.Target, damage, move.Name)
    end
    return true
end

local function engageOrChase(self, fish, now, pos, params, dt, name, windup, label, skipIdle)
    local target, tpos = self:choose_target(fish, pos, params)
    if not target then
        if self.ai then self.ai:custom(fish) end
        return false
    end
    if withinBite(pos, tpos, params) then
        self:start_move(fish, name, pos, target, tpos, now, windup, params.BiteRange)
        return false
    end
    return chaseStep(self, fish, pos, tpos, dt, params, label, skipIdle)
end

local function bossWindup(fish, move)
    local row = BossMoves.get(BossMoves.key_of(GameCfg.Fish[fish.fish_id], fish.fish_id), move) or {}
    local warning = row.Warning
    local windup = type(warning) == 'table' and warning.WindupSec or nil
    return type(windup) == 'number' and windup or 0
end

function Mgr:update_king_crab_combat(fish, now, pos, params)
    local dt = beginCombatFrame(fish, now)
    local move = fish.Move
    if move then
        if move.Name ~= 'jab' then return end
        local elapsed = now - move.at
        local windup = bossWindup(fish, 'jab')
        local slot = elapsed <= windup and -1 or math.min(params.JabsPerSide * 2 - 1,
            math.floor((elapsed - windup) / params.JabStepSec + 1e-9) - 1)
        if slot > (move.last_slot or -1) then
            move.last_slot = slot
            local target, tp = self:is_target_valid(move.Target, pos, params)
            if target and withinBite(pos, tp, params)
                and Mgr.in_head_zone(pos, fish.facing, tp, params) then
                self:hit(fish, move.Target, params.JabDamage, 'jab')
            end
        end
        if now < move.strike_at - 1e-9 then return end
        self:end_move(fish, 'jab-end')
        return
    end
    local target, tp = self:choose_target(fish, pos, params)
    if not target then
        if self.ai then self.ai:custom(fish) end
        return
    end
    if now < (fish.JabAt or 0) then return end
    if not withinBite(pos, tp, params) then
        chaseStep(self, fish, pos, tp, dt, params, '帝王蟹', nil, true)
        return
    end
    fish.JabAt = now + params.JabIntervalSec
    self:start_move(fish, 'jab', pos, target, tp, now,
        bossWindup(fish, 'jab') + params.JabStepSec * params.JabsPerSide * 2, params.BiteRange)
end

function Mgr:update_crab_boss_combat(fish, now, pos, params)
    local dt = beginCombatFrame(fish, now)
    local move = fish.Move
    if move then
        if move.Name == 'pinch' then
            local elapsed = now - move.at
            local windup = bossWindup(fish, 'pinch')
            local strike = elapsed <= windup and 0 or math.min(params.PinchStrikes,
                math.floor((elapsed - windup) / params.PinchStepSec + 1e-9))
            if strike > (move.last_strike or 0) and strike >= 1 then
                move.last_strike = strike
                local target, tp = self:is_target_valid(move.Target, pos, params)
                if target and withinBite(pos, tp, params)
                    and Mgr.in_head_zone(pos, fish.facing, tp, params) then
                    self:hit(fish, move.Target, params.PinchDamage, 'pinch')
                end
            end
            if now < move.strike_at - 1e-9 then return end
            self:end_move(fish, 'pinch-end')
            return
        elseif move.Name == 'charge' then
            if not move.hit_done and now >= move.at + bossWindup(fish, 'charge') then
                local target, tp = self:choose_target(fish, pos, params)
                if target and tp and (tp.x - pos.x)^2 + (tp.z - pos.z)^2 <= params.ChargeRange^2 then
                    move.hit_done = true
                    self:hit(fish, target, params.ChargeDamage, 'charge')
                end
            end
            if now < move.strike_at - 1e-9 then return end
            self:end_move(fish, 'charge-end')
            return
        elseif move.Name == 'spin' then
            local tick = math.min(params.SpinDurationSec,
                math.max(0, math.floor(now - move.at)))
            if tick > (move.last_tick or 0) then
                move.last_tick = tick
                for _, player in ipairs(self:players()) do
                    local valid, cp = self:is_target_valid(player, move.Center)
                    if valid and (cp.x - pos.x)^2 + (cp.z - pos.z)^2 <= params.SpinRadius^2 then
                        self:hit(fish, player, params.SpinDamage, 'spin')
                    end
                end
            end
            if now < move.strike_at - 1e-9 then return end
            self:end_move(fish, 'spin-end')
            return
        end
        return
    end
    local target, tp = self:choose_target(fish, pos, params)
    if not target then
        if self.ai then self.ai:custom(fish) end
        return
    end
    if now >= (fish.SpecialAt or math.huge) then
        fish.SpecialAt = now + params.SpinSec
        self:start_move(fish, 'spin', pos, target, tp, now, params.SpinDurationSec, params.SpinRadius)
        return
    end
    if now >= (fish.ChargeAt or math.huge) then
        fish.ChargeAt = now + params.ChargeSec
        self:start_move(fish, 'charge', pos, target, tp, now, params.ChargeWindowSec, params.ChargeRange)
        return
    end
    if now >= (fish.PinchAt or 0) and withinBite(pos, tp, params) then
        fish.PinchAt = now + params.PinchCooldownSec
        self:start_move(fish, 'pinch', pos, target, tp, now,
            bossWindup(fish, 'pinch') + params.PinchStepSec * params.PinchStrikes, params.BiteRange)
        return
    end
    if not withinBite(pos, tp, params) then
        chaseStep(self, fish, pos, tp, dt, params, '蟹老板', nil, true)
    end
end
function Mgr:start_jump(fish, now, pos, params)
    fish.JumpAt = now + params.JumpIntervalSec
    local rng = math.random
    local angle = (rng and rng() or 0.5) * math.pi * 2
    local dest = { x = pos.x + math.cos(angle) * params.JumpDistance, y = pos.y,
        z = pos.z + math.sin(angle) * params.JumpDistance }
    self:start_move(fish, 'jump', pos, nil, dest, now, params.JumpSec, params.JumpRadius)
end

function Mgr:advance_jump(fish, now, pos, params)
    local body = fish.carrier.body
    local move = fish.Move
    local dest = move.destination or move.Center
    local progress = math.min(1, math.max(0, (now - move.at) / params.JumpSec))
    local ok, err = pcall(function()
        body.Position = Vector3.New(
            move.Center.x + (dest.x - move.Center.x) * progress,
            move.Center.y + math.sin(progress * math.pi) * params.JumpHeight,
            move.Center.z + (dest.z - move.Center.z) * progress)
    end)
    if not ok then
        print('[FishTree] 高跃位移失败', 'fish=' .. tostring(fish.Id), tostring(err))
        self:end_move(fish, 'cancel')
        return
    end
    if now < move.strike_at - 1e-9 then return end
    self:end_move(fish, 'jump-end')
    for _, player in ipairs(self:players()) do
        local valid, cp = self:is_target_valid(player, dest, params)
        if valid and (cp.x - dest.x)^2 + (cp.z - dest.z)^2 <= params.JumpRadius * params.JumpRadius then
            self:hit(fish, player, params.JumpDamage, 'jump')
        end
    end
end

function Mgr:update_swordfish_combat(fish, now, pos, params)
    local dt = beginCombatFrame(fish, now)
    local move = fish.Move
    if move then
        if move.Name == 'jump' then
            self:advance_jump(fish, now, pos, params)
            return
        end
        if advanceHeadMove(self, fish, move, now, pos, params, params.SwingDamage) then return end
    end
    if now >= (fish.JumpAt or math.huge) then
        self:start_jump(fish, now, pos, params)
        return
    end
    engageOrChase(self, fish, now, pos, params, dt, 'swing', params.SwingCooldownSec, '剑鱼')
end

function Mgr:update_shark_combat(fish, now, pos, params)
    local dt = beginCombatFrame(fish, now)
    local move = fish.Move
    if move then
        if move.Name == 'jump' then
            self:advance_jump(fish, now, pos, params)
            return
        end
        if advanceHeadMove(self, fish, move, now, pos, params, params.SweepDamage) then return end
    end
    if now >= (fish.JumpAt or math.huge) then
        self:start_jump(fish, now, pos, params)
        return
    end
    if not engageOrChase(self, fish, now, pos, params, dt, 'sweep', params.SweepCooldownSec, '三头鲨', true) then
        return
    end
    local actual = readPosition(fish.carrier.body)
    pos = (self.ai and fish.roll_from) or pos
    if not actual or not pos or (actual.x == pos.x and actual.z == pos.z) then return end
    local slot = math.floor(now)
    if fish.roll_slot ~= slot then fish.roll_slot, fish.roll_hits = slot, {} end
    for _, player in ipairs(self:players()) do
        local valid, cp = self:is_target_valid(player, actual, params)
        if valid and not fish.roll_hits[player]
            and segmentDistanceSq(cp.x, cp.z, pos.x, pos.z, actual.x, actual.z) <= params.BiteRange^2 then
            fish.roll_hits[player] = true
            self:hit(fish, player, params.RollDamage, 'roll')
        end
    end
end

function Mgr:advance_walrus_charge(fish, now, pos, params)
    local body = fish.carrier.body
    local move = fish.Move
    if now < move.windup_at - 1e-9 then
        local valid = self:is_target_valid(move.Target, pos, params)
        if not valid then self:end_move(fish, 'cancel') end
        return
    end
    if not move.dash_from then
        move.dash_from = { x = pos.x, y = pos.y, z = pos.z }
    end
    local facing = fish.facing or { x = 0, z = 1 }
    local progress = math.min(params.ChargeDistance, (now - move.windup_at) * params.ChargeSpeed)
    local moved, err = pcall(function()
        body.Position = Vector3.New(
            move.dash_from.x + facing.x * progress, pos.y,
            move.dash_from.z + facing.z * progress)
    end)
    if not moved then
        print('[FishTree] 海象突击位移失败', 'fish=' .. tostring(fish.Id), tostring(err))
        self:end_move(fish, 'cancel')
        return
    end
    local actual = readPosition(body)
    if actual then
        for _, player in ipairs(self:players()) do
            if not move.hits[player] then
                local valid, cp = self:is_target_valid(player, actual, params)
                if valid and segmentDistanceSq(cp.x, cp.z,
                        move.dash_from.x, move.dash_from.z, actual.x, actual.z)
                    <= params.ChargeContactRange * params.ChargeContactRange then
                    move.hits[player] = true
                    self:hit(fish, player, params.ChargeDamage, 'charge')
                end
            end
        end
    end
    if now >= move.strike_at - 1e-9 then
        self:end_move(fish, 'charge-end')
    end
end

function Mgr:update_walrus_combat(fish, now, pos, params)
    local dt = beginCombatFrame(fish, now)
    local move = fish.Move
    if move then
        if move.Name == 'swing' then
            if advanceHeadMove(self, fish, move, now, pos, params, params.SwingDamage) then return end
        elseif move.Name == 'charge' then
            self:advance_walrus_charge(fish, now, pos, params)
            return
        else
            return
        end
    end
    if now >= (fish.ChargeAt or math.huge) then
        local target, tp = self:choose_target(fish, pos, params)
        if not target then
        if self.ai then self.ai:custom(fish) end
        return
    end
        fish.ChargeAt = now + params.ChargeSec
        if not self:start_move(fish, 'charge', pos, target, tp, now,
            params.ChargeWindupSec + params.ChargeDistance / params.ChargeSpeed,
            params.ChargeDistance) then return end
        fish.Move.windup_at = now + params.ChargeWindupSec
        fish.Move.hits = {}
        return
    end
    engageOrChase(self, fish, now, pos, params, dt, 'swing', params.SwingCooldownSec, '海象')
end

function Mgr:update_orca_combat(fish, now, pos, params)
    local dt = beginCombatFrame(fish, now)
    local move = fish.Move
    if move then
        if move.Name == 'jump' then
            self:advance_jump(fish, now, pos, params)
            return
        end
        if now < move.strike_at - 1e-9 then
            local valid = self:is_target_valid(move.Target, pos, params)
            if not valid then self:end_move(fish, 'cancel') end
            return
        end
        if move.Name == 'claw' then
            self:end_move(fish, 'claw')
            local valid, tp = self:is_target_valid(move.Target, pos, params)
            if valid and withinBite(pos, tp, params)
                and Mgr.in_head_zone(pos, fish.facing, tp, params) then
                self:hit(fish, move.Target, params.ClawDamage, 'claw')
            end
            return
        end
        if move.Name == 'roar' then
            self:end_move(fish, 'roar')
            local valid, tp = self:is_target_valid(move.Target, pos, params)
            if valid and (tp.x - pos.x)^2 + (tp.z - pos.z)^2 <= params.RoarRange * params.RoarRange then
                self:hit(fish, move.Target, params.RoarDamage, 'roar')
            end
            return
        end
        if move.Name == 'tail' then
            self:end_move(fish, 'tail')
            local facing = fish.facing or { x = 0, z = 1 }
            for _, player in ipairs(self:players()) do
                local valid, cp = self:is_target_valid(player, pos, params)
                if valid and (cp.x - pos.x)^2 + (cp.z - pos.z)^2 <= params.TailRadius * params.TailRadius then
                    local dx, dz = cp.x - pos.x, cp.z - pos.z
                    if dx * facing.x + dz * facing.z < 0 then
                        self:hit(fish, player, params.TailDamage, 'tail')
                    end
                end
            end
            return
        end
        return
    end
    if now >= (fish.JumpAt or math.huge) then
        self:start_jump(fish, now, pos, params)
        return
    end
    local target, tp = self:choose_target(fish, pos, params)
    if not target then
        if self.ai then self.ai:custom(fish) end
        return
    end
    if now >= (fish.RoarAt or math.huge) then
        fish.RoarAt = now + params.RoarSec
        self:start_move(fish, 'roar', pos, target, tp, now, params.RoarWindupSec, params.RoarRange, 'circle')
        return
    end
    if now >= (fish.TailAt or math.huge) then
        fish.TailAt = now + params.TailSec
        self:start_move(fish, 'tail', pos, target, tp, now, params.TailWindupSec, params.TailRadius, 'circle')
        return
    end
    if now >= (fish.ClawAt or 0) and withinBite(pos, tp, params) then
        fish.ClawAt = now + params.ClawCooldownSec
        self:start_move(fish, 'claw', pos, target, tp, now, params.ClawWindupSec, params.BiteRange)
        return
    end
    if not withinBite(pos, tp, params) then
        chaseStep(self, fish, pos, tp, dt, params, '虎鲸')
    end
end

function Mgr:update_combat(fish, now)
    local body = fish.carrier.body
    local pos = readPosition(body)
    if not pos then
        print('[FishTree] 战斗鱼坐标异常，移除', fish.Id)
        self:remove(fish)
        return
    end
    local moveName = fish.Move and fish.Move.Name
    local diving = moveName == 'dive'
    local jumping = moveName == 'jump'
    local airborne = (diving or jumping) and pos.y > fish.Move.Center.y + 0.1
    if now >= fish.flee_at or (not airborne and inWater(pos) and not (fish.Phase and fish.Phase.Phase == 'water')) then
        if diving or jumping then
            local ground = fish.Move.Center.y
            local ok, err = pcall(function() body.Position = Vector3.New(pos.x, ground, pos.z) end)
            if not ok then print('[FishTree] 腾空逃脱落地失败', fish.Id, tostring(err)) end
            pos = readPosition(body) or pos
        end
        if self.Ability then self.Ability:remove_fish(fish) end
        self:end_bite(fish, 'gone')
        self:end_move(fish, 'gone')
        self:end_boss_attack(fish, 'timeout')
        self:release_carried(fish, nil, 'timeout')
        fish.Aquatic = nil
        fish.wake_at, fish.MoveName = nil, nil
        self:set_state(fish, Mgr.State.escaping)
        fish.straight_escape = true
        if fish.combat_rotation then body.Rotation = fish.combat_rotation end
        self:set_heading(fish, towardWater(pos))
        print('[FishTree] 精英开始逃脱', fish.fish_id, 'fish=' .. tostring(fish.Id))
        self:publish_combat(fish)
        self:update_escaping(fish, now)
        return
    end
    self:refresh_moving_combat(fish, now)
    if self.Ability and self.Ability.fish_paralyzed then
        local ok, paralyzed = pcall(self.Ability.fish_paralyzed, self.Ability, fish)
        if ok and paralyzed then
            pcall(function() body.LinearVelocity = Vector3.New(0, 0, 0) end)
            return
        end
    end
    local combat = GameCfg.Fish[fish.fish_id].Combat
    if fish.State == 'stunned' and combat == 'kingCrab' then
        body.LinearVelocity = Vector3.New(0, 0, 0)
        if now < (fish.wake_at or math.huge) then return end
        fish.State, fish.wake_at = Mgr.State.Combat, nil
        local params = GameCfg.FishCombat and GameCfg.FishCombat[combat]
        if params then resetCrabRhythm(fish, now, params) end
        self:publish_combat(fish)
    end
    if self:boss_phase_enabled(fish.fish_id) then
        self:update_boss_phase(fish, now, pos)
        return
    end
    local chase = GameCfg.FishCombat and GameCfg.FishCombat[combat]
    if chase then
        local key = BossMoves.key_of(GameCfg.Fish[fish.fish_id], fish.fish_id)
        FishBehaviors.step(self, fish, now, pos, BossMoves.combat_params(chase, key), combat)
        return
    end
    self:update_eel(fish, now, GameCfg.Ability.FishAbilities[combat])
end

function Mgr:combat_payload(fish, gone)
    if gone then return { id = fish.Id, state = 'gone' } end
    local entry = GameCfg.Ability.FishAbilities[GameCfg.Fish[fish.fish_id].Combat]
    local pos = readPosition(fish.carrier.body) or fish.combat_position or fish.Anchor
    return { id = fish.Id, fishId = fish.fish_id, state = fish.State,
        phase = fish.Phase and fish.Phase.Phase,
        fleeAt = fish.flee_at, escapeSec = GameCfg.Fish[fish.fish_id].EscapeSec,
        wakeAt = fish.wake_at, move = fish.MoveName, discharges = fish.discharges or 0, dischargeCount = entry and entry.DischargeCount,
        position = pos and { x = pos.x, y = pos.y, z = pos.z } }
end

function Mgr:refresh_moving_combat(fish, now)
    if GameCfg.Ability.FishAbilities[GameCfg.Fish[fish.fish_id].Combat] then return end
    if now < (fish.combat_refresh_at or 0) then return end
    fish.combat_refresh_at = now + GameCfg.FishCombatLabel.MovingRefreshSec
    self:publish_combat(fish)
end

function Mgr:publish_combat(fish, gone)
    local species = GameCfg.Fish[fish.fish_id]
    if not (species and species.Combat) then return end
    if gone and not fish.combat_published then return end
    fish.combat_published = not gone and fish.State ~= Mgr.State.escaping
    local publish = self.combat_publisher
    if not publish and self.combat_re then
        publish = function(payload) self.combat_re:FireAllClients(payload) end
    end
    if not publish then return end
    local ok, err = pcall(publish, self:combat_payload(fish, gone))
    if not ok then print('[FishTree] 战斗状态广播失败', 'fish=' .. tostring(fish.Id), tostring(err)) end
end

function Mgr:handle_combat_request(player)
    if not player or not self.combat_re then return false end
    for _, fish in pairs(self.Fish) do
        if fish.combat_published then
            local ok, err = pcall(function() self.combat_re:FireClient(player, self:combat_payload(fish)) end)
            if not ok then print('[FishTree] 战斗快照发送失败', player.UserId, tostring(err)) end
        end
    end
    return true
end

function Mgr:start_combat_channel()
    if self.combat_channel_started then return end
    self.combat_channel_started = true
    if type(self.bind_combat_channel) == 'function' then
        self.combat_request_conn = self.bind_combat_channel(function(player)
            self:handle_combat_request(player)
        end)
    end
end

function Mgr:update_eel(fish, now, entry)
    local body = fish.carrier.body
    body.Position = fish.combat_position
    body.LinearVelocity = Vector3.New(0, 0, 0)
    if fish.State == Mgr.State.sleeping then
        if now < fish.wake_at then return end
        if fish.combat_rotation then body.Rotation = fish.combat_rotation end
        self:set_state(fish, Mgr.State.Combat)
        fish.wake_at = nil
        fish.discharges = 0
        fish.warn_at, fish.discharge_at = nil, nil
        print('[FishTree] 电鳗醒来', 'fish=' .. tostring(fish.Id))
        self:publish_combat(fish)
    end
    local attacking = fish.State == Mgr.State.attacking
    local done = fish.discharges or 0
    local windup = bossWindup(fish, 'discharge')
    local interval = entry.DischargeIntervalSec
    if attacking then self:flail_eel(fish, now, entry) end
    if attacking and done >= entry.DischargeCount and not fish.discharge_at then
        if now < (fish.warn_at or math.huge) then return end
        if fish.combat_rotation and Quaternion then
            body.Rotation = fish.combat_rotation * Quaternion.FromEulerAngles(0, 0, entry.SleepRollRadians)
        end
        self:set_state(fish, Mgr.State.sleeping)
        fish.wake_at = now + entry.SleepSec
        fish.warn_at = nil
        publishBite(self, GarBiteNotice.clear(fish.Id, 'sleep'))
        print('[FishTree] 电鳗睡眠', 'fish=' .. tostring(fish.Id), 'wakeAt=' .. tostring(fish.wake_at))
        self:publish_combat(fish)
        return
    end
    if fish.discharge_at then
        if now < fish.discharge_at then return end
    elseif not attacking then
        fish.State, fish.attack_at = Mgr.State.attacking, now
        done, fish.discharges = 0, 0
        fish.warn_at = now
    elseif now < fish.warn_at then
        return
    end
    if not fish.discharge_at then
        local warning = BossMoves.warning_of('eel', 'discharge')
        local notice = GarBiteNotice.lock(fish.Id, fish.combat_position or body.Position, 0, 1,
            warning.Range, 180, warning.WindupSec)
        notice.move, notice.shape, notice.notice = 'discharge', warning.Shape, warning.Notice
        publishBite(self, notice)
        fish.discharge_at, fish.warn_at = now + windup, now + interval
        self:publish_combat(fish)
        return
    end
    local castOk, casted = true, false
    if self.Ability then castOk, casted = pcall(self.Ability.cast_fish, self.Ability, fish) end
    if not castOk then
        print('[FishTree] 电鳗施法异常', 'fish=' .. tostring(fish.Id), tostring(casted))
    end
    if not castOk or not casted then
        fish.discharge_at = now
        if not fish.cast_rejected then
            fish.cast_rejected = true
            print('[FishTree] 电鳗施法未成功，下帧重试', 'fish=' .. tostring(fish.Id), 'done=' .. tostring(done))
        end
        return
    end
    fish.cast_rejected, fish.discharge_at = nil, nil
    fish.discharges = done + 1
    print('[FishTree] 电鳗放电', 'fish=' .. tostring(fish.Id), fish.discharges .. '/' .. entry.DischargeCount)
    self:publish_combat(fish)
end

function Mgr:flail_eel(fish, now, entry)
    if fish.combat_rotation and Quaternion then
        fish.carrier.body.Rotation = fish.combat_rotation * Quaternion.FromEulerAngles(0,
            math.sin((now - fish.attack_at) * math.pi * 2 * entry.FlailHz) * entry.FlailRadians, 0)
    end
end


local function zoneScene(zoneId)
    for _, zone in ipairs(GameCfg.Zones or {}) do
        if zone.Id == zoneId then return zone.Scene end
    end
end

function Mgr:flight_profile(fishId)
    local species = GameCfg.Ability.Flight.Species
    if species and species[fishId] then
        return BossMoves.combat_params(species[fishId], fishId)
    end
    local fish = GameCfg.Fish[fishId]
    if fish and fish.CatchSource == 'air' and (fish.Grade == 'normal' or fish.Grade == 'rare') then
        return { Speed = fish.Speed, CruiseHeight = GameCfg.Ability.Flight.CruiseHeight,
            DiveIntervalSec = math.huge }
    end
end

function Mgr:boss_phase_enabled(fishId)
    local species = GameCfg.Ability.BossPhase.Species
    return type(species) == 'table' and species[fishId] == true
end

function Mgr:flight_bounds(fishId, position)
    local species = GameCfg.Fish[fishId]
    local scene = species and zoneScene(species.ZoneId)
    if position and species and species.ZoneId == 'reefIsland' then
        for _, zone in ipairs(GameCfg.Zones) do
            local boundary = zone.Scene and zone.Scene.Boundary
            if boundary and position.x >= boundary.MinX and position.x <= boundary.MaxX
                and position.z >= boundary.MinZ and position.z <= boundary.MaxZ then
                scene = zone.Scene
                break
            end
        end
    end
    local bounds = FlightPath.bounds_of(scene, GameCfg.Ability.Flight)
    if bounds then return bounds end
    local fallback = GameCfg.Ability.Flight.FallbackBounds
    if not fallback then return nil end
    return FlightPath.bounds_of({ Boundary = fallback, SafePoint = { x = 0, y = 0, z = 0 } }, GameCfg.Ability.Flight)
end

function Mgr:start_flight(fish, now)
    if self.ai then self.ai:custom(fish) end
    local profile = self:flight_profile(fish.fish_id)
    local pos = readPosition(fish.carrier.body)
    local bounds = self:flight_bounds(fish.fish_id, pos)
    if not profile or not bounds then return false end
    fish.Flight = FlightPath.new(bounds, GameCfg.Ability.Flight, profile, pos, now)
    fish.flight_at = now
    self:set_state(fish, Mgr.State.flying)
    fish.dive_active = false
    if fish.fish_id == 'fish55Elite' then
        self:start_aquatic(fish, now)
    end
    if GameCfg.Fish[fish.fish_id].ZoneId == 'reefIsland' then
        fish.Flight.next_dive_at = math.huge
        fish.NextReefDiveAt = now + (profile.DiveIntervalSec or math.huge)
        fish.NextThrowAt = now + (profile.ThrowIntervalSec or math.huge)
        fish.air_attacks = {}
        self:publish_combat(fish)
    end
    pcall(function() fish.carrier.body.BodyType = 2 end)
    print('[FishTree] 起飞', fish.fish_id, 'fish=' .. tostring(fish.Id))
    return true
end

function Mgr:exit_flight(fish, now, reason)
    self:end_air_attacks(fish, reason)
    fish.Flight = nil
    fish.dive_active = false
    if self.Fish[fish.Id] ~= fish then return end
    self:set_state(fish, Mgr.State.escaping)
    fish.straight_escape = true
    self:publish_combat(fish, true)
    fish.escape_at = now
    fish.escape_by = nil
    fish.turn_at = now + cfg().TurnSec
    fish.ray_at = now
    if fish.combat_rotation then pcall(function() fish.carrier.body.Rotation = fish.combat_rotation end) end
    self:set_heading(fish, towardWater(readPosition(fish.carrier.body) or fish.Anchor))
    print('[FishTree] 结束飞行', reason or '', fish.fish_id, 'fish=' .. tostring(fish.Id))
end

function Mgr:start_air_attack(fish, kind, pos, now)
    local flight, profile = GameCfg.Ability.Flight, fish.Flight.profile
    self.next_air_attack_id = (self.next_air_attack_id or 0) + 1
    local dive = kind == 'airDive'
    local duration = dive and (flight.ReefDiveWarnSec + flight.ReefDiveSec) or flight.ThrowFlightSec
    local attack = { Id = -self.next_air_attack_id, Kind = kind, at = now, strike_at = now + duration,
        Center = { x = pos.x, y = pos.y, z = pos.z },
        Origin = { x = fish.Flight.pos.x, y = fish.Flight.pos.y, z = fish.Flight.pos.z },
        Radius = dive and flight.DiveRadius or profile.ThrowRadius,
        Damage = dive and profile.DiveDamage or profile.ThrowDamage }
    local b = fish.Flight.bounds
    attack.Center.x = math.max(b.MinX,math.min(b.MaxX,attack.Center.x))
    attack.Center.z = math.max(b.MinZ,math.min(b.MaxZ,attack.Center.z))
    attack.Center.y = math.max(b.ground_y,math.min(b.ceiling_y,attack.Center.y))
    fish.air_attacks[kind] = attack
    local payload = GarBiteNotice.lock(attack.Id, attack.Center, 0, 1, attack.Radius, 180, duration)
    payload.shape, payload.move, payload.ownerFishId = 'circle', kind, fish.Id
    payload.flightOrigin = attack.Origin
    local row = BossMoves.get(fish.fish_id, dive and 'dive' or 'throw')
    if row and row.Delivery and row.Warning.Kind ~= 'none' then
        payload.shape = row.Warning.Kind or payload.shape
        payload.notice, payload.delivery, payload.landing = row.Warning.Notice, row.Delivery, row.Landing
        payload.landingPoint = attack.Center
    end
    publishBite(self, payload)
    print('[FishTree] 空战预警', fish.fish_id, kind, attack.Id, attack.Damage)
    return attack
end

function Mgr:end_air_attacks(fish, reason)
    for _, attack in pairs(fish.air_attacks or {}) do
        publishBite(self, GarBiteNotice.clear(attack.Id, reason or 'gone'))
    end
    fish.air_attacks = nil
end

function Mgr:update_air_attacks(fish, targetPos, now)
    local state, flight = fish.Flight, GameCfg.Ability.Flight
    if not fish.air_attacks then return false end
    for kind, attack in pairs(fish.air_attacks) do
        if now >= attack.strike_at - 1e-8 then
            fish.air_attacks[kind] = nil
            local hit = false
            for _, player in ipairs(self:players()) do
                local valid, cp = self:is_target_valid(player, attack.Center)
                if valid and (cp.x-attack.Center.x)^2 + (cp.z-attack.Center.z)^2 <= attack.Radius^2
                    and math.abs(cp.y-attack.Center.y) <= attack.Radius then
                    hit = self:hit(fish, player, attack.Damage, kind) or hit
                end
            end
            publishBite(self, GarBiteNotice.clear(attack.Id, hit and 'hit' or 'miss'))
            if kind == 'airDive' then
                state.pos = {x=attack.Center.x,y=attack.Center.y,z=attack.Center.z}
                state.last = {x=state.pos.x,y=state.pos.y,z=state.pos.z}
                state.Phase = 'climb'
            end
        end
    end
    if targetPos then
        if now >= (fish.NextThrowAt or math.huge) - 1e-8 then
            fish.NextThrowAt = now + state.profile.ThrowIntervalSec
            self:start_air_attack(fish, 'airThrow', targetPos, now)
        end
        if now >= (fish.NextReefDiveAt or math.huge) - 1e-8 then
            fish.NextReefDiveAt = now + state.profile.DiveIntervalSec
            self:start_air_attack(fish, 'airDive', targetPos, now)
        end
    end
    local dive = fish.air_attacks.airDive
    if not dive then return false end
    local progress = math.min(1, math.max(0, (now-dive.at-flight.ReefDiveWarnSec)/flight.ReefDiveSec))
    state.pos = { x=dive.Origin.x+(dive.Center.x-dive.Origin.x)*progress,
        y=dive.Origin.y+(dive.Center.y-dive.Origin.y)*progress,
        z=dive.Origin.z+(dive.Center.z-dive.Origin.z)*progress }
    state.last = {x=state.pos.x,y=state.pos.y,z=state.pos.z}
    state.vel = {x=0,y=0,z=0}
    return true
end

function Mgr:update_flying(fish, now)
    local state = fish.Flight
    local body = fish.carrier.body
    if not state then
        self:remove(fish)
        return
    end
    local pos = readPosition(body)
    if not pos then
        print('[FishTree] 飞行鱼坐标异常，移除', fish.Id)
        self:remove(fish)
        return
    end
    if fish.fish_id == 'fish55Elite' then
        if fish.flee_at and now >= fish.flee_at then
            self:end_boss_attack(fish, 'timeout')
            self:release_carried(fish, nil, 'timeout')
            fish.Aquatic = nil
            self:exit_flight(fish, now, 'timeout')
        else
            self:update_aquatic(fish,now)
        end
        return
    end
    if (fish.flee_at and now >= fish.flee_at) or (inWater(pos) and pos.y <= inWater(pos).SurfaceY) then
        self:exit_flight(fish, now, (fish.flee_at and now >= fish.flee_at) and 'timeout' or 'water')
        return
    end
    local flight = GameCfg.Ability.Flight
    local target, tpos = self:choose_target(fish, pos, { AggroRange = flight.AggroRange })
    FlightPath.set_target(state, tpos)
    local dt = math.max(0, now - (fish.flight_at or now))
    fish.flight_at = now
    if self.ai then
        self.ai:custom(fish)
        local speed = GameCfg.Fish[fish.fish_id].Speed
        if speed and speed > 0 then dt = dt * self:speed(fish) / speed end
    end
    local diving = self:update_air_attacks(fish, tpos, now)
    local events = diving and {} or FlightPath.step(state, now, dt)
    local moved, moveErr = pcall(function()
        body.Position = Vector3.New(state.pos.x, state.pos.y, state.pos.z)
    end)
    if not moved then
        print('[FishTree] 飞行位置写回失败', fish.fish_id, tostring(moveErr))
        if self.ai then self:remove(fish); return end
    end
    MgrFishCarrier:sync_position(fish.carrier, Vector3.New(state.pos.x,state.pos.y,state.pos.z))
    self:refresh_moving_combat(fish, now)
    pcall(function()
        body.LinearVelocity = Vector3.New(state.vel.x, state.vel.y, state.vel.z)
    end)
    if events.dive then
        fish.dive_active = true
    elseif fish.dive_active and state.Phase == 'climb' then
        fish.dive_active = false
        if target and tpos then
            local dx, dz = tpos.x - state.pos.x, tpos.z - state.pos.z
            if math.sqrt(dx * dx + dz * dz) <= flight.DiveRadius then
                self:hit(fish, target, events.diveDamage or state.profile.DiveDamage or flight.DiveDamage, 'dive')
            end
        end
    end
end

function Mgr:hit(fish, target, damage, kind)
    if not target or not self.Vitals or type(damage) ~= 'number' or damage <= 0 then return false end
    local hit = self.Vitals:new_hit(fish, 'fishAttack')
    local applied = self.Vitals:apply_hit(hit, target, damage)
    if applied then
        print('[FishTree] 命中', kind or 'attack', fish.fish_id, damage, 'fish=' .. tostring(fish.Id))
    end
    return applied == true
end

function Mgr:update_boss_phase(fish, now, pos)
    if self.ai then self.ai:custom(fish) end
    local state = fish.Phase
    if not state then
        self:remove(fish)
        return
    end
    local params = GameCfg.FishCombat and GameCfg.FishCombat[fish.Fight] or nil
    params = params or GameCfg.Ability.BossPhase.Chase
    local target, tpos = self:choose_target(fish, pos, params)
    local dt = math.max(0, now - (fish.phase_at or now))
    fish.phase_at = now
    pcall(function() fish.carrier.body.LinearVelocity = Vector3.New(0, 0, 0) end)
    local events = BossPhase.update(state, now, dt, {
        Health = fish.carrier.Health, MaxHealth = fish.carrier.MaxHealth,
        alive = not fish.carrier.dead, Target = tpos, pos = pos,
    })
    if fish.boss_warn and (events.phase_changed or events.interrupted or not state.alive) then
        self:end_boss_attack(fish, events.to or events.Reason or 'gone')
    end
    if events.phase_changed then
        self:release_carried(fish,nil,'phase')
        self:end_air_attacks(fish,'phase')
        self:end_move(fish,'phase')
        fish.Aquatic=nil
        if events.to == 'water' then
            self:start_aquatic(fish,now)
        else
            local p=fish.combat_position
            fish.carrier.body.Position=Vector3.New(p.x,p.y,p.z)
            MgrFishCarrier:sync_position(fish.carrier,Vector3.New(p.x,p.y,p.z))
        end
        self:publish_combat(fish)
        print('[FishTree] 首领阶段',fish.fish_id,events.to,events.Percent)
        return
    end
    if state.Phase == 'water' then self:update_aquatic(fish,now); return end
    if state.pending and not fish.boss_warn then
        local fx, fz = flatDirection(tpos.x-pos.x,tpos.z-pos.z)
        fx, fz = fx or 0, fz or 1
        self:face(fish,fx,fz)
        local attackCfg = GameCfg.Ability.BossPhase.Attacks[state.pending.Name]
        local row = BossMoves.get(BossMoves.key_of(GameCfg.Fish[fish.fish_id], fish.fish_id),
            state.pending.Name)
        fish.boss_warn = { Origin = {x=pos.x,y=pos.y,z=pos.z}, facing = {x=fx,z=fz}, Target = target }
        if not row or row.Warning.Kind ~= 'none' then
            local notice = GarBiteNotice.lock(fish.Id,pos,fx,fz,attackCfg.Range,0,attackCfg.WindupSec)
            notice.move = row and row.Warning.Notice or 'bossStomp'
            notice.shape, notice.width = row and row.Warning.Kind or 'circle',
                (row and row.Warning.Width) or attackCfg.Width
            publishBite(self,notice)
        end
    end
    if fish.Carry then self:update_carry(fish,now); return end
    if not events.Attack then return end
    local attack = events.Attack
    if attack.Name == 'stomp' then
        local warn=fish.boss_warn
        self:end_boss_attack(fish,'stomp')
        if not warn then return end
        local radius=GameCfg.Ability.BossPhase.Attacks.stomp.Range
        for _, player in ipairs(self:players()) do
            local valid,cp=self:is_target_valid(player,warn.Origin)
            if valid and (cp.x-warn.Origin.x)^2+(cp.z-warn.Origin.z)^2<=radius^2
                and math.abs(cp.y-warn.Origin.y)<=radius then
                self:hit(fish,player,attack.Damage,'stomp')
            end
        end
        return
    end
    if attack.lethal then
        local warn = fish.boss_warn
        self:end_boss_attack(fish,'strike')
        if not warn then return end
        local breath = GameCfg.Ability.BossPhase.Attacks.breath
        for _, player in ipairs(self:players()) do
            local valid, cp = self:is_target_valid(player,warn.Origin)
            if valid then
                local dx,dz = cp.x-warn.Origin.x,cp.z-warn.Origin.z
                local along = dx*warn.facing.x+dz*warn.facing.z
                local across = math.abs(dx*warn.facing.z-dz*warn.facing.x)
                if along >= 0 and along <= breath.Range and across <= breath.Width/2
                    and math.abs(cp.y-warn.Origin.y) <= GameCfg.Ability.BossPhase.Chase.BiteRange then
                    self:hit(fish,player,player.Character.Controller.Health,'breath')
                end
            end
        end
        return
    end
    if attack.Name == 'bite' and target and tpos and CarryMount.in_range(
        CarryMount.new(GameCfg.Ability.Carry, pos, fish.Yaw or 0, now), tpos) then
        self:grab_player(fish, target, now, attack.Damage)
        return
    end
    if target then self:hit(fish, target, attack.Damage, attack.Name) end
end

function Mgr:end_boss_attack(fish, reason)
    if not fish.boss_warn then return end
    fish.boss_warn = nil
    if fish.Phase then fish.Phase.pending = nil end
    publishBite(self,GarBiteNotice.clear(fish.Id,reason or 'gone'))
end

function Mgr:start_aquatic(fish, now)
    local pos = readPosition(fish.carrier.body)
    local scene
    for _, zone in ipairs(GameCfg.Zones) do
        local b=zone.Scene.Boundary
        if pos.x>=b.MinX and pos.x<=b.MaxX and pos.z>=b.MinZ and pos.z<=b.MaxZ then
            scene=zone.Scene; break
        end
    end
    if not scene or not scene.Waters[1] then return false end
    fish.Aquatic={ Scene=scene, Water=scene.Waters[1], last_at=now,
        next_leap_at=now+GameCfg.Ability.Aquatic.LeapIntervalSec, Angle=0 }
    self:publish_combat(fish)
    return true
end

function Mgr:update_aquatic(fish, now)
    local state=fish.Aquatic
    if not state then return end
    if self.ai then self.ai:custom(fish) end
    local cfg=GameCfg.Ability.Aquatic
    local body=fish.carrier.body
    local p=readPosition(body)
    local dt=math.min(0.25,math.max(0,now-state.last_at))
    state.last_at=now
    local speed=self:speed(fish)
    local w=state.Water
    local function moveTo(destination)
        local dx,dy,dz=destination.x-p.x,destination.y-p.y,destination.z-p.z
        local distance=math.sqrt(dx*dx+dy*dy+dz*dz)
        local t=distance>0 and math.min(1,speed*dt/distance) or 1
        p={x=p.x+dx*t,y=p.y+dy*t,z=p.z+dz*t}
    end
    if state.head_at and now>=state.head_at then
        local center=state.head_center
        state.head_at,state.head_center=nil,nil
        self:end_boss_attack(fish,'head')
        for _, player in ipairs(self:players()) do
            local valid,cp=self:is_target_valid(player,center)
            if valid and (cp.x-center.x)^2+(cp.z-center.z)^2<=cfg.HeadRadius^2 then
                self:hit(fish,player,cfg.HeadDamage,'head')
            end
        end
    end
    if fish.Carry then
        moveTo({x=w.Center.x,y=w.SurfaceY,z=w.Center.z})
        body.Position=Vector3.New(p.x,p.y,p.z)
        self:update_carry(fish,now)
        if inWater(p) then
            self:release_carried(fish,{x=p.x,y=w.SurfaceY,z=p.z},'water')
        end
    elseif state.leap then
        local leap=state.leap
        local progress=math.min(1,math.max(0,(now-leap.at-cfg.LeapWindupSec)/cfg.LeapSec))
        p={x=leap.Origin.x+(leap.Center.x-leap.Origin.x)*progress,
            y=leap.Origin.y+(leap.Center.y-leap.Origin.y)*progress+cfg.LeapHeight*math.sin(math.pi*progress),
            z=leap.Origin.z+(leap.Center.z-leap.Origin.z)*progress}
        body.Position=Vector3.New(p.x,p.y,p.z)
        if progress>=1 then
            local phase = fish.Phase and fish.Phase.Phase
            state.leap=nil
            self:end_boss_attack(fish,'land')
            for _, player in ipairs(self:players()) do
                local valid,cp=self:is_target_valid(player,p)
                if valid and (cp.x-p.x)^2+(cp.z-p.z)^2<=cfg.LeapRadius^2 then
                    self:hit(fish,player,cfg.LeapDamage,'leap')
                end
            end
            if self.Fish[fish.Id] ~= fish or fish.Aquatic ~= state
                or (fish.Phase and fish.Phase.Phase) ~= phase then return end
            local valid,cp=self:is_target_valid(leap.Target,p)
            if valid and (cp.x-p.x)^2+(cp.z-p.z)^2<=GameCfg.Ability.Carry.GrabRange^2 then
                local damage=fish.Phase and GameCfg.Ability.BossPhase.Thresholds[1].BiteDamage or cfg.GrabDamage
                self:grab_player(fish,leap.Target,now,damage)
            end
            if self.Fish[fish.Id] ~= fish or fish.Aquatic ~= state
                or (fish.Phase and fish.Phase.Phase) ~= phase
                or not self:is_target_valid(leap.Target,p) then return end
            state.head_at=now+cfg.HeadWindupSec
            state.head_center={x=p.x,y=p.y,z=p.z}
            local n=GarBiteNotice.lock(fish.Id,p,0,1,cfg.HeadRadius,180,cfg.HeadWindupSec)
            n.shape,n.move='circle','mosasaurHead'
            fish.boss_warn={Target=leap.Target}
            publishBite(self,n)
        end
    elseif not state.head_at then
        if now>=state.next_leap_at then
            local target,tpos,best
            local center=state.Scene.SafePoint
            for _, player in ipairs(self:players()) do
                local valid,cp=self:is_target_valid(player,center,{AggroRange=GameCfg.Ability.Flight.AggroRange})
                if valid then
                    local d=(cp.x-center.x)^2+(cp.z-center.z)^2
                    if not best or d<best then target,tpos,best=player,cp,d end
                end
            end
            state.next_leap_at=now+cfg.LeapIntervalSec
            if target then
                state.leap={at=now,Origin={x=p.x,y=p.y,z=p.z},Center={x=tpos.x,y=tpos.y,z=tpos.z},Target=target}
                fish.boss_warn={Target=target}
                local n=GarBiteNotice.lock(fish.Id,tpos,0,1,cfg.LeapRadius,180,cfg.LeapWindupSec+cfg.LeapSec)
                n.shape,n.move='circle','mosasaurLeap'
                publishBite(self,n)
            end
        else
            state.Angle=state.Angle+speed*dt/20
            moveTo({x=w.Center.x+math.cos(state.Angle)*(w.HalfX or w.HalfXZ)*0.6,
                y=w.SurfaceY,z=w.Center.z+math.sin(state.Angle)*(w.HalfZ or w.HalfXZ)*0.6})
        end
    end
    body.Position=Vector3.New(p.x,p.y,p.z)
    body.LinearVelocity=Vector3.New(0,0,0)
    MgrFishCarrier:sync_position(fish.carrier, Vector3.New(p.x,p.y,p.z))
    self:refresh_moving_combat(fish,now)
end

function Mgr:grab_player(fish, target, now, damage)
    if fish.Carry then return false end
    local carryCfg = GameCfg.Ability.Carry
    local pos = readPosition(fish.carrier.body)
    if not pos then return false end
    local state = CarryMount.new(carryCfg, pos, fish.Yaw or 0, now)
    state.ground_y = (fish.Anchor and fish.Anchor.y) or pos.y
    state.target_player = target
    state.last_step_at = now
    local grabbed = CarryMount.attach(state, target.Character and readPosition(target.Character) or pos, now)
    if not grabbed.Ok then
        print('[FishTree] 叼人失败', tostring(grabbed.Reason), 'fish=' .. tostring(fish.Id))
        return false
    end
    fish.Carry = state
    self:hit(fish, target, damage or carryCfg.GrabDamage, 'bite')
    if fish.Carry ~= state or not self:is_target_valid(target, pos) then
        if fish.Carry == state then self:release_carried(fish, nil, 'gone') end
        return false
    end
    fish.contact_at = now
    local ok, attached = pcall(function()
        local api = abilityApi(self)
        if not api then return nil end
        return api.attach_to_socket(self.World, nil, fish.carrier.body, carryCfg.Socket, state.Offset)
    end)
    if ok and attached and attached.Ok then
        fish.carry_mount = attached.mount
    else
        print('[FishTree] 叼人挂点创建失败', 'fish=' .. tostring(fish.Id), tostring(attached))
    end
    print('[FishTree] 叼起玩家', target.UserId, 'fish=' .. tostring(fish.Id))
    return true
end

function Mgr:update_carry(fish, now)
    local state = fish.Carry
    local carryCfg = GameCfg.Ability.Carry
    local pos = readPosition(fish.carrier.body)
    if pos then state.host = pos end
    local dt = math.max(0, now - (state.last_step_at or now))
    state.last_step_at = now
    local target = state.target_player
    local tpos = target and target.Character and readPosition(target.Character)
    if not tpos or not self:is_target_valid(target, pos) then
        self:release_carried(fish, nil, 'gone')
        return
    end
    local step = CarryMount.step(state, now, dt)
    if step.released then
        self:release_carried(fish, step.drop_point, step.Reason)
        return
    end
    local followed = CarryMount.follow(state, tpos, now, dt)
    if followed.released then
        self:release_carried(fish, followed.Position, followed.Reason)
        return
    end
    if followed.Position and target.Character then
        pcall(function()
            target.Character.Position = Vector3.New(followed.Position.x, followed.Position.y, followed.Position.z)
        end)
    end
    if carryCfg.ContactDamage and now - (fish.contact_at or 0) >= (carryCfg.ContactIntervalSec or 1) then
        fish.contact_at = now
        self:hit(fish, target, carryCfg.ContactDamage, 'carry')
        if fish.Aquatic then
            local contact=GameCfg.Ability.Aquatic
            for _, player in ipairs(self:players()) do
                local valid,cp=self:is_target_valid(player,pos)
                if player~=target and valid
                    and (cp.x-pos.x)^2+(cp.z-pos.z)^2<=contact.ContactRange^2
                    and math.abs(cp.y-pos.y)<=contact.ContactRange then
                    self:hit(fish,player,contact.ContactDamage,'carryContact')
                end
            end
        end
    end
end

function Mgr:release_carried(fish, dropPoint, reason)
    local state = fish.Carry
    if not state then return false end
    local now = self:now()
    local target = state.target_player
    local drop = dropPoint or CarryMount.drop_point(state.host, state.Yaw, state.ground_y, GameCfg.Ability.Carry)
    CarryMount.release(state, now, reason or 'release')
    fish.Carry = nil
    fish.contact_at = nil
    if fish.carry_mount then
        local api = abilityApi(self)
        if api then pcall(api.detach_from_socket, fish.carry_mount) end
        fish.carry_mount = nil
    end
    if target and target.Character and drop then
        pcall(function() target.Character.Position = Vector3.New(drop.x, drop.y, drop.z) end)
        self:hit(fish, target, GameCfg.Ability.Carry.FallDamage or 0, 'fall')
    end
    print('[FishTree] 放开玩家', target and target.UserId, reason or '', 'fish=' .. tostring(fish.Id))
    return true
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

function Mgr:weight(fish)
    return FishCatch.weight(GameCfg.Fish[fish.fish_id], fish.mult)
end

function Mgr:Price(fish)
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

function Mgr:stabilize(fish)
    local body = fish.carrier.body
    local anchor = fish.Anchor
    if not body or not anchor then return end
    local pos = readPosition(body)
    local tol = cfg().AwaitDriftTolerance
    if pos and math.abs(pos.x - anchor.x) <= tol and math.abs(pos.y - anchor.y) <= tol
        and math.abs(pos.z - anchor.z) <= tol then return end
    pcall(function()
        body.Position = anchor
        body.LinearVelocity = Vector3.New(0, 0, 0)
        body.AngularVelocity = Vector3.New(0, 0, 0)
    end)
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

function Mgr.new()
  local host = { Fish = {}, next_id = 0, held = {}, links = {} }
  return setmetatable(host, { __index = Mgr })
end

function Mgr:damage_fish(fish, amount)
  if type(fish) ~= 'table' or self.Fish[fish.Id] ~= fish then return false end
  if not Number.is_finite_number(amount) or amount <= 0 then return false end
  local carrier = fish.carrier
  if not carrier then return false end
  local health = (carrier.Health or 0) - amount
  if health < 0 then health = 0 end
  carrier.Health = health
  if carrier.Controller then
    pcall(function() carrier.Controller.Health = health end)
  end
  if health <= 0 then
    self:on_carrier_died(carrier)
  elseif type(self.on_state_changed) == 'function' then
    self.on_state_changed(fish)
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

return Mgr
