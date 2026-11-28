local Util = {}
local Task = game:GetService("Task")
local RunService = game:GetService("RunService")
local World = game:GetService("World")
local REUtil = require("common.re_util")

function Util:wait_for_child(rootObj, childName, waitTime)
	if not rootObj then
		return 
	end
	if not waitTime then waitTime = 10 end
	local costTime = 0.0
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

function Util:msg_notice(player, msg, duration, textColor)
	if RunService:IsServer() then
		REUtil:get_re("MsgNoticeRE"):FireClient(player, msg, duration, textColor)
		return
	end

	if not _G.local_msg_notice then 
		print("_G.LocalMsgNotice 未初始化")
		return 
	end

	_G.local_msg_notice(msg, duration, textColor)
end

function Util:global_msg_notice(msg, duration, textColor)
	if RunService:IsClient() then
		print("GlobalMsgNotice 只在服务端调用")
		return
	end

	REUtil:get_re("MsgNoticeRE"):FireAllClients(msg, duration, textColor)
end

if RunService:IsClient() then
	local Players = game:GetService("Players")
	local LocalPlayer = Players.LocalPlayer
	REUtil:get_re("MsgNoticeRE").OnClientEvent:Connect(function(msg, duration, textColor) 
		Util:msg_notice(LocalPlayer, msg, duration, textColor)
	end)
end

function Util:split_string(inputstr, sep) 
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

function Util:random_direction(detailRange, ignoreY)
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
		str = "K",
		Value = 1000,
	},
	{
		str = "M",
		Value = 1000000,
	},
	{
		str = "B",
		Value = 1000000000,
	},
}

function Util:design_number(value, keepNum)
	if value < 0 then return tostring(value) end

	local curNumInfo = nil
	for _, info in ipairs(NumWithStrMap) do
		if value > info.Value then
			curNumInfo = info
		else
			break
		end	
	end

	if not curNumInfo then return tostring(value) end

	if not keepNum then keepNum = 2 end

	local formatKey = "%." .. keepNum ..  "f" ..curNumInfo.str
	return string.format(formatKey, value/curNumInfo.Value)
end

_G.Util = Util
return Util
