-- 把 01 鱼塘的两个站人单位对齐到安全落点 Z1_Safe（编辑器侧，edit mode）。
-- 背景：现场 出生点 (z=64) 与 Z1_Safe (z=68) 差 4 米；试玩出生点仍停在 06 礁石岛附近，
-- #164 的 zone06_ridge_trim_spawn.lua 从未以 APPLY=true 执行过。
-- 只在脚本内把 APPLY 改为 true 后写入，写完立即改回 false。不保存地图。可重复执行。
-- 复跑：
--   editor-cli exec --file <本文件绝对路径> --expect-edit-mode --timeout 60 --json
--   editor-cli log grep SPAWNA1 --platform editor --context 0 --max-matches 60 --json
-- 目标坐标不写死：运行时读 Z1_Safe 的 Position，避免与标记漂移。
local APPLY = false
local MARK = 'SPAWNA1'

local world = editor:GetService('World')
local function emit(line) print(MARK .. '|' .. line) end
-- 实测口径：编辑器 SDK 的 Position 返回 FVector3，支持 .x/.y/.z，下标 [1] 为 nil。
local function comp(v, i)
    if v == nil then return nil end
    if v.x ~= nil then
        if i == 1 then return v.x elseif i == 2 then return v.y else return v.z end
    end
    return v[i]
end
local function text(v)
    if v == nil then return '-' end
    return string.format('%.3f,%.3f,%.3f', comp(v, 1), comp(v, 2), comp(v, 3))
end
local function safe(fn, fallback)
    local ok, value = pcall(fn)
    if not ok then return fallback end
    return value
end
local function unitType(unit)
    return tostring(safe(function() return unit:GetUnitType() end, '?'))
end

-- 与 ZoneMarkers.catalog 同口径：按名唯一，重名拒绝。
local function uniqueByName(name, expectType)
    local found = {}
    for _, unit in ipairs(world:GetDescendants()) do
        if unit.Name == name then found[#found + 1] = unit end
    end
    if #found == 0 then error(MARK .. ': 缺失 ' .. name) end
    if #found > 1 then error(MARK .. ': 重名 ' .. name .. ' x' .. #found) end
    if expectType and unitType(found[1]) ~= expectType then
        error(MARK .. ': 类型不符 ' .. name .. ' = ' .. unitType(found[1]))
    end
    return found[1]
end

local safeMarker = uniqueByName('Z1_Safe', 'WorldUnit')
local target = safe(function() return safeMarker:GetPosition() end, nil)
if target == nil then error(MARK .. ': Z1_Safe 坐标读取失败') end
emit('TARGET|Z1_Safe=' .. text(target))

local spawnUnit = uniqueByName('出生点', 'SpawnLocationUnit')
local playEgg = uniqueByName('蛋仔：试玩出生点', 'EditEgg')

local function move(label, unit)
    local before = safe(function() return unit:GetPosition() end, nil)
    emit('UNIT|' .. label .. '|before=' .. text(before) .. '|after=' .. text(target))
    if not APPLY then return end
    local dest = Vector3.New(comp(target, 1), comp(target, 2), comp(target, 3))
    if unit.SetPosition then
        unit:SetPosition(dest)
    else
        unit:SetProperty('Position', dest)
    end
    emit('MOVED|' .. label .. '|now=' .. text(safe(function() return unit:GetPosition() end, nil)))
end

move('出生点', spawnUnit)
move('蛋仔：试玩出生点', playEgg)
emit('END|apply=' .. tostring(APPLY))
