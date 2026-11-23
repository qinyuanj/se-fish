local AiAPI = require('server.packages.official_ai_feature.api')

-- 官方 AI 只是 FishTree 树底的单向输出叶子。
-- 仇恨、阶段、暂停和命令缓存都属于 fish.AiLeaf（由 FishTree 拥有），本模块不读取官方运行时。
local Mgr = { AiAPI = AiAPI }

local function leaf(fish)
    if not fish.AiLeaf then fish.AiLeaf = {} end
    return fish.AiLeaf
end

function Mgr:Custom(fish)
    local state = leaf(fish)
    local carrier = fish.Carrier
    if state.Mode or not state.Initialized then
        local ok, err = pcall(function()
            self.AiAPI.Funcs.StopAI(carrier.Receiver)
            self.AiAPI.Funcs.StopMove(carrier.Receiver, 0)
            local p, offset = carrier.Body.Position, carrier.ReceiverOffset
            carrier.Receiver.Position = Vector3.New(p.x + (offset and offset.x or 0),
                p.y + (offset and offset.y or 0), p.z + (offset and offset.z or 0))
        end)
        state.Mode, state.Target, state.Direction = nil, nil, nil
        carrier.AiOwnsMovement = false
        if not ok then
            state.Initialized = false
            print('[FishAi] operation=Custom', 'fish=' .. tostring(fish.Id), tostring(err))
            return false
        end
        state.Initialized = true
    end
    carrier.AiOwnsMovement = false
    return true
end

function Mgr:Pause(fish, paused)
    local state = leaf(fish)
    if paused then
        self:Custom(fish)
        local record = fish.AbilityRecord
        if record and record.Ready and not state.Paused then
            local api = self.AbilityAPI or require('server.packages.ability_system.api')
            local ok, err = pcall(api.StopAbility, record.Receiver, record.Entry.Index)
            if not ok then print('[FishAi] operation=PauseAbility', 'fish=' .. tostring(fish.Id), tostring(err)) end
        end
    end
    state.Paused = paused == true
end

function Mgr:Command(fish, mode, target, direction, speed, distance, range)
    local state = leaf(fish)
    if self.Stopped or state.Paused then return false end
    local carrier = fish.Carrier
    local unit = carrier and carrier.Receiver
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
        and carrier.AiOwnsMovement then
        -- FishTree 每帧更新自己的移动真源：到距后目标再次远离才恢复，不读取官方运行时任务。
        local resume = mode == 'chase' and state.LastDistance ~= nil and distance ~= nil
            and state.LastDistance <= distance and current_distance ~= nil and current_distance > distance
        if not resume then
            state.LastDistance = current_distance
            return true
        end
    end
    if not self:Custom(fish) then return false end
    local ok, err = pcall(function()
        local p, offset = carrier.Body.Position, carrier.ReceiverOffset
        unit.Position = Vector3.New(p.x + (offset and offset.x or 0),
            p.y + (offset and offset.y or 0), p.z + (offset and offset.z or 0))
        unit.Controller.WalkSpeed = speed
        self.AiAPI.Funcs.StartAI(unit)
        self.AiAPI.Funcs.StopMove(unit, 0)
        if mode == 'direction' then
            self.AiAPI.Funcs.MoveDirection(unit, direction, 0, 0)
        else
            self.AiAPI.Funcs.ChaseTarget(unit, target, range or 0, distance or 0.1, 0, nil, 0, 1)
        end
    end)
    if not ok then
        print('[FishAi] operation=Command', 'fish=' .. tostring(fish.Id), mode, tostring(err))
        state.Mode = nil
        self:Custom(fish)
        return false
    end
    state.Mode, state.Target, state.Direction, state.Speed = mode, target, direction, speed
    state.Distance, state.Range = distance, range
    state.LastDistance = current_distance
    carrier.AiOwnsMovement = true
    return true
end

function Mgr:MoveDirection(fish, direction, speed)
    return self:Command(fish, 'direction', nil, direction, speed)
end

function Mgr:Chase(fish, target, speed, distance, range)
    return self:Command(fish, 'chase', target, nil, speed, distance, range)
end

-- BasicCommand 不返回施法结果；只认可既有槽位在本次调用内同步发出的 CastStart。
-- 零蓄力避免 vendor 创建不受 StopAI 管理的延迟施法任务。
function Mgr:CastFish(fish)
    local state = leaf(fish)
    local record = fish.AbilityRecord
    if self.Stopped or state.Paused or not record or not record.Ready
        or record.Cancelled or fish.Carrier.Dead then return false end
    local api = self.AbilityAPI or require('server.packages.ability_system.api')
    local connection, started = nil, false
    local ok, err = pcall(function()
        local script = api.GetAbility(record.Receiver, record.Entry.Index)
        local handler = script and api.GetAbilityByScript(script)
        local signals = handler and handler.getSignals and handler.getSignals()
        if not signals or not signals.CastStart then return end
        connection = signals.CastStart:Connect(function() started = true end)
        self.AiAPI.Funcs.BasicCommand(record.Receiver, self.AiAPI.Configs.CMD_ABILITY, record.Entry.Index)
    end)
    if connection then connection:Disconnect() end
    if not ok then
        print('[FishAi] operation=CastFish', 'fish=' .. tostring(fish.Id), tostring(err))
        return false
    end
    return started
end

function Mgr:Attach(fish)
    local carrier = fish and fish.Carrier
    if not carrier or not carrier.Receiver or not carrier.Receiver.Controller then
        print('[FishAi] operation=Attach', 'fish=' .. tostring(fish and fish.Id), 'missing-receiver')
        return false
    end
    leaf(fish).Attached = true
    return true
end

function Mgr:Remove(fish)
    if not fish then return true end
    local ok = self:Custom(fish)
    fish.AiLeaf = nil
    if fish.Carrier then fish.Carrier.AiOwnsMovement = false end
    return ok
end

function Mgr:Start()
    self.Stopped = false
end

function Mgr:Stop()
    self.Stopped = true
end

return Mgr
