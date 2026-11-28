local spoke = require("common.packages.spoke.api")
local SpokeError = require("common.packages.spoke.runtime.spoke_error")

---@class SpokeEggy.Connection
---@field Disconnect fun(self: SpokeEggy.Connection)

---@class SpokeEggy.Signal
---@field Connect fun(self: any, fn: fun(...: any)): SpokeEggy.Connection

---@class SpokeEggy.DestroyingSignal: SpokeEggy.Signal
---@field Connect fun(self: SpokeEggy.DestroyingSignal, fn: fun()): SpokeEggy.Connection

---@class SpokeEggy.Unit
---@field Name? string
---@field Destroying SpokeEggy.DestroyingSignal

---@class SpokeEggy.BehaviourOptions
---@field name? string
---@field services? table<string, any>
---@field logger? Spoke.Logger

---@class SpokeEggy.API
local spoke_eggy = {}

---@class SpokeEggy.Behaviour
---@field root Spoke.SpokeTree
---@field unit SpokeEggy.Unit
---@field is_alive Spoke.State<boolean>
---@field package _connection SpokeEggy.Connection?
---@field package _disposed boolean
---@field package _pending_dispose boolean
local Behaviour = {}
Behaviour.__index = Behaviour

local DEFAULT_NAME = "SpokeBehaviour"
local TREE_SUFFIX = ":SpokeTree"

---@param unit any
---@return any
local function read_unit_name(unit)
  return unit.Name
end

---@param unit any
---@return string?
local function unit_name(unit)
  if unit == nil then
    return nil
  end
  local ok, name = pcall(read_unit_name, unit)
  if ok and type(name) == "string" and name ~= "" then
    return name
  end
  return nil
end

---@param signal any
---@return any
local function read_connect(signal)
  return signal.Connect
end

---@param unit any
---@return any
---@return any
local function read_destroying(unit)
  local candidate = unit.Destroying
  if candidate == nil then
    return nil, nil
  end
  return candidate, candidate.Connect
end

---@param unit any
---@return SpokeEggy.DestroyingSignal?
local function destroying_signal(unit)
  if unit == nil then
    return nil
  end
  local ok, signal, connect = pcall(read_destroying, unit)
  if ok and type(connect) == "function" then
    return signal --[[@as SpokeEggy.DestroyingSignal]]
  end
  return nil
end

---@param tree_name string
---@return Spoke.Logger
local function prefixed_logger(tree_name)
  local prefix = "[" .. tree_name .. "] "
  return {
    ---@param _ Spoke.Logger
    ---@param message any
    log = function(_, message)
      SpokeError.log(prefix .. tostring(message))
    end,
    ---@param _ Spoke.Logger
    ---@param message any
    error = function(_, message)
      SpokeError.log(prefix .. tostring(message))
    end,
  }
end

---@param unit SpokeEggy.Unit
---@param init fun(s: Spoke.EffectBuilder, behaviour: SpokeEggy.Behaviour)
---@param options? SpokeEggy.BehaviourOptions
---@return SpokeEggy.Behaviour
function spoke_eggy.behaviour(unit, init, options)
  if type(init) ~= "function" then
    error("spoke_eggy.behaviour expects an init function", 2)
  end

  local signal = destroying_signal(unit)
  if signal == nil then
    error("spoke_eggy.behaviour expects a Unit with a Destroying signal", 2)
  end

  options = options or {}
  local name = options.name
  if name == nil or name == "" then
    name = unit_name(unit)
  end
  if name == nil then
    name = DEFAULT_NAME
  end
  local tree_name = name .. TREE_SUFFIX

  ---@type SpokeEggy.Behaviour
  local self = setmetatable({
    ---@diagnostic disable-next-line: assign-type-mismatch
    root = nil,
    unit = unit,
    is_alive = spoke.State.new(true),
    _connection = nil,
    _disposed = false,
    _pending_dispose = false,
  }, Behaviour)

  local services = {}
  if type(options.services) == "table" then
    for key, value in pairs(options.services) do
      services[key] = value
    end
  end
  services.logger = options.logger or services.logger or prefixed_logger(tree_name)

  local tree = spoke.SpokeTree.spawn(tree_name, spoke.Effect.new("Init", function(s)
    init(s, self)
  end), services)
  self.root = tree

  if self._pending_dispose then
    self._pending_dispose = false
    self:dispose()
    return self
  end

  local behaviour = self
  self._connection = signal:Connect(function()
    behaviour:dispose()
  end)

  return self
end

---@param s Spoke.EpochBuilder | Spoke.EffectBuilder
---@param signal SpokeEggy.Signal
---@param fn fun(...: any)
---@return SpokeEggy.Connection
function spoke_eggy.connect(s, signal, fn)
  if type(s) ~= "table" or type(s.on_cleanup) ~= "function" then
    error("spoke_eggy.connect expects an EpochBuilder or EffectBuilder", 2)
  end
  if type(fn) ~= "function" then
    error("spoke_eggy.connect expects a callback function", 2)
  end
  local ok, connect_fn = false, nil
  if signal ~= nil then
    ok, connect_fn = pcall(read_connect, signal)
  end
  if not ok or type(connect_fn) ~= "function" then
    error("spoke_eggy.connect expects a Signal with a Connect method", 2)
  end
  local disconnected = false
  ---@type SpokeEggy.Connection?
  local connection = nil
  s:on_cleanup(function()
    if not disconnected and connection ~= nil and type(connection.Disconnect) == "function" then
      disconnected = true
      connection:Disconnect()
    end
  end)
  ---@type SpokeEggy.Connection
  local connected = connect_fn(signal, fn)
  connection = connected
  return connected
end

---@param self SpokeEggy.Behaviour
function Behaviour.dispose(self)
  if self._disposed then
    return
  end
  local tree = (self --[[@as { root: Spoke.SpokeTree? }]]).root
  if tree == nil then
    self._pending_dispose = true
    return
  end
  self._disposed = true
  self.is_alive:set(false)
  tree:dispose()
  local connection = self._connection
  self._connection = nil
  if connection ~= nil and type(connection.Disconnect) == "function" then
    connection:Disconnect()
  end
end

return spoke_eggy
