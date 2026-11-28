local IntrospectLabels = require("common.packages.spoke.runtime.introspect_labels")

---@class Spoke.IntrospectTree
local IntrospectTree = {}

---@param epoch Spoke.Epoch
---@param store? Spoke.Epoch[]
---@return Spoke.Epoch[]
function IntrospectTree.get_children(epoch, store)
  store = store or {}
  local internal = epoch --[[@as Spoke.EpochInternal]]
  if type(internal._get_children) == "function" then
    return internal:_get_children(store)
  end
  return store
end

---@param epoch Spoke.Epoch
---@return Spoke.Epoch?
function IntrospectTree.get_parent(epoch)
  local internal = epoch --[[@as Spoke.EpochInternal]]
  if type(internal._get_parent) == "function" then
    return internal:_get_parent()
  end
  return internal._parent
end

---@param epoch Spoke.Epoch
---@param visit fun(child: Spoke.Epoch)
local function walk_children(epoch, visit)
  for _, child in ipairs(IntrospectTree.get_children(epoch)) do
    visit(child)
  end
end

local scratch_stack = {}

---@param epoch Spoke.Epoch
---@return integer
function IntrospectTree.count_nodes(epoch)
  for i = #scratch_stack, 1, -1 do
    scratch_stack[i] = nil
  end
  local count = 0
  local top = 1
  scratch_stack[1] = epoch
  while top > 0 do
    local node = scratch_stack[top]
    scratch_stack[top] = nil
    top = top - 1
    count = count + 1
    local internal = node --[[@as Spoke.EpochInternal]]
    if type(internal._get_children) == "function" then
      local children = internal:_get_children(scratch_stack)
      if children ~= scratch_stack then
        for i = 1, #children do
          top = top + 1
          scratch_stack[top] = children[i]
        end
      else
        top = #scratch_stack
      end
    end
  end
  return count
end

---@generic T, K
---@param values T[]
---@param key_of fun(value: T): K?
---@return K[]
local function collect_distinct(values, key_of)
  local distinct = {}
  local seen = {}
  for _, value in ipairs(values) do
    local key = key_of(value)
    if key ~= nil and not seen[key] then
      seen[key] = true
      distinct[#distinct + 1] = key
    end
  end
  return distinct
end

---@param epoch Spoke.Epoch
---@return Spoke.Epoch
local function root_of(epoch)
  local root = epoch
  while true do
    local parent = IntrospectTree.get_parent(root)
    if parent == nil then
      return root
    end
    root = parent
  end
end

---@param frames Spoke.Frame[]
---@return Spoke.Epoch[]
function IntrospectTree.roots_from_frames(frames)
  ---@type Spoke.Epoch[]
  local epochs = collect_distinct(frames, function(frame)
    return frame.epoch
  end)
  return collect_distinct(epochs, root_of)
end

---@param roots Spoke.Epoch[]
---@return integer
function IntrospectTree.total_nodes(roots)
  local total = 0
  for _, root in ipairs(roots) do
    total = total + IntrospectTree.count_nodes(root)
  end
  return total
end

---@param roots Spoke.Epoch[]
---@param frames Spoke.Frame[]
---@return string
function IntrospectTree.render(roots, frames)
  local lines = {}
  ---@param epoch Spoke.Epoch
  ---@param depth integer
  local function render_epoch(epoch, depth)
    local label = IntrospectLabels.append_fault_suffix(
      IntrospectLabels.frame_epoch_label(epoch, frames), epoch)
    lines[#lines + 1] = string.rep("    ", depth) .. "|--" .. label
    walk_children(epoch, function(child)
      render_epoch(child, depth + 1)
    end)
  end
  for _, root in ipairs(roots) do
    render_epoch(root, 0)
  end
  return table.concat(lines, "\n")
end

return IntrospectTree
