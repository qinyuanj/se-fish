local Number = {}

-- Lua 5.4 中 NaN 与自身不等，±math.huge 经 math.floor 后仍不是有限整数。
-- 跨端数值与位置计算统一先经过这里，避免各模块重复实现而漏掉一种非法值。
function Number.is_finite_number(value)
    return type(value) == 'number'
        and value == value
        and value ~= math.huge
        and value ~= -math.huge
end

--- (x, z) 水平面距离：只比水平位移的场合统一从这里取，避免各模块重复实现。
---@param a { x: number, z: number }
---@param b { x: number, z: number }
---@return number
function Number.flat_distance(a, b)
    local dx, dz = a.x - b.x, a.z - b.z
    return math.sqrt(dx * dx + dz * dz)
end

--- 非法数值按 0 处理：坐标、时长等从存档或宿主读来的数统一先过这里，避免各模块各写一份。
---@param value any
---@return number
function Number.or_zero(value)
    if not Number.is_finite_number(value) then return 0 end
    return value
end

return Number
