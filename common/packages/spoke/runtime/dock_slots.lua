local PackedTreeCoords = require("common.packages.spoke.runtime.packed_tree_coords")

---@class Spoke.DockSlot
---@field key string
---@field epoch Spoke.EpochInternal?

---@class Spoke.DockSlots
local DockSlots = {}

---@param dock Spoke.DockInternal
function DockSlots.reset(dock)
  dock._child_slots = {}
  dock._slot_by_key = {}
  dock._live_count = 0
end

---@param dock Spoke.DockInternal
---@return boolean
function DockSlots.should_compact(dock)
  return #dock._child_slots > PackedTreeCoords.MAX_INDEX
    and dock._live_count * 2 <= #dock._child_slots
end

---@param dock Spoke.DockInternal
---@param key string
---@param epoch Spoke.EpochInternal
---@return integer
function DockSlots.append(dock, key, epoch)
  local index = #dock._child_slots
  dock._slot_by_key[key] = index
  dock._child_slots[index + 1] = { key = key, epoch = epoch }
  dock._live_count = dock._live_count + 1
  return index
end

---@param dock Spoke.DockInternal
---@param key string
---@return Spoke.EpochInternal?
function DockSlots.find(dock, key)
  local index = dock._slot_by_key[key]
  if index == nil then
    return nil
  end
  local slot = dock._child_slots[index + 1]
  return slot and slot.epoch or nil
end

---@param dock Spoke.DockInternal
---@param size integer
local function truncate(dock, size)
  local slots = dock._child_slots
  for index = #slots, size + 1, -1 do
    slots[index] = nil
  end
end

---@param dock Spoke.DockInternal
---@param key string
function DockSlots.release(dock, key)
  local index = dock._slot_by_key[key]
  if index == nil then
    return
  end
  local slot = dock._child_slots[index + 1]
  if slot ~= nil then
    slot.epoch = nil
  end
  dock._slot_by_key[key] = nil
  dock._live_count = dock._live_count - 1
  if dock._live_count == 0 then
    truncate(dock, 0)
  end
end

---@param dock Spoke.DockInternal
---@param slot Spoke.DockSlot
---@param epoch Spoke.EpochInternal
---@param write_index integer
local function move_slot(dock, slot, epoch, write_index)
  dock._child_slots[write_index + 1] = slot
  dock._slot_by_key[slot.key] = write_index
  epoch:_reindex(write_index)
end

---@param dock Spoke.DockInternal
---@param reindex_all boolean
function DockSlots.compact(dock, reindex_all)
  local write_index = 0
  for read_pos = 1, #dock._child_slots do
    local slot = dock._child_slots[read_pos]
    local epoch = slot and slot.epoch
    if slot and epoch then
      if reindex_all or write_index ~= (read_pos - 1) then
        move_slot(dock, slot, epoch, write_index)
      end
      write_index = write_index + 1
    end
  end
  truncate(dock, write_index)
end

---@param dock Spoke.DockInternal
---@param store? Spoke.Epoch[]
---@return Spoke.Epoch[]
function DockSlots.children(dock, store)
  store = store or {}
  for _, slot in ipairs(dock._child_slots) do
    local epoch = slot.epoch
    if epoch ~= nil then
      store[#store + 1] = epoch
    end
  end
  return store
end

---@param dock Spoke.DockInternal
function DockSlots.detach_all(dock)
  local slots = dock._child_slots
  for index = #slots, 1, -1 do
    local slot = slots[index]
    local epoch = slot and slot.epoch
    if epoch ~= nil then
      epoch:detach()
    end
    slots[index] = nil
  end
  for key in pairs(dock._slot_by_key) do
    dock._slot_by_key[key] = nil
  end
  dock._live_count = 0
end

return DockSlots
