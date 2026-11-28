local SpokeHandle = require("common.packages.spoke.runtime.spoke_handle")
local SpokeError = require("common.packages.spoke.runtime.spoke_error")
local SpokeRuntime = require("common.packages.spoke.runtime.spoke_runtime")

---@class Spoke.Subscribable<T>
---@field subscribe fun(self: any, fn: fun(value: T)): Spoke.SpokeHandle

---@class Spoke.Signal<T>: Spoke.Subscribable<T>
---@field now fun(self: any): T
---@field unsubscribe fun(self: any, fn: fun(value: T))

---@alias Spoke.TriggerList Spoke.Subscribable<any> | Spoke.Subscribable<any>[]

---@class Spoke.TriggerSubscription<T>
---@field id integer
---@field fn (fun(value: T))?

---@class Spoke.Trigger<T>: Spoke.Subscribable<T>
---@field name string?
---@field subscribe fun(self: Spoke.Trigger<T>, fn: fun(value: T)): Spoke.SpokeHandle
---@field unsubscribe fun(self: Spoke.Trigger<T>, fn: fun(value: T))
---@field invoke fun(self: Spoke.Trigger<T>, payload?: T)

---@class Spoke.TriggerClass
local Trigger = {}

---@class Spoke.TriggerImpl: Spoke.Trigger<any>
---@field private _subs Spoke.TriggerSubscription<any>[]
---@field private _dead_count integer
---@field private _id_count integer
---@field private _events table<integer, any>
---@field private _event_head integer
---@field private _event_tail integer
---@field private _is_flushing boolean
---@field private _dispatch_list (fun(value: any))[]?
local methods = Trigger --[[@as table]]
methods.__index = methods

---@param name? string
---@return Spoke.Trigger<any>
function Trigger.new(name)
  local self = setmetatable({
    name = name,
    _subs = {},
    _dead_count = 0,
    _id_count = 0,
    _events = {},
    _event_head = 1,
    _event_tail = 0,
    _is_flushing = false,
    _dispatch_list = nil,
  }, methods)
  return self
end

---@generic T
---@param subs Spoke.TriggerSubscription<T>[]
---@param dead_count integer
---@return Spoke.TriggerSubscription<T>[]
---@return integer
local function compact(subs, dead_count)
  if dead_count * 2 <= #subs then
    return subs, dead_count
  end
  local write = 0
  for read = 1, #subs do
    if subs[read].fn ~= nil then
      write = write + 1
      subs[write] = subs[read]
    end
  end
  for index = write + 1, #subs do
    subs[index] = nil
  end
  return subs, 0
end

---@param fn fun(value: any)
---@return Spoke.SpokeHandle
function methods:_subscribe(fn)
  if type(fn) ~= "function" then
    error("Trigger.subscribe expects a function", 2)
  end
  self._subs, self._dead_count = compact(self._subs, self._dead_count)
  local id = self._id_count
  self._id_count = id + 1
  local sub = { id = id, fn = fn }
  local subs = self._subs
  subs[#subs + 1] = sub
  local trigger = self
  return SpokeHandle.of(id, function()
    trigger:_unsub_by_id(id)
  end)
end

function methods:subscribe(fn)
  return self:_subscribe(fn)
end

---@param id integer
function methods:_unsub_by_id(id)
  local subs = self._subs
  local lo, hi = 1, #subs
  while lo <= hi do
    local mid = math.floor((lo + hi) / 2)
    local sub = subs[mid]
    ---@cast sub -nil
    if sub.id < id then
      lo = mid + 1
    elseif sub.id > id then
      hi = mid - 1
    else
      if sub.fn == nil then
        return
      end
      sub.fn = nil
      self._dead_count = self._dead_count + 1
      return
    end
  end
end

---@param fn fun(value: any)
function methods:_unsub_by_fn(fn)
  local ids = {}
  for _, sub in ipairs(self._subs) do
    if sub.fn == fn then
      ids[#ids + 1] = sub.id
    end
  end
  for _, id in ipairs(ids) do
    self:_unsub_by_id(id)
  end
end

function methods:unsubscribe(fn)
  if type(fn) ~= "function" then
    error("Trigger.unsubscribe expects a function", 2)
  end
  self:_unsub_by_fn(fn)
end

---@return (fun(value: any))[]
function methods:_reset_dispatch_list()
  local list = self._dispatch_list
  if list == nil then
    list = {}
    self._dispatch_list = list
    return list
  end
  for index = 1, #list do
    list[index] = nil
  end
  return list
end

---@param fn fun(value: any)
---@param payload any
local function invoke_subscriber(fn, payload)
  local ok, err = pcall(function()
    fn(payload)
  end)
  if not ok then
    SpokeError.log("Trigger subscriber error", err)
  end
end

---@param payload any
function methods:_dispatch(payload)
  local dispatch_list = self:_reset_dispatch_list()
  for _, sub in ipairs(self._subs) do
    if sub.fn ~= nil then
      dispatch_list[#dispatch_list + 1] = sub.fn
    end
  end
  for _, fn in ipairs(dispatch_list) do
    invoke_subscriber(fn, payload)
  end
end

function methods:_flush()
  if self._is_flushing then
    return
  end
  self._is_flushing = true
  local ok, err = pcall(function()
    while self._event_head <= self._event_tail do
      local payload = self._events[self._event_head]
      self._events[self._event_head] = nil
      self._event_head = self._event_head + 1
      self:_dispatch(payload)
    end
  end)
  self._is_flushing = false
  self._subs, self._dead_count = compact(self._subs, self._dead_count)
  if not ok then
    error(err, 0)
  end
end

function methods:invoke(payload)
  local events = self._events
  self._event_tail = self._event_tail + 1
  events[self._event_tail] = payload
  SpokeRuntime.batch(function()
    self:_flush()
  end)
end

return Trigger
