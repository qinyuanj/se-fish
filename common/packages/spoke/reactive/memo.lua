local Computation = require("common.packages.spoke.reactive.computation")
local State = require("common.packages.spoke.reactive.state")
local EffectBuilder = require("common.packages.spoke.reactive.effect_builder")

local MemoBuilder = EffectBuilder.MemoBuilder

local collect_triggers = Computation._collect_triggers

local Memo = Computation.extend("Memo", {
  constructor = function(self, selector, ...)
    if selector ~= nil and type(selector) ~= "function" then
      error("Memo selector must be a function", 2)
    end
    local triggers = collect_triggers(...)
    Computation.constructor(self, triggers)
    self._selector = selector
    self._state = State.new()
  end,

  on_run = function(self, s)
    if self._selector == nil then
      return
    end
    local builder = MemoBuilder.new(function(signal)
      self:_add_dynamic_trigger(signal)
    end, s)
    self._state:set(self._selector(builder))
  end,
})

function Memo:now()
  return self._state:now()
end

function Memo:subscribe(fn)
  return self._state:subscribe(fn)
end

function Memo:unsubscribe(fn)
  self._state:unsubscribe(fn)
end

return Memo
