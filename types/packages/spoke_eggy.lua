---@meta common.packages.spoke_eggy.api
-- 上游 spoke_eggy 宿主适配包公开契约声明（仅类型）。

---@class SpokeEggyBehaviour
---@field root any
---@field unit any
---@field is_alive any
---@field dispose fun(self: SpokeEggyBehaviour)

---@class SpokeEggyAPI
local M = {}

---@param unit any
---@param init fun(s: any, behaviour: SpokeEggyBehaviour)
---@param options? table
---@return SpokeEggyBehaviour
function M.behaviour(unit, init, options) end

---@param s any
---@param signal any
---@param fn fun(...: any)
---@return any
function M.connect(s, signal, fn) end

return M
