local re_util = {}

local World = game:GetService("World")
local RunService = game:GetService("RunService")

re_util.REMap = {}


local RECDCheckMap = {}

function re_util:GetRE(eventName)
    local targetRE = re_util.REMap[eventName]
    if not targetRE then 
        targetRE = RemoteEvent.New(eventName)
        re_util.REMap[eventName] = targetRE
        print("[re_util] RemoteEvent.New", eventName)
    end
    
    return targetRE
end

function re_util:CheckRECD(player, reName, duration)
    if not duration then duration = 1 end

    local pMap = RECDCheckMap[player.UserId]
    if not pMap then
        pMap = {}
        RECDCheckMap[player.UserId] = pMap
    end

    local workTime = pMap[reName]
    local nowTime = World:GetServerTime()
    if not workTime or workTime < nowTime then
        pMap[reName] = nowTime + duration
        return
    end

    return true
end

if RunService:IsServer() then
    local Players = game:GetService("Players")
    Players.PlayerRemoving:Connect(function(player)
        RECDCheckMap[player.UserId] = nil        
    end)
end

_G.re_util = re_util
return re_util