local PackedTreeCoords = require("common.packages.spoke.runtime.packed_tree_coords")
local EpochBuilder = require("common.packages.spoke.runtime.epoch_builder")

---@class Spoke.EpochAttach
local EpochAttach = {}

---@param parent? Spoke.EpochInternal
---@return integer
local function import_index_of(parent)
  if parent then
    return #parent._attachments - 1
  end
  return -1
end

---@param parent? Spoke.EpochInternal
---@return integer
local function depth_of(parent)
  if parent then
    return parent._depth + 1
  end
  return 0
end

---@param parent? Spoke.EpochInternal
---@param index integer
---@return Spoke.PackedTreeCoords
local function coords_of(parent, index)
  if parent then
    return parent._coords:extend(index)
  end
  return PackedTreeCoords.ROOT
end

---@param epoch Spoke.EpochInternal
---@param parent? Spoke.EpochInternal
---@param tree? Spoke.SpokeTreeInternal | Spoke.EpochInternal
---@return Spoke.SpokeTreeInternal | Spoke.EpochInternal | nil
local function tree_of(epoch, parent, tree)
  if tree then
    return tree
  end
  if parent then
    return parent._tree
  end
  return epoch
end

---@param epoch Spoke.EpochInternal
---@param parent? Spoke.EpochInternal
---@param index integer
---@param ticker? Spoke.TickerInternal
---@param tree? Spoke.SpokeTreeInternal | Spoke.EpochInternal
function EpochAttach.link_into_tree(epoch, parent, index, ticker, tree)
  epoch._parent = parent
  epoch._coord_index = index
  epoch._import_index = import_index_of(parent)
  epoch._depth = depth_of(parent)
  epoch._coords = coords_of(parent, index)
  epoch._tick_cursor = epoch._coords
  epoch._ticker = ticker
  epoch._tree = tree_of(epoch, parent, tree)
  epoch._attached = true
  epoch.is_detached = false
  epoch._is_pending = false
end

---@param epoch Spoke.EpochInternal
---@param services? table<string, any>
function EpochAttach.export_services(epoch, services)
  if not services then
    return
  end
  local keys = {}
  for key in pairs(services) do
    EpochBuilder.assert_export_key(key)
    keys[#keys + 1] = key
  end
  table.sort(keys)
  for _, key in ipairs(keys) do
    epoch._attachments[#epoch._attachments + 1] = {
      kind = "export",
      key = key,
      value = services[key],
    }
  end
end

---@param epoch Spoke.EpochInternal
---@param builder Spoke.EpochBuilder
---@return Spoke.EpochTickFn?
function EpochAttach.invoke_init(epoch, builder)
  local init_result = epoch:init(builder)
  if init_result ~= nil and type(init_result) ~= "function" then
    error("Epoch init must return a tick function or nil, got " .. type(init_result), 0)
  end
  return init_result
end

---@param epoch Spoke.EpochInternal
function EpochAttach.open_tick_window(epoch)
  epoch._tick_index = #epoch._attachments
  epoch._tick_cursor = epoch._coords:extend(epoch._tick_index)
end

return EpochAttach
