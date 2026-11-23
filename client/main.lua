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
local LotteryView = require("client.Views.LotteryView")
local BlindboxView = require("client.Views.BlindboxView")
local PlatformShopView = require("client.Views.PlatformShopView")
local LotteryInteraction = require("client.Views.LotteryInteraction")
local MainHudLayout = require("client.MainHudLayout")
local Util = require("common.Util")
local FerryView = require("client.Views.FerryView")
local ReelOverlayView = require("client.Views.ReelOverlayView")
local CastSourceView = require("client.Views.CastSourceView")
local ShopView = require("client.Views.ShopView")
local FishermanView = require("client.Views.FishermanView")
local CompendiumView = require("client.Views.CompendiumView")
local GuideView = require("client.Views.GuideView")
local MessageView = require("client.Views.MessageView")
local StoryView = require("client.Views.StoryView")
local GMView = require("client.Views.GMView")
local SquadView = require("client.Views.SquadView")
local Util = require("common.Util")
local REUtil = require("common.REUtil")
local GameUI = require("client.GameUI")

local Task = game:GetService("Task")
local World = game:GetService("World")
local Players = game:GetService("Players")

-- 客户端 Spoke 响应式主干（ADR-0032 / #296）：
-- 写侧仅由 L1 入口持有并绑定宿主下行事件与空间传感器；对外只暴露统一只读状态仓库。
local ok_now, initial_now = pcall(function() return World:GetServerTime() end) -- 启动瞬间宿主时钟可能未就绪，异常时安全回退 0
local client_clock = SpokeClock.new(ok_now and Number.IsFiniteNumber(initial_now) and initial_now or 0)
local client_store, client_store_writer = ClientStore.new({ clock = client_clock })
client_store_writer:bind_host()
_G.LocalMsgNotice = function(text) client_store_writer:show_notice(text) end
local function send_gm(payload) REUtil:GetRE("GMAction"):FireServer(payload) end
_G.GM = {
    Coin = function(amount, target) send_gm({ action = "Coin", amount = amount, target = target }) end,
    Item = function(itemId, count, target) send_gm({ action = "Item", itemId = itemId, count = count or 1, target = target }) end,
    SetHealth = function(value, target) send_gm({ action = "SetHealth", value = value, target = target }) end,
    SetHunger = function(value, target) send_gm({ action = "SetHunger", value = value, target = target }) end,
    NextFish = function(fishId, target) send_gm({ action = "NextFish", fishId = fishId, target = target }) end,
}
_G.ClientSpoke = { Store = client_store, Clock = client_store.clock }

local hud_backpack_open = spoke.State.new("ClientMain.hud_backpack_open", false)
local hud_open_popup = spoke.State.new("ClientMain.hud_open_popup", nil)
local hud_reel = {}
local hud_drop_resolvers = {}
local fisherman_shared = {}
local rescue_view_state = FishermanView.rescue_state({
    get_players = function() return Players:GetPlayers() end,
    get_local_player = function() return Players.LocalPlayer end,
    is_squad_member = function(user_id)
        local party = client_store.party:now()
        if party.state ~= "party" then return false end
        for _, row in ipairs(party.members) do
            if not row.self and row.userId == user_id then return true end
        end
        return false
    end,
})
local squad_rescue_view_state = SquadView.rescue_state({
    get_players = function() return Players:GetPlayers() end,
    get_local_player = function() return Players.LocalPlayer end,
})
local action_seq = 0
local compendium_seq, records_seq = 0, 0
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
    payload.seq = next_action_seq()
    payload.action = "Operate"
    REUtil:GetRE("ItemBarAction"):FireServer(payload)
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
        _G.PlatformShop = {
            Open = function()
                client_store_writer:open_modal("platform")
                REUtil:GetRE("PlatformAction"):FireServer({ action = "OpenCoinShop" })
            end,
        }
        RootView.mount(ui_root, client_store, {
            services = {
                open_modal = function(id, payload) client_store_writer:open_modal(id, payload) end,
                close_modal = function(id) client_store_writer:close_modal(id) end,
                send_lottery = function(payload) REUtil:GetRE("LotteryAction"):FireServer(payload) end,
                send_blindbox = function(payload) REUtil:GetRE("BlindboxAction"):FireServer(payload) end,
                send_platform = function(payload) REUtil:GetRE("PlatformAction"):FireServer(payload) end,
                send_story = function(payload) REUtil:GetRE("StoryRead"):FireServer(payload) end,
                send_gm = send_gm,
                request_compendium = function()
                    compendium_seq = compendium_seq + 1
                    REUtil:GetRE("CompendiumRequest"):FireServer({ seq = compendium_seq })
                end,
                request_records = function(fishId)
                    records_seq = records_seq + 1
                    REUtil:GetRE("RecordsRequest"):FireServer({ fishId = fishId, seq = records_seq })
                end,
                request_blindbox_state = function() REUtil:GetRE("BlindboxStateRequest"):FireServer() end,
                local_character = function()
                    return Players.LocalPlayer and Players.LocalPlayer.Character or nil
                end,
                find_lottery_anchor = function(name) return Util:WaitForChild(World, name) end,
                create_lottery_scene_node = function(preset, anchor, offset)
                    return GameUI:CreateSceneNode(preset, anchor, offset)
                end,
                hud_entry_rect = function(name)
                    local resolution = GameUI:GetEuiManager():GetDeviceResolution() or { x = 1920, y = 1080 }
                    return MainHudLayout.Compute({ width = resolution.x, height = resolution.y }).Rects[name]
                end,
                send_ferry = function(payload)
                    REUtil:GetRE("FerryAction"):FireServer(payload)
                end,
                create_scene_node = function(position, name)
                    local player = Players.LocalPlayer
                    local eui = player and player.PlayerGui and player.PlayerGui.EuiManager
                    if not eui then error("摆渡场景节点创建时 EUI 未就绪", 2) end
                    local node = eui:CreateSceneNodeAtPosition(position)
                    node.Name = name
                    return node
                end,
                get_device_resolution = function()
                    local player = Players.LocalPlayer
                    local eui = player and player.PlayerGui and player.PlayerGui.EuiManager
                    return eui and eui:GetDeviceResolution() or { x = 1920, y = 1080 }
                end,
                send_grill = function(payload)
                    REUtil:GetRE("GrillAction"):FireServer(payload)
                end,
                next_seq = next_action_seq,
                send_party = function(payload)
                    REUtil:GetRE("PartyAction"):FireServer(payload)
                end,
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
                notify = function(text) client_store_writer:show_notice(text) end,
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
                SquadView.hud_spec(),
                SquadView.rescue_driver_spec(squad_rescue_view_state),
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
                GuideView.spec(),
                MessageView.spec(),
                CompendiumView.entry_spec(),
                GMView.entry_spec(),
                GrillView.spec(),
                BlindboxView.entry_spec(),
                PlatformShopView.entry_spec(),
                FerryView.spec(),
                CastSourceView.spec(),
                MainHudActionButtonsView.spec({
                    backpack_open = hud_backpack_open,
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
                }),
            },
            modals = {
                shop = ShopView.modal_spec(),
                fisherman = FishermanView.modal_spec(),
                confirm = FishermanView.confirm_modal_spec(),
            },
            overlays = {
                lottery_interaction = LotteryInteraction.spec(),
                survival = SurvivalOverlayView.spec(),
                aim_pickup = GroundLootView.aim_spec(),
                reel = ReelOverlayView.spec({ controller = hud_reel }),
            },
            modals = {
                lottery = LotteryView.modal_spec(),
                blindbox = BlindboxView.modal_spec(),
                platform = PlatformShopView.modal_spec(),
                compendium = CompendiumView.modal_spec(),
                story = StoryView.modal_spec(),
                gm = GMView.modal_spec(),
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
                squad_members = SquadView.member_spec(),
                squad_rescue = SquadView.rescue_bubble_spec(squad_rescue_view_state),
                ground_loot = GroundLootView.bubble_spec({
                    send = function(payload)
                        REUtil:GetRE('ItemBarAction'):FireServer(payload)
                    end,
                }),
                ferry = FerryView.legs_spec(),
                fish_combat = FishCombatView.bar_spec(),
                fish_warning = FishCombatView.warning_spec(),
            },
        })
    else
        print("[client.main] 等待 EUI 根节点超时，跳过 Spoke 根视图树挂载")
    end
end)

local StarterGui = game:GetService("StarterGui")
pcall(function() StarterGui:SetCoreGuiEnabled(Enums.CoreGuiType.LiftButton, false) end)
pcall(function() StarterGui:SetCoreGuiEnabled(Enums.CoreGuiType.Health, false) end)


local AbilityAPI = require("client.packages.ability_system.api")
if AbilityAPI then
    AbilityAPI.StartClientLifecycle()
end

REUtil:GetRE("RequestQuest"):FireServer()
REUtil:GetRE("RequestStory"):FireServer()

