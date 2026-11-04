-- #164 回退重做 B1：七区点位重排（编辑器侧，edit mode）。平面坐标来自 2026-11-04 测算表（#164 评论），高度取 ZRC164 中心贴地射线实测（Z4_Shop 取同轮东侧 1.5 米采样）。
-- 默认 dry-run；仅在脚本内把 APPLY 改为 true 后写入，写完改回 false。不保存地图。可重复执行。
-- 名字按七区子树递归查找（全图唯一由 ZoneMarkers 校验）；缺 Z2_Safe 时克隆 Z3_Safe 到 02/摆渡。
-- 跟随件：FishermanModel / FX_Shop 与 01 的 TGUnitFish / TGUnitShop 同步平移；06/07 商店的钩子与绳索先对齐中式杆的 x。
local APPLY = false
local MARK = 'ZPR164'
local world = editor:GetService('World')
local points = {
  {'01 鱼塘','Z1_Safe',-616,1.00,68},
  {'01 鱼塘','出生点',-616,1.00,64},
  {'01 鱼塘','TGUnitFish',-628,1.00,52},
  {'01 鱼塘','TGUnitShop',-604,1.00,52},
  {'01 鱼塘','Z1_Lottery',-580,1.00,52},
  {'01 鱼塘','Z1_Bait1',-640,1.00,78},
  {'01 鱼塘','Z1_Bait2',-628,1.00,84},
  {'01 鱼塘','Z1_Bait3',-616,1.00,86},
  {'01 鱼塘','Z1_Bait4',-604,1.00,84},
  {'01 鱼塘','Z1_Bait5',-592,1.00,78},
  {'02 虾池','Z2_Safe',-315,1.00,15},
  {'02 虾池','TGUnitFishShrimp',-340,1.00,30},
  {'02 虾池','TGUnitShopShrimp',-340,1.00,5},
  {'02 虾池','Z2_Lottery',-340,1.00,55},
  {'02 虾池','FerryReturn',-300,1.00,35},
  {'02 虾池','Z2_Bait1',-322,1.00,40},
  {'02 虾池','Z2_Bait2',-305,1.00,0},
  {'03 蟹湖','Z3_Safe',-160,1.01,90},
  {'03 蟹湖','Z3_Fisherman',-160,1.01,62},
  {'03 蟹湖','Z3_Shop',-140,1.01,75},
  {'03 蟹湖','Z3_Lottery',-180,1.01,75},
  {'03 蟹湖','Z3_FerryOut',-29,0.97,110},
  {'03 蟹湖','Z3_FerryReturn',-205,1.01,65},
  {'03 蟹湖','Z3_Bait1',-190,1.01,95},
  {'03 蟹湖','Z3_Bait2',-130,1.01,95},
  {'04 树林岛','Z4_Safe',-90,3.14,310},
  {'04 树林岛','Z4_Fisherman',-100,5.34,325},
  {'04 树林岛','Z4_Shop',-98.5,5.09,350},
  {'04 树林岛','Z4_Lottery',-70,4.96,348},
  {'04 树林岛','Z4_FerryOut',-120,0.55,335},
  {'04 树林岛','Z4_FerryReturn',-80,0.65,300},
  {'04 树林岛','Z4_Bait1',-110,0.46,310},
  {'04 树林岛','Z4_Bait2',-65,5.33,340},
  {'05 沙滩岛','Z5_Safe',-280,4.67,312},
  {'05 沙滩岛','Z5_Fisherman',-295,5.00,330},
  {'05 沙滩岛','Z5_Shop',-295,4.98,355},
  {'05 沙滩岛','Z5_Lottery',-270,4.43,365},
  {'05 沙滩岛','Z5_FerryOut',-314,3.90,334},
  {'05 沙滩岛','Z5_FerryReturn',-240,2.15,335},
  {'05 沙滩岛','Z5_Bait1',-305,3.54,315},
  {'05 沙滩岛','Z5_Bait2',-250,3.77,350},
  {'06 礁石岛','Z6_Safe',-505,6.00,312},
  {'06 礁石岛','Z6_Fisherman',-505,6.00,340},
  {'06 礁石岛','Z6_Shop',-530,6.53,325},
  {'06 礁石岛','Z6_Lottery',-480,6.00,300},
  {'06 礁石岛','Z6_FerryOut',-555,6.00,312},
  {'06 礁石岛','Z6_FerryReturn',-450,6.00,312},
  {'06 礁石岛','Z6_Bait1',-490,6.00,290},
  {'06 礁石岛','Z6_Bait2',-525,6.00,295},
  {'07 火山岛','Z7_Safe',-640,0.53,332},
  {'07 火山岛','Z7_Fisherman',-628,0.50,345},
  {'07 火山岛','Z7_Shop',-628,0.52,320},
  {'07 火山岛','Z7_Lottery',-629,0.41,364},
  {'07 火山岛','Z7_FerryReturn',-633,0.46,308},
  {'07 火山岛','Z7_Bait1',-640,0.53,358},
  {'07 火山岛','Z7_Bait2',-645,1.11,310},
}
local follow = { {'TGUnitFish','FishermanModel'}, {'TGUnitShop','FX_Shop'} }
local index = {}
local function walk(zoneName, node)
  for _, unit in ipairs(node:GetChildren()) do
    if unit.Name ~= '装饰' then
      local key = zoneName .. '|' .. unit.Name
      if index[key] then index[key] = false else index[key] = unit end
      walk(zoneName, unit)
    end
  end
end
local zones = { '01 鱼塘', '02 虾池', '03 蟹湖', '04 树林岛', '05 沙滩岛', '06 礁石岛', '07 火山岛' }
for _, zoneName in ipairs(zones) do walk(zoneName, assert(world:FindFirstChild(zoneName), zoneName)) end
local function find(zoneName, name)
  local unit = index[zoneName .. '|' .. name]
  if unit == false then error(MARK .. ': 重名 ' .. zoneName .. '/' .. name) end
  return unit
end
local function c(v, i, k) return v[k] or v[i] end
local function xyz(v) return c(v,1,'x'), c(v,2,'y'), c(v,3,'z') end
local function text(v) local x,y,z = xyz(v) return string.format('%.2f,%.2f,%.2f', x, y, z) end
local function place(unit, v) if unit.SetPosition then unit:SetPosition(v) else unit:SetProperty('Position', v) end end

if APPLY and not find('02 虾池','Z2_Safe') then
  local safe = assert(find('03 蟹湖','Z3_Safe'))
  local clone = safe:Clone()
  clone.Name = 'Z2_Safe'
  clone:SetParent(assert(world:FindFirstChild('02 虾池'):FindFirstChild('摆渡')))
  index['02 虾池|Z2_Safe'] = clone
  print(MARK .. '|CREATE|Z2_Safe')
end

for _, zoneName in ipairs({'06 礁石岛','07 火山岛'}) do
  local pole = find(zoneName, '中式杆')
  for _, name in ipairs({'铁艺弯钩','直线绳索'}) do
    local unit = find(zoneName, name)
    if pole and unit then
      local px = xyz(pole.Position)
      local _, y, z = xyz(unit.Position)
      print(MARK .. '|HOOK|' .. zoneName .. '/' .. name .. '|before=' .. text(unit.Position) .. '|after=' .. string.format('%.2f,%.2f,%.2f', px, y, z))
      if APPLY then place(unit, Vector3.New(px, y, z)) end
    end
  end
end

local missing = 0
for _, item in ipairs(points) do
  local zoneName, name, x, y, z = item[1], item[2], item[3], item[4], item[5]
  local unit = find(zoneName, name)
  if not unit then
    missing = missing + 1
    print(MARK .. '|MISSING|' .. zoneName .. '/' .. name)
  else
    local ox, oy, oz = xyz(unit.Position)
    print(MARK .. '|POINT|' .. zoneName .. '/' .. name .. '|before=' .. text(unit.Position) .. '|after=' .. string.format('%.2f,%.2f,%.2f', x, y, z))
    for _, pair in ipairs(follow) do
      if pair[1] == name then
        local other = find(zoneName, pair[2])
        if other then
          local fx, fy, fz = xyz(other.Position)
          local tx, ty, tz = fx + x - ox, fy + y - oy, fz + z - oz
          print(MARK .. '|FOLLOW|' .. zoneName .. '/' .. pair[2] .. '|before=' .. text(other.Position) .. '|after=' .. string.format('%.2f,%.2f,%.2f', tx, ty, tz))
          if APPLY then place(other, Vector3.New(tx, ty, tz)) end
        end
      end
    end
    if APPLY then
      place(unit, Vector3.New(x, y, z))
      if name == 'Z1_Lottery' then unit:SetProperty('CanCollide', false) end
    end
  end
end
print(MARK .. '|END|points=' .. #points .. '|missing=' .. missing .. '|apply=' .. tostring(APPLY))
