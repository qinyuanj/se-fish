---@class Spoke.SpokeHandleClass
local SpokeHandle = {}

---@class Spoke.SpokeHandle: Spoke.DisposableTable
---@field private _id any
---@field private _on_dispose (fun(id: any))?
local methods = SpokeHandle --[[@as table]]
methods.__index = methods

---@param id any
---@param on_dispose? fun(id: any)
---@return Spoke.SpokeHandle
function SpokeHandle.of(id, on_dispose)
  if on_dispose ~= nil and type(on_dispose) ~= "function" then
    error("SpokeHandle.on_dispose must be a function", 2)
  end
  return setmetatable({
    _id = id,
    _on_dispose = on_dispose,
  }, methods)
end

local NOOP = setmetatable({
  _id = nil,
  _on_dispose = nil,
}, methods)

---@return Spoke.SpokeHandle
function SpokeHandle.new()
  return NOOP
end

---@param value any
---@return boolean
function SpokeHandle.is(value)
  return type(value) == "table" and getmetatable(value) == SpokeHandle
end

function methods:dispose()
  local on_dispose = self._on_dispose
  if on_dispose then
    self._on_dispose = nil
    on_dispose(self._id)
  end
end

return SpokeHandle
