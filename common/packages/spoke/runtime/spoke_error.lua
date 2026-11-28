---@class Spoke.Logger
---@field log? fun(self: Spoke.Logger, message: any)
---@field error? fun(self: Spoke.Logger, message: any)

---@class Spoke.SpokeError
---@field log fun(message: any, cause?: any)
---@field default_logger Spoke.Logger
local SpokeError = {}

---@param message any
---@param cause? any
---@return string
local function render(message, cause)
  local text = tostring(message)
  if cause ~= nil then
    text = text .. "\n" .. tostring(cause)
  end
  return text
end

---@param message any
---@param cause? any
SpokeError.log = function(message, cause)
  if type(print) == "function" then
    local capture = type(debug) == "table" and debug.traceback or traceback
    local suffix = type(capture) == "function" and ("\n" .. capture("", 2)) or ""
    print(render(message, cause) .. suffix)
  end
end

---@type Spoke.Logger
SpokeError.default_logger = {
  log = function(_, message)
    SpokeError.log(message)
  end,
  error = function(_, message)
    SpokeError.log(message)
  end,
}

return SpokeError
