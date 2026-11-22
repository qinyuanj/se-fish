local ZoneMarkers = require("common.ZoneMarkers")
ZoneMarkers.Start()

local LocalMgrUtil = require("client.LocalMgrUtil")
LocalMgrUtil:Start()

local Task = game:GetService("Task")

_G.MgrGameUI:HideLiftButton()
_G.MgrGameUI:HideNativeHealth()

local LocalMotorUnitCtrl = require("client.LocalMotorUnitCtrl")
local LocalReelIn = require("client.LocalReelIn")
local LocalLoot = require("client.LocalLoot")
local LocalInteract = require("client.LocalInteract")
local LocalGM = require("client.LocalGM")
local LocalShop = require("client.LocalShop")
local LocalLottery = require("client.LocalLottery")
local ScreenLottery = require("client.ScreenHandlers.ScreenLottery")
local ScreenFerry = require("client.ScreenHandlers.ScreenFerry")
local ScreenSurvival = require("client.ScreenHandlers.ScreenSurvival")
local ScreenParty = require("client.ScreenHandlers.ScreenParty")
local ScreenGrill = require("client.ScreenHandlers.ScreenGrill")
local ScreenBlindbox = require("client.ScreenHandlers.ScreenBlindbox")
local ScreenPlatform = require("client.ScreenHandlers.ScreenPlatform")
local ScreenCompendium = require('client.ScreenHandlers.ScreenCompendium')
local LocalGarBite = require("client.LocalGarBite")
local LocalCastSource = require('client.LocalCastSource')
local LocalAttr = require('client.LocalAttr')

local AbilityAPI = require("client.packages.ability_system.api")
if AbilityAPI then
    AbilityAPI.StartClientLifecycle()
end

Task:Spawn(function() 
    LocalMotorUnitCtrl:Start()
    _G.LocalReelIn = LocalReelIn
    LocalReelIn:Start()
    _G.MgrGameUI:OpenScreen('ScreenMain')
    LocalLoot:Start()
    LocalGM:Start()
    _G.MgrGameUI:StartGM()
end)
Task:Spawn(function() LocalGarBite:Start() end)
Task:Spawn(function() LocalCastSource:Start() end)
Task:Spawn(function() LocalAttr:Start() end)
Task:Spawn(function() LocalInteract:Start() end)
Task:Spawn(function() LocalShop:Start() end)
Task:Spawn(function() ScreenLottery:Start() end)
Task:Spawn(function() LocalLottery:Start() end)
Task:Spawn(function() ScreenFerry:Start() end)
Task:Spawn(function() ScreenSurvival:Start() end)
Task:Spawn(function() ScreenParty:Start() end)
Task:Spawn(function() ScreenGrill:Start() end)
Task:Spawn(function() ScreenBlindbox:Start() end)
Task:Spawn(function() ScreenPlatform:Start() end)
Task:Spawn(function() ScreenCompendium:Start() end)
Task:Delay(1, function() 
    _G.MgrGameUI:OpenScreen("ScreenMsg")
end)




