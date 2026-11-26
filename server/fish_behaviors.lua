local GameCfg = require('common.game_cfg')

local FishBehaviors = {}
---@type table<string, table?>
local behaviors = {}
local ShrimpBehaviors = require('server.fish_behaviors.shrimp')
local CrabBehaviors = require('server.fish_behaviors.crab')
local SwordfishBehaviors = require('server.fish_behaviors.swordfish')
local SharkBehaviors = require('server.fish_behaviors.shark')
local WalrusBehaviors = require('server.fish_behaviors.walrus')
local OrcaBehaviors = require('server.fish_behaviors.orca')
local GarBehaviors = require('server.fish_behaviors.gar')
local modules = {
    ShrimpBehaviors, CrabBehaviors, SwordfishBehaviors,
    SharkBehaviors, WalrusBehaviors, OrcaBehaviors, GarBehaviors,
}
for _, module in ipairs(modules) do
    for combat, behavior in pairs(module) do
        if GameCfg.FishCombat[combat] == nil then error('FishBehaviors 配置未知键: ' .. tostring(combat), 2) end
        if behaviors[combat] ~= nil then error('FishBehaviors 重复键: ' .. tostring(combat), 2) end
        behaviors[combat] = behavior
    end
end

local legacy_methods = {
    kingCrab = 'update_king_crab_combat', crabBoss = 'update_crab_boss_combat',
    swordfish = 'update_swordfish_combat', shark = 'update_shark_combat',
    walrus = 'update_walrus_combat', orca = 'update_orca_combat',
}

local function legacy_step(mgr, fish, now, pos, params, combat)
    if combat == 'shrimp' or combat == 'dragon' then
        mgr:update_shrimp_combat(fish, now, pos, params, combat)
    elseif combat == 'kingCrab' and now >= (fish.ActiveUntil or math.huge) then
        mgr:stun_fish(fish, now, params)
    elseif legacy_methods[combat] then
        mgr[legacy_methods[combat]](mgr, fish, now, pos, params)
    else
        error('FishBehaviors 未注册战斗键: ' .. tostring(combat), 2)
    end
end

function FishBehaviors.init(fish, now, combat, species)
    local behavior = behaviors[species.Combat]
    if behavior and behavior.init then return behavior.init(fish, now, combat, species) end
end

function FishBehaviors.step(mgr, fish, now, pos, params, combat)
    local behavior = behaviors[combat]
    if behavior then return behavior.step(mgr, fish, now, pos, params, combat) end
    return legacy_step(mgr, fish, now, pos, params, combat)
end

function FishBehaviors.has(combat)
    return behaviors[combat] ~= nil
end

return FishBehaviors
