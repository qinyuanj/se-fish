local Epoch = require("common.packages.spoke.runtime.epoch")
local EpochClass = require("common.packages.spoke.runtime.epoch_class")
local Heap = require("common.packages.spoke.runtime.heap")
local SpokeRuntime = require("common.packages.spoke.runtime.spoke_runtime")

local Ticker = {}
Ticker.__index = Ticker
Ticker.__tostring = Epoch.__tostring
Ticker._default_name = "Ticker"
Ticker.is_ticker = true
Ticker.auto_arm_tick_after_init = false
setmetatable(Ticker, { __index = Epoch })

local TickerBuilder = {}
TickerBuilder.__index = TickerBuilder

local TickerPorts = {}
TickerPorts.__index = TickerPorts

local TickContext = {}
TickContext.__index = TickContext

local DEFAULT_MAX_PASSES = 1000

local function identity(value)
  return value
end

function Ticker.extend(name, definition)
  return EpochClass.define(Ticker, name, definition, Epoch.__tostring)
end

function Ticker.new(...)
  return EpochClass.new_instance(Ticker, ...)
end

function Ticker:bootstrap()
  error("Ticker subclasses must implement bootstrap", 2)
end

local function run_on_tick_callbacks(ticker)
  for _, callback in ipairs(ticker._on_tick) do
    if not ticker._paused then
      callback(setmetatable({ _ticker = ticker }, TickContext))
    end
  end
end

local function assert_pass_advanced(ticker)
  if not ticker._did_continue and not ticker._paused then
    error("Ticker must tick_next() or pause() during on_tick")
  end
end

local function request_next_pass(ticker)
  if ticker:has_pending() and not ticker._paused then
    ticker:_request_upstream()
  end
end

local function run_on_tick_pass(ticker)
  run_on_tick_callbacks(ticker)
  assert_pass_advanced(ticker)
  request_next_pass(ticker)
end

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

function Ticker:init(builder)
  self._pending = Heap.new(function(a, b)
    return a:compare_to(b)
  end)
  self._on_tick = {}
  self._paused = false
  self._is_ticking = false
  self._in_on_tick = false
  self._last_ticked = nil
  self._pass_count = 0
  self._max_passes = DEFAULT_MAX_PASSES
  self._guard_entry = -1
  self._bootstrap_active = true
  local ticker_builder = setmetatable({
    _builder = builder,
    _ticker = self,
  }, TickerBuilder)
  local ok, root = xpcall(function()
    return self:bootstrap(ticker_builder)
  end, identity)
  self._bootstrap_active = false
  if not ok then
    error(root, 0)
  end
  if type(root) ~= "table" or type(root._attach) ~= "function" then
    error("Ticker bootstrap must return an unattached Epoch", 2)
  end
  builder:call(root)

  return make_tick_block(self)
end

function Ticker:_request_upstream()
  if self._is_manual then
    return
  end
  local request = function()
    if self._is_tree then
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

local function is_live(node)
  return not (node.is_detached or node.fault)
end

local function should_request_upstream(ticker, had_pending)
  return not ticker._is_ticking
    and not had_pending
    and not ticker._paused
end

function Ticker:_schedule(epoch)
  if not (is_live(self) and is_live(epoch)) then
    return
  end
  local had_pending = self:has_pending()
  self._pending:insert(epoch)
  if should_request_upstream(self, had_pending) then
    self:_request_upstream()
  end
end

function Ticker:has_pending()
  if not self._pending then
    return false
  end
  while self._pending:count() > 0 do
    local epoch = self._pending:peek_min()
    if epoch.is_detached or epoch.fault then
      self._pending:remove_min()
    else
      return true
    end
  end
  return false
end

function Ticker:peek_next()
  if not self:has_pending() then
    return nil
  end
  return self._pending:peek_min()
end

local function reset_loop_guard(ticker)
  ticker._last_ticked = nil
  ticker._pass_count = 0
end

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

function Ticker:tick_next()
  if not self._in_on_tick then
    error("tick_next() must be called from within an on_tick block", 2)
  end
  if not self:has_pending() then
    error("Ticker has no pending epochs", 2)
  end
  self._did_continue = true
  check_loop_guard(self, self._pending:peek_min())
  local epoch = self._pending:remove_min()
  epoch:_tick()
  if not self:has_pending() then
    reset_loop_guard(self)
  end
  return epoch
end

function Ticker:pause()
  if self._paused then
    return
  end
  self._paused = true
end

function Ticker:resume()
  if not self._paused then
    return
  end
  self._paused = false
  if self:has_pending() and not self._is_ticking then
    self:_request_upstream()
  end
end

function Ticker:_discard_pending()
  if not self._pending then
    return
  end
  while self._pending:count() > 0 do
    local epoch = self._pending:remove_min()
    epoch._is_pending = false
    if type(epoch._discard_pending) == "function" then
      epoch:_discard_pending()
    end
  end
end

function Ticker:_clear_pending()
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

function TickerBuilder:on_tick(fn)
  self:_assert_bootstrap()
  if type(fn) ~= "function" then
    error("TickerBuilder:on_tick expects a function", 2)
  end
  self._ticker._on_tick[#self._ticker._on_tick + 1] = fn
end

function TickerBuilder:loop_guard(max_passes)
  self:_assert_bootstrap()
  self._ticker._max_passes = max_passes
end

function TickerBuilder:ports()
  return setmetatable({ _ticker = self._ticker }, TickerPorts)
end

function TickerBuilder:use(resource)
  return self._builder:use(resource)
end

function TickerBuilder:call(epoch)
  return self._builder:call(epoch)
end

function TickerBuilder:export(key, value)
  return self._builder:export(key, value)
end

function TickerBuilder:import(key)
  return self._builder:import(key)
end

function TickerBuilder:try_import(key)
  return self._builder:try_import(key)
end

function TickerBuilder:on_cleanup(fn)
  return self._builder:on_cleanup(fn)
end

function TickerBuilder:log(message)
  return self._builder:log(message)
end

function TickerPorts:has_pending()
  return self._ticker:has_pending()
end

function TickerPorts:peek_next()
  return self._ticker:peek_next()
end

function TickerPorts:pause()
  self._ticker:pause()
end

function TickerPorts:resume()
  self._ticker:resume()
end

function TickContext:tick_next()
  return self._ticker:tick_next()
end

return Ticker
