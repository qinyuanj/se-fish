-- #164 收尾：修关键 NPC 高度（编辑器侧，edit mode）。NGP164 实测模型底面对脚下地面得到两处偏差：
-- FishermanModel 按旧灰盒高岸摆放，B1 平移时保留了高差，悬空 7.6 米，落到 01 地面 y=1。
-- 06 烧烤棚连同厨师蛋共 19 件都按 y≈4.83 摆放，比 Z6_Land 顶面 6.00 低 1.17 米，整体抬高；
-- 单抬厨师蛋会让他浮在埋着的棚板上方。Z6_Grill 已在 6.00，不动。
-- 默认 dry-run；仅在脚本内把 APPLY 改为 true 后写入，写完改回 false。不保存地图。可重复执行。
local APPLY = false
local MARK = 'NHF164'
local FISHERMAN_Y = 1.0
local SHED_LIFT = 1.17
local SHED_COUNT = 19
local SHED_BOX = { minX = -480, maxX = -463, minZ = 322, maxZ = 338, minY = 4.5, maxY = 15 }
local SHED_DONE_Y = 5.9
local world = editor:GetService('World')
local function c(v, i, k) return v[k] or v[i] end
local function text(x, y, z) return string.format('%.2f,%.2f,%.2f', x, y, z) end

local function place(unit, x, y, z)
  local target = Vector3.New(x, y, z)
  if unit.SetPosition then unit:SetPosition(target) else unit:SetProperty('Position', target) end
end

local fisherman
for _, unit in ipairs(world:GetDescendants()) do
  if unit.Name == 'FishermanModel' then
    if fisherman then error(MARK .. ': FishermanModel 重名') end
    fisherman = unit
  end
end
assert(fisherman, MARK .. ': FishermanModel 缺失')
local fp = fisherman.Position
local fx, fy, fz = c(fp, 1, 'x'), c(fp, 2, 'y'), c(fp, 3, 'z')
print(MARK .. '|FISHERMAN|before=' .. text(fx, fy, fz) .. '|after=' .. text(fx, FISHERMAN_Y, fz))
if APPLY then place(fisherman, fx, FISHERMAN_Y, fz) end

local decor = assert(world:FindFirstChild('06 礁石岛'):FindFirstChild('装饰'), MARK .. ': 06/装饰 缺失')
local shed, chef = {}, nil
for _, unit in ipairs(decor:GetDescendants()) do
  local ok, p = pcall(function() return unit.Position end)
  if ok and p and c(p, 1, 'x') then
    local x, y, z = c(p, 1, 'x'), c(p, 2, 'y'), c(p, 3, 'z')
    local inside = x >= SHED_BOX.minX and x <= SHED_BOX.maxX and z >= SHED_BOX.minZ and z <= SHED_BOX.maxZ
      and y >= SHED_BOX.minY and y <= SHED_BOX.maxY + SHED_LIFT
    if inside and not unit.Name:match('假山石') then
      shed[#shed + 1] = { unit = unit, x = x, y = y, z = z }
      if unit.Name == '厨师蛋' then chef = shed[#shed] end
    end
  end
end
assert(#shed == SHED_COUNT, MARK .. ': 烧烤棚件数不符 ' .. #shed)
assert(chef, MARK .. ': 06 厨师蛋缺失')

local lifted = chef.y >= SHED_DONE_Y
for _, item in ipairs(shed) do
  local after = lifted and item.y or item.y + SHED_LIFT
  print(MARK .. '|SHED|' .. item.unit.Name .. '|before=' .. text(item.x, item.y, item.z) .. '|afterY=' .. string.format('%.2f', after))
  if APPLY and not lifted then place(item.unit, item.x, after, item.z) end
end
print(MARK .. '|END|shed=' .. #shed .. '|alreadyLifted=' .. tostring(lifted) .. '|apply=' .. tostring(APPLY))
