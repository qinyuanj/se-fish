---@class Spoke.Frame
---@field epoch Spoke.Epoch?
---@field type Spoke.FrameKind|string|nil
---@field kind Spoke.FrameKind|string|nil
---@field phase string?

---@class Spoke.FrameAux
---@field version integer
---@field on_pop (fun())[]?

---@class Spoke.RuntimeFrames
---@field Handle Spoke.FrameHandle
local RuntimeFrames = {}

---@class Spoke.FrameHandle
---@field private _runtime Spoke.SpokeRuntime
---@field private _index integer
---@field private _version integer
local Handle = {}
Handle.__index = Handle

---@param runtime Spoke.SpokeRuntime
---@param frame? Spoke.Frame
---@return Spoke.FrameHandle
function RuntimeFrames.push(runtime, frame)
  if #runtime.frames == 0 then
    runtime._entry_count = runtime._entry_count + 1
  end
  frame = frame or {}
  frame.type = frame.type or frame.kind or "None"
  frame.kind = frame.kind or frame.type
  local index = #runtime.frames + 1
  local version = runtime._clock
  runtime._clock = version + 1
  runtime.frames[index] = frame
  runtime._frame_aux[index] = {
    version = version,
    on_pop = nil,
  }
  return setmetatable({
    _runtime = runtime,
    _index = index,
    _version = version,
  }, Handle)
end

---@param runtime Spoke.SpokeRuntime
function RuntimeFrames.pop(runtime)
  local frames = runtime.frames
  local index = #frames
  if index == 0 then
    error("SpokeRuntime frame stack is empty", 3)
  end
  local aux = runtime._frame_aux[index]
  ---@cast aux -nil
  frames[index] = nil
  runtime._frame_aux[index] = nil
  local actions = aux.on_pop
  if actions then
    for _, action in ipairs(actions) do
      action()
    end
  end
end

---@param runtime Spoke.SpokeRuntime
---@return Spoke.Frame[]
function RuntimeFrames.snapshot(runtime)
  local snapshot = {}
  for index, frame in ipairs(runtime.frames) do
    snapshot[index] = {
      epoch = frame.epoch,
      type = frame.type,
      kind = frame.kind,
      phase = frame.phase,
    }
  end
  return snapshot
end

---@param runtime Spoke.SpokeRuntime
---@return Spoke.FrameHandle?
function RuntimeFrames.current_handle(runtime)
  local index = #runtime.frames
  if index == 0 then
    return nil
  end
  local aux = runtime._frame_aux[index]
  ---@cast aux -nil
  return setmetatable({
    _runtime = runtime,
    _index = index,
    _version = aux.version,
  }, Handle)
end

---@return boolean
function Handle:is_alive()
  local runtime = self._runtime
  local aux = runtime._frame_aux[self._index]
  return aux ~= nil
    and aux.version == self._version
    and runtime.frames[self._index] ~= nil
end

---@return boolean
function Handle:is_top()
  return self:is_alive() and self._index == #self._runtime.frames
end

---@return Spoke.Frame?
function Handle:frame()
  if self:is_alive() then
    return self._runtime.frames[self._index]
  end
  return nil
end

---@param fn fun()
function Handle:on_pop_self(fn)
  if type(fn) ~= "function" then
    error("SpokeRuntime frame action must be a function", 2)
  end
  if not self:is_alive() then
    fn()
    return
  end
  local aux = self._runtime._frame_aux[self._index]
  ---@cast aux -nil
  aux.on_pop = aux.on_pop or {}
  aux.on_pop[#aux.on_pop + 1] = fn
end

RuntimeFrames.Handle = Handle

return RuntimeFrames
