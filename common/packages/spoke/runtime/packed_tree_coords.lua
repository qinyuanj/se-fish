local Ordering = require("common.packages.spoke.runtime.ordering")

---@class Spoke.PackedTreeCoords
---@field hi integer
---@field lo integer
---@field depth integer
local PackedTreeCoords = {}
PackedTreeCoords.__index = PackedTreeCoords

local BITS_PER_INDEX = 8
local LAYERS_PER_WORD = 8

---@type integer
PackedTreeCoords.MAX_INDEX = (1 << BITS_PER_INDEX) - 1

---@type integer
PackedTreeCoords.MAX_DEPTH = LAYERS_PER_WORD * 2

---@param hi integer
---@param lo integer
---@param depth integer
---@return Spoke.PackedTreeCoords
function PackedTreeCoords.new(hi, lo, depth)
  local self = setmetatable({}, PackedTreeCoords)
  rawset(self, "hi", hi)
  rawset(self, "lo", lo)
  rawset(self, "depth", depth)
  return self
end

---@param _ Spoke.PackedTreeCoords
---@param key any
function PackedTreeCoords.__newindex(_, key)
  error("PackedTreeCoords has no writable field '" .. tostring(key) .. "'", 2)
end

---@type Spoke.PackedTreeCoords
PackedTreeCoords.ROOT = PackedTreeCoords.new(0, 0, 0)

---@type Spoke.PackedTreeCoords
PackedTreeCoords.INVALID = PackedTreeCoords.new(0, 0, 255)

---@return boolean
function PackedTreeCoords:is_valid()
  return self.depth < 255
end

---@param idx integer
---@return Spoke.PackedTreeCoords
function PackedTreeCoords:extend(idx)
  if not self:can_extend(idx) then
    return PackedTreeCoords.INVALID
  end
  if self.depth < LAYERS_PER_WORD then
    return PackedTreeCoords.new(
      self.hi | (idx << ((LAYERS_PER_WORD - 1 - self.depth) * BITS_PER_INDEX)),
      self.lo,
      self.depth + 1)
  end
  return PackedTreeCoords.new(
    self.hi,
    self.lo | (idx << ((PackedTreeCoords.MAX_DEPTH - 1 - self.depth) * BITS_PER_INDEX)),
    self.depth + 1)
end

---@param idx integer
---@return boolean
function PackedTreeCoords:can_extend(idx)
  return self:is_valid()
    and self.depth ~= PackedTreeCoords.MAX_DEPTH
    and idx >= 0
    and idx <= PackedTreeCoords.MAX_INDEX
end

---@param other Spoke.PackedTreeCoords
---@return integer
function PackedTreeCoords:compare_to(other)
  local by_hi = Ordering.compare_unsigned(self.hi, other.hi)
  if by_hi ~= 0 then
    return by_hi
  end
  local by_lo = Ordering.compare_unsigned(self.lo, other.lo)
  if by_lo ~= 0 then
    return by_lo
  end
  return Ordering.compare(self.depth, other.depth)
end

return PackedTreeCoords
