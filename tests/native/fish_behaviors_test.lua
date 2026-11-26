-- 公开行为合同：init/step 参数顺序；注册完整性结构合同由 fish_behavior_registry_guard_test 持有。
local species_modules = {
    'server.fish_behaviors.shrimp',
    'server.fish_behaviors.crab',
    'server.fish_behaviors.swordfish',
    'server.fish_behaviors.shark',
    'server.fish_behaviors.walrus',
    'server.fish_behaviors.orca',
    'server.fish_behaviors.gar',
}

local function load_registry(overrides)
    overrides = overrides or {}
    local empty = {}
    for _, name in ipairs(species_modules) do empty[name] = true end
    local env = setmetatable({
        require = function(name)
            if overrides[name] then return overrides[name] end
            if empty[name] then return {} end
            return require(name)
        end,
    }, { __index = _G })
    return assert(loadfile('server/fish_behaviors.lua', 't', env))()
end

describe('FishBehaviors', function()
    it('test_registered_behavior_receives_public_init_and_step_contract', function()
        local calls = {}
        local registry = load_registry({
            ['common.game_cfg'] = { FishCombat = { shrimp = {} } },
            ['server.fish_behaviors.shrimp'] = {
                shrimp = {
                    init = function(fish, now, combat, species)
                        calls.init = { fish, now, combat, species }
                    end,
                    step = function(mgr, fish, now, pos, params, combat)
                        calls.step = { mgr, fish, now, pos, params, combat }
                    end,
                },
            },
        })
        local fish, species, combat, params = {}, { Combat = 'shrimp' }, { ActiveSec = 3 }, { ActiveSec = 4 }
        assert.is_true(registry.has('shrimp'))
        assert.is_false(registry.has('crabBoss'))
        registry.init(fish, 10, combat, species)
        registry.step('mgr', fish, 11, 'pos', params, 'shrimp')
        assert.same({ fish, 10, combat, species }, calls.init)
        assert.same({ 'mgr', fish, 11, 'pos', params, 'shrimp' }, calls.step)
    end)

end)
