local Epoch = require("common.packages.spoke.runtime.epoch")
local EpochClass = require("common.packages.spoke.runtime.epoch_class")
local Heap = require("common.packages.spoke.runtime.heap")
local SpokeRuntime = require("common.packages.spoke.runtime.spoke_runtime")

---@class Spoke.TickerClass
local Ticker = {}

---@class Spoke.Ticker: Spoke.Epoch
local methods = Ticker --[[@as table]]
methods.__index = methods

---@class Spoke.TickerInternal: Spoke.Ticker, Spoke.EpochInternal
---@field _pending Spoke.Heap<Spoke.EpochInternal>?
---@field _on_tick (fun(context: Spoke.TickContext))[]
---@field _paused boolean
---@field _is_ticking boolean
---@field _in_on_tick boolean
---@field _did_continue boolean
---@field _last_ticked Spoke.EpochInternal?
---@field _pass_count integer
---@field _max_passes integer
---@field _guard_entry integer
---@field _bootstrap_active boolean
local internal = Ticker --[[@as table]]
internal.__tostring = Epoch.__tostring
internal._default_name = "Ticker"
internal.is_ticker = true
internal.auto_arm_tick_after_init = false
setmetatable(Ticker, { __index = Epoch })

---@class Spoke.TickerBuilder
---@field private _builder Spoke.EpochBuilder
---@field private _ticker Spoke.TickerInternal
local TickerBuilder = {}
TickerBuilder.__index = TickerBuilder

---@class Spoke.TickerPorts
---@field private _ticker Spoke.Ticker
local TickerPorts = {}
TickerPorts.__index = TickerPorts

---@class Spoke.TickContext
---@field private _ticker Spoke.Ticker
local TickContext = {}
TickContext.__index = TickContext

local DEFAULT_MAX_PASSES = 1000

---@generic T
---@param value T
---@return T
local function identity(value)
  return value
end

---@param name string
---@param definition? Spoke.EpochDefinition
---@return table
function Ticker.extend(name, definition)
  return EpochClass.define(Ticker, name, definition, Epoch.__tostring)
end

---@param ... any
---@return Spoke.Ticker
function Ticker.new(...)
  return EpochClass.new_instance(Ticker, ...)
end

---@param s Spoke.TickerBuilder
---@return Spoke.Epoch
---@diagnostic disable-next-line: unused
function methods:bootstrap(s)
  local _ = s
  error("Ticker subclasses must implement bootstrap", 2)
end

---@param ticker Spoke.TickerInternal
local function run_on_tick_callbacks(ticker)
  for _, callback in ipairs(ticker._on_tick) do
    if not ticker._paused then
      callback(setmetatable({ _ticker = ticker }, TickContext))
    end
  end
end

---@param ticker Spoke.TickerInternal
local function assert_pass_advanced(ticker)
  if not ticker._did_continue and not ticker._paused then
    error("Ticker must tick_next() or pause() during on_tick")
  end
end

---@param ticker Spoke.TickerInternal
local function request_next_pass(ticker)
  if ticker:has_pending() and not ticker._paused then
    ticker:_request_upstream()
  end
end

---@param ticker Spoke.TickerInternal
local function run_on_tick_pass(ticker)
  run_on_tick_callbacks(ticker)
  assert_pass_advanced(ticker)
  request_next_pass(ticker)
end

---@param ticker Spoke.TickerInternal
---@return Spoke.EpochTickFn
local function make_tick_block(ticker)
  return function()
    if ticker._paused or not ticker:has_pending() then
      return
    end
    ticker._did_continue = false
    ticker._in_on_tick = true
    local tick_ok, tick_error = xpcall(run_on_tick_pass, identity, ticker)
    ticker._in_on_tick = false
    if not tick_ok then
      error(tick_error, 0)
    end
  end
end

---@param builder Spoke.EpochBuilder
---@return Spoke.EpochTickFn
function methods:init(builder)
  local this = self --[[@as Spoke.TickerInternal]]
  this._pending = Heap.new(function(a, b)
    return a:compare_to(b)
  end)
  this._on_tick = {}
  this._paused = false
  this._is_ticking = false
  this._in_on_tick = false
  this._last_ticked = nil
  this._pass_count = 0
  this._max_passes = DEFAULT_MAX_PASSES
  this._guard_entry = -1
  this._bootstrap_active = true
  local ticker_builder = setmetatable({
    _builder = builder,
    _ticker = this,
  }, TickerBuilder)
  local ok, root = xpcall(function()
    return this:bootstrap(ticker_builder)
  end, identity)
  this._bootstrap_active = false
  if not ok then
    error(root, 0)
  end
  if type(root) ~= "table" or type((root --[[@as Spoke.EpochInternal]])._attach) ~= "function" then
    error("Ticker bootstrap must return an unattached Epoch", 2)
  end
  builder:call(root)

  return make_tick_block(this)
end

function internal:_request_upstream()
  if self._is_manual then
    return
  end
  local request = function()
    if self._is_tree then
      ---@cast self Spoke.SpokeTreeInternal
      SpokeRuntime.schedule(self)
    elseif self._request_tick then
      self._request_tick()
    end
  end
  local frame = self._frame_handle
  if frame and frame:is_alive() then
    frame:on_pop_self(request)
  else
    request()
  end
end

---@param node Spoke.Epoch
---@return boolean
local function is_live(node)
  return not (node.is_detached or node.fault)
end

---@param ticker Spoke.TickerInternal
---@param had_pending boolean
---@return boolean
local function should_request_upstream(ticker, had_pending)
  return not ticker._is_ticking
    and not had_pending
    and not ticker._paused
end

---@param epoch Spoke.EpochInternal
function internal:_schedule(epoch)
  if not (is_live(self) and is_live(epoch)) then
    return
  end
  local pending = self._pending
  if not pending then
    return
  end
  local had_pending = self:has_pending()
  pending:insert(epoch)
  if should_request_upstream(self, had_pending) then
    self:_request_upstream()
  end
end

---@return boolean
function methods:has_pending()
  local pending = (self --[[@as Spoke.TickerInternal]])._pending
  if not pending then
    return false
  end
  while pending:count() > 0 do
    local epoch = pending:peek_min()
    if epoch.is_detached or epoch.fault then
      pending:remove_min()
    else
      return true
    end
  end
  return false
end

---@return Spoke.Epoch?
function methods:peek_next()
  if not self:has_pending() then
    return nil
  end
  local pending = (self --[[@as Spoke.TickerInternal]])._pending
  if not pending then
    return nil
  end
  return pending:peek_min()
end

---@param ticker Spoke.TickerInternal
local function reset_loop_guard(ticker)
  ticker._last_ticked = nil
  ticker._pass_count = 0
end

---@param ticker Spoke.TickerInternal
---@param next_epoch Spoke.EpochInternal
local function check_loop_guard(ticker, next_epoch)
  local entry = SpokeRuntime._entry_count
  if entry ~= ticker._guard_entry then
    ticker._guard_entry = entry
    reset_loop_guard(ticker)
  end
  if ticker._last_ticked then
    local went_backwards
    if ticker._last_ticked == next_epoch then
      went_backwards = not next_epoch._is_ticker
    else
      went_backwards = ticker._last_ticked:compare_to(next_epoch) > 0
    end
    if went_backwards then
      ticker._pass_count = ticker._pass_count + 1
    end
  end
  ticker._last_ticked = next_epoch
  if ticker._max_passes > 0 and ticker._pass_count > ticker._max_passes then
    reset_loop_guard(ticker)
    error("Exceed oscillation limit - possible infinite loop", 0)
  end
end

---@return Spoke.Epoch
function methods:tick_next()
  local this = self --[[@as Spoke.TickerInternal]]
  if not this._in_on_tick then
    error("tick_next() must be called from within an on_tick block", 2)
  end
  local pending = this._pending
  if not pending or not this:has_pending() then
    error("Ticker has no pending epochs", 2)
  end
  this._did_continue = true
  check_loop_guard(this, pending:peek_min())
  local epoch = pending:remove_min()
  epoch:_tick()
  if not this:has_pending() then
    reset_loop_guard(this)
  end
  return epoch
end

function methods:pause()
  local this = self --[[@as Spoke.TickerInternal]]
  if this._paused then
    return
  end
  this._paused = true
end

function methods:resume()
  local this = self --[[@as Spoke.TickerInternal]]
  if not this._paused then
    return
  end
  this._paused = false
  if this:has_pending() and not this._is_ticking then
    this:_request_upstream()
  end
end

function internal:_discard_pending()
  local pending = self._pending
  if not pending then
    return
  end
  while pending:count() > 0 do
    local epoch = pending:remove_min()
    epoch._is_pending = false
    if type(epoch._discard_pending) == "function" then
      epoch:_discard_pending()
    end
  end
end

function internal:_clear_pending()
  self:_discard_pending()
end

function TickerBuilder:_assert_bootstrap()
  local frame = self._ticker._frame_handle
  if not self._ticker._bootstrap_active
    or not frame
    or not frame:is_top() then
    error("Cannot mutate a Ticker outside its bootstrap block", 3)
  end
end

---@param fn fun(context: Spoke.TickContext)
function TickerBuilder:on_tick(fn)
  self:_assert_bootstrap()
  if type(fn) ~= "function" then
    error("TickerBuilder:on_tick expects a function", 2)
  end
  self._ticker._on_tick[#self._ticker._on_tick + 1] = fn
end

---@param max_passes integer
function TickerBuilder:loop_guard(max_passes)
  self:_assert_bootstrap()
  self._ticker._max_passes = max_passes
end

---@return Spoke.TickerPorts
function TickerBuilder:ports()
  return setmetatable({ _ticker = self._ticker }, TickerPorts)
end

---@generic T: Spoke.Disposable
---@param resource T
---@return T
function TickerBuilder:use(resource)
  return self._builder:use(resource)
end

---@generic T: Spoke.Epoch
---@param epoch T
---@return T
function TickerBuilder:call(epoch)
  return self._builder:call(epoch)
end

---@generic T
---@param key string
---@param value T
---@return T
function TickerBuilder:export(key, value)
  return self._builder:export(key, value)
end

---@param key string
---@return any
function TickerBuilder:import(key)
  return self._builder:import(key)
end

---@param key string
---@return boolean found
---@return any value
function TickerBuilder:try_import(key)
  return self._builder:try_import(key)
end

---@param fn fun()
function TickerBuilder:on_cleanup(fn)
  self._builder:on_cleanup(fn)
end

---@param message any
function TickerBuilder:log(message)
  self._builder:log(message)
end

---@return boolean
function TickerPorts:has_pending()
  return self._ticker:has_pending()
end

---@return Spoke.Epoch?
function TickerPorts:peek_next()
  return self._ticker:peek_next()
end

function TickerPorts:pause()
  self._ticker:pause()
end

function TickerPorts:resume()
  self._ticker:resume()
end

---@return Spoke.Epoch
function TickContext:tick_next()
  return self._ticker:tick_next()
end

return Ticker
