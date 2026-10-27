-- 服务端挥砍登记：一次性消费并带 TTL，调用方共享本模块状态。
local M = {}

-- #129 挥砍登记：MgrWeapon 发起近战前登记本次挥砍（伤害/射程按 GameCfg 表，空手 5、近战按表），
-- melee_hit 行为在 AnchorStart 时经 TakeSwing 取用登记值推导命中盒与伤害；未经登记的玩家挥砍
-- 不结算伤害（不再回落到预设属性 25），伪造 RequestCast 因此被结构性堵住。登记一次性消费、带 TTL。
local SWING_TTL_SEC = 1.5
local SWING_FUTURE_SKEW_SEC = 0.5
local swings = {}
local function swingClock()
    local ok, now = pcall(function() return game:GetService('World'):GetServerTime() end)
    if ok and type(now) == 'number' and now == now and math.abs(now) < math.huge then return now end
    print('[SwingRegistry] 读取服务端时钟失败', tostring(now))
end
local function swingAlive(entry)
    if not entry then return nil end
    local now = swingClock()
    if now == nil or entry.at == nil then return nil end
    if entry.at > now + SWING_FUTURE_SKEW_SEC then return nil end -- 登记在未来（时钟回拨）视为过期
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
