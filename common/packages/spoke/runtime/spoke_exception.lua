local SpokeIntrospect = require("common.packages.spoke.runtime.spoke_introspect")

local SpokeException = {}
SpokeException.__index = SpokeException

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

function SpokeException.is(value)
  return type(value) == "table" and getmetatable(value) == SpokeException
end

function SpokeException:__tostring()
  return SpokeIntrospect.tree_trace(self.stack_snapshot or {})
    .. "\n" .. tostring(self.cause)
end

return SpokeException
