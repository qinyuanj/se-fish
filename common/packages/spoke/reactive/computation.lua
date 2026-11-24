local Epoch = require("common.packages.spoke.runtime.epoch")

local DependencyTracker = {}
DependencyTracker.__index = DependencyTracker

function DependencyTracker.new(schedule)
  return setmetatable({
    _schedule = schedule,
    _static_handles = {},
    _dynamic = {},
    _slot_callbacks = {},
    _dep_index = 0,
  }, DependencyTracker)
end

function DependencyTracker:add_static(trigger)
  self._static_handles[#self._static_handles + 1] = trigger:subscribe(self._schedule)
end

function DependencyTracker:begin_dynamic()
  self._dep_index = 0
end

function DependencyTracker:add_dynamic(trigger)
  local slot = self._dynamic[self._dep_index + 1]
  if slot == nil then
    self._dynamic[self._dep_index + 1] = {
      trigger = trigger,
      handle = trigger:subscribe(self:_schedule_from_index(self._dep_index)),
    }
  elseif slot.trigger ~= trigger then
    slot.handle:dispose()
    slot.trigger = trigger
    slot.handle = trigger:subscribe(self:_schedule_from_index(self._dep_index))
  end
  self._dep_index = self._dep_index + 1
end

function DependencyTracker:end_dynamic()
  while #self._dynamic > self._dep_index do
    table.remove(self._dynamic).handle:dispose()
  end
end

function DependencyTracker:dispose()
  for _, handle in ipairs(self._static_handles) do
    handle:dispose()
  end
  for _, slot in ipairs(self._dynamic) do
    slot.handle:dispose()
  end
  self._static_handles = {}
  self._dynamic = {}
end

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
  return self._slot_callbacks[index + 1]
end

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

local function parse_effect_args(a, b, ...)
  if type(a) == "string" then
    return a, b, collect_triggers(...)
  end
  return nil, a, collect_triggers(b, ...)
end

local function normalize_triggers(triggers)
  if triggers == nil then
    return {}
  end
  if type(triggers) == "table" then
    if type(triggers.subscribe) == "function" then
      return { triggers }
    end
    return triggers
  end
  error("Computation triggers must be a trigger or an array of triggers", 3)
end

local Computation = Epoch.extend("Computation", {
  constructor = function(self, triggers)
    self._triggers = normalize_triggers(triggers)
  end,

  init = function(self, s)
    local ports = s:ports()
    local tracker = DependencyTracker.new(function()
      ports:request_tick()
    end)
    s:use(tracker)
    self._tracker = tracker
    for _, trigger in ipairs(self._triggers) do
      tracker:add_static(trigger)
    end
    return function(tick_s)
      tracker:begin_dynamic()
      local ok, err = pcall(function()
        self:on_run(tick_s)
      end)
      tracker:end_dynamic()
      if not ok then
        error(err, 0)
      end
    end
  end,

  on_run = function(self)
    error("Computation.on_run is abstract", 2)
  end,

  _add_static_trigger = function(self, trigger)
    self._tracker:add_static(trigger)
  end,

  _add_dynamic_trigger = function(self, trigger)
    self._tracker:add_dynamic(trigger)
  end,
})

function Computation.extend(name, definition)
  local class = Epoch.extend(name, definition)
  getmetatable(class).__index = Computation
  return class
end

Computation.DependencyTracker = DependencyTracker
Computation._collect_triggers = collect_triggers
Computation._parse_effect_args = parse_effect_args

return Computation
