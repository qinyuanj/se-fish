-- 伤害优先目标选择：纯排序规则，只产出候选名次，不持有单位、不写控制器（#260）。
-- 条款 6-29：累计有效伤害最高的有效玩家优先；没有伤害记录时按距离最近；同分同距按 UserId 稳定裁决。
-- 合法性（濒死/死亡/离线/离战范围，6-30）和特殊招式指定目标（6-31）由调用方在排序前处理。
local M = {}

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
    table.sort(ranked, function(a, b)
        if a.damage ~= b.damage then return a.damage > b.damage end
        if a.distance ~= b.distance then return a.distance < b.distance end
        -- 同分同距按 UserId 数值裁决（不是字符串序：'100' < '91' 会颠倒），保证确定性。
        return (tonumber(a.userId) or math.huge) < (tonumber(b.userId) or math.huge)
    end)
    return ranked
end

return M
