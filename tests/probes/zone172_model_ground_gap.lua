-- #172 七区钓鱼佬、抽奖机占位模型的贴地复测（试玩服务端，只读）。
-- 复跑：试玩中 editor-cli exec --file tests/probes/zone172_model_ground_gap.lua --platform server
--       editor-cli log grep GGP172 --platform server --context 0 --max-matches 100
-- 每个模型在中心与十字 ±0.4 米各取样：底面 = 自地下 y-30 向上、只含该模型（Include）的射线首命中；
-- 地面 = 自底面 +1 米向下 20 米、排除该模型与玩家角色的射线首命中。gap = 最低底面 − 最高地面，判据 |gap| ≤ 0.1。
local MARK = 'GGP172'
local CROSS = { { 0, 0 }, { 0.4, 0 }, { -0.4, 0 }, { 0, 0.4 }, { 0, -0.4 } }
local physics = game:GetService('PhysicsService')
local world = game:GetService('World')
local players = game:GetService('Players')
local names = { 'FishermanModel' }
for index = 2, 7 do names[#names + 1] = 'Z' .. index .. '_FishermanModel' end
for index = 1, 7 do names[#names + 1] = 'Z' .. index .. '_LotteryModel' end

local function params(filterType, list)
  local p = RaycastParams.New()
  p.FilterType = filterType
  p.FilterDescendantsInstances = list
  return p
end
local characters = {}
for _, player in ipairs(players:GetPlayers()) do
  if player.Character then characters[#characters + 1] = player.Character end
end

local failed = 0
-- 试玩服务端的 World:FindFirstChild 不递归（2026-11-04 实测连 FishermanModel 都取不到），按绕过合同用 GetDescendants
local byName = {}
for _, unit in ipairs(world:GetDescendants()) do
  local name = unit.Name
  if byName[name] then byName[name] = false elseif byName[name] == nil then byName[name] = unit end
end
for _, name in ipairs(names) do
  local unit = byName[name]
  if unit == false then
    failed = failed + 1
    print(MARK .. '|' .. name .. '|DUPLICATE')
  elseif not unit then
    failed = failed + 1
    print(MARK .. '|' .. name .. '|MISSING')
  else
    local pos = unit.Position
    local include = params(Enums.RaycastFilterType.Include, { unit })
    local exclude = { unit }
    for _, character in ipairs(characters) do exclude[#exclude + 1] = character end
    local excludeParams = params(Enums.RaycastFilterType.Exclude, exclude)
    local bottom, ground, groundName = nil, nil, '-'
    for _, offset in ipairs(CROSS) do
      local x, z = pos.x + offset[1], pos.z + offset[2]
      local ok, hit = pcall(physics.Raycast, physics, Vector3.New(x, pos.y - 30, z), Vector3.New(0, 60, 0), include)
      if ok and hit then
        local y = hit.Position.y
        if not bottom or y < bottom then bottom = y end
        local okG, down = pcall(physics.Raycast, physics, Vector3.New(x, y + 1, z), Vector3.New(0, -20, 0), excludeParams)
        if okG and down and (not ground or down.Position.y > ground) then
          ground = down.Position.y
          groundName = tostring(down.Instance and down.Instance.Name)
        end
      end
    end
    local gap = bottom and ground and bottom - ground
    local pass = gap and math.abs(gap) <= 0.1
    if not pass then failed = failed + 1 end
    print(string.format('%s|%s|pivotY=%.3f|bottom=%s|ground=%s(%s)|gap=%s|%s', MARK, name, pos.y,
      bottom and string.format('%.3f', bottom) or '-', ground and string.format('%.3f', ground) or '-', groundName,
      gap and string.format('%.3f', gap) or '-', pass and 'PASS' or 'FAIL'))
  end
end
print(MARK .. '|END|models=' .. #names .. '|failed=' .. failed)
