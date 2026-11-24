local Util = {}
function Util:teleport()
end

function Util:simple_teleport(player, pos)
    if not player or not player.Character then
        print("[TeleportUtil] SimpleTeleport() no player character")
        return
    end
    
    print("[TeleportUtil] SimpleTeleport()", pos)
    player.Character.Position =  pos
end

_G.TeleportUtil = Util

return Util