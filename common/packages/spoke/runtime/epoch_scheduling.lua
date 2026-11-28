local SpokeRuntime = require("common.packages.spoke.runtime.spoke_runtime")

---@class Spoke.EpochScheduling
local EpochScheduling = {}

---@param epoch Spoke.EpochInternal
---@return boolean
local function is_inert(epoch)
  return epoch.is_detached or epoch._detaching or epoch.fault ~= nil
end

---@param epoch Spoke.EpochInternal
---@return boolean
local function can_request_tick(epoch)
  return not is_inert(epoch)
    and not epoch._detach_requested
    and not epoch._is_pending
end

---@param target any
---@return boolean
local function is_scheduler(target)
  return target ~= nil and type(target._schedule) == "function"
end

---@param epoch Spoke.EpochInternal
local function route(epoch)
  local ticker = epoch._ticker
  if ticker and is_scheduler(ticker) then
    ticker:_schedule(epoch)
  elseif epoch._is_tree then
    if not epoch._is_manual then
      ---@cast epoch Spoke.SpokeTreeInternal
      SpokeRuntime.schedule(epoch)
    end
  elseif is_scheduler(epoch._tree) then
    (epoch._tree --[[@as Spoke.TickerInternal]]):_schedule(epoch)
  end
end

---@param epoch Spoke.EpochInternal
---@return fun()
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
