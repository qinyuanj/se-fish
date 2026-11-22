local GameCfg = require('common.GameCfg')

local function positionOf(player)
    local character = player and player.Character
    if not character then return nil end
    local ok, value = pcall(function() return character.Position end)
    if not ok or type(value) ~= 'table' then return nil end
    local x, z = tonumber(value.x), tonumber(value.z)
    if not x or not z then return nil end
    return { x = x, z = z }
end

local function insideFishPond(position, zone)
    local boundary = zone and zone.Boundary
    if not boundary or not position then return false end
    return position.x > boundary.MinX and position.x < boundary.MaxX
        and position.z > boundary.MinZ and position.z < boundary.MaxZ
end

local function makePkDamageFilter()
    return function(hit, target, vitals)
        local source = hit and hit.sourcePlayer
        if not source or not target or source == target then return true end
        local party = vitals and vitals.Party
        if party and type(party.SameParty) == 'function' then
            local ok, same = pcall(party.SameParty, party, source, target)
            if ok and same then return false end
        end
        local zoneMarkers = vitals and vitals.ZoneMarkers
        local snapshot = zoneMarkers and zoneMarkers.Zones
        for _, config in ipairs(GameCfg.Zones or {}) do
            if config.Id == 'fishPond' then
                local zone = snapshot and snapshot[config.Id] or config.Scene
                if not (zone and zone.Boundary) then
                    if target.UserId == nil then return true end
                    print('[MgrPkFilter] 鱼塘区域未解析，非同队玩家伤害按鱼塘外处理',
                        tostring(source.UserId), tostring(target.UserId))
                    return true
                end
                local sourcePos, targetPos = positionOf(source), positionOf(target)
                if insideFishPond(sourcePos, zone) and insideFishPond(targetPos, zone) then
                    return false
                end
                break
            end
        end
        return true
    end
end

return { Make = makePkDamageFilter }
