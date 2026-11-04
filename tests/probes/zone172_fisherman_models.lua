-- #172 02–07 钓鱼佬占位模型（编辑器侧，edit mode）：以 01 的 FishermanModel（官方「咸鱼」official://preset/102179，
-- 引擎临时占位，正式资源见 #44）为模板 Clone，命名 Z<i>_FishermanModel，放进本区「设施」，
-- 位置取本区钓鱼佬触发器（触发器已贴地，#164；01 模型与触发器同点同高）。
-- 默认 dry-run；仅在脚本内把 APPLY 改为 true 后写入，写完改回 false。不保存地图。可重复执行（已存在只对位）。
local APPLY = false
local MARK = 'FMM172'
local world = editor:GetService('World')
local ZONES = {
  { '02 虾池', 'TGUnitFishShrimp', 'Z2_FishermanModel' },
  { '03 蟹湖', 'Z3_Fisherman', 'Z3_FishermanModel' },
  { '04 树林岛', 'Z4_Fisherman', 'Z4_FishermanModel' },
  { '05 沙滩岛', 'Z5_Fisherman', 'Z5_FishermanModel' },
  { '06 礁石岛', 'Z6_Fisherman', 'Z6_FishermanModel' },
  { '07 火山岛', 'Z7_Fisherman', 'Z7_FishermanModel' },
}

local function c(v, i, k, u) return v[k] or v[u] or v[i] end
local function text(v) return string.format('%.3f,%.3f,%.3f', c(v, 1, 'x', 'X'), c(v, 2, 'y', 'Y'), c(v, 3, 'z', 'Z')) end
local function facilities(zoneName)
  local zone = assert(world:FindFirstChild(zoneName), MARK .. ': 缺区 ' .. zoneName)
  return assert(zone:FindFirstChild('设施'), MARK .. ': 缺 ' .. zoneName .. '/设施')
end

local template = assert(facilities('01 鱼塘'):FindFirstChild('FishermanModel'), MARK .. ': 01 FishermanModel 缺失')
assert(template:GetProperty('AssetId') == 'official://preset/102179', MARK .. ': 模板不是官方咸鱼')
local created, moved = 0, 0
for _, item in ipairs(ZONES) do
  local folder = facilities(item[1])
  local trigger = assert(folder:FindFirstChild(item[2]), MARK .. ': 缺触发器 ' .. item[2])
  local target = trigger.Position
  local unit = folder:FindFirstChild(item[3])
  print(MARK .. '|' .. item[3] .. '|before=' .. (unit and text(unit.Position) or 'MISSING')
    .. '|after=' .. text(target) .. '|trigger=' .. item[2])
  if APPLY then
    if not unit then
      unit = template:Clone()
      unit.Name = item[3]
      unit:SetParent(folder)
      created = created + 1
    end
    unit:SetPosition(Vector3.New(c(target, 1, 'x', 'X'), c(target, 2, 'y', 'Y'), c(target, 3, 'z', 'Z')))
    moved = moved + 1
  end
end
print(MARK .. '|END|created=' .. created .. '|moved=' .. moved .. '|apply=' .. tostring(APPLY))
