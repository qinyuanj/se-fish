local GameCfg = require('common.game_cfg')
local Number = require('common.number')
local FishCatch = require('common.fish_catch')
local MathWaterJudge = require('common.math_water_judge')
local MgrFishCarrier = require('server.WorldHost.FishCarrier')
local FlightPath = require('common.flight_path')
local CarryMount = require('common.carry_mount')
local BossPhase = require('common.boss_phase')
local GarBiteNotice = require('common.gar_bite_notice')
local BossMoves = require('common.cfg.boss_moves')
local FishBehaviors = require('server.FishBehaviors')
local spoke = require('common.packages.spoke.api')
local SpokeTree, Effect, State = spoke.SpokeTree, spoke.Effect, spoke.State

local function abilityApi(self)
    return self.AbilityApi
end

local Mgr = { Fish = {}, NextId = 0, Held = {}, Links = {} }

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

Mgr.State = { AwaitLift = 'awaitLift', Held = 'held', Escaping = 'escaping',
    Combat = 'combat', Attacking = 'attacking', Sleeping = 'sleeping', Wild = 'wild',
    Flying = 'flying' }

local function cfg()
    return GameCfg.FishUnit
end

local function distanceSq(pos, cp)
    if not pos or not cp then return math.huge end
    return (cp.x - pos.x) * (cp.x - pos.x) + (cp.z - pos.z) * (cp.z - pos.z)
end

function Mgr:Now()
    local world = self.World or service('World')
    return world:GetServerTime()
end

local function isBadNumber(v)
    return not Number.IsFiniteNumber(v)
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

function Mgr:Isolate(fish)
    local body = fish.Carrier.Body
    for _, player in ipairs(self:Players()) do noCollide(body, player.Character) end
    for _, other in pairs(self.Fish) do
        if other ~= fish and other.Carrier then
            noCollide(body, other.Carrier.Body)
            noCollide(body, other.Carrier.Receiver)
            noCollide(other.Carrier.Body, fish.Carrier.Receiver)
        end
    end
end

function Mgr:IsolateCharacter(character)
    for _, fish in pairs(self.Fish) do
        if fish.Carrier then noCollide(fish.Carrier.Body, character) end
    end
end

function Mgr:Players()
    local players = service('Players')
    return players and players:GetPlayers() or {}
end

function Mgr:SetState(fish, value)
    fish.State = value
    if fish.StateSignal and fish.StateSignal:now() ~= value then
        fish.StateSignal:set(value)
    end
    if type(self.OnStateChanged) == 'function' then
        self.OnStateChanged(fish)
    end
end

function Mgr:FrameClock()
    if not self.Clock then
        self.Clock = { on_frame = spoke.Trigger.new('FishHostFrame') }
    end
    return self.Clock
end

local function lifePhase(state)
    if state == Mgr.State.AwaitLift or state == Mgr.State.Held then return 'lifted' end
    if state == Mgr.State.Escaping then return 'escaping' end
    if state == Mgr.State.Wild then return 'wild' end
    return 'combat'
end

function Mgr:UpdateFish(fish, now)
    if self.Fish[fish.Id] ~= fish then return end
    now = now or self:Now()
    if self.Ai and not MgrFishCarrier:SyncAiPosition(fish.Carrier) then
        self:Remove(fish)
        return
    end
    local controlled = self:AiControlled(fish, now)
    local canUpdate = not controlled or (fish.FleeAt ~= nil and now >= fish.FleeAt)
    if not canUpdate then return end
    if fish.State == Mgr.State.AwaitLift then
        self:Stabilize(fish)
        if fish.LiftAt and now - fish.LiftAt >= cfg().LiftConfirmSec then
            if not self:RequestLift(fish) and fish.LiftAttempts >= cfg().LiftAttempts and not fish.LiftGaveUp then
                fish.LiftGaveUp = true
                print('[FishTree] 抓举未确认，放弃重试', fish.Owner.UserId, 'fish=' .. tostring(fish.Id))
            end
        end
    elseif fish.State == Mgr.State.Wild then
        if fish.WildUntil and now >= fish.WildUntil then
            print('[FishTree] 爆炸保底鱼到期消失', fish.FishId, 'fish=' .. tostring(fish.Id))
            self:Remove(fish)
        end
    elseif fish.State == Mgr.State.Escaping then
        self:UpdateEscaping(fish, now)
    elseif fish.State == Mgr.State.Flying then
        self:UpdateFlying(fish, now)
    elseif fish.FleeAt then
        self:UpdateCombat(fish, now)
    end
end

function Mgr:MountAiProjection(fish, s, phase)
    local projection = self.AiProjection
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
            if self.Logger and type(self.Logger.error) == 'function' then
                self.Logger.error('[FishTree] operation=AiStart', 'fish=' .. tostring(fish.Id), tostring(err))
            else
                print('[FishTree] operation=AiStart', 'fish=' .. tostring(fish.Id), tostring(err))
            end
        end
        start()
        es:subscribe(self:FrameClock().on_frame, start)
        es:on_cleanup(function()
            if not started or type(projection.stop) ~= 'function' then return end
            local ok, err = pcall(projection.stop, projection, fish.Id)
            if not ok then
                if self.Logger and type(self.Logger.error) == 'function' then
                    self.Logger.error('[FishTree] operation=AiStop', 'fish=' .. tostring(fish.Id), tostring(err))
                else
                    print('[FishTree] operation=AiStop', 'fish=' .. tostring(fish.Id), tostring(err))
                end
            end
        end)
    end)
end

function Mgr:SpawnTree(fish)
    fish.StateSignal = State.new('FishState:' .. tostring(fish.Id), fish.State)
    fish.HolderTreeState = State.new('HolderTree:' .. tostring(fish.Id), fish.HolderTree)
    local host = self
    local root = Effect.new('FishTree:' .. tostring(fish.Id), function(s)
        -- 根清理最先声明、最后执行：相位与 AI 叶子拆完后，再统一回收载体和宿主信号。
        s:on_cleanup(function() host:CleanupFish(fish) end)
        local phase = s:memo('FishLifePhase', function(ms)
            return lifePhase(ms:d(fish.StateSignal))
        end)
        local lifted = s:memo('IsLifted', function(ms) return ms:d(phase) == 'lifted' end)
        local combat = s:memo('IsCombat', function(ms) return ms:d(phase) == 'combat' end)
        local escaping = s:memo('IsEscaping', function(ms) return ms:d(phase) == 'escaping' end)
        local wild = s:memo('IsWild', function(ms) return ms:d(phase) == 'wild' end)

        s:phase('LiftedPhase', lifted, function(ps)
            ps:effect('HolderAlive', function(es)
                local holder_tree = es:d(fish.HolderTreeState)
                fish.HolderTree = holder_tree
                if not holder_tree then return end
                if fish.State ~= Mgr.State.Held and fish.State ~= Mgr.State.AwaitLift then return end
                local alive = holder_tree.memos and holder_tree.memos.is_alive
                local session = holder_tree.session_alive
                if not alive or not session then return end
                if not es:d(alive) or not es:d(session) then
                    local reason = session:now() == false and 'leave' or 'life'
                    if fish.State == Mgr.State.Held then
                        host:Release(fish, reason)
                    elseif fish.State == Mgr.State.AwaitLift then
                        host:ReleaseAwaitLift(fish, reason)
                    end
                end
            end)
            ps:subscribe(host:FrameClock().on_frame, function(frame)
                host:UpdateFish(fish, frame and frame.now)
            end)
            ps:on_cleanup(function()
                if fish.Mount then pcall(function() fish.Mount:Destroy() end) end
                fish.Mount = nil
            end)
        end)
        s:phase('CombatPhase', combat, function(ps)
            ps:subscribe(host:FrameClock().on_frame, function(frame)
                host:UpdateFish(fish, frame and frame.now)
            end)
            ps:on_cleanup(function()
                local gone = host.Fish[fish.Id] ~= fish
                local reason = gone and 'gone' or 'phase'
                host:EndBossAttack(fish, reason)
                host:EndAirAttacks(fish, reason)
                host:EndBite(fish, reason)
                host:EndMove(fish, reason)
                if fish.Carry then host:ReleaseCarried(fish, nil, gone and 'died' or 'phase') end
            end)
        end)
        s:phase('EscapingPhase', escaping, function(ps)
            ps:subscribe(host:FrameClock().on_frame, function(frame)
                host:UpdateFish(fish, frame and frame.now)
            end)
            ps:on_cleanup(function()
                host:EndMove(fish, host.Fish[fish.Id] == fish and 'phase' or 'gone')
            end)
        end)
        s:phase('WildPhase', wild, function(ps)
            ps:subscribe(host:FrameClock().on_frame, function(frame)
                host:UpdateFish(fish, frame and frame.now)
            end)
        end)
        fish.FaultDock = s:dock('FaultDock:' .. tostring(fish.Id))
        host:MountAiProjection(fish, s, phase)
    end)
    local services = self.Logger and { logger = self.Logger } or nil
    fish.Tree = SpokeTree.spawn('FishTree:' .. tostring(fish.Id), root, services)
    return fish.Tree
end

function Mgr:SpawnLanded(player, catch, position)
    local species = catch and GameCfg.Fish[catch.fishId]
    if not player or not species or type(catch.mult) ~= 'number' then return nil, 'bad-catch' end
    local carrier, err = MgrFishCarrier:Spawn({
        CreateUnit = self.CreateUnit,
        Position = position,
        FishId = catch.fishId,
        MaxHealth = species.Health,
        ModelId = species.Model,
        Player = player,
        GravityEnabled = false,
        LinearDamping = cfg().LinearDamping,
        AngularDamping = cfg().AngularDamping,
    })
    if not carrier then return nil, err end
    self.NextId = self.NextId + 1
    local holder_tree = self.GetPlayerTree and self:GetPlayerTree(player) or nil
    local fish = { Id = self.NextId, Owner = player, FishId = catch.fishId, Mult = catch.mult,
        Carrier = carrier, State = Mgr.State.AwaitLift, Anchor = position, LiftAttempts = 0,
        Threat = {}, HolderTree = holder_tree }
    self.Fish[fish.Id] = fish
    if carrier.Receiver and carrier.Receiver.Controller then
        pcall(function() carrier.Receiver.Controller.LiftedEnabled = false end)
    end
    self:Isolate(fish)
    self:SpawnTree(fish)
    local body = carrier.Body
    if body and body.OnLiftedBegin then
        local beginConn = body.OnLiftedBegin:Connect(function(liftunit) self:OnLifted(fish, liftunit) end)
        fish.Conns = { beginConn }
        if body.OnLiftedEnd then
            fish.Conns[#fish.Conns + 1] = body.OnLiftedEnd:Connect(function() self:Release(fish, 'liftEnd') end)
        end
    end
    self:RequestLift(fish)
    if type(self.OnStateChanged) == 'function' then self.OnStateChanged(fish) end
    return fish
end

function Mgr:SpawnBlastFish(fishId, mult, position, owner)
    local species = GameCfg.Fish[fishId]
    if not species or type(mult) ~= 'number' or not position then return nil, 'bad-fish' end
    local carrier, err = MgrFishCarrier:Spawn({
        CreateUnit = self.CreateUnit,
        Position = position,
        FishId = fishId,
        MaxHealth = species.Health,
        ModelId = species.Model,
        Player = owner,
        GravityEnabled = false,
        LinearDamping = cfg().LinearDamping,
        AngularDamping = cfg().AngularDamping,
    })
    if not carrier then return nil, err end
    self.NextId = self.NextId + 1
    local ttl = (GameCfg.Ability.Throw and GameCfg.Ability.Throw.FishTtlSec) or 60
    local fish = { Id = self.NextId, Owner = owner, FishId = fishId, Mult = mult,
        Carrier = carrier, State = Mgr.State.Wild, Anchor = position,
        WildUntil = self:Now() + ttl, Threat = {} }
    self.Fish[fish.Id] = fish
    if carrier.Receiver and carrier.Receiver.Controller then
        pcall(function() carrier.Receiver.Controller.LiftedEnabled = false end)
    end
    self:Isolate(fish)
    self:SpawnTree(fish)
    if type(self.OnStateChanged) == 'function' then self.OnStateChanged(fish) end
    return fish
end

function Mgr:RequestLift(fish)
    local owner = fish.Owner
    if fish.State ~= Mgr.State.AwaitLift or self.Held[owner.UserId]
        or fish.LiftAttempts >= cfg().LiftAttempts then return false end
    local controller = owner.Character and owner.Character.Controller
    if not controller then return false end
    fish.LiftAttempts = fish.LiftAttempts + 1
    fish.LiftAt = self:Now()
    -- SE 实测 Lift 的指定目标支持 WorldUnit；仍由原生 OnLiftedBegin 确认成功。
    local ok, err = pcall(function() controller:Lift(fish.Carrier.Body) end)
    if not ok then print('[FishTree] Lift 调用失败', owner.UserId, tostring(err)) end
    return ok
end

function Mgr:ResolveLifter(fish, liftunit)
    if liftunit == nil then return fish.LiftAt and fish.Owner or nil end
    if fish.Owner.Character == liftunit then return fish.Owner end
    for _, player in ipairs(self:Players()) do
        if player.Character == liftunit then return player end
    end
end

function Mgr:OnLifted(fish, liftunit)
    if self.Fish[fish.Id] ~= fish or fish.State ~= Mgr.State.AwaitLift then return end
    local holder = self:ResolveLifter(fish, liftunit)
    local character = holder and holder.Character
    if not character or self.Held[holder.UserId] then
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
    fish.Mount = mount
    fish.Holder = holder
    self:SetState(fish, Mgr.State.Held)
    fish.HolderTree = self.GetPlayerTree and self:GetPlayerTree(holder) or nil
    if fish.HolderTreeState then fish.HolderTreeState:set(fish.HolderTree) end
    self.Held[holder.UserId] = fish
    pcall(function() fish.Carrier.Body.Parent = mount end)
    print('[FishTree] 举起', holder.UserId, fish.FishId, fish.Mult, 'fish=' .. tostring(fish.Id))
    if self.Cast then self.Cast:PushState(holder) end
end

function Mgr:GetHeld(player)
    return player and self.Held[player.UserId] or nil
end

function Mgr:HeldInfo(player)
    local fish = self:GetHeld(player)
    return fish and { fishId = fish.FishId, mult = fish.Mult } or nil
end

function Mgr:CanCast(player)
    return self:GetHeld(player) == nil
end

function Mgr:Drop(player)
    local fish = self:GetHeld(player)
    return fish ~= nil and self:Release(fish, 'drop')
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
    return MathWaterJudge.Toward(waters, pos)
end

-- 入水只看 (x,z)：岸上鱼的 y 高于水面（V4 实测 2.15 > SurfaceY），按 y 判会永远判不进
local function inWater(pos)
    for _, zone in ipairs(GameCfg.Water.Zones) do
        if MathWaterJudge.InZone(zone, { x = pos.x, y = zone.SurfaceY, z = pos.z }) then return zone end
    end
end

function Mgr:Speed(fish)
    local species = GameCfg.Fish[fish.FishId]
    local speed = species and species.Speed or cfg().EscapeSpeed
    if self.Ability and self.Ability.FishSpeedFactor then
        local ok, factor = pcall(self.Ability.FishSpeedFactor, self.Ability, fish)
        if ok and type(factor) == 'number' and factor >= 0 and factor <= 1 then speed = speed * factor end
    end
    return speed
end

function Mgr:SetHeading(fish, x, z)
    if not x then return end
    local speed = self:Speed(fish)
    fish.Heading = { x = x, z = z }
    if self.Ai then
        local started = self.Ai:MoveDirection(fish, Vector3.New(x, 0, z), speed)
        fish.AppliedSpeed = speed
        return started
    end
    local ok, err = pcall(function() fish.Carrier.Body.LinearVelocity = Vector3.New(x * speed, 0, z * speed) end)
    if not ok then
        print("[FishTree] 逃跑速度写入失败", fish.Id, tostring(err))
        return false, tostring(err)
    end
    fish.AppliedSpeed = speed
    return true
end

function Mgr:ReleaseAwaitLift(fish, reason)
    if self.Fish[fish.Id] ~= fish or fish.State ~= Mgr.State.AwaitLift then return false end
    local owner = fish.Owner
    local body = fish.Carrier and fish.Carrier.Body
    local pos = body and readPosition(body) or fish.Anchor
    local now = self:Now()
    local species = GameCfg.Fish[fish.FishId]
    if body then
        pcall(function()
            body.BodyType = 2
            body.AngularVelocity = Vector3.New(0, 0, 0)
        end)
    end
    self:SetState(fish, Mgr.State.Escaping)
    fish.EscapeAt = now
    fish.EscapeBy = owner
    fish.TurnAt = now + cfg().TurnSec
    fish.RayAt = now
    fish.FleeAt = now + (species and species.EscapeSec or 1)
    if reason == 'leave' then
        fish.Owner = nil
        fish.Holder = nil
    end
    if pos then
        self:SetHeading(fish, towardWater(pos))
    end
    self:EnforceEscapeCap(owner, fish)
    if self.Cast and owner then self.Cast:PushState(owner) end
    return true
end

function Mgr:Release(fish, reason)
    if self.Fish[fish.Id] ~= fish or fish.State ~= Mgr.State.Held then return false end
    if self.Ai then self.Ai:Custom(fish) end
    local holder = fish.Holder
    if holder and self.Held[holder.UserId] == fish then self.Held[holder.UserId] = nil end
    local body = fish.Carrier.Body
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
    if fish.Mount then pcall(function() fish.Mount:Destroy() end) end
    fish.Mount = nil
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
    local now = self:Now()
    self:SetState(fish, Mgr.State.Escaping)
    fish.EscapeAt = now
    fish.EscapeBy = holder
    fish.TurnAt = now + cfg().TurnSec
    fish.RayAt = now
    local pos = readPosition(body) or origin
    local species = GameCfg.Fish[fish.FishId]
    if species.Grade ~= 'normal' and species.Grade ~= 'rare' and self:FlightProfile(fish.FishId) then
        fish.FleeAt = now + (species.EscapeSec or 180)
        body.LinearVelocity = Vector3.New(0, 0, 0)
        if not self:StartFlight(fish, now) then
            print('[FishTree] 飞行档案或边界缺失，回落普通逃脱', fish.FishId, 'fish=' .. tostring(fish.Id))
            self:SetHeading(fish, towardWater(pos))
        end
    elseif self:BossPhaseEnabled(fish.FishId) then
        self:SetState(fish, Mgr.State.Combat)
        fish.FleeAt = now + (species.EscapeSec or 300)
        fish.CombatPosition = pos
        fish.CombatRotation = body.Rotation
        fish.Phase = BossPhase.New(GameCfg.Ability.BossPhase, now, pos)
        fish.PhaseAt = now
        fish.Yaw = 0
        body.LinearVelocity = Vector3.New(0, 0, 0)
    elseif species.Combat then
        self:SetState(fish, Mgr.State.Combat)
        fish.FleeAt = now + species.EscapeSec
        fish.CombatPosition = pos
        fish.CombatRotation = body.Rotation
        body.LinearVelocity = Vector3.New(0, 0, 0)
        if GameCfg.FishCombat and GameCfg.FishCombat[species.Combat] then
            fish.BiteAim = nil
            if species.Combat == 'shrimp' or species.Combat == 'dragon' then
                local params = GameCfg.FishCombat[species.Combat]
                fish.ActiveUntil = now + (params.ActiveSec or params.SpecialSec)
                fish.SpecialAt = now + (params.SpecialSec or 0)
                fish.Combo = 0
            elseif species.Combat == 'kingCrab' or species.Combat == 'crabBoss' then
                resetCrabRhythm(fish, now, GameCfg.FishCombat[species.Combat])
            elseif species.Combat == 'swordfish' or species.Combat == 'shark' then
                local params = GameCfg.FishCombat[species.Combat]
                fish.JumpAt = now + params.JumpIntervalSec
                fish.RollSlot = -1
            elseif species.Combat == 'walrus' then
                fish.ChargeAt = now + GameCfg.FishCombat[species.Combat].ChargeSec
            elseif species.Combat == 'orca' then
                local params = GameCfg.FishCombat[species.Combat]
                fish.JumpAt = now + params.JumpIntervalSec
                fish.RoarAt = now + params.RoarSec
                fish.TailAt = now + params.TailSec
                fish.ClawAt = -1
            end
        elseif self.Ability then
            self.Ability:EquipFish(fish)
        end
        self:PublishCombat(fish)
    elseif pos then
        self:SetHeading(fish, towardWater(pos))
    end
    if reason == 'leave' then
        fish.FleeAt = now + (species.EscapeSec or 1)
        fish.Owner = nil
        fish.Holder = nil
    end
    print('[FishTree] 放下', holder and holder.UserId, reason, fish.FishId, 'fish=' .. tostring(fish.Id))
    if reason == 'drop' and holder and self.Quest and not (pos and inWater(pos)) then
        self.NextFactId = (self.NextFactId or 0) + 1
        self.Quest:Notify('DropShore', holder, { itemId = fish.FishId,
            eventId = 'drop:' .. tostring(fish.Id) .. ':' .. tostring(self.NextFactId) })
    end
    self:EnforceEscapeCap(holder, fish)
    if self.Cast and holder then self.Cast:PushState(holder) end
    return true
end

function Mgr:Escaping()
    local list = {}
    for _, fish in pairs(self.Fish) do
        if fish.State == Mgr.State.Escaping then list[#list + 1] = fish end
    end
    table.sort(list, function(a, b)
        if a.EscapeAt ~= b.EscapeAt then return a.EscapeAt < b.EscapeAt end
        return a.Id < b.Id
    end)
    return list
end

local function trimOldest(self, list, extra, keep, why)
    for _, fish in ipairs(list) do
        if extra <= 0 then return end
        if fish ~= keep then
            print('[FishTree] 在逃超出' .. why .. '，清最旧', 'fish=' .. tostring(fish.Id))
            self:Remove(fish)
            extra = extra - 1
        end
    end
end

function Mgr:EnforceEscapeCap(trigger, keep)
    local c = cfg()
    if trigger then
        local own = {}
        for _, fish in ipairs(self:Escaping()) do
            if fish.EscapeBy == trigger then own[#own + 1] = fish end
        end
        trimOldest(self, own, #own - c.PerPlayerEscapeCap, keep, '每人上限')
    end
    local list = self:Escaping()
    trimOldest(self, list, #list - #self:Players() * c.GlobalEscapePerPlayer, keep, '全局上限')
end

function Mgr:RayExclusions()
    local list = {}
    for _, player in ipairs(self:Players()) do
        if player.Character then list[#list + 1] = player.Character end
    end
    for _, fish in pairs(self.Fish) do
        if fish.Carrier then
            list[#list + 1] = fish.Carrier.Body
            if fish.Carrier.Receiver then list[#list + 1] = fish.Carrier.Receiver end
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

function Mgr:WallAhead(fish, pos)
    local heading = fish.Heading
    if not heading or not RaycastParams then return false end
    local physics = service('PhysicsService')
    if not physics then return false end
    local distance = cfg().RayDistance
    local params = RaycastParams.New()
    local excluded = self:RayExclusions()
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

function Mgr:UpdateEscaping(fish, now)
    if fish.FleeAt and now >= fish.FleeAt and not fish.StraightEscape then
        self:Remove(fish)
        return
    end
    local pos = readPosition(fish.Carrier.Body)
    if not pos then
        print('[FishTree] 在逃的鱼坐标异常，移除', 'fish=' .. tostring(fish.Id))
        self:Remove(fish)
        return
    end
    local zone = inWater(pos)
    if zone then
        print('[FishTree] 逃回水里', zone.Id, fish.FishId, 'fish=' .. tostring(fish.Id))
        self:Remove(fish)
        return
    end
    if fish.Heading and fish.AppliedSpeed ~= self:Speed(fish) then
        self:SetHeading(fish, fish.Heading.x, fish.Heading.z)
    end
    if fish.StraightEscape then return end
    if now >= fish.TurnAt then
        fish.TurnAt = now + cfg().TurnSec
        self:SetHeading(fish, towardWater(pos))
    end
    if now >= fish.RayAt then
        fish.RayAt = now + 1 / cfg().RayHz
        if self:WallAhead(fish, pos) then
            local h = fish.Heading
            self:SetHeading(fish, -h.z, h.x)
        end
    end
end

function Mgr:IsTargetValid(player, pos, params)
    if not player or not self.Vitals or not self.Vitals:CanTakeDamage(player) then return false end
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

function Mgr:NoteDamage(fish, player, amount)
    if not fish or self.Fish[fish.Id] ~= fish or not player
        or type(amount) ~= 'number' or amount <= 0 or amount ~= amount then return false end
    fish.Threat = fish.Threat or {}
    fish.Threat[player] = (fish.Threat[player] or 0) + amount
    return true
end

function Mgr:SetTargetOverride(fish, player)
    if not fish or self.Fish[fish.Id] ~= fish then return false end
    fish.TargetOverride = player
    return true
end

function Mgr:ChooseTarget(fish, pos, params)
    local adapter = self.AiTarget
    local override = fish.TargetOverride
    if override then
        local valid, cp = self:IsTargetValid(override, pos, params)
        if valid then
            adapter:SetFocus(fish, override)
            return override, cp
        end
        fish.TargetOverride = nil
    end
    local candidates, present = {}, {}
    for _, player in ipairs(self:Players()) do
        present[player] = true
        local valid, cp = self:IsTargetValid(player, pos, params)
        if valid then
            candidates[#candidates + 1] = { player = player, pos = cp,
                damage = fish.Threat and fish.Threat[player] or 0, distance = distanceSq(pos, cp) }
        end
    end
    if fish.Threat then
        for player in pairs(fish.Threat) do
            if not present[player] or not self:IsTargetValid(player, pos, params) then
                fish.Threat[player] = nil
            end
        end
    end
    local ranked = adapter:Select(fish, candidates)
    local top = ranked[1]
    return top and top.player or nil, top and top.pos or nil
end

function Mgr.InHeadZone(pos, facing, tpos, params)
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

function Mgr:PublishBite(payload)
    GarBiteNotice.Publish(payload)
end

local function publishBite(self, payload)
    local ok, err = pcall(self.PublishBite, self, payload)
    if not ok then print('[FishTree] 首领咬预警推送失败', payload.kind, 'fish=' .. tostring(payload.fishId), tostring(err)) end
end

function Mgr:Face(fish, fx, fz, params)
    if not fx then return end
    fish.Facing = { x = fx, z = fz }
    if not Quaternion then return end
    local yaw = math.atan(fx, fz) + ((params and params.ModelYawOffset) or 0)
    local ok, err = pcall(function() fish.Carrier.Body.Rotation = Quaternion.FromEulerAngles(0, yaw, 0) end)
    if not ok then print('[FishTree] 首领转向失败', 'fish=' .. tostring(fish.Id), tostring(err)) end
end

function Mgr:EndBite(fish, reason)
    if not fish.BiteAim then return end
    fish.BiteAim = nil
    publishBite(self, GarBiteNotice.Clear(fish.Id, reason))
end

function Mgr:LockBite(fish, target, pos, tpos, now, params)
    if self.Ai then self.Ai:Custom(fish) end
    local fx, fz = flatDirection(tpos.x - pos.x, tpos.z - pos.z)
    if fx then self:Face(fish, fx, fz, params) end
    fish.BiteAim = { Target = target, StrikeAt = now + params.BiteCooldownSec }
    local facing = fish.Facing or { x = 0, z = 1 }
    local species = GameCfg.Fish[fish.FishId]
    local warning = species and BossMoves.WarningOf(BossMoves.KeyOf(species, fish.FishId), 'bite') or nil
    local notice = GarBiteNotice.Lock(fish.Id, pos, facing.x, facing.z, params.BiteRange,
        params.HeadHalfAngleDeg, params.BiteCooldownSec)
    notice.move = 'bite'
    if warning then
        notice.shape, notice.duration = warning.Shape, warning.WindupSec
        if warning.Notice then notice.notice = warning.Notice end
    end
    publishBite(self, notice)
    print('[FishTree] 首领起咬', fish.FishId, 'target=' .. tostring(target.UserId),
        string.format('facing=%.2f,%.2f', facing.x, facing.z), 'fish=' .. tostring(fish.Id))
end

function Mgr:UpdateChase(fish, now, pos, params)
    local species = GameCfg.Fish[fish.FishId]
    local body = fish.Carrier.Body
    local aim = fish.BiteAim
    if aim then
        local valid, apos = self:IsTargetValid(aim.Target, pos, params)
        if not valid or not withinBite(pos, apos, params) then
            self:EndBite(fish, 'cancel')
        else
            pcall(function() body.LinearVelocity = Vector3.New(0, 0, 0) end)
            if now < aim.StrikeAt then return end
            if Mgr.InHeadZone(pos, fish.Facing, apos, params) then
                self:EndBite(fish, 'bite')
                local hit = self.Vitals:NewHit(fish, 'fishAttack')
                self.Vitals:ApplyHit(hit, aim.Target, species.Attack)
                print('[FishTree] 首领追咬', fish.FishId, species.Attack, 'fish=' .. tostring(fish.Id))
            else
                self:EndBite(fish, 'miss')
                print('[FishTree] 首领咬空（绕后）', fish.FishId, 'target=' .. tostring(aim.Target.UserId),
                    'fish=' .. tostring(fish.Id))
            end
        end
    end
    local target, tpos = self:ChooseTarget(fish, pos, params)
    if not target then
        if self.Ai then self.Ai:Custom(fish) end
        pcall(function() body.LinearVelocity = Vector3.New(0, 0, 0) end)
        return
    end
    if not withinBite(pos, tpos, params) then
        local ux, uz = flatDirection(tpos.x - pos.x, tpos.z - pos.z)
        local speed = self:Speed(fish)
        self:Face(fish, ux, uz, params)
        if self.Ai then
            self.Ai:Chase(fish, target.Character, speed, params.BiteRange, params.AggroRange)
            return
        end
        pcall(function() body.LinearVelocity = Vector3.New((ux or 0) * speed, 0, (uz or 0) * speed) end)
        return
    end
    pcall(function() body.LinearVelocity = Vector3.New(0, 0, 0) end)
    self:LockBite(fish, target, pos, tpos, now, params)
end

function Mgr:EndMove(fish, reason)
    if not fish.Move then return end
    fish.Move, fish.MoveName = nil, nil
    publishBite(self, GarBiteNotice.Clear(fish.Id, reason))
    self:PublishCombat(fish)
end

function Mgr:StartMove(fish, name, pos, target, tpos, now, duration, range, shape)
    if self.Ai and not self.Ai:Custom(fish) then return false end
    fish.OfficialRollFrom, fish.RollFrom = nil, nil
    self:EndMove(fish, 'replace')
    local fx, fz
    if tpos then fx, fz = flatDirection(tpos.x - pos.x, tpos.z - pos.z) end
    self:Face(fish, fx, fz)
    fish.Move = { Name = name, Target = target, At = now, StrikeAt = now + duration,
        Center = { x = pos.x, y = pos.y, z = pos.z },
        Destination = tpos and { x = tpos.x, y = pos.y, z = tpos.z } }
    local facing = fish.Facing or { x = 0, z = 1 }
    local warningPos = (name == 'dive' or name == 'jump') and fish.Move.Destination or pos
    warningPos = warningPos or pos
    local species = GameCfg.Fish[fish.FishId]
    local warning = species and BossMoves.WarningOf(BossMoves.KeyOf(species, fish.FishId), name) or nil
    local warningRange = warning and math.max(range or 0, warning.Range or 0) or range
    local warningSec = warning and warning.WindupSec and warning.WindupSec > 0 and warning.WindupSec or duration
    local payload = GarBiteNotice.Lock(fish.Id, warningPos, facing.x, facing.z, warningRange, 90, warningSec)
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
    local row = BossMoves.Get(BossMoves.KeyOf(GameCfg.Fish[fish.FishId], fish.FishId), name)
    if row and row.Delivery and row.Warning.Kind ~= 'none' then
        payload.shape = row.Warning.Kind or payload.shape
        payload.notice, payload.delivery, payload.landing = row.Warning.Notice, row.Delivery, row.Landing
        payload.width = row.Warning.Width
        payload.landingPoint = fish.Move.Destination or fish.Move.Center
    end
    publishBite(self, payload)
    fish.MoveName = name
    self:PublishCombat(fish)
    print('[FishTree] 招式预警', fish.FishId, name, 'fish=' .. tostring(fish.Id))
    return true
end

function Mgr:StunFish(fish, now, params)
    if self.Ai then self.Ai:Custom(fish) end
    self:EndMove(fish, 'stun')
    fish.State, fish.WakeAt, fish.MoveName = 'stunned', now + params.StunSec, nil
    fish.Carrier.Body.LinearVelocity = Vector3.New(0, 0, 0)
    self:PublishCombat(fish)
    print('[FishTree] 眩晕', fish.FishId, 'wakeAt=' .. tostring(fish.WakeAt))
end

function Mgr:UpdateShrimpCombat(fish, now, pos, params, combat)
    local body = fish.Carrier.Body
    local dt = math.max(0, now - (fish.CombatStepAt or now))
    fish.CombatStepAt = now
    if fish.State == 'stunned' or fish.State == Mgr.State.Sleeping then
        body.LinearVelocity = Vector3.New(0, 0, 0)
        if now < (fish.WakeAt or math.huge) then return end
        fish.State, fish.WakeAt = Mgr.State.Combat, nil
        fish.ActiveUntil, fish.Combo = now + (params.ActiveSec or params.SpecialSec), 0
        dt = 0
        self:PublishCombat(fish)
    end
    if combat == 'shrimp' and now >= fish.ActiveUntil then
        self:StunFish(fish, now, params)
        return
    end
    local move = fish.Move
    if combat == 'dragon' and now >= fish.SpecialAt and (not move or move.Name == 'peck') then
        fish.SpecialAt = now + params.SpecialSec
        if not self:StartMove(fish, 'rain', pos, nil, nil, now, params.RainSec, params.RainRadius) then return end
        fish.Move.LastTick = 0
        move = fish.Move
    end
    if move then
        dt = 0
        body.LinearVelocity = Vector3.New(0, 0, 0)
        if move.Name == 'rain' then
            local tick = math.min(params.RainSec, math.floor(now - move.At))
            if tick > move.LastTick then
                move.LastTick = tick
                for _, player in ipairs(self:Players()) do
                    local valid, cp = self:IsTargetValid(player, move.Center)
                    if valid and (cp.x - move.Center.x)^2 + (cp.z - move.Center.z)^2 <= params.RainRadius^2 then
                        self:Hit(fish, player, params.RainDamage, 'rain')
                    end
                end
            end
            if now < move.StrikeAt then return end
            self:EndMove(fish, 'rain-end')
            local target, tp = self:ChooseTarget(fish, pos, params)
            self:StartMove(fish, 'dive', pos, target, tp, now, params.DiveSec, params.DiveRadius)
            return
        elseif move.Name == 'dive' then
            local progress = math.min(1, math.max(0, (now - move.At) / params.DiveSec))
            local dest = move.Destination or move.Center
            body.Position = Vector3.New(move.Center.x + (dest.x - move.Center.x) * progress,
                move.Center.y + math.sin(progress * math.pi) * params.DiveHeight,
                move.Center.z + (dest.z - move.Center.z) * progress)
            if now < move.StrikeAt then return end
            self:EndMove(fish, 'dive-end')
            for _, player in ipairs(self:Players()) do
                local valid, cp = self:IsTargetValid(player, dest)
                if valid and (cp.x - dest.x)^2 + (cp.z - dest.z)^2 <= params.DiveRadius^2 then
                    self:Hit(fish, player, params.DiveDamage, 'dive')
                end
            end
            self:StunFish(fish, now, params)
            return
        end
        local valid, cp = self:IsTargetValid(move.Target, pos, params)
        if not valid or not withinBite(pos, cp, params) then
            self:EndMove(fish, 'cancel')
        elseif now < move.StrikeAt then return
        else
            self:EndMove(fish, 'strike')
            if Mgr.InHeadZone(pos, fish.Facing, cp, params) then
                local damage = move.Name == 'tail' and params.TailDamage
                    or (move.Name == 'peck' and params.PeckDamage or params.ClawDamage)
                local applied = self:Hit(fish, move.Target, damage, move.Name)
                if applied and move.Name == 'tail' then
                    local f = fish.Facing or { x = 0, z = 1 }
                    local ok, err = pcall(function()
                        move.Target.Character.Position = Vector3.New(cp.x + f.x * params.KnockHorizontal,
                            cp.y + params.KnockUp, cp.z + f.z * params.KnockHorizontal)
                    end)
                    if not ok then print('[FishTree] 尾刺击飞失败', fish.Id, tostring(err)) end
                end
            end
            fish.Combo = ((fish.Combo or 0) + 1) % 3
        end
    end
    local target, tp = self:ChooseTarget(fish, pos, params)
    if not target then
        if self.Ai then self.Ai:Custom(fish) end
        body.LinearVelocity = Vector3.New(0, 0, 0)
        return
    end
    if not withinBite(pos, tp, params) then
        local fx, fz = flatDirection(tp.x - pos.x, tp.z - pos.z)
        self:Face(fish, fx, fz, params)
        if self.Ai then
            self.Ai:Chase(fish, target.Character, self:Speed(fish), params.BiteRange, params.AggroRange)
            return
        end
        local distance = math.sqrt((tp.x - pos.x)^2 + (tp.z - pos.z)^2)
        local step = math.min(self:Speed(fish) * dt, math.max(0, distance - params.BiteRange))
        body.LinearVelocity = Vector3.New(0, 0, 0)
        local moved, err = pcall(function()
            body.Position = Vector3.New(pos.x + (fx or 0) * step, pos.y, pos.z + (fz or 0) * step)
        end)
        if not moved then print('[FishTree] 虾池追击位移失败', fish.Id, tostring(err)) end
        return
    end
    body.LinearVelocity = Vector3.New(0, 0, 0)
    local name = combat == 'dragon' and 'peck' or ((fish.Combo or 0) == 2 and 'tail' or 'claw')
    self:StartMove(fish, name, pos, target, tp, now, params.BiteCooldownSec, params.BiteRange)
end

local function beginCombatFrame(fish, now)
    fish.Carrier.Body.LinearVelocity = Vector3.New(0, 0, 0)
    local dt = math.max(0, now - (fish.CombatStepAt or now))
    fish.CombatStepAt = now
    return dt
end

local function chaseStep(self, fish, pos, tpos, dt, params, label, skipIdle, plainId)
    if self.Ai then
        local target = self:ChooseTarget(fish, pos, params)
        if not target then self.Ai:Custom(fish); return false end
        self:Face(fish, flatDirection(tpos.x - pos.x, tpos.z - pos.z))
        local previous = fish.OfficialRollFrom
        fish.OfficialRollFrom = { x = pos.x, y = pos.y, z = pos.z }
        fish.RollFrom = previous
        self.Ai:Chase(fish, target.Character, self:Speed(fish), params.BiteRange, params.AggroRange)
        return previous ~= nil and (previous.x ~= pos.x or previous.z ~= pos.z)
    end
    local body = fish.Carrier.Body
    local fx, fz = flatDirection(tpos.x - pos.x, tpos.z - pos.z)
    self:Face(fish, fx, fz, params)
    local distance = math.sqrt((tpos.x - pos.x)^2 + (tpos.z - pos.z)^2)
    local step = math.min(self:Speed(fish) * dt, math.max(0, distance - params.BiteRange))
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
    local valid, tp = self:IsTargetValid(move.Target, pos, params)
    if not valid or not withinBite(pos, tp, params) then
        self:EndMove(fish, 'cancel')
        return false
    end
    if now < move.StrikeAt - 1e-9 then return true end
    self:EndMove(fish, move.Name)
    if Mgr.InHeadZone(pos, fish.Facing, tp, params) then
        self:Hit(fish, move.Target, damage, move.Name)
    end
    return true
end

local function engageOrChase(self, fish, now, pos, params, dt, name, windup, label, skipIdle)
    local target, tpos = self:ChooseTarget(fish, pos, params)
    if not target then
        if self.Ai then self.Ai:Custom(fish) end
        return false
    end
    if withinBite(pos, tpos, params) then
        self:StartMove(fish, name, pos, target, tpos, now, windup, params.BiteRange)
        return false
    end
    return chaseStep(self, fish, pos, tpos, dt, params, label, skipIdle)
end

local function bossWindup(fish, move)
    local row = BossMoves.Get(BossMoves.KeyOf(GameCfg.Fish[fish.FishId], fish.FishId), move) or {}
    local warning = row.Warning
    local windup = type(warning) == 'table' and warning.WindupSec or nil
    return type(windup) == 'number' and windup or 0
end

function Mgr:UpdateKingCrabCombat(fish, now, pos, params)
    local dt = beginCombatFrame(fish, now)
    local move = fish.Move
    if move then
        if move.Name ~= 'jab' then return end
        local elapsed = now - move.At
        local windup = bossWindup(fish, 'jab')
        local slot = elapsed <= windup and -1 or math.min(params.JabsPerSide * 2 - 1,
            math.floor((elapsed - windup) / params.JabStepSec + 1e-9) - 1)
        if slot > (move.LastSlot or -1) then
            move.LastSlot = slot
            local target, tp = self:IsTargetValid(move.Target, pos, params)
            if target and withinBite(pos, tp, params)
                and Mgr.InHeadZone(pos, fish.Facing, tp, params) then
                self:Hit(fish, move.Target, params.JabDamage, 'jab')
            end
        end
        if now < move.StrikeAt - 1e-9 then return end
        self:EndMove(fish, 'jab-end')
        return
    end
    local target, tp = self:ChooseTarget(fish, pos, params)
    if not target then
        if self.Ai then self.Ai:Custom(fish) end
        return
    end
    if now < (fish.JabAt or 0) then return end
    if not withinBite(pos, tp, params) then
        chaseStep(self, fish, pos, tp, dt, params, '帝王蟹', nil, true)
        return
    end
    fish.JabAt = now + params.JabIntervalSec
    self:StartMove(fish, 'jab', pos, target, tp, now,
        bossWindup(fish, 'jab') + params.JabStepSec * params.JabsPerSide * 2, params.BiteRange)
end

function Mgr:UpdateCrabBossCombat(fish, now, pos, params)
    local dt = beginCombatFrame(fish, now)
    local move = fish.Move
    if move then
        if move.Name == 'pinch' then
            local elapsed = now - move.At
            local windup = bossWindup(fish, 'pinch')
            local strike = elapsed <= windup and 0 or math.min(params.PinchStrikes,
                math.floor((elapsed - windup) / params.PinchStepSec + 1e-9))
            if strike > (move.LastStrike or 0) and strike >= 1 then
                move.LastStrike = strike
                local target, tp = self:IsTargetValid(move.Target, pos, params)
                if target and withinBite(pos, tp, params)
                    and Mgr.InHeadZone(pos, fish.Facing, tp, params) then
                    self:Hit(fish, move.Target, params.PinchDamage, 'pinch')
                end
            end
            if now < move.StrikeAt - 1e-9 then return end
            self:EndMove(fish, 'pinch-end')
            return
        elseif move.Name == 'charge' then
            if not move.HitDone and now >= move.At + bossWindup(fish, 'charge') then
                local target, tp = self:ChooseTarget(fish, pos, params)
                if target and tp and (tp.x - pos.x)^2 + (tp.z - pos.z)^2 <= params.ChargeRange^2 then
                    move.HitDone = true
                    self:Hit(fish, target, params.ChargeDamage, 'charge')
                end
            end
            if now < move.StrikeAt - 1e-9 then return end
            self:EndMove(fish, 'charge-end')
            return
        elseif move.Name == 'spin' then
            local tick = math.min(params.SpinDurationSec,
                math.max(0, math.floor(now - move.At)))
            if tick > (move.LastTick or 0) then
                move.LastTick = tick
                for _, player in ipairs(self:Players()) do
                    local valid, cp = self:IsTargetValid(player, move.Center)
                    if valid and (cp.x - pos.x)^2 + (cp.z - pos.z)^2 <= params.SpinRadius^2 then
                        self:Hit(fish, player, params.SpinDamage, 'spin')
                    end
                end
            end
            if now < move.StrikeAt - 1e-9 then return end
            self:EndMove(fish, 'spin-end')
            return
        end
        return
    end
    local target, tp = self:ChooseTarget(fish, pos, params)
    if not target then
        if self.Ai then self.Ai:Custom(fish) end
        return
    end
    if now >= (fish.SpecialAt or math.huge) then
        fish.SpecialAt = now + params.SpinSec
        self:StartMove(fish, 'spin', pos, target, tp, now, params.SpinDurationSec, params.SpinRadius)
        return
    end
    if now >= (fish.ChargeAt or math.huge) then
        fish.ChargeAt = now + params.ChargeSec
        self:StartMove(fish, 'charge', pos, target, tp, now, params.ChargeWindowSec, params.ChargeRange)
        return
    end
    if now >= (fish.PinchAt or 0) and withinBite(pos, tp, params) then
        fish.PinchAt = now + params.PinchCooldownSec
        self:StartMove(fish, 'pinch', pos, target, tp, now,
            bossWindup(fish, 'pinch') + params.PinchStepSec * params.PinchStrikes, params.BiteRange)
        return
    end
    if not withinBite(pos, tp, params) then
        chaseStep(self, fish, pos, tp, dt, params, '蟹老板', nil, true)
    end
end
function Mgr:StartJump(fish, now, pos, params)
    fish.JumpAt = now + params.JumpIntervalSec
    local rng = math.random
    local angle = (rng and rng() or 0.5) * math.pi * 2
    local dest = { x = pos.x + math.cos(angle) * params.JumpDistance, y = pos.y,
        z = pos.z + math.sin(angle) * params.JumpDistance }
    self:StartMove(fish, 'jump', pos, nil, dest, now, params.JumpSec, params.JumpRadius)
end

function Mgr:AdvanceJump(fish, now, pos, params)
    local body = fish.Carrier.Body
    local move = fish.Move
    local dest = move.Destination or move.Center
    local progress = math.min(1, math.max(0, (now - move.At) / params.JumpSec))
    local ok, err = pcall(function()
        body.Position = Vector3.New(
            move.Center.x + (dest.x - move.Center.x) * progress,
            move.Center.y + math.sin(progress * math.pi) * params.JumpHeight,
            move.Center.z + (dest.z - move.Center.z) * progress)
    end)
    if not ok then
        print('[FishTree] 高跃位移失败', 'fish=' .. tostring(fish.Id), tostring(err))
        self:EndMove(fish, 'cancel')
        return
    end
    if now < move.StrikeAt - 1e-9 then return end
    self:EndMove(fish, 'jump-end')
    for _, player in ipairs(self:Players()) do
        local valid, cp = self:IsTargetValid(player, dest, params)
        if valid and (cp.x - dest.x)^2 + (cp.z - dest.z)^2 <= params.JumpRadius * params.JumpRadius then
            self:Hit(fish, player, params.JumpDamage, 'jump')
        end
    end
end

function Mgr:UpdateSwordfishCombat(fish, now, pos, params)
    local dt = beginCombatFrame(fish, now)
    local move = fish.Move
    if move then
        if move.Name == 'jump' then
            self:AdvanceJump(fish, now, pos, params)
            return
        end
        if advanceHeadMove(self, fish, move, now, pos, params, params.SwingDamage) then return end
    end
    if now >= (fish.JumpAt or math.huge) then
        self:StartJump(fish, now, pos, params)
        return
    end
    engageOrChase(self, fish, now, pos, params, dt, 'swing', params.SwingCooldownSec, '剑鱼')
end

function Mgr:UpdateSharkCombat(fish, now, pos, params)
    local dt = beginCombatFrame(fish, now)
    local move = fish.Move
    if move then
        if move.Name == 'jump' then
            self:AdvanceJump(fish, now, pos, params)
            return
        end
        if advanceHeadMove(self, fish, move, now, pos, params, params.SweepDamage) then return end
    end
    if now >= (fish.JumpAt or math.huge) then
        self:StartJump(fish, now, pos, params)
        return
    end
    if not engageOrChase(self, fish, now, pos, params, dt, 'sweep', params.SweepCooldownSec, '三头鲨', true) then
        return
    end
    local actual = readPosition(fish.Carrier.Body)
    pos = (self.Ai and fish.RollFrom) or pos
    if not actual or not pos or (actual.x == pos.x and actual.z == pos.z) then return end
    local slot = math.floor(now)
    if fish.RollSlot ~= slot then fish.RollSlot, fish.RollHits = slot, {} end
    for _, player in ipairs(self:Players()) do
        local valid, cp = self:IsTargetValid(player, actual, params)
        if valid and not fish.RollHits[player]
            and segmentDistanceSq(cp.x, cp.z, pos.x, pos.z, actual.x, actual.z) <= params.BiteRange^2 then
            fish.RollHits[player] = true
            self:Hit(fish, player, params.RollDamage, 'roll')
        end
    end
end

function Mgr:AdvanceWalrusCharge(fish, now, pos, params)
    local body = fish.Carrier.Body
    local move = fish.Move
    if now < move.WindupAt - 1e-9 then
        local valid = self:IsTargetValid(move.Target, pos, params)
        if not valid then self:EndMove(fish, 'cancel') end
        return
    end
    if not move.DashFrom then
        move.DashFrom = { x = pos.x, y = pos.y, z = pos.z }
    end
    local facing = fish.Facing or { x = 0, z = 1 }
    local progress = math.min(params.ChargeDistance, (now - move.WindupAt) * params.ChargeSpeed)
    local moved, err = pcall(function()
        body.Position = Vector3.New(
            move.DashFrom.x + facing.x * progress, pos.y,
            move.DashFrom.z + facing.z * progress)
    end)
    if not moved then
        print('[FishTree] 海象突击位移失败', 'fish=' .. tostring(fish.Id), tostring(err))
        self:EndMove(fish, 'cancel')
        return
    end
    local actual = readPosition(body)
    if actual then
        for _, player in ipairs(self:Players()) do
            if not move.Hits[player] then
                local valid, cp = self:IsTargetValid(player, actual, params)
                if valid and segmentDistanceSq(cp.x, cp.z,
                        move.DashFrom.x, move.DashFrom.z, actual.x, actual.z)
                    <= params.ChargeContactRange * params.ChargeContactRange then
                    move.Hits[player] = true
                    self:Hit(fish, player, params.ChargeDamage, 'charge')
                end
            end
        end
    end
    if now >= move.StrikeAt - 1e-9 then
        self:EndMove(fish, 'charge-end')
    end
end

function Mgr:UpdateWalrusCombat(fish, now, pos, params)
    local dt = beginCombatFrame(fish, now)
    local move = fish.Move
    if move then
        if move.Name == 'swing' then
            if advanceHeadMove(self, fish, move, now, pos, params, params.SwingDamage) then return end
        elseif move.Name == 'charge' then
            self:AdvanceWalrusCharge(fish, now, pos, params)
            return
        else
            return
        end
    end
    if now >= (fish.ChargeAt or math.huge) then
        local target, tp = self:ChooseTarget(fish, pos, params)
        if not target then
        if self.Ai then self.Ai:Custom(fish) end
        return
    end
        fish.ChargeAt = now + params.ChargeSec
        if not self:StartMove(fish, 'charge', pos, target, tp, now,
            params.ChargeWindupSec + params.ChargeDistance / params.ChargeSpeed,
            params.ChargeDistance) then return end
        fish.Move.WindupAt = now + params.ChargeWindupSec
        fish.Move.Hits = {}
        return
    end
    engageOrChase(self, fish, now, pos, params, dt, 'swing', params.SwingCooldownSec, '海象')
end

function Mgr:UpdateOrcaCombat(fish, now, pos, params)
    local dt = beginCombatFrame(fish, now)
    local move = fish.Move
    if move then
        if move.Name == 'jump' then
            self:AdvanceJump(fish, now, pos, params)
            return
        end
        if now < move.StrikeAt - 1e-9 then
            local valid = self:IsTargetValid(move.Target, pos, params)
            if not valid then self:EndMove(fish, 'cancel') end
            return
        end
        if move.Name == 'claw' then
            self:EndMove(fish, 'claw')
            local valid, tp = self:IsTargetValid(move.Target, pos, params)
            if valid and withinBite(pos, tp, params)
                and Mgr.InHeadZone(pos, fish.Facing, tp, params) then
                self:Hit(fish, move.Target, params.ClawDamage, 'claw')
            end
            return
        end
        if move.Name == 'roar' then
            self:EndMove(fish, 'roar')
            local valid, tp = self:IsTargetValid(move.Target, pos, params)
            if valid and (tp.x - pos.x)^2 + (tp.z - pos.z)^2 <= params.RoarRange * params.RoarRange then
                self:Hit(fish, move.Target, params.RoarDamage, 'roar')
            end
            return
        end
        if move.Name == 'tail' then
            self:EndMove(fish, 'tail')
            local facing = fish.Facing or { x = 0, z = 1 }
            for _, player in ipairs(self:Players()) do
                local valid, cp = self:IsTargetValid(player, pos, params)
                if valid and (cp.x - pos.x)^2 + (cp.z - pos.z)^2 <= params.TailRadius * params.TailRadius then
                    local dx, dz = cp.x - pos.x, cp.z - pos.z
                    if dx * facing.x + dz * facing.z < 0 then
                        self:Hit(fish, player, params.TailDamage, 'tail')
                    end
                end
            end
            return
        end
        return
    end
    if now >= (fish.JumpAt or math.huge) then
        self:StartJump(fish, now, pos, params)
        return
    end
    local target, tp = self:ChooseTarget(fish, pos, params)
    if not target then
        if self.Ai then self.Ai:Custom(fish) end
        return
    end
    if now >= (fish.RoarAt or math.huge) then
        fish.RoarAt = now + params.RoarSec
        self:StartMove(fish, 'roar', pos, target, tp, now, params.RoarWindupSec, params.RoarRange, 'circle')
        return
    end
    if now >= (fish.TailAt or math.huge) then
        fish.TailAt = now + params.TailSec
        self:StartMove(fish, 'tail', pos, target, tp, now, params.TailWindupSec, params.TailRadius, 'circle')
        return
    end
    if now >= (fish.ClawAt or 0) and withinBite(pos, tp, params) then
        fish.ClawAt = now + params.ClawCooldownSec
        self:StartMove(fish, 'claw', pos, target, tp, now, params.ClawWindupSec, params.BiteRange)
        return
    end
    if not withinBite(pos, tp, params) then
        chaseStep(self, fish, pos, tp, dt, params, '虎鲸')
    end
end

function Mgr:UpdateCombat(fish, now)
    local body = fish.Carrier.Body
    local pos = readPosition(body)
    if not pos then
        print('[FishTree] 战斗鱼坐标异常，移除', fish.Id)
        self:Remove(fish)
        return
    end
    local moveName = fish.Move and fish.Move.Name
    local diving = moveName == 'dive'
    local jumping = moveName == 'jump'
    local airborne = (diving or jumping) and pos.y > fish.Move.Center.y + 0.1
    if now >= fish.FleeAt or (not airborne and inWater(pos) and not (fish.Phase and fish.Phase.Phase == 'water')) then
        if diving or jumping then
            local ground = fish.Move.Center.y
            local ok, err = pcall(function() body.Position = Vector3.New(pos.x, ground, pos.z) end)
            if not ok then print('[FishTree] 腾空逃脱落地失败', fish.Id, tostring(err)) end
            pos = readPosition(body) or pos
        end
        if self.Ability then self.Ability:RemoveFish(fish) end
        self:EndBite(fish, 'gone')
        self:EndMove(fish, 'gone')
        self:EndBossAttack(fish, 'timeout')
        self:ReleaseCarried(fish, nil, 'timeout')
        fish.Aquatic = nil
        fish.WakeAt, fish.MoveName = nil, nil
        self:SetState(fish, Mgr.State.Escaping)
        fish.StraightEscape = true
        if fish.CombatRotation then body.Rotation = fish.CombatRotation end
        self:SetHeading(fish, towardWater(pos))
        print('[FishTree] 精英开始逃脱', fish.FishId, 'fish=' .. tostring(fish.Id))
        self:PublishCombat(fish)
        self:UpdateEscaping(fish, now)
        return
    end
    self:RefreshMovingCombat(fish, now)
    if self.Ability and self.Ability.FishParalyzed then
        local ok, paralyzed = pcall(self.Ability.FishParalyzed, self.Ability, fish)
        if ok and paralyzed then
            pcall(function() body.LinearVelocity = Vector3.New(0, 0, 0) end)
            return
        end
    end
    local combat = GameCfg.Fish[fish.FishId].Combat
    if fish.State == 'stunned' and combat == 'kingCrab' then
        body.LinearVelocity = Vector3.New(0, 0, 0)
        if now < (fish.WakeAt or math.huge) then return end
        fish.State, fish.WakeAt = Mgr.State.Combat, nil
        local params = GameCfg.FishCombat and GameCfg.FishCombat[combat]
        if params then resetCrabRhythm(fish, now, params) end
        self:PublishCombat(fish)
    end
    if self:BossPhaseEnabled(fish.FishId) then
        self:UpdateBossPhase(fish, now, pos)
        return
    end
    local chase = GameCfg.FishCombat and GameCfg.FishCombat[combat]
    if chase then
        local key = BossMoves.KeyOf(GameCfg.Fish[fish.FishId], fish.FishId)
        FishBehaviors.Step(self, fish, now, pos, BossMoves.CombatParams(chase, key), combat)
        return
    end
    self:UpdateEel(fish, now, GameCfg.Ability.FishAbilities[combat])
end

function Mgr:CombatPayload(fish, gone)
    if gone then return { id = fish.Id, state = 'gone' } end
    local entry = GameCfg.Ability.FishAbilities[GameCfg.Fish[fish.FishId].Combat]
    local pos = readPosition(fish.Carrier.Body) or fish.CombatPosition or fish.Anchor
    return { id = fish.Id, fishId = fish.FishId, state = fish.State,
        phase = fish.Phase and fish.Phase.Phase,
        fleeAt = fish.FleeAt, escapeSec = GameCfg.Fish[fish.FishId].EscapeSec,
        wakeAt = fish.WakeAt, move = fish.MoveName, discharges = fish.Discharges or 0, dischargeCount = entry and entry.DischargeCount,
        position = pos and { x = pos.x, y = pos.y, z = pos.z } }
end

function Mgr:RefreshMovingCombat(fish, now)
    if GameCfg.Ability.FishAbilities[GameCfg.Fish[fish.FishId].Combat] then return end
    if now < (fish.CombatRefreshAt or 0) then return end
    fish.CombatRefreshAt = now + GameCfg.FishCombatLabel.MovingRefreshSec
    self:PublishCombat(fish)
end

function Mgr:PublishCombat(fish, gone)
    local species = GameCfg.Fish[fish.FishId]
    if not (species and species.Combat) then return end
    if gone and not fish.CombatPublished then return end
    fish.CombatPublished = not gone and fish.State ~= Mgr.State.Escaping
    local publish = self.CombatPublisher
    if not publish and self.CombatRE then
        publish = function(payload) self.CombatRE:FireAllClients(payload) end
    end
    if not publish then return end
    local ok, err = pcall(publish, self:CombatPayload(fish, gone))
    if not ok then print('[FishTree] 战斗状态广播失败', 'fish=' .. tostring(fish.Id), tostring(err)) end
end

function Mgr:HandleCombatRequest(player)
    if not player or not self.CombatRE then return false end
    for _, fish in pairs(self.Fish) do
        if fish.CombatPublished then
            local ok, err = pcall(function() self.CombatRE:FireClient(player, self:CombatPayload(fish)) end)
            if not ok then print('[FishTree] 战斗快照发送失败', player.UserId, tostring(err)) end
        end
    end
    return true
end

function Mgr:StartCombatChannel()
    if self.CombatChannelStarted then return end
    self.CombatChannelStarted = true
    if type(self.BindCombatChannel) == 'function' then
        self.CombatRequestConn = self.BindCombatChannel(function(player)
            self:HandleCombatRequest(player)
        end)
    end
end

function Mgr:UpdateEel(fish, now, entry)
    local body = fish.Carrier.Body
    body.Position = fish.CombatPosition
    body.LinearVelocity = Vector3.New(0, 0, 0)
    if fish.State == Mgr.State.Sleeping then
        if now < fish.WakeAt then return end
        if fish.CombatRotation then body.Rotation = fish.CombatRotation end
        self:SetState(fish, Mgr.State.Combat)
        fish.WakeAt = nil
        fish.Discharges = 0
        fish.WarnAt, fish.DischargeAt = nil, nil
        print('[FishTree] 电鳗醒来', 'fish=' .. tostring(fish.Id))
        self:PublishCombat(fish)
    end
    local attacking = fish.State == Mgr.State.Attacking
    local done = fish.Discharges or 0
    local windup = bossWindup(fish, 'discharge')
    local interval = entry.DischargeIntervalSec
    if attacking then self:FlailEel(fish, now, entry) end
    if attacking and done >= entry.DischargeCount and not fish.DischargeAt then
        if now < (fish.WarnAt or math.huge) then return end
        if fish.CombatRotation and Quaternion then
            body.Rotation = fish.CombatRotation * Quaternion.FromEulerAngles(0, 0, entry.SleepRollRadians)
        end
        self:SetState(fish, Mgr.State.Sleeping)
        fish.WakeAt = now + entry.SleepSec
        fish.WarnAt = nil
        publishBite(self, GarBiteNotice.Clear(fish.Id, 'sleep'))
        print('[FishTree] 电鳗睡眠', 'fish=' .. tostring(fish.Id), 'wakeAt=' .. tostring(fish.WakeAt))
        self:PublishCombat(fish)
        return
    end
    if fish.DischargeAt then
        if now < fish.DischargeAt then return end
    elseif not attacking then
        fish.State, fish.AttackAt = Mgr.State.Attacking, now
        done, fish.Discharges = 0, 0
        fish.WarnAt = now
    elseif now < fish.WarnAt then
        return
    end
    if not fish.DischargeAt then
        local warning = BossMoves.WarningOf('eel', 'discharge')
        local notice = GarBiteNotice.Lock(fish.Id, fish.CombatPosition or body.Position, 0, 1,
            warning.Range, 180, warning.WindupSec)
        notice.move, notice.shape, notice.notice = 'discharge', warning.Shape, warning.Notice
        publishBite(self, notice)
        fish.DischargeAt, fish.WarnAt = now + windup, now + interval
        self:PublishCombat(fish)
        return
    end
    local castOk, casted = true, false
    if self.Ability then castOk, casted = pcall(self.Ability.CastFish, self.Ability, fish) end
    if not castOk then
        print('[FishTree] 电鳗施法异常', 'fish=' .. tostring(fish.Id), tostring(casted))
    end
    if not castOk or not casted then
        fish.DischargeAt = now
        if not fish.CastRejected then
            fish.CastRejected = true
            print('[FishTree] 电鳗施法未成功，下帧重试', 'fish=' .. tostring(fish.Id), 'done=' .. tostring(done))
        end
        return
    end
    fish.CastRejected, fish.DischargeAt = nil, nil
    fish.Discharges = done + 1
    print('[FishTree] 电鳗放电', 'fish=' .. tostring(fish.Id), fish.Discharges .. '/' .. entry.DischargeCount)
    self:PublishCombat(fish)
end

function Mgr:FlailEel(fish, now, entry)
    if fish.CombatRotation and Quaternion then
        fish.Carrier.Body.Rotation = fish.CombatRotation * Quaternion.FromEulerAngles(0,
            math.sin((now - fish.AttackAt) * math.pi * 2 * entry.FlailHz) * entry.FlailRadians, 0)
    end
end


local function zoneScene(zoneId)
    for _, zone in ipairs(GameCfg.Zones or {}) do
        if zone.Id == zoneId then return zone.Scene end
    end
end

function Mgr:FlightProfile(fishId)
    local species = GameCfg.Ability.Flight.Species
    if species and species[fishId] then
        return BossMoves.CombatParams(species[fishId], fishId)
    end
    local fish = GameCfg.Fish[fishId]
    if fish and fish.CatchSource == 'air' and (fish.Grade == 'normal' or fish.Grade == 'rare') then
        return { Speed = fish.Speed, CruiseHeight = GameCfg.Ability.Flight.CruiseHeight,
            DiveIntervalSec = math.huge }
    end
end

function Mgr:BossPhaseEnabled(fishId)
    local species = GameCfg.Ability.BossPhase.Species
    return type(species) == 'table' and species[fishId] == true
end

function Mgr:FlightBounds(fishId, position)
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
    local bounds = FlightPath.BoundsOf(scene, GameCfg.Ability.Flight)
    if bounds then return bounds end
    local fallback = GameCfg.Ability.Flight.FallbackBounds
    if not fallback then return nil end
    return FlightPath.BoundsOf({ Boundary = fallback, SafePoint = { x = 0, y = 0, z = 0 } }, GameCfg.Ability.Flight)
end

function Mgr:StartFlight(fish, now)
    if self.Ai then self.Ai:Custom(fish) end
    local profile = self:FlightProfile(fish.FishId)
    local pos = readPosition(fish.Carrier.Body)
    local bounds = self:FlightBounds(fish.FishId, pos)
    if not profile or not bounds then return false end
    fish.Flight = FlightPath.New(bounds, GameCfg.Ability.Flight, profile, pos, now)
    fish.FlightAt = now
    self:SetState(fish, Mgr.State.Flying)
    fish.DiveActive = false
    if fish.FishId == 'fish55Elite' then
        self:StartAquatic(fish, now)
    end
    if GameCfg.Fish[fish.FishId].ZoneId == 'reefIsland' then
        fish.Flight.NextDiveAt = math.huge
        fish.NextReefDiveAt = now + (profile.DiveIntervalSec or math.huge)
        fish.NextThrowAt = now + (profile.ThrowIntervalSec or math.huge)
        fish.AirAttacks = {}
        self:PublishCombat(fish)
    end
    pcall(function() fish.Carrier.Body.BodyType = 2 end)
    print('[FishTree] 起飞', fish.FishId, 'fish=' .. tostring(fish.Id))
    return true
end

function Mgr:ExitFlight(fish, now, reason)
    self:EndAirAttacks(fish, reason)
    fish.Flight = nil
    fish.DiveActive = false
    if self.Fish[fish.Id] ~= fish then return end
    self:SetState(fish, Mgr.State.Escaping)
    fish.StraightEscape = true
    self:PublishCombat(fish, true)
    fish.EscapeAt = now
    fish.EscapeBy = nil
    fish.TurnAt = now + cfg().TurnSec
    fish.RayAt = now
    if fish.CombatRotation then pcall(function() fish.Carrier.Body.Rotation = fish.CombatRotation end) end
    self:SetHeading(fish, towardWater(readPosition(fish.Carrier.Body) or fish.Anchor))
    print('[FishTree] 结束飞行', reason or '', fish.FishId, 'fish=' .. tostring(fish.Id))
end

function Mgr:StartAirAttack(fish, kind, pos, now)
    local flight, profile = GameCfg.Ability.Flight, fish.Flight.Profile
    self.NextAirAttackId = (self.NextAirAttackId or 0) + 1
    local dive = kind == 'airDive'
    local duration = dive and (flight.ReefDiveWarnSec + flight.ReefDiveSec) or flight.ThrowFlightSec
    local attack = { Id = -self.NextAirAttackId, Kind = kind, At = now, StrikeAt = now + duration,
        Center = { x = pos.x, y = pos.y, z = pos.z },
        Origin = { x = fish.Flight.Pos.x, y = fish.Flight.Pos.y, z = fish.Flight.Pos.z },
        Radius = dive and flight.DiveRadius or profile.ThrowRadius,
        Damage = dive and profile.DiveDamage or profile.ThrowDamage }
    local b = fish.Flight.Bounds
    attack.Center.x = math.max(b.MinX,math.min(b.MaxX,attack.Center.x))
    attack.Center.z = math.max(b.MinZ,math.min(b.MaxZ,attack.Center.z))
    attack.Center.y = math.max(b.GroundY,math.min(b.CeilingY,attack.Center.y))
    fish.AirAttacks[kind] = attack
    local payload = GarBiteNotice.Lock(attack.Id, attack.Center, 0, 1, attack.Radius, 180, duration)
    payload.shape, payload.move, payload.ownerFishId = 'circle', kind, fish.Id
    payload.flightOrigin = attack.Origin
    local row = BossMoves.Get(fish.FishId, dive and 'dive' or 'throw')
    if row and row.Delivery and row.Warning.Kind ~= 'none' then
        payload.shape = row.Warning.Kind or payload.shape
        payload.notice, payload.delivery, payload.landing = row.Warning.Notice, row.Delivery, row.Landing
        payload.landingPoint = attack.Center
    end
    publishBite(self, payload)
    print('[FishTree] 空战预警', fish.FishId, kind, attack.Id, attack.Damage)
    return attack
end

function Mgr:EndAirAttacks(fish, reason)
    for _, attack in pairs(fish.AirAttacks or {}) do
        publishBite(self, GarBiteNotice.Clear(attack.Id, reason or 'gone'))
    end
    fish.AirAttacks = nil
end

function Mgr:UpdateAirAttacks(fish, targetPos, now)
    local state, flight = fish.Flight, GameCfg.Ability.Flight
    if not fish.AirAttacks then return false end
    for kind, attack in pairs(fish.AirAttacks) do
        if now >= attack.StrikeAt - 1e-8 then
            fish.AirAttacks[kind] = nil
            local hit = false
            for _, player in ipairs(self:Players()) do
                local valid, cp = self:IsTargetValid(player, attack.Center)
                if valid and (cp.x-attack.Center.x)^2 + (cp.z-attack.Center.z)^2 <= attack.Radius^2
                    and math.abs(cp.y-attack.Center.y) <= attack.Radius then
                    hit = self:Hit(fish, player, attack.Damage, kind) or hit
                end
            end
            publishBite(self, GarBiteNotice.Clear(attack.Id, hit and 'hit' or 'miss'))
            if kind == 'airDive' then
                state.Pos = {x=attack.Center.x,y=attack.Center.y,z=attack.Center.z}
                state.Last = {x=state.Pos.x,y=state.Pos.y,z=state.Pos.z}
                state.Phase = 'climb'
            end
        end
    end
    if targetPos then
        if now >= (fish.NextThrowAt or math.huge) - 1e-8 then
            fish.NextThrowAt = now + state.Profile.ThrowIntervalSec
            self:StartAirAttack(fish, 'airThrow', targetPos, now)
        end
        if now >= (fish.NextReefDiveAt or math.huge) - 1e-8 then
            fish.NextReefDiveAt = now + state.Profile.DiveIntervalSec
            self:StartAirAttack(fish, 'airDive', targetPos, now)
        end
    end
    local dive = fish.AirAttacks.airDive
    if not dive then return false end
    local progress = math.min(1, math.max(0, (now-dive.At-flight.ReefDiveWarnSec)/flight.ReefDiveSec))
    state.Pos = { x=dive.Origin.x+(dive.Center.x-dive.Origin.x)*progress,
        y=dive.Origin.y+(dive.Center.y-dive.Origin.y)*progress,
        z=dive.Origin.z+(dive.Center.z-dive.Origin.z)*progress }
    state.Last = {x=state.Pos.x,y=state.Pos.y,z=state.Pos.z}
    state.Vel = {x=0,y=0,z=0}
    return true
end

function Mgr:UpdateFlying(fish, now)
    local state = fish.Flight
    local body = fish.Carrier.Body
    if not state then
        self:Remove(fish)
        return
    end
    local pos = readPosition(body)
    if not pos then
        print('[FishTree] 飞行鱼坐标异常，移除', fish.Id)
        self:Remove(fish)
        return
    end
    if fish.FishId == 'fish55Elite' then
        if fish.FleeAt and now >= fish.FleeAt then
            self:EndBossAttack(fish, 'timeout')
            self:ReleaseCarried(fish, nil, 'timeout')
            fish.Aquatic = nil
            self:ExitFlight(fish, now, 'timeout')
        else
            self:UpdateAquatic(fish,now)
        end
        return
    end
    if (fish.FleeAt and now >= fish.FleeAt) or (inWater(pos) and pos.y <= inWater(pos).SurfaceY) then
        self:ExitFlight(fish, now, (fish.FleeAt and now >= fish.FleeAt) and 'timeout' or 'water')
        return
    end
    local flight = GameCfg.Ability.Flight
    local target, tpos = self:ChooseTarget(fish, pos, { AggroRange = flight.AggroRange })
    FlightPath.SetTarget(state, tpos)
    local dt = math.max(0, now - (fish.FlightAt or now))
    fish.FlightAt = now
    if self.Ai then
        self.Ai:Custom(fish)
        local speed = GameCfg.Fish[fish.FishId].Speed
        if speed and speed > 0 then dt = dt * self:Speed(fish) / speed end
    end
    local diving = self:UpdateAirAttacks(fish, tpos, now)
    local events = diving and {} or FlightPath.Step(state, now, dt)
    local moved, moveErr = pcall(function()
        body.Position = Vector3.New(state.Pos.x, state.Pos.y, state.Pos.z)
    end)
    if not moved then
        print('[FishTree] 飞行位置写回失败', fish.FishId, tostring(moveErr))
        if self.Ai then self:Remove(fish); return end
    end
    MgrFishCarrier:SyncPosition(fish.Carrier, Vector3.New(state.Pos.x,state.Pos.y,state.Pos.z))
    self:RefreshMovingCombat(fish, now)
    pcall(function()
        body.LinearVelocity = Vector3.New(state.Vel.x, state.Vel.y, state.Vel.z)
    end)
    if events.dive then
        fish.DiveActive = true
    elseif fish.DiveActive and state.Phase == 'climb' then
        fish.DiveActive = false
        if target and tpos then
            local dx, dz = tpos.x - state.Pos.x, tpos.z - state.Pos.z
            if math.sqrt(dx * dx + dz * dz) <= flight.DiveRadius then
                self:Hit(fish, target, events.diveDamage or state.Profile.DiveDamage or flight.DiveDamage, 'dive')
            end
        end
    end
end

function Mgr:Hit(fish, target, damage, kind)
    if not target or not self.Vitals or type(damage) ~= 'number' or damage <= 0 then return false end
    local hit = self.Vitals:NewHit(fish, 'fishAttack')
    local applied = self.Vitals:ApplyHit(hit, target, damage)
    if applied then
        print('[FishTree] 命中', kind or 'attack', fish.FishId, damage, 'fish=' .. tostring(fish.Id))
    end
    return applied == true
end

function Mgr:UpdateBossPhase(fish, now, pos)
    if self.Ai then self.Ai:Custom(fish) end
    local state = fish.Phase
    if not state then
        self:Remove(fish)
        return
    end
    local params = GameCfg.FishCombat and GameCfg.FishCombat[fish.Fight] or nil
    params = params or GameCfg.Ability.BossPhase.Chase
    local target, tpos = self:ChooseTarget(fish, pos, params)
    local dt = math.max(0, now - (fish.PhaseAt or now))
    fish.PhaseAt = now
    pcall(function() fish.Carrier.Body.LinearVelocity = Vector3.New(0, 0, 0) end)
    local events = BossPhase.Update(state, now, dt, {
        Health = fish.Carrier.Health, MaxHealth = fish.Carrier.MaxHealth,
        Alive = not fish.Carrier.Dead, Target = tpos, Pos = pos,
    })
    if fish.BossWarn and (events.PhaseChanged or events.Interrupted or not state.Alive) then
        self:EndBossAttack(fish, events.To or events.Reason or 'gone')
    end
    if events.PhaseChanged then
        self:ReleaseCarried(fish,nil,'phase')
        self:EndAirAttacks(fish,'phase')
        self:EndMove(fish,'phase')
        fish.Aquatic=nil
        if events.To == 'water' then
            self:StartAquatic(fish,now)
        else
            local p=fish.CombatPosition
            fish.Carrier.Body.Position=Vector3.New(p.x,p.y,p.z)
            MgrFishCarrier:SyncPosition(fish.Carrier,Vector3.New(p.x,p.y,p.z))
        end
        self:PublishCombat(fish)
        print('[FishTree] 首领阶段',fish.FishId,events.To,events.Percent)
        return
    end
    if state.Phase == 'water' then self:UpdateAquatic(fish,now); return end
    if state.Pending and not fish.BossWarn then
        local fx, fz = flatDirection(tpos.x-pos.x,tpos.z-pos.z)
        fx, fz = fx or 0, fz or 1
        self:Face(fish,fx,fz)
        local attackCfg = GameCfg.Ability.BossPhase.Attacks[state.Pending.Name]
        local row = BossMoves.Get(BossMoves.KeyOf(GameCfg.Fish[fish.FishId], fish.FishId),
            state.Pending.Name)
        fish.BossWarn = { Origin = {x=pos.x,y=pos.y,z=pos.z}, Facing = {x=fx,z=fz}, Target = target }
        if not row or row.Warning.Kind ~= 'none' then
            local notice = GarBiteNotice.Lock(fish.Id,pos,fx,fz,attackCfg.Range,0,attackCfg.WindupSec)
            notice.move = row and row.Warning.Notice or 'bossStomp'
            notice.shape, notice.width = row and row.Warning.Kind or 'circle',
                (row and row.Warning.Width) or attackCfg.Width
            publishBite(self,notice)
        end
    end
    if fish.Carry then self:UpdateCarry(fish,now); return end
    if not events.Attack then return end
    local attack = events.Attack
    if attack.Name == 'stomp' then
        local warn=fish.BossWarn
        self:EndBossAttack(fish,'stomp')
        if not warn then return end
        local radius=GameCfg.Ability.BossPhase.Attacks.stomp.Range
        for _, player in ipairs(self:Players()) do
            local valid,cp=self:IsTargetValid(player,warn.Origin)
            if valid and (cp.x-warn.Origin.x)^2+(cp.z-warn.Origin.z)^2<=radius^2
                and math.abs(cp.y-warn.Origin.y)<=radius then
                self:Hit(fish,player,attack.Damage,'stomp')
            end
        end
        return
    end
    if attack.Lethal then
        local warn = fish.BossWarn
        self:EndBossAttack(fish,'strike')
        if not warn then return end
        local breath = GameCfg.Ability.BossPhase.Attacks.breath
        for _, player in ipairs(self:Players()) do
            local valid, cp = self:IsTargetValid(player,warn.Origin)
            if valid then
                local dx,dz = cp.x-warn.Origin.x,cp.z-warn.Origin.z
                local along = dx*warn.Facing.x+dz*warn.Facing.z
                local across = math.abs(dx*warn.Facing.z-dz*warn.Facing.x)
                if along >= 0 and along <= breath.Range and across <= breath.Width/2
                    and math.abs(cp.y-warn.Origin.y) <= GameCfg.Ability.BossPhase.Chase.BiteRange then
                    self:Hit(fish,player,player.Character.Controller.Health,'breath')
                end
            end
        end
        return
    end
    if attack.Name == 'bite' and target and tpos and CarryMount.InRange(
        CarryMount.New(GameCfg.Ability.Carry, pos, fish.Yaw or 0, now), tpos) then
        self:GrabPlayer(fish, target, now, attack.Damage)
        return
    end
    if target then self:Hit(fish, target, attack.Damage, attack.Name) end
end

function Mgr:EndBossAttack(fish, reason)
    if not fish.BossWarn then return end
    fish.BossWarn = nil
    if fish.Phase then fish.Phase.Pending = nil end
    publishBite(self,GarBiteNotice.Clear(fish.Id,reason or 'gone'))
end

function Mgr:StartAquatic(fish, now)
    local pos = readPosition(fish.Carrier.Body)
    local scene
    for _, zone in ipairs(GameCfg.Zones) do
        local b=zone.Scene.Boundary
        if pos.x>=b.MinX and pos.x<=b.MaxX and pos.z>=b.MinZ and pos.z<=b.MaxZ then
            scene=zone.Scene; break
        end
    end
    if not scene or not scene.Waters[1] then return false end
    fish.Aquatic={ Scene=scene, Water=scene.Waters[1], LastAt=now,
        NextLeapAt=now+GameCfg.Ability.Aquatic.LeapIntervalSec, Angle=0 }
    self:PublishCombat(fish)
    return true
end

function Mgr:UpdateAquatic(fish, now)
    local state=fish.Aquatic
    if not state then return end
    if self.Ai then self.Ai:Custom(fish) end
    local cfg=GameCfg.Ability.Aquatic
    local body=fish.Carrier.Body
    local p=readPosition(body)
    local dt=math.min(0.25,math.max(0,now-state.LastAt))
    state.LastAt=now
    local speed=self:Speed(fish)
    local w=state.Water
    local function moveTo(destination)
        local dx,dy,dz=destination.x-p.x,destination.y-p.y,destination.z-p.z
        local distance=math.sqrt(dx*dx+dy*dy+dz*dz)
        local t=distance>0 and math.min(1,speed*dt/distance) or 1
        p={x=p.x+dx*t,y=p.y+dy*t,z=p.z+dz*t}
    end
    if state.HeadAt and now>=state.HeadAt then
        local center=state.HeadCenter
        state.HeadAt,state.HeadCenter=nil,nil
        self:EndBossAttack(fish,'head')
        for _, player in ipairs(self:Players()) do
            local valid,cp=self:IsTargetValid(player,center)
            if valid and (cp.x-center.x)^2+(cp.z-center.z)^2<=cfg.HeadRadius^2 then
                self:Hit(fish,player,cfg.HeadDamage,'head')
            end
        end
    end
    if fish.Carry then
        moveTo({x=w.Center.x,y=w.SurfaceY,z=w.Center.z})
        body.Position=Vector3.New(p.x,p.y,p.z)
        self:UpdateCarry(fish,now)
        if inWater(p) then
            self:ReleaseCarried(fish,{x=p.x,y=w.SurfaceY,z=p.z},'water')
        end
    elseif state.Leap then
        local leap=state.Leap
        local progress=math.min(1,math.max(0,(now-leap.At-cfg.LeapWindupSec)/cfg.LeapSec))
        p={x=leap.Origin.x+(leap.Center.x-leap.Origin.x)*progress,
            y=leap.Origin.y+(leap.Center.y-leap.Origin.y)*progress+cfg.LeapHeight*math.sin(math.pi*progress),
            z=leap.Origin.z+(leap.Center.z-leap.Origin.z)*progress}
        body.Position=Vector3.New(p.x,p.y,p.z)
        if progress>=1 then
            local phase = fish.Phase and fish.Phase.Phase
            state.Leap=nil
            self:EndBossAttack(fish,'land')
            for _, player in ipairs(self:Players()) do
                local valid,cp=self:IsTargetValid(player,p)
                if valid and (cp.x-p.x)^2+(cp.z-p.z)^2<=cfg.LeapRadius^2 then
                    self:Hit(fish,player,cfg.LeapDamage,'leap')
                end
            end
            if self.Fish[fish.Id] ~= fish or fish.Aquatic ~= state
                or (fish.Phase and fish.Phase.Phase) ~= phase then return end
            local valid,cp=self:IsTargetValid(leap.Target,p)
            if valid and (cp.x-p.x)^2+(cp.z-p.z)^2<=GameCfg.Ability.Carry.GrabRange^2 then
                local damage=fish.Phase and GameCfg.Ability.BossPhase.Thresholds[1].BiteDamage or cfg.GrabDamage
                self:GrabPlayer(fish,leap.Target,now,damage)
            end
            if self.Fish[fish.Id] ~= fish or fish.Aquatic ~= state
                or (fish.Phase and fish.Phase.Phase) ~= phase
                or not self:IsTargetValid(leap.Target,p) then return end
            state.HeadAt=now+cfg.HeadWindupSec
            state.HeadCenter={x=p.x,y=p.y,z=p.z}
            local n=GarBiteNotice.Lock(fish.Id,p,0,1,cfg.HeadRadius,180,cfg.HeadWindupSec)
            n.shape,n.move='circle','mosasaurHead'
            fish.BossWarn={Target=leap.Target}
            publishBite(self,n)
        end
    elseif not state.HeadAt then
        if now>=state.NextLeapAt then
            local target,tpos,best
            local center=state.Scene.SafePoint
            for _, player in ipairs(self:Players()) do
                local valid,cp=self:IsTargetValid(player,center,{AggroRange=GameCfg.Ability.Flight.AggroRange})
                if valid then
                    local d=(cp.x-center.x)^2+(cp.z-center.z)^2
                    if not best or d<best then target,tpos,best=player,cp,d end
                end
            end
            state.NextLeapAt=now+cfg.LeapIntervalSec
            if target then
                state.Leap={At=now,Origin={x=p.x,y=p.y,z=p.z},Center={x=tpos.x,y=tpos.y,z=tpos.z},Target=target}
                fish.BossWarn={Target=target}
                local n=GarBiteNotice.Lock(fish.Id,tpos,0,1,cfg.LeapRadius,180,cfg.LeapWindupSec+cfg.LeapSec)
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
    MgrFishCarrier:SyncPosition(fish.Carrier, Vector3.New(p.x,p.y,p.z))
    self:RefreshMovingCombat(fish,now)
end

function Mgr:GrabPlayer(fish, target, now, damage)
    if fish.Carry then return false end
    local carryCfg = GameCfg.Ability.Carry
    local pos = readPosition(fish.Carrier.Body)
    if not pos then return false end
    local state = CarryMount.New(carryCfg, pos, fish.Yaw or 0, now)
    state.GroundY = (fish.Anchor and fish.Anchor.y) or pos.y
    state.TargetPlayer = target
    state.LastStepAt = now
    local grabbed = CarryMount.Attach(state, target.Character and readPosition(target.Character) or pos, now)
    if not grabbed.Ok then
        print('[FishTree] 叼人失败', tostring(grabbed.Reason), 'fish=' .. tostring(fish.Id))
        return false
    end
    fish.Carry = state
    self:Hit(fish, target, damage or carryCfg.GrabDamage, 'bite')
    if fish.Carry ~= state or not self:IsTargetValid(target, pos) then
        if fish.Carry == state then self:ReleaseCarried(fish, nil, 'gone') end
        return false
    end
    fish.ContactAt = now
    local ok, attached = pcall(function()
        local api = abilityApi(self)
        if not api then return nil end
        return api.AttachToSocket(self.World, nil, fish.Carrier.Body, carryCfg.Socket, state.Offset)
    end)
    if ok and attached and attached.Ok then
        fish.CarryMount = attached.Mount
    else
        print('[FishTree] 叼人挂点创建失败', 'fish=' .. tostring(fish.Id), tostring(attached))
    end
    print('[FishTree] 叼起玩家', target.UserId, 'fish=' .. tostring(fish.Id))
    return true
end

function Mgr:UpdateCarry(fish, now)
    local state = fish.Carry
    local carryCfg = GameCfg.Ability.Carry
    local pos = readPosition(fish.Carrier.Body)
    if pos then state.Host = pos end
    local dt = math.max(0, now - (state.LastStepAt or now))
    state.LastStepAt = now
    local target = state.TargetPlayer
    local tpos = target and target.Character and readPosition(target.Character)
    if not tpos or not self:IsTargetValid(target, pos) then
        self:ReleaseCarried(fish, nil, 'gone')
        return
    end
    local step = CarryMount.Step(state, now, dt)
    if step.Released then
        self:ReleaseCarried(fish, step.DropPoint, step.Reason)
        return
    end
    local followed = CarryMount.Follow(state, tpos, now, dt)
    if followed.Released then
        self:ReleaseCarried(fish, followed.Position, followed.Reason)
        return
    end
    if followed.Position and target.Character then
        pcall(function()
            target.Character.Position = Vector3.New(followed.Position.x, followed.Position.y, followed.Position.z)
        end)
    end
    if carryCfg.ContactDamage and now - (fish.ContactAt or 0) >= (carryCfg.ContactIntervalSec or 1) then
        fish.ContactAt = now
        self:Hit(fish, target, carryCfg.ContactDamage, 'carry')
        if fish.Aquatic then
            local contact=GameCfg.Ability.Aquatic
            for _, player in ipairs(self:Players()) do
                local valid,cp=self:IsTargetValid(player,pos)
                if player~=target and valid
                    and (cp.x-pos.x)^2+(cp.z-pos.z)^2<=contact.ContactRange^2
                    and math.abs(cp.y-pos.y)<=contact.ContactRange then
                    self:Hit(fish,player,contact.ContactDamage,'carryContact')
                end
            end
        end
    end
end

function Mgr:ReleaseCarried(fish, dropPoint, reason)
    local state = fish.Carry
    if not state then return false end
    local now = self:Now()
    local target = state.TargetPlayer
    local drop = dropPoint or CarryMount.DropPoint(state.Host, state.Yaw, state.GroundY, GameCfg.Ability.Carry)
    CarryMount.Release(state, now, reason or 'release')
    fish.Carry = nil
    fish.ContactAt = nil
    if fish.CarryMount then
        local api = abilityApi(self)
        if api then pcall(api.DetachFromSocket, fish.CarryMount) end
        fish.CarryMount = nil
    end
    if target and target.Character and drop then
        pcall(function() target.Character.Position = Vector3.New(drop.x, drop.y, drop.z) end)
        self:Hit(fish, target, GameCfg.Ability.Carry.FallDamage or 0, 'fall')
    end
    print('[FishTree] 放开玩家', target and target.UserId, reason or '', 'fish=' .. tostring(fish.Id))
    return true
end

function Mgr:FindByCarrier(carrier)
    for _, fish in pairs(self.Fish) do
        if fish.Carrier == carrier then return fish end
    end
end

function Mgr:TakeKilled(fish)
    if not fish or self.Fish[fish.Id] ~= fish then return nil end
    local holder = fish.State == Mgr.State.Held and fish.Holder or nil
    local pos = holder and holder.Character and readPosition(holder.Character)
        or readPosition(fish.Carrier.Body) or fish.Anchor
    self:Remove(fish)
    print('[FishTree] 被打死', fish.FishId, fish.Mult, holder and ('held by ' .. tostring(holder.UserId)) or fish.State,
        'fish=' .. tostring(fish.Id))
    if holder and self.Cast then self.Cast:PushState(holder) end
    if fish.Owner and self.Quest then
        self.Quest:Notify('Kill', fish.Owner, { itemId = fish.FishId, eventId = 'kill:' .. tostring(fish.Id) })
    end
    return { fishId = fish.FishId, mult = fish.Mult, position = pos }
end

function Mgr:GetFish(player)
    local list = {}
    for _, fish in pairs(self.Fish) do
        if fish.Owner == player then list[#list + 1] = fish end
    end
    table.sort(list, function(a, b) return a.Id < b.Id end)
    return list
end

function Mgr:Weight(fish)
    return FishCatch.Weight(GameCfg.Fish[fish.FishId], fish.Mult)
end

function Mgr:Price(fish)
    return FishCatch.Price(GameCfg.Fish[fish.FishId], fish.Mult)
end

function Mgr:CleanupFish(fish)
    if not fish or fish.Cleaned then return end
    fish.Cleaned = true
    self:EndBossAttack(fish, 'gone')
    self:EndAirAttacks(fish, 'gone')
    if self.Ai then self.Ai:Remove(fish) end
    if fish.Carry then self:ReleaseCarried(fish, nil, 'died') end
    self:EndBite(fish, 'gone')
    if fish.DischargeAt then publishBite(self, GarBiteNotice.Clear(fish.Id, 'gone')) end
    self:EndMove(fish, 'gone')
    fish.WakeAt, fish.MoveName = nil, nil
    self.Fish[fish.Id] = nil
    self:PublishCombat(fish, true)
    if self.Ability then self.Ability:RemoveFish(fish) end
    for _, conn in ipairs(fish.Conns or {}) do conn:Disconnect() end
    fish.Conns = nil
    if fish.Holder and self.Held[fish.Holder.UserId] == fish then self.Held[fish.Holder.UserId] = nil end
    MgrFishCarrier:Despawn(fish.Carrier)
    if fish.Mount then pcall(function() fish.Mount:Destroy() end) end
    fish.Mount = nil
end

function Mgr:OnCarrierDied(carrier)
    local fish = self:FindByCarrier(carrier)
    if not fish then return false end
    local killed = self:TakeKilled(fish)
    if killed and type(self.OnKilled) == 'function' then
        self.OnKilled({
            fishId = killed.fishId,
            mult = killed.mult,
            zoneId = GameCfg.Fish[killed.fishId] and GameCfg.Fish[killed.fishId].ZoneId or nil,
            position = killed.position,
        })
    end
    return killed ~= nil
end

function Mgr:Remove(fish)
    if not fish or fish.Cleaned then return end
    self.Fish[fish.Id] = nil
    if fish.Tree and fish.Tree.is_detached ~= true then fish.Tree:dispose() end
    self:CleanupFish(fish)
    if type(self.OnStateChanged) == 'function' then self.OnStateChanged(fish) end
end

function Mgr:Stabilize(fish)
    local body = fish.Carrier.Body
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

function Mgr:Start()
    if self.Ai then self.Ai:Start() end
    self.World = service('World')
    local now = self:Now()
    for _, fish in pairs(self.Fish) do
        if fish.Flight and not fish.AirAttacks and GameCfg.Fish[fish.FishId].ZoneId == 'reefIsland' then
            local profile = fish.Flight.Profile
            fish.AirAttacks = {}
            fish.NextReefDiveAt = now + (profile.DiveIntervalSec or math.huge)
            fish.NextThrowAt = now + (profile.ThrowIntervalSec or math.huge)
            fish.FlightAt = now
        end
    end
    self:StartCombatChannel()
end

function Mgr:ClearLinks(player)
    local links = self.Links[player.UserId]
    if not links then return end
    if links.Added then links.Added:Disconnect() end
    if links.Died then links.Died:Disconnect() end
    self.Links[player.UserId] = nil
end

function Mgr:Stop()
    for _, fish in pairs(self.Fish) do
        self:EndAirAttacks(fish, 'stop')
        self:EndBossAttack(fish, 'stop')
        if fish.Aquatic then fish.Aquatic.Leap=nil; fish.Aquatic.HeadAt=nil end
        if fish.Carry then self:ReleaseCarried(fish, nil, 'stop') end
    end
    if self.Ai then
        self.Ai:Stop()
        for _, fish in pairs(self.Fish) do
            self:EndBite(fish, 'stop')
            self:EndMove(fish, 'stop')
            if fish.Carry then self:ReleaseCarried(fish, nil, 'stop') end
        end
    end
    for _, links in pairs(self.Links) do
        if links.Added then links.Added:Disconnect() end
        if links.Died then links.Died:Disconnect() end
    end
    self.Links = {}
    if self.CombatRequestConn then self.CombatRequestConn:Disconnect() end
    self.CombatRequestConn = nil
end

function Mgr:OnDied(player)
    for _, fish in pairs(self.Fish) do
        if fish.BossWarn and fish.BossWarn.Target == player then
            self:EndBossAttack(fish,'gone')
            if fish.Aquatic then fish.Aquatic.Leap=nil; fish.Aquatic.HeadAt=nil end
        end
        if fish.Carry and fish.Carry.TargetPlayer == player then self:ReleaseCarried(fish,nil,'gone') end
    end
    if self.Ai then
        for _, current in pairs(self.Fish) do
            self.Ai:Custom(current)
            if current.Heading then self:SetHeading(current, current.Heading.x, current.Heading.z) end
            if current.Carry and current.Carry.TargetPlayer == player then self:ReleaseCarried(current, nil, 'gone') end
            if current.BiteAim and current.BiteAim.Target == player then self:EndBite(current, 'gone') end
            if current.Move and current.Move.Target == player then self:EndMove(current, 'gone') end
        end
    end
    if self.Cast and self.Cast.Abort then self.Cast:Abort(player) end
end

function Mgr:WatchCharacter(player, character)
    local links = self.Links[player.UserId]
    if links.Died then links.Died:Disconnect() end
    links.Died = nil
    if not character then return end
    self:IsolateCharacter(character)
    local controller = character.Controller
    if controller and controller.Died then
        links.Died = controller.Died:Connect(function() self:OnDied(player) end)
    end
end

function Mgr:OnPlayerAdded(player)
    self:ClearLinks(player)
    local links = {}
    self.Links[player.UserId] = links
    links.Added = player.CharacterAdded:Connect(function(character)
        self:WatchCharacter(player, character)
    end)
    self:WatchCharacter(player, player.Character)
end

function Mgr:OnPlayerRemoving(player)
    self:ClearLinks(player)
    for _, fish in pairs(self.Fish) do
        if self.Ai then
            self.Ai:Custom(fish)
            if fish.Heading then self:SetHeading(fish, fish.Heading.x, fish.Heading.z) end
        end
        if fish.Carry and fish.Carry.TargetPlayer == player then self:ReleaseCarried(fish, nil, 'gone') end
        if fish.BossWarn and fish.BossWarn.Target == player then
            self:EndBossAttack(fish,'gone')
            if fish.Aquatic then fish.Aquatic.Leap=nil; fish.Aquatic.HeadAt=nil end
        end
        if fish.BiteAim and fish.BiteAim.Target == player then self:EndBite(fish, 'gone') end
        if fish.Move and fish.Move.Target == player then self:EndMove(fish, 'gone') end
        if fish.Threat then fish.Threat[player] = nil end
        if fish.TargetOverride == player then fish.TargetOverride = nil end
    end
    for _, fish in ipairs(self:GetFish(player)) do
        if fish.State == Mgr.State.AwaitLift then
            local species = GameCfg.Fish[fish.FishId]
            self:SetState(fish, Mgr.State.Escaping)
            fish.EscapeAt = self:Now()
            fish.FleeAt = self:Now() + (species and species.EscapeSec or 1)
            fish.Owner = nil
            fish.Holder = nil
        end
    end
end

function Mgr:AiControlled(fish, now)
    if not self.Ai then return false end
    local controlled = self.Ai.Stopped == true
    if self.Ability and self.Ability.FishParalyzed then
        local ok, value = pcall(self.Ability.FishParalyzed, self.Ability, fish)
        if not ok then print('[FishTree] 控制读取失败', fish.Id, tostring(value)); controlled = true
        else controlled = controlled or value == true end
    end
    if controlled then
        if not fish.ControlAt then
            fish.ControlAt = now
            fish.OfficialRollFrom, fish.RollFrom = nil, nil
            if fish.Phase then fish.Phase.Pending = nil end
            self:EndBossAttack(fish, 'controlled')
            if fish.Aquatic then
                fish.Aquatic.Leap,fish.Aquatic.HeadAt,fish.Aquatic.HeadCenter=nil,nil,nil
                fish.Aquatic.LastAt=now
            end
            if fish.Flight then fish.Flight.Phase = 'cruise'; fish.DiveActive = false end
            self:EndBite(fish, 'controlled')
            self:EndMove(fish, 'controlled')
            self:EndAirAttacks(fish, 'controlled')
            if fish.Flight then fish.AirAttacks = {} end
            if fish.Carry then self:ReleaseCarried(fish, nil, 'controlled') end
        end
        self.Ai:Pause(fish, true)
        fish.Carrier.Body.LinearVelocity = Vector3.New(0, 0, 0)
        fish.CombatStepAt, fish.FlightAt, fish.PhaseAt = now, now, now
        return true
    end
    if fish.ControlAt then
        local elapsed = now - fish.ControlAt
        for _, key in ipairs({ 'ActiveUntil', 'SpecialAt', 'JabAt', 'PinchAt', 'ChargeAt',
            'JumpAt', 'RoarAt', 'TailAt', 'ClawAt', 'NextDischargeAt', 'WakeAt',
            'NextReefDiveAt', 'NextThrowAt' }) do
            if fish[key] then fish[key] = fish[key] + elapsed end
        end
        if fish.Phase then
            for key, at in pairs(fish.Phase.Cooldown) do fish.Phase.Cooldown[key] = at + elapsed end
        end
        if fish.Flight then fish.Flight.NextDiveAt = fish.Flight.NextDiveAt + elapsed end
        if fish.Aquatic then
            fish.Aquatic.NextLeapAt=fish.Aquatic.NextLeapAt+elapsed
            fish.Aquatic.LastAt=now
        end
        fish.ControlAt = nil
        self.Ai:Pause(fish, false)
        if fish.Heading then self:SetHeading(fish, fish.Heading.x, fish.Heading.z) end
    end
    return false
end

function Mgr:Update()
    self:FrameClock().on_frame:invoke({ dt = 0, now = self:Now() })
    self:EnforceEscapeCap(nil)
end

function Mgr.new()
  local host = { Fish = {}, NextId = 0, Held = {}, Links = {} }
  return setmetatable(host, { __index = Mgr })
end

function Mgr:DamageFish(fish, amount)
  if type(fish) ~= 'table' or self.Fish[fish.Id] ~= fish then return false end
  if not Number.IsFiniteNumber(amount) or amount <= 0 then return false end
  local carrier = fish.Carrier
  if not carrier then return false end
  local health = (carrier.Health or 0) - amount
  if health < 0 then health = 0 end
  carrier.Health = health
  if carrier.Controller then
    pcall(function() carrier.Controller.Health = health end)
  end
  if health <= 0 then
    self:OnCarrierDied(carrier)
  elseif type(self.OnStateChanged) == 'function' then
    self.OnStateChanged(fish)
  end
  return true
end

function Mgr:Fault(fish, reason)
  if type(fish) ~= 'table' or self.Fish[fish.Id] ~= fish then return false end
  if not fish.FaultDock or not fish.Tree or fish.Tree.is_detached == true then return false end
  fish.FaultDock:effect('fault', function()
    error(tostring(reason or 'fish'), 0)
  end)
  return fish.Tree.fault ~= nil
end

return Mgr
