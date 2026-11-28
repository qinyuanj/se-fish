local IntrospectLabels = require("common.packages.spoke.runtime.introspect_labels")
local IntrospectTree = require("common.packages.spoke.runtime.introspect_tree")

---@class Spoke.SpokeIntrospect
local SpokeIntrospect = {}

local FRAME_TRACE_HEADER = "<------------ Spoke Frame Trace ------------>"
local TREE_TRACE_HEADER = "<------------ Spoke Tree Trace ------------>"
local TREE_SIZE_THRESHOLD = 50

SpokeIntrospect.get_children = IntrospectTree.get_children
SpokeIntrospect.get_parent = IntrospectTree.get_parent

---@param frames? Spoke.Frame[]
---@return string
function SpokeIntrospect.stack_trace(frames)
  frames = frames or {}
  if #frames == 0 then
    return "(empty)"
  end

  local width = #tostring(#frames)
  local lines = {}
  for index, frame in ipairs(frames) do
    local epoch = frame.epoch
    local label = string.format(
      "%s: %s %s <%s>",
      string.format("%" .. width .. "d", index - 1),
      IntrospectLabels.frame_kind(frame),
      IntrospectLabels.epoch_frame_name(epoch),
      IntrospectLabels.epoch_type_name(epoch))
    lines[index] = IntrospectLabels.append_fault_suffix(label, epoch)
  end
  return table.concat(lines, "\n")
end

SpokeIntrospect.frame_trace = SpokeIntrospect.stack_trace

---@param roots Spoke.Epoch[]
---@param frames Spoke.Frame[]
---@return string
local function tree_section(roots, frames)
  local total_nodes = IntrospectTree.total_nodes(roots)
  if total_nodes > TREE_SIZE_THRESHOLD then
    return "(tree too large to display - " .. total_nodes .. " nodes)"
  end
  return IntrospectTree.render(roots, frames)
end

---@param frames? Spoke.Frame[]
---@return string
function SpokeIntrospect.tree_trace(frames)
  frames = frames or {}
  if #frames == 0 then
    return "(empty)"
  end

  local roots = IntrospectTree.roots_from_frames(frames)
  return FRAME_TRACE_HEADER
    .. "\n" .. SpokeIntrospect.stack_trace(frames)
    .. "\n" .. TREE_TRACE_HEADER
    .. "\n" .. tree_section(roots, frames)
end

return SpokeIntrospect
