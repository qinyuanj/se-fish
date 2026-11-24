local GameCfg = require('common.GameCfg')

local Records = {}

local function cfg() return GameCfg.Records end

function Records.ValidUserId(userId)
    if type(userId) == 'string' then return userId ~= '' end
    return type(userId) == 'number' and userId < math.huge
        and userId >= 1 and userId == math.floor(userId)
end

function Records.Scale(weight)
    if type(weight) ~= 'number' or weight ~= weight or weight == math.huge or weight == -math.huge
        or weight <= 0 then return nil, 'invalid' end
    local scaled = math.floor(weight * cfg().Scale + 0.5 + 1e-9)
    if scaled < 1 then return nil, 'invalid' end
    if scaled > cfg().MaxScaled then return nil, 'overflow' end
    return scaled
end

function Records.Unscale(scaled)
    if type(scaled) ~= 'number' or scaled ~= math.floor(scaled) or scaled < 1 then return nil end
    return scaled / cfg().Scale
end

function Records.Entry(scaled, userId, name)
    if type(scaled) ~= 'number' or scaled ~= math.floor(scaled) or scaled < 1
        or scaled > cfg().MaxScaled then return nil, 'invalid' end
    if not Records.ValidUserId(userId) then return nil, 'invalid' end
    local display = type(name) == 'string' and name ~= '' and #name <= cfg().MaxNameLength and name or nil
    return { w = scaled, u = userId, n = display }
end

function Records.Valid(entry)
    if type(entry) ~= 'table' then return nil end
    local scaled = entry.w
    if type(scaled) ~= 'number' or scaled ~= math.floor(scaled) or scaled < 1
        or scaled > cfg().MaxScaled then return nil end
    local userId = entry.u
    if not Records.ValidUserId(userId) then return nil end
    local name = entry.n
    if name ~= nil and (type(name) ~= 'string' or #name > cfg().MaxNameLength) then name = nil end
    return { w = scaled, u = userId, n = name }
end

function Records.Wins(candidate, current)
    local next_ = Records.Valid(candidate)
    if not next_ then return false end
    local held = Records.Valid(current)
    if not held then return true end
    if next_.w ~= held.w then return next_.w > held.w end
    if type(next_.u) ~= type(held.u) then return type(next_.u) == 'number' end
    return next_.u < held.u
end

function Records.Holder(entry)
    local valid = Records.Valid(entry)
    if not valid then return nil end
    return valid.n or (cfg().HolderFallback:format(valid.u))
end

function Records.State(entry)
    local valid = Records.Valid(entry)
    if not valid then return { state = 'missing' } end
    return { state = 'ok', scaled = valid.w, weight = valid.w / cfg().Scale,
        userId = valid.u, name = valid.n, holder = Records.Holder(valid) }
end

function Records.Describe(state)
    local texts = cfg().Texts
    if type(state) ~= 'table' or state.state == 'unavailable' then return texts.Unavailable end
    if state.state ~= 'ok' then return texts.Missing end
    return texts.Format:format(state.weight, state.holder or cfg().HolderFallback:format(state.userId))
end

return Records
