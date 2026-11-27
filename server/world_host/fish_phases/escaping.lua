local GameCfg = require('common.game_cfg')
local BossPhase = require('common.boss_phase')
local FishBehaviors = require('server.fish_behaviors')
local FishBehaviorKit = require('server.fish_behaviors.kit')

---@class FishEscapingSpecies
---@field Grade string
---@field Speed? number
---@field EscapeSec number
---@field Combat? string

---@class FishEscapingJumpParams
---@field JumpIntervalSec number

local EscapingPhase = {}
local EscapingBehavior = {}

-- 射线会命中 TGUnitShop 这类 TriggerUnit（V4 实测），它们和不碰撞的物体都不算墙
local function pass_through(unit)
    if not unit then return true end
    local ok, trigger = pcall(function() return unit.IsA ~= nil and unit:IsA('TriggerUnit') end)
    if ok and trigger then return true end
    local okCollide, collide = pcall(function() return unit.CanCollide end)
    return okCollide and collide == false
end

function EscapingBehavior.speed(self, fish)
    local env = self.escaping_env
    local cfg = env.cfg
    local species = GameCfg.Fish[fish.fish_id]
    ---@cast species FishEscapingSpecies?
    ---@type number
    local speed = species and species.Speed or cfg().EscapeSpeed
    if self.Ability and self.Ability.fish_speed_factor then
        local ok, factor = pcall(self.Ability.fish_speed_factor, self.Ability, fish)
        if ok and type(factor) == 'number' and factor >= 0 and factor <= 1 then speed = speed * factor end
    end
    return speed
end

function EscapingBehavior.set_heading(self, fish, x, z)
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

function EscapingBehavior.release_await_lift(self, fish, reason)
    local env = self.escaping_env
    local readPosition, cfg, towardWater = env.readPosition, env.cfg, env.towardWater
    if self.Fish[fish.Id] ~= fish or fish.State ~= self.State.await_lift then return false end
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
    self:set_state(fish, self.State.escaping)
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

--- 放下时的刚体复位：脱钩到世界、朝向、落地偏移与刚体设置。
---@param self table 逃脱阶段句柄
---@param env table 逃脱阶段的环境依赖
---@param fish table 目标鱼
---@param holder table? 原持有者
---@return table, table? 刚体与放下点
local function release_detach_body(self, env, fish, holder)
    local body = fish.carrier.body
    local world = self.World or env.service('World')
    local character = holder and holder.Character
    local origin = character and env.readPosition(character) or env.readPosition(body)
    local fx, fz
    pcall(function()
        local forward = character.Rotation:GetForward()
        fx, fz = env.flatDirection(forward.x, forward.z)
    end)
    fx, fz = fx or 0, fz or 0
    pcall(function() body.Parent = world end)
    if fish.mount then pcall(function() fish.mount:Destroy() end) end
    fish.mount = nil
    if origin then
        local c = env.cfg()
        pcall(function()
            body.Position = Vector3.New(origin.x + fx * c.DropOffset, origin.y + c.DropHeight, origin.z + fz * c.DropOffset)
        end)
    end
    pcall(function()
        body.BodyType = 2
        body.AngularVelocity = Vector3.New(0, 0, 0)
    end)
    return body, origin
end

--- 放下后的状态分流：飞行、首领阶段、战斗或普通逃脱。
---@param self table 逃脱阶段句柄
---@param env table 逃脱阶段的环境依赖
---@param fish table 目标鱼
---@param species table 鱼种配置
---@param pos table? 放下位置
---@param body table 刚体
---@param now number 当前时间
local function release_species_phase(self, env, fish, species, pos, body, now)
    if species.Grade ~= 'normal' and species.Grade ~= 'rare' and self:flight_profile(fish.fish_id) then
        fish.flee_at = now + (species.EscapeSec or 180)
        body.LinearVelocity = Vector3.New(0, 0, 0)
        if not self:start_flight(fish, now) then
            print('[FishTree] 飞行档案或边界缺失，回落普通逃脱', fish.fish_id, 'fish=' .. tostring(fish.Id))
            self:set_heading(fish, env.towardWater(pos))
        end
    elseif self:boss_phase_enabled(fish.fish_id) then
        self:set_state(fish, self.State.Combat)
        fish.flee_at = now + (species.EscapeSec or 300)
        fish.combat_position = pos
        fish.combat_rotation = body.Rotation
        fish.Phase = BossPhase.new(GameCfg.Ability.BossPhase, now, pos)
        fish.phase_at = now
        fish.Yaw = 0
        body.LinearVelocity = Vector3.New(0, 0, 0)
    elseif species.Combat then
        self:set_state(fish, self.State.Combat)
        fish.flee_at = now + species.EscapeSec
        fish.combat_position = pos
        fish.combat_rotation = body.Rotation
        body.LinearVelocity = Vector3.New(0, 0, 0)
        local combat_params = GameCfg.FishCombat[species.Combat]
        ---@cast combat_params table?
        if combat_params then
            fish.bite_aim = nil
            FishBehaviors.init(fish, now, combat_params, species)
        elseif self.Ability then
            self.Ability:equip_fish(fish)
        end
        self:publish_combat(fish)
    elseif pos then
        self:set_heading(fish, env.towardWater(pos))
    end
end

function EscapingBehavior.release(self, fish, reason)
    local env = self.escaping_env
    if self.Fish[fish.Id] ~= fish or fish.State ~= self.State.held then return false end
    if self.ai then self.ai:custom(fish) end
    local holder = fish.holder
    if holder and self.held[holder.UserId] == fish then self.held[holder.UserId] = nil end
    local body, origin = release_detach_body(self, env, fish, holder)
    local now = self:now()
    self:set_state(fish, self.State.escaping)
    fish.escape_at = now
    fish.escape_by = holder
    fish.turn_at = now + env.cfg().TurnSec
    fish.ray_at = now
    local pos = env.readPosition(body) or origin
    local species = GameCfg.Fish[fish.fish_id]
    ---@cast species FishEscapingSpecies
    release_species_phase(self, env, fish, species, pos, body, now)
    if reason == 'leave' then
        fish.flee_at = now + (species.EscapeSec or 1)
        fish.Owner = nil
        fish.holder = nil
    end
    print('[FishTree] 放下', holder and holder.UserId, reason, fish.fish_id, 'fish=' .. tostring(fish.Id))
    if reason == 'drop' and holder and self.Quest and not (pos and env.inWater(pos)) then
        self.next_fact_id = (self.next_fact_id or 0) + 1
        self.Quest:notify('DropShore', holder, { itemId = fish.fish_id,
            eventId = 'drop:' .. tostring(fish.Id) .. ':' .. tostring(self.next_fact_id) })
    end
    self:enforce_escape_cap(holder, fish)
    if self.cast and holder then self.cast:PushState(holder) end
    return true
end

function EscapingBehavior.escaping(self)
    local list = {}
    for _, fish in pairs(self.Fish) do
        if fish.State == self.State.escaping then list[#list + 1] = fish end
    end
    table.sort(list, function(a, b)
        if a.escape_at ~= b.escape_at then return a.escape_at < b.escape_at end
        return a.Id < b.Id
    end)
    return list
end

function EscapingBehavior.ray_exclusions(self)
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

function EscapingBehavior.wall_ahead(self, fish, pos)
    local env = self.escaping_env
    local service, cfg = env.service, env.cfg
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
        if not pass_through(hit.Instance) then
            return hit.Distance == nil or hit.Distance <= distance
        end
        excluded[#excluded + 1] = hit.Instance
    end
    return false
end

function EscapingBehavior.update_escaping(self, fish, now)
    local env = self.escaping_env
    local readPosition, inWater, cfg, towardWater = env.readPosition, env.inWater, env.cfg, env.towardWater
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

--- 把行为表挂到管理器上；方法名与签名沿用拆分前的 Mgr 方法，依赖从 mgr.escaping_env 读取。
EscapingPhase.install = FishBehaviorKit.install_behavior(EscapingBehavior,
    { 'readPosition', 'flatDirection', 'towardWater', 'inWater', 'cfg', 'service' },
    'escaping_env', 'EscapingPhase.install')

function EscapingPhase.mount(host, fish, ps)
    ps:subscribe(host:frame_clock().on_frame, function(frame)
        local now = host:begin_phase_frame(fish, frame and frame.now)
        if now then host:update_escaping(fish, now) end
    end)
    ps:on_cleanup(function()
        host:end_move(fish, host.Fish[fish.Id] == fish and 'phase' or 'gone')
    end)
end

return EscapingPhase
