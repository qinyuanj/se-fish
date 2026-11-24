local EpochClass = {}

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
  local args = { ... }
  if type(args[1]) == "string" then
    self.name = table.remove(args, 1)
  end
  if type(class.constructor) == "function" then
    class.constructor(self, table.unpack(args))
  end
  return self
end

function EpochClass.define(parent, name, definition, tostring_fn)
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
