local Epoch = require("common.packages.spoke.runtime.epoch")
local Ticker = require("common.packages.spoke.runtime.ticker")
local SpokeError = require("common.packages.spoke.runtime.spoke_error")
local SpokeRuntime = require("common.packages.spoke.runtime.spoke_runtime")
local Ordering = require("common.packages.spoke.runtime.ordering")
local TreeFlush = require("common.packages.spoke.runtime.spoke_tree_flush")

---@alias Spoke.FlushMode "Auto" | "Manual"
---@alias Spoke.DriveCommand "flush" | "tick"

---@class Spoke.SpokeTreeClass
local SpokeTree = {}

---@class Spoke.SpokeTree: Spoke.Ticker
---@field main Spoke.Epoch
---@field flush_mode Spoke.FlushMode
---@field flush_layer integer
local methods = SpokeTree --[[@as table]]
methods.__index = methods

---@class Spoke.SpokeTreeInternal: Spoke.SpokeTree, Spoke.TickerInternal
---@field _flush_layer integer
---@field _is_tree boolean
---@field _is_manual boolean
---@field _bootstrapping boolean
---@field _command Spoke.DriveCommand?
---@field _driving boolean
---@field _logger Spoke.Logger?
---@field _ports Spoke.TickerPorts?
---@field _timestamp integer?
---@field _runtime_pending boolean
local internal = SpokeTree --[[@as table]]
internal.__tostring = Epoch.__tostring
internal._default_name = "SpokeTree"
internal.is_ticker = true
internal.auto_arm_tick_after_init = false
setmetatable(SpokeTree, { __index = Ticker })

---@generic T
---@param value T
---@return T
local function identity(value)
  return value
end

---@param tree Spoke.SpokeTreeInternal
---@param services? table<string, any>
local function attach_tree(tree, services)
  tree:_attach(nil, 0, nil, services, tree)
end

---@param tree Spoke.SpokeTreeInternal
---@param mode Spoke.FlushMode
---@param services? table<string, any>
---@return boolean ok
---@return any error_value
local function run_bootstrap(tree, mode, services)
  tree._bootstrapping = true
  tree._timestamp = SpokeRuntime.next_timestamp()
  SpokeRuntime.try_scoped_layer_boost(tree)
  SpokeRuntime.push({
    type = "Bootstrap",
    epoch = tree,
  })
  local ok, error_value = xpcall(attach_tree, identity, tree, services)
  tree._bootstrapping = false
  if ok and mode == "Auto" then
    SpokeRuntime.try_flush()
  end
  SpokeRuntime.pop()
  return ok, error_value
end

---@param name string
---@param root Spoke.Epoch
---@param mode Spoke.FlushMode
---@param layer integer
---@param services? table<string, any>
---@return Spoke.SpokeTree
local function create(name, root, mode, layer, services)
  local root_internal = root --[[@as Spoke.EpochInternal]]
  if type(root) ~= "table"
    or type(root_internal._attach) ~= "function"
    or root_internal._attached then
    error("SpokeTree.spawn expects an unattached Epoch root", 2)
  end
  ---@type Spoke.SpokeTreeInternal
  local tree = (Epoch --[[@as Spoke.EpochClassInternal]])._new_instance(
    SpokeTree,
    name,
    root,
    mode,
    layer,
    services)
  local ok, error_value = run_bootstrap(tree, mode, services)
  if not ok then
    tree:_log_error("[SpokeTree] uncaught error in bootstrap", error_value)
  end
  if mode == "Auto" then
    SpokeRuntime.try_flush()
  end
  return tree
end

---@param default_name string
---@param first string | Spoke.Epoch
---@param second? any
---@param third? any
---@return string name
---@return Spoke.Epoch root
---@return table<string, any>? services
local function named_args(default_name, first, second, third)
  if type(first) == "string" then
    return first, second, third
  end
  return default_name, first, second
end

---@param root Spoke.Epoch
---@param mode? Spoke.FlushMode
---@param layer? integer
---@param services? table<string, any>
function internal:constructor(root, mode, layer, services)
  local _ = services
  self.main = root
  self.flush_mode = mode or "Auto"
  self._flush_layer = layer or 0
  self.flush_layer = self._flush_layer
  self._is_tree = true
  self._is_manual = self.flush_mode == "Manual"
  self._command = not self._is_manual and "flush" or nil
  self._driving = false
  self._logger = nil
  self._ports = nil
  self._timestamp = nil
  self._runtime_pending = false
end

---@overload fun(name: string, root: Spoke.Epoch, mode?: Spoke.FlushMode, layer?: integer, services?: table<string, any>): Spoke.SpokeTree
---@overload fun(root: Spoke.Epoch, mode?: Spoke.FlushMode, layer?: integer, services?: table<string, any>): Spoke.SpokeTree
---@param first string | Spoke.Epoch
---@param second? any
---@param third? any
---@param fourth? any
---@param fifth? any
---@return Spoke.SpokeTree
function SpokeTree.new(first, second, third, fourth, fifth)
  local name, root, mode, layer, services
  if type(first) == "string" then
    name, root, mode, layer, services = first, second, third, fourth, fifth
  else
    name, root, mode, layer, services = "SpokeTree", first, second, third, fourth
  end
  return create(name, root, mode or "Auto", layer or 0, services)
end

---@overload fun(name: string, root: Spoke.Epoch, services?: table<string, any>): Spoke.SpokeTree
---@overload fun(root: Spoke.Epoch, services?: table<string, any>): Spoke.SpokeTree
---@param first string | Spoke.Epoch
---@param second? Spoke.Epoch | table<string, any>
---@param third? table<string, any>
---@return Spoke.SpokeTree
function SpokeTree.spawn(first, second, third)
  local name, root, services = named_args("SpokeTree", first, second, third)
  return create(name, root, "Auto", 0, services)
end

---@overload fun(name: string, root: Spoke.Epoch, services?: table<string, any>): Spoke.SpokeTree
---@overload fun(root: Spoke.Epoch, services?: table<string, any>): Spoke.SpokeTree
---@param first string | Spoke.Epoch
---@param second? Spoke.Epoch | table<string, any>
---@param third? table<string, any>
---@return Spoke.SpokeTree
function SpokeTree.spawn_eager(first, second, third)
  local name, root, services = named_args("SpokeTree (Eager)", first, second, third)
  return create(name, root, "Auto", -1, services)
end

---@overload fun(name: string, root: Spoke.Epoch, services?: table<string, any>): Spoke.SpokeTree
---@overload fun(root: Spoke.Epoch, services?: table<string, any>): Spoke.SpokeTree
---@param first string | Spoke.Epoch
---@param second? Spoke.Epoch | table<string, any>
---@param third? table<string, any>
---@return Spoke.SpokeTree
function SpokeTree.spawn_manual(first, second, third)
  local name, root, services = named_args("SpokeTree (Manual)", first, second, third)
  return create(name, root, "Manual", -math.maxinteger, services)
end

---@param s Spoke.TickerBuilder
---@return Spoke.Epoch
function methods:bootstrap(s)
  local this = self --[[@as Spoke.SpokeTreeInternal]]
  local found, logger = s:try_import("logger")
  if found then
    this._logger = logger
  end
  this._ports = s:ports()
  s:on_tick(function(context)
    this:_drive_pending(context)
  end)
  return this.main
end

---@param other Spoke.SpokeTree
---@return integer
function methods:compare_to(other)
  local a = self --[[@as Spoke.SpokeTreeInternal]]
  local b = other --[[@as Spoke.SpokeTreeInternal]]
  local by_layer = Ordering.compare(a._flush_layer, b._flush_layer)
  if by_layer ~= 0 then
    return by_layer
  end
  return Ordering.compare(a._timestamp --[[@as integer]], b._timestamp --[[@as integer]])
end

---@param message string
---@param error_value any
function internal:_log_error(message, error_value)
  local logger = self._logger
  local err_fn = type(logger) == "table" and logger.error or nil
  if type(err_fn) == "function" then
    pcall(err_fn, logger --[[@as Spoke.Logger]], message .. "\n" .. tostring(error_value))
  else
    SpokeError.log(message, error_value)
  end
end

---@param context Spoke.TickContext
function internal:_drive_pending(context)
  TreeFlush.drive(self, context)
end

---@param command Spoke.DriveCommand
function internal:_drive_manual(command)
  if self.flush_mode ~= "Manual" then
    error("Only Manual trees can be explicitly driven", 2)
  end
  if self._driving then
    error("Re-entrant flush detected", 2)
  end
  if self.is_detached then
    return
  end
  self._driving = true
  self._command = command
  SpokeRuntime.tick_tree(self)
  self._command = nil
  self._driving = false
end

function methods:flush()
  (self --[[@as Spoke.SpokeTreeInternal]]):_drive_manual("flush")
end

function methods:tick()
  (self --[[@as Spoke.SpokeTreeInternal]]):_drive_manual("tick")
end

function methods:dispose()
  self:detach()
end

return SpokeTree
