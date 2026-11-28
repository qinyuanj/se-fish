-- #411 运行期建点（CreateUnit）台账守卫：
-- 扫描 client/、common/、server/（排除官方只读 packages/）所有真实引擎 CreateUnit 调用，
-- 强制每一处运行期动态单位创建都登记在下方台账中；新增未授权建点或超额立即阻断，
-- 已移除的旧建点若台账未同步收窄也会提示收紧。
local seam = require('tools.seam')
local LuaSourceStrip = require('tests.support.lua_source_strip')

-- 台账：相对路径 -> { count = 真实 CreateUnit 调用次数, reason = 用途说明 }
local LEDGER = {
    ['client/damage_float.lua'] = { count = 1, reason = '战斗伤害飘字 EUITextLabel' },
    ['client/interaction_bubble.lua'] = { count = 2, reason = '通用交互气泡 EUIButton + EUITextLabel' },
    ['client/main.lua'] = { count = 1, reason = 'RootView 统一注入的客户端 EUI 节点工厂' },
    ['client/views/cast_source_view.lua'] = { count = 1, reason = '抛竿源点视图 EUI 节点回退建点' },
    ['client/views/root_view.lua'] = { count = 1, reason = 'Spoke 根视图树默认 EUI 节点建点' },
    ['server/ability_api.lua'] = { count = 1, reason = '技能骨骼挂点 SkeletalSocketMount' },
    ['server/ability_behaviors/melee_hit.lua'] = { count = 2, reason = '近战挂点 SkeletalSocketMount 与命中检测 TriggerUnit' },
    ['server/main.lua'] = { count = 1, reason = 'ServerRuntime 统一注入的服务端建点工厂（活鱼/鱼饵点/浮漂/武器）' },
    ['server/world_host/fish_carrier.lua'] = { count = 2, reason = '活鱼载体与受击体动态创建（回退默认工厂）' },
    ['server/world_host/fish_tree.lua'] = { count = 1, reason = '活鱼行为树实体建点（回退默认工厂）' },
    ['server/world_host/fishing_phase.lua'] = { count = 1, reason = '抛竿浮漂与钓线视觉建点（回退默认工厂）' },
    ['server/world_host/player_weapon.lua'] = { count = 1, reason = '武器投射物视觉触发载体' },
}

local function read_source(path)
    local handle = assert(io.open(path, 'rb'))
    local text = handle:read('*a')
    handle:close()
    return text
end

-- 统计真实引擎建点调用：:CreateUnit(、.CreateUnit( 或 pcall/xpcall(xxx.CreateUnit,
local function count_create_unit_calls(code)
    local count = 0
    for _ in code:gmatch(':CreateUnit%s*%(') do count = count + 1 end
    for receiver in code:gmatch('([%w_]+)%.CreateUnit%s*%(') do
        if receiver ~= 'self' and receiver ~= 'opts' then count = count + 1 end
    end
    for _ in code:gmatch('x?pcall%s*%(%s*[%w_%.]+%.CreateUnit%s*,') do count = count + 1 end
    return count
end

describe('runtime_unit_ledger_guard (#411)', function()
    it('test_every_runtime_create_unit_call_is_registered_in_ledger', function()
        local observed = {}
        for _, root in ipairs({ 'client', 'common', 'server' }) do
            for _, rel_path in ipairs(seam.list_files(root)) do
                local rel = seam.normalize(root .. '/' .. rel_path)
                if rel:match('%.lua$') and not rel:find('/packages/', 1, true) then
                    local stripped = LuaSourceStrip.strip_comments_and_strings(read_source(rel))
                    local calls = count_create_unit_calls(stripped)
                    if calls > 0 then observed[rel] = calls end
                end
            end
        end

        local violations = {}
        for path, calls in pairs(observed) do
            local entry = LEDGER[path]
            if not entry then
                violations[#violations + 1] = string.format('未登记的运行期 CreateUnit 建点: %s (%d 处)', path, calls)
            elseif calls > entry.count then
                violations[#violations + 1] = string.format(
                    '运行期 CreateUnit 建点超出台账上限: %s (实际=%d, 台账=%d)', path, calls, entry.count)
            elseif calls < entry.count then
                violations[#violations + 1] = string.format(
                    '运行期 CreateUnit 建点已缩减，请收窄台账: %s (实际=%d, 台账=%d)', path, calls, entry.count)
            end
        end
        for path, entry in pairs(LEDGER) do
            if not observed[path] then
                violations[#violations + 1] = string.format(
                    '台账中已无 CreateUnit 调用，请移除条目: %s (原登记=%d)', path, entry.count)
            end
        end
        table.sort(violations)
        assert.same({}, violations)
    end)
end)
