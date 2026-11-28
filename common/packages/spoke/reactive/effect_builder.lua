local Computation = require("common.packages.spoke.reactive.computation")
local Dock = require("common.packages.spoke.runtime.dock")
local SpokeHandle = require("common.packages.spoke.runtime.spoke_handle")

---@class Spoke.EffectBuilderClass
---@field MemoBuilder Spoke.MemoBuilderClass
local EffectBuilder = {}

---@class Spoke.EffectBuilder
---@field package _add_dynamic fun(signal: Spoke.Subscribable<any>)
---@field package _s Spoke.EpochBuilderInternal
local methods = EffectBuilder --[[@as table]]
methods.__index = methods

---@class Spoke.MemoBuilderClass
local MemoBuilder = {}

---@class Spoke.MemoBuilder
---@field package _add_dynamic fun(signal: Spoke.Subscribable<any>)
---@field package _s Spoke.EpochBuilderInternal
local memo_methods = MemoBuilder --[[@as table]]
memo_methods.__index = memo_methods

---@param builder Spoke.EffectBuilder | Spoke.MemoBuilder
local function assert_active(builder)
  local s = builder._s
  if not s._active
    or not s._frame_handle
    or not s._frame_handle:is_top() then
    error("Tried to mutate an Epoch that's been sealed for further changes.", 3)
  end
end

local collect_triggers = Computation._collect_triggers

---@param add_dynamic fun(signal: Spoke.Subscribable<any>)
---@param epoch_builder Spoke.EpochBuilder
---@return Spoke.EffectBuilder
function EffectBuilder.new(add_dynamic, epoch_builder)
  return setmetatable({
    _add_dynamic = add_dynamic,
    _s = epoch_builder,
  }, methods)
end

---@generic T
---@param signal Spoke.Signal<T>
---@return T
function methods:d(signal)
  assert_active(self)
  self._add_dynamic(signal)
  return signal:now()
end

---@generic T
---@param trigger Spoke.Subscribable<T>?
---@param fn fun(value: T)
---@return Spoke.SpokeHandle
function methods:subscribe(trigger, fn)
  assert_active(self)
  if trigger == nil then
    return self:use(SpokeHandle.new())
  end
  return self:use(trigger:subscribe(fn))
end

---@generic T: Spoke.Disposable
---@param resource T
---@return T
function methods:use(resource)
  assert_active(self)
  return self._s:use(resource)
end

---@generic T: Spoke.Epoch
---@param epoch T
---@return T
function methods:call(epoch)
  assert_active(self)
  return self._s:call(epoch)
end

---@generic T
---@param key string
---@param value T
---@return T
function methods:export(key, value)
  assert_active(self)
  return self._s:export(key, value)
end

---@param key string
---@return any
function methods:import(key)
  assert_active(self)
  return self._s:import(key)
end

---@param key string
---@return boolean found
---@return any value
function methods:try_import(key)
  assert_active(self)
  return self._s:try_import(key)
end

---@param fn fun()
function methods:on_cleanup(fn)
  assert_active(self)
  self._s:on_cleanup(fn)
end

---@param message any
function methods:log(message)
  assert_active(self)
  self._s:log(message)
end

---@param builder Spoke.EffectBuilder
---@param class { new: fun(...: any): Spoke.Epoch }
---@param a any
---@param b? any
---@param ... any
---@return Spoke.Epoch
local function call_block_factory(builder, class, a, b, ...)
  if type(a) == "string" then
    return builder:call(class.new(a, b, collect_triggers(...)))
  end
  return builder:call(class.new(a, collect_triggers(b, ...)))
end

---@generic T
---@overload fun(self: Spoke.EffectBuilder, name: string, selector: (fun(s: Spoke.MemoBuilder): T), ...: Spoke.TriggerList): Spoke.Memo<T>
---@overload fun(self: Spoke.EffectBuilder, selector: (fun(s: Spoke.MemoBuilder): T), ...: Spoke.TriggerList): Spoke.Memo<T>
---@param a any
---@param b? any
---@param ... any
---@return Spoke.Memo<any>
function methods:memo(a, b, ...)
  assert_active(self)
  local Memo = require("common.packages.spoke.reactive.memo")
  return call_block_factory(self, Memo, a, b, ...) --[[@as Spoke.Memo<any>]]
end

---@generic T
---@overload fun(self: Spoke.EffectBuilder, name: string, block: (fun(s: Spoke.EffectBuilder): Spoke.Signal<T>?), ...: Spoke.TriggerList): Spoke.Effect<T>
---@overload fun(self: Spoke.EffectBuilder, block: (fun(s: Spoke.EffectBuilder): Spoke.Signal<T>?), ...: Spoke.TriggerList): Spoke.Effect<T>
---@param a any
---@param b? any
---@param ... any
---@return Spoke.Effect<any>
function methods:effect(a, b, ...)
  assert_active(self)
  local Effect = require("common.packages.spoke.reactive.effect")
  local name, block, triggers = Computation._parse_effect_args(a, b, ...)
  if name ~= nil then
    return self:call(Effect.new(name, block, triggers))
  end
  return self:call(Effect.new(block, triggers))
end

---@overload fun(self: Spoke.EffectBuilder, name: string, block: fun(s: Spoke.EffectBuilder), ...: Spoke.TriggerList): Spoke.Reaction
---@overload fun(self: Spoke.EffectBuilder, block: fun(s: Spoke.EffectBuilder), ...: Spoke.TriggerList): Spoke.Reaction
---@param a any
---@param b? any
---@param ... any
---@return Spoke.Reaction
function methods:reaction(a, b, ...)
  assert_active(self)
  local Reaction = require("common.packages.spoke.reactive.reaction")
  return call_block_factory(self, Reaction, a, b, ...) --[[@as Spoke.Reaction]]
end

---@overload fun(self: Spoke.EffectBuilder, name: string, mount_when: Spoke.Signal<boolean>, block: fun(s: Spoke.EffectBuilder), ...: Spoke.TriggerList): Spoke.Phase
---@overload fun(self: Spoke.EffectBuilder, mount_when: Spoke.Signal<boolean>, block: fun(s: Spoke.EffectBuilder), ...: Spoke.TriggerList): Spoke.Phase
---@param a any
---@param b any
---@param c? any
---@param ... any
---@return Spoke.Phase
function methods:phase(a, b, c, ...)
  assert_active(self)
  local Phase = require("common.packages.spoke.reactive.phase")
  if type(a) == "string" then
    return self:call(Phase.new(a, b, c, collect_triggers(...)))
  end
  return self:call(Phase.new(a, b, collect_triggers(c, ...)))
end

---@param name? string
---@return Spoke.Dock
function methods:dock(name)
  assert_active(self)
  return self:call(Dock.new(name))
end

---@param add_dynamic fun(signal: Spoke.Subscribable<any>)
---@param epoch_builder Spoke.EpochBuilder
---@return Spoke.MemoBuilder
function MemoBuilder.new(add_dynamic, epoch_builder)
  return setmetatable({
    _add_dynamic = add_dynamic,
    _s = epoch_builder,
  }, memo_methods)
end

---@generic T
---@param signal Spoke.Signal<T>
---@return T
function memo_methods:d(signal)
  assert_active(self)
  self._add_dynamic(signal)
  return signal:now()
end

---@param fn fun()
function memo_methods:on_cleanup(fn)
  assert_active(self)
  self._s:on_cleanup(fn)
end

EffectBuilder.MemoBuilder = MemoBuilder

return EffectBuilder
