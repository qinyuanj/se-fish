local Epoch = require("common.packages.spoke.runtime.epoch")

---@alias Spoke.LambdaInitFn fun(s: Spoke.EpochBuilder): Spoke.EpochTickFn?

---@class Spoke.LambdaEpoch: Spoke.Epoch
---@field package _init_fn Spoke.LambdaInitFn

---@class Spoke.LambdaEpochClass
local LambdaEpoch = Epoch.extend("LambdaEpoch", {
  ---@param self Spoke.LambdaEpoch
  ---@param init_fn Spoke.LambdaInitFn
  constructor = function(self, init_fn)
    self._init_fn = init_fn
  end,

  ---@param self Spoke.LambdaEpoch
  ---@param s Spoke.EpochBuilder
  ---@return Spoke.EpochTickFn?
  init = function(self, s)
    return self._init_fn(s)
  end,
})

local raw_new = (LambdaEpoch --[[@as table]]).new

---@overload fun(name: string, init_fn: Spoke.LambdaInitFn): Spoke.LambdaEpoch
---@overload fun(init_fn: Spoke.LambdaInitFn): Spoke.LambdaEpoch
---@param ... any
---@return Spoke.LambdaEpoch
function LambdaEpoch.new(...)
  return raw_new(...)
end

return LambdaEpoch
