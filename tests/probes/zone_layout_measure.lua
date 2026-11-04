-- #164 回退重做：七区布点与水域测算（试玩服务端，只读）。
-- 复跑：试玩中 editor-cli exec --file tests/probes/zone_layout_measure.lua --platform server
--       editor-cli log grep ZLM164 --platform server --context 0 --max-matches 1000 --json
-- 每区按 STEP 米网格从 y=200 向下打射线，只包含根下「地形」与 06 的临时「地块」；
-- 行格式 ZLM164|G|<区序>|z=<z>|x0=<x0>|<高度…>，miss 记 '-'。高度用于选点与划水域，坡度离线由相邻格推算。
local MARK = 'ZLM164'
local STEP = 4
local INSET = 2
local ZONES = { '01 鱼塘', '02 虾池', '03 蟹湖', '04 树林岛', '05 沙滩岛', '06 礁石岛', '07 火山岛' }
local physics = game:GetService('PhysicsService')
local world = game:GetService('World')

local targets = {}
local byName = {}
for _, unit in ipairs(world:GetDescendants()) do
  if unit.Name == '地形' then targets[#targets + 1] = unit end
  byName[unit.Name] = unit
end
local greybox = byName['地块']
if greybox then targets[#targets + 1] = greybox end
local params = RaycastParams.New()
params.FilterType = Enums.RaycastFilterType.Include
params.FilterDescendantsInstances = targets
print(MARK .. '|targets=' .. #targets .. '|greybox06=' .. tostring(greybox ~= nil))

local function wall(zoneIndex, side)
  return byName['Z' .. zoneIndex .. '_Boundary' .. side].Position
end

for index = 1, #ZONES do
  local minX, maxX = wall(index, 'West').x + INSET, wall(index, 'East').x - INSET
  local minZ, maxZ = wall(index, 'South').z + INSET, wall(index, 'North').z - INSET
  print(string.format('%s|ZONE|%d|x=%.1f..%.1f|z=%.1f..%.1f|step=%d', MARK, index, minX, maxX, minZ, maxZ, STEP))
  local z = minZ
  while z <= maxZ do
    local row, x = {}, minX
    while x <= maxX do
      local ok, hit = pcall(physics.Raycast, physics, Vector3.New(x, 200, z), Vector3.New(0, -400, 0), params)
      row[#row + 1] = (ok and hit) and string.format('%.1f', hit.Position.y) or '-'
      x = x + STEP
    end
    print(string.format('%s|G|%d|z=%.1f|x0=%.1f|%s', MARK, index, z, minX, table.concat(row, ',')))
    z = z + STEP
  end
end
print(MARK .. '|done')
