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

---@class Spoke.EffectImpl: Spoke.Effect<any>
---@field package _block Spoke.EffectBlock?
---@field package _output_state Spoke.State<any>?
---@field package _current_signal Spoke.Signal<any>?
---@field package _forward_output (fun(value: any))?
---@field package _deferred_init Spoke.LambdaInitFn?

---@param self Spoke.EffectImpl
---@return Spoke.State<any>
local function ensure_output_state(self)
  local state = self._output_state
  if state == nil then
    state = State.new()
    self._output_state = state
    self._forward_output = function(value)
      state:set(value)
    end
    local sync_tick = function()
      local current = self._current_signal
      state:set(current ~= nil and current:now() or nil)
    end
    self._deferred_init = function()
      return sync_tick
    end
  end
  return state
end

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
    self._output_state = nil
    self._current_signal = nil
    self._forward_output = nil
    self._deferred_init = nil
  end,

  ---@param self Spoke.EffectImpl
  ---@param s Spoke.EpochBuilder
  on_run = function(self, s)
    if self._block == nil then
      return
    end
    self._current_signal = nil
    local builder = EffectBuilder.new(self._add_dynamic_fn, s)
    local result = self._block(builder)

    if is_signal(result) then
      ensure_output_state(self)
      self._current_signal = result
      builder:subscribe(result, self._forward_output --[[@as fun(value: any)]])
      builder:call(LambdaEpoch.new("Deferred Initializer", self._deferred_init --[[@as Spoke.LambdaInitFn]]))
    else
      local state = self._output_state
      if state ~= nil and state:now() ~= nil then
        builder:call(LambdaEpoch.new("Deferred Initializer", self._deferred_init --[[@as Spoke.LambdaInitFn]]))
      end
    end
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

local methods = Effect --[[@as Spoke.EffectImpl]]

function methods:now()
  local state = self._output_state
  if state == nil then
    return nil
  end
  return state:now()
end

function methods:subscribe(fn)
  return ensure_output_state(self):subscribe(fn)
end

function methods:unsubscribe(fn)
  if type(fn) ~= "function" then
    error("Trigger.unsubscribe expects a function", 2)
  end
  local state = self._output_state
  if state ~= nil then
    state:unsubscribe(fn)
  end
end

return Effect
