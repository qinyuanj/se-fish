local REUtil = {}

local World = game:GetService("World")
local RunService = game:GetService("RunService")

REUtil.re_map = {}


local RECDCheckMap = {}

function REUtil:get_re(eventName)
    local targetRE = REUtil.re_map[eventName]
    if not targetRE then 
        targetRE = RemoteEvent.New(eventName)
        REUtil.re_map[eventName] = targetRE
        print("[REUtil] RemoteEvent.New", eventName)
    end
    
    return targetRE
end

function REUtil:check_recd(player, reName, duration)
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

_G.REUtil = REUtil
return REUtil