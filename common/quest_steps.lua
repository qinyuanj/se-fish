local QuestSteps = {}

function QuestSteps.New()
    return { step = 1, count = 0, seen = {} }
end

function QuestSteps.Restore(steps, saved)
    if type(saved) ~= 'table' then return QuestSteps.New() end
    local step, count = saved.step, saved.count
    if type(step) ~= 'number' or step ~= math.floor(step) or step < 1 or step > #steps + 1
        or type(count) ~= 'number' or count ~= math.floor(count) or count < 0
        or count >= (steps[step] and steps[step].Need or 1) then return QuestSteps.New() end
    local state = { step = step, count = count, seen = {} }
    for id, seen in pairs(type(saved.seen) == 'table' and saved.seen or {}) do
        if type(id) == 'string' and seen == true then state.seen[id] = true end
    end
    return state
end

function QuestSteps.Done(steps, state)
    return state.step > #steps
end

function QuestSteps.Apply(steps, state, fact)
    local eventId = fact.eventId
    if eventId == nil or state.seen[eventId] then return false end
    local current = steps[state.step]
    if not current or current.Kind ~= fact.kind or (current.ItemId and current.ItemId ~= fact.itemId)
        or (current.Category and current.Category ~= fact.category) then return false end
    state.seen[eventId] = true
    state.count = state.count + math.max(1, math.floor(tonumber(fact.count) or 1))
    if state.count < (current.Need or 1) then return true, false end
    state.step = state.step + 1
    state.count = 0
    return true, true
end

function QuestSteps.Text(steps, state, title, doneText)
    local current = steps[state.step]
    if not current then return doneText end
    local text = string.format('%s %d/%d：%s', title, state.step, #steps, current.Text)
    if (current.Need or 1) > 1 then
        text = text .. string.format('（%d/%d）', state.count, current.Need)
    end
    return text
end

return QuestSteps
