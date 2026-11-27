local GameCfg = require('common.game_cfg')
local Policy = require('common.ai_target_policy')

local Mgr = { policy = Policy }

local function logFailure(operation, fish, unit, player, err)
    print(string.format('[FishAiTarget] operation=%s fish=%s unit=%s player=%s error=%s',
        operation, tostring(fish and fish.Id or '-'), tostring(unit and unit.UnitId or '-'),
        tostring(player and player.UserId or '-'), tostring(err)))
end

-- 官方 AI 包的两个入口模块：加载失败只记录、不缓存失败（下次调用重试），成功后按 key 缓存。
local MODULES = {
    api = { name = 'server.packages.official_ai_feature.api', operation = 'RequireOfficialAPI' },
    runtime = { name = 'server.packages.official_ai_feature.behavior_runtime', operation = 'RequireOfficialRuntime' },
}
local loaded_modules = {}

local function load_module(key, fish, unit)
    local module = loaded_modules[key]
    if module == nil then
        local entry = MODULES[key]
        local ok, required = pcall(require, entry.name)
        if not ok then
            logFailure(entry.operation, fish, unit, nil, required)
            return nil
        end
        module = required
        loaded_modules[key] = module
    end
    return module
end

local function receiver(fish)
    local carrier = fish and fish.carrier
    return carrier and carrier.receiver or nil
end

function Mgr:state(fish)
    local unit = receiver(fish)
    if not unit then
        logFailure('ReadOfficialState', fish, nil, nil, 'official AI receiver unavailable')
        return nil
    end
    local runtime = load_module('runtime', fish, unit)
    if not runtime then return nil end
    local ok, state = pcall(runtime.getState, unit)
    if not ok then
        logFailure('ReadOfficialState', fish, unit, nil, state)
        return nil
    end
    return state
end

function Mgr:focus(fish)
    local state = self:state(fish)
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
    local apiTable, runtime = load_module('api', fish, unit), load_module('runtime', fish, unit)
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

function Mgr:select(fish, candidates)
    local ranked = self.policy.order(candidates)
    self:set_focus(fish, ranked[1] and ranked[1].player or nil, ranked)
    return ranked
end

function Mgr:start() end

return Mgr
