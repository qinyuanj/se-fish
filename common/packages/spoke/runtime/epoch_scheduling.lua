local SpokeRuntime = require("common.packages.spoke.runtime.spoke_runtime")

local EpochScheduling = {}

local function is_inert(epoch)
  return epoch.is_detached or epoch._detaching or epoch.fault
end

local function can_request_tick(epoch)
  return not is_inert(epoch)
    and not epoch._detach_requested
    and not epoch._is_pending
end

local function is_scheduler(target)
  return target ~= nil and type(target._schedule) == "function"
end

local function route(epoch)
  if is_scheduler(epoch._ticker) then
    epoch._ticker:_schedule(epoch)
  elseif epoch._is_tree then
    if not epoch._is_manual then
      SpokeRuntime.schedule(epoch)
    end
  elseif is_scheduler(epoch._tree) then
    epoch._tree:_schedule(epoch)
  end
end

function EpochScheduling.make_request_tick(epoch)
  return function()
    if not can_request_tick(epoch) then
      return
    end
    epoch._is_pending = true
    route(epoch)
  end
end

return EpochScheduling
