local GameCfg = require('common.game_cfg')
local Policy = require('common.ai_target_policy')

local Mgr = { Policy = Policy }
local AiAPI, Runtime

local function logFailure(operation, fish, unit, player, err)
    print(string.format('[FishAiTarget] operation=%s fish=%s unit=%s player=%s error=%s',
        operation, tostring(fish and fish.Id or '-'), tostring(unit and unit.UnitId or '-'),
        tostring(player and player.UserId or '-'), tostring(err)))
end

local function loadAPI(fish, unit)
    if AiAPI == nil then
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

function Mgr:State(fish)
    local unit = receiver(fish)
    if not unit then
        logFailure('ReadOfficialState', fish, nil, nil, 'official AI receiver unavailable')
        return nil
    end
    local runtime = loadRuntime(fish, unit)
    if not runtime then return nil end
    local ok, state = pcall(runtime.get_state, unit)
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

function Mgr:set_focus(fish, player, ranked)
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
        local state = runtime.get_state(unit)
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

function Mgr:select(fish, candidates)
    local ranked = self.Policy.order(candidates)
    self:set_focus(fish, ranked[1] and ranked[1].player or nil, ranked)
    return ranked
end

function Mgr:Start() end

return Mgr
