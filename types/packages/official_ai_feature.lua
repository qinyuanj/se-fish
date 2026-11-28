---@meta server.packages.official_ai_feature.api
-- 生物 AI 包服务端公开契约声明（仅类型）。

---@class OfficialAIFeatureAPI
local M = {}

---@type table<string, any>
M.Configs = {}

---@class OfficialAIFeatureFuncs
M.Funcs = {}

---@param unit any
function M.Funcs.StartAI(unit) end

---@param unit any
function M.Funcs.StopAI(unit) end

---@param unit any
function M.Funcs.Roll(unit) end

---@param unit any
function M.Funcs.Rush(unit) end

---@param unit any
function M.Funcs.Jump(unit) end

---@param unit any
function M.Funcs.Lift(unit) end

---@param unit any
---@param direction any
---@param hateTime number
---@param autoObstacle any
function M.Funcs.MoveDirection(unit, direction, hateTime, autoObstacle) end

---@param unit any
---@param targetPos any
---@param hateTime number
---@param toleranceDis number
---@param autoObstacle any
function M.Funcs.MoveToPos(unit, targetPos, hateTime, toleranceDis, autoObstacle) end

---@param unit any
---@param duration number
function M.Funcs.StopMove(unit, duration) end

---@param unit any
---@param continuousSec number
---@param followTarget any
---@param followDis number
---@param tolerateDis number
function M.Funcs.Follow(unit, continuousSec, followTarget, followDis, tolerateDis) end

---@param unit any
---@param continuousSec number
---@param keepPos any
---@param keepPosRotation? any
---@param delayTime? number
---@param tolerateDis? number
function M.Funcs.Alert(unit, continuousSec, keepPos, keepPosRotation, delayTime, tolerateDis) end

---@param unit any
---@param imitateTarget any
---@param continuousSec number
function M.Funcs.Imitate(unit, imitateTarget, continuousSec) end

---@param unit any
---@param ... any
function M.Funcs.SearchEnemy(unit, ...) end

---@param unit any
---@param ... any
function M.Funcs.ChaseTarget(unit, ...) end

---@param unit any
---@param ... any
function M.Funcs.Nav(unit, ...) end

---@param unit any
---@param ... any
function M.Funcs.BasicCommand(unit, ...) end

---@param unit any
---@param ... any
function M.Funcs.CastAbility(unit, ...) end

---@param unit any
---@param ... any
function M.Funcs.CastAbilityByKey(unit, ...) end

---@param unit any
---@param ... any
function M.Funcs.ExecuteCareerSkill(unit, ...) end

---@param unit any
---@param ... any
function M.Funcs.AddAbilityToSlot(unit, ...) end

---@param unit any
---@param ... any
function M.Funcs.SetSearchEnemyPriorityMode(unit, ...) end

---@param unit any
---@param ... any
function M.Funcs.SetSearchEnemyPriorityValue(unit, ...) end

---@param unit any
---@param ... any
function M.Funcs.SetSearchEnemyFocusTarget(unit, ...) end

---@param unit any
---@param ... any
function M.Funcs.SetMoveThreshold(unit, ...) end

return M
