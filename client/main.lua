local ZoneMarkers = require("common.ZoneMarkers")
ZoneMarkers.Start()

local Number = require("common.Number")
local SpokeClock = require("common.SpokeClock")
local spoke = require("common.packages.spoke.api")
local ClientStore = require("client.Store.ClientStore")
local RootView = require("client.Views.RootView")
local CameraZoomView = require("client.Views.CameraZoomView")
local MainHudVitalsView = require("client.Views.MainHudVitalsView")
local MainHudEquipPopups = require("client.Views.MainHudEquipPopups")
local MainHudBackpackView = require("client.Views.MainHudBackpackView")
local MainHudItemBarView = require("client.Views.MainHudItemBarView")
local MainHudActionButtonsView = require("client.Views.MainHudActionButtonsView")
local AttackView = require("client.Views.AttackView")
local WeaponAim = require("client.WeaponAim")
local SurvivalOverlayView = require("client.Views.SurvivalOverlayView")
local GroundLootView = require("client.Views.GroundLootView")
local FishCombatView = require("client.Views.FishCombatView")
local GrillView = require("client.Views.GrillView")
local ScreenMain = require("client.ScreenHandlers.ScreenMain")
local REUtil = require("common.REUtil")
local GameUI = require("client.GameUI")

local LocalMgrUtil = require("client.LocalMgrUtil")
LocalMgrUtil:Start()

local Task = game:GetService("Task")
local World = game:GetService("World")

-- 客户端 Spoke 响应式主干（ADR-0032 / #296）：
-- 写侧仅由 L1 入口持有并绑定宿主下行事件与空间传感器；_G.ClientSpoke 仅暴露只读侧给过渡期旧界面。
local ok_now, initial_now = pcall(function() return World:GetServerTime() end) -- 启动瞬间宿主时钟可能未就绪，异常时安全回退 0
local client_clock = SpokeClock.new(ok_now and Number.IsFiniteNumber(initial_now) and initial_now or 0)
local client_store, client_store_writer = ClientStore.new({ clock = client_clock })
client_store_writer:bind_host()
_G.ClientSpoke = { Store = client_store, Clock = client_store.clock }

local hud_backpack_open = spoke.State.new("ClientMain.hud_backpack_open", false)
local hud_open_popup = spoke.State.new("ClientMain.hud_open_popup", nil)
local hud_reel_active = spoke.State.new("ClientMain.hud_reel_active", false)
local hud_drop_resolvers = {}

local function resolve_item_bar_drop(pos)
    return hud_drop_resolvers.backpack and hud_drop_resolvers.backpack(pos) or nil
end

local function resolve_backpack_drop(pos)
    return hud_drop_resolvers.item_bar and hud_drop_resolvers.item_bar(pos) or nil
end

local function send_hud_operate(payload)
    if type(ScreenMain.Operate) == "function" then
        ScreenMain:Operate(payload)
    end
end

ScreenMain.OnOpenChanged = function(is_open)
    if not is_open then
        hud_open_popup:set(nil)
    end
    client_store_writer:set_hud_visible(is_open)
end

ScreenMain.OnReelActiveChanged = function(active)
    hud_reel_active:set(active == true)
end

Task:Spawn(function()
    local waited = 0
    local ui_root = GameUI:GetUIRoot()
    while not ui_root and waited < 30 do
        Task:Wait(0.05)
        waited = waited + 0.05
        ui_root = GameUI:GetUIRoot()
    end
    if ui_root then
        RootView.mount(ui_root, client_store, {
            services = {
                send_grill = function(payload)
                    REUtil:GetRE("GrillAction"):FireServer(payload)
                end,
                send_weapon = function(payload)
                    local event = _G.REUtil and _G.REUtil:GetRE("WeaponAction")
                    if event and type(event.FireServer) == "function" then
                        event:FireServer(payload)
                    end
                end,
                notify = function(text)
                    local notice = rawget(_G, "LocalMsgNotice")
                    if type(notice) == "function" then notice(text) end
                end,
                aim_direction = function()
                    local payload = WeaponAim:AttackPayload()
                    return payload and payload.aim or nil
                end,
            },
            hud = {
                CameraZoomView.spec(),
                MainHudVitalsView.spec(),
                MainHudEquipPopups.spec({
                    open_popup = hud_open_popup,
                    backpack_open = hud_backpack_open,
                    send_operate = send_hud_operate,
                }),
                MainHudItemBarView.spec({
                    backpack_open = hud_backpack_open,
                    resolve_drop_target = resolve_item_bar_drop,
                    on_drop_resolver = function(fn)
                        hud_drop_resolvers.item_bar = fn
                    end,
                }),
                AttackView.spec(),
                GrillView.spec(),
                MainHudActionButtonsView.spec({
                    backpack_open = hud_backpack_open,
                    reel_active = hud_reel_active,
                    send_operate = send_hud_operate,
                    on_reel_click = function(session_id)
                        local reel = rawget(_G, "LocalReelIn")
                        if type(reel) == "table" and reel.SessionId == session_id and type(reel.Click) == "function" then
                            reel:Click()
                            if ScreenMain.Inited then
                                ScreenMain:ShowCast()
                            end
                        end
                    end,
                }),
                MainHudBackpackView.spec({
                    backpack_open = hud_backpack_open,
                    open_popup = hud_open_popup,
                    resolve_drop_target = resolve_backpack_drop,
                    on_drop_resolver = function(fn)
                        hud_drop_resolvers.backpack = fn
                    end,
                    on_open_changed = function(is_open)
                        if type(ScreenMain.SetBackpackOpen) == "function" then
                            ScreenMain:SetBackpackOpen(is_open)
                        end
                    end,
                }),
            },
            overlays = {
                survival = SurvivalOverlayView.spec(),
                aim_pickup = GroundLootView.aim_spec(),
            },
            docks = {
                ground_loot = GroundLootView.bubble_spec({
                    send = function(payload)
                        REUtil:GetRE('ItemBarAction'):FireServer(payload)
                    end,
                }),
                fish_combat = FishCombatView.bar_spec(),
                fish_warning = FishCombatView.warning_spec(),
            },
        })
    else
        print("[client.main] 等待 EUI 根节点超时，跳过 Spoke 根视图树挂载")
    end
end)

_G.MgrGameUI:HideLiftButton()
_G.MgrGameUI:HideNativeHealth()

local LocalMotorUnitCtrl = require("client.LocalMotorUnitCtrl")
local LocalReelIn = require("client.LocalReelIn")
local LocalInteract = require("client.LocalInteract")
local LocalGM = require("client.LocalGM")
local LocalShop = require("client.LocalShop")
local LocalLottery = require("client.LocalLottery")
local ScreenLottery = require("client.ScreenHandlers.ScreenLottery")
local ScreenFerry = require("client.ScreenHandlers.ScreenFerry")
local ScreenParty = require("client.ScreenHandlers.ScreenParty")
local ScreenBlindbox = require("client.ScreenHandlers.ScreenBlindbox")
local ScreenPlatform = require("client.ScreenHandlers.ScreenPlatform")
local ScreenCompendium = require('client.ScreenHandlers.ScreenCompendium')
local LocalCastSource = require('client.LocalCastSource')

local AbilityAPI = require("client.packages.ability_system.api")
if AbilityAPI then
    AbilityAPI.StartClientLifecycle()
end

Task:Spawn(function() 
    LocalMotorUnitCtrl:Start()
    _G.LocalReelIn = LocalReelIn
    LocalReelIn:Start()
    _G.MgrGameUI:OpenScreen('ScreenMain')
    LocalGM:Start()
    _G.MgrGameUI:StartGM()
end)
Task:Spawn(function() LocalCastSource:Start() end)
Task:Spawn(function() LocalInteract:Start() end)
Task:Spawn(function() LocalShop:Start() end)
Task:Spawn(function() ScreenLottery:Start() end)
Task:Spawn(function() LocalLottery:Start() end)
Task:Spawn(function() ScreenFerry:Start() end)
Task:Spawn(function() ScreenParty:Start() end)
Task:Spawn(function() ScreenBlindbox:Start() end)
Task:Spawn(function() ScreenPlatform:Start() end)
Task:Spawn(function() ScreenCompendium:Start() end)
Task:Delay(1, function() 
    _G.MgrGameUI:OpenScreen("ScreenMsg")
end)




