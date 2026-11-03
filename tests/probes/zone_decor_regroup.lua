-- #164 把 World 根下散落的美术件按 xz 归入七区的「装饰」文件夹（编辑器侧，edit mode）。
-- 复跑：editor-cli exec --file <本文件> --expect-edit-mode --timeout 120 --json
--       editor-cli log grep ZDR164 --platform editor --context 0 --max-matches 1000 --json
-- APPLY=false 只打印归属，不写入。本脚本不保存地图。可重复执行：只处理仍在根下的物体，缺的「装饰」文件夹按需补建。
-- 归属按物体 pivot 的 xz 落在哪个空气墙盒内判定，区间左闭右开 [Min, Max)，边界上的物体统一归坐标较大一侧；
-- 落在所有盒外的物体归到距离最近的盒。根下物体的 GetParent 可能是 nil，也可能是名为 World 的单位。
-- 单次 exec 有 5 秒预算，每轮最多搬 BATCH 个，看到 ZDR164|PENDING 就再跑一轮。
-- TerrainUnit 的 Lua SetParent 不报错但不生效：只打印 TERRAIN 行（UnitId 与目标文件夹 UnitId），
-- 由 editor-cli editor-unit reparent <unit-id> <folder-id> --yes 搬动。
local APPLY = false
local BATCH = 60
local MARK = 'ZDR164'
local world = editor:GetService('World')

local boxes = {
  { '01 鱼塘', -810, -530, -170, 185 },
  { '02 虾池', -530, -275, -170, 185 },
  { '03 蟹湖', -275, 30, -170, 185 },
  { '04 树林岛', -155, 30, 185, 430 },
  { '05 沙滩岛', -385, -155, 185, 430 },
  { '06 礁石岛', -575, -385, 185, 430 },
  { '07 火山岛', -810, -575, 185, 430 },
}
local unitTypes = { 'WorldUnit', 'ModelUnit', 'TerrainUnit', 'WaterUnit', 'EggyUnit', 'EffectUnit' }

local function component(value, index, lower, upper)
  return value[lower] or value[upper] or value[index]
end

local function gap(value, low, high)
  if value < low then return low - value end
  if value > high then return value - high end
  return 0
end

local function zoneOf(x, z)
  local nearest, best
  for _, box in ipairs(boxes) do
    if x >= box[2] and x < box[3] and z >= box[4] and z < box[5] then
      return box[1], 'IN'
    end
    local dx, dz = gap(x, box[2], box[3]), gap(z, box[4], box[5])
    local distance = dx * dx + dz * dz
    if not best or distance < best then
      nearest, best = box[1], distance
    end
  end
  return nearest, 'NEAREST'
end

local folders = {}
for _, box in ipairs(boxes) do
  local zone = world:FindFirstChild(box[1])
  assert(zone, MARK .. ': 缺少区 ' .. box[1])
  local folder = zone:FindFirstChild('装饰')
  if not folder and APPLY then
    folder = world:CreateUnit('Folder', {})
    folder.Name = '装饰'
    folder:SetParent(zone)
    print(MARK .. '|FOLDER_CREATED|' .. box[1])
  end
  folders[box[1]] = folder
  print(MARK .. '|FOLDER|' .. box[1] .. '|' .. (folder and tostring(folder:GetProperty('UnitId')) or 'MISSING'))
end

local function isRoot(unit)
  local parent = unit:GetParent()
  return parent == nil or tostring(parent.Name) == 'World'
end

local seen, counts, moved, pending = {}, {}, 0, 0
for _, unitType in ipairs(unitTypes) do
  for _, unit in ipairs(world:GetUnitsByUnitType(unitType, true)) do
    local id = tostring(unit:GetProperty('UnitId'))
    if not seen[id] and isRoot(unit) then
      seen[id] = true
      local position = unit.Position
      local x, y, z = component(position, 1, 'x', 'X'), component(position, 2, 'y', 'Y'), component(position, 3, 'z', 'Z')
      local zone, fit = zoneOf(x, z)
      local action = unitType == 'TerrainUnit' and 'TERRAIN' or 'MOVE'
      if action == 'MOVE' and APPLY then
        if moved < BATCH then
          unit:SetParent(folders[zone])
          moved = moved + 1
          local after = unit.Position
          x, y, z = component(after, 1, 'x', 'X'), component(after, 2, 'y', 'Y'), component(after, 3, 'z', 'Z')
        else
          action = 'PENDING'
          pending = pending + 1
        end
      end
      local key = action .. '|' .. zone
      counts[key] = (counts[key] or 0) + 1
      local folderId = folders[zone] and tostring(folders[zone]:GetProperty('UnitId')) or 'MISSING'
      print(string.format('%s|%s|%s|%s|%s|%s|%.2f,%.2f,%.2f|%s|%s', MARK, action, zone, unitType,
        tostring(unit.Name), id, x, y, z, fit, folderId))
    end
  end
end
for key, count in pairs(counts) do
  print(MARK .. '|COUNT|' .. key .. '|' .. count)
end
print(MARK .. '|END|apply=' .. tostring(APPLY) .. '|moved=' .. moved .. '|pending=' .. pending)
