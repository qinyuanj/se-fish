local SpokeHandle = require("common.packages.spoke.runtime.spoke_handle")
local SpokeError = require("common.packages.spoke.runtime.spoke_error")
local SpokeRuntime = require("common.packages.spoke.runtime.spoke_runtime")

---@class Spoke.DisposableTable
---@field dispose fun(self: any)

---@alias Spoke.Disposable Spoke.DisposableTable | fun()

---@class Spoke.EpochAttachment
---@field kind "call" | "cleanup" | "use" | "handle" | "export"
---@field key? string
---@field value any

---@class Spoke.EpochBuilder
local EpochBuilder = {}
EpochBuilder.__index = EpochBuilder

---@class Spoke.EpochBuilderInternal: Spoke.EpochBuilder
---@field _owner Spoke.EpochInternal
---@field _active boolean
---@field _frame_handle Spoke.FrameHandle?
---@field package _ports Spoke.Ports?

---@param message any
local log_sink = function(message)
  SpokeError.log(message)
end

---@param fn fun(message: any)
function EpochBuilder.set_log_sink(fn)
  log_sink = fn
end

---@class Spoke.Ports
---@field private _owner Spoke.EpochInternal
local Ports = {}
Ports.__index = Ports

---@param builder Spoke.EpochBuilder
local function assert_active(builder)
  local b = builder --[[@as Spoke.EpochBuilderInternal]]
  if not b._active
    or not b._frame_handle
    or not b._frame_handle:is_top() then
    error("Tried to mutate an Epoch that's been sealed for further changes.", 3)
  end
end

---@param key any
local function assert_export_key(key)
  if type(key) ~= "string" or key == "" then
    error("EpochBuilder export keys must be non-empty strings", 3)
  end
end

---@param builder Spoke.EpochBuilder
---@param record Spoke.EpochAttachment
local function attach_record(builder, record)
  local b = builder --[[@as Spoke.EpochBuilderInternal]]
  local attachments = b._owner._attachments
  attachments[#attachments + 1] = record
end

---@param value any
---@return boolean
local function is_epoch(value)
  return type(value) == "table" and type(value._attach) == "function"
end

---@param value any
---@return boolean
local function is_disposable(value)
  local kind = type(value)
  return kind == "function"
    or (kind == "table" and type(value.dispose) == "function")
end

---@param owner Spoke.EpochInternal
---@param frame_handle Spoke.FrameHandle
---@return Spoke.EpochBuilderInternal
function EpochBuilder.new(owner, frame_handle)
  return setmetatable({
    _owner = owner,
    _active = true,
    _frame_handle = frame_handle,
    _ports = nil,
  }, EpochBuilder)
end

---@generic T: Spoke.Epoch
---@param child T
---@return T
function EpochBuilder:call(child)
  assert_active(self)
  local target = child --[[@as Spoke.EpochInternal]]
  if not is_epoch(target) then
    error("EpochBuilder:call expects an unattached Epoch", 2)
  end
  if target._attached then
    error("Tried to attach an epoch which was already attached", 2)
  end

  local owner = (self --[[@as Spoke.EpochBuilderInternal]])._owner
  attach_record(self, { kind = "call", value = target })
  local child_ticker = owner._is_ticker and (owner --[[@as Spoke.TickerInternal]]) or owner._ticker
  target:_attach(owner, #owner._attachments - 1, child_ticker, nil, owner._tree)
  return child
end

---@param fn fun()
function EpochBuilder:on_cleanup(fn)
  assert_active(self)
  if type(fn) ~= "function" then
    error("EpochBuilder:on_cleanup expects a function", 2)
  end
  attach_record(self, { kind = "cleanup", value = fn })
end

---@generic T: Spoke.Disposable
---@param resource T
---@return T
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

---@return Spoke.Ports
function EpochBuilder:ports()
  assert_active(self)
  local this = self --[[@as Spoke.EpochBuilderInternal]]
  if not this._ports then
    this._ports = setmetatable({ _owner = this._owner }, Ports)
  end
  return this._ports
end

---@param log_s Spoke.EpochBuilder
---@param message any
---@return nil
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

---@param message any
function EpochBuilder:log(message)
  assert_active(self)
  local LambdaEpoch = require("common.packages.spoke.runtime.lambda_epoch")
  self:call(LambdaEpoch.new("Log: " .. tostring(message), function(log_s)
    return emit_log(log_s, message)
  end))
end

---@generic T
---@param key string
---@param value T
---@return T
function EpochBuilder:export(key, value)
  assert_active(self)
  assert_export_key(key)
  attach_record(self, { kind = "export", key = key, value = value })
  return value
end

---@param key string
---@return boolean found
---@return any value
function EpochBuilder:try_import(key)
  assert_active(self)
  assert_export_key(key)
  local epoch = (self --[[@as Spoke.EpochBuilderInternal]])._owner
  local limit = #epoch._attachments
  ---@cast epoch Spoke.EpochInternal?
  while epoch do
    for index = limit, 1, -1 do
      local record = epoch._attachments[index]
      ---@cast record -nil
      if record.kind == "export" and record.key == key then
        return true, record.value
      end
    end
    limit = epoch._import_index + 1
    epoch = epoch._parent
  end
  return false, nil
end

---@param key string
---@return any
function EpochBuilder:import(key)
  local found, value = self:try_import(key)
  if found then
    return value
  end
  error("Failed to import: " .. tostring(key), 2)
end

function Ports:request_tick()
  local owner = self._owner
  local request_tick = owner._request_tick
  if not request_tick then
    return
  end
  local frame = owner._frame_handle
  if frame and frame:is_alive() then
    frame:on_pop_self(request_tick)
  else
    request_tick()
  end
end

EpochBuilder.assert_export_key = assert_export_key

return EpochBuilder
