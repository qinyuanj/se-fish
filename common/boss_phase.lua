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
    local list = chain(state.cfg)
    return list[phaseIndex(state.cfg, state.Phase)]
end

local function attackSet(state)
    local set = state.cfg.AttackSets and state.cfg.AttackSets[state.Phase]
    return set or state.cfg.AttackSets.normal
end

local function intervalOf(state, name)
    local entry = phaseEntry(state)
    if name == 'breath' and entry and not isBadNumber(entry.BreathIntervalSec) then
        return entry.BreathIntervalSec
    end
    local attack = state.cfg.Attacks[name]
    if not attack or isBadNumber(attack.IntervalSec) then return 1 end
    return attack.IntervalSec
end

local function damageOf(state, name)
    local entry = phaseEntry(state)
    local attack = state.cfg.Attacks[name] or {}
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
    state.cooldown = {}
    for _, name in ipairs(attackSet(state)) do
        state.cooldown[name] = now + intervalOf(state, name)
    end
    state.pending = nil
end

local function withinRange(state, name)
    local attack = state.cfg.Attacks[name]
    if not attack or isBadNumber(attack.Range) then return true end
    if not state.Target then return false end
    local dx, dz = state.Target.x - state.pos.x, state.Target.z - state.pos.z
    return math.sqrt(dx * dx + dz * dz) <= attack.Range
end

---@param bossCfg? table
---@param now? number
---@param pos? table 首领位置（吐息射程判定用）
function M.new(bossCfg, now, pos)
    bossCfg = bossCfg or cfg()
    local state = {
        cfg = bossCfg, Phase = 'normal', alive = true, Target = nil, pending = nil,
        Percent = 100, pos = pos and copy(pos) or { x = 0, y = 0, z = 0 },
        cooldown = {}, Log = {}, attack_log = {},
        stats = { frames = 0, transitions = 0, skipped = 0, Attacks = 0, interrupts = 0 },
    }
    resetCooldowns(state, now_(now))
    return state
end

---血量百分比；MaxHealth 非法时返回 nil（本帧不做阶段判定，也不清空已有阶段）
function M.percent_of(health, max_health)
    if isBadNumber(health) or isBadNumber(max_health) or max_health <= 0 then return nil end
    local percent = health / max_health * 100
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
    state.stats.frames = state.stats.frames + 1
    local events = { Phase = state.Phase, Percent = state.Percent, interrupted = false }

    if input.alive == false then
        if state.pending then
            events.interrupted = true
            events.Reason = 'death'
            state.stats.interrupts = state.stats.interrupts + 1
            state.Log[#state.Log + 1] = { at = now, Kind = 'interrupt', Reason = 'death',
                Attack = state.pending.Name }
        end
        state.pending = nil
        state.alive = false
        return events
    end
    state.alive = true
    state.Target = isPoint(input.Target) and copy(input.Target) or nil
    if isPoint(input.pos) then state.pos = copy(input.pos) end

    local percent = M.percent_of(input.Health, input.MaxHealth)
    if percent then
        state.Percent = percent
        local target = 1
        for index, threshold in ipairs(state.cfg.Thresholds) do
            if percent < threshold.Percent then target = index + 1 end
        end
        local current = phaseIndex(state.cfg, state.Phase)
        if target > current then
            local list = chain(state.cfg)
            local skipped = {}
            for index = current + 1, target - 1 do
                skipped[#skipped + 1] = list[index].Phase
            end
            events.phase_changed = true
            events.From = state.Phase
            events.to = list[target].Phase
            events.skipped = skipped
            state.Phase = list[target].Phase
            state.stats.transitions = state.stats.transitions + 1
            state.stats.skipped = state.stats.skipped + #skipped
            state.Log[#state.Log + 1] = { at = now, Kind = 'phase', From = events.From,
                to = events.to, Percent = percent, skipped = skipped }
            resetCooldowns(state, now)
        end
    end
    events.Phase = state.Phase
    events.Percent = state.Percent

    if state.pending and not state.Target then
        local name = state.pending.Name
        state.pending = nil
        events.interrupted = true
        events.Reason = 'lostTarget'
        state.stats.interrupts = state.stats.interrupts + 1
        state.cooldown[name] = now + intervalOf(state, name)
        state.Log[#state.Log + 1] = { at = now, Kind = 'interrupt', Reason = 'lostTarget', Attack = name }
    end
    if not state.Target then return events end

    if state.pending then
        if now >= state.pending.ready_at then
            local pending = state.pending
            state.pending = nil
            state.cooldown[pending.Name] = now + intervalOf(state, pending.Name)
            events.Attack = M.land(state, now, pending)
        end
        return events
    end

    for _, name in ipairs(attackSet(state)) do
        local readyAt = state.cooldown[name] or 0
        if now >= readyAt and withinRange(state, name) then
            local attack = state.cfg.Attacks[name] or {}
            if not isBadNumber(attack.WindupSec) and attack.WindupSec > 0 then
                state.pending = { Name = name, ready_at = now + attack.WindupSec,
                    Damage = damageOf(state, name), lethal = attack.OneShot == true }
            else
                state.cooldown[name] = now + intervalOf(state, name)
                events.Attack = M.land(state, now, { Name = name, Damage = damageOf(state, name),
                    lethal = attack.OneShot == true })
            end
            return events
        end
    end
    return events
end

function M.land(state, now, attack)
    local landed = { at = now, Name = attack.Name, Damage = attack.Damage, lethal = attack.lethal == true }
    state.stats.Attacks = state.stats.Attacks + 1
    if #state.attack_log < 64 then state.attack_log[#state.attack_log + 1] = landed end
    return landed
end

function M.winding(state)
    return state.pending ~= nil
end

return M
