local SpokeHandle = require("common.packages.spoke.runtime.spoke_handle")
local SpokeError = require("common.packages.spoke.runtime.spoke_error")
local SpokeRuntime = require("common.packages.spoke.runtime.spoke_runtime")

local EpochBuilder = {}
EpochBuilder.__index = EpochBuilder

local log_sink = function(message)
  SpokeError.log(message)
end

function EpochBuilder.set_log_sink(fn)
  log_sink = fn
end

local Ports = {}
Ports.__index = Ports

local function assert_active(builder)
  if not builder._active
    or not builder._frame_handle
    or not builder._frame_handle:is_top() then
    error("Tried to mutate an Epoch that's been sealed for further changes.", 3)
  end
end

local function assert_export_key(key)
  if type(key) ~= "string" or key == "" then
    error("EpochBuilder export keys must be non-empty strings", 3)
  end
end

local function attach_record(builder, record)
  local attachments = builder._owner._attachments
  attachments[#attachments + 1] = record
end

local function is_epoch(value)
  return type(value) == "table" and type(value._attach) == "function"
end

local function is_disposable(value)
  local kind = type(value)
  return kind == "function"
    or (kind == "table" and type(value.dispose) == "function")
end

function EpochBuilder.new(owner, frame_handle)
  return setmetatable({
    _owner = owner,
    _active = true,
    _frame_handle = frame_handle,
    _ports = nil,
  }, EpochBuilder)
end

function EpochBuilder:call(child)
  assert_active(self)
  if not is_epoch(child) then
    error("EpochBuilder:call expects an unattached Epoch", 2)
  end
  if child._attached then
    error("Tried to attach an epoch which was already attached", 2)
  end

  local owner = self._owner
  attach_record(self, { kind = "call", value = child })
  local child_ticker = owner._is_ticker and owner or owner._ticker
  child:_attach(owner, #owner._attachments - 1, child_ticker, nil, owner._tree)
  return child
end

function EpochBuilder:on_cleanup(fn)
  assert_active(self)
  if type(fn) ~= "function" then
    error("EpochBuilder:on_cleanup expects a function", 2)
  end
  attach_record(self, { kind = "cleanup", value = fn })
end

function EpochBuilder:use(resource)
  assert_active(self)
  if not is_disposable(resource) then
    error("EpochBuilder:use expects a disposable resource", 2)
  end
  attach_record(self, {
    kind = SpokeHandle.is(resource) and "handle" or "use",
    value = resource,
  })
  return resource
end

function EpochBuilder:ports()
  assert_active(self)
  if not self._ports then
    self._ports = setmetatable({ _owner = self._owner }, Ports)
  end
  return self._ports
end

local function emit_log(log_s, message)
  local SpokeIntrospect = require("common.packages.spoke.runtime.spoke_introspect")
  local found, logger = log_s:try_import("logger")
  local text = tostring(message) .. "\n\n"
    .. SpokeIntrospect.tree_trace(SpokeRuntime.snapshot_frames())
  pcall(function()
    if found and type(logger) == "table" and type(logger.log) == "function" then
      logger:log(text)
    else
      log_sink(text)
    end
  end)
  return nil
end

function EpochBuilder:log(message)
  assert_active(self)
  local LambdaEpoch = require("common.packages.spoke.runtime.lambda_epoch")
  self:call(LambdaEpoch.new("Log: " .. tostring(message), function(log_s)
    return emit_log(log_s, message)
  end))
end

function EpochBuilder:export(key, value)
  assert_active(self)
  assert_export_key(key)
  attach_record(self, { kind = "export", key = key, value = value })
  return value
end

function EpochBuilder:try_import(key)
  assert_active(self)
  assert_export_key(key)
  local epoch = self._owner
  local limit = #epoch._attachments
  while epoch do
    for index = limit, 1, -1 do
      local record = epoch._attachments[index]
      if record.kind == "export" and record.key == key then
        return true, record.value
      end
    end
    limit = epoch._import_index + 1
    epoch = epoch._parent
  end
  return false, nil
end

function EpochBuilder:import(key)
  local found, value = self:try_import(key)
  if found then
    return value
  end
  error("Failed to import: " .. tostring(key), 2)
end

function Ports:request_tick()
  local owner = self._owner
  local frame = owner._frame_handle
  if frame and frame:is_alive() then
    frame:on_pop_self(owner._request_tick)
  else
    owner:_request_tick()
  end
end

EpochBuilder.assert_export_key = assert_export_key

return EpochBuilder
