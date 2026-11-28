---@meta common.packages.spoke.runtime.spoke_runtime
-- 上游 spoke 运行时公开契约声明（仅类型）。

---@class SpokeRuntimeAPI
local M = {}

---@type table[]
M.frames = {}

M.FrameKind = {
  None = "None",
  Init = "Init",
  Tick = "Tick",
  Dock = "Dock",
  Bootstrap = "Bootstrap",
}

---@return integer
function M.next_timestamp() end

---@param frame table
---@return any
function M.push(frame) end

---@return any
function M.pop() end

---@return table[]
function M.snapshot_frames() end

---@return any
function M.current_handle() end

---@param fn fun()
function M.batch(fn) end

---@param message string
---@param cause? any
function M._log(message, cause) end

---@return boolean
function M._has_pending() end

---@param tree any
function M.schedule(tree) end

---@param tree any
function M.try_scoped_layer_boost(tree) end

---@param tree any
function M.tick_tree(tree) end

function M.try_flush() end

function M._reset_for_tests() end

return M
