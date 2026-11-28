local SpokeError = require("common.packages.spoke.runtime.spoke_error")
local SpokeRuntime = require("common.packages.spoke.runtime.spoke_runtime")
local EpochAttach = require("common.packages.spoke.runtime.epoch_attach")
local EpochBuilder = require("common.packages.spoke.runtime.epoch_builder")
local EpochClass = require("common.packages.spoke.runtime.epoch_class")
local EpochCursor = require("common.packages.spoke.runtime.epoch_cursor")
local EpochFrame = require("common.packages.spoke.runtime.epoch_frame")
local EpochScheduling = require("common.packages.spoke.runtime.epoch_scheduling")
local EpochTeardown = require("common.packages.spoke.runtime.epoch_teardown")

---@alias Spoke.EpochTickFn fun(s: Spoke.EpochBuilder)

---@class Spoke.EpochClass
---@field _log_error fun(message: any, error_value?: any)
---@field _log fun(message: any, error_value?: any)
---@field __tostring fun(self: Spoke.Epoch): string
local Epoch = {}

---@class Spoke.EpochClassInternal: Spoke.EpochClass
---@field _new_instance fun(class: table, ...: any): any
---@field _refresh_coords fun(self: Spoke.EpochInternal)
local epoch_class_internal = Epoch --[[@as table]]

---@class Spoke.Epoch
---@field name string
---@field is_detached boolean
---@field fault Spoke.SpokeException?
---@field is_ticker? boolean
---@field auto_arm_tick_after_init? boolean
local methods = Epoch --[[@as table]]
methods.__index = methods

---@class Spoke.EpochInternal: Spoke.Epoch
---@field is_detached boolean
---@field fault Spoke.SpokeException?
---@field _default_name? string
---@field _attachments Spoke.EpochAttachment[]
---@field _attached boolean
---@field _tick_index integer
---@field _frame_depth integer
---@field _frame_handle Spoke.FrameHandle?
---@field _detach_requested boolean
---@field _detaching? boolean
---@field _is_ticker boolean
---@field _is_ticking? boolean
---@field _is_tree? boolean
---@field _is_manual? boolean
---@field _is_pending? boolean
---@field _auto_arm_tick_after_init boolean
---@field _parent Spoke.EpochInternal?
---@field _coord_index integer
---@field _import_index integer
---@field _depth integer
---@field _coords Spoke.PackedTreeCoords
---@field _tick_cursor Spoke.PackedTreeCoords
---@field _ticker Spoke.TickerInternal?
---@field _tree (Spoke.SpokeTreeInternal | Spoke.EpochInternal)?
---@field _request_tick (fun())?
---@field _tick_block Spoke.EpochTickFn?
---@field _discard_pending? fun(self: Spoke.EpochInternal)
local internal = Epoch --[[@as table]]

Epoch._log_error = function(message, error_value)
  SpokeError.log(message, error_value)
end
Epoch._log = function(message, error_value)
  SpokeError.log(message, error_value)
end

---@param message string
---@param error_value any
local function fallback_log(message, error_value)
  Epoch._log_error(message, error_value)
end

EpochBuilder.set_log_sink(function(message)
  Epoch._log(message)
end)

---@param name? string
---@return Spoke.Epoch
function Epoch.new(name)
  return EpochClass.new_instance(Epoch, name)
end

---@param name string
---@param definition? Spoke.EpochDefinition
---@return table
function Epoch.extend(name, definition)
  return EpochClass.define(Epoch, name, definition, Epoch.__tostring)
end

epoch_class_internal._new_instance = EpochClass.new_instance

---@param s? Spoke.EpochBuilder
---@return Spoke.EpochTickFn?
---@diagnostic disable-next-line: unused
function methods:init(s)
  local _ = s
  return nil
end

---@param epoch Spoke.EpochInternal
---@param other Spoke.EpochInternal
---@return integer
local function compare_across_trees(epoch, other)
  local tree_a = epoch._tree
  local tree_b = other._tree
  if tree_a and tree_b and tree_a._is_tree and tree_b._is_tree then
    return (tree_a --[[@as Spoke.SpokeTreeInternal]]):compare_to(tree_b --[[@as Spoke.SpokeTreeInternal]])
  end
  return 0
end

---@param epoch Spoke.EpochInternal
---@param other Spoke.EpochInternal
---@return boolean
local function both_cursors_valid(epoch, other)
  return epoch._tick_cursor:is_valid() and other._tick_cursor:is_valid()
end

---@param other Spoke.Epoch
---@return integer
function methods:compare_to(other)
  local a = self --[[@as Spoke.EpochInternal]]
  local b = other --[[@as Spoke.EpochInternal]]
  if a._tree ~= b._tree then
    return compare_across_trees(a, b)
  end
  if both_cursors_valid(a, b) then
    return a._tick_cursor:compare_to(b._tick_cursor)
  end
  return EpochCursor.compare(a, b)
end

---@return string
function methods:__tostring()
  return self.name or "Epoch"
end

---@param parent? Spoke.EpochInternal
---@param index integer
---@param ticker? Spoke.TickerInternal
---@param services? table<string, any>
---@param tree? Spoke.SpokeTreeInternal | Spoke.EpochInternal
function internal:_attach(parent, index, ticker, services, tree)
  if self._attached then
    error("Tried to attach an epoch which was already attached", 2)
  end
  EpochAttach.link_into_tree(self, parent, index, ticker, tree)
  self._request_tick = EpochScheduling.make_request_tick(self)

  local ok, result, frame = EpochFrame.run(self, "Init", function(builder)
    EpochAttach.export_services(self, services)
    return EpochAttach.invoke_init(self, builder)
  end)
  if not ok then
    EpochFrame.fail(self, "Init", frame, result)
  end

  self._tick_block = result
  EpochAttach.open_tick_window(self)
  if not EpochFrame.settle_detach_request(self, frame)
    and self._auto_arm_tick_after_init then
    frame:on_pop_self(self._request_tick)
  end
  SpokeRuntime.pop()
end

---@param index integer
function internal:_detach_from(index)
  EpochTeardown.release_from(self, index, fallback_log)
end

function internal:_perform_detach()
  if self.is_detached or not self._attached or self._detaching then
    return
  end
  self._detaching = true
  self:_detach_from(0)
  if type(self._discard_pending) == "function" then
    self:_discard_pending()
  end
  self.is_detached = true
  self._is_pending = false
  self._detaching = false
end

function methods:detach()
  local this = self --[[@as Spoke.EpochInternal]]
  if this.is_detached or not this._attached then
    return
  end
  if this._frame_depth > 0 then
    this._detach_requested = true
    return
  end
  this:_perform_detach()
end

function internal:_tick()
  if self.is_detached or self.fault then
    return
  end
  self._is_pending = false
  if self._is_ticker then
    self._is_ticking = true
  end

  local ok, result, frame = EpochFrame.run(self, "Tick", function(builder)
    self:_detach_from(self._tick_index)
    if self._tick_block then
      return self._tick_block(builder)
    end
  end)
  if not ok then
    EpochFrame.fail(self, "Tick", frame, result)
  end

  EpochFrame.settle_detach_request(self, frame)
  SpokeRuntime.pop()
end

function internal:_refresh_coords()
  self._coords = EpochCursor.resolve_coords(self)
  self._tick_cursor = EpochCursor.resolve_cursor(self)
  for _, record in ipairs(self._attachments) do
    if record.kind == "call" then
      record.value:_refresh_coords()
    end
  end
end

---@param index integer
function internal:_reindex(index)
  self._coord_index = index
  self:_refresh_coords()
end

---@return Spoke.EpochInternal?
function internal:_get_parent()
  return self._parent
end

---@return Spoke.TickerInternal?
function internal:_get_ticker()
  return self._ticker
end

---@param fault Spoke.SpokeException?
function internal:_set_fault(fault)
  self.fault = fault
end

---@param store? Spoke.Epoch[]
---@return Spoke.Epoch[]
function internal:_get_children(store)
  store = store or {}
  for _, record in ipairs(self._attachments) do
    if record.kind == "call" then
      store[#store + 1] = record.value
    end
  end
  return store
end

return Epoch
