local RunService = game:GetService("RunService")
local Players = game:GetService("Players")
local WorldService = game:GetService("World")
local re_util = require("common.re_util")
require("common.util")
require("common.teleport_util")
local zone_markers = require("common.zone_markers")
zone_markers.Start()
local number = require("common.number")
local game_cfg = require("common.game_cfg")
local ability_api = require("server.ability_api")
local server_runtime = require("server.world_host.server_runtime")
local player_data_host = require("server.player_data_host")
local save_host = require("server.save_host")
local platform_host = require("server.platform_host")
local fish_carrier = require("server.world_host.fish_carrier")
local fish_ai = require("server.world_host.fish_ai")
local fish_ability = require("server.fish_ability")
local interaction_points = require("server.world_host.interaction_points")
local attr_leaf = require("server.world_host.attr_leaf")
local WorldRuntime

local function serverNow()
    local ok, now = pcall(WorldService.GetServerTime, WorldService) -- 引擎早期阶段可能未就绪
    if ok and number.IsFiniteNumber(now) then return now end
    return nil
end

local attr_package_api = require("server.packages.attr_rule.api")
local modifier_package_api = require("server.packages.modifier_system.api")
local ability_package_api = require("server.packages.ability_system.api")

local activeCastGuards = {}
local function registerCastGuard(guard)
    activeCastGuards[guard] = true
    return function()
        activeCastGuards[guard] = nil
    end
end
if type(ability_api.AddCastGuard) == "function" then
    ability_api.AddCastGuard(function(unit, abilityIndex)
        for guard in pairs(activeCastGuards) do
            if guard(unit, abilityIndex) ~= true then return false end
        end
        return true
    end)
end

local function applyDotHit(target, damage, source)
    local life = WorldRuntime and WorldRuntime.life
    if life then
        life:ApplyHit(life:NewHit(source, "dot"), target, damage)
    end
end

local function attrTree(player)
    if not player or not WorldRuntime then return nil end
    local tree = WorldRuntime:get_player_tree(player.UserId)
    if tree then player_data_host:SyncPlayerTree(player) end
    return tree
end

local AttrBridge = {}
function AttrBridge:CaptureBaseSpeed(player)
    local tree = attrTree(player)
    return tree and tree:capture_base_speed() or nil
end
function AttrBridge:BodyPlan(player)
    local tree = attrTree(player)
    if not tree then return nil, "no-player-tree" end
    return tree.memos.attr_plan:now().Body
end
function AttrBridge:MaxHealth(player)
    local tree = attrTree(player)
    return tree and tree.memos.max_health:now() or game_cfg.vitals.MaxHealth
end
function AttrBridge:RefreshMaxHealth(player)
    local tree = attrTree(player)
    if not tree then return false, "no-player-tree" end
    local cap = tree.memos.max_health:now()
    if not number.IsFiniteNumber(cap) or cap < 1 then return false, "bad-max" end
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
    if WorldRuntime.life and number.IsFiniteNumber(current) and current > cap then
        WorldRuntime.life:SetHealth(player, cap)
    end
    return true
end
function AttrBridge:RefreshMoveSpeed(player)
    local tree = attrTree(player)
    if not tree then return false, "no-player-tree" end
    return attr_leaf.apply_walk_speed(tree.states.character:now(), tree.memos.walk_speed:now())
end
function AttrBridge:ApplyBodyScale(player)
    local tree = attrTree(player)
    if not tree then return { Ok = false, Error = "no-player-tree" } end
    local character = tree.states.character:now()
    if not character then return { Ok = false, Error = "no-character" } end
    local scale = tree.memos.body_scale:now()
    local capped = tree.memos.body_scale_capped:now()
    local ok, derivedOrErr = attr_leaf.apply_body_presentation(character, scale, capped)
    return {
        Ok = ok,
        Error = not ok and tostring(derivedOrErr) or nil,
        Scale = scale,
        Health = tree.memos.max_health:now(),
        Capped = capped,
        Derived = ok and derivedOrErr or tree.memos.body_derived:now(),
    }
end
function AttrBridge:ApplyGrowth(player)
    local applied = self:ApplyBodyScale(player)
    local errors = {}
    if not applied.Ok then errors[#errors + 1] = tostring(applied.Error) end
    local okHealth, healthErr = self:RefreshMaxHealth(player)
    if not okHealth then errors[#errors + 1] = "MaxHealth:" .. tostring(healthErr) end
    local okSpeed, speedErr = self:RefreshMoveSpeed(player)
    if not okSpeed then errors[#errors + 1] = tostring(speedErr) end
    applied.Ok = #errors == 0
    if not applied.Ok then applied.Error = table.concat(errors, "; ") end
    return applied
end
fish_ability.Attr = AttrBridge

local function bindRE(name, cooldown, handler, requireTable)
    _G.re_util:GetRE(name).OnServerEvent:Connect(function(player, payload)
        if requireTable and type(payload) ~= "table" then return end
        if cooldown and _G.re_util:CheckRECD(player, name, cooldown) then return end
        handler(player, payload)
    end)
end

WorldRuntime = server_runtime.new({
    initial_now = serverNow() or 0,
    remote = _G.re_util,
    player_data = player_data_host,
    save = save_host,
    platform = platform_host,
    interact = interaction_points,
    fish_ability = fish_ability,
    fish_ai = fish_ai,
    ability_api = ability_api,
    fish_carrier = fish_carrier,
    random = math.random,
    delivery_epoch = tostring({}),
    lottery_in_range = function(player)
        local cfg = game_cfg.Lottery
        return interaction_points:InRange(player, {
            AnchorNames = cfg.MachineAnchors(), Radius = cfg.Radius, Slack = cfg.Slack,
        })
    end,
    fish_units = function()
        return WorldRuntime and WorldRuntime.fish_host.Fish or {}
    end,
    physics = game:GetService("PhysicsService"),
    players_service = Players,
    world_service = WorldService,
    zone_markers = zone_markers,
    bind_weapon_action = function(dispatch)
        bindRE("WeaponAction", game_cfg.Ability.GunShared.ActionCooldownSec, dispatch)
    end,
    bind_party_action = function(dispatch)
        bindRE("PartyAction", game_cfg.Party.ActionCooldownSec, dispatch)
    end,
    bind_party_state_request = function(dispatch)
        bindRE("PartyStateRequest", game_cfg.Party.StateCooldownSec, dispatch)
    end,
    bind_ferry_action = function(dispatch)
        bindRE("FerryAction", game_cfg.Items.ActionCooldownSec, dispatch, true)
    end,
    bind_grill_action = function(dispatch)
        bindRE("GrillAction", game_cfg.Items.ActionCooldownSec, dispatch, true)
    end,
    bind_shop_action = function(dispatch)
        bindRE("ShopAction", game_cfg.Items.ActionCooldownSec, dispatch)
    end,
    bind_interact_action = function(dispatch)
        bindRE("InteractAction", game_cfg.Items.ActionCooldownSec, dispatch)
    end,
    bind_survival_action = function(dispatch)
        bindRE("SurvivalAction", game_cfg.Items.ActionCooldownSec, dispatch, true)
    end,
    bind_special_item_action = function(onAction, onQuery)
        bindRE("SpecialItemAction", nil, onAction, true)
        bindRE("SpecialItemStateRequest", nil, onQuery)
    end,
    bind_loot_request = function(dispatch)
        bindRE("RequestLoot", game_cfg.Items.ActionCooldownSec, dispatch)
    end,
    bind_item_bar_action = false,
    bind_lottery_action = function(dispatch)
        bindRE("LotteryAction", game_cfg.Lottery.ActionCooldownSec, dispatch)
        bindRE("LotteryStateRequest", game_cfg.Lottery.ActionCooldownSec, function(player)
            if WorldRuntime then WorldRuntime:lottery_state(player) end
        end)
    end,
    bind_blindbox_action = function(dispatch)
        bindRE("BlindboxAction", game_cfg.Blindbox.ActionCooldownSec, dispatch)
        bindRE("BlindboxStateRequest", game_cfg.Blindbox.ActionCooldownSec, function(player)
            if WorldRuntime then WorldRuntime:blindbox_state(player) end
        end)
    end,
    bind_cast_action = function(dispatch)
        bindRE("CastAction", game_cfg.Items.ActionCooldownSec, dispatch, true)
        bindRE("RequestCastState", game_cfg.Items.ActionCooldownSec, function(player)
            dispatch(player, { action = "Request" })
        end)
    end,
    bind_reel_action = function(dispatch)
        bindRE("ReelInRE", game_cfg.Items.ActionCooldownSec, function(player, payload)
            dispatch(player, "click", payload)
        end, true)
        bindRE("CloseReelIn", game_cfg.Items.ActionCooldownSec, function(player, payload)
            dispatch(player, "close", payload)
        end, true)
    end,
    ability = { CastAbility = ability_api.CastAbility },
    register_cast_guard = registerCastGuard,
    create_unit = function(unit_type, props)
        return WorldService:CreateUnit(unit_type, props)
    end,
    ai = {
        start = function(_, fish_id)
            local host = WorldRuntime and WorldRuntime.fish_host
            local fish = host and host.Fish[fish_id]
            if not fish then return false end
            return fish_ai:Attach(fish) == true
        end,
        stop = function(_, fish_id)
            local host = WorldRuntime and WorldRuntime.fish_host
            local fish = host and host.Fish[fish_id]
            if fish then fish_ai:Remove(fish) end
            return true
        end,
        command = function(_, fish, ...)
            return fish_ai:Command(fish, ...)
        end,
    },
    on_item_bar_state = function(player, snapshot)
        _G.re_util:GetRE('ItemBarState'):FireClient(player, snapshot)
    end,
    player_effects = {
        on_dot_tick = function(pt, _kind, damage, source)
            applyDotHit(pt.player, damage, source)
        end,
    },
    attr_leaf = { attr_api = attr_package_api },
    modifier_leaf = { modifier_api = modifier_package_api },
    ability_leaf = {
        ability_api = ability_package_api,
        attach_anchor = ability_api.AttachAnchor,
        register_cast_guard = registerCastGuard,
    },
    entity_modifiers = {
        modifier_api = modifier_package_api,
        on_dot_tick = function(target, _kind, damage, source)
            local ref = type(target) == "table" and target.Ref or target
            applyDotHit(ref, damage, source)
        end,
    },
})
server_runtime.set_current(WorldRuntime)
local fishHost = WorldRuntime.fish_host
fishHost.vitals = WorldRuntime.life
fishHost.Ai = fish_ai
fish_ai.FishUnit = fishHost
fish_carrier.DamageListener = function(carrier, actual, hit)
    local fish = carrier and fishHost:FindByCarrier(carrier)
    local attacker = hit and hit.sourcePlayer
    if fish and attacker then fishHost:NoteDamage(fish, attacker, actual) end
end
fishHost:Start()

local function HandlePlayerAdded(player)
    WorldRuntime:on_player_added(player)
end

local function HandlePlayerRemoving(player)
    WorldRuntime:on_player_removing(player)
end

local function HandleTimeUpdate(deltaTime)
    WorldRuntime:step(deltaTime, serverNow())
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
