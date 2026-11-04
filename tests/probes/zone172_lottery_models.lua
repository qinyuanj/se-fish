-- #172 七区抽奖机占位模型（编辑器侧，edit mode）：官方「电视」official://preset/1504175（引擎临时占位，
-- 正式资源见 #44；官方库无抽奖机类预设），命名 Z<i>_LotteryModel，放进本区「设施」，与本区抽奖点标记
-- Z<i>_Lottery 同点（标记已贴地，#164）。交互仍以标记为锚点，半径不变。
-- 模板：03 的 Z3_LotteryModel。它由 AssetService:CreateUnitByAsset 建出（返回的是单位 ID 而非对象，建出后无父级），
-- 再 SetParent 到 03/设施并改名；其余区一律 Clone 它。
-- 默认 dry-run；执行时用 APPLY=true 的临时副本，入库版本保持 false。不保存地图。可重复执行（已存在只对位）。
local APPLY = false
local MARK = 'LTM172'
local world = editor:GetService('World')
local ASSET = 'official://preset/1504175'
local ZONES = { '01 鱼塘', '02 虾池', '03 蟹湖', '04 树林岛', '05 沙滩岛', '06 礁石岛', '07 火山岛' }

local function c(v, i, k, u) return v[k] or v[u] or v[i] end
local function text(v) return string.format('%.3f,%.3f,%.3f', c(v, 1, 'x', 'X'), c(v, 2, 'y', 'Y'), c(v, 3, 'z', 'Z')) end
local function facilities(zoneName)
  local zone = assert(world:FindFirstChild(zoneName), MARK .. ': 缺区 ' .. zoneName)
  return assert(zone:FindFirstChild('设施'), MARK .. ': 缺 ' .. zoneName .. '/设施')
end

local template = assert(facilities('03 蟹湖'):FindFirstChild('Z3_LotteryModel'), MARK .. ': 模板 Z3_LotteryModel 缺失')
assert(template:GetProperty('AssetId') == ASSET, MARK .. ': 模板不是官方电视')
local created, moved = 0, 0
for index, zoneName in ipairs(ZONES) do
  local folder = facilities(zoneName)
  local marker = assert(folder:FindFirstChild('Z' .. index .. '_Lottery'), MARK .. ': 缺抽奖点 Z' .. index .. '_Lottery')
  local name = 'Z' .. index .. '_LotteryModel'
  local target = marker.Position
  local unit = folder:FindFirstChild(name)
  print(MARK .. '|' .. name .. '|before=' .. (unit and text(unit.Position) or 'MISSING') .. '|after=' .. text(target))
  if APPLY then
    if not unit then
      unit = template:Clone()
      unit.Name = name
      unit:SetParent(folder)
      created = created + 1
    end
    unit:SetPosition(Vector3.New(c(target, 1, 'x', 'X'), c(target, 2, 'y', 'Y'), c(target, 3, 'z', 'Z')))
    moved = moved + 1
  end
end
print(MARK .. '|END|created=' .. created .. '|moved=' .. moved .. '|apply=' .. tostring(APPLY))
