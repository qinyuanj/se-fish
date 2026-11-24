local SpokeException = require("common.packages.spoke.runtime.spoke_exception")
local EpochFrame = require("common.packages.spoke.runtime.epoch_frame")

local TreeFlush = {}

local function identity(value)
  return value
end

local function halt(tree, fault, message)
  tree.fault = fault
  tree:_clear_pending()
  tree:_log_error(message, fault)
end

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
