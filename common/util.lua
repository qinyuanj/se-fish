local Util = {}
local Task = game:GetService("Task")
local RunService = game:GetService("RunService")
local World = game:GetService("World")
local REUtil = require("common.REUtil")

function Util:WaitForChild(rootObj, childName, waitTime)
	if not rootObj then
		return 
	end
	if not waitTime then waitTime = 10 end
	local costTime = 0
	while rootObj and costTime < waitTime do
		local childObj = rootObj:FindFirstChild(childName, rootObj == World)
		if childObj then 
			return childObj
		 end
		Task:Wait(0.033) 
		costTime = costTime + 0.033
	end

	print("[Util] WaitForChild time end", childName, waitTime)
	return
end	

function Util:MsgNotice(player, msg, duration, textColor)
	if RunService:IsServer() then
		REUtil:GetRE("MsgNoticeRE"):FireClient(player, msg, duration, textColor)
		return
	end

	if not _G.LocalMsgNotice then 
		print("_G.LocalMsgNotice 未初始化")
		return 
	end

	_G.LocalMsgNotice(msg, duration, textColor)
end

function Util:GlobalMsgNotice(msg, duration, textColor)
	if RunService:IsClient() then
		print("GlobalMsgNotice 只在服务端调用")
		return
	end

	REUtil:GetRE("MsgNoticeRE"):FireAllClients(msg, duration, textColor)
end

if RunService:IsClient() then
	local Players = game:GetService("Players")
	local LocalPlayer = Players.LocalPlayer
	REUtil:GetRE("MsgNoticeRE").OnClientEvent:Connect(function(msg, duration, textColor) 
		Util:MsgNotice(LocalPlayer, msg, duration, textColor)
	end)
end


if RunService:IsServer() then
	REUtil:GetRE("GlobalMarquee").OnServerEvent:Connect(function(p, msg) 
		Util:GlobalMarquee(msg)
	end)
end

function Util:SplitString(inputstr, sep) 
	if sep == nil then
        sep = "%s"
    end

    local t = {}
    local i = 1
    for str in string.gmatch(inputstr, "([^"..sep.."]+)") do
        t[i] = str
        i = i + 1
    end
	return t
end

function Util:RandomDirection(detailRange, ignoreY)
	if not detailRange then
		detailRange = 10
	end
	if ignoreY == nil then
		ignoreY = true
	end
	local x = math.random(-detailRange, detailRange)
	local y = ignoreY and 0 or math.random(-detailRange, detailRange)
	local z = math.random(-detailRange, detailRange)
	return Vector3(x, y, z).Unit
end

local NumWithStrMap = {
	{
		Str = "K",
		Value = 1000,
	},
	{
		Str = "M",
		Value = 1000000,
	},
	{
		Str = "B",
		Value = 1000000000,
	},
}

function Util:DesignNumber(value, keepNum)
	if value < 0 then return tostring(value) end

	local curNumInfo = nil
	for i, info in ipairs(NumWithStrMap) do
		if value > info.Value then
			curNumInfo = info
		else
			break
		end	
	end

	if not curNumInfo then return tostring(value) end

	if not keepNum then keepNum = 2 end

	local formatKey = "%." .. keepNum ..  "f" ..curNumInfo.Str
	return string.format(formatKey, value/curNumInfo.Value)
end

_G.Util = Util
return Util
