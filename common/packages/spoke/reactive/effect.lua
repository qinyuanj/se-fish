local Computation = require("common.packages.spoke.reactive.computation")
local EffectBuilder = require("common.packages.spoke.reactive.effect_builder")
local LambdaEpoch = require("common.packages.spoke.runtime.lambda_epoch")
local State = require("common.packages.spoke.reactive.state")

local function is_signal(value)
  return type(value) == "table"
    and type(value.now) == "function"
    and type(value.subscribe) == "function"
    and type(value.unsubscribe) == "function"
end

local Effect = Computation.extend("Effect", {
  constructor = function(self, block, triggers)
    if block ~= nil and type(block) ~= "function" then
      error("Effect.new expects a block function", 2)
    end
    Computation.constructor(self, triggers)
    self._block = block
    self._output_state = State.new()
    self._was_signal = false
  end,

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

function Effect:now()
  return self._output_state:now()
end

function Effect:subscribe(fn)
  return self._output_state:subscribe(fn)
end

function Effect:unsubscribe(fn)
  return self._output_state:unsubscribe(fn)
end

return Effect
