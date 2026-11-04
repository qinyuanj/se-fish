-- #164 收尾：删 06 旧灰盒「轮廓山体」Z6_Ridge*，并把编辑器试玩出生点挪回 01 鱼塘（编辑器侧，edit mode）。
-- 06 的 Z6_Land / Z6_Bank / Z6_LandSide* / Z6_PondFloor 保留：06 没有美术地形，它们是唯一可站地面与原池轮廓，
-- 189 块水域按此轮廓划分。Ridge 是 #65 P3 模板里的山体替身，美术假山石已取代，点位与水域都不依赖。
-- 默认 dry-run；仅在脚本内把 APPLY 改为 true 后写入，写完改回 false。不保存地图。可重复执行。
local APPLY = false
local MARK = 'ZRT164'
local SPAWN = { x = -616, y = 1.0, z = 64 }
local RIDGES = { 'Z6_Ridge432', 'Z6_Ridge460', 'Z6_Ridge500', 'Z6_Ridge528', 'Z6_RidgeIn435', 'Z6_RidgeIn525' }
local world = editor:GetService('World')
local function c(v, i, k) return v[k] or v[i] end
local function text(v) return string.format('%.2f,%.2f,%.2f', c(v,1,'x'), c(v,2,'y'), c(v,3,'z')) end

local folder = assert(world:FindFirstChild('06 礁石岛'):FindFirstChild('地块'), MARK .. ': 06/地块 缺失')
local deleted = 0
for _, name in ipairs(RIDGES) do
  local unit = folder:FindFirstChild(name)
  print(MARK .. '|RIDGE|' .. name .. '|' .. (unit and text(unit.Position) or 'GONE'))
  if unit and APPLY then unit:Destroy() deleted = deleted + 1 end
end

local spawn
for _, unit in ipairs(world:GetDescendants()) do
  if unit.Name == '蛋仔：试玩出生点' then
    if spawn then error(MARK .. ': 试玩出生点重名') end
    spawn = unit
  end
end
assert(spawn, MARK .. ': 试玩出生点缺失')
print(MARK .. '|SPAWN|before=' .. text(spawn.Position) .. '|after=' .. text(SPAWN))
if APPLY then
  local target = Vector3.New(SPAWN.x, SPAWN.y, SPAWN.z)
  if spawn.SetPosition then spawn:SetPosition(target) else spawn:SetProperty('Position', target) end
end
print(MARK .. '|END|deleted=' .. deleted .. '|apply=' .. tostring(APPLY))
