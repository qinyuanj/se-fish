---@meta server.packages.modifier_system.api
-- 效果系统包服务端公开契约声明（仅类型）。

---@class ModifierSystemAPI
local M = {}

---@type { CreateResult: table<string, string> }
M.Enums = {}

---@param ownerUnit any
---@param assetId string
---@param addConfig? table
---@return string
function M.AddModifier(ownerUnit, assetId, addConfig) end

---@param modifierUnit any
---@return boolean
function M.RemoveModifier(modifierUnit) end

---@param ownerUnit any
---@param modifierKey? string
---@return number
function M.ClearUnitModifiers(ownerUnit, modifierKey) end

---@param ownerUnit any
---@param modifierKey? string
---@return any[]
function M.GetUnitModifiers(ownerUnit, modifierKey) end

---@param ownerUnit any
---@param modifierKey? string
---@return boolean
function M.IsInModifier(ownerUnit, modifierKey) end

---@param modifierUnit any
---@param count number
---@return boolean
function M.SetModifierStackCount(modifierUnit, count) end

---@param modifierUnit any
---@param delta number
---@return number
function M.AddModifierStackCount(modifierUnit, delta) end

---@param modifierUnit any
---@param extra number
---@return boolean
function M.AddModifierDurationByInstance(modifierUnit, extra) end

---@param modifierUnit any
---@param remaining number
---@return boolean
function M.SetModifierRemainTime(modifierUnit, remaining) end

---@param modifierUnit any
---@return any
function M.GetModifierOwner(modifierUnit) end

---@param ownerUnit any
---@param modifierKey string
---@param unitId? number
---@return boolean
function M.Pause(ownerUnit, modifierKey, unitId) end

---@param ownerUnit any
---@param modifierKey string
---@param unitId? number
---@return boolean
function M.Resume(ownerUnit, modifierKey, unitId) end

---@param ownerUnit any
---@param interrupt boolean
---@return boolean
function M.SetInterruptModifierObtain(ownerUnit, interrupt) end

---@param ownerUnit any
---@param modifierKey string
---@return number
function M.GetRemainingTimeByKey(ownerUnit, modifierKey) end

---@param ownerUnit any
---@param modifierKey string
---@return any
function M.GetSourceByKey(ownerUnit, modifierKey) end

return M
