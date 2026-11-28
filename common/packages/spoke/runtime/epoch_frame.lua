local SpokeException = require("common.packages.spoke.runtime.spoke_exception")
local SpokeRuntime = require("common.packages.spoke.runtime.spoke_runtime")
local EpochBuilder = require("common.packages.spoke.runtime.epoch_builder")

---@class Spoke.EpochFrame
local EpochFrame = {}

---@generic T
---@param value T
---@return T
local function identity_error(value)
  return value
end

---@param epoch Spoke.Epoch
---@param phase string
---@param error_value any
---@return Spoke.SpokeException
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

---@param epoch Spoke.EpochInternal
---@param phase Spoke.FrameKind
---@param body fun(builder: Spoke.EpochBuilderInternal, arg?: any): any
---@param arg? any
---@return boolean ok
---@return any result
---@return Spoke.FrameHandle frame
function EpochFrame.run(epoch, phase, body, arg)
  local depth = epoch._frame_depth + 1
  epoch._frame_depth = depth
  local reuse = depth == 1 and epoch._reusable_handle or nil
  local frame = SpokeRuntime.push({
    type = phase,
    epoch = epoch,
  }, reuse)
  if depth == 1 and reuse == nil then
    epoch._reusable_handle = frame
  end
  epoch._frame_handle = frame
  local builder = EpochBuilder.new(epoch, frame)
  local ok, result = xpcall(body, identity_error, builder, arg)
  builder._active = false
  if epoch._is_ticker and phase == "Tick" then
    epoch._is_ticking = false
  end
  epoch._frame_depth = depth - 1
  return ok, result, frame
end

---@param epoch Spoke.EpochInternal
---@param frame Spoke.FrameHandle
---@return boolean
function EpochFrame.settle_detach_request(epoch, frame)
  if not epoch._detach_requested or epoch._frame_depth > 0 then
    return false
  end
  frame:on_pop_self(function()
    epoch:_perform_detach()
  end)
  return true
end

---@param epoch Spoke.EpochInternal
---@param phase string
---@param frame Spoke.FrameHandle
---@param error_value any
function EpochFrame.fail(epoch, phase, frame, error_value)
  epoch.fault = EpochFrame.wrap_fault(epoch, phase, error_value)
  EpochFrame.settle_detach_request(epoch, frame)
  SpokeRuntime.pop()
  error(epoch.fault, 0)
end

return EpochFrame
