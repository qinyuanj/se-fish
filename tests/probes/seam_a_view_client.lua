-- #162 接缝 A 取证（客户端）：固定镜头并隐藏 UI，取证完按原状态还原。
-- 默认跟随镜头下，主界面按钮会挡住鱼身；连帧比较还要求镜头不动。
-- 参数先用一次 exec 写进 _G.SeamAView，再 exec 本文件（-p client）；结果用 log grep SEAMA_VIEW 取回。
--   _G.SeamAView = {
--     action = 'fix',                 -- 'fix'（默认）或 'restore'
--     pos = {x, y, z},                -- 镜头位置
--     yaw = -math.pi / 2,             -- 绕 Y 轴（弧度）；-pi/2 朝 -X 看
--     pitch = 0,                      -- 可选，绕 X 轴（弧度）
--   }
-- 重复 fix 只换机位，原状态只在第一次 fix 时记录；restore 后清空记录。
local StarterGui = game:GetService('StarterGui')
local cams = game:GetService('CameraService')
local cam = cams.LiveCamera or cams.MainCamera
local root = require('client.GameUI'):GetUIRoot()
local args = _G.SeamAView or {}
local function log(...) print('SEAMA_VIEW', ...) end
if not cam then log('ABORT 没有相机') return end

-- 只记录逐项类型；All 是批量开关，没有独立状态
local CORE_TYPES = {}
for name, value in pairs(Enums.CoreGuiType) do
    if name ~= 'All' then CORE_TYPES[#CORE_TYPES + 1] = value end
end

if args.action == 'restore' then
    local saved = _G.SeamAViewSaved
    if not saved then log('restore', 'nothing-saved') return end
    cam.Mode = saved.mode
    for node, visible in pairs(saved.nodes) do node.Visible = visible end
    for coreType, enabled in pairs(saved.core) do StarterGui:SetCoreGuiEnabled(coreType, enabled) end
    _G.SeamAViewSaved = nil
    log('restore', 'mode=' .. tostring(cam.Mode))
    return
end

if not (args.pos and args.yaw) then log('ABORT 缺 pos 或 yaw') return end
if not _G.SeamAViewSaved then
    local saved = { mode = cam.Mode, nodes = {}, core = {} }
    for _, node in ipairs(root and root:GetChildren() or {}) do saved.nodes[node] = node.Visible end
    for _, coreType in ipairs(CORE_TYPES) do saved.core[coreType] = StarterGui:GetCoreGuiEnabled(coreType) end
    _G.SeamAViewSaved = saved
end
for node in pairs(_G.SeamAViewSaved.nodes) do node.Visible = false end
StarterGui:SetCoreGuiEnabled(Enums.CoreGuiType.All, false)
cam.Mode = Enums.CameraMode.SCRIPTABLE
cam.Position = Vector3.New(args.pos[1], args.pos[2], args.pos[3])
cam.Rotation = Quaternion.FromEulerAngles(args.pitch or 0, args.yaw, 0)
log('fix', 'pos=' .. tostring(cam.Position), 'fov=' .. tostring(cam.FieldOfView))
