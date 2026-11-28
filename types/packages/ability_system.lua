---@meta server.packages.ability_system.api
-- 技能系统服务端公开契约声明（仅类型）。

---@class AbilityServerAPI
local M = {}

---@param unit any
---@return any
function M.GetManagerForUnit(unit) end

---@param unit any
---@param abilityKey string
---@param slotIndex? integer
---@return any, string?
function M.AddAbility(unit, abilityKey, slotIndex) end

---@param unit any
---@param abilityIndex integer
---@return any
function M.GetAbility(unit, abilityIndex) end

---@param abilityScript any
---@return any
function M.GetAbilityByScript(abilityScript) end

---@param unit any
---@param abilityIndex integer
---@param releasePoint? any
---@param releaseDir? any
---@param releaseTarget? any
---@param fromClient? boolean
---@return boolean
function M.CastAbility(unit, abilityIndex, releasePoint, releaseDir, releaseTarget, fromClient) end

---@param unit any
---@param abilityIndex integer
---@return boolean
function M.StopAbility(unit, abilityIndex) end

---@param unit any
---@param abilityIndex integer
---@return boolean
function M.AccumulateAbility(unit, abilityIndex) end

---@param unit any
---@param parentSlotIndex integer
---@return boolean
function M.SwitchNextAbility(unit, parentSlotIndex) end

---@param abilityScript any
---@return boolean
function M.SwitchToParent(abilityScript) end

---@param abilityScript any
---@param childIndex integer
---@return boolean
function M.SwitchToChild(abilityScript, childIndex) end

---@param abilityScript any
---@return boolean
function M.SwitchAbilityNext(abilityScript) end

---@param unit any
---@param ability any
---@param slotIndex integer
---@return boolean
function M.SetAbilityToSlot(unit, ability, slotIndex) end

---@param unit any
---@param ability any
---@param slotIndex integer
---@return boolean
function M.ReplaceAbility(unit, ability, slotIndex) end

---@param unit any
---@param abilityKey string
---@return boolean
function M.RemoveAbilityByKey(unit, abilityKey) end

---@param unit any
---@param slotIndex integer
---@return boolean
function M.RemoveAbility(unit, slotIndex) end

---@param abilityScript any
---@return boolean
function M.RemoveAbilityEntity(abilityScript) end

---@param unit any
---@return any[]
function M.GetAbilities(unit) end

---@param unit any
---@param abilityKey string
---@return any
function M.GetAbilityByKey(unit, abilityKey) end

---@param unit any
---@param startIndex integer
---@param endIndex integer
---@return any[]
function M.GetAbilitiesFromIndexRange(unit, startIndex, endIndex) end

---@param marker any
---@param unit any
---@param ability any
---@param duration? number
---@param grayout? boolean
---@param recoverAfterCast? boolean
---@return boolean
function M.DisableAbility(marker, unit, ability, duration, grayout, recoverAfterCast) end

---@param marker any
---@param unit any
---@param ability any
---@return boolean
function M.EnableAbility(marker, unit, ability) end

function M.RegisterEvents() end

return M
