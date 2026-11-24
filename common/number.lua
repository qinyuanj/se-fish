local Number = {}

-- Lua 5.4 中 NaN 与自身不等，±math.huge 经 math.floor 后仍不是有限整数。
-- 跨端数值与位置计算统一先经过这里，避免各模块重复实现而漏掉一种非法值。
function Number.IsFiniteNumber(value)
    return type(value) == 'number'
        and value == value
        and value ~= math.huge
        and value ~= -math.huge
end

return Number
