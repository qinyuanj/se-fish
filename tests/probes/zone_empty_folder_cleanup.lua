-- #164 回退重做：空目录清理（编辑器侧，edit mode）。
-- 只删七区子树中无子项且名称未被玩法读取的 Folder；默认 dry-run，不保存地图。
local APPLY = false
local MARK = 'ZEF164'
local world = editor:GetService('World')
local zones = {'01 鱼塘','02 虾池','03 蟹湖','04 树林岛','05 沙滩岛','06 礁石岛','07 火山岛'}
local referenced = {
  ['摆渡'] = true, ['设施'] = true, ['空气墙'] = true, ['水域'] = true,
  ['地块'] = true, ['装饰'] = true, ['标记'] = true,
}
local empty = {}
local function visit(unit, path)
  for _, child in ipairs(unit:GetChildren()) do
    if child.ClassName == 'Folder' or child:GetProperty('ClassName') == 'Folder' then
      visit(child, path .. '/' .. tostring(child.Name))
    end
  end
  if #unit:GetChildren() == 0 and not referenced[tostring(unit.Name)] then
    empty[#empty + 1] = {unit=unit,path=path}
  end
end
for _,zoneName in ipairs(zones) do
  local zone = world:FindFirstChild(zoneName)
  if zone then
    for _,child in ipairs(zone:GetChildren()) do
      if child.ClassName == 'Folder' or child:GetProperty('ClassName') == 'Folder' then
        visit(child,zoneName .. '/' .. tostring(child.Name))
      end
    end
  end
end
for _,item in ipairs(empty) do
  print(MARK .. '|EMPTY|' .. item.path)
  if APPLY then item.unit:Destroy() end
end
print(MARK .. '|END|count=' .. #empty .. '|apply=' .. tostring(APPLY))
