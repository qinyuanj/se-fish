---@meta client.packages.ability_system.api
-- 技能系统客户端公开契约声明（仅类型）。

---@class AbilityClientAPI
local M = {}

---@param unit any
---@return any
function M.GetManagerForUnit(unit) end

---@param unit any
---@param abilityIndex integer
---@return any
function M.GetAbility(unit, abilityIndex) end

---@param manager any
---@param abilityIndex integer
---@param releasePoint? any
---@param releaseDir? any
---@param releaseTarget? any
function M.RequestCast(manager, abilityIndex, releasePoint, releaseDir, releaseTarget) end

---@param manager any
---@param abilityIndex integer
function M.RequestStop(manager, abilityIndex) end

---@param manager any
---@param parentSlotIndex integer
function M.RequestSwitchNext(manager, parentSlotIndex) end

---@param manager any
---@param abilityIndex integer
function M.RequestAccumulate(manager, abilityIndex) end

---@return any
function M.GetUIManager() end

---@param domain string
---@param key string
---@param value any
function M.Register(domain, key, value) end

function M.StartClientLifecycle() end

return M
