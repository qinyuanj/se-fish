local AiAPI = require('server.packages.official_ai_feature.api')

local Mgr = { ai_api = AiAPI }

local function leaf(fish)
    if not fish.ai_leaf then fish.ai_leaf = {} end
    return fish.ai_leaf
end

function Mgr:custom(fish)
    local state = leaf(fish)
    local carrier = fish.carrier
    if state.Mode or not state.initialized then
        local ok, err = pcall(function()
            self.ai_api.Funcs.StopAI(carrier.receiver)
            self.ai_api.Funcs.StopMove(carrier.receiver, 0)
            local p, offset = carrier.body.Position, carrier.receiver_offset
            carrier.receiver.Position = Vector3.New(p.x + (offset and offset.x or 0),
                p.y + (offset and offset.y or 0), p.z + (offset and offset.z or 0))
        end)
        state.Mode, state.Target, state.Direction = nil, nil, nil
        carrier.ai_owns_movement = false
        if not ok then
            state.initialized = false
            print('[FishAi] operation=Custom', 'fish=' .. tostring(fish.Id), tostring(err))
            return false
        end
        state.initialized = true
    end
    carrier.ai_owns_movement = false
    return true
end

function Mgr:pause(fish, paused)
    local state = leaf(fish)
    if paused then
        self:custom(fish)
        local record = fish.ability_record
        if record and record.ready and not state.paused then
            local api = self.AbilityAPI or require('server.packages.ability_system.api')
            local ok, err = pcall(api.StopAbility, record.receiver, record.entry.Index)
            if not ok then print('[FishAi] operation=PauseAbility', 'fish=' .. tostring(fish.Id), tostring(err)) end
        end
    end
    state.paused = paused == true
end

function Mgr:command(fish, mode, target, direction, speed, distance, range)
    local state = leaf(fish)
    if self.Stopped or state.paused then return false end
    local carrier = fish.carrier
    local unit = carrier and carrier.receiver
    if not unit or not unit.Controller then
        print('[FishAi] operation=Command', 'fish=' .. tostring(fish.Id), 'missing-controller')
        return false
    end
    local function horizontal_distance()
        if mode ~= 'chase' or not target or not target.Position or not unit.Position then return nil end
        local dx, dz = target.Position.x - unit.Position.x, target.Position.z - unit.Position.z
        return math.sqrt(dx * dx + dz * dz)
    end
    local current_distance = horizontal_distance()
    if state.Mode == mode and state.Target == target and state.Direction == direction
        and state.Speed == speed and state.Distance == distance and state.Range == range
        and carrier.ai_owns_movement then
        local resume = mode == 'chase' and state.last_distance ~= nil and distance ~= nil
            and state.last_distance <= distance and current_distance ~= nil and current_distance > distance
        if not resume then
            state.last_distance = current_distance
            return true
        end
    end
    if not self:custom(fish) then return false end
    local ok, err = pcall(function()
        local p, offset = carrier.body.Position, carrier.receiver_offset
        unit.Position = Vector3.New(p.x + (offset and offset.x or 0),
            p.y + (offset and offset.y or 0), p.z + (offset and offset.z or 0))
        unit.Controller.WalkSpeed = speed
        self.ai_api.Funcs.StartAI(unit)
        self.ai_api.Funcs.StopMove(unit, 0)
        if mode == 'direction' then
            self.ai_api.Funcs.MoveDirection(unit, direction, 0, 0)
        else
            self.ai_api.Funcs.ChaseTarget(unit, target, range or 0, distance or 0.1, 0, nil, 0, 1)
        end
    end)
    if not ok then
        print('[FishAi] operation=Command', 'fish=' .. tostring(fish.Id), mode, tostring(err))
        state.Mode = nil
        self:custom(fish)
        return false
    end
    state.Mode, state.Target, state.Direction, state.Speed = mode, target, direction, speed
    state.Distance, state.Range = distance, range
    state.last_distance = current_distance
    carrier.ai_owns_movement = true
    return true
end

function Mgr:move_direction(fish, direction, speed)
    return self:command(fish, 'direction', nil, direction, speed)
end

function Mgr:Chase(fish, target, speed, distance, range)
    return self:command(fish, 'chase', target, nil, speed, distance, range)
end

-- BasicCommand 不返回施法结果；只认可既有槽位在本次调用内同步发出的 CastStart。
-- 零蓄力避免 vendor 创建不受 StopAI 管理的延迟施法任务。
function Mgr:cast_fish(fish)
    local state = leaf(fish)
    local record = fish.ability_record
    if self.Stopped or state.paused or not record or not record.ready
        or record.cancelled or fish.carrier.dead then return false end
    local api = self.AbilityAPI or require('server.packages.ability_system.api')
    local connection, started = nil, false
    local ok, err = pcall(function()
        local script = api.GetAbility(record.receiver, record.entry.Index)
        local handler = script and api.GetAbilityByScript(script)
        local signals = handler and handler.getSignals and handler.getSignals()
        if not signals or not signals.CastStart then return end
        connection = signals.CastStart:Connect(function() started = true end)
        self.ai_api.Funcs.BasicCommand(record.receiver, self.ai_api.Configs.CMD_ABILITY, record.entry.Index)
    end)
    if connection then connection:Disconnect() end
    if not ok then
        print('[FishAi] operation=CastFish', 'fish=' .. tostring(fish.Id), tostring(err))
        return false
    end
    return started
end

function Mgr:attach(fish)
    local carrier = fish and fish.carrier
    if not carrier or not carrier.receiver or not carrier.receiver.Controller then
        print('[FishAi] operation=Attach', 'fish=' .. tostring(fish and fish.Id), 'missing-receiver')
        return false
    end
    leaf(fish).attached = true
    return true
end

function Mgr:remove(fish)
    if not fish then return true end
    local ok = self:custom(fish)
    fish.ai_leaf = nil
    if fish.carrier then fish.carrier.ai_owns_movement = false end
    return ok
end

function Mgr:start()
    self.Stopped = false
end

function Mgr:stop()
    self.Stopped = true
end

return Mgr
