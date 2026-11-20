-- §9 多人规则（#255 PK 伤害过滤）：统一伤害入口里的玩家间伤害判定。
-- 只由入口注入的 MgrParty 读实时归属，不缓存队伍；鱼塘判定读 ZoneMarkers 已解析的场景边界。
-- 鱼攻击等非玩家来源一律放行，安全区只约束玩家之间，不读在线人数。
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
        -- 没解析出玩家来源（鱼、烧烤、饥饿、GM 等）不是玩家间伤害，统一入口照常结算。
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
                -- 区域几何取不到时保守拒伤（fail-closed）：宁可临时挡下玩家互伤，
                -- 也不让鱼塘免伤在快照缺失时悄悄失效。鱼/场景目标不受这条兜底影响。
                if not (zone and zone.Boundary) then
                    if target.UserId == nil then return true end
                    print('[MgrPkFilter] 鱼塘区域未解析，玩家间伤害按拒伤处理',
                        tostring(source.UserId), tostring(target.UserId))
                    return false
                end
                local sourcePos, targetPos = positionOf(source), positionOf(target)
                if insideFishPond(sourcePos, zone) and insideFishPond(targetPos, zone) then
                    return false
                end
                break
            end
        end
        -- 鱼塘以外、不同队的玩家伤害照常结算；这里不看在线人数（9-15）。
        return true
    end
end

return makePkDamageFilter
