local ZoneMarkers = require("common.ZoneMarkers")
ZoneMarkers.Start()

local Number = require("common.Number")
local GameCfg = require("common.GameCfg")
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
local ReelOverlayView = require("client.Views.ReelOverlayView")
local CastSourceView = require("client.Views.CastSourceView")
local ShopView = require("client.Views.ShopView")
local FishermanView = require("client.Views.FishermanView")
local Util = require("common.Util")
local ScreenMain = require("client.ScreenHandlers.ScreenMain")
local REUtil = require("common.REUtil")
local GameUI = require("client.GameUI")

local LocalMgrUtil = require("client.LocalMgrUtil")
LocalMgrUtil:Start()

local Task = game:GetService("Task")
local World = game:GetService("World")
local Players = game:GetService("Players")

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
local hud_reel = {}
local hud_drop_resolvers = {}
local fisherman_shared = {}
local rescue_view_state = FishermanView.rescue_state({
    get_players = function() return Players:GetPlayers() end,
    get_local_player = function() return Players.LocalPlayer end,
})
local action_seq = 0
local function next_action_seq()
    action_seq = action_seq + 1
    return action_seq
end

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
                next_seq = next_action_seq,
                send_shop = function(payload)
                    REUtil:GetRE("ShopAction"):FireServer(payload)
                end,
                send_interact = function(payload)
                    REUtil:GetRE("InteractAction"):FireServer(payload)
                end,
                open_modal = function(id, payload)
                    client_store_writer:open_modal(id, payload)
                end,
                close_modal = function(id)
                    client_store_writer:close_modal(id)
                end,
                open_platform_shop = function()
                    local platform = rawget(_G, "PlatformShop")
                    if type(platform) ~= "table" or type(platform.Open) ~= "function" then
                        error("地图商店暂不可用", 0)
                    end
                    return platform:Open()
                end,
                create_scene_node = function(entry, height, kind)
                    local anchor = entry.name and World:FindFirstChild(entry.name, true) or nil
                    if kind == "shop" and anchor and _G.GameUI then
                        local ok, node = pcall(_G.GameUI.CreateSceneNode, _G.GameUI,
                            GameCfg.Shop.BubblePreset, anchor, Vector3.New(0, height, 0))
                        if ok and node then return node end
                    end
                    local eui = Players.LocalPlayer and Players.LocalPlayer.PlayerGui
                        and Players.LocalPlayer.PlayerGui.EuiManager
                    if not eui and _G.GameUI then eui = _G.GameUI:GetEuiManager() end
                    local center = entry.position or (anchor and anchor.Position)
                    if not eui or not center then return nil end
                    return eui:CreateSceneNodeAtPosition(Vector3.New(center.x, center.y + height, center.z))
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
                reel = hud_reel,
            },
            create_node = function(kind, props)
                return World:CreateUnit(kind, props)
            end,
            hud = {
                CameraZoomView.spec(),
                ShopView.presentation_spec(),
                FishermanView.presentation_spec({
                    shared = fisherman_shared,
                    models = (function()
                        local rows = {}
                        for index, npc in ipairs(GameCfg.Interact.Fishermen) do
                            local unit = Util:WaitForChild(World, npc.AnchorNames[1])
                            if unit and unit.Scale then rows[index] = { unit = unit, baseScale = unit.Scale } end
                        end
                        return rows
                    end)(),
                }),
                FishermanView.rescue_driver_spec(rescue_view_state),
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
                CastSourceView.spec(),
                MainHudActionButtonsView.spec({
                    backpack_open = hud_backpack_open,
                    reel_active = hud_reel_active,
                    send_operate = send_hud_operate,
                    on_reel_click = function(session_id)
                        if type(hud_reel.click) == "function" then
                            hud_reel.click(session_id)
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
            modals = {
                shop = ShopView.modal_spec(),
                fisherman = FishermanView.modal_spec(),
                confirm = FishermanView.confirm_modal_spec(),
            },
            overlays = {
                survival = SurvivalOverlayView.spec(),
                aim_pickup = GroundLootView.aim_spec(),
                reel = ReelOverlayView.spec({ controller = hud_reel }),
            },
            docks = {
                shop = ShopView.bubble_spec({ anchors = (function()
                    local rows = {}
                    for _, stand in ipairs(GameCfg.Shop.Stands) do
                        local anchor = Util:WaitForChild(World, stand.AnchorName)
                        if anchor then rows[#rows + 1] = {
                            stand = stand, name = stand.AnchorName, position = anchor.Position,
                        } end
                    end
                    return rows
                end)() }),
                fisherman = FishermanView.bubble_spec({ shared = fisherman_shared, anchors = (function()
                    local rows = {}
                    for index, npc in ipairs(GameCfg.Interact.Fishermen) do
                        for _, name in ipairs(npc.AnchorNames) do
                            local anchor = Util:WaitForChild(World, name)
                            if anchor then rows[#rows + 1] = {
                                npc = npc, name = name, index = index, position = anchor.Position,
                            } end
                        end
                    end
                    return rows
                end)() }),
                rescue = FishermanView.rescue_bubble_spec(rescue_view_state),
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
local LocalGM = require("client.LocalGM")
local LocalLottery = require("client.LocalLottery")
local ScreenLottery = require("client.ScreenHandlers.ScreenLottery")
local ScreenFerry = require("client.ScreenHandlers.ScreenFerry")
local ScreenParty = require("client.ScreenHandlers.ScreenParty")
local ScreenBlindbox = require("client.ScreenHandlers.ScreenBlindbox")
local ScreenPlatform = require("client.ScreenHandlers.ScreenPlatform")
local ScreenCompendium = require('client.ScreenHandlers.ScreenCompendium')


local AbilityAPI = require("client.packages.ability_system.api")
if AbilityAPI then
    AbilityAPI.StartClientLifecycle()
end

Task:Spawn(function() 
    LocalMotorUnitCtrl:Start()
    _G.MgrGameUI:OpenScreen('ScreenMain')
    LocalGM:Start()
    _G.MgrGameUI:StartGM()
end)

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




