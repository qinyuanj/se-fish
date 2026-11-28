---@class Spoke.Frame
---@field epoch Spoke.Epoch?
---@field type Spoke.FrameKind|string|nil
---@field kind? Spoke.FrameKind|string|nil
---@field phase? string

---@class Spoke.RuntimeFrames
---@field Handle Spoke.FrameHandle
local RuntimeFrames = {}

---@class Spoke.FrameHandle
---@field package _runtime Spoke.SpokeRuntime
---@field package _index integer
---@field package _version integer
local Handle = {}
Handle.__index = Handle

---@param runtime Spoke.SpokeRuntime
---@param frame? Spoke.Frame
---@param reuse_handle? Spoke.FrameHandle
---@return Spoke.FrameHandle
function RuntimeFrames.push(runtime, frame, reuse_handle)
  local frames = runtime.frames
  local index = #frames + 1
  if index == 1 then
    runtime._entry_count = runtime._entry_count + 1
  end
  if frame == nil then
    frame = { type = "None" }
  elseif frame.type == nil then
    frame.type = frame.kind or "None"
  end
  local version = runtime._clock
  runtime._clock = version + 1
  frames[index] = frame
  runtime._frame_versions[index] = version
  runtime._frame_on_pop[index] = nil
  if reuse_handle ~= nil then
    reuse_handle._index = index
    reuse_handle._version = version
    return reuse_handle
  end
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
  local actions = runtime._frame_on_pop[index]
  frames[index] = nil
  runtime._frame_versions[index] = nil
  runtime._frame_on_pop[index] = nil
  if actions then
    for i = 1, #actions do
      actions[i]()
    end
  end
end

---@param runtime Spoke.SpokeRuntime
---@return Spoke.Frame[]
function RuntimeFrames.snapshot(runtime)
  local frames = runtime.frames
  local count = #frames
  if count == 0 then
    return {}
  end
  return table.move(frames, 1, count, 1, {})
end

---@param runtime Spoke.SpokeRuntime
---@return Spoke.FrameHandle?
function RuntimeFrames.current_handle(runtime)
  local index = #runtime.frames
  if index == 0 then
    return nil
  end
  local version = runtime._frame_versions[index]
  ---@cast version -nil
  return setmetatable({
    _runtime = runtime,
    _index = index,
    _version = version,
  }, Handle)
end

---@return boolean
function Handle:is_alive()
  local runtime = self._runtime
  local index = self._index
  return runtime.frames[index] ~= nil
    and runtime._frame_versions[index] == self._version
end

---@return boolean
function Handle:is_top()
  local runtime = self._runtime
  local index = self._index
  return index == #runtime.frames
    and runtime.frames[index] ~= nil
    and runtime._frame_versions[index] == self._version
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
  local on_pop = self._runtime._frame_on_pop
  local index = self._index
  local actions = on_pop[index]
  if actions == nil then
    actions = { fn }
    on_pop[index] = actions
  else
    actions[#actions + 1] = fn
  end
end

RuntimeFrames.Handle = Handle

return RuntimeFrames
