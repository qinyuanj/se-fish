local RunService = game:GetService("RunService")
local Players = game:GetService("Players")
local WorldService = game:GetService("World")
local REUtil = require("common.re_util")
require("common.util")
require("common.teleport_util")
local ZoneMarkers = require("common.zone_markers")
ZoneMarkers.start()
local Number = require("common.number")
local GameCfg = require("common.game_cfg")
local AbilityAPI = require("server.ability_api")
local ServerRuntime = require("server.world_host.server_runtime")
local PlayerDataHost = require("server.player_data_host")
local SaveHost = require("server.save_host")
local PlatformHost = require("server.platform_host")
local FishCarrier = require("server.world_host.fish_carrier")
local FishAi = require("server.world_host.fish_ai")
local FishAbility = require("server.fish_ability")
local InteractionPoints = require("server.world_host.interaction_points")
local AttrLeaf = require("server.world_host.attr_leaf")
local WorldRuntime

local function serverNow()
    local ok, now = pcall(WorldService.GetServerTime, WorldService)
    if ok and Number.is_finite_number(now) then return now end
    print("[server.main] 读取宿主时钟失败", tostring(now)); return nil
end

local AttrPackageApi = require("server.packages.attr_rule.api")
local ModifierPackageApi = require("server.packages.modifier_system.api")
local AbilityPackageApi = require("server.packages.ability_system.api")

local activeCastGuards = {}
local function registerCastGuard(guard)
    activeCastGuards[guard] = true
    return function()
        activeCastGuards[guard] = nil
    end
end
if type(AbilityAPI.add_cast_guard) == "function" then
    AbilityAPI.add_cast_guard(function(unit, abilityIndex)
        for guard in pairs(activeCastGuards) do
            if guard(unit, abilityIndex) ~= true then return false end
        end
        return true
    end)
end

local function applyDotHit(target, damage, source)
    local life = WorldRuntime and WorldRuntime.life
    if life then
        life:apply_hit(life:new_hit(source, "dot"), target, damage)
    end
end

local function attrTree(player)
    if not player or not WorldRuntime then return nil end
    local tree = WorldRuntime:get_player_tree(player.UserId)
    if tree then PlayerDataHost:sync_player_tree(player) end
    return tree
end

local AttrBridge = {}
function AttrBridge:capture_base_speed(player)
    local tree = attrTree(player)
    return tree and tree:capture_base_speed() or nil
end
function AttrBridge:body_plan(player)
    local tree = attrTree(player)
    if not tree then return nil, "no-player-tree" end
    return tree.memos.attr_plan:now().body
end
function AttrBridge:max_health(player)
    local tree = attrTree(player)
    return tree and tree.memos.max_health:now() or GameCfg.Vitals.MaxHealth
end
function AttrBridge:refresh_max_health(player)
    local tree = attrTree(player)
    if not tree then return false, "no-player-tree" end
    local cap = tree.memos.max_health:now()
    if not Number.is_finite_number(cap) or cap < 1 then return false, "bad-max" end
    cap = math.floor(cap)
    local character = tree.states.character:now()
    local controller = character and character.Controller
    if not controller then return false, "no-controller" end
    local ok, err = pcall(function()
        controller.MaxHealth = cap
        if type(controller.Health) == "number" and controller.Health > cap then controller.Health = cap end
    end)
    if not ok then return false, tostring(err) end
    local current = tree.states.health:now()
    if WorldRuntime.life and Number.is_finite_number(current) and current > cap then
        WorldRuntime.life:set_health(player, cap)
    end
    return true
end
function AttrBridge:refresh_move_speed(player)
    local tree = attrTree(player)
    if not tree then return false, "no-player-tree" end
    return AttrLeaf.apply_walk_speed(tree.states.character:now(), tree.memos.walk_speed:now())
end
function AttrBridge:apply_body_scale(player)
    local tree = attrTree(player)
    if not tree then return { Ok = false, Error = "no-player-tree" } end
    local character = tree.states.character:now()
    if not character then return { Ok = false, Error = "no-character" } end
    local scale = tree.memos.body_scale:now()
    local capped = tree.memos.body_scale_capped:now()
    local ok, derivedOrErr = AttrLeaf.apply_body_presentation(character, scale, capped)
    return {
        Ok = ok,
        Error = not ok and tostring(derivedOrErr) or nil,
        Scale = scale,
        Health = tree.memos.max_health:now(),
        capped = capped,
        derived = ok and derivedOrErr or tree.memos.body_derived:now(),
    }
end
function AttrBridge:apply_growth(player)
    local applied = self:apply_body_scale(player)
    local errors = {}
    if not applied.Ok then errors[#errors + 1] = tostring(applied.Error) end
    local okHealth, healthErr = self:refresh_max_health(player)
    if not okHealth then errors[#errors + 1] = "MaxHealth:" .. tostring(healthErr) end
    local okSpeed, speedErr = self:refresh_move_speed(player)
    if not okSpeed then errors[#errors + 1] = tostring(speedErr) end
    applied.Ok = #errors == 0
    if not applied.Ok then applied.Error = table.concat(errors, "; ") end
    return applied
end
FishAbility.attr = AttrBridge

local function bindRE(name, cooldown, handler, requireTable)
    _G.REUtil:get_re(name).OnServerEvent:Connect(function(player, payload)
        if requireTable and type(payload) ~= "table" then return end
        if cooldown and _G.REUtil:check_recd(player, name, cooldown) then return end
        handler(player, payload)
    end)
end

WorldRuntime = ServerRuntime.new({
    initial_now = serverNow(),
    remote = _G.REUtil,
    player_data = PlayerDataHost,
    save = SaveHost,
    platform = PlatformHost,
    interact = InteractionPoints,
    fish_ability = FishAbility,
    fish_ai = FishAi,
    ability_api = AbilityAPI,
    fish_carrier = FishCarrier,
    random = math.random,
    delivery_epoch = tostring({}),
    lottery_in_range = function(player)
        local cfg = GameCfg.Lottery
        return InteractionPoints:in_range(player, {
            AnchorNames = cfg.machine_anchors(), Radius = cfg.Radius, Slack = cfg.Slack,
        })
    end,
    fish_units = function()
        return WorldRuntime and WorldRuntime.fish_host.Fish or {}
    end,
    physics = game:GetService("PhysicsService"),
    players_service = Players,
    world_service = WorldService,
    zone_markers = ZoneMarkers,
    bind_weapon_action = function(dispatch)
        bindRE("WeaponAction", GameCfg.Ability.GunShared.ActionCooldownSec, dispatch)
    end,
    bind_party_action = function(dispatch)
        bindRE("PartyAction", GameCfg.Party.ActionCooldownSec, dispatch)
    end,
    bind_party_state_request = function(dispatch)
        bindRE("PartyStateRequest", GameCfg.Party.StateCooldownSec, dispatch)
    end,
    bind_ferry_action = function(dispatch)
        bindRE("FerryAction", GameCfg.Items.ActionCooldownSec, dispatch, true)
    end,
    bind_grill_action = function(dispatch)
        bindRE("GrillAction", GameCfg.Items.ActionCooldownSec, dispatch, true)
    end,
    bind_shop_action = function(dispatch)
        bindRE("ShopAction", GameCfg.Items.ActionCooldownSec, dispatch)
    end,
    bind_interact_action = function(dispatch)
        bindRE("InteractAction", GameCfg.Items.ActionCooldownSec, dispatch)
    end,
    bind_survival_action = function(dispatch)
        bindRE("SurvivalAction", GameCfg.Items.ActionCooldownSec, dispatch, true)
    end,
    bind_special_item_action = function(onAction, onQuery)
        bindRE("SpecialItemAction", nil, onAction, true)
        bindRE("SpecialItemStateRequest", nil, onQuery)
    end,
    bind_loot_request = function(dispatch)
        bindRE("RequestLoot", GameCfg.Items.ActionCooldownSec, dispatch)
    end,
    bind_item_bar_action = false,
    bind_lottery_action = function(dispatch)
        bindRE("LotteryAction", GameCfg.Lottery.ActionCooldownSec, dispatch)
        bindRE("LotteryStateRequest", GameCfg.Lottery.ActionCooldownSec, function(player)
            if WorldRuntime then WorldRuntime:lottery_state(player) end
        end)
    end,
    bind_blindbox_action = function(dispatch)
        bindRE("BlindboxAction", GameCfg.Blindbox.ActionCooldownSec, dispatch)
        bindRE("BlindboxStateRequest", GameCfg.Blindbox.ActionCooldownSec, function(player)
            if WorldRuntime then WorldRuntime:blindbox_state(player) end
        end)
    end,
    bind_cast_action = function(dispatch)
        bindRE("CastAction", GameCfg.Items.ActionCooldownSec, dispatch, true)
        bindRE("RequestCastState", GameCfg.Items.ActionCooldownSec, function(player)
            dispatch(player, { action = "Request" })
        end)
    end,
    bind_reel_action = function(dispatch)
        bindRE("ReelInRE", GameCfg.Items.ActionCooldownSec, function(player, payload)
            dispatch(player, "click", payload)
        end, true)
        bindRE("CloseReelIn", GameCfg.Items.ActionCooldownSec, function(player, payload)
            dispatch(player, "close", payload)
        end, true)
    end,
    ability = { cast_ability = AbilityAPI.cast_ability },
    register_cast_guard = registerCastGuard,
    create_unit = function(unit_type, props)
        return WorldService:CreateUnit(unit_type, props)
    end,
    ai = {
        start = function(_, fish_id)
            local host = WorldRuntime and WorldRuntime.fish_host
            local fish = host and host.Fish[fish_id]
            if not fish then return false end
            return FishAi:attach(fish) == true
        end,
        stop = function(_, fish_id)
            local host = WorldRuntime and WorldRuntime.fish_host
            local fish = host and host.Fish[fish_id]
            if fish then FishAi:remove(fish) end
            return true
        end,
        command = function(_, fish, ...)
            return FishAi:command(fish, ...)
        end,
    },
    on_item_bar_state = function(player, snapshot)
        _G.REUtil:get_re('ItemBarState'):FireClient(player, snapshot)
    end,
    player_effects = {
        on_dot_tick = function(pt, _kind, damage, source)
            applyDotHit(pt.player, damage, source)
        end,
    },
    attr_leaf = { attr_api = AttrPackageApi },
    modifier_leaf = { modifier_api = ModifierPackageApi },
    ability_leaf = {
        ability_api = AbilityPackageApi,
        attach_anchor = AbilityAPI.attach_anchor,
        register_cast_guard = registerCastGuard,
    },
    entity_modifiers = {
        modifier_api = ModifierPackageApi,
        on_dot_tick = function(target, _kind, damage, source)
            local ref = type(target) == "table" and target.ref or target
            applyDotHit(ref, damage, source)
        end,
    },
})
ServerRuntime.set_current(WorldRuntime)
local fishHost = WorldRuntime.fish_host
fishHost.Vitals = WorldRuntime.life
fishHost.ai = FishAi
FishAi.FishUnit = fishHost
FishCarrier.damage_listener = function(carrier, actual, hit)
    local fish = carrier and fishHost:find_by_carrier(carrier)
    local attacker = hit and hit.sourcePlayer
    if fish and attacker then fishHost:note_damage(fish, attacker, actual) end
end
fishHost:start()

local function HandlePlayerAdded(player)
    WorldRuntime:on_player_added(player)
end

local function HandlePlayerRemoving(player)
    WorldRuntime:on_player_removing(player)
end
local function HandleTimeUpdate(deltaTime)
    local now = serverNow()
    if now == nil then WorldRuntime:step(deltaTime) else WorldRuntime:step(deltaTime, now) end
end

Players.PlayerAdded:Connect(HandlePlayerAdded)
Players.PlayerRemoving:Connect(HandlePlayerRemoving)
for _, player in pairs(Players:GetPlayers()) do
    HandlePlayerAdded(player)
end

WorldRuntime:start()
WorldRuntime:mark_started()
RunService.Heartbeat:Connect(HandleTimeUpdate)

return WorldRuntime
