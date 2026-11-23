local Computation = require("common.packages.spoke.reactive.computation")
local EffectBuilder = require("common.packages.spoke.reactive.effect_builder")

local collect_triggers = Computation._collect_triggers

local Phase = Computation.extend("Phase", {
  constructor = function(self, mount_when, block, ...)
    local normalized = collect_triggers(...)
    local triggers = {}
    for index = 1, #(normalized or {}) do
      triggers[index] = normalized[index]
    end
    triggers[#triggers + 1] = mount_when
    Computation.constructor(self, triggers)
    self._mount_when = mount_when
    self._block = block
  end,

  on_run = function(self, s)
    if self._mount_when:now() then
      local builder = EffectBuilder.new(function(signal)
        self:_add_dynamic_trigger(signal)
      end, s)
      if self._block ~= nil then
        self._block(builder)
      end
    end
  end,
})

return Phase
