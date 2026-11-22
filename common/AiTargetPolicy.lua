local M = {}

function M.Compare(a, b)
    if a.damage ~= b.damage then return a.damage > b.damage end
    if a.distance ~= b.distance then return a.distance < b.distance end
    return (tonumber(a.userId) or math.huge) < (tonumber(b.userId) or math.huge)
end

function M.Order(candidates)
    local ranked = {}
    for _, row in ipairs(candidates or {}) do
        if row and row.player then
            ranked[#ranked + 1] = { player = row.player, pos = row.pos,
                damage = type(row.damage) == 'number' and row.damage or 0,
                distance = type(row.distance) == 'number' and row.distance or math.huge,
                userId = row.player.UserId }
        end
    end
    table.sort(ranked, M.Compare)
    return ranked
end

return M
