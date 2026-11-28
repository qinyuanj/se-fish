local Epoch = require("common.packages.spoke.runtime.epoch")
local SpokeRuntime = require("common.packages.spoke.runtime.spoke_runtime")
local DockSlots = require("common.packages.spoke.runtime.dock_slots")

---@generic T
---@param value T
---@return T
local function identity(value)
  return value
end

---@param key any
local function assert_key(key)
  if type(key) ~= "string" or key == "" then
    error("Dock keys must be non-empty strings", 3)
  end
end

---@param epoch any
local function assert_unattached_epoch(epoch)
  if type(epoch) ~= "table" or type(epoch._attach) ~= "function" then
    error("Dock:call expects an Epoch", 3)
  end
  if epoch._attached then
    error("Dock:call expects an unattached Epoch", 3)
  end
end

---@class Spoke.DockClass
local Dock = Epoch.extend("Dock", {
  ---@param self Spoke.DockInternal
  constructor = function(self)
    DockSlots.reset(self)
    self._is_detaching = false
  end,

  ---@param self Spoke.DockInternal
  ---@param s Spoke.EpochBuilder
  ---@return nil
  init = function(self, s)
    s:on_cleanup(function()
      self._is_detaching = true
      DockSlots.detach_all(self)
    end)
    return nil
  end,

  ---@param self Spoke.DockInternal
  _refresh_coords = function(self)
    (Epoch --[[@as Spoke.EpochClassInternal]])._refresh_coords(self)
    DockSlots.compact(self, true)
  end,

  ---@param self Spoke.DockInternal
  ---@param store? Spoke.Epoch[]
  ---@return Spoke.Epoch[]
  _get_children = function(self, store)
    return DockSlots.children(self, store)
  end,
})

local raw_new = (Dock --[[@as table]]).new

---@param name? string
---@return Spoke.Dock
function Dock.new(name)
  return raw_new(name)
end

---@class Spoke.Dock: Spoke.Epoch
local methods = Dock --[[@as table]]

---@class Spoke.DockInternal: Spoke.Dock, Spoke.EpochInternal
---@field _child_slots Spoke.DockSlot[]
---@field _slot_by_key table<string, integer>
---@field _live_count integer
---@field _is_detaching boolean
local internal = Dock --[[@as table]]

---@param key string
---@param epoch Spoke.EpochInternal
---@return Spoke.EpochInternal
function internal:_install(key, epoch)
  self:drop(key)
  if DockSlots.should_compact(self) then
    DockSlots.compact(self, false)
  end
  local index = DockSlots.append(self, key, epoch)
  local child_ticker = self._is_ticker and (self --[[@as Spoke.TickerInternal]]) or self._ticker
  epoch:_attach(self, index, child_ticker, nil, self._tree)
  return epoch
end

---@generic T: Spoke.Epoch
---@param key string
---@param epoch T
---@return T
function methods:call(key, epoch)
  local this = self --[[@as Spoke.DockInternal]]
  if this._is_detaching then
    error("Cannot Call while detaching", 2)
  end
  assert_key(key)
  assert_unattached_epoch(epoch)

  SpokeRuntime.push({ type = "Dock", epoch = this })
  local ok, result = xpcall(this._install, identity, this, key, epoch --[[@as Spoke.EpochInternal]])
  SpokeRuntime.pop()

  if not ok then
    error(result, 0)
  end
  return result
end

local cached_effect
local cached_parse_effect_args

---@generic T
---@overload fun(self: Spoke.Dock, key: string, name: string, block: (fun(s: Spoke.EffectBuilder): Spoke.Signal<T>?), ...: Spoke.TriggerList): Spoke.Effect<T>
---@overload fun(self: Spoke.Dock, key: string, block: (fun(s: Spoke.EffectBuilder): Spoke.Signal<T>?), ...: Spoke.TriggerList): Spoke.Effect<T>
---@param a string
---@param b any
---@param ... any
---@return Spoke.Effect<any>
function methods:effect(a, b, ...)
  assert_key(a)
  local Effect = cached_effect
  local parse_args = cached_parse_effect_args
  if Effect == nil or parse_args == nil then
    Effect = require("common.packages.spoke.reactive.effect")
    parse_args = require("common.packages.spoke.reactive.computation")._parse_effect_args
    cached_effect = Effect
    cached_parse_effect_args = parse_args
  end
  local name, block, triggers = parse_args(b, ...)
  if name ~= nil then
    return self:call(a, Effect.new(name, block, triggers))
  end
  return self:call(a, Effect.new(block, triggers))
end

---@param key? string
function methods:drop(key)
  local this = self --[[@as Spoke.DockInternal]]
  if key == nil then
    return
  end
  if type(key) ~= "string" then
    error("Dock keys must be non-empty strings", 2)
  end
  local child = DockSlots.find(this, key)
  if child == nil then
    return
  end

  DockSlots.release(this, key)

  local handle = child._frame_handle
  if handle and handle:is_alive() then
    handle:on_pop_self(function()
      child:detach()
    end)
  else
    child:detach()
  end
end

---@param reindex_all boolean
function internal:_compact(reindex_all)
  DockSlots.compact(self, reindex_all)
end

return Dock
