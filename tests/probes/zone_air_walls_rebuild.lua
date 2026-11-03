-- #164 按用户手绘分区重建七区空气墙（编辑器侧，edit mode）。
-- 复跑：editor-cli exec --file <本文件> --expect-edit-mode --timeout 120 --json
--       editor-cli log grep ZAW164 --platform editor --context 0 --max-matches 200 --json
-- APPLY=false 只打印目标与当前值，不写入。本脚本不保存地图。
-- 命名沿用 GameCfg：West=MinX、East=MaxX、South=MinZ、North=MaxZ；墙体中心落在边界面上。
-- Position.y 是墙底（#65 P1 实测），高度沿用 y[-30,40]。
local APPLY = true
local MARK = 'ZAW164'
local THICKNESS, BOTTOM_Y, HEIGHT = 3, -30, 70
local SOUTH, MIDDLE, NORTH = -170, 185, 430
local EAST, WEST = 30, -810
local world = editor:GetService('World')

local boxes = {
  { '01 鱼塘', 1, WEST, -530, SOUTH, MIDDLE },
  { '02 虾池', 2, -530, -275, SOUTH, MIDDLE },
  { '03 蟹湖', 3, -275, EAST, SOUTH, MIDDLE },
  { '04 树林岛', 4, -155, EAST, MIDDLE, NORTH },
  { '05 沙滩岛', 5, -385, -155, MIDDLE, NORTH },
  { '06 礁石岛', 6, -575, -385, MIDDLE, NORTH },
  { '07 火山岛', 7, WEST, -575, MIDDLE, NORTH },
}

local function wallSpecs(box)
  local minX, maxX, minZ, maxZ = box[3], box[4], box[5], box[6]
  local centerX, centerZ = (minX + maxX) / 2, (minZ + maxZ) / 2
  local lengthX, lengthZ = maxX - minX + THICKNESS, maxZ - minZ + THICKNESS
  return {
    { 'West', minX, centerZ, THICKNESS, lengthZ },
    { 'East', maxX, centerZ, THICKNESS, lengthZ },
    { 'South', centerX, minZ, lengthX, THICKNESS },
    { 'North', centerX, maxZ, lengthX, THICKNESS },
  }
end

local function report(...)
  print(MARK .. '|' .. table.concat({ ... }, '|'))
end

local function vectorText(value)
  return string.format('%.3f,%.3f,%.3f', value.x or value.X or value[1], value.y or value.Y or value[2], value.z or value.Z or value[3])
end

local template = world:FindFirstChild('02 虾池'):FindFirstChild('空气墙'):FindFirstChild('Z2_BoundaryEast')
assert(template, MARK .. ': 模板墙缺失')

if APPLY then
  local zoneOne = world:FindFirstChild('01 鱼塘')
  local folder = zoneOne:FindFirstChild('空气墙')
  if not folder then
    folder = world:CreateUnit('Folder', {})
    folder.Name = '空气墙'
    folder:SetParent(zoneOne)
  end
  for _, side in ipairs({ 'West', 'East', 'South', 'North' }) do
    local name = 'Z1_Boundary' .. side
    if not folder:FindFirstChild(name) then
      local wall = template:Clone()
      wall.Name = name
      wall:SetParent(folder)
    end
  end
end

for _, box in ipairs(boxes) do
  local zone = world:FindFirstChild(box[1])
  local folder = zone and zone:FindFirstChild('空气墙')
  for _, spec in ipairs(wallSpecs(box)) do
    local name = 'Z' .. box[2] .. '_Boundary' .. spec[1]
    local wall = folder and folder:FindFirstChild(name)
    if not wall then
      report('MISSING', box[1], name)
    else
      if APPLY then
        wall:SetPosition(Vector3.New(spec[2], BOTTOM_Y, spec[3]))
        wall:SetProperty('Size', Vector3.New(spec[4], HEIGHT, spec[5]))
        wall:SetProperty('CanCollide', true)
      end
      report('WALL', box[1], name,
        'pos=' .. vectorText(wall.Position),
        'size=' .. vectorText(wall:GetProperty('Size')),
        'cc=' .. tostring(wall:GetProperty('CanCollide')),
        'cq=' .. tostring(wall:GetProperty('CanQuery')),
        'asset=' .. tostring(wall:GetProperty('AssetId')))
    end
  end
end
report('END', 'apply=' .. tostring(APPLY))
