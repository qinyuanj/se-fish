local GameCfg = require('common.game_cfg')
local GarBiteNotice = require('common.gar_bite_notice')
local BossMoves = require('common.cfg.boss_moves')
local FishBehaviors = require('server.fish_behaviors')
local FishBehaviorKit = require('server.fish_behaviors.kit')
local MoveWarning = require('server.world_host.fish_phases.move_warning')

---@class FishCombatWarning
---@field Range number
---@field WindupSec number
---@field Shape string
---@field Notice string

local CombatPhase = {}
local CombatBehavior = {}

local boss_windup = FishBehaviorKit.boss_windup
local move_warning_payload = MoveWarning.payload

function CombatBehavior.is_target_valid(self, player, pos, params)
    local env = self.combat_env
    local readPosition = env.readPosition
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

function CombatBehavior.note_damage(self, fish, player, amount)
    if not fish or self.Fish[fish.Id] ~= fish or not player
        or type(amount) ~= 'number' or amount <= 0 or amount ~= amount then return false end
    fish.threat = fish.threat or {}
    fish.threat[player] = (fish.threat[player] or 0) + amount
    return true
end

function CombatBehavior.set_target_override(self, fish, player)
    if not fish or self.Fish[fish.Id] ~= fish then return false end
    fish.target_override = player
    return true
end

function CombatBehavior.choose_target(self, fish, pos, params)
    local env = self.combat_env
    local distanceSq = env.distanceSq
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

function CombatBehavior.publish_bite(_, payload)
    GarBiteNotice.publish(payload)
end

function CombatBehavior.face(_, fish, fx, fz, params)
    if not fx then return end
    fish.facing = { x = fx, z = fz }
    if not Quaternion then return end
    local yaw = math.atan(fx, fz) + ((params and params.ModelYawOffset) or 0)
    local ok, err = pcall(function() fish.carrier.body.Rotation = Quaternion.FromEulerAngles(0, yaw, 0) end)
    if not ok then print('[FishTree] 首领转向失败', 'fish=' .. tostring(fish.Id), tostring(err)) end
end

function CombatBehavior.end_bite(self, fish, reason)
    local env = self.combat_env
    local publishBite = env.publishBite
    if not fish.bite_aim then return end
    fish.bite_aim = nil
    publishBite(self, GarBiteNotice.clear(fish.Id, reason))
end

function CombatBehavior.lock_bite(self, fish, target, pos, tpos, now, params)
    local env = self.combat_env
    local flatDirection, publishBite = env.flatDirection, env.publishBite
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

function CombatBehavior.end_move(self, fish, reason)
    local env = self.combat_env
    local publishBite = env.publishBite
    if not fish.Move then return end
    fish.Move, fish.MoveName = nil, nil
    publishBite(self, GarBiteNotice.clear(fish.Id, reason))
    self:publish_combat(fish)
end

function CombatBehavior.start_move(self, fish, name, pos, target, tpos, now, duration, range, shape)
    local env = self.combat_env
    local flatDirection, publishBite = env.flatDirection, env.publishBite
    if self.ai and not self.ai:custom(fish) then return false end
    fish.official_roll_from, fish.roll_from = nil, nil
    self:end_move(fish, 'replace')
    local fx, fz
    if tpos then fx, fz = flatDirection(tpos.x - pos.x, tpos.z - pos.z) end
    self:face(fish, fx, fz)
    fish.Move = { Name = name, Target = target, at = now, strike_at = now + duration,
        Center = { x = pos.x, y = pos.y, z = pos.z },
        destination = tpos and { x = tpos.x, y = pos.y, z = tpos.z } }
    publishBite(self, move_warning_payload(fish, name, pos, fish.Move.destination, duration, range, shape))
    fish.MoveName = name
    self:publish_combat(fish)
    print('[FishTree] 招式预警', fish.fish_id, name, 'fish=' .. tostring(fish.Id))
    return true
end

function CombatBehavior.stun_fish(self, fish, now, params)
    if self.ai then self.ai:custom(fish) end
    self:end_move(fish, 'stun')
    fish.State, fish.wake_at, fish.MoveName = 'stunned', now + params.StunSec, nil
    fish.carrier.body.LinearVelocity = Vector3.New(0, 0, 0)
    self:publish_combat(fish)
    print('[FishTree] 眩晕', fish.fish_id, 'wakeAt=' .. tostring(fish.wake_at))
end

function CombatBehavior.start_jump(self, fish, now, pos, params)
    fish.JumpAt = now + params.JumpIntervalSec
    local rng = math.random
    local angle = (rng and rng() or 0.5) * math.pi * 2
    local dest = { x = pos.x + math.cos(angle) * params.JumpDistance, y = pos.y,
        z = pos.z + math.sin(angle) * params.JumpDistance }
    self:start_move(fish, 'jump', pos, nil, dest, now, params.JumpSec, params.JumpRadius)
end

function CombatBehavior.advance_jump(self, fish, now, _pos, params)
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

function CombatBehavior.update_combat(self, fish, now)
    local env = self.combat_env
    local readPosition, inWater, towardWater = env.readPosition, env.inWater, env.towardWater
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
        self:set_state(fish, self.State.escaping)
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

function CombatBehavior.combat_payload(self, fish, gone)
    local env = self.combat_env
    local readPosition = env.readPosition
    if gone then return { id = fish.Id, state = 'gone' } end
    local entry = GameCfg.Ability.FishAbilities[GameCfg.Fish[fish.fish_id].Combat]
    local pos = readPosition(fish.carrier.body) or fish.combat_position or fish.Anchor
    return { id = fish.Id, fishId = fish.fish_id, state = fish.State,
        phase = fish.Phase and fish.Phase.Phase,
        fleeAt = fish.flee_at, escapeSec = GameCfg.Fish[fish.fish_id].EscapeSec,
        wakeAt = fish.wake_at, move = fish.MoveName, discharges = fish.discharges or 0, dischargeCount = entry and entry.DischargeCount,
        position = pos and { x = pos.x, y = pos.y, z = pos.z } }
end

function CombatBehavior.refresh_moving_combat(self, fish, now)
    local entry = GameCfg.Ability.FishAbilities[GameCfg.Fish[fish.fish_id].Combat]
    ---@cast entry table?
    if entry then return end
    if now < (fish.combat_refresh_at or 0) then return end
    fish.combat_refresh_at = now + GameCfg.FishCombatLabel.MovingRefreshSec
    self:publish_combat(fish)
end

function CombatBehavior.publish_combat(self, fish, gone)
    local species = GameCfg.Fish[fish.fish_id]
    if not (species and species.Combat) then return end
    if gone and not fish.combat_published then return end
    fish.combat_published = not gone and fish.State ~= self.State.escaping
    local publish = self.combat_publisher
    if not publish and self.combat_re then
        publish = function(payload) self.combat_re:FireAllClients(payload) end
    end
    if not publish then return end
    local ok, err = pcall(publish, self:combat_payload(fish, gone))
    if not ok then print('[FishTree] 战斗状态广播失败', 'fish=' .. tostring(fish.Id), tostring(err)) end
end

function CombatBehavior.handle_combat_request(self, player)
    if not player or not self.combat_re then return false end
    for _, fish in pairs(self.Fish) do
        if fish.combat_published then
            local ok, err = pcall(function() self.combat_re:FireClient(player, self:combat_payload(fish)) end)
            if not ok then print('[FishTree] 战斗快照发送失败', player.UserId, tostring(err)) end
        end
    end
    return true
end

function CombatBehavior.start_combat_channel(self)
    if self.combat_channel_started then return end
    self.combat_channel_started = true
    if type(self.bind_combat_channel) == 'function' then
        self.combat_request_conn = self.bind_combat_channel(function(player)
            self:handle_combat_request(player)
        end)
    end
end

function CombatBehavior.update_eel(self, fish, now, entry)
    local env = self.combat_env
    local publishBite = env.publishBite
    local body = fish.carrier.body
    body.Position = fish.combat_position
    body.LinearVelocity = Vector3.New(0, 0, 0)
    if fish.State == self.State.sleeping then
        if now < fish.wake_at then return end
        if fish.combat_rotation then body.Rotation = fish.combat_rotation end
        self:set_state(fish, self.State.Combat)
        fish.wake_at = nil
        fish.discharges = 0
        fish.warn_at, fish.discharge_at = nil, nil
        print('[FishTree] 电鳗醒来', 'fish=' .. tostring(fish.Id))
        self:publish_combat(fish)
    end
    local attacking = fish.State == self.State.attacking
    local done = fish.discharges or 0
    local windup = boss_windup(fish, 'discharge')
    local interval = entry.DischargeIntervalSec
    if attacking then self:flail_eel(fish, now, entry) end
    if attacking and done >= entry.DischargeCount and not fish.discharge_at then
        if now < (fish.warn_at or math.huge) then return end
        local combat_rotation = fish.combat_rotation
        ---@cast combat_rotation table?
        if combat_rotation and Quaternion then
            body.Rotation = combat_rotation * Quaternion.FromEulerAngles(0, 0, entry.SleepRollRadians)
        end
        self:set_state(fish, self.State.sleeping)
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
        fish.State, fish.attack_at = self.State.attacking, now
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

function CombatBehavior.flail_eel(_, fish, now, entry)
    local combat_rotation = fish.combat_rotation
    ---@cast combat_rotation table?
    if combat_rotation and Quaternion then
        fish.carrier.body.Rotation = combat_rotation * Quaternion.FromEulerAngles(0,
            math.sin((now - fish.attack_at) * math.pi * 2 * entry.FlailHz) * entry.FlailRadians, 0)
    end
end

--- 把行为表挂到管理器上；方法名与签名沿用拆分前的 Mgr 方法，依赖从 mgr.combat_env 读取。
CombatPhase.install = FishBehaviorKit.install_behavior(CombatBehavior,
    { 'distanceSq', 'readPosition', 'flatDirection', 'towardWater', 'inWater', 'publishBite' },
    'combat_env', 'CombatPhase.install')

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
