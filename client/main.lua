local zone_markers = require("common.zone_markers")
zone_markers.Start()

local number = require("common.number")
local game_cfg = require("common.game_cfg")
local spoke_clock = require("common.spoke_clock")
local spoke = require("common.packages.spoke.api")
local client_store = require("client.store.client_store")
local root_view = require("client.views.root_view")
local camera_zoom_view = require("client.views.camera_zoom_view")
local main_hud_vitals_view = require("client.views.main_hud_vitals_view")
local main_hud_equip_popups = require("client.views.main_hud_equip_popups")
local main_hud_backpack_view = require("client.views.main_hud_backpack_view")
local main_hud_item_bar_view = require("client.views.main_hud_item_bar_view")
local main_hud_action_buttons_view = require("client.views.main_hud_action_buttons_view")
local attack_view = require("client.views.attack_view")
local weapon_aim = require("client.weapon_aim")
local survival_overlay_view = require("client.views.survival_overlay_view")
local ground_loot_view = require("client.views.ground_loot_view")
local fish_combat_view = require("client.views.fish_combat_view")
local grill_view = require("client.views.grill_view")
local lottery_view = require("client.views.lottery_view")
local blindbox_view = require("client.views.blindbox_view")
local platform_shop_view = require("client.views.platform_shop_view")
local lottery_interaction = require("client.views.lottery_interaction")
local main_hud_layout = require("client.main_hud_layout")
local util = require("common.util")
local ferry_view = require("client.views.ferry_view")
local reel_overlay_view = require("client.views.reel_overlay_view")
local cast_source_view = require("client.views.cast_source_view")
local shop_view = require("client.views.shop_view")
local fisherman_view = require("client.views.fisherman_view")
local compendium_view = require("client.views.compendium_view")
local guide_view = require("client.views.guide_view")
local message_view = require("client.views.message_view")
local story_view = require("client.views.story_view")
local gm_view = require("client.views.gm_view")
local squad_view = require("client.views.squad_view")
local re_util = require("common.re_util")
local game_ui = require("client.game_ui")

local Task = game:GetService("Task")
local World = game:GetService("World")
local Players = game:GetService("Players")

-- 客户端 Spoke 响应式主干（ADR-0032 / #296）：
local ok_now, initial_now = pcall(function() return World:GetServerTime() end) -- 启动瞬间宿主时钟可能未就绪，异常时安全回退 0
local client_clock = spoke_clock.new(ok_now and number.IsFiniteNumber(initial_now) and initial_now or 0)
local client_store, client_store_writer = client_store.new({ clock = client_clock })
client_store_writer:bind_host()
_G.LocalMsgNotice = function(text) client_store_writer:show_notice(text) end
local function send_gm(payload) re_util:GetRE("GMAction"):FireServer(payload) end
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
local grill_shared = grill_view.new_shared()
local rescue_view_state = fisherman_view.rescue_state({
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
local squad_rescue_view_state = squad_view.rescue_state({
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
    return number.IsFiniteNumber(value) and value >= 1 and value == math.floor(value)
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
    re_util:GetRE("ItemBarAction"):FireServer(payload)
end

local function send_item_bar(payload)
    re_util:GetRE("ItemBarAction"):FireServer(payload)
end

local function get_eui_manager()
    local player = Players.LocalPlayer
    local eui = player and player.PlayerGui and player.PlayerGui.EuiManager or nil
    if not eui and type(game_ui.GetEuiManager) == "function" then
        eui = game_ui:GetEuiManager()
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
    if kind == "shop" and anchor and type(game_ui.CreateSceneNode) == "function" then
        local ok, node = pcall(game_ui.CreateSceneNode, game_ui,
            game_cfg.Shop.BubblePreset, anchor, Vector3.New(0, height, 0))
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
    re_util:GetRE("PlatformAction"):FireServer({ action = "OpenCoinShop" })
    return true
end

Task:Spawn(function()
    local waited = 0
    local ui_root = game_ui:GetUIRoot()
    while not ui_root and waited < 30 do
        Task:Wait(0.05)
        waited = waited + 0.05
        ui_root = game_ui:GetUIRoot()
    end
    if ui_root then
        _G.PlatformShop = { Open = open_platform_shop }
        root_view.mount(ui_root, client_store, {
            services = {
                open_modal = function(id, payload) client_store_writer:open_modal(id, payload) end,
                close_modal = function(id) client_store_writer:close_modal(id) end,
                set_overlay = function(id, active) client_store_writer:set_overlay(id, active) end,
                send_lottery = function(payload) re_util:GetRE("LotteryAction"):FireServer(payload) end,
                send_blindbox = function(payload) re_util:GetRE("BlindboxAction"):FireServer(payload) end,
                send_platform = function(payload) re_util:GetRE("PlatformAction"):FireServer(payload) end,
                send_story = function(payload) re_util:GetRE("StoryRead"):FireServer(payload) end,
                send_survival = function(payload) re_util:GetRE("SurvivalAction"):FireServer(payload) end,
                send_reel = function(payload) re_util:GetRE("ReelInRE"):FireServer(payload) end,
                send_close = function(payload) re_util:GetRE("CloseReelIn"):FireServer(payload) end,
                send_gm = send_gm,
                request_compendium = function()
                    compendium_seq = compendium_seq + 1
                    re_util:GetRE("CompendiumRequest"):FireServer({ seq = compendium_seq })
                end,
                request_records = function(fishId)
                    records_seq = records_seq + 1
                    re_util:GetRE("RecordsRequest"):FireServer({ fishId = fishId, seq = records_seq })
                end,
                request_blindbox_state = function() re_util:GetRE("BlindboxStateRequest"):FireServer() end,
                local_character = function()
                    return Players.LocalPlayer and Players.LocalPlayer.Character or nil
                end,
                find_lottery_anchor = function(name) return util:WaitForChild(World, name) end,
                create_lottery_scene_node = function(preset, anchor, offset)
                    return game_ui:CreateSceneNode(preset, anchor, offset)
                end,
                hud_entry_rect = function(name)
                    local eui = get_eui_manager()
                    local resolution = eui and eui:GetDeviceResolution() or { x = 1920, y = 1080 }
                    return main_hud_layout.Compute({ width = resolution.x, height = resolution.y }).Rects[name]
                end,
                send_ferry = function(payload)
                    re_util:GetRE("FerryAction"):FireServer(payload)
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
                    re_util:GetRE("GrillAction"):FireServer(body)
                end,
                next_seq = next_action_seq,
                send_party = function(payload)
                    re_util:GetRE("PartyAction"):FireServer(payload)
                end,
                send_shop = function(payload)
                    re_util:GetRE("ShopAction"):FireServer(payload)
                end,
                send_interact = function(payload)
                    re_util:GetRE("InteractAction"):FireServer(payload)
                end,
                open_platform_shop = open_platform_shop,
                send_weapon = function(payload)
                    local event = re_util:GetRE("WeaponAction")
                    if event and type(event.FireServer) == "function" then
                        event:FireServer(payload)
                    end
                end,
                notify = function(text) client_store_writer:show_notice(text) end,
                aim_direction = function()
                    local payload = weapon_aim:AttackPayload()
                    return payload and payload.aim or nil
                end,
                grill_shared = grill_shared,
                reel = hud_reel,
            },
            create_node = function(kind, props)
                return World:CreateUnit(kind, props)
            end,
            hud = {
                camera_zoom_view.spec(),
                shop_view.presentation_spec(),
                fisherman_view.presentation_spec({
                    shared = fisherman_shared,
                    models = (function()
                        local rows = {}
                        for index, npc in ipairs(game_cfg.Interact.Fishermen) do
                            local unit = util:WaitForChild(World, npc.AnchorNames[1])
                            if unit and unit.Scale then rows[index] = { unit = unit, baseScale = unit.Scale } end
                        end
                        return rows
                    end)(),
                }),
                fisherman_view.rescue_driver_spec(rescue_view_state),
                squad_view.hud_spec(),
                squad_view.rescue_driver_spec(squad_rescue_view_state),
                ground_loot_view.aim_toggle_spec(),
                main_hud_vitals_view.spec(),
                main_hud_equip_popups.spec({
                    open_popup = hud_open_popup,
                    backpack_open = hud_backpack_open,
                    send_operate = send_hud_operate,
                }),
                main_hud_item_bar_view.spec({
                    backpack_open = hud_backpack_open,
                    resolve_drop_target = resolve_item_bar_drop,
                    on_drop_resolver = function(fn)
                        hud_drop_resolvers.item_bar = fn
                    end,
                }),
                attack_view.spec(),
                guide_view.spec(),
                message_view.spec(),
                compendium_view.entry_spec(),
                gm_view.entry_spec(),
                grill_view.spec(),
                blindbox_view.entry_spec(),
                platform_shop_view.entry_spec(),
                ferry_view.spec(),
                cast_source_view.spec(),
                main_hud_action_buttons_view.spec({
                    backpack_open = hud_backpack_open,
                    send_operate = send_hud_operate,
                    on_reel_click = function(session_id)
                        if type(hud_reel.click) == "function" then
                            hud_reel.click(session_id)
                        end
                    end,
                }),
                main_hud_backpack_view.spec({
                    backpack_open = hud_backpack_open,
                    open_popup = hud_open_popup,
                    resolve_drop_target = resolve_backpack_drop,
                    on_drop_resolver = function(fn)
                        hud_drop_resolvers.backpack = fn
                    end,
                }),
            },
            modals = {
                shop = shop_view.modal_spec(),
                fisherman = fisherman_view.modal_spec(),
                confirm = fisherman_view.confirm_modal_spec(),
                lottery = lottery_view.modal_spec(),
                blindbox = blindbox_view.modal_spec(),
                platform = platform_shop_view.modal_spec(),
                compendium = compendium_view.modal_spec(),
                story = story_view.modal_spec(),
                gm = gm_view.modal_spec(),
            },
            overlays = {
                lottery_interaction = lottery_interaction.spec(),
                survival = survival_overlay_view.spec(),
                aim_pickup = ground_loot_view.aim_spec({
                    on_pick = function()
                        local id = ground_loot_view.pick_nearest(client_store)
                        if id ~= nil then
                            send_item_bar({ action = "Pickup", value = id })
                        end
                        client_store_writer:set_overlay("aim_pickup", false)
                    end,
                }),
                reel = reel_overlay_view.spec({ controller = hud_reel }),
            },
            docks = {
                shop = shop_view.bubble_spec({ anchors = (function()
                    local rows = {}
                    for _, stand in ipairs(game_cfg.Shop.Stands) do
                        local anchor = util:WaitForChild(World, stand.AnchorName)
                        if anchor then rows[#rows + 1] = {
                            stand = stand, name = stand.AnchorName, position = anchor.Position,
                        } end
                    end
                    return rows
                end)() }),
                fisherman = fisherman_view.bubble_spec({ shared = fisherman_shared, anchors = (function()
                    local rows = {}
                    for index, npc in ipairs(game_cfg.Interact.Fishermen) do
                        for _, name in ipairs(npc.AnchorNames) do
                            local anchor = util:WaitForChild(World, name)
                            if anchor then rows[#rows + 1] = {
                                npc = npc, name = name, index = index, position = anchor.Position,
                            } end
                        end
                    end
                    return rows
                end)() }),
                grill = grill_view.bubble_spec({ shared = grill_shared, anchors = (function()
                    local rows = {}
                    for index, point in ipairs(game_cfg.Grill.Points or {}) do
                        local anchor = util:WaitForChild(World, point.AnchorName)
                        if anchor then rows[#rows + 1] = {
                            point = point, index = index, name = point.AnchorName, position = anchor.Position,
                        } end
                    end
                    return rows
                end)() }),
                rescue = fisherman_view.rescue_bubble_spec(rescue_view_state),
                squad_members = squad_view.member_spec(),
                squad_rescue = squad_view.rescue_bubble_spec(squad_rescue_view_state),
                ground_loot = ground_loot_view.bubble_spec({
                    send = send_item_bar,
                }),
                ferry = ferry_view.legs_spec(),
                fish_combat = fish_combat_view.bar_spec(),
                fish_warning = fish_combat_view.warning_spec(),
            },
        })
    else
        print("[client.main] 等待 EUI 根节点超时，跳过 Spoke 根视图树挂载")
    end
end)

local StarterGui = game:GetService("StarterGui")
pcall(function() StarterGui:SetCoreGuiEnabled(Enums.CoreGuiType.LiftButton, false) end) -- 兼容部分宿主环境未开放 CoreGui 隐藏接口
pcall(function() StarterGui:SetCoreGuiEnabled(Enums.CoreGuiType.Health, false) end) -- 兼容部分宿主环境未开放 CoreGui 隐藏接口

local ability_api = require("client.packages.ability_system.api")
if ability_api then
    ability_api.StartClientLifecycle()
end

re_util:GetRE("RequestLoot"):FireServer()
re_util:GetRE("RequestQuest"):FireServer()
re_util:GetRE("RequestStory"):FireServer()
