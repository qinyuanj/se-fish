local Computation = require("common.packages.spoke.reactive.computation")
local EffectBuilder = require("common.packages.spoke.reactive.effect_builder")

local Reaction = Computation.extend("Reaction", {
  auto_arm_tick_after_init = false,

  constructor = function(self, block, triggers)
    Computation.constructor(self, triggers)
    self._block = block
  end,

  on_run = function(self, s)
    if self._block ~= nil then
      self._block(EffectBuilder.new(function(signal)
        self:_add_dynamic_trigger(signal)
      end, s))
    end
  end,
})

return Reaction
