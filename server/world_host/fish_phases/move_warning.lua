-- 战斗相位的招式预警载荷构造（L2 server.world_host.fish_phases 辅助模块，不是相位）：
-- 从 combat.lua 原样搬出的纯构造逻辑，只读 BossMoves / GameCfg / GarBiteNotice，不持有相位状态、不注册行为。
local GameCfg = require('common.game_cfg')
local GarBiteNotice = require('common.gar_bite_notice')
local BossMoves = require('common.cfg.boss_moves')

local MoveWarning = {}

--- 招式预警的范围与蓄力：招式表优先，缺项回落到调用方给的范围与时长。
---@param warning table? 招式表行
---@param range number? 调用方给的范围
---@param duration number 蓄力时长
---@return number?, number 预警范围、预警时长
local function move_warning_reach(warning, range, duration)
    local warningRange = warning and math.max(range or 0, warning.Range or 0) or range
    local warningSec = warning and warning.WindupSec and warning.WindupSec > 0 and warning.WindupSec or duration
    return warningRange, warningSec
end

--- 招式预警的形状：先按招式表，再按调用方给的形状。
---@param payload table 预警载荷
---@param warning table? 招式表行
---@param shape string? 调用方给的形状
---@param name string 招式名
local function move_warning_shape(payload, warning, shape, name)
    local shapeName = (warning and warning.Kind ~= 'none' and warning.Shape) or shape
    if shapeName == 'circle' or name == 'jump' then
        payload.shape, payload.halfAngleDeg = 'circle', 180
    elseif shapeName == 'line' then
        payload.shape = 'line'
        if warning and warning.Width then payload.width = warning.Width end
    elseif shapeName == 'cone' then
        payload.shape = 'cone'
    end
end

--- 招式表的落地投递信息：招式表声明投递时才补齐。
---@param payload table 预警载荷
---@param fish table 目标鱼
---@param name string 招式名
local function move_warning_delivery(payload, fish, name)
    local row = BossMoves.get(BossMoves.key_of(GameCfg.Fish[fish.fish_id], fish.fish_id), name)
    if row and row.Delivery and row.Warning.Kind ~= 'none' then
        payload.shape = row.Warning.Kind or payload.shape
        payload.notice, payload.delivery, payload.landing = row.Warning.Notice, row.Delivery, row.Landing
        payload.width = row.Warning.Width
        payload.landingPoint = fish.Move.destination or fish.Move.Center
    end
end

--- 招式预警载荷：位置、范围、形状与投递信息一次补齐。
---@param fish table 目标鱼
---@param name string 招式名
---@param pos table 起手位置
---@param destination table? 落点
---@param duration number 蓄力时长
---@param range number? 调用方给的范围
---@param shape string? 调用方给的形状
---@return table
function MoveWarning.payload(fish, name, pos, destination, duration, range, shape)
    local facing = fish.facing or { x = 0, z = 1 }
    local warningPos = (name == 'dive' or name == 'jump') and destination or pos
    warningPos = warningPos or pos
    local species = GameCfg.Fish[fish.fish_id]
    local warning = species and BossMoves.warning_of(BossMoves.key_of(species, fish.fish_id), name) or nil
    local warningRange, warningSec = move_warning_reach(warning, range, duration)
    local payload = GarBiteNotice.lock(fish.Id, warningPos, facing.x, facing.z, warningRange, 90, warningSec)
    payload.move = name
    move_warning_shape(payload, warning, shape, name)
    if warning and warning.Notice then payload.notice = warning.Notice end
    move_warning_delivery(payload, fish, name)
    return payload
end

return MoveWarning
