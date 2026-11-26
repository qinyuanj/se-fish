local GameCfg = require('common.game_cfg')
local GarBiteNotice = require('common.gar_bite_notice')
local BossMoves = require('common.cfg.boss_moves')
local FishBehaviors = require('server.fish_behaviors')
local FishBehaviorKit = require('server.fish_behaviors.kit')

---@class FishCombatWarning
---@field Range number
---@field WindupSec number
---@field Shape string
---@field Notice string

local CombatPhase = {}

function CombatPhase.install(Mgr, context)
    local distanceSq = context.distanceSq
    local readPosition = context.readPosition
    local flatDirection = context.flatDirection
    local towardWater = context.towardWater
    local inWater = context.inWater
    local resetCrabRhythm = context.resetCrabRhythm
    local publishBite = context.publishBite


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

    local withinBite = FishBehaviorKit.within_bite
    local segmentDistanceSq = FishBehaviorKit.segment_distance_sq

    function Mgr.publish_bite(_, payload)
        GarBiteNotice.publish(payload)
    end

    function Mgr.face(_, fish, fx, fz, params)
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
                if FishBehaviorKit.in_head_zone(pos, fish.facing, apos, params) then
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
                ---@type number
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
                if FishBehaviorKit.in_head_zone(pos, fish.facing, cp, params) then
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
            ---@type number
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

    local beginCombatFrame = FishBehaviorKit.begin_combat_frame
    local chaseStep = FishBehaviorKit.chase_step
    local advanceHeadMove = FishBehaviorKit.advance_head_move
    local engageOrChase = FishBehaviorKit.engage_or_chase
    local bossWindup = FishBehaviorKit.boss_windup

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
                    and FishBehaviorKit.in_head_zone(pos, fish.facing, tp, params) then
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
                        and FishBehaviorKit.in_head_zone(pos, fish.facing, tp, params) then
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

    function Mgr:advance_jump(fish, now, _pos, params)
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
                    and FishBehaviorKit.in_head_zone(pos, fish.facing, tp, params) then
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
            ---@cast params table?
            if params then resetCrabRhythm(fish, now, params) end
            self:publish_combat(fish)
        end
        if self:boss_phase_enabled(fish.fish_id) then
            self:update_boss_phase(fish, now, pos)
            return
        end
        local chase = GameCfg.FishCombat and GameCfg.FishCombat[combat]
        ---@cast chase table?
        if chase then
            local key = BossMoves.key_of(GameCfg.Fish[fish.fish_id], fish.fish_id)
            FishBehaviors.step(self, fish, now, pos, BossMoves.combat_params(chase, key), combat)
            return
        end
        self:update_eel(fish, now, GameCfg.Ability.FishAbilities[combat])
    end

    function Mgr.combat_payload(_, fish, gone)
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
        local entry = GameCfg.Ability.FishAbilities[GameCfg.Fish[fish.fish_id].Combat]
        ---@cast entry table?
        if entry then return end
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
            local combat_rotation = fish.combat_rotation
            ---@cast combat_rotation table?
            if combat_rotation and Quaternion then
                body.Rotation = combat_rotation * Quaternion.FromEulerAngles(0, 0, entry.SleepRollRadians)
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
            ---@cast warning FishCombatWarning
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

    function Mgr.flail_eel(_, fish, now, entry)
        local combat_rotation = fish.combat_rotation
        ---@cast combat_rotation table?
        if combat_rotation and Quaternion then
            fish.carrier.body.Rotation = combat_rotation * Quaternion.FromEulerAngles(0,
                math.sin((now - fish.attack_at) * math.pi * 2 * entry.FlailHz) * entry.FlailRadians, 0)
        end
    end



end

function CombatPhase.mount(host, fish, ps)
    ps:subscribe(host:frame_clock().on_frame, function(frame)
        local now = host:begin_phase_frame(fish, frame and frame.now)
        if not now then return end
        if fish.State == host.State.flying then
            host:update_flying(fish, now)
        elseif fish.flee_at then
            host:update_combat(fish, now)
        end
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
end

return CombatPhase
