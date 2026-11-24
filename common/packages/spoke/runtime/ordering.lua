local Ordering = {}

function Ordering.compare(a, b)
  if a == b then
    return 0
  end
  return a < b and -1 or 1
end

function Ordering.compare_unsigned(a, b)
  if a == b then
    return 0
  end
  return math.ult(a, b) and -1 or 1
end

function Ordering.compare_flag(a, b)
  if a == b then
    return 0
  end
  return a and -1 or 1
end

function Ordering.count_regression(count, previous, current, compare)
  if previous and compare(previous, current) > 0 then
    return count + 1
  end
  return count
end

return Ordering
