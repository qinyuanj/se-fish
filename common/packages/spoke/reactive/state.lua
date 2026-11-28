local Trigger = require("common.packages.spoke.reactive.trigger")

---@class Spoke.State<T>: Spoke.Signal<T>
---@field name string?
---@field now fun(self: Spoke.State<T>): T
---@field set fun(self: Spoke.State<T>, value: T)
---@field update fun(self: Spoke.State<T>, fn?: fun(current: T): T)
---@field subscribe fun(self: Spoke.State<T>, fn: fun(value: T)): Spoke.SpokeHandle
---@field unsubscribe fun(self: Spoke.State<T>, fn: fun(value: T))

---@class Spoke.StateClass
local State = {}

---@class Spoke.StateImpl: Spoke.State<any>
---@field private _value any
---@field private _trigger Spoke.Trigger<any>
---@field private _equals fun(a: any, b: any): boolean
local methods = State --[[@as table]]
methods.__index = methods

---@param a any
---@param b any
---@return boolean
local function default_equals(a, b)
  return a == b
end

---@param name string?
---@param initial any
---@param equals? fun(a: any, b: any): boolean
---@return Spoke.State<any>
local function make_state(name, initial, equals)
  return setmetatable({
    name = name,
    _value = initial,
    _trigger = Trigger.new(),
    _equals = equals or default_equals,
  }, methods)
end

---@generic T
---@overload fun(): Spoke.State<any>
---@overload fun(initial: T): Spoke.State<T>
---@overload fun(name: string, initial: T, equals?: fun(a: T, b: T): boolean): Spoke.State<T>
---@overload fun(initial: T, equals: fun(a: T, b: T): boolean): Spoke.State<T>
---@param ... any
---@return Spoke.State<any>
function State.new(...)
  local arg_count = select("#", ...)
  local args = { ... }
  local name = nil
  local initial = nil
  local equals = nil

  if arg_count == 0 then
    initial = nil
  elseif arg_count == 1 then
    initial = args[1]
  elseif arg_count >= 2 then
    if type(args[1]) == "string" then
      name = args[1]
      initial = args[2]
      equals = args[3]
    else
      initial = args[1]
      equals = args[2]
    end
  end

  return make_state(name, initial, equals)
end

---@generic T
---@param name string
---@param initial T
---@param equals? fun(a: T, b: T): boolean
---@return Spoke.State<T>
function State.named(name, initial, equals)
  if type(name) ~= "string" then
    error("State.named expects a string name", 2)
  end
  return make_state(name, initial, equals)
end

function methods:now()
  return self._value
end

function methods:set(value)
  if self._equals(self._value, value) then
    return
  end
  self._value = value
  self._trigger:invoke(value)
end

function methods:update(fn)
  if fn == nil then
    return
  end
  self:set(fn(self._value))
end

function methods:subscribe(fn)
  return self._trigger:subscribe(fn)
end

function methods:unsubscribe(fn)
  self._trigger:unsubscribe(fn)
end

return State
