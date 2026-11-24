-- 水圈 CanQuery=true 但没有可命中几何：垂直射线只能命中鱼触发器或地板，不能依赖射线判水。
-- 配置见 GameCfg.Water.Zones。HalfXZ 直接写运行时该水区的半边尺寸：运行时读到的 Size 已含
-- Scale，配置时再乘缩放会翻倍（#12 W-4）。取值与溯源见 issue #25 的 M0 模块线台账（评论 9862）。

local MathWaterJudge = {}

local function finite(value)
    return type(value) == 'number' and value == value and math.abs(value) < math.huge
end

local function checkZone(index, zone)
    local where = "MathWaterJudge.Build: 第 " .. index .. " 个水区"

    if type(zone) ~= "table" then
        error(where .. "不是 table")
    end
    if type(zone.Id) ~= "string" or zone.Id == "" then
        error(where .. "缺 Id（判定结果要能溯源到是哪个水区）")
    end

    local center = zone.Center
    if type(center) ~= "table" or type(center.x) ~= "number" or type(center.z) ~= "number" then
        error(where .. "（" .. zone.Id .. "）的 Center 必须是含数字 x/z 的 table")
    end
    if zone.HalfX ~= nil or zone.HalfZ ~= nil then
        if type(zone.HalfX) ~= "number" or zone.HalfX <= 0
            or type(zone.HalfZ) ~= "number" or zone.HalfZ <= 0 then
            error(where .. "（" .. zone.Id .. "）的 HalfX/HalfZ 必须同时为正数")
        end
    elseif type(zone.HalfXZ) ~= "number" or zone.HalfXZ <= 0 then
        error(where .. "（" .. zone.Id .. "）的 HalfXZ 必须是正数")
    end
    if type(zone.SurfaceY) ~= "number" then
        error(where .. "（" .. zone.Id .. "）的 SurfaceY 必须是数字")
    end
    if not finite(center.x) or not finite(center.z) or not finite(zone.SurfaceY)
        or not finite(zone.HalfX or zone.HalfXZ) or not finite(zone.HalfZ or zone.HalfXZ) then
        error(where .. '（' .. zone.Id .. '）的坐标与尺寸必须是有限数字')
    end
end

function MathWaterJudge.InZone(zone, pos)
    local center = zone.Center
    return math.abs(pos.x - center.x) <= (zone.HalfX or zone.HalfXZ)
        and math.abs(pos.z - center.z) <= (zone.HalfZ or zone.HalfXZ)
        and pos.y <= zone.SurfaceY
end

function MathWaterJudge.HitZone(zones, pos)
    for i = 1, #zones do
        if MathWaterJudge.InZone(zones[i], pos) then
            return zones[i]
        end
    end
    return nil
end

function MathWaterJudge.Build(zones)
    if type(zones) ~= "table" or #zones == 0 then
        error("MathWaterJudge.Build: 水区配置为空")
    end
    local ids = {}
    for i = 1, #zones do
        checkZone(i, zones[i])
        if ids[zones[i].Id] then error('MathWaterJudge.Build: 重复水域 ' .. zones[i].Id) end
        ids[zones[i].Id] = true
    end

    return function(pos)
        return MathWaterJudge.HitZone(zones, pos)
    end
end

function MathWaterJudge.Toward(zones, pos)
    local best, bestX, bestZ
    for _, zone in ipairs(zones) do
        local halfX, halfZ = zone.HalfX or zone.HalfXZ, zone.HalfZ or zone.HalfXZ
        local nearX = math.max(zone.Center.x - halfX, math.min(pos.x, zone.Center.x + halfX))
        local nearZ = math.max(zone.Center.z - halfZ, math.min(pos.z, zone.Center.z + halfZ))
        local dx, dz = nearX - pos.x, nearZ - pos.z
        local distance = dx * dx + dz * dz
        if not best or distance < best then best, bestX, bestZ = distance, dx, dz end
    end
    if not best or best < 1e-4 then return nil end
    local length = math.sqrt(best)
    return bestX / length, bestZ / length
end

function MathWaterJudge.InspectScene(zones, snapshot)
    local byName = {}
    for _, entity in ipairs(snapshot) do
        local matches = byName[entity.Name] or {}
        matches[#matches + 1] = entity
        byName[entity.Name] = matches
    end
    local report = { EntitiesMatch = true, Issues = {}, PendingZones = {}, Verification = {
        Saved = 'unverified', Synced = 'unverified', Collision = 'unverified', Playtested = 'unverified',
    } }
    for _, zone in ipairs(zones) do
        local scene = zone.Scene
        if not scene or scene.State ~= 'resolved' then
            report.PendingZones[#report.PendingZones + 1] = zone.Id
        end
        for _, expected in ipairs(scene and scene.Entities or {}) do
            local matches = byName[expected.Name] or {}
            local code
            if #matches == 0 then code = 'missing'
            elseif #matches > 1 then code = 'duplicate'
            elseif expected.Position then
                local actual = matches[1].Position
                for _, axis in ipairs({ 'x', 'y', 'z' }) do
                    if not actual or not finite(actual[axis]) or not finite(expected.Position[axis])
                        or math.abs(actual[axis] - expected.Position[axis]) > 0.1 then
                        code = 'position'
                    end
                end
            end
            if code then
                report.Issues[#report.Issues + 1] = {
                    ZoneId = zone.Id, ZoneName = zone.Name, Name = expected.Name, Code = code,
                }
            end
        end
    end
    report.EntitiesMatch = #report.Issues == 0
    return report
end

return MathWaterJudge
