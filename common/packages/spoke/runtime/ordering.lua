---@class Spoke.Ordering
local Ordering = {}

---@param a number
---@param b number
---@return integer
function Ordering.compare(a, b)
  if a == b then
    return 0
  end
  return a < b and -1 or 1
end

---@param a integer
---@param b integer
---@return integer
function Ordering.compare_unsigned(a, b)
  if a == b then
    return 0
  end
  return math.ult(a, b) and -1 or 1
end

---@param a boolean
---@param b boolean
---@return integer
function Ordering.compare_flag(a, b)
  if a == b then
    return 0
  end
  return a and -1 or 1
end

---@generic T
---@param count integer
---@param previous any
---@param current T
---@param compare fun(a: T, b: T): integer
---@return integer
function Ordering.count_regression(count, previous, current, compare)
  if previous and compare(previous, current) > 0 then
    return count + 1
  end
  return count
end

return Ordering
