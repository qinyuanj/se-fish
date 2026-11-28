local Computation = require("common.packages.spoke.reactive.computation")
local EffectBuilder = require("common.packages.spoke.reactive.effect_builder")

local collect_triggers = Computation._collect_triggers

---@class Spoke.Reaction: Spoke.Computation
---@field package _block (fun(s: Spoke.EffectBuilder))?

---@class Spoke.ReactionClass
local Reaction = Computation.extend("Reaction", {
  auto_arm_tick_after_init = false,

  ---@param self Spoke.Reaction
  ---@param block? fun(s: Spoke.EffectBuilder)
  ---@param ... Spoke.TriggerList
  constructor = function(self, block, ...)
    local triggers = collect_triggers(...)
    Computation.constructor(self, triggers)
    self._block = block
  end,

  ---@param self Spoke.Reaction
  ---@param s Spoke.EpochBuilder
  on_run = function(self, s)
    if self._block ~= nil then
      self._block(EffectBuilder.new(self._add_dynamic_fn, s))
    end
  end,
})

local raw_new = (Reaction --[[@as table]]).new

---@overload fun(name: string, block?: fun(s: Spoke.EffectBuilder), ...: Spoke.TriggerList): Spoke.Reaction
---@overload fun(block?: fun(s: Spoke.EffectBuilder), ...: Spoke.TriggerList): Spoke.Reaction
---@param ... any
---@return Spoke.Reaction
function Reaction.new(...)
  return raw_new(...)
end

return Reaction
