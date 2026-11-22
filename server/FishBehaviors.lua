local Behaviors = {}
local methods = {
    kingCrab = 'UpdateKingCrabCombat', crabBoss = 'UpdateCrabBossCombat',
    swordfish = 'UpdateSwordfishCombat', shark = 'UpdateSharkCombat',
    walrus = 'UpdateWalrusCombat', orca = 'UpdateOrcaCombat',
}
function Behaviors.Step(mgr, fish, now, pos, params, combat)
    if combat == 'shrimp' or combat == 'dragon' then
        mgr:UpdateShrimpCombat(fish, now, pos, params, combat)
    elseif combat == 'kingCrab' and now >= (fish.ActiveUntil or math.huge) then
        mgr:StunFish(fish, now, params)
    elseif methods[combat] then
        mgr[methods[combat]](mgr, fish, now, pos, params)
    else
        mgr:UpdateChase(fish, now, pos, params)
    end
end
return Behaviors
