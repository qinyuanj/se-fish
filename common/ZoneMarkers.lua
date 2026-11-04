-- 区域标记启动解析（ADR-0013）：按稳定名称读取七区标记，全部校验通过后一次性发布本轮快照。
-- 标记名全图唯一且须位于所属区目录之下；目录层级只用于整理，不参与查找。
local GameCfg = require('common.GameCfg')

local ZoneMarkers = { Ready = false, Zones = {} }

local zoneNames = { '01 鱼塘', '02 虾池', '03 蟹湖', '04 树林岛', '05 沙滩岛', '06 礁石岛', '07 火山岛' }
-- 客户端 main 早于场景同步完成执行（2026-11-04 实测约早 10 ms），启动时按此节奏重试解析
local START_POLL_SEC = 0.1
local START_WAIT_SEC = 30

local function finite(value)
    return type(value) == 'number' and value == value and math.abs(value) < math.huge
end

local function vector(value, label, name)
    if value == nil then error('区域标记' .. label .. '缺失: ' .. name) end
    local result = { x = value.x, y = value.y, z = value.z }
    if not finite(result.x) or not finite(result.y) or not finite(result.z) then
        error('区域标记' .. label .. '非法: ' .. name)
    end
    return result
end

local function sizeOf(unit, name)
    local size = vector(unit.Size, '尺寸', name)
    if size.x <= 0 or size.y <= 0 or size.z <= 0 then error('区域标记尺寸非法: ' .. name) end
    return size
end

local function waterOrder(name, prefix)
    local suffix = name:sub(#prefix + 1)
    if suffix == '' then return 0 end
    return suffix:match('^%d+$') and tonumber(suffix) or nil
end

-- 全图名称计数 + 区内名称表：缺失、重名、跨区摆放都在这里拒绝。
local function catalog(world)
    local counts = {}
    for _, unit in ipairs(world:GetDescendants()) do
        counts[unit.Name] = (counts[unit.Name] or 0) + 1
    end
    local function unique(name)
        local count = counts[name] or 0
        if count == 0 then error('区域标记缺失: ' .. name) end
        if count > 1 then error('区域标记重名: ' .. name .. ' x' .. count) end
    end
    local zones = {}
    for index, zoneName in ipairs(zoneNames) do
        unique(zoneName)
        local folder = world:FindFirstChild(zoneName)
        if not folder then error('区域目录缺失: ' .. zoneName) end
        local byName, waters = {}, {}
        local prefix = 'Z' .. index .. '_Water'
        for _, unit in ipairs(folder:GetDescendants()) do
            byName[unit.Name] = unit
            if unit.Name:sub(1, #prefix) == prefix and waterOrder(unit.Name, prefix) then
                waters[#waters + 1] = unit
            end
        end
        table.sort(waters, function(first, second)
            return waterOrder(first.Name, prefix) < waterOrder(second.Name, prefix)
        end)
        zones[index] = { Name = zoneName, ByName = byName, Waters = waters }
    end
    return {
        Zones = zones,
        Unit = function(zoneIndex, name)
            unique(name)
            local unit = zones[zoneIndex].ByName[name]
            if not unit then error('区域标记不在所属区: ' .. zoneNames[zoneIndex] .. '/' .. name) end
            return unit
        end,
        Unique = unique,
    }
end

local function boundary(markers, zoneIndex, maxFlightHeight)
    local prefix = 'Z' .. zoneIndex .. '_Boundary'
    local walls = {}
    for _, side in ipairs({ 'West', 'East', 'South', 'North' }) do
        local name = prefix .. side
        local unit = markers.Unit(zoneIndex, name)
        walls[side] = { Position = vector(unit.Position, '坐标', name), Size = sizeOf(unit, name) }
    end
    local west, east, south, north = walls.West, walls.East, walls.South, walls.North
    if west.Position.x >= east.Position.x or south.Position.z >= north.Position.z then
        error('区域边界方向非法: ' .. zoneNames[zoneIndex])
    end
    if west.Size.x >= west.Size.z or east.Size.x >= east.Size.z
        or south.Size.z >= south.Size.x or north.Size.z >= north.Size.x then
        error('区域边界墙朝向非法: ' .. zoneNames[zoneIndex])
    end
    local bottom, top = math.huge, -math.huge
    for _, wall in pairs(walls) do
        bottom = math.min(bottom, wall.Position.y)
        top = math.max(top, wall.Position.y + wall.Size.y)
    end
    return {
        MinX = west.Position.x, MaxX = east.Position.x,
        MinZ = south.Position.z, MaxZ = north.Position.z,
        BottomY = bottom, TopY = top,
        MaxFlightHeight = maxFlightHeight,
        CanClimb = false,
        EntityNames = { prefix .. 'West', prefix .. 'East', prefix .. 'South', prefix .. 'North' },
    }
end

local function inside(bounds, position)
    return position.x > bounds.MinX and position.x < bounds.MaxX
        and position.z > bounds.MinZ and position.z < bounds.MaxZ
end

local function overlaps(first, second)
    return math.abs(first.Center.x - second.Center.x) < first.HalfX + second.HalfX
        and math.abs(first.Center.z - second.Center.z) < first.HalfZ + second.HalfZ
end

local function copyPoint(pointValue)
    return { x = pointValue.x, y = pointValue.y, z = pointValue.z }
end

-- 命名合同：每区必须存在的稳定标记名（不含按前缀枚举的水域）。渔夫、商店、摆渡沿用各自配置里的锚点名。
function ZoneMarkers.Contract(cfg)
    cfg = cfg or GameCfg
    local entries = {}
    local function add(zoneIndex, role, name)
        entries[#entries + 1] = { ZoneIndex = zoneIndex, Role = role, Name = name }
    end
    for index = 1, #cfg.Zones do
        local prefix = 'Z' .. index .. '_'
        add(index, 'Safe', prefix .. 'Safe')
        add(index, 'Fisherman', cfg.Interact.Fishermen[index].AnchorNames[1])
        add(index, 'Shop', cfg.Shop.Stands[index].AnchorName)
        add(index, 'Lottery', prefix .. 'Lottery')
        if index >= 3 then add(index, 'Grill', prefix .. 'Grill') end
        for baitIndex = 1, index == 1 and 5 or 2 do add(index, 'Bait' .. baitIndex, prefix .. 'Bait' .. baitIndex) end
        for _, side in ipairs({ 'West', 'East', 'South', 'North' }) do
            add(index, 'Boundary', prefix .. 'Boundary' .. side)
        end
    end
    for index, route in ipairs(cfg.Ferry.Routes) do
        add(index, 'FerryOut', route.Outbound.AnchorName)
        add(index + 1, 'FerryReturn', route.Return.AnchorName)
    end
    return entries
end

local function resolveZone(markers, cfg, index, snapshot)
    local zone = cfg.Zones[index]
    local zoneName = zoneNames[index]
    local prefix = 'Z' .. index .. '_'
    local scene = {
        State = 'resolved', Entities = {}, Waters = {},
        Boundary = boundary(markers, index, cfg.Ability.Flight.MaxHeight),
        BaitSpots = { ItemId = zone.BaitItemId, RespawnSec = 15, Count = 1, Positions = {} },
    }
    local function point(role, name)
        local position = vector(markers.Unit(index, name).Position, '坐标', name)
        if not inside(scene.Boundary, position) then
            error('区域标记越出本区边界: ' .. zoneName .. '/' .. name)
        end
        scene.Entities[#scene.Entities + 1] = { Name = name, Role = role, Position = position, State = 'observed' }
        return position
    end
    scene.SafePointName = prefix .. 'Safe'
    scene.SafePoint = point('Safe', scene.SafePointName)
    scene.FishermanName = cfg.Interact.Fishermen[index].AnchorNames[1]
    point('Fisherman', scene.FishermanName)
    scene.ShopName = cfg.Shop.Stands[index].AnchorName
    point('Shop', scene.ShopName)
    scene.LotteryName = prefix .. 'Lottery'
    point('Lottery', scene.LotteryName)
    if index >= 3 then
        scene.GrillName = prefix .. 'Grill'
        point('Grill', scene.GrillName)
    end
    for baitIndex = 1, index == 1 and 5 or 2 do
        local name = prefix .. 'Bait' .. baitIndex
        local position = point('Bait' .. baitIndex, name)
        scene['Bait' .. baitIndex .. 'Name'] = name
        scene.BaitSpots.Positions[#scene.BaitSpots.Positions + 1] = position
        snapshot.BaitSpots[#snapshot.BaitSpots + 1] = {
            Id = zone.Id .. ':bait-' .. baitIndex, ItemId = zone.BaitItemId,
            Count = 1, Position = position, ZoneId = zone.Id,
        }
    end
    local waterUnits = markers.Zones[index].Waters
    if #waterUnits == 0 then error('区域水域缺失: ' .. zoneName) end
    local casting = cfg.Casting.Zones[zone.WaterId]
    if not casting then error('区域抽鱼池缺失: ' .. zone.Id) end
    for waterIndex, unit in ipairs(waterUnits) do
        local name = unit.Name
        markers.Unique(name)
        local center = vector(unit.Position, '坐标', name)
        local size = sizeOf(unit, name)
        local water = {
            Id = waterIndex == 1 and zone.WaterId or (zone.WaterId .. '.' .. waterIndex),
            ZoneId = zone.Id, EntityName = name,
            Center = center, HalfX = size.x / 2, HalfZ = size.z / 2,
            SurfaceY = center.y + size.y,
        }
        for _, other in ipairs(snapshot.Waters) do
            if overlaps(water, other) then error('区域水域重叠: ' .. name .. ' / ' .. other.EntityName) end
        end
        if not inside(scene.Boundary, center) then error('区域水域越出本区边界: ' .. name) end
        scene.Waters[#scene.Waters + 1] = water
        scene.Entities[#scene.Entities + 1] = { Name = name, Role = 'Water', Position = center, State = 'observed' }
        snapshot.Waters[#snapshot.Waters + 1] = water
        snapshot.ZoneIdByWater[water.Id] = zone.Id
        snapshot.Casting[water.Id] = casting
    end
    if index == 6 then
        scene.AirCombat = {
            MinY = 5, MaxY = 30, Radius = 35, Center = copyPoint(scene.SafePoint),
        }
    elseif index == 7 then
        scene.CruiseWater = scene.Waters[1]
        scene.BossArena = { Center = copyPoint(scene.SafePoint), HalfX = 30, HalfZ = 25 }
    end
    snapshot.Zones[zone.Id] = scene
    snapshot.ContentWaterIds[zone.WaterId] = zone.Id
end

function ZoneMarkers.Resolve(world, config)
    local cfg = config or GameCfg
    ZoneMarkers.Ready, ZoneMarkers.Zones = false, {}
    if not world then error('ZoneMarkers.Resolve 需要 World') end
    local markers = catalog(world)
    local snapshot = { Zones = {}, Waters = {}, BaitSpots = {}, ZoneIdByWater = {}, ContentWaterIds = {}, Casting = {} }
    for index = 1, #cfg.Zones do resolveZone(markers, cfg, index, snapshot) end
    local routes = {}
    for index, route in ipairs(cfg.Ferry.Routes) do
        local from, to = cfg.Zones[index], cfg.Zones[index + 1]
        if route.FromZoneId ~= from.Id or route.ToZoneId ~= to.Id then error('航线与区序不一致: ' .. route.Id) end
        local outName, backName = route.Outbound.AnchorName, route.Return.AnchorName
        local outbound = vector(markers.Unit(index, outName).Position, '坐标', outName)
        local returning = vector(markers.Unit(index + 1, backName).Position, '坐标', backName)
        if not inside(snapshot.Zones[from.Id].Boundary, outbound) then error('区域标记越出本区边界: ' .. outName) end
        if not inside(snapshot.Zones[to.Id].Boundary, returning) then error('区域标记越出本区边界: ' .. backName) end
        routes[index] = { OutName = outName, BackName = backName, Outbound = outbound, Returning = returning }
    end
    for index, route in ipairs(routes) do
        local fromScene = snapshot.Zones[cfg.Zones[index].Id]
        local toScene = snapshot.Zones[cfg.Zones[index + 1].Id]
        fromScene.Entities[#fromScene.Entities + 1] = { Name = route.OutName, Role = 'Ferry', Position = route.Outbound, State = 'observed' }
        toScene.Entities[#toScene.Entities + 1] = { Name = route.BackName, Role = 'Ferry', Position = route.Returning, State = 'observed' }
    end

    for _, route in ipairs(cfg.Ferry.Routes) do
        route.Outbound.Destination = snapshot.Zones[route.ToZoneId].SafePoint
        route.Return.Destination = snapshot.Zones[route.FromZoneId].SafePoint
    end
    for _, zone in ipairs(cfg.Zones) do zone.Scene = snapshot.Zones[zone.Id] end
    cfg.Water.Zones = snapshot.Waters
    cfg.Water.ZoneIdByWater = snapshot.ZoneIdByWater
    cfg.Water.ContentWaterIds = snapshot.ContentWaterIds
    cfg.BaitSpots.Spots = snapshot.BaitSpots
    for waterId, casting in pairs(snapshot.Casting) do cfg.Casting.Zones[waterId] = casting end
    local fallback = snapshot.Zones[cfg.Zones[1].Id].Boundary
    cfg.Ability.Flight.FallbackBounds = {
        MinX = fallback.MinX, MaxX = fallback.MaxX, MinZ = fallback.MinZ, MaxZ = fallback.MaxZ,
        BottomY = fallback.BottomY, TopY = fallback.TopY, MaxFlightHeight = fallback.MaxFlightHeight,
    }
    snapshot.FerryRoutes = {}
    for index, route in ipairs(cfg.Ferry.Routes) do
        snapshot.FerryRoutes[index] = {
            State = 'resolved', FromZoneId = route.FromZoneId, ToZoneId = route.ToZoneId,
            Outbound = route.Outbound, Return = route.Return,
        }
    end
    cfg.Ferry.PlannedRoutes = snapshot.FerryRoutes
    snapshot.Ready = true
    ZoneMarkers.Ready, ZoneMarkers.Zones = true, snapshot.Zones
    return snapshot
end

function ZoneMarkers.Start()
    local world, task = game:GetService('World'), game:GetService('Task')
    local ok, snapshot = pcall(ZoneMarkers.Resolve, world)
    local waited = 0
    while not ok and waited < START_WAIT_SEC do
        task:Wait(START_POLL_SEC)
        waited = waited + START_POLL_SEC
        ok, snapshot = pcall(ZoneMarkers.Resolve, world)
    end
    if not ok then error(snapshot, 0) end
    print('[ZoneMarkers] ready', 'waters=' .. #snapshot.Waters, 'baits=' .. #snapshot.BaitSpots,
        'routes=' .. #snapshot.FerryRoutes, 'waitedSec=' .. waited)
    return snapshot
end

return ZoneMarkers
