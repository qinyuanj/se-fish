-- #385：FishTree/FishPhase 不持有九键物种字面量，FishBehaviors 注册表与配置保持一致。
local lfs = require('lfs')
local GameCfg = require('common.game_cfg')
local FishBehaviors = require('server.fish_behaviors')

local REGISTRY = 'server.fish_behaviors'
local EXPECTED_KEYS = { 'shrimp', 'dragon', 'gar', 'kingCrab', 'crabBoss', 'swordfish', 'shark', 'walrus', 'orca' }
local KEY_SET = {}
for _, key in ipairs(EXPECTED_KEYS) do KEY_SET[key] = true end

local function read_file(path)
    local file = assert(io.open(path, 'rb'))
    local source = assert(file:read('*a'))
    file:close()
    return source
end

-- 注释替换为空格但保留字符串和换行；字符串中的注释标记不参与识别。
local function strip_comments(source)
    local out, index = {}, 1
    while index <= #source do
        local char, next_char = source:sub(index, index), source:sub(index + 1, index + 1)
        local long = source:match('^%[(=*)%[', index)
        if char == '-' and next_char == '-' then
            local eqs = source:match('^%[(=*)%[', index + 2)
            local stop
            if eqs then
                local closer = ']' .. eqs .. ']'
                local found = source:find(closer, index + 4 + #eqs, true)
                stop = found and found + #closer - 1 or #source
            else
                local newline = source:find('\n', index, true)
                stop = newline and newline - 1 or #source
            end
            out[#out + 1] = source:sub(index, stop):gsub('[^\r\n]', ' ')
            index = stop + 1
        elseif long then
            local closer = ']' .. long .. ']'
            local found = source:find(closer, index + 2 + #long, true)
            local stop = found and found + #closer - 1 or #source
            out[#out + 1] = source:sub(index, stop)
            index = stop + 1
        elseif char == '"' or char == "'" then
            local cursor = index + 1
            while cursor <= #source do
                local current = source:sub(cursor, cursor)
                if current == '\\' then
                    cursor = cursor + 2
                elseif current == char then
                    break
                else
                    cursor = cursor + 1
                end
            end
            local stop = math.min(cursor, #source)
            out[#out + 1] = source:sub(index, stop)
            index = stop + 1
        else
            out[#out + 1] = char
            index = index + 1
        end
    end
    return table.concat(out)
end

local function combat_literals(path)
    local source = strip_comments(read_file(path))
    local failures = {}
    local patterns = { '"([A-Za-z]+)"', "'([A-Za-z]+)'", '%[=*%[([A-Za-z]+)%]=*%]' }
    for _, pattern in ipairs(patterns) do
        local from = 1
        while true do
            local first, last, value = source:find(pattern, from)
            if not first then break end
            if KEY_SET[value] then
                local line = select(2, source:sub(1, first):gsub('\n', '')) + 1
                failures[#failures + 1] = string.format('%s:%d: %s', path, line, value)
            end
            from = last + 1
        end
    end
    return failures
end

local function sorted_keys(map)
    local keys = {}
    for key in pairs(map) do keys[#keys + 1] = key end
    table.sort(keys)
    return keys
end

local function load_registry(overrides)
    local names = { REGISTRY, 'common.game_cfg', 'server.fish_behaviors.gar' }
    local saved = {}
    for _, name in ipairs(names) do
        saved[name] = package.loaded[name]
        package.loaded[name] = nil
    end
    for name, value in pairs(overrides) do package.loaded[name] = value end
    local ok, result = pcall(require, REGISTRY)
    for _, name in ipairs(names) do package.loaded[name] = saved[name] end
    return ok, result
end

describe('FishBehaviorRegistryGuard', function()
    it('宿主生命周期与相位源码不含九键字面量（注释除外）', function()
        local failures = combat_literals('server/world_host/fish_tree.lua')
        for name in lfs.dir('server/world_host/fish_phases') do
            if name:match('%.lua$') then
                local found = combat_literals('server/world_host/fish_phases/' .. name)
                for _, failure in ipairs(found) do failures[#failures + 1] = failure end
            end
        end
        table.sort(failures)
        assert.same({}, failures)
    end)

    it('九个配置键全部显式注册，gar 不依赖默认回退', function()
        assert.same(sorted_keys(KEY_SET), sorted_keys(GameCfg.FishCombat))
        for _, key in ipairs(EXPECTED_KEYS) do
            assert.is_true(FishBehaviors.has(key), '未注册 FishCombat 键: ' .. key)
        end
        assert.is_true(FishBehaviors.has('gar'))
    end)

    it('已配置但未注册的键在加载注册表时立即失败', function()
        local combat = setmetatable({ configuredButMissing = {} }, { __index = GameCfg.FishCombat })
        local config = setmetatable({ FishCombat = combat }, { __index = GameCfg })
        local ok, err = load_registry({ ['common.game_cfg'] = config })
        assert.is_false(ok)
        assert.matches('未注册战斗键: configuredButMissing', tostring(err), 1, true)
    end)

    it('注册表拒绝配置未知键', function()
        local ok, err = load_registry({
            ['server.fish_behaviors.gar'] = { unknownCombat = { step = function() end } },
        })
        assert.is_false(ok)
        assert.matches('配置未知键: unknownCombat', tostring(err), 1, true)
    end)

    it('注册表拒绝重复键', function()
        local ok, err = load_registry({
            ['server.fish_behaviors.gar'] = { shrimp = { step = function() end } },
        })
        assert.is_false(ok)
        assert.matches('重复键: shrimp', tostring(err), 1, true)
    end)
end)
