-- #164 回退重做第 3 批：水域标记与旧灰盒清理（编辑器侧，edit mode）。
-- 默认 dry-run；仅在脚本内把 APPLY 改为 true 后写入。不保存地图。
local APPLY = false
local MARK = 'ZWG164'
local world = editor:GetService('World')

-- 01/02 来自 4 米地形网格，03 来自 8 米网格；04–07 用岛缘水域标记承接周边海域。
local waters = {
  {'01 鱼塘','Z1_Water1',-633,-20,92,92,-0.924},
  {'02 虾池','Z2_Water1',-405,-20,84,84,-0.926},
  {'03 蟹湖','Z3_Water',-130.5,-2,136,56,-0.926},
  {'04 树林岛','Z4_Water',-82.686,335.861,98,98,-0.25},
  {'05 沙滩岛','Z5_Water',-281.102,335.768,112,111,-0.25},
  {'06 礁石岛','Z6_Water',-503.5,364,80,24,-0.25},
  {'07 火山岛','Z7_Water',-687.5,335.768,112,111,-0.25},
}
local deletes = {
  {'01 鱼塘','地块'},{'02 虾池','地块'},{'03 蟹湖','地块'},
  {'04 树林岛','地块'},{'05 沙滩岛','地块'},{'07 火山岛','地块'},
}
local function child(zoneName,folderName,name)
  local zone = world:FindFirstChild(zoneName)
  local folder = zone and zone:FindFirstChild(folderName)
  return folder and folder:FindFirstChild(name)
end
local function component(v,index,lower,upper) return v[lower] or v[upper] or v[index] end
local function text(v) return string.format('%.3f,%.3f,%.3f',component(v,1,'x','X'),component(v,2,'y','Y'),component(v,3,'z','Z')) end
local template = assert(child('03 蟹湖','水域','Z3_Water'), MARK .. ': 水域模板缺失')
local missing = 0

for _,item in ipairs(waters) do
  local zoneName,name,cx,cz,width,depth,surfaceY = item[1],item[2],item[3],item[4],item[5],item[6],item[7]
  local unit = child(zoneName,'水域',name)
  if not unit and APPLY then
    local zone = world:FindFirstChild(zoneName)
    local folder = zone:FindFirstChild('水域')
    if not folder then
      folder = world:CreateUnit('Folder', {})
      folder.Name = '水域'
      folder:SetParent(zone)
    end
    unit = template:Clone()
    unit.Name = name
    unit:SetParent(folder)
  end
  print(MARK .. '|WATER|' .. name .. '|before=' .. (unit and text(unit.Position) or 'MISSING')
    .. '|center=' .. cx .. ',' .. cz .. '|size=' .. width .. ',' .. depth .. '|surface=' .. surfaceY)
  if not unit then missing = missing + 1 end
  if unit and APPLY then
    unit:SetScale(Vector3.New(1,1,1))
    unit:SetProperty('Size',Vector3.New(width,1,depth))
    unit:SetPosition(Vector3.New(cx,surfaceY-1,cz))
    unit:SetProperty('CanCollide',false)
    unit:SetProperty('CanQuery',false)
    unit:SetVisible(false)
  end
end
for _,item in ipairs(deletes) do
  local zone = world:FindFirstChild(item[1])
  local folder = zone and zone:FindFirstChild(item[2])
  print(MARK .. '|DELETE|' .. item[1] .. '/' .. item[2] .. '|children=' .. (folder and #folder:GetChildren() or 'MISSING'))
  if folder and APPLY then folder:Destroy() end
end
print(MARK .. '|END|missing=' .. missing .. '|apply=' .. tostring(APPLY))
