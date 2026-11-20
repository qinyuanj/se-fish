-- #260 官方 AI 目标选择适配层（业务侧，只读消费官方包，不修改 packages/）。
-- 官方包 searchEnemy 只按距离最近选目标，且优先级权重/焦点接口在包内标注为预留（当前不参与搜敌）。
-- 因此本适配层是目标选择的唯一裁决处：先按累计有效伤害排序，再把名次与焦点登记到官方 AI 管理器
-- （SetSearchEnemyPriorityMode / SetSearchEnemyPriorityValue / SetSearchEnemyFocusTarget）。
-- 它绝不调用 SearchEnemy / ChaseTarget：那会让官方 AI 同时写 Controller 位移，与自研
-- FishBehaviors / FlightPath 形成双写权威。鱼的移动、飞行与轨迹仍由自研模块拥有。
local GameCfg = require('common.GameCfg')
local Policy = require('common.AiTargetPolicy')

local Mgr = { Policy = Policy }
local AiAPI

local function api()
    if AiAPI == nil then
        -- 大量单测用假 game 加载业务模块；官方包在加载时要引擎服务，故延迟到真正登记时再取。
        local ok, module = pcall(require, 'server.packages.official_ai_feature.api')
        AiAPI = ok and module or false
    end
    return AiAPI or nil
end

local function receiver(fish)
    local carrier = fish and fish.Carrier
    return carrier and carrier.Receiver or nil
end

--- 官方 AI 管理器持有的运行态（只读观察，不在这里另存一份目标）。
function Mgr:State(fish)
    local unit = receiver(fish)
    if not unit then return nil end
    local ok, runtime = pcall(require, 'server.packages.official_ai_feature.behavior_runtime')
    if not ok then return nil end
    return runtime.getState(unit)
end

function Mgr:Focus(fish)
    local state = self:State(fish)
    return state and state.focusTarget or nil
end

--- 把已裁决的目标登记到官方 AI 管理器；失败不影响业务侧目标，只留日志。
function Mgr:SetFocus(fish, player, ranked)
    local unit, apiTable = receiver(fish), api()
    local funcs = apiTable and apiTable.Funcs
    if not unit or not funcs then return false end
    local config = GameCfg.Ability.AiTarget
    local ok, err = pcall(function()
        funcs.SetSearchEnemyPriorityMode(unit, config.PriorityMode)
        for _, row in ipairs(ranked or {}) do
            if row.player.Character then
                -- 包内该接口是预留权重：当前不参与搜敌，但名次仍完整交给官方管理器。
                funcs.SetSearchEnemyPriorityValue(unit, row.player.Character, row.damage)
            end
        end
        funcs.SetSearchEnemyFocusTarget(unit, player and player.Character or nil)
    end)
    if not ok then print('[MgrAiTarget] 官方目标登记失败', tostring(err)) end
    return ok
end

--- 伤害优先裁决：返回名次表（首项即目标），并把裁决交给官方 AI 管理器。
function Mgr:Select(fish, candidates)
    local ranked = self.Policy.Order(candidates)
    self:SetFocus(fish, ranked[1] and ranked[1].player or nil, ranked)
    return ranked
end

function Mgr:Start() end

return Mgr
