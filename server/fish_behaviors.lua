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

for combat in pairs(GameCfg.FishCombat) do
    if behaviors[combat] == nil then error('FishBehaviors 未注册战斗键: ' .. tostring(combat), 2) end
end

function FishBehaviors.init(fish, now, combat, species)
    local behavior = behaviors[species.Combat]
    if not behavior then error('FishBehaviors 未注册战斗键: ' .. tostring(species.Combat), 2) end
    if behavior.init then return behavior.init(fish, now, combat, species) end
end

function FishBehaviors.step(mgr, fish, now, pos, params, combat)
    local behavior = behaviors[combat]
    if not behavior then error('FishBehaviors 未注册战斗键: ' .. tostring(combat), 2) end
    return behavior.step(mgr, fish, now, pos, params, combat)
end

function FishBehaviors.has(combat)
    return behaviors[combat] ~= nil
end

return FishBehaviors
