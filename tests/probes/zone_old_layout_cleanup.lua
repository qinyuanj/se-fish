-- #164 清理旧布局并对齐美术新版（编辑器侧，edit mode）。
-- 复跑：editor-cli exec --file <本文件> --expect-edit-mode --timeout 120 --json
--       editor-cli log grep ZOLC164 --platform editor --context 0 --max-matches 400 --json
-- APPLY=false 只打印目标与当前值，不写入。本脚本不保存地图。
-- 恢复依据：同批次运行前的 P2BASE65V2 基线；06 的 地块 是唯一连续地面，不在删除范围。
local APPLY = true
local MARK = 'ZOLC164'
local world = editor:GetService('World')

local function zoneFolder(zoneName, folderName)
  local zone = world:FindFirstChild(zoneName)
  return zone and zone:FindFirstChild(folderName)
end

local function child(zoneName, folderName, name)
  local folder = zoneFolder(zoneName, folderName)
  return folder and folder:FindFirstChild(name)
end

local function prop(unit, key)
  local ok, value = pcall(function() return unit:GetProperty(key) end)
  return ok and tostring(value) or 'err'
end

local deleteFolders = {
  { '01 鱼塘', '地块' }, { '02 虾池', '地块' }, { '03 蟹湖', '地块' },
  { '04 树林岛', '地块' }, { '05 沙滩岛', '地块' }, { '07 火山岛', '地块' },
}

local moves = {
  { '01 鱼塘', '摆渡', 'FerryBoat', -554.75, 1.178, -16.187, '摆渡车' },
  { '02 虾池', '摆渡', 'FerryReturn', -554.75, 1.178, -16.187, '摆渡车' },
  { '02 虾池', '摆渡', 'Z2_FerryOut', -331.395, 1.178, -16.187, '摆渡车' },
  { '03 蟹湖', '摆渡', 'Z3_FerryReturn', -331.395, 1.178, -16.187, '摆渡车' },
  { '03 蟹湖', '摆渡', 'Z3_FerryOut', -28.989, 1.266, 129.591, '摆渡船' },
  { '04 树林岛', '摆渡', 'Z4_FerryOut', -139.657, 0.596, 334.814, '摆渡船' },
  { '05 沙滩岛', '摆渡', 'Z5_FerryReturn', -222.35, 0.596, 334.814, '摆渡船' },
  { '03 蟹湖', '设施', 'Z3_Grill', -129.205, 1.598, -46.91, '火焰' },
  { '04 树林岛', '设施', 'Z4_Grill', -78.344, 6.399, 327.89, '烤架' },
  { '05 沙滩岛', '设施', 'Z5_Grill', -262.685, 6.399, 333.691, '烤架' },
  { '06 礁石岛', '设施', 'Z6_Grill', -470.25, 4.826, 334.75, '厨师蛋' },
  { '07 火山岛', '设施', 'Z7_Grill', -688.509, 10.106, 337.698, '圆台' },
}

local walls = { 'East', 'West', 'North', 'South' }
local wallZones = { { '02 虾池', 2 }, { '03 蟹湖', 3 }, { '04 树林岛', 4 }, { '05 沙滩岛', 5 }, { '06 礁石岛', 6 }, { '07 火山岛', 7 } }
local slabs = {
  { '03 蟹湖', '摆渡', 'Z3_Safe' }, { '04 树林岛', '摆渡', 'Z4_Safe' }, { '05 沙滩岛', '摆渡', 'Z5_Safe' },
  { '06 礁石岛', '摆渡', 'Z6_Safe' }, { '07 火山岛', '摆渡', 'Z7_Safe' },
  { '04 树林岛', '水域', 'Z4_Water' }, { '05 沙滩岛', '水域', 'Z5_Water' },
  { '06 礁石岛', '水域', 'Z6_Water' }, { '07 火山岛', '水域', 'Z7_Water' },
  { '01 鱼塘', '摆渡', 'FerryBoat' }, { '02 虾池', '摆渡', 'FerryReturn' },
}

local missing = 0
local function report(kind, path, unit, extra)
  if not unit then missing = missing + 1 end
  print(MARK .. '|' .. kind .. '|' .. path .. '|' .. (unit and 'found' or 'MISSING') .. '|' .. (extra or ''))
end

for _, item in ipairs(deleteFolders) do
  local folder = zoneFolder(item[1], item[2])
  local count = 0
  if folder then count = #folder:GetChildren() end
  report('DELETE', item[1] .. '/' .. item[2], folder, 'children=' .. count)
end
for _, item in ipairs(moves) do
  local unit = child(item[1], item[2], item[3])
  report('MOVE', item[1] .. '/' .. item[3], unit, (unit and tostring(unit:GetPosition()) or '') .. '->' .. item[7])
end
for _, zone in ipairs(wallZones) do
  for _, side in ipairs(walls) do
    local name = 'Z' .. zone[2] .. '_Boundary' .. side
    local unit = child(zone[1], '空气墙', name)
    report('WALL', zone[1] .. '/' .. name, unit, unit and ('CanCollide=' .. prop(unit, 'CanCollide')) or '')
  end
end
for _, item in ipairs(slabs) do
  local unit = child(item[1], item[2], item[3])
  report('HIDE', item[1] .. '/' .. item[3], unit, unit and ('CanCollide=' .. prop(unit, 'CanCollide') .. ',Visible=' .. tostring(unit:GetVisible())) or '')
end
print(MARK .. '|DRY|missing=' .. missing .. '|apply=' .. tostring(APPLY))

if not APPLY then
  print(MARK .. '|END|dry-run')
  return
end
if missing > 0 then
  error(MARK .. ': 目标缺失，未写入')
end

for _, item in ipairs(moves) do
  child(item[1], item[2], item[3]):SetPosition(Vector3.New(item[4], item[5], item[6]))
end
for _, zone in ipairs(wallZones) do
  for _, side in ipairs(walls) do
    child(zone[1], '空气墙', 'Z' .. zone[2] .. '_Boundary' .. side):SetProperty('CanCollide', false)
  end
end
for _, item in ipairs(slabs) do
  local unit = child(item[1], item[2], item[3])
  unit:SetProperty('CanCollide', false)
  unit:SetVisible(false)
end
for _, item in ipairs(deleteFolders) do
  zoneFolder(item[1], item[2]):Destroy()
end
print(MARK .. '|END|applied')
