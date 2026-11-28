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
    _detach_requested = false,
    _is_ticker = class.is_ticker == true,
    _auto_arm_tick_after_init = class.auto_arm_tick_after_init ~= false,
  }, class)
  local args = table.pack(...)
  local start = 1
  if args.n >= 1 and type(args[1]) == "string" then
    self.name = args[1]
    start = 2
  end
  if type(class.constructor) == "function" then
    class.constructor(self, table.unpack(args, start, args.n))
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
