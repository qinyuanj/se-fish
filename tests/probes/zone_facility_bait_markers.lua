-- #164 回退重做第 2 批：设施、烧烤、抽奖与鱼饵标记（编辑器侧，edit mode）。
-- 默认 dry-run；仅在脚本内把 APPLY 改为 true 后写入。不保存地图。
local APPLY = false
local MARK = 'ZFB164'
local world = editor:GetService('World')

local items = {
  {'01 鱼塘','设施','Z1_Bait1',-610,2,20},{'01 鱼塘','设施','Z1_Bait2',-630,2,20},
  {'01 鱼塘','设施','Z1_Bait3',-600,2,30},{'01 鱼塘','设施','Z1_Bait4',-640,2,30},{'01 鱼塘','设施','Z1_Bait5',-620,0.973,40},
  {'01 鱼塘','设施','TGUnitFish',-616.75,1,-9.25},{'01 鱼塘','设施','TGUnitShop',-619.25,1,15.25},
  {'02 虾池','设施','Z2_Bait1',-355,0.844,20},{'02 虾池','设施','Z2_Bait2',-420,0.984,60},
  {'02 虾池','设施','TGUnitFishShrimp',-364.5,1,20},{'02 虾池','设施','TGUnitShopShrimp',-376.5,1,30},{'02 虾池','设施','Z2_Lottery',-385,1,30},
  {'03 蟹湖','设施','Z3_Bait1',-180,1.010,80},{'03 蟹湖','设施','Z3_Bait2',-120,1.010,80},
  {'03 蟹湖','设施','Z3_Grill',-129.205,3.956,-46.91},{'03 蟹湖','设施','Z3_Lottery',-161.5,1.010,90},
  {'03 蟹湖','设施','Z3_Fisherman',-161.5,1.010,70},{'03 蟹湖','设施','Z3_Shop',-158.5,1.010,90},
  {'04 树林岛','设施','Z4_Bait1',-90,5.175,320},{'04 树林岛','设施','Z4_Bait2',-100,5.347,340},
  {'04 树林岛','设施','Z4_Grill',-78.344,6.597,327.89},{'04 树林岛','设施','Z4_Lottery',-100,5.347,350},
  {'04 树林岛','设施','Z4_Fisherman',-95,5.347,330},{'04 树林岛','设施','Z4_Shop',-85,5.347,340},
  {'05 沙滩岛','设施','Z5_Bait1',-250,3.568,320},{'05 沙滩岛','设施','Z5_Bait2',-290,4.931,360},
  {'05 沙滩岛','设施','Z5_Grill',-262.685,6.597,333.691},{'05 沙滩岛','设施','Z5_Lottery',-280,5,350},
  {'05 沙滩岛','设施','Z5_Fisherman',-270,5,340},{'05 沙滩岛','设施','Z5_Shop',-280,5,330},
  {'06 礁石岛','设施','Z6_Bait1',-480,6,320},{'06 礁石岛','设施','Z6_Bait2',-460,6,320},
  {'06 礁石岛','设施','Z6_Grill',-470.25,6,334.75},{'06 礁石岛','设施','Z6_Lottery',-490,6,340},
  {'06 礁石岛','设施','Z6_Fisherman',-470,6,320},{'06 礁石岛','设施','Z6_Shop',-490,6,330},
  {'07 火山岛','设施','Z7_Bait1',-610,0.531,350},{'07 火山岛','设施','Z7_Bait2',-600,0.516,350},
  {'07 火山岛','设施','Z7_Grill',-688.509,10.106,337.698},{'07 火山岛','设施','Z7_Lottery',-620,0.531,340},
  {'07 火山岛','设施','Z7_Fisherman',-610,0.531,340},{'07 火山岛','设施','Z7_Shop',-600,0.516,340},
}

local function child(zoneName,folderName,name)
  local zone = world:FindFirstChild(zoneName)
  local folder = zone and zone:FindFirstChild(folderName)
  return folder and folder:FindFirstChild(name)
end
local template = assert(child('03 蟹湖','设施','Z3_Bait1'), MARK .. ': 鱼饵标记模板缺失')
local function component(v,index,lower,upper) return v[lower] or v[upper] or v[index] end
local function text(v) return string.format('%.3f,%.3f,%.3f',component(v,1,'x','X'),component(v,2,'y','Y'),component(v,3,'z','Z')) end
local missing, created = 0,0

for _,item in ipairs(items) do
  local unit = child(item[1],item[2],item[3])
  if not unit and APPLY then
    unit = template:Clone()
    unit.Name = item[3]
    unit:SetParent(world:FindFirstChild(item[1]):FindFirstChild(item[2]))
    created = created + 1
  end
  print(MARK .. '|' .. item[3] .. '|before=' .. (unit and text(unit.Position) or 'MISSING')
    .. '|after=' .. item[4] .. ',' .. item[5] .. ',' .. item[6])
  if not unit then missing = missing + 1 end
  if unit and APPLY then
    unit:SetPosition(Vector3.New(item[4],item[5],item[6]))
    if item[3]:match('^Z%d_Bait%d$') or item[3]:match('^Z%d_Lottery$') then
      unit:SetProperty('CanCollide',false)
      unit:SetProperty('CanQuery',false)
      unit:SetVisible(false)
    end
  end
end
print(MARK .. '|END|missing=' .. missing .. '|created=' .. created .. '|apply=' .. tostring(APPLY))
