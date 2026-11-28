local SpokeException = require("common.packages.spoke.runtime.spoke_exception")
local EpochFrame = require("common.packages.spoke.runtime.epoch_frame")

---@class Spoke.TreeFlush
local TreeFlush = {}

---@generic T
---@param value T
---@return T
local function identity(value)
  return value
end

---@param tree Spoke.SpokeTreeInternal
---@param fault Spoke.SpokeException
---@param message string
local function halt(tree, fault, message)
  tree.fault = fault
  tree:_clear_pending()
  tree:_log_error(message, fault)
end

---@param tree Spoke.SpokeTreeInternal
---@param context Spoke.TickContext
---@return boolean
local function tick_once(tree, context)
  local ok, error_value = xpcall(function()
    context:tick_next()
  end, identity)
  if ok then
    return true
  end
  local fault = SpokeException.is(error_value)
    and error_value
    or EpochFrame.wrap_fault(tree, "Tick", error_value)
  halt(tree, fault, "[SpokeTree] flush error")
  return false
end

---@param tree Spoke.SpokeTreeInternal
---@param context Spoke.TickContext
function TreeFlush.drive(tree, context)
  if not tree._command then
    return
  end
  while tree:has_pending() do
    if not tick_once(tree, context) then
      return
    end
    if tree._command == "tick" then
      return
    end
  end
end

return TreeFlush
