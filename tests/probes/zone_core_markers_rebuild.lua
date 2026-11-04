-- #164 回退重做第 1 批：七区空气墙、安全落点与摆渡标记（编辑器侧，edit mode）。
-- 默认 dry-run；仅在脚本内把 APPLY 改为 true 后写入。不保存地图。
local APPLY = false
local MARK = 'ZCM164'
local world = editor:GetService('World')

local boxes = {
  {'01 鱼塘',1,-810,-530,-170,185}, {'02 虾池',2,-530,-275,-170,185},
  {'03 蟹湖',3,-275,30,-170,185}, {'04 树林岛',4,-155,30,185,430},
  {'05 沙滩岛',5,-385,-155,185,430}, {'06 礁石岛',6,-575,-385,185,430},
  {'07 火山岛',7,-810,-575,185,430},
}
local points = {
  {'01 鱼塘','标记','Z1_Safe',-620,0.973,40},
  {'01 鱼塘','摆渡','FerryBoat',-560,1.168,-10},
  {'02 虾池','摆渡','FerryReturn',-365,1.000,30},
  {'02 虾池','摆渡','Z2_FerryOut',-335,1.168,-10},
  {'03 蟹湖','摆渡','Z3_Safe',-161.5,1.010,80},
  {'03 蟹湖','摆渡','Z3_FerryOut',-28.989,4.883,129.591},
  {'03 蟹湖','摆渡','Z3_FerryReturn',-340,1.168,-10},
  {'04 树林岛','摆渡','Z4_Safe',-90,5.175,320},
  {'04 树林岛','摆渡','Z4_FerryOut',-139.657,4.213,334.814},
  {'04 树林岛','摆渡','Z4_FerryReturn',-90,5.347,340},
  {'05 沙滩岛','摆渡','Z5_Safe',-290,4.931,360},
  {'05 沙滩岛','摆渡','Z5_FerryOut',-222.35,4.213,334.814},
  {'05 沙滩岛','摆渡','Z5_FerryReturn',-250,4.876,335},
  {'06 礁石岛','摆渡','Z6_Safe',-470,6.000,320},
  {'06 礁石岛','摆渡','Z6_FerryOut',-460,6.000,320},
  {'06 礁石岛','摆渡','Z6_FerryReturn',-480,6.000,320},
  {'07 火山岛','摆渡','Z7_Safe',-610,0.531,340},
  {'07 火山岛','摆渡','Z7_FerryReturn',-600,0.516,340},
}

local function child(zoneName, folderName, name)
  local zone = world:FindFirstChild(zoneName)
  local folder = zone and zone:FindFirstChild(folderName)
  return folder and folder:FindFirstChild(name)
end
local function vec(x,y,z) return Vector3.New(x,y,z) end
local function component(v,index,lower,upper) return v[lower] or v[upper] or v[index] end
local function text(v) return string.format('%.3f,%.3f,%.3f',component(v,1,'x','X'),component(v,2,'y','Y'),component(v,3,'z','Z')) end
local function ensureFolder(zoneName, folderName)
  local zone = assert(world:FindFirstChild(zoneName), zoneName)
  local folder = zone:FindFirstChild(folderName)
  if not folder and APPLY then
    folder = world:CreateUnit('Folder', {})
    folder.Name = folderName
    folder:SetParent(zone)
  end
  return folder
end

local template = child('02 虾池','空气墙','Z2_BoundaryEast')
assert(template, MARK .. ': 空气墙模板缺失')
local pointTemplate = child('03 蟹湖','摆渡','Z3_Safe')
assert(pointTemplate, MARK .. ': 标记模板缺失')
local missing = 0
local function report(kind, name, unit, target)
  if not unit then missing = missing + 1 end
  print(MARK .. '|' .. kind .. '|' .. name .. '|before=' .. (unit and text(unit.Position) or 'MISSING')
    .. '|after=' .. text(target))
end

if APPLY then
  local folder = ensureFolder('01 鱼塘','空气墙')
  for _, side in ipairs({'West','East','South','North'}) do
    local name = 'Z1_Boundary' .. side
    if not folder:FindFirstChild(name) then
      local wall = template:Clone()
      wall.Name = name
      wall:SetParent(folder)
    end
  end
  ensureFolder('01 鱼塘','标记')
  for _, item in ipairs(points) do
    if not child(item[1],item[2],item[3]) then
      local marker = pointTemplate:Clone()
      marker.Name = item[3]
      marker:SetParent(assert(ensureFolder(item[1],item[2])))
    end
  end
end

for _, box in ipairs(boxes) do
  local minX,maxX,minZ,maxZ = box[3],box[4],box[5],box[6]
  local cx,cz = (minX+maxX)/2,(minZ+maxZ)/2
  local specs = {
    {'West',minX,cz,3,maxZ-minZ+3}, {'East',maxX,cz,3,maxZ-minZ+3},
    {'South',cx,minZ,maxX-minX+3,3}, {'North',cx,maxZ,maxX-minX+3,3},
  }
  for _, spec in ipairs(specs) do
    local name = 'Z' .. box[2] .. '_Boundary' .. spec[1]
    local wall = child(box[1],'空气墙',name)
    report('WALL',name,wall,vec(spec[2],-30,spec[3]))
    if wall and APPLY then
      wall:SetPosition(vec(spec[2],-30,spec[3]))
      wall:SetProperty('Size',vec(spec[4],70,spec[5]))
      wall:SetProperty('CanCollide',true)
    end
  end
end
for _, item in ipairs(points) do
  local marker = child(item[1],item[2],item[3])
  local target = vec(item[4],item[5],item[6])
  report('POINT',item[3],marker,target)
  if marker and APPLY then
    marker:SetPosition(target)
    marker:SetProperty('CanCollide',false)
    marker:SetProperty('CanQuery',false)
    marker:SetVisible(false)
  end
end
print(MARK .. '|END|missing=' .. missing .. '|apply=' .. tostring(APPLY))
