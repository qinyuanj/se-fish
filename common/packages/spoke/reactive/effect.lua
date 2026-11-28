local Computation = require("common.packages.spoke.reactive.computation")
local EffectBuilder = require("common.packages.spoke.reactive.effect_builder")
local LambdaEpoch = require("common.packages.spoke.runtime.lambda_epoch")
local State = require("common.packages.spoke.reactive.state")

---@param value any
---@return boolean
local function is_signal(value)
  return type(value) == "table"
    and type(value.now) == "function"
    and type(value.subscribe) == "function"
    and type(value.unsubscribe) == "function"
end

local collect_triggers = Computation._collect_triggers

---@alias Spoke.EffectBlock fun(s: Spoke.EffectBuilder): any

---@class Spoke.Effect<T>: Spoke.Computation, Spoke.Signal<T>
---@field now fun(self: Spoke.Effect<T>): T
---@field subscribe fun(self: Spoke.Effect<T>, fn: fun(value: T)): Spoke.SpokeHandle
---@field unsubscribe fun(self: Spoke.Effect<T>, fn: fun(value: T))

---@class Spoke.EffectClass
local Effect = Computation.extend("Effect", {
  ---@param self Spoke.EffectImpl
  ---@param block? Spoke.EffectBlock
  ---@param ... Spoke.TriggerList
  constructor = function(self, block, ...)
    if block ~= nil and type(block) ~= "function" then
      error("Effect.new expects a block function", 2)
    end
    local triggers = collect_triggers(...)
    Computation.constructor(self, triggers)
    self._block = block
    self._output_state = State.new()
    self._was_signal = false
  end,

  ---@param self Spoke.EffectImpl
  ---@param s Spoke.EpochBuilder
  on_run = function(self, s)
    if self._block == nil then
      return
    end
    local builder = EffectBuilder.new(function(signal)
      self:_add_dynamic_trigger(signal)
    end, s)

    local result = self._block(builder)

    local result_is_signal = is_signal(result)
    if result_is_signal then
      builder:subscribe(result, function(value)
        self._output_state:set(value)
      end)
      builder:call(LambdaEpoch.new("Deferred Initializer", function()
        return function()
          self._output_state:set(result:now())
        end
      end))
    elseif self._was_signal then
      builder:call(LambdaEpoch.new("Deferred Initializer", function()
        return function()
          self._output_state:set(nil)
        end
      end))
    end
    self._was_signal = self._was_signal or result_is_signal
  end,
})

local raw_new = (Effect --[[@as table]]).new

---@generic T
---@overload fun(name: string, block: (fun(s: Spoke.EffectBuilder): Spoke.Signal<T>?), ...: Spoke.TriggerList): Spoke.Effect<T>
---@overload fun(block: (fun(s: Spoke.EffectBuilder): Spoke.Signal<T>?), ...: Spoke.TriggerList): Spoke.Effect<T>
---@overload fun(name: string, block: nil, ...: Spoke.TriggerList): Spoke.Effect<nil>
---@overload fun(block?: nil, ...: Spoke.TriggerList): Spoke.Effect<nil>
---@param ... any
---@return Spoke.Effect<any>
function Effect.new(...)
  return raw_new(...)
end

---@class Spoke.EffectImpl: Spoke.Effect<any>
---@field package _block Spoke.EffectBlock?
---@field package _output_state Spoke.State<any>
---@field package _was_signal boolean
local methods = Effect --[[@as table]]

function methods:now()
  return self._output_state:now()
end

function methods:subscribe(fn)
  return self._output_state:subscribe(fn)
end

function methods:unsubscribe(fn)
  self._output_state:unsubscribe(fn)
end

return Effect
