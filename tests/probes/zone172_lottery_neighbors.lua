-- #172 只读：列 01/02 抽奖点（Z1_Lottery / Z2_Lottery）水平 RADIUS 米内的全部单位与其子级，
-- 找出两区抽奖机的模型本体，作为 03–07 摆放的样板。不写场景。
local MARK = 'LNB172'
local RADIUS = 10
local world = editor:GetService('World')
local TARGETS = { { '01 鱼塘', 'Z1_Lottery' }, { '02 虾池', 'Z2_Lottery' } }

local function c(v, i, k, u) return v[k] or v[u] or v[i] end
local function position(unit)
  local ok, p = pcall(function() return unit.Position end)
  if ok and p and c(p, 1, 'x', 'X') then return c(p, 1, 'x', 'X'), c(p, 2, 'y', 'Y'), c(p, 3, 'z', 'Z') end
end
local function prop(unit, name)
  local ok, value = pcall(function() return unit:GetProperty(name) end)
  if ok and value ~= nil then return tostring(value) end
  return '-'
end

for _, target in ipairs(TARGETS) do
  local zone = assert(world:FindFirstChild(target[1]), MARK .. ': 缺区 ' .. target[1])
  local anchor = assert(zone:FindFirstChild('设施'):FindFirstChild(target[2]), MARK .. ': 缺 ' .. target[2])
  local ax, _, az = position(anchor)
  for _, childUnit in ipairs(anchor:GetChildren()) do
    print(MARK .. '|' .. target[2] .. '|CHILD|' .. tostring(childUnit.Name) .. '|' .. prop(childUnit, 'UnitType'))
  end
  for _, unit in ipairs(zone:GetDescendants()) do
    local x, y, z = position(unit)
    if x and (x - ax) ^ 2 + (z - az) ^ 2 <= RADIUS * RADIUS then
      local parent = unit.Parent and tostring(unit.Parent.Name) or '-'
      print(MARK .. '|' .. target[2] .. '|NEAR|' .. parent .. '/' .. tostring(unit.Name)
        .. string.format('|pos=%.3f,%.3f,%.3f', x, y, z) .. '|type=' .. prop(unit, 'UnitType')
        .. '|asset=' .. prop(unit, 'AssetId') .. '|mesh=' .. prop(unit, 'RenderMeshId'))
    end
  end
end
print(MARK .. '|END')
