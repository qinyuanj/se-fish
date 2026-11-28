-- 为离线源码守卫剥离注释与字符串字面量，仅保留真实 Lua 代码词法，避免注释/日志误报。
local M = {}

function M.strip_comments_and_strings(src)
    local out, i, n = {}, 1, #src
    while i <= n do
        local ch, nxt = src:sub(i, i), src:sub(i + 1, i + 1)
        if ch == '-' and nxt == '-' then
            local eqs = src:match('^%[(=*)%[', i + 2)
            if eqs then
                local close_pos = src:find(']' .. eqs .. ']', i + 4 + #eqs, true)
                i = close_pos and (close_pos + 2 + #eqs) or (n + 1)
            else
                local nl = src:find('\n', i + 2, true)
                i = nl and (nl + 1) or (n + 1)
            end
        elseif ch == "'" or ch == '"' then
            local quote = ch
            i = i + 1
            while i <= n do
                local c = src:sub(i, i)
                if c == '\\' then
                    i = i + 2
                elseif c == quote then
                    i = i + 1
                    break
                else
                    i = i + 1
                end
            end
            out[#out + 1] = ' '
        elseif ch == '[' and (nxt == '[' or nxt == '=') then
            local eqs = src:match('^%[(=*)%[', i)
            if eqs then
                local close_pos = src:find(']' .. eqs .. ']', i + 2 + #eqs, true)
                i = close_pos and (close_pos + 2 + #eqs) or (n + 1)
                out[#out + 1] = ' '
            else
                out[#out + 1] = ch
                i = i + 1
            end
        else
            out[#out + 1] = ch
            i = i + 1
        end
    end
    return table.concat(out)
end

return M
