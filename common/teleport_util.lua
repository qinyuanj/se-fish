local util = {}
function util:Teleport()
end

function util:SimpleTeleport(player, pos)
    if not player or not player.Character then
        print("[TeleportUtil] SimpleTeleport() no player character")
        return
    end
    
    print("[TeleportUtil] SimpleTeleport()", pos)
    player.Character.Position =  pos
end

_G.TeleportUtil = util

return util