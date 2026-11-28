local PackedTreeCoords = require("common.packages.spoke.runtime.packed_tree_coords")

---@class Spoke.EpochCursor
local EpochCursor = {}

---@param epoch Spoke.EpochInternal
---@return integer
local function leaf_component(epoch)
  return epoch._tick_index
end

---@param epoch Spoke.EpochInternal
---@param depth integer
---@param target_depth integer
---@param component integer
---@return Spoke.EpochInternal
---@return integer
local function climb_to_depth(epoch, depth, target_depth, component)
  for _ = depth, target_depth + 1, -1 do
    component = epoch._coord_index
    epoch = epoch._parent --[[@as Spoke.EpochInternal]]
  end
  return epoch, component
end

---@param a Spoke.EpochInternal
---@param b Spoke.EpochInternal
---@param component_a integer
---@param component_b integer
---@return integer
---@return integer
local function climb_to_common_ancestor(a, b, component_a, component_b)
  while a ~= b do
    component_a = a._coord_index
    component_b = b._coord_index
    a = a._parent --[[@as Spoke.EpochInternal]]
    b = b._parent --[[@as Spoke.EpochInternal]]
  end
  return component_a, component_b
end

---@param is_less boolean
---@return integer
local function order_by(is_less)
  if is_less then
    return -1
  end
  return 1
end

---@param a Spoke.EpochInternal
---@param b Spoke.EpochInternal
---@return integer
function EpochCursor.compare(a, b)
  if a == b then
    return 0
  end
  local depth_a = a._depth
  local depth_b = b._depth
  local component_a = leaf_component(a)
  local component_b = leaf_component(b)

  a, component_a = climb_to_depth(a, depth_a, depth_b, component_a)
  b, component_b = climb_to_depth(b, depth_b, depth_a, component_b)
  component_a, component_b = climb_to_common_ancestor(a, b, component_a, component_b)

  if component_a ~= component_b then
    return order_by(component_a < component_b)
  end
  return order_by(depth_a < depth_b)
end

---@param epoch Spoke.EpochInternal
---@return Spoke.PackedTreeCoords
function EpochCursor.resolve_coords(epoch)
  if epoch._parent then
    return epoch._parent._coords:extend(epoch._coord_index)
  end
  return PackedTreeCoords.ROOT
end

---@param epoch Spoke.EpochInternal
---@return Spoke.PackedTreeCoords
function EpochCursor.resolve_cursor(epoch)
  if epoch._tick_index >= 0 then
    return epoch._coords:extend(epoch._tick_index)
  end
  return epoch._coords
end

return EpochCursor
