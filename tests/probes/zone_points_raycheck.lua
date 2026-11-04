-- #164 回退重做：七区新点位落地复测（试玩服务端，只读）。点位同 2026-11-04 测算表，地图尚未写入时也可测。
-- 复跑：试玩中 editor-cli exec --file tests/probes/zone_points_raycheck.lua --platform server
--       editor-cli log grep ZRC164 --platform server --context 0 --max-matches 200 --json
-- 每点打中心与十字 ±1.5 米共 5 条高空射线（y=200 向下 400），不限定目标，只排除本表点位、水域、空气墙、设施跟随件与玩家角色（Z6_Land 等实体地块不排除）。
-- 中心点再打一条贴地射线（期望高度 +1 向下 20），与 MgrLoot:Ground 同口径。
-- 行格式 ZRC164|P|<区序>|<点名>|expect=<高度>|low:<贴地结果>|<dx,dz:命中名/父名@高度^法线y;…>；miss 记 '-'。
-- 判定：06 的非石头点应命中 Z6_Land@6.00，仍 miss 就停下查（MgrLoot:SpawnBait 无命中会跳过刷新）；其他点命中装饰且明显高于 expect 的算待处理，贴地结果 miss 的鱼饵点直接不通过。
local MARK = 'ZRC164'
local CROSS = { { 0, 0 }, { 1.5, 0 }, { -1.5, 0 }, { 0, 1.5 }, { 0, -1.5 } }
local points = {
  {1,'Z1_Safe',-616,1.00,68},
  {1,'出生点',-616,1.00,64},
  {1,'TGUnitFish',-628,1.00,52},
  {1,'TGUnitShop',-604,1.00,52},
  {1,'Z1_Lottery',-580,1.00,52},
  {1,'FerryBoat',-560,1.17,-10},
  {1,'Z1_Bait1',-640,1.00,78},
  {1,'Z1_Bait2',-628,1.00,84},
  {1,'Z1_Bait3',-616,1.00,86},
  {1,'Z1_Bait4',-604,1.00,84},
  {1,'Z1_Bait5',-592,1.00,78},
  {2,'Z2_Safe',-315,1.00,15},
  {2,'TGUnitFishShrimp',-340,1.00,30},
  {2,'TGUnitShopShrimp',-340,1.00,5},
  {2,'Z2_Lottery',-340,1.00,55},
  {2,'Z2_FerryOut',-335,1.17,-10},
  {2,'FerryReturn',-300,1.00,35},
  {2,'Z2_Bait1',-322,1.00,40},
  {2,'Z2_Bait2',-305,1.00,0},
  {3,'Z3_Safe',-160,1.01,90},
  {3,'Z3_Fisherman',-160,1.01,62},
  {3,'Z3_Shop',-140,1.01,75},
  {3,'Z3_Lottery',-180,1.01,75},
  {3,'Z3_Grill',-129.21,1.01,-46.91},
  {3,'Z3_FerryOut',-29,0.97,110},
  {3,'Z3_FerryReturn',-205,1.01,65},
  {3,'Z3_Bait1',-190,1.01,95},
  {3,'Z3_Bait2',-130,1.01,95},
  {4,'Z4_Safe',-90,3.14,310},
  {4,'Z4_Fisherman',-100,5.34,325},
  {4,'Z4_Shop',-98.5,5.09,350},
  {4,'Z4_Lottery',-70,4.96,348},
  {4,'Z4_Grill',-78.34,5.35,327.89},
  {4,'Z4_FerryOut',-120,0.55,335},
  {4,'Z4_FerryReturn',-80,0.65,300},
  {4,'Z4_Bait1',-110,0.46,310},
  {4,'Z4_Bait2',-65,5.33,340},
  {5,'Z5_Safe',-280,4.67,312},
  {5,'Z5_Fisherman',-295,5.00,330},
  {5,'Z5_Shop',-295,4.98,355},
  {5,'Z5_Lottery',-270,4.43,365},
  {5,'Z5_Grill',-262.69,5.00,333.69},
  {5,'Z5_FerryOut',-314,3.90,334},
  {5,'Z5_FerryReturn',-240,2.15,335},
  {5,'Z5_Bait1',-305,3.54,315},
  {5,'Z5_Bait2',-250,3.77,350},
  {6,'Z6_Safe',-505,6.00,312},
  {6,'Z6_Fisherman',-505,6.00,340},
  {6,'Z6_Shop',-530,6.53,325},
  {6,'Z6_Lottery',-480,6.00,300},
  {6,'Z6_Grill',-470.25,6.00,334.75},
  {6,'Z6_FerryOut',-555,6.00,312},
  {6,'Z6_FerryReturn',-450,6.00,312},
  {6,'Z6_Bait1',-490,6.00,290},
  {6,'Z6_Bait2',-525,6.00,295},
  {7,'Z7_Safe',-640,0.53,332},
  {7,'Z7_Fisherman',-628,0.50,345},
  {7,'Z7_Shop',-628,0.52,320},
  {7,'Z7_Lottery',-629,0.41,364},
  {7,'Z7_Grill',-688.51,1.01,337.7},
  {7,'Z7_FerryReturn',-633,0.46,308},
  {7,'Z7_Bait1',-640,0.53,358},
  {7,'Z7_Bait2',-645,1.11,310},
}
local physics = game:GetService('PhysicsService')
local world = game:GetService('World')
local players = game:GetService('Players')
local stale = { FishermanModel = true, FX_Shop = true, ['出生点'] = true }
for _, item in ipairs(points) do stale[item[2]] = true end
local excluded = {}
for _, unit in ipairs(world:GetDescendants()) do
  if stale[unit.Name] or unit.Name:match('^Z%d_Water%d*$') or unit.Name:match('^Z%d_Boundary') then excluded[#excluded + 1] = unit end
end
for _, player in ipairs(players:GetPlayers()) do
  if player.Character then excluded[#excluded + 1] = player.Character end
end
local params = RaycastParams.New()
params.FilterType = Enums.RaycastFilterType.Exclude
params.FilterDescendantsInstances = excluded
print(MARK .. '|excluded=' .. #excluded .. '|points=' .. #points)
local function describe(ok, hit)
  if not ok then return 'ERR' end
  if not hit then return '-' end
  local unit = hit.Instance
  local parent = unit and unit.Parent
  return string.format('%s/%s@%.2f^%.2f', unit and unit.Name or '?', parent and parent.Name or '?', hit.Position.y, hit.Normal and hit.Normal.y or 0)
end
for _, item in ipairs(points) do
  local samples = {}
  for _, offset in ipairs(CROSS) do
    local origin = Vector3.New(item[3] + offset[1], 200, item[5] + offset[2])
    samples[#samples + 1] = offset[1] .. ',' .. offset[2] .. ':' .. describe(pcall(physics.Raycast, physics, origin, Vector3.New(0, -400, 0), params))
  end
  local low = describe(pcall(physics.Raycast, physics, Vector3.New(item[3], item[4] + 1, item[5]), Vector3.New(0, -20, 0), params))
  print(string.format('%s|P|%d|%s|expect=%.2f|low:%s|%s', MARK, item[1], item[2], item[4], low, table.concat(samples, ';')))
end
print(MARK .. '|done')
