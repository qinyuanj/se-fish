-- 离线测试用假场景：与生产 ZoneMarkers 同一解析路径，坐标只服务行为夹具，不是场景事实。
-- 节点与坐标由严格引擎替身 engine_double 提供，越出真引擎能力的访问直接报错。
local M = {}
local ZoneMarkers = require('common.ZoneMarkers')
local Engine = require('tests.support.engine_double')

local centers = {
  {x=0,z=0}, {x=240,z=0}, {x=480,z=0}, {x=720,z=0},
  {x=720,z=320}, {x=480,z=320}, {x=240,z=320},
}
local sceneCenters = {
  {x=0,z=0}, {x=100,z=100}, {x=260,z=100}, {x=460,z=100},
  {x=660,z=100}, {x=880,z=100}, {x=1160,z=100},
}
local zoneCombat = { {24,20}, {24,20}, {32,28}, {40,36}, {40,36}, {48,40}, {48,40} }
local foldedPoints = {
  Z1_Safe={x=6.26,y=5.01,z=-0.71}, FerryBoat={x=-8,y=1.5,z=-15},
  TGUnitFish={x=-6.25,y=-1,z=-9.25}, TGUnitShop={x=-8.75,y=2.5,z=15.25},
  Z1_Lottery={x=5,y=5,z=-5}, Z1_Bait1={x=5,y=6,z=-9},
  TGUnitFishShrimp={x=213,y=6,z=-17}, TGUnitShopShrimp={x=216,y=6,z=13},
  Z3_Grill={x=502,y=6,z=11}, FerryReturn={x=265,y=6,z=40.5},
}

function M.World()
  local zones = {}
  local world = Engine.World(zones)
  local zoneNames = {'01 鱼塘','02 虾池','03 蟹湖','04 树林岛','05 沙滩岛','06 礁石岛','07 火山岛'}
  for index, center in ipairs(centers) do
    local walls, points, facilities, waters = Engine.Unit({ Name = '空气墙' }), Engine.Unit({ Name = '摆渡' }),
      Engine.Unit({ Name = '设施' }), Engine.Unit({ Name = '水域' })
    local zone = Engine.Unit({ Name = zoneNames[index], Children = { walls, points, facilities, waters } })
    local function unit(parent, name, x, y, z, sx, sy, sz)
      local value = Engine.Unit({ Name = name, Position = {x=x,y=y,z=z}, Size = {x=sx or 1,y=sy or 1,z=sz or 1} })
      local children = Engine.Children(parent)
      children[#children + 1] = value
      return value
    end
    local sceneCenter = sceneCenters[index]
    local halfX = index == 1 and 69 or 60
    local minX, maxX = center.x - halfX, center.x + halfX
    local minZ = center.z - (index == 1 and 59 or index <= 4 and 70 or 50)
    local maxZ = center.z + (index == 1 and 79 or index <= 4 and 50 or 70)
    unit(walls,'Z'..index..'_BoundaryWest',minX,-30,center.z,3,70,120)
    unit(walls,'Z'..index..'_BoundaryEast',maxX,-30,center.z,3,70,120)
    unit(walls,'Z'..index..'_BoundarySouth',center.x,-30,minZ,120,70,3)
    unit(walls,'Z'..index..'_BoundaryNorth',center.x,-30,maxZ,120,70,3)
    local innerWallZ = sceneCenter.z - (index == 1 and 59 or 50) + 1.5
    local safe = {x=sceneCenter.x,y=6,z=innerWallZ+18}
    unit(points,'Z'..index..'_Safe',safe.x,safe.y,safe.z)
    unit(points,index == 1 and 'FerryBoat' or 'Z'..index..'_FerryOut',sceneCenter.x+25,6,sceneCenter.z-40.5)
    if index > 1 then
      unit(points,'Z'..index..'_FerryReturn',sceneCenter.x-25,6,sceneCenter.z-40.5)
    end
    local fisherman = index == 1 and 'TGUnitFish' or index == 2 and 'TGUnitFishShrimp' or 'Z'..index..'_Fisherman'
    local shop = index == 1 and 'TGUnitShop' or index == 2 and 'TGUnitShopShrimp' or 'Z'..index..'_Shop'
    local combat = zoneCombat[index]
    local shoreZ = sceneCenter.z + 32
    local baitSide = index >= 2 and index <= 4 and 1 or -1
    unit(facilities,fisherman,sceneCenter.x+combat[1]/2+15,6,shoreZ-15)
    unit(facilities,shop,sceneCenter.x+combat[1]/2+12,6,shoreZ-(combat[2]+25))
    unit(facilities,'Z'..index..'_Lottery',sceneCenter.x-combat[1]/2-6,6,shoreZ-14)
    if index >= 3 then unit(facilities,'Z'..index..'_Grill',sceneCenter.x-combat[1]/2-6,6,shoreZ-(combat[2]+15)) end
    if index == 1 then
      for bait = 1, 5 do unit(facilities,'Z1_Bait'..bait,5,6,-9) end
    end
    for bait = 1, index == 1 and 5 or 2 do
      if index > 1 then
        unit(facilities,'Z'..index..'_Bait'..bait,sceneCenter.x+baitSide*52*(bait == 1 and 1 or -1),6,shoreZ-8)
      end
    end
    local waterZ = center.z + (index >= 2 and index <= 4 and -44 or 44)
    local waterX = center.x
    local water = unit(waters,index <= 2 and 'Z'..index..'_Water1' or 'Z'..index..'_Water',waterX,2,waterZ,80,1,24)
    for _, value in ipairs(Engine.Children(points)) do
      value.Position.x = center.x + (index >= 2 and index <= 4 and -1 or 1) * (value.Position.x - sceneCenter.x)
      value.Position.z = center.z + (index >= 2 and index <= 4 and -1 or 1) * (value.Position.z - sceneCenter.z)
      if index == 2 and value.Name == 'Z2_FerryReturn' then value.Name = 'FerryReturn' end
    end
    for _, value in ipairs(Engine.Children(facilities)) do
      value.Position.x = center.x + (index >= 2 and index <= 4 and -1 or 1) * (value.Position.x - sceneCenter.x)
      value.Position.z = center.z + (index >= 2 and index <= 4 and -1 or 1) * (value.Position.z - sceneCenter.z)
    end
    for name, position in pairs(foldedPoints) do
      for _, parent in ipairs({points, facilities}) do
        for _, value in ipairs(Engine.Children(parent)) do
          if value.Name == name then value.Position = position end
        end
      end
    end
    if index == 1 then
      unit(waters,'Z1_Water2',11.5,1.05,-26.5,7,1,7)
      water.Position = {x=-11.75,y=1.183,z=-12.25}
      Engine.SetSize(water, {x=12,y=1,z=12})
    end
    zones[index] = zone
  end
  return world
end

function M.Apply(cfg)
  ZoneMarkers.Resolve(M.World(), cfg)
  return cfg
end

function M.Load()
  package.loaded['common.GameCfg'] = nil
  return M.Apply(require('common.GameCfg'))
end

return M
