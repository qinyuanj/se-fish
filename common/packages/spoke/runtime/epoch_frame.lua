local SpokeException = require("common.packages.spoke.runtime.spoke_exception")
local SpokeRuntime = require("common.packages.spoke.runtime.spoke_runtime")
local EpochBuilder = require("common.packages.spoke.runtime.epoch_builder")

local EpochFrame = {}

local function identity_error(value)
  return value
end

function EpochFrame.wrap_fault(epoch, phase, error_value)
  if SpokeException.is(error_value) then
    return error_value
  end
  return SpokeException.new(
    "Uncaught Exception in " .. phase,
    error_value,
    epoch,
    phase,
    SpokeRuntime.snapshot_frames())
end

function EpochFrame.run(epoch, phase, body)
  epoch._frame_depth = epoch._frame_depth + 1
  local frame = SpokeRuntime.push({
    type = phase,
    epoch = epoch,
    phase = phase,
  })
  epoch._frame_handle = frame
  local builder = EpochBuilder.new(epoch, frame)
  local ok, result = xpcall(function()
    return body(builder)
  end, identity_error)
  builder._active = false
  if epoch._is_ticker and phase == "Tick" then
    epoch._is_ticking = false
  end
  epoch._frame_depth = epoch._frame_depth - 1
  return ok, result, frame
end

function EpochFrame.settle_detach_request(epoch, frame)
  if not epoch._detach_requested then
    return false
  end
  epoch._detach_requested = false
  frame:on_pop_self(function()
    epoch:_perform_detach()
  end)
  return true
end

function EpochFrame.fail(epoch, phase, frame, error_value)
  epoch.fault = EpochFrame.wrap_fault(epoch, phase, error_value)
  EpochFrame.settle_detach_request(epoch, frame)
  SpokeRuntime.pop()
  error(epoch.fault, 0)
end

return EpochFrame
