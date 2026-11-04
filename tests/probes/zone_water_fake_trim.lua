-- #164 收尾：删掉没有水的假水域（编辑器侧，edit mode）。WSC164 试玩实测每块 5×5 采样：
-- 06 原池 Z6_Water 被假山石与 Z6_PondFloor 盖满（0/25 深水）；它是 06 抽鱼池 reefIsland.water 的第 1 块，不能删，
-- 改为接替南侧海面（原 Z6_Water2 的矩形），再删 Z6_Water2。南边界 Z1_Water4 / Z2_Water5 / Z3_Water5 是岩壁与虚空，直接删。
-- 栈桥下的 Z1_Water27–29、Z3_Water33/34/41 与礁石下的 Z1_Water33 下面是深水，保留。
-- 默认 dry-run；仅在脚本内把 APPLY 改为 true 后写入，写完改回 false。不保存地图。可重复执行。
local APPLY = false
local MARK = 'ZWT164'
local DELETE = { {'01 鱼塘','Z1_Water4'}, {'02 虾池','Z2_Water5'}, {'03 蟹湖','Z3_Water5'}, {'06 礁石岛','Z6_Water2'} }
local POND = { zone = '06 礁石岛', name = 'Z6_Water', cx = -480, cz = 228.75, sx = 188, sz = 85.5, y = -1.25 }
local world = editor:GetService('World')
local function c(v, i, k) return v[k] or v[i] end
local function text(v) return string.format('%.2f,%.2f,%.2f', c(v,1,'x'), c(v,2,'y'), c(v,3,'z')) end
local function water(zone, name) return world:FindFirstChild(zone):FindFirstChild('水域'):FindFirstChild(name) end

local pond = assert(water(POND.zone, POND.name), MARK .. ': Z6_Water 缺失')
local size = pond:GetProperty('Size')
local moved = math.abs(c(pond.Position,1,'x') - POND.cx) < 0.01 and math.abs(c(pond.Position,3,'z') - POND.cz) < 0.01
  and math.abs(c(size,1,'x') - POND.sx) < 0.01 and math.abs(c(size,3,'z') - POND.sz) < 0.01
print(MARK .. '|MOVE|Z6_Water|before=' .. text(pond.Position) .. '|size=' .. text(size) .. '|moved=' .. tostring(moved))

local deleted = 0
for _, item in ipairs(DELETE) do
  local unit = water(item[1], item[2])
  print(MARK .. '|DELETE|' .. item[2] .. '|' .. (unit and text(unit.Position) or 'GONE'))
  if unit and APPLY then unit:Destroy() deleted = deleted + 1 end
end
if APPLY and not moved then
  pond:SetScale(Vector3.New(1, 1, 1))
  pond:SetProperty('Size', Vector3.New(POND.sx, 1, POND.sz))
  pond:SetPosition(Vector3.New(POND.cx, POND.y, POND.cz))
end
print(MARK .. '|END|deleted=' .. deleted .. '|apply=' .. tostring(APPLY))
