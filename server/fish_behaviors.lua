local Behaviors = {}
local methods = {
    kingCrab = 'update_king_crab_combat', crabBoss = 'update_crab_boss_combat',
    swordfish = 'update_swordfish_combat', shark = 'update_shark_combat',
    walrus = 'update_walrus_combat', orca = 'update_orca_combat',
}
function Behaviors.step(mgr, fish, now, pos, params, combat)
    if combat == 'shrimp' or combat == 'dragon' then
        mgr:update_shrimp_combat(fish, now, pos, params, combat)
    elseif combat == 'kingCrab' and now >= (fish.ActiveUntil or math.huge) then
        mgr:stun_fish(fish, now, params)
    elseif methods[combat] then
        mgr[methods[combat]](mgr, fish, now, pos, params)
    else
        mgr:update_chase(fish, now, pos, params)
    end
end
return Behaviors
