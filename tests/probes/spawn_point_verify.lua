-- 出生点位试玩验收（试玩服务端，只读）。MARK SPAWNCHK1
-- 复跑：试玩中 editor-cli exec --file <本文件> --platform server
--       editor-cli log grep SPAWNCHK1 --platform server --context 0 --max-matches 40 --json
local MARK = 'SPAWNCHK1'
local function emit(line) print(MARK .. '|' .. line) end
local function vec(v)
    if v == nil then return '-' end
    return string.format('%.2f,%.2f,%.2f', v.x, v.y, v.z)
end

local world = game:GetService('World')
local players = game:GetService('Players')
local physics = game:GetService('PhysicsService')

local spawnUnit, safeMarker
for _, unit in ipairs(world:GetDescendants()) do
    if unit.Name == '出生点' then spawnUnit = unit end
    if unit.Name == 'Z1_Safe' then safeMarker = unit end
end
emit('UNIT|出生点=' .. (spawnUnit and vec(spawnUnit.Position) or 'GONE'))
emit('UNIT|Z1_Safe=' .. (safeMarker and vec(safeMarker.Position) or 'GONE'))
if spawnUnit then
    emit('PROP|Capacity=' .. tostring(spawnUnit.Capacity) .. '|RangeBirth=' .. tostring(spawnUnit.RangeBirth))
end

local list = players:GetPlayers()
emit('PLAYERS|' .. #list)
local excluded = {}
for _, unit in ipairs(world:GetDescendants()) do
    if unit.Name:match('^Z%d_Water%d*$') or unit.Name:match('^Z%d_Boundary') then
        excluded[#excluded + 1] = unit
    end
end
for _, player in ipairs(list) do
    local character = player.Character
    emit('PLAYER|' .. tostring(player.Name) .. '|pos=' .. (character and vec(character.Position) or 'NOCHAR'))
    if character then excluded[#excluded + 1] = character end
end

local params = RaycastParams.New()
params.FilterType = Enums.RaycastFilterType.Exclude
params.FilterDescendantsInstances = excluded
for _, point in ipairs({ { -616, 68 }, { -616, 64 } }) do
    local ok, hit = pcall(physics.Raycast, physics,
        Vector3.New(point[1], 60, point[2]), Vector3.New(0, -200, 0), params)
    if not ok then
        emit('RAY|' .. point[1] .. ',' .. point[2] .. '|ERR')
    elseif hit == nil then
        emit('RAY|' .. point[1] .. ',' .. point[2] .. '|miss')
    else
        emit('RAY|' .. point[1] .. ',' .. point[2] .. '|' .. hit.Instance.Name ..
            '/' .. tostring(hit.Instance.Parent and hit.Instance.Parent.Name) .. '@' .. string.format('%.2f', hit.Position.y))
    end
end
emit('END')
