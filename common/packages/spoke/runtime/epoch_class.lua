---@class Spoke.EpochDefinition
---@field constructor? fun(self: any, ...: any)
---@field init? fun(self: any, s: Spoke.EpochBuilder): Spoke.EpochTickFn?
---@field is_ticker? boolean
---@field auto_arm_tick_after_init? boolean
---@field [string] any

---@class Spoke.EpochClassFactory
local EpochClass = {}

---@param class table
---@param ... any
---@return any
function EpochClass.new_instance(class, ...)
  local self = setmetatable({
    name = class._default_name or "Epoch",
    is_detached = false,
    fault = nil,
    _attachments = {},
    _attached = false,
    _tick_index = -1,
    _frame_depth = 0,
    _frame_handle = nil,
    _reusable_handle = nil,
    _epoch_ports = nil,
    _detach_requested = false,
    _is_ticker = class.is_ticker == true,
    _auto_arm_tick_after_init = class.auto_arm_tick_after_init ~= false,
    _is_pending = false,
    _parent = nil,
    _coord_index = 0,
    _import_index = -1,
    _depth = 0,
    _coords = nil,
    _tick_cursor = nil,
    _ticker = nil,
    _tree = nil,
    _request_tick = nil,
    _tick_block = nil,
  }, class)
  local ctor = class.constructor
  local count = select("#", ...)
  if count >= 1 and type((...)) == "string" then
    self.name = ...
    if type(ctor) == "function" then
      ctor(self, select(2, ...))
    end
  elseif type(ctor) == "function" then
    ctor(self, ...)
  end
  return self
end

---@param parent table
---@param name string
---@param definition? Spoke.EpochDefinition
---@param tostring_fn? fun(self: any): string
---@return table
function EpochClass.define(parent, name, definition, tostring_fn)
  ---@type table<string, any>
  local class = {
    _default_name = name,
    __tostring = tostring_fn,
  }
  class.__index = class
  setmetatable(class, { __index = parent })
  for key, value in pairs(definition or {}) do
    class[key] = value
  end
  function class.new(...)
    return EpochClass.new_instance(class, ...)
  end
  return class
end

return EpochClass
