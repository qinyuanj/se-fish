local SpokeError = {}

local function render(message, cause)
  local text = tostring(message)
  if cause ~= nil then
    text = text .. "\n" .. tostring(cause)
  end
  return text
end

SpokeError.log = function(message, cause)
  if type(print) == "function" then
    -- SE removes the debug library but keeps the equivalent global `traceback`
    -- (docs/research/eggy-u5-lua-runtime.md). Prefer the library, fall back to the
    -- host global, and degrade to no stack when the host offers neither.
    local capture = type(debug) == "table" and debug.traceback or traceback
    local suffix = type(capture) == "function" and ("\n" .. capture("", 2)) or ""
    print(render(message, cause) .. suffix)
  end
end

SpokeError.default_logger = {
  log = function(_, message)
    SpokeError.log(message)
  end,
  error = function(_, message)
    SpokeError.log(message)
  end,
}

return SpokeError
