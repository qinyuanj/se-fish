local GameCfg = require('common.game_cfg')
local Number = require('common.number')

local M = {}

local function cfg()
    return GameCfg.Ability.SpecialItem
end

local function isBadNumber(v)
    return not Number.is_finite_number(v)
end

---@param itemId? string
---@return string? effect
function M.desired(itemId)
    if type(itemId) ~= 'string' then return nil end
    return cfg().Items[itemId]
end

---@param wingsCfg table GameCfg.Ability.SpecialItem.Wings
---@param state table { Y = number, Airborne = bool }
---@param holding bool 长按中
---@param dt number 距上一帧的秒数
---@param bounds table FlightPath.bounds_of 的结果（GroundY / CeilingY）
---@return number y, bool airborne
function M.step_flight_y(wingsCfg, state, holding, dt, bounds)
    local y = state.Y
    local airborne = state.airborne == true
    if isBadNumber(dt) or dt < 0 then return y, airborne end
    if dt > wingsCfg.MaxStepSec then dt = wingsCfg.MaxStepSec end
    if holding then
        y = y + wingsCfg.ClimbSpeed * dt
        airborne = true
    else
        y = y - wingsCfg.DescendSpeed * dt
    end
    if y > bounds.ceiling_y then y = bounds.ceiling_y end
    if y <= bounds.ground_y then
        y = bounds.ground_y
        airborne = false
    end
    return y, airborne
end

---@param bounds table FlightPath.bounds_of 的结果
---@param x number
---@param z number
---@return number x, number z, bool clamped
function M.clamp_xz(bounds, x, z)
    local clamped = false
    if isBadNumber(x) then x = (bounds.MinX + bounds.MaxX) / 2 clamped = true end
    if isBadNumber(z) then z = (bounds.MinZ + bounds.MaxZ) / 2 clamped = true end
    if x < bounds.MinX then x = bounds.MinX clamped = true end
    if x > bounds.MaxX then x = bounds.MaxX clamped = true end
    if z < bounds.MinZ then z = bounds.MinZ clamped = true end
    if z > bounds.MaxZ then z = bounds.MaxZ clamped = true end
    return x, z, clamped
end

---@param totalDamage number 票面总伤害（1000）
---@param durationSec number 吐息持续秒数（3）
---@param tickSec number 结算间隔（0.25）
---@return number[] plan 每段伤害（正整数，和恰为 totalDamage）
function M.tick_damages(totalDamage, durationSec, tickSec)
    local count = math.floor(durationSec / tickSec + 1e-9)
    if count < 1 then count = 1 end
    local base = math.floor(totalDamage / count)
    local plan = {}
    local sum = 0
    for tick = 1, count do
        plan[tick] = base
        sum = sum + base
    end
    plan[count] = plan[count] + (totalDamage - sum)
    return plan
end

---@param breathCfg table GameCfg.Ability.SpecialItem.Godzilla.Breath
---@return table ledger { plan = number[], Targets = { [key] = { Hits = { [tick]=true }, Total = n } } }
function M.new_breath_ledger(breathCfg)
    return {
        plan = M.tick_damages(breathCfg.TotalDamage, breathCfg.DurationSec, breathCfg.TickSec),
        targets = {},
    }
end

---@param ledger table new_breath_ledger 的结果
---@param targetKey string 目标身份（玩家 'player:<UserId>' / 鱼 'fish:<Id>'）
---@param tick number 段序号（1..#plan）
---@return number? amount
function M.breath_hit(ledger, targetKey, tick)
    if type(targetKey) ~= 'string' or type(tick) ~= 'number' then return nil end
    local amount = ledger.plan[tick]
    if not amount then return nil end
    local entry = ledger.targets[targetKey]
    if not entry then
        entry = { hits = {}, total = 0 }
        ledger.targets[targetKey] = entry
    end
    if entry.hits[tick] then return nil end
    entry.hits[tick] = true
    entry.total = entry.total + amount
    return amount
end

---@param lastCastAt? number 上次施法的绝对时刻（World:GetServerTime()）
---@param now number
---@param cooldownSec number
---@return number remaining
function M.cooldown_remaining(lastCastAt, now, cooldownSec)
    if isBadNumber(lastCastAt) or isBadNumber(now) then return 0 end
    local remaining = lastCastAt + cooldownSec - now
    if remaining < 0 then return 0 end
    return remaining
end

return M
