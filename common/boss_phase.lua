local GameCfg = require('common.game_cfg')
local Number = require('common.number')

local M = {}

local function cfg()
    return GameCfg.Ability.BossPhase
end

local function isBadNumber(v)
    return not Number.is_finite_number(v)
end

local function isPoint(p)
    return type(p) == 'table' and not isBadNumber(p.x) and not isBadNumber(p.y) and not isBadNumber(p.z)
end

local function copy(p)
    return { x = p.x, y = p.y, z = p.z }
end

local function now_(v)
    if isBadNumber(v) then return 0 end
    return v
end

local function chain(bossCfg)
    local list = { { Phase = 'normal' } }
    for _, threshold in ipairs(bossCfg.Thresholds) do
        list[#list + 1] = threshold
    end
    return list
end

local function phaseIndex(bossCfg, phase)
    local list = chain(bossCfg)
    for index, entry in ipairs(list) do
        if entry.Phase == phase then return index end
    end
    return 1
end

local function phaseEntry(state)
    local list = chain(state.Cfg)
    return list[phaseIndex(state.Cfg, state.Phase)]
end

local function attackSet(state)
    local set = state.Cfg.AttackSets and state.Cfg.AttackSets[state.Phase]
    return set or state.Cfg.AttackSets.normal
end

local function intervalOf(state, name)
    local entry = phaseEntry(state)
    if name == 'breath' and entry and not isBadNumber(entry.BreathIntervalSec) then
        return entry.BreathIntervalSec
    end
    local attack = state.Cfg.Attacks[name]
    if not attack or isBadNumber(attack.IntervalSec) then return 1 end
    return attack.IntervalSec
end

local function damageOf(state, name)
    local entry = phaseEntry(state)
    local attack = state.Cfg.Attacks[name] or {}
    local damage = attack.Damage
    if name == 'bite' and entry and not isBadNumber(entry.BiteDamage) then
        damage = entry.BiteDamage
    end
    if isBadNumber(damage) then damage = 0 end
    if entry and not isBadNumber(entry.DamageBonusPercent) then
        damage = damage * (1 + entry.DamageBonusPercent / 100)
    end
    return damage
end

local function resetCooldowns(state, now)
    state.Cooldown = {}
    for _, name in ipairs(attackSet(state)) do
        state.Cooldown[name] = now + intervalOf(state, name)
    end
    state.Pending = nil
end

local function withinRange(state, name)
    local attack = state.Cfg.Attacks[name]
    if not attack or isBadNumber(attack.Range) then return true end
    if not state.Target then return false end
    local dx, dz = state.Target.x - state.Pos.x, state.Target.z - state.Pos.z
    return math.sqrt(dx * dx + dz * dz) <= attack.Range
end

---@param bossCfg? table
---@param now? number
---@param pos? table 首领位置（吐息射程判定用）
function M.New(bossCfg, now, pos)
    bossCfg = bossCfg or cfg()
    local state = {
        Cfg = bossCfg, Phase = 'normal', Alive = true, Target = nil, Pending = nil,
        Percent = 100, Pos = pos and copy(pos) or { x = 0, y = 0, z = 0 },
        Cooldown = {}, Log = {}, AttackLog = {},
        Stats = { Frames = 0, Transitions = 0, Skipped = 0, Attacks = 0, Interrupts = 0 },
    }
    resetCooldowns(state, now_(now))
    return state
end

---血量百分比；MaxHealth 非法时返回 nil（本帧不做阶段判定，也不清空已有阶段）
function M.percent_of(health, maxHealth)
    if isBadNumber(health) or isBadNumber(maxHealth) or maxHealth <= 0 then return nil end
    local percent = health / maxHealth * 100
    if percent < 0 then percent = 0 end
    if percent > 100 then percent = 100 end
    return percent
end

---@param state table
---@param now number
---@param dt number
---@param input table { Health, MaxHealth, Alive, Target, Pos? }
---@return table events { Phase, PhaseChanged?, From?, To?, Skipped?, Percent, Attack?, Interrupted?, Reason? }
function M.update(state, now, dt, input)
    now = now_(now)
    input = input or {}
    state.Stats.Frames = state.Stats.Frames + 1
    local events = { Phase = state.Phase, Percent = state.Percent, Interrupted = false }

    if input.Alive == false then
        if state.Pending then
            events.Interrupted = true
            events.Reason = 'death'
            state.Stats.Interrupts = state.Stats.Interrupts + 1
            state.Log[#state.Log + 1] = { At = now, Kind = 'interrupt', Reason = 'death',
                Attack = state.Pending.Name }
        end
        state.Pending = nil
        state.Alive = false
        return events
    end
    state.Alive = true
    state.Target = isPoint(input.Target) and copy(input.Target) or nil
    if isPoint(input.Pos) then state.Pos = copy(input.Pos) end

    local percent = M.percent_of(input.Health, input.MaxHealth)
    if percent then
        state.Percent = percent
        local target = 1
        for index, threshold in ipairs(state.Cfg.Thresholds) do
            if percent < threshold.Percent then target = index + 1 end
        end
        local current = phaseIndex(state.Cfg, state.Phase)
        if target > current then
            local list = chain(state.Cfg)
            local skipped = {}
            for index = current + 1, target - 1 do
                skipped[#skipped + 1] = list[index].Phase
            end
            events.PhaseChanged = true
            events.From = state.Phase
            events.To = list[target].Phase
            events.Skipped = skipped
            state.Phase = list[target].Phase
            state.Stats.Transitions = state.Stats.Transitions + 1
            state.Stats.Skipped = state.Stats.Skipped + #skipped
            state.Log[#state.Log + 1] = { At = now, Kind = 'phase', From = events.From,
                To = events.To, Percent = percent, Skipped = skipped }
            resetCooldowns(state, now)
        end
    end
    events.Phase = state.Phase
    events.Percent = state.Percent

    if state.Pending and not state.Target then
        local name = state.Pending.Name
        state.Pending = nil
        events.Interrupted = true
        events.Reason = 'lostTarget'
        state.Stats.Interrupts = state.Stats.Interrupts + 1
        state.Cooldown[name] = now + intervalOf(state, name)
        state.Log[#state.Log + 1] = { At = now, Kind = 'interrupt', Reason = 'lostTarget', Attack = name }
    end
    if not state.Target then return events end

    if state.Pending then
        if now >= state.Pending.ReadyAt then
            local pending = state.Pending
            state.Pending = nil
            state.Cooldown[pending.Name] = now + intervalOf(state, pending.Name)
            events.Attack = M.land(state, now, pending)
        end
        return events
    end

    for _, name in ipairs(attackSet(state)) do
        local readyAt = state.Cooldown[name] or 0
        if now >= readyAt and withinRange(state, name) then
            local attack = state.Cfg.Attacks[name] or {}
            if not isBadNumber(attack.WindupSec) and attack.WindupSec > 0 then
                state.Pending = { Name = name, ReadyAt = now + attack.WindupSec,
                    Damage = damageOf(state, name), Lethal = attack.OneShot == true }
            else
                state.Cooldown[name] = now + intervalOf(state, name)
                events.Attack = M.land(state, now, { Name = name, Damage = damageOf(state, name),
                    Lethal = attack.OneShot == true })
            end
            return events
        end
    end
    return events
end

function M.land(state, now, attack)
    local landed = { At = now, Name = attack.Name, Damage = attack.Damage, Lethal = attack.Lethal == true }
    state.Stats.Attacks = state.Stats.Attacks + 1
    if #state.AttackLog < 64 then state.AttackLog[#state.AttackLog + 1] = landed end
    return landed
end

function M.winding(state)
    return state.Pending ~= nil
end

return M
