local GameCfg = require('common.game_cfg')
local MgrFishCarrier = require('server.world_host.fish_carrier')
local FlightPath = require('common.flight_path')
local CarryMount = require('common.carry_mount')
local CommonBossPhase = require('common.boss_phase')
local GarBiteNotice = require('common.gar_bite_notice')
local BossMoves = require('common.cfg.boss_moves')

---@class FishBossAttackConfig
---@field Range number
---@field WindupSec number
---@field Width number

---@class FishBossAttackEvent
---@field Name string
---@field Damage number
---@field lethal? boolean

---@class FishBossPosition
---@field x number
---@field y number
---@field z number

---@class FishBossReadyZone
---@field Scene FishBossReadyScene

---@class FishBossReadyScene
---@field Boundary FishTreeBoundary
---@field Waters table

local BossPhase = {}

function BossPhase.install(Mgr, context)
    local cfg = context.cfg
    local readPosition = context.readPosition
    local abilityApi = context.abilityApi
    local flatDirection = context.flatDirection
    local towardWater = context.towardWater
    local inWater = context.inWater
    local publishBite = context.publishBite

    local function zoneScene(zoneId)
        for _, zone in ipairs(GameCfg.Zones or {}) do
            ---@cast zone FishTreeZone
            if zone.Id == zoneId then return zone.Scene end
        end
    end

    function Mgr.flight_profile(_, fishId)
        local species = GameCfg.Ability.Flight.Species
        local profile = species and species[fishId]
        ---@cast profile table?
        if profile then
            return BossMoves.combat_params(profile, fishId)
        end
        local fish = GameCfg.Fish[fishId]
        if fish and fish.CatchSource == 'air' and (fish.Grade == 'normal' or fish.Grade == 'rare') then
            return { Speed = fish.Speed, CruiseHeight = GameCfg.Ability.Flight.CruiseHeight,
                DiveIntervalSec = math.huge }
        end
    end

    function Mgr.boss_phase_enabled(_, fishId)
        local species = GameCfg.Ability.BossPhase.Species
        return type(species) == 'table' and species[fishId] == true
    end

    function Mgr.flight_bounds(_, fishId, position)
        local species = GameCfg.Fish[fishId]
        local scene = species and zoneScene(species.ZoneId)
        if position and species and species.ZoneId == 'reefIsland' then
            for _, zone in ipairs(GameCfg.Zones) do
                ---@cast zone FishTreeZone
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
            ---@cast speed number?
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

    function Mgr:hit(fish, target, damage, kind, log_label)
        if not target or not self.Vitals or type(damage) ~= 'number' or damage <= 0 then return false end
        local hit = self.Vitals:new_hit(fish, 'fishAttack')
        local applied = self.Vitals:apply_hit(hit, target, damage)
        if applied then
            if log_label then
                print('[FishTree] ' .. log_label, fish.fish_id, damage, 'fish=' .. tostring(fish.Id))
            else
                print('[FishTree] 命中', kind or 'attack', fish.fish_id, damage, 'fish=' .. tostring(fish.Id))
            end
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
        local events = CommonBossPhase.update(state, now, dt, {
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
            ---@cast attackCfg FishBossAttackConfig
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
        ---@cast attack FishBossAttackEvent
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
            ---@cast breath FishBossAttackConfig
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
            ---@cast zone FishBossReadyZone
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
        local aquatic_cfg=GameCfg.Ability.Aquatic
        local body=fish.carrier.body
        local p=readPosition(body)
        local dt=math.min(0.25,math.max(0,now-state.last_at))
        state.last_at=now
        local speed=self:speed(fish)
        local w=state.Water
        local function moveTo(destination)
            local dx,dy,dz=destination.x-p.x,destination.y-p.y,destination.z-p.z
            local distance=math.sqrt(dx*dx+dy*dy+dz*dz)
            ---@type number
            local t=distance>0 and math.min(1,speed*dt/distance) or 1
            p={x=p.x+dx*t,y=p.y+dy*t,z=p.z+dz*t}
        end
        if state.head_at and now>=state.head_at then
            local center=state.head_center
            state.head_at,state.head_center=nil,nil
            self:end_boss_attack(fish,'head')
            for _, player in ipairs(self:players()) do
                local valid,cp=self:is_target_valid(player,center)
                if valid and (cp.x-center.x)^2+(cp.z-center.z)^2<=aquatic_cfg.HeadRadius^2 then
                    self:hit(fish,player,aquatic_cfg.HeadDamage,'head')
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
            local progress=math.min(1,math.max(0,(now-leap.at-aquatic_cfg.LeapWindupSec)/aquatic_cfg.LeapSec))
            p={x=leap.Origin.x+(leap.Center.x-leap.Origin.x)*progress,
                y=leap.Origin.y+(leap.Center.y-leap.Origin.y)*progress+aquatic_cfg.LeapHeight*math.sin(math.pi*progress),
                z=leap.Origin.z+(leap.Center.z-leap.Origin.z)*progress}
            body.Position=Vector3.New(p.x,p.y,p.z)
            if progress>=1 then
                local phase = fish.Phase and fish.Phase.Phase
                state.leap=nil
                self:end_boss_attack(fish,'land')
                for _, player in ipairs(self:players()) do
                    local valid,cp=self:is_target_valid(player,p)
                    if valid and (cp.x-p.x)^2+(cp.z-p.z)^2<=aquatic_cfg.LeapRadius^2 then
                        self:hit(fish,player,aquatic_cfg.LeapDamage,'leap')
                    end
                end
                if self.Fish[fish.Id] ~= fish or fish.Aquatic ~= state
                    or (fish.Phase and fish.Phase.Phase) ~= phase then return end
                local valid,cp=self:is_target_valid(leap.Target,p)
                if valid and (cp.x-p.x)^2+(cp.z-p.z)^2<=GameCfg.Ability.Carry.GrabRange^2 then
                    local damage=fish.Phase and GameCfg.Ability.BossPhase.Thresholds[1].BiteDamage or aquatic_cfg.GrabDamage
                    self:grab_player(fish,leap.Target,now,damage)
                end
                if self.Fish[fish.Id] ~= fish or fish.Aquatic ~= state
                    or (fish.Phase and fish.Phase.Phase) ~= phase
                    or not self:is_target_valid(leap.Target,p) then return end
                state.head_at=now+aquatic_cfg.HeadWindupSec
                state.head_center={x=p.x,y=p.y,z=p.z}
                local n=GarBiteNotice.lock(fish.Id,p,0,1,aquatic_cfg.HeadRadius,180,aquatic_cfg.HeadWindupSec)
                n.shape,n.move='circle','mosasaurHead'
                fish.boss_warn={Target=leap.Target}
                publishBite(self,n)
            end
        elseif not state.head_at then
            if now>=state.next_leap_at then
                ---@type table?
                local target
                ---@type FishBossPosition?
                local tpos
                local best
                local center=state.Scene.SafePoint
                for _, player in ipairs(self:players()) do
                    local valid,cp=self:is_target_valid(player,center,{AggroRange=GameCfg.Ability.Flight.AggroRange})
                    if valid then
                        local d=(cp.x-center.x)^2+(cp.z-center.z)^2
                        if not best or d<best then target,tpos,best=player,cp,d end
                    end
                end
                state.next_leap_at=now+aquatic_cfg.LeapIntervalSec
                if target then
                    ---@cast tpos FishBossPosition
                    state.leap={at=now,Origin={x=p.x,y=p.y,z=p.z},Center={x=tpos.x,y=tpos.y,z=tpos.z},Target=target}
                    fish.boss_warn={Target=target}
                    local n=GarBiteNotice.lock(fish.Id,tpos,0,1,aquatic_cfg.LeapRadius,180,aquatic_cfg.LeapWindupSec+aquatic_cfg.LeapSec)
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


end

return BossPhase
