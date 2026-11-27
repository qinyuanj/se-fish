-- 纯数据 table 的深拷贝：非 table 原样返回，递归复制，不复制元表。
-- 存档镜像、快照与投影原本各写一份，收敛到这里，避免某处漏拷一层或误连同一张表。
local DeepCopy = {}

function DeepCopy.copy(value)
    if type(value) ~= 'table' then return value end
    local out = {}
    for k, v in pairs(value) do out[k] = DeepCopy.copy(v) end
    return out
end

return DeepCopy
