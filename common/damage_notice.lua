local DamageNotice = {}

function DamageNotice.publish(payload)
    require('common.re_util'):get_re('DamageNotice'):FireAllClients(payload)
end

function DamageNotice.from_health(target_id, previous, current, position, critical, target_type, height)
    if type(previous) ~= 'number' or type(current) ~= 'number'
        or previous ~= previous or current ~= current
        or math.abs(previous) == math.huge or math.abs(current) == math.huge
        or type(target_id) ~= 'number' or not position then return nil end
    local amount = math.max(0, previous) - math.max(0, current)
    if amount <= 0 then return nil end
    return {
        target_type = target_type or 'fish', target_id = target_id, amount = amount,
        position = { x = position.x, y = position.y, z = position.z },
        height = type(height) == 'number' and height > 0 and height < math.huge and height or nil,
        critical = critical == true,
    }
end

return DamageNotice
