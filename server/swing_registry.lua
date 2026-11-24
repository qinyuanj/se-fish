local M = {}

local SWING_TTL_SEC = 1.5
local SWING_FUTURE_SKEW_SEC = 0.5
local swings = {}
local clock_now = nil
function M.SetClock(now)
    clock_now = type(now) == 'function' and now or nil
end
local function swingClock()
    if clock_now then
        local ok, now = pcall(clock_now)
        if ok and type(now) == 'number' and now == now and math.abs(now) < math.huge then return now end
    end
    local ok, now = pcall(function() return game:GetService('World'):GetServerTime() end)
    if ok and type(now) == 'number' and now == now and math.abs(now) < math.huge then return now end
    print('[SwingRegistry] 读取服务端时钟失败', tostring(now))
end
local function swingAlive(entry)
    if not entry then return nil end
    local now = swingClock()
    if now == nil or entry.at == nil then return nil end
    if entry.at > now + SWING_FUTURE_SKEW_SEC then return nil end
    if now - entry.at > SWING_TTL_SEC then return nil end
    return entry
end
function M.StageSwing(userId, swing)
    local validId = type(userId) == 'number' and userId == userId and math.abs(userId) < math.huge
        or type(userId) == 'string' and userId ~= ''
    if not validId or type(swing) ~= 'table' then return false end
    local now = swingClock()
    if now == nil then
        swings[userId] = nil
        return false
    end
    swings[userId] = { damage = swing.damage, range = swing.range, effect = swing.effect, at = now }
    return true
end
function M.PeekSwing(userId)
    local entry = swingAlive(swings[userId])
    if not entry then swings[userId] = nil end
    return entry
end
function M.ClearSwing(userId)
    swings[userId] = nil
end
function M.TakeSwing(userId)
    local entry = swingAlive(swings[userId])
    swings[userId] = nil
    return entry
end


return M
