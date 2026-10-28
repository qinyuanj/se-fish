-- #160 接缝 A 取证第 2 步（服务端）：在镜头前建 AnimatedUnit 播放模型动画片段，或清理探针单位。
-- 流程与判定口径见 docs/art-asset-overview.md「模型动画导入与播放」。
-- 参数先用一次 exec 写进 _G.SeamA，再 exec 本文件（-p server）；结果用 log grep SEAMA_ANIM 取回。
--   _G.SeamA = {
--     action = 'play',                         -- 'play'（默认）或 'cleanup'
--     mesh = 'custom://0h1DIiDiCuEpQD9Kj',     -- 网格资源 URI
--     clip = 'fish_alligator_gar_Walk',        -- 导入对话框里的完整片段名
--     skin = nil,                              -- 可选皮肤 URI
--     cam = {x, y, z}, focus = {x, y, z},      -- 取自 seam_a_camera_client.lua 的输出
--     dist = 4.5,                              -- 焦点前方的水平距离
--   }
-- 探针单位只保留一个：重跑 play 换网格或片段时先删旧单位再按当前镜头重建。
-- GetAnimationState 对任意片段名都可能返回 isPlaying=true，这里打印它只作留痕，在播与否看截图。
local NAME = 'SeamAAnimProbe'
local world = game:GetService('World')
local args = _G.SeamA or {}
local function log(...) print('SEAMA_ANIM', ...) end

local function findProbes()
    local found = {}
    for _, u in ipairs(world:GetDescendants()) do
        if u.Name == NAME then found[#found + 1] = u end
    end
    return found
end

local function cleanup()
    local probes = findProbes()
    for _, u in ipairs(probes) do u:Destroy() end
    return #probes
end

if args.action == 'cleanup' then
    local removed = cleanup()
    log('cleanup', 'removed=' .. removed, 'left=' .. #findProbes())
    return
end

if not (args.mesh and args.clip) then log('ABORT 缺 mesh 或 clip') return end
if not (args.cam and args.focus) then log('ABORT 缺 cam 或 focus') return end

-- 先删旧探针，否则下面的射线会打在旧探针身上
cleanup()

-- 镜头到焦点的水平方向向前推 dist；地面高度用向下射线求，未命中时退回焦点高度
local c, f = args.cam, args.focus
local dx, dz = f[1] - c[1], f[3] - c[3]
local len = math.sqrt(dx * dx + dz * dz)
if len < 1e-3 then log('ABORT 镜头竖直朝下，定不了水平方向') return end
local dist = args.dist or 4.5
local x, z = f[1] + dx / len * dist, f[3] + dz / len * dist
local y, ground = f[2], 'focus'
local physics = game:GetService('PhysicsService')
local ok, hit = pcall(physics.Raycast, physics, Vector3.New(x, f[2] + 10, z), Vector3.New(0, -40, 0), nil)
if ok and hit then y, ground = hit.Position.y, 'ray' end

local pos = Vector3.New(x, y, z)
local unit = world:CreateUnit('AnimatedUnit', { Name = NAME, RenderMeshId = args.mesh, Position = pos })
if args.skin then unit.SkinId = args.skin end
-- 刚建的单位立即 PlayAnimation，客户端画面不动（#160 实测）；等单位同步到客户端后再播
local task = game:GetService('Task')
task:Spawn(function()
    task:Wait(args.delay or 0.5)
    unit:PlayAnimation(args.clip, { startTime = 0, looped = true, speed = 1 })
    local s = unit:GetAnimationState()
    log('play', 'pos=' .. tostring(pos), 'ground=' .. ground, 'mesh=' .. args.mesh, 'clip=' .. args.clip,
        'stateIsPlaying=' .. tostring(s and s.isPlaying))
end)
