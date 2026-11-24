local GarBiteNotice = { EventName = 'GarBiteNotice' }

local function finite(v)
    return type(v) == 'number' and v == v and math.abs(v) < math.huge
end

---起咬预警：fishId 为 MgrFishUnit 的鱼编号，(fx,fz) 为锁定的头部朝向（单位向量）
function GarBiteNotice.lock(fishId, pos, fx, fz, range, halfAngleDeg, duration)
    return {
        kind = 'lock', fishId = fishId,
        position = { x = pos.x, y = pos.y, z = pos.z },
        yaw = math.atan(fx, fz), range = range, halfAngleDeg = halfAngleDeg, duration = duration,
    }
end

---reason：bite（咬中）/ miss（绕后咬空）/ cancel（目标出咬距或失效）/ gone（鱼逃脱或被移除）
function GarBiteNotice.Clear(fishId, reason)
    return { kind = 'clear', fishId = fishId, reason = reason }
end

function GarBiteNotice.valid(payload)
    if type(payload) ~= 'table' or type(payload.fishId) ~= 'number' then return false end
    if payload.kind == 'clear' then return true end
    if payload.kind ~= 'lock' then return false end
    local p = payload.position
    return type(p) == 'table' and finite(p.x) and finite(p.y) and finite(p.z) and finite(payload.yaw)
        and finite(payload.range) and payload.range > 0
        and finite(payload.duration) and payload.duration > 0
end

function GarBiteNotice.publish(payload)
    require('common.re_util'):get_re(GarBiteNotice.EventName):FireAllClients(payload)
end

return GarBiteNotice
