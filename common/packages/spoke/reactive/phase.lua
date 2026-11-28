local Computation = require("common.packages.spoke.reactive.computation")
local EffectBuilder = require("common.packages.spoke.reactive.effect_builder")

local collect_triggers = Computation._collect_triggers

---@class Spoke.Phase: Spoke.Computation
---@field package _mount_when Spoke.Signal<boolean>
---@field package _block (fun(s: Spoke.EffectBuilder))?

---@class Spoke.PhaseClass
local Phase = Computation.extend("Phase", {
  ---@param self Spoke.Phase
  ---@param mount_when Spoke.Signal<boolean>
  ---@param block? fun(s: Spoke.EffectBuilder)
  ---@param ... Spoke.TriggerList
  constructor = function(self, mount_when, block, ...)
    local triggers = collect_triggers(...)
    Computation.constructor(self, triggers)
    self._mount_when = mount_when
    self._block = block
  end,

  ---@param self Spoke.Phase
  ---@param s Spoke.EpochBuilder
  ---@return Spoke.EpochTickFn?
  init = function(self, s)
    local tick_fn = Computation.init(self, s)
    self:_add_static_trigger(self._mount_when)
    return tick_fn
  end,

  ---@param self Spoke.Phase
  ---@param s Spoke.EpochBuilder
  on_run = function(self, s)
    if self._mount_when:now() and self._block ~= nil then
      self._block(EffectBuilder.new(self._add_dynamic_fn, s))
    end
  end,
})

local raw_new = (Phase --[[@as table]]).new

---@overload fun(name: string, mount_when: Spoke.Signal<boolean>, block?: fun(s: Spoke.EffectBuilder), ...: Spoke.TriggerList): Spoke.Phase
---@overload fun(mount_when: Spoke.Signal<boolean>, block?: fun(s: Spoke.EffectBuilder), ...: Spoke.TriggerList): Spoke.Phase
---@param ... any
---@return Spoke.Phase
function Phase.new(...)
  return raw_new(...)
end

return Phase
