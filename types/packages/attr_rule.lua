---@meta server.packages.attr_rule.api
-- 属性规则包服务端公开契约声明（仅类型）。

---@class AttrRuleAPI
local M = {}

---@type table<string, any>
M.Enums = {}

---@type { AttrUnit: table, AttrBuffUnit: table }
M.Prefabs = {}

---@class AttrRuleFuncs
M.Funcs = {}

---@param attrKey string
---@return table?
function M.Funcs.GetAttrConfig(attrKey) end

---@return table<string, table>
function M.Funcs.GetAllAttrConfigs() end

---@param attrKey string
---@return string?
function M.Funcs.GetAttrIcon(attrKey) end

---@param targetUnit any
---@return any
function M.Funcs.GetAttrUnit(targetUnit) end

---@param targetUnit any
---@param attrKey string
---@return number
function M.Funcs.GetAttr(targetUnit, attrKey) end

---@param targetUnit any
---@param attrKey string
---@param attrComponentType any
---@return number
function M.Funcs.GetAttrComponent(targetUnit, attrKey, attrComponentType) end

---@param targetUnit any
---@param attrKey string
---@param attrComponentType any
---@param value number
---@return boolean, string?
function M.Funcs.SetAttrComponent(targetUnit, attrKey, attrComponentType, value) end

---@param targetUnit any
---@param attrBuffConfigs table[]
---@return integer?, string?
function M.Funcs.AddAttrBuff(targetUnit, attrBuffConfigs) end

---@param targetUnit any
---@param attrBuffId integer
---@return boolean, string?
function M.Funcs.RemoveAttrBuff(targetUnit, attrBuffId) end

---@param attrUnit any
---@param config? table
---@return boolean, string?
function M.Funcs.InitAttrUnit(attrUnit, config) end

---@param targetUnit any
---@return any, string?
function M.Funcs.EnsureAttrUnit(targetUnit) end

---@param unit any
---@return any
function M.Funcs.GetAttrBuffUnit(unit) end

---@param buffUnit any
---@return any
function M.Funcs.GetAttrBuffTargetUnit(buffUnit) end

---@param buffUnit any
---@param targetUnit any
---@return boolean, string?
function M.Funcs.SetAttrBuffTargetUnit(buffUnit, targetUnit) end

---@param buffUnit any
---@param config? table
---@return boolean, string?
function M.Funcs.InitAttrBuffUnit(buffUnit, config) end

return M
