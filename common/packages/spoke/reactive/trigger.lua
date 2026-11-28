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
---@field private _dispatch_list table<integer, (fun(value: any))?>?
---@field private _unsub_fn (fun(id: any))?
local methods = Trigger --[[@as table]]
methods.__index = methods

---@param name? string
---@return Spoke.Trigger<any>
function Trigger.new(name)
  return setmetatable({
    name = name,
    _subs = {},
    _dead_count = 0,
    _id_count = 0,
    _events = {},
    _event_head = 1,
    _event_tail = 0,
    _is_flushing = false,
    _dispatch_list = nil,
    _unsub_fn = nil,
  }, methods)
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
  local unsub_fn = self._unsub_fn
  if unsub_fn == nil then
    local trigger = self
    unsub_fn = function(sub_id)
      trigger:_unsub_by_id(sub_id)
    end
    self._unsub_fn = unsub_fn
  end
  return SpokeHandle.of(id, unsub_fn)
end

function methods:subscribe(fn)
  return self:_subscribe(fn)
end

---@param id integer
function methods:_unsub_by_id(id)
  local subs = self._subs
  local lo, hi = 1, #subs
  while lo <= hi do
    local mid = (lo + hi) // 2
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
  local subs = self._subs
  local dead = self._dead_count
  for index = 1, #subs do
    local sub = subs[index]
    if sub.fn == fn then
      sub.fn = nil
      dead = dead + 1
    end
  end
  self._dead_count = dead
end

function methods:unsubscribe(fn)
  if type(fn) ~= "function" then
    error("Trigger.unsubscribe expects a function", 2)
  end
  self:_unsub_by_fn(fn)
end

---@param fn fun(value: any)
---@param payload any
local function invoke_subscriber(fn, payload)
  local ok, err = pcall(fn, payload)
  if not ok then
    SpokeError.log("Trigger subscriber error", err)
  end
end

---@param payload any
function methods:_dispatch(payload)
  local dispatch_list = self._dispatch_list
  if dispatch_list == nil then
    dispatch_list = {}
    self._dispatch_list = dispatch_list
  end
  local subs = self._subs
  local count = 0
  for index = 1, #subs do
    local fn = subs[index].fn
    if fn ~= nil then
      count = count + 1
      dispatch_list[count] = fn
    end
  end
  for index = 1, count do
    local fn = dispatch_list[index]
    dispatch_list[index] = nil
    if fn ~= nil then
      invoke_subscriber(fn, payload)
    end
  end
end

function methods:_drain()
  local events = self._events
  while self._event_head <= self._event_tail do
    local head = self._event_head
    local payload = events[head]
    events[head] = nil
    self._event_head = head + 1
    self:_dispatch(payload)
  end
  self._event_head = 1
  self._event_tail = 0
end

function methods:_flush()
  if self._is_flushing then
    return
  end
  self._is_flushing = true
  local ok, err = pcall(methods._drain, self)
  self._is_flushing = false
  self._subs, self._dead_count = compact(self._subs, self._dead_count)
  if not ok then
    error(err, 0)
  end
end

function methods:invoke(payload)
  local tail = self._event_tail + 1
  self._event_tail = tail
  self._events[tail] = payload
  SpokeRuntime.batch(methods._flush, self)
end

return Trigger
