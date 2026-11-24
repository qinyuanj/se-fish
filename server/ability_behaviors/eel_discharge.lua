local HostSignal = require("common.host_signal")
local SpokeEggy = require("common.packages.spoke_eggy.api")

local M = { services = {} }

function M.discharge(owner, radius, damage, hit)
    local Vitals = assert(M.services.Vitals, '[EelDischarge] 缺少 Vitals 注入')
    local FishCarrier = assert(M.services.FishCarrier, '[EelDischarge] 缺少 FishCarrier 注入')
    hit = hit or Vitals:new_hit(FishCarrier:resolve_carrier(owner) or owner, 'fishAttack')
    local position = owner.Position
    local hits = 0
    for _, player in ipairs(game:GetService('Players'):GetPlayers()) do
        local character = player.Character
        local controller = character and character.Controller
        if controller and controller.Health > 0 then
            local pos = character.Position
            local dx, dy, dz = pos.x - position.x, pos.y - position.y, pos.z - position.z
            if dx * dx + dy * dy + dz * dz <= radius * radius then
                if Vitals:apply_hit(hit, player, damage) then
                    hits = hits + 1
                    print('[EelDischarge] 命中', player.UserId, damage, 'health=' .. tostring(controller.Health))
                end
            end
        end
    end
    return hits
end

function M.Attach(anchor, services)
    if services then M.services = services end
    local start = anchor:FindFirstChild('AnchorStart')
    if not start then error('[EelDischarge] 缺少 AnchorStart') end
    return SpokeEggy.behaviour(anchor, function(scope)
        HostSignal.connect(scope, start, function()
            local ability = anchor.Parent
            local manager = ability and ability.Parent
            local owner = manager and manager.Parent
            if not owner or not owner.Controller or owner.Controller.Health <= 0 then return end
            M.discharge(owner, anchor:GetAttribute('DischargeRadius'), anchor:GetAttribute('DischargeDamage'))
        end)
    end, { name = 'EelDischarge' })
end

return M
