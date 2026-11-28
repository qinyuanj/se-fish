local Epoch = require("common.packages.spoke.runtime.epoch")

---@class Spoke.DependencyTracker: Spoke.DisposableTable
---@field private _schedule fun()
---@field private _static_handles table<integer, Spoke.SpokeHandle?>
---@field private _dyn_triggers table<integer, Spoke.Subscribable<any>?>
---@field private _dyn_handles table<integer, Spoke.SpokeHandle?>
---@field private _dyn_count integer
---@field private _slot_callbacks (fun())[]
---@field private _dep_index integer
local DependencyTracker = {}
DependencyTracker.__index = DependencyTracker

---@param schedule fun()
---@return Spoke.DependencyTracker
function DependencyTracker.new(schedule)
  return setmetatable({
    _schedule = schedule,
    _static_handles = {},
    _dyn_triggers = {},
    _dyn_handles = {},
    _dyn_count = 0,
    _slot_callbacks = {},
    _dep_index = 0,
  }, DependencyTracker)
end

---@param trigger Spoke.Subscribable<any>
function DependencyTracker:add_static(trigger)
  self._static_handles[#self._static_handles + 1] = trigger:subscribe(self._schedule)
end

function DependencyTracker:begin_dynamic()
  self._dep_index = 0
end

---@param trigger Spoke.Subscribable<any>
function DependencyTracker:add_dynamic(trigger)
  local slot_idx = self._dep_index + 1
  local cur_trigger = self._dyn_triggers[slot_idx]
  if cur_trigger == nil then
    self._dyn_triggers[slot_idx] = trigger
    self._dyn_handles[slot_idx] = trigger:subscribe(self:_schedule_from_index(self._dep_index))
    if slot_idx > self._dyn_count then
      self._dyn_count = slot_idx
    end
  elseif cur_trigger ~= trigger then
    local old_handle = self._dyn_handles[slot_idx]
    if old_handle ~= nil then
      old_handle:dispose()
    end
    self._dyn_triggers[slot_idx] = trigger
    self._dyn_handles[slot_idx] = trigger:subscribe(self:_schedule_from_index(self._dep_index))
  end
  self._dep_index = slot_idx
end

function DependencyTracker:end_dynamic()
  for index = self._dyn_count, self._dep_index + 1, -1 do
    local handle = self._dyn_handles[index]
    self._dyn_triggers[index] = nil
    self._dyn_handles[index] = nil
    if handle ~= nil then
      handle:dispose()
    end
  end
  if self._dep_index < self._dyn_count then
    self._dyn_count = self._dep_index
  end
end

function DependencyTracker:dispose()
  local static_handles = self._static_handles
  for index = 1, #static_handles do
    local handle = static_handles[index]
    static_handles[index] = nil
    if handle ~= nil then
      handle:dispose()
    end
  end
  for index = 1, self._dyn_count do
    local handle = self._dyn_handles[index]
    self._dyn_triggers[index] = nil
    self._dyn_handles[index] = nil
    if handle ~= nil then
      handle:dispose()
    end
  end
  self._dyn_count = 0
  self._dep_index = 0
end

---@param index integer
---@return fun()
function DependencyTracker:_schedule_from_index(index)
  while #self._slot_callbacks <= index do
    local captured = #self._slot_callbacks
    local tracker = self
    self._slot_callbacks[#self._slot_callbacks + 1] = function()
      if captured < tracker._dep_index then
        tracker._schedule()
      end
    end
  end
  return self._slot_callbacks[index + 1] --[[@as fun()]]
end

---@param ... any
---@return Spoke.Subscribable<any>[]?
local function collect_triggers(...)
  local count = select("#", ...)
  if count == 0 then
    return nil
  end
  if count == 1 then
    local only = ...
    if type(only) == "table" and type(only.subscribe) ~= "function" then
      return only
    end
  end
  return { ... }
end

---@param a any
---@param b? any
---@param ... any
---@return string? name
---@return (fun(s: Spoke.EffectBuilder): any)? block
---@return Spoke.TriggerList? triggers
local function parse_effect_args(a, b, ...)
  if type(a) == "string" then
    return a, b, collect_triggers(...)
  end
  return nil, a, collect_triggers(b, ...)
end

---@param triggers? any
---@return Spoke.Subscribable<any>[]
local function normalize_triggers(triggers)
  if triggers == nil then
    return {}
  end
  if type(triggers) == "table" then
    if type(triggers.subscribe) == "function" then
      return { triggers --[[@as Spoke.Subscribable<any>]] }
    end
    return triggers
  end
  error("Computation triggers must be a trigger or an array of triggers", 3)
end

---@class Spoke.Computation: Spoke.Epoch
---@field package _triggers Spoke.Subscribable<any>[]
---@field package _tracker Spoke.DependencyTracker
---@field protected _add_dynamic_fn fun(signal: Spoke.Subscribable<any>)
---@field constructor fun(self: Spoke.Computation, triggers?: Spoke.TriggerList)
---@field on_run fun(self: Spoke.Computation, s: Spoke.EpochBuilder)
---@field protected _add_static_trigger fun(self: Spoke.Computation, trigger: Spoke.Subscribable<any>)
---@field protected _add_dynamic_trigger fun(self: Spoke.Computation, trigger: Spoke.Subscribable<any>)
---@field DependencyTracker Spoke.DependencyTracker
---@field _collect_triggers fun(...: any): Spoke.Subscribable<any>[]?
---@field _parse_effect_args fun(a: any, b?: any, ...: any): string?, (fun(s: Spoke.EffectBuilder): any)?, Spoke.TriggerList?
local Computation = Epoch.extend("Computation", {
  ---@param self Spoke.Computation
  ---@param triggers? Spoke.TriggerList
  constructor = function(self, triggers)
    self._triggers = normalize_triggers(triggers)
  end,

  ---@param self Spoke.Computation
  ---@param s Spoke.EpochBuilder
  ---@return Spoke.EpochTickFn
  init = function(self, s)
    local ports = s:ports()
    local tracker = DependencyTracker.new(function()
      ports:request_tick()
    end)
    s:use(tracker)
    self._tracker = tracker
    self._add_dynamic_fn = function(signal)
      tracker:add_dynamic(signal)
    end
    for _, trigger in ipairs(self._triggers) do
      tracker:add_static(trigger)
    end
    return function(tick_s)
      tracker:begin_dynamic()
      local ok, err = pcall(self.on_run, self, tick_s)
      tracker:end_dynamic()
      if not ok then
        error(err, 0)
      end
    end
  end,

  ---@param self Spoke.Computation
  ---@param s? Spoke.EpochBuilder
  on_run = function(self, s)
    local _, _ = self, s
    error("Computation.on_run is abstract", 2)
  end,

  ---@param self Spoke.Computation
  ---@param trigger Spoke.Subscribable<any>
  _add_static_trigger = function(self, trigger)
    self._tracker:add_static(trigger)
  end,

  ---@param self Spoke.Computation
  ---@param trigger Spoke.Subscribable<any>
  _add_dynamic_trigger = function(self, trigger)
    self._tracker:add_dynamic(trigger)
  end,
})

---@param name string
---@param definition? Spoke.EpochDefinition
---@return table
function Computation.extend(name, definition)
  local class = Epoch.extend(name, definition)
  getmetatable(class).__index = Computation
  return class
end

Computation.DependencyTracker = DependencyTracker
Computation._collect_triggers = collect_triggers
Computation._parse_effect_args = parse_effect_args

return Computation
