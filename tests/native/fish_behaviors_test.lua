-- 注册表失败方式：行为参数错位、重复键被覆盖、配置未知键静默注册。
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

    it('test_duplicate_combat_key_fails_during_module_merge', function()
        local ok, err = pcall(load_registry, {
            ['server.fish_behaviors.shrimp'] = { shrimp = {} },
            ['server.fish_behaviors.crab'] = { shrimp = {} },
        })
        assert.is_false(ok)
        assert.is_truthy(tostring(err):match('重复.*shrimp'))
    end)

    it('test_unknown_config_key_fails_during_module_merge', function()
        local ok, err = pcall(load_registry, {
            ['server.fish_behaviors.shark'] = { notConfigured = {} },
        })
        assert.is_false(ok)
        assert.is_truthy(tostring(err):match('配置未知键.*notConfigured'))
    end)

    it('test_gar_is_explicitly_registered', function()
        assert.is_true(require('server.fish_behaviors').has('gar'))
    end)
end)
