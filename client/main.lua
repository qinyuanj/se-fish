local ZoneMarkers = require("common.zone_markers")
ZoneMarkers.start()

local Number = require("common.number")
local GameCfg = require("common.game_cfg")
local SpokeClock = require("common.spoke_clock")
local Spoke = require("common.packages.spoke.api")
local ClientStore = require("client.store.client_store")
local RootView = require("client.views.root_view")
local CameraZoomView = require("client.views.camera_zoom_view")
local MainHudVitalsView = require("client.views.main_hud_vitals_view")
local MainHudEquipPopups = require("client.views.main_hud_equip_popups")
local MainHudBackpackView = require("client.views.main_hud_backpack_view")
local MainHudItemBarView = require("client.views.main_hud_item_bar_view")
local MainHudActionButtonsView = require("client.views.main_hud_action_buttons_view")
local AttackView = require("client.views.attack_view")
local WeaponAim = require("client.weapon_aim")
local SurvivalOverlayView = require("client.views.survival_overlay_view")
local GroundLootView = require("client.views.ground_loot_view")
local FishCombatView = require("client.views.fish_combat_view")
local GrillView = require("client.views.grill_view")
local LotteryView = require("client.views.lottery_view")
local BlindboxView = require("client.views.blindbox_view")
local PlatformShopView = require("client.views.platform_shop_view")
local LotteryInteraction = require("client.views.lottery_interaction")
local MainHudLayout = require("client.main_hud_layout")
local Util = require("common.util")
local FerryView = require("client.views.ferry_view")
local ReelOverlayView = require("client.views.reel_overlay_view")
local CastSourceView = require("client.views.cast_source_view")
local ShopView = require("client.views.shop_view")
local FishermanView = require("client.views.fisherman_view")
local CompendiumView = require("client.views.compendium_view")
local GuideView = require("client.views.guide_view")
local MessageView = require("client.views.message_view")
local StoryView = require("client.views.story_view")
local GMView = require("client.views.gm_view")
local SquadView = require("client.views.squad_view")
local REUtil = require("common.re_util")
local GameUI = require("client.game_ui")

local Task = game:GetService("Task")
local World = game:GetService("World")
local Players = game:GetService("Players")

-- 客户端 Spoke 响应式主干（ADR-0032 / #296）：
local ok_now, initial_now = pcall(function() return World:GetServerTime() end) -- 启动瞬间宿主时钟可能未就绪，异常时安全回退 0
local client_clock = SpokeClock.new(ok_now and Number.is_finite_number(initial_now) and initial_now or 0)
local client_store, client_store_writer = ClientStore.new({ clock = client_clock })
client_store_writer:bind_host()
_G.local_msg_notice = function(text) client_store_writer:show_notice(text) end
local function send_gm(payload) REUtil:get_re("GMAction"):FireServer(payload) end
_G.GM = {
    coin = function(amount, target) send_gm({ action = "Coin", amount = amount, target = target }) end,
    Item = function(itemId, count, target) send_gm({ action = "Item", itemId = itemId, count = count or 1, target = target }) end,
    set_health = function(value, target) send_gm({ action = "SetHealth", value = value, target = target }) end,
    set_hunger = function(value, target) send_gm({ action = "SetHunger", value = value, target = target }) end,
    next_fish = function(fishId, target) send_gm({ action = "NextFish", fishId = fishId, target = target }) end,
}
_G.ClientSpoke = { Store = client_store, clock = client_store.clock }

local hud_backpack_open = Spoke.State.new("ClientMain.hud_backpack_open", false)
local hud_open_popup = Spoke.State.new("ClientMain.hud_open_popup", nil)
local hud_reel = {}
local hud_drop_resolvers = {}
local fisherman_shared = {}
local grill_shared = GrillView.new_shared()
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

local function is_positive_int(value)
    return Number.is_finite_number(value) and value >= 1 and value == math.floor(value)
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
    REUtil:get_re("ItemBarAction"):FireServer(payload)
end

local function send_item_bar(payload)
    REUtil:get_re("ItemBarAction"):FireServer(payload)
end

local function get_eui_manager()
    local player = Players.LocalPlayer
    local eui = player and player.PlayerGui and player.PlayerGui.EuiManager or nil
    if not eui and type(GameUI.get_eui_manager) == "function" then
        eui = GameUI:get_eui_manager()
    end
    return eui
end

local function create_scene_node_at(position, name)
    local eui = get_eui_manager()
    if not eui then error("场景节点创建时 EUI 未就绪", 2) end
    local node = eui:CreateSceneNodeAtPosition(position)
    node.Name = name
    return node
end

local function create_anchor_scene_node(entry, height, kind)
    local anchor = entry.name and World:FindFirstChild(entry.name, true) or nil
    if kind == "shop" and anchor and type(GameUI.create_scene_node) == "function" then
        local ok, node = pcall(GameUI.create_scene_node, GameUI,
            GameCfg.Shop.BubblePreset, anchor, Vector3.New(0, height, 0))
        if ok and node then
            return node
        end
        print("[client.main] 商店预设气泡创建失败，回退坐标节点", tostring(entry.name), tostring(node))
    end
    local eui = get_eui_manager()
    local center = entry.position or (anchor and anchor.Position)
    if not eui or not center then return nil end
    return eui:CreateSceneNodeAtPosition(Vector3.New(center.x, center.y + height, center.z))
end

local function open_platform_shop()
    client_store_writer:open_modal("platform")
    REUtil:get_re("PlatformAction"):FireServer({ action = "OpenCoinShop" })
    return true
end

Task:Spawn(function()
    local waited = 0
    local ui_root = GameUI:get_ui_root()
    while not ui_root and waited < 30 do
        Task:Wait(0.05)
        waited = waited + 0.05
        ui_root = GameUI:get_ui_root()
    end
    if ui_root then
        _G.PlatformShop = { open = open_platform_shop }
        RootView.mount(ui_root, client_store, {
            services = {
                open_modal = function(id, payload) client_store_writer:open_modal(id, payload) end,
                close_modal = function(id) client_store_writer:close_modal(id) end,
                set_overlay = function(id, active) client_store_writer:set_overlay(id, active) end,
                send_lottery = function(payload) REUtil:get_re("LotteryAction"):FireServer(payload) end,
                send_blindbox = function(payload) REUtil:get_re("BlindboxAction"):FireServer(payload) end,
                send_platform = function(payload) REUtil:get_re("PlatformAction"):FireServer(payload) end,
                send_story = function(payload) REUtil:get_re("StoryRead"):FireServer(payload) end,
                send_survival = function(payload) REUtil:get_re("SurvivalAction"):FireServer(payload) end,
                send_reel = function(payload) REUtil:get_re("ReelInRE"):FireServer(payload) end,
                send_close = function(payload) REUtil:get_re("CloseReelIn"):FireServer(payload) end,
                send_gm = send_gm,
                request_compendium = function()
                    compendium_seq = compendium_seq + 1
                    REUtil:get_re("CompendiumRequest"):FireServer({ seq = compendium_seq })
                end,
                request_records = function(fishId)
                    records_seq = records_seq + 1
                    REUtil:get_re("RecordsRequest"):FireServer({ fishId = fishId, seq = records_seq })
                end,
                request_blindbox_state = function() REUtil:get_re("BlindboxStateRequest"):FireServer() end,
                local_character = function()
                    return Players.LocalPlayer and Players.LocalPlayer.Character or nil
                end,
                find_lottery_anchor = function(name) return Util:wait_for_child(World, name) end,
                create_lottery_scene_node = function(preset, anchor, offset)
                    return GameUI:create_scene_node(preset, anchor, offset)
                end,
                hud_entry_rect = function(name)
                    local eui = get_eui_manager()
                    local resolution = eui and eui:GetDeviceResolution() or { x = 1920, y = 1080 }
                    return MainHudLayout.compute({ width = resolution.x, height = resolution.y }).Rects[name]
                end,
                send_ferry = function(payload)
                    REUtil:get_re("FerryAction"):FireServer(payload)
                end,
                create_scene_node_at = create_scene_node_at,
                create_anchor_scene_node = create_anchor_scene_node,
                get_device_resolution = function()
                    local eui = get_eui_manager()
                    return eui and eui:GetDeviceResolution() or { x = 1920, y = 1080 }
                end,
                send_grill = function(payload)
                    if type(payload) ~= "table" then return end
                    local body = {}
                    for k, v in pairs(payload) do body[k] = v end
                    if not is_positive_int(body.seq) then
                        body.seq = next_action_seq()
                    end
                    REUtil:get_re("GrillAction"):FireServer(body)
                end,
                next_seq = next_action_seq,
                send_party = function(payload)
                    REUtil:get_re("PartyAction"):FireServer(payload)
                end,
                send_shop = function(payload)
                    REUtil:get_re("ShopAction"):FireServer(payload)
                end,
                send_interact = function(payload)
                    REUtil:get_re("InteractAction"):FireServer(payload)
                end,
                open_platform_shop = open_platform_shop,
                send_weapon = function(payload)
                    local event = REUtil:get_re("WeaponAction")
                    if event and type(event.FireServer) == "function" then
                        event:FireServer(payload)
                    end
                end,
                notify = function(text) client_store_writer:show_notice(text) end,
                aim_direction = function()
                    local payload = WeaponAim:attack_payload()
                    return payload and payload.aim or nil
                end,
                grill_shared = grill_shared,
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
                            local unit = Util:wait_for_child(World, npc.AnchorNames[1])
                            if unit and unit.Scale then rows[index] = { unit = unit, baseScale = unit.Scale } end
                        end
                        return rows
                    end)(),
                }),
                FishermanView.rescue_driver_spec(rescue_view_state),
                SquadView.hud_spec(),
                SquadView.rescue_driver_spec(squad_rescue_view_state),
                GroundLootView.aim_toggle_spec(),
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
                lottery = LotteryView.modal_spec(),
                blindbox = BlindboxView.modal_spec(),
                platform = PlatformShopView.modal_spec(),
                compendium = CompendiumView.modal_spec(),
                story = StoryView.modal_spec(),
                gm = GMView.modal_spec(),
            },
            overlays = {
                lottery_interaction = LotteryInteraction.spec(),
                survival = SurvivalOverlayView.spec(),
                aim_pickup = GroundLootView.aim_spec({
                    on_pick = function()
                        local id = GroundLootView.pick_nearest(client_store)
                        if id ~= nil then
                            send_item_bar({ action = "Pickup", value = id })
                        end
                        client_store_writer:set_overlay("aim_pickup", false)
                    end,
                }),
                reel = ReelOverlayView.spec({ controller = hud_reel }),
            },
            docks = {
                shop = ShopView.bubble_spec({ anchors = (function()
                    local rows = {}
                    for _, stand in ipairs(GameCfg.Shop.Stands) do
                        local anchor = Util:wait_for_child(World, stand.AnchorName)
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
                            local anchor = Util:wait_for_child(World, name)
                            if anchor then rows[#rows + 1] = {
                                npc = npc, name = name, index = index, position = anchor.Position,
                            } end
                        end
                    end
                    return rows
                end)() }),
                grill = GrillView.bubble_spec({ shared = grill_shared, anchors = (function()
                    local rows = {}
                    for index, point in ipairs(GameCfg.Grill.Points or {}) do
                        local anchor = Util:wait_for_child(World, point.AnchorName)
                        if anchor then rows[#rows + 1] = {
                            point = point, index = index, name = point.AnchorName, position = anchor.Position,
                        } end
                    end
                    return rows
                end)() }),
                rescue = FishermanView.rescue_bubble_spec(rescue_view_state),
                squad_members = SquadView.member_spec(),
                squad_rescue = SquadView.rescue_bubble_spec(squad_rescue_view_state),
                ground_loot = GroundLootView.bubble_spec({
                    send = send_item_bar,
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
pcall(function() StarterGui:SetCoreGuiEnabled(Enums.CoreGuiType.LiftButton, false) end) -- 兼容部分宿主环境未开放 CoreGui 隐藏接口
pcall(function() StarterGui:SetCoreGuiEnabled(Enums.CoreGuiType.Health, false) end) -- 兼容部分宿主环境未开放 CoreGui 隐藏接口

local AbilityAPI = require("client.packages.ability_system.api")
if AbilityAPI then
    AbilityAPI.StartClientLifecycle()
end

REUtil:get_re("RequestLoot"):FireServer()
REUtil:get_re("RequestQuest"):FireServer()
REUtil:get_re("RequestStory"):FireServer()
