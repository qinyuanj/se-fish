local ult = math.ult or function(a, b)
  if (a ~ b) < 0 then
    return a >= 0
  end
  return a < b
end

---@class Spoke.PackedTreeCoords
---@field hi integer
---@field lo integer
---@field depth integer
local PackedTreeCoords = {}
PackedTreeCoords.__index = PackedTreeCoords

local BITS_PER_INDEX = 8
local LAYERS_PER_WORD = 8
local MAX_INDEX = (1 << BITS_PER_INDEX) - 1
local MAX_DEPTH = LAYERS_PER_WORD * 2

---@type integer
PackedTreeCoords.MAX_INDEX = MAX_INDEX

---@type integer
PackedTreeCoords.MAX_DEPTH = MAX_DEPTH

---@param hi integer
---@param lo integer
---@param depth integer
---@return Spoke.PackedTreeCoords
function PackedTreeCoords.new(hi, lo, depth)
  return setmetatable({
    hi = hi,
    lo = lo,
    depth = depth,
  }, PackedTreeCoords)
end

---@param _ Spoke.PackedTreeCoords
---@param key any
function PackedTreeCoords.__newindex(_, key)
  error("PackedTreeCoords has no writable field '" .. tostring(key) .. "'", 2)
end

---@type Spoke.PackedTreeCoords
PackedTreeCoords.ROOT = PackedTreeCoords.new(0, 0, 0)

local INVALID = PackedTreeCoords.new(0, 0, 255)

---@type Spoke.PackedTreeCoords
PackedTreeCoords.INVALID = INVALID

---@return boolean
function PackedTreeCoords:is_valid()
  return self.depth < 255
end

---@param idx integer
---@return Spoke.PackedTreeCoords
function PackedTreeCoords:extend(idx)
  local depth = self.depth
  if depth < 0 or depth >= MAX_DEPTH or idx < 0 or idx > MAX_INDEX then
    return INVALID
  end
  if depth < LAYERS_PER_WORD then
    return PackedTreeCoords.new(
      self.hi | (idx << ((LAYERS_PER_WORD - 1 - depth) * BITS_PER_INDEX)),
      self.lo,
      depth + 1)
  end
  return PackedTreeCoords.new(
    self.hi,
    self.lo | (idx << ((MAX_DEPTH - 1 - depth) * BITS_PER_INDEX)),
    depth + 1)
end

---@param idx integer
---@return boolean
function PackedTreeCoords:can_extend(idx)
  local depth = self.depth
  return depth >= 0
    and depth < MAX_DEPTH
    and idx >= 0
    and idx <= MAX_INDEX
end

---@param other Spoke.PackedTreeCoords
---@return integer
function PackedTreeCoords:compare_to(other)
  local a_hi, b_hi = self.hi, other.hi
  if a_hi ~= b_hi then
    return ult(a_hi, b_hi) and -1 or 1
  end
  local a_lo, b_lo = self.lo, other.lo
  if a_lo ~= b_lo then
    return ult(a_lo, b_lo) and -1 or 1
  end
  local a_depth, b_depth = self.depth, other.depth
  if a_depth == b_depth then
    return 0
  end
  return a_depth < b_depth and -1 or 1
end

return PackedTreeCoords
