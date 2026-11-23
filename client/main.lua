local ZoneMarkers = require("common.ZoneMarkers")
ZoneMarkers.Start()

local SpokeClock = require("common.SpokeClock")
local ClientStore = require("client.Store.ClientStore")
local RootView = require("client.Views.RootView")
local GameUI = require("client.GameUI")

local LocalMgrUtil = require("client.LocalMgrUtil")
LocalMgrUtil:Start()

local Task = game:GetService("Task")
local World = game:GetService("World")

-- 客户端 Spoke 响应式主干（ADR-0032 / #296）：
-- 写侧仅由 L1 入口持有并绑定宿主下行事件与空间传感器；_G.ClientSpoke 仅暴露只读侧给过渡期旧界面。
local ok_now, initial_now = pcall(function() return World:GetServerTime() end)
local valid_now = ok_now and type(initial_now) == "number" and initial_now == initial_now and math.abs(initial_now) < math.huge
local client_clock = SpokeClock.new(valid_now and initial_now or 0)
local client_store, client_store_writer = ClientStore.new({ clock = client_clock })
client_store_writer:bind_host()
_G.ClientSpoke = { Store = client_store, Clock = client_store.clock }

Task:Spawn(function()
    local waited = 0
    local ui_root = GameUI:GetUIRoot()
    while not ui_root and waited < 30 do
        Task:Wait(0.05)
        waited = waited + 0.05
        ui_root = GameUI:GetUIRoot()
    end
    if ui_root then
        RootView.mount(ui_root, client_store)
    else
        print("[client.main] 等待 EUI 根节点超时，跳过 Spoke 根视图树挂载")
    end
end)

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




