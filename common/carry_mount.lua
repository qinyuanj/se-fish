local GameCfg = require('common.game_cfg')
local Number = require('common.number')

local M = {}

local function cfg()
    return GameCfg.Ability.Carry
end

local function isBadNumber(v)
    return not Number.is_finite_number(v)
end

local function isBadPoint(p)
    return type(p) ~= 'table' or isBadNumber(p.x) or isBadNumber(p.y) or isBadNumber(p.z)
end

local function num(v)
    if isBadNumber(v) then return 0 end
    return v
end

local function copy(p)
    return { x = num(p.x), y = num(p.y), z = num(p.z) }
end

local function pointDistance(a, b)
    local dx, dy, dz = a.x - b.x, a.y - b.y, a.z - b.z
    return math.sqrt(dx * dx + dy * dy + dz * dz)
end

function M.length(offset)
    if type(offset) ~= 'table' then return 0 end
    return math.sqrt(num(offset.x) ^ 2 + num(offset.y) ^ 2 + num(offset.z) ^ 2)
end

---@param offset table { x, y, z }
---@param hostHalf number 宿主半高
---@param carriedHalf number 携带物半高
---@return table { Offset, Corrected }
function M.safe_offset(offset, hostHalf, carriedHalf)
    local safe = { x = num(offset and offset.x), y = num(offset and offset.y), z = num(offset and offset.z) }
    local need = math.max(0, num(hostHalf)) + math.max(0, num(carriedHalf))
    local length = M.length(safe)
    if length >= need and length > 0 then return { Offset = safe, corrected = false } end
    if length <= 1e-9 then return { Offset = { x = 0, y = 0, z = need }, corrected = true } end
    local k = need / length
    return { Offset = { x = safe.x * k, y = safe.y * k, z = safe.z * k }, corrected = true }
end

---@param host table 宿主位置
---@param offset table 挂点位移（1 倍体型下的基准值 × 体型倍率）
---@param yaw number 宿主朝向（弧度）
---@return table { x, y, z }
function M.mount_point(host, offset, yaw)
    host = host or { x = 0, y = 0, z = 0 }
    offset = offset or { x = 0, y = 0, z = 0 }
    yaw = num(yaw)
    local cos, sin = math.cos(yaw), math.sin(yaw)
    local ox, oz = num(offset.x), num(offset.z)
    return {
        x = num(host.x) + ox * cos + oz * sin,
        y = num(host.y) + num(offset.y),
        z = num(host.z) - ox * sin + oz * cos,
    }
end

function M.drop_point(host, yaw, groundY, carryCfg)
    carryCfg = carryCfg or cfg()
    host = host or { x = 0, y = 0, z = 0 }
    yaw = num(yaw)
    return {
        x = num(host.x) + math.sin(yaw) * carryCfg.DropForward,
        y = num(groundY) + carryCfg.DropHeight,
        z = num(host.z) + math.cos(yaw) * carryCfg.DropForward,
    }
end

---@param carryCfg? table
---@param host? table
---@param yaw? number
---@param now? number
function M.new(carryCfg, host, yaw, now)
    carryCfg = carryCfg or cfg()
    host = host and copy(host) or { x = 0, y = 0, z = 0 }
    local safe = M.safe_offset(carryCfg.Offset, carryCfg.HostHalfHeight, carryCfg.CarriedHalfHeight)
    return {
        Cfg = carryCfg, Host = host, Yaw = num(yaw), GroundY = host.y,
        Offset = safe.Offset, corrected = safe.corrected,
        carried = false, Target = nil, Mount = nil,
        started_at = num(now), released_at = nil,
        Stats = { frames = 0, attaches = 0, snaps = 0, releases = 0 },
    }
end

function M.carried(state)
    return state.carried == true
end

function M.in_range(state, target)
    if isBadPoint(target) then return false end
    local dx, dz = target.x - state.Host.x, target.z - state.Host.z
    return math.sqrt(dx * dx + dz * dz) <= state.Cfg.GrabRange
end

---@return table { Ok, Reason?, Damage? }
function M.attach(state, target, now)
    if type(state.Cfg.Socket) ~= 'string' or state.Cfg.Socket == '' then
        return { Ok = false, Reason = 'noSocket' }
    end
    if isBadPoint(target) then return { Ok = false, Reason = 'noTarget' } end
    if not M.in_range(state, target) then return { Ok = false, Reason = 'outOfRange' } end
    state.carried = true
    state.Target = copy(target)
    state.started_at = num(now)
    state.released_at = nil
    state.Mount = M.mount_point(state.Host, state.Offset, state.Yaw)
    state.Stats.attaches = state.Stats.attaches + 1
    return { Ok = true, Damage = state.Cfg.GrabDamage, Position = state.Mount }
end

function M.release(state, now, reason)
    if not state.carried then return { Ok = false, Reason = 'notCarrying' } end
    state.carried = false
    state.released_at = num(now)
    state.Stats.releases = state.Stats.releases + 1
    local drop = M.drop_point(state.Host, state.Yaw, state.GroundY, state.Cfg)
    state.Target = nil
    return { Ok = true, Reason = reason or 'manual', drop_point = drop, Position = drop }
end

---@return table { Position?, Snapped?, Released?, Reason? }
function M.follow(state, targetPos, now, dt)
    if not state.carried then return { Position = nil } end
    local desired = M.mount_point(state.Host, state.Offset, state.Yaw)
    state.Mount = desired
    if isBadPoint(targetPos) then
        local released = M.release(state, now, 'nan')
        return { Position = released.drop_point, released = true, Reason = 'nan' }
    end
    if pointDistance(targetPos, desired) > state.Cfg.FollowTolerance then
        state.Stats.snaps = state.Stats.snaps + 1
        return { Position = desired, snapped = true }
    end
    return { Position = targetPos, snapped = false }
end

---@return table { Released, Reason?, drop_point?, Position? }
function M.step(state, now, dt)
    state.Stats.frames = state.Stats.frames + 1
    if not state.carried then return { released = false, Position = nil } end
    if num(now) - state.started_at >= state.Cfg.MaxCarrySec then
        local released = M.release(state, now, 'timeout')
        return { released = true, Reason = 'timeout', drop_point = released.drop_point, Position = released.drop_point }
    end
    return { released = false, Position = state.Mount or M.mount_point(state.Host, state.Offset, state.Yaw) }
end

return M
