-- #172 只读盘点（编辑器侧，edit mode）：七区钓鱼佬触发器、抽奖点标记与已有模型的位置、尺寸和来源，
-- 作为摆放占位模型（02–07 咸鱼、03–07 抽奖机）的基线。不写场景。
local MARK = 'NLI172'
local world = editor:GetService('World')
local ZONES = { '01 鱼塘', '02 虾池', '03 蟹湖', '04 树林岛', '05 沙滩岛', '06 礁石岛', '07 火山岛' }
local PATTERN = { 'Fisherman', 'Lottery', 'TGUnitFish', '抽奖', '咸鱼', '老虎机', '扭蛋' }
local PROPS = { 'UnitType', 'PrefabId', 'PresetId', 'AssetId', 'ModelId', 'RenderMeshId', 'Visible', 'CanCollide' }

local function c(v, i, k, u) return v[k] or v[u] or v[i] end
local function vec(v)
  if not v then return '-' end
  return string.format('%.3f,%.3f,%.3f', c(v, 1, 'x', 'X'), c(v, 2, 'y', 'Y'), c(v, 3, 'z', 'Z'))
end
local function prop(unit, name)
  local ok, value = pcall(function() return unit:GetProperty(name) end)
  if ok and value ~= nil then return tostring(value) end
  ok, value = pcall(function() return unit[name] end)
  if ok and value ~= nil then return tostring(value) end
end
local function matches(name)
  for _, p in ipairs(PATTERN) do if name:find(p, 1, true) then return true end end
end
local function report(zoneName, path, unit)
  local okP, pos = pcall(function() return unit.Position end)
  local okS, scale = pcall(function() return unit.Scale end)
  local okZ, size = pcall(function() return unit.Size end)
  local extra = {}
  for _, name in ipairs(PROPS) do
    local value = prop(unit, name)
    if value then extra[#extra + 1] = name .. '=' .. value end
  end
  print(MARK .. '|' .. zoneName .. '|' .. path .. '|pos=' .. vec(okP and pos or nil) .. '|scale=' .. vec(okS and scale or nil)
    .. '|size=' .. vec(okZ and size or nil) .. '|' .. table.concat(extra, '|'))
end

local function walk(zoneName, unit, path)
  local ok, children = pcall(function() return unit:GetChildren() end)
  if not ok or not children then return end
  for _, childUnit in ipairs(children) do
    local name = tostring(childUnit.Name)
    local childPath = path .. '/' .. name
    if matches(name) then report(zoneName, childPath, childUnit) end
    walk(zoneName, childUnit, childPath)
  end
end

for _, zoneName in ipairs(ZONES) do
  local zone = world:FindFirstChild(zoneName)
  if zone then walk(zoneName, zone, zoneName) else print(MARK .. '|' .. zoneName .. '|MISSING_ZONE') end
end
print(MARK .. '|END')
