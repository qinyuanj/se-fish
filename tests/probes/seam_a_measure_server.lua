-- #162 接缝 A 取证（服务端）：摆 1 单位参照方块，量探针单位的碰撞 AABB，或清理方块。
-- BasePart.Size 对自定义蒙皮网格和方块都返回 (1,1,1)，不能当尺寸；尺寸看同框方块，碰撞看本探针扫描。
-- 参数先用一次 exec 写进 _G.SeamAMeasure，再 exec 本文件（-p server）；结果用 log grep SEAMA_MEASURE 取回。
--   _G.SeamAMeasure = {
--     action = 'aabb',                -- 'cube' | 'aabb'（默认）| 'cleanup'
--     at = {x, y, z},                 -- cube：方块底面中心（方块原点在底面）
--     range = 10,                     -- aabb：单方向最大扫描距离
--   }
-- aabb 用 0.01 小盒沿三轴逐 0.02 探测 SeamAAnimProbe 的碰撞 AABB；GetPartBoundsInBox 判的是 AABB，
-- 任一过 AABB 内点的轴线都能扫出该轴完整范围。播放中重扫可判断碰撞体是否随动画变化。
local CUBE, PROBE, CUBE_MESH = 'SeamACube', 'SeamAAnimProbe', 'official://mesh/59268'
local STEP = 0.02
local world, physics = game:GetService('World'), game:GetService('PhysicsService')
local args = _G.SeamAMeasure or {}
local function log(...) print('SEAMA_MEASURE', ...) end

local function find(name)
    local found = {}
    for _, u in ipairs(world:GetDescendants()) do
        if u.Name == name then found[#found + 1] = u end
    end
    return found
end

local function removeCubes()
    local cubes = find(CUBE)
    for _, u in ipairs(cubes) do u:Destroy() end
    return #cubes
end

if args.action == 'cleanup' then
    local removed = removeCubes()
    log('cleanup', 'removed=' .. removed, 'left=' .. #find(CUBE))
    return
end

if args.action == 'cube' then
    if not args.at then log('ABORT 缺 at') return end
    removeCubes()
    local cube = world:CreateUnit('WorldUnit', {
        Name = CUBE, RenderMeshId = CUBE_MESH, Position = Vector3.New(args.at[1], args.at[2], args.at[3]),
    })
    cube.GravityEnabled = false
    cube.CanCollide = false
    log('cube', 'pos=' .. tostring(cube.Position))
    return
end

local probe = find(PROBE)[1]
if not probe then log('ABORT 没有 ' .. PROBE) return end
local o, box = probe.Position, Vector3.New(0.01, 0.01, 0.01)
local function inside(p)
    for _, u in ipairs(physics:GetPartBoundsInBox(CFrame.New(Vector3.New(p[1], p[2], p[3])), box) or {}) do
        if u == probe then return true end
    end
    return false
end

-- 原点不一定在网格内（如原点偏离底面中心），沿原点竖线上下交替找第一个内点
local range = args.range or 10
local seed
for i = 0, math.floor(range / STEP) do
    for _, dy in ipairs({ i * STEP, -i * STEP }) do
        if not seed and inside({ o.x, o.y + dy, o.z }) then seed = { o.x, o.y + dy, o.z } end
    end
    if seed then break end
end
if not seed then log('ABORT 原点竖线上没有碰撞体') return end

local function edge(axis, dir)
    local p = { seed[1], seed[2], seed[3] }
    local last = p[axis]
    for _ = 1, math.floor(range / STEP) do
        p[axis] = last + dir * STEP
        if not inside(p) then break end
        last = p[axis]
    end
    return last
end

local x0, x1, y0, y1, z0, z1 = edge(1, -1), edge(1, 1), edge(2, -1), edge(2, 1), edge(3, -1), edge(3, 1)
log('aabb', string.format('origin=%.3f,%.3f,%.3f', o.x, o.y, o.z),
    string.format('x=[%.3f,%.3f] y=[%.3f,%.3f] z=[%.3f,%.3f]', x0, x1, y0, y1, z0, z1),
    string.format('size=%.2f,%.2f,%.2f', x1 - x0, y1 - y0, z1 - z0),
    'gravity=' .. tostring(probe.GravityEnabled), 'collide=' .. tostring(probe.CanCollide),
    'physMesh=' .. tostring(probe.PhysicsMeshId == probe.RenderMeshId and 'render' or probe.PhysicsMeshId))
