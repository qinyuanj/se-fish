local Computation = require("common.packages.spoke.reactive.computation")
local State = require("common.packages.spoke.reactive.state")
local EffectBuilder = require("common.packages.spoke.reactive.effect_builder")

local MemoBuilder = EffectBuilder.MemoBuilder

local collect_triggers = Computation._collect_triggers

---@alias Spoke.MemoSelector<T> fun(s: Spoke.MemoBuilder): T

---@class Spoke.Memo<T>: Spoke.Computation, Spoke.Signal<T>
---@field now fun(self: Spoke.Memo<T>): T
---@field subscribe fun(self: Spoke.Memo<T>, fn: fun(value: T)): Spoke.SpokeHandle
---@field unsubscribe fun(self: Spoke.Memo<T>, fn: fun(value: T))

---@class Spoke.MemoClass
local Memo = Computation.extend("Memo", {
  ---@param self Spoke.MemoImpl
  ---@param selector? Spoke.MemoSelector<any>
  ---@param ... Spoke.TriggerList
  constructor = function(self, selector, ...)
    if selector ~= nil and type(selector) ~= "function" then
      error("Memo selector must be a function", 2)
    end
    local triggers = collect_triggers(...)
    Computation.constructor(self, triggers)
    self._selector = selector
    self._state = State.new()
  end,

  ---@param self Spoke.MemoImpl
  ---@param s Spoke.EpochBuilder
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

local raw_new = (Memo --[[@as table]]).new

---@generic T
---@overload fun(name: string, selector: Spoke.MemoSelector<T>, ...: Spoke.TriggerList): Spoke.Memo<T>
---@overload fun(selector: Spoke.MemoSelector<T>, ...: Spoke.TriggerList): Spoke.Memo<T>
---@overload fun(name: string, selector: nil, ...: Spoke.TriggerList): Spoke.Memo<nil>
---@overload fun(selector?: nil, ...: Spoke.TriggerList): Spoke.Memo<nil>
---@param ... any
---@return Spoke.Memo<any>
function Memo.new(...)
  return raw_new(...)
end

---@class Spoke.MemoImpl: Spoke.Memo<any>
---@field package _selector Spoke.MemoSelector<any>?
---@field package _state Spoke.State<any>
local methods = Memo --[[@as table]]

function methods:now()
  return self._state:now()
end

function methods:subscribe(fn)
  return self._state:subscribe(fn)
end

function methods:unsubscribe(fn)
  self._state:unsubscribe(fn)
end

return Memo
