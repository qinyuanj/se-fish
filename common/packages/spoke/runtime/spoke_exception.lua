local SpokeIntrospect = require("common.packages.spoke.runtime.spoke_introspect")

---@class Spoke.SpokeException
---@field message string
---@field cause any
---@field inner any
---@field epoch Spoke.Epoch?
---@field phase string?
---@field stack_snapshot Spoke.Frame[]
---@field stack Spoke.Frame[]
---@field traceback string?
local SpokeException = {}
SpokeException.__index = SpokeException

---@param message string
---@param cause any
---@param epoch? Spoke.Epoch
---@param phase? string
---@param stack_snapshot? Spoke.Frame[]
---@return Spoke.SpokeException
function SpokeException.new(message, cause, epoch, phase, stack_snapshot)
  stack_snapshot = stack_snapshot or {
    {
      epoch = epoch,
      type = phase,
      phase = phase,
    },
  }
  local capture = type(debug) == "table" and debug.traceback or traceback
  local stack_trace = type(capture) == "function" and capture("", 3) or nil
  return setmetatable({
    message = message,
    cause = cause,
    inner = cause,
    epoch = epoch,
    phase = phase,
    stack_snapshot = stack_snapshot,
    stack = stack_snapshot,
    traceback = stack_trace,
  }, SpokeException)
end

---@param value any
---@return boolean
function SpokeException.is(value)
  return type(value) == "table" and getmetatable(value) == SpokeException
end

---@return string
function SpokeException:__tostring()
  return SpokeIntrospect.tree_trace(self.stack_snapshot or {})
    .. "\n" .. tostring(self.cause)
end

return SpokeException
