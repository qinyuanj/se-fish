-- #260 目标选择适配层：业务 Policy.Order 按累计有效伤害裁决，官方 AI 管理器只登记结果。
-- 上游 searchEnemy 写死最近距离且会写 Controller 位移，优先级权重/焦点接口均为预留，不能宣称官方裁决。
-- SetFocus 仅把业务名次、优先级与焦点登记到官方运行态供观察；登记失败不阻断业务目标，但完整记录日志。
-- 不调用 SearchEnemy / ChaseTarget，移动、飞行与轨迹仍由 FishBehaviors / FlightPath 自研模块拥有。
local GameCfg = require('common.GameCfg')
local Policy = require('common.AiTargetPolicy')

local Mgr = { Policy = Policy }
local AiAPI, Runtime

local function logFailure(operation, fish, unit, player, err)
    print(string.format('[MgrAiTarget] operation=%s fish=%s unit=%s player=%s error=%s',
        operation, tostring(fish and fish.Id or '-'), tostring(unit and unit.UnitId or '-'),
        tostring(player and player.UserId or '-'), tostring(err)))
end

local function loadAPI(fish, unit)
    if AiAPI == nil then
        -- 大量单测用假 game 加载业务模块；官方包在加载时要引擎服务，故延迟到真正登记时再取。
        local ok, module = pcall(require, 'server.packages.official_ai_feature.api')
        if not ok then
            logFailure('RequireOfficialAPI', fish, unit, nil, module)
            return nil
        end
        AiAPI = module
    end
    return AiAPI
end

local function loadRuntime(fish, unit)
    if Runtime == nil then
        local ok, module = pcall(require, 'server.packages.official_ai_feature.behavior_runtime')
        if not ok then
            logFailure('RequireOfficialRuntime', fish, unit, nil, module)
            return nil
        end
        Runtime = module
    end
    return Runtime
end

local function receiver(fish)
    local carrier = fish and fish.Carrier
    return carrier and carrier.Receiver or nil
end

--- 官方 AI 管理器持有的运行态（只读观察，不在这里另存一份目标）。
function Mgr:State(fish)
    local unit = receiver(fish)
    if not unit then
        logFailure('ReadOfficialState', fish, nil, nil, 'official AI receiver unavailable')
        return nil
    end
    local runtime = loadRuntime(fish, unit)
    if not runtime then return nil end
    local ok, state = pcall(runtime.getState, unit)
    if not ok then
        logFailure('ReadOfficialState', fish, unit, nil, state)
        return nil
    end
    return state
end

function Mgr:Focus(fish)
    local state = self:State(fish)
    return state and state.focusTarget or nil
end

local function clearFocus(fish, unit, apiTable)
    local funcs = apiTable and apiTable.Funcs
    if not funcs then return end
    local ok, err = pcall(funcs.SetSearchEnemyFocusTarget, unit, nil)
    if not ok then logFailure('ClearOfficialFocus', fish, unit, nil, err) end
end

--- 只登记业务已经裁决的目标与名次；失败返回 false，由调用方决定是否继续业务目标。
function Mgr:SetFocus(fish, player, ranked)
    local unit = receiver(fish)
    if not unit then
        logFailure('SetFocus', fish, nil, player, 'official AI receiver unavailable')
        return false
    end
    local apiTable, runtime = loadAPI(fish, unit), loadRuntime(fish, unit)
    local funcs = apiTable and apiTable.Funcs
    if not funcs or not runtime then
        logFailure('SetFocus', fish, unit, player, 'official AI API unavailable')
        return false
    end
    local config = GameCfg.Ability.AiTarget
    local target = player and player.Character or nil
    local ok, err = pcall(function()
        funcs.SetSearchEnemyPriorityMode(unit, config.PriorityMode)
        for _, row in ipairs(ranked or {}) do
            if row.player.Character then
                -- 上游权重接口当前是预留空实现；这里只登记业务裁决数据，不声称它会驱动官方搜敌。
                funcs.SetSearchEnemyPriorityValue(unit, row.player.Character, row.damage)
            end
        end
        funcs.SetSearchEnemyFocusTarget(unit, target)
        local state = runtime.getState(unit)
        if not state or state.focusTarget ~= target then
            error('official AI focus registration did not apply')
        end
    end)
    if not ok then
        logFailure('SetFocus', fish, unit, player, err)
        clearFocus(fish, unit, apiTable)
        return false
    end
    return true
end

--- 业务伤害优先裁决是唯一目标来源；官方登记只作观察，失败不改变业务名次。
function Mgr:Select(fish, candidates)
    local ranked = self.Policy.Order(candidates)
    self:SetFocus(fish, ranked[1] and ranked[1].player or nil, ranked)
    return ranked
end

function Mgr:Start() end

return Mgr
