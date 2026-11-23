-- 服务端唯一 Spoke 宿主入口：引擎信号只在这里翻译，玩法生命期由 ServerRuntime 持有。
local RunService = game:GetService("RunService")
local Players = game:GetService("Players")
local WorldService = game:GetService("World")
local REUtil = require("common.REUtil")
require("common.Util")
require("common.TeleportUtil")
local ZoneMarkers = require("common.ZoneMarkers")
ZoneMarkers.Start()
local Number = require("common.Number")
local GameCfg = require("common.GameCfg")
local AbilityAPI = require("server.AbilityAPI")
local ServerRuntime = require("server.World.ServerRuntime")
local PlayerDataHost = require("server.PlayerDataHost")
local SaveHost = require("server.SaveHost")
local PlatformHost = require("server.PlatformHost")
local FishCarrier = require("server.World.FishCarrier")
local FishAi = require("server.World.FishAi")
local FishAbility = require("server.FishAbility")
local InteractionPoints = require("server.World.InteractionPoints")
local AttrLeaf = require("server.World.AttrLeaf")
local WorldRuntime

local function serverNow()
    local ok, now = pcall(WorldService.GetServerTime, WorldService) -- 引擎早期阶段可能未就绪
    if ok and Number.IsFiniteNumber(now) then return now end
    return nil
end

local attrPackageApi = require("server.packages.attr_rule.api")
local modifierPackageApi = require("server.packages.modifier_system.api")
local abilityPackageApi = require("server.packages.ability_system.api")

local activeCastGuards = {}
local function registerCastGuard(guard)
    activeCastGuards[guard] = true
    return function()
        activeCastGuards[guard] = nil
    end
end
if type(AbilityAPI.AddCastGuard) == "function" then
    AbilityAPI.AddCastGuard(function(unit, abilityIndex)
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

-- 属性适配器只在 L1 组合根存在：从 PlayerTree 读取派生值，经 AttrLeaf 单向投影到引擎角色。
local function attrTree(player)
    if not player or not WorldRuntime then return nil end
    local tree = WorldRuntime:get_player_tree(player.UserId)
    if tree then PlayerDataHost:SyncPlayerTree(player) end
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
    return tree and tree.memos.max_health:now() or GameCfg.Vitals.MaxHealth
end
function AttrBridge:RefreshMaxHealth(player)
    local tree = attrTree(player)
    if not tree then return false, "no-player-tree" end
    local cap = tree.memos.max_health:now()
    if not Number.IsFiniteNumber(cap) or cap < 1 then return false, "bad-max" end
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
    if WorldRuntime.life and Number.IsFiniteNumber(current) and current > cap then
        WorldRuntime.life:SetHealth(player, cap)
    end
    return true
end
function AttrBridge:RefreshMoveSpeed(player)
    local tree = attrTree(player)
    if not tree then return false, "no-player-tree" end
    return AttrLeaf.apply_walk_speed(tree.states.character:now(), tree.memos.walk_speed:now())
end
function AttrBridge:ApplyBodyScale(player)
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
FishAbility.Attr = AttrBridge

-- 服务端 Spoke 运行时主干：装配官方包叶子投影与宿主事件入口。
WorldRuntime = ServerRuntime.new({
    initial_now = serverNow() or 0,
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
        return InteractionPoints:InRange(player, {
            AnchorNames = cfg.MachineAnchors(), Radius = cfg.Radius, Slack = cfg.Slack,
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
        local event = _G.REUtil:GetRE("WeaponAction")
        event.OnServerEvent:Connect(function(player, payload)
            if _G.REUtil:CheckRECD(player, "WeaponAction", GameCfg.Ability.GunShared.ActionCooldownSec) then return end
            dispatch(player, payload)
        end)
    end,
    bind_party_action = function(dispatch)
        _G.REUtil:GetRE("PartyAction").OnServerEvent:Connect(function(player, payload)
            if _G.REUtil:CheckRECD(player, "PartyAction", GameCfg.Party.ActionCooldownSec) then return end
            dispatch(player, payload)
        end)
    end,
    bind_party_state_request = function(dispatch)
        _G.REUtil:GetRE("PartyStateRequest").OnServerEvent:Connect(function(player)
            if _G.REUtil:CheckRECD(player, "PartyStateRequest", GameCfg.Party.StateCooldownSec) then return end
            dispatch(player)
        end)
    end,
    bind_ferry_action = function(dispatch)
        _G.REUtil:GetRE("FerryAction").OnServerEvent:Connect(function(player, payload)
            if type(payload) ~= "table" then return end
            if _G.REUtil:CheckRECD(player, "FerryAction", GameCfg.Items.ActionCooldownSec) then return end
            dispatch(player, payload)
        end)
    end,
    bind_grill_action = function(dispatch)
        local event = _G.REUtil:GetRE("GrillAction")
        event.OnServerEvent:Connect(function(player, payload)
            if type(payload) ~= "table" then return end
            if _G.REUtil:CheckRECD(player, "GrillAction", GameCfg.Items.ActionCooldownSec) then return end
            dispatch(player, payload)
        end)
    end,
    bind_shop_action = function(dispatch)
        _G.REUtil:GetRE("ShopAction").OnServerEvent:Connect(function(player, payload)
            if _G.REUtil:CheckRECD(player, "ShopAction", GameCfg.Items.ActionCooldownSec) then return end
            dispatch(player, payload)
        end)
    end,
    bind_interact_action = function(dispatch)
        _G.REUtil:GetRE("InteractAction").OnServerEvent:Connect(function(player, payload)
            if _G.REUtil:CheckRECD(player, "InteractAction", GameCfg.Items.ActionCooldownSec) then return end
            dispatch(player, payload)
        end)
    end,
    bind_lottery_action = function(dispatch)
        _G.REUtil:GetRE("LotteryAction").OnServerEvent:Connect(function(player, payload)
            if _G.REUtil:CheckRECD(player, "LotteryAction", GameCfg.Lottery.ActionCooldownSec) then return end
            dispatch(player, payload)
        end)
        _G.REUtil:GetRE("LotteryStateRequest").OnServerEvent:Connect(function(player)
            if _G.REUtil:CheckRECD(player, "LotteryStateRequest", GameCfg.Lottery.ActionCooldownSec) then return end
            if WorldRuntime then WorldRuntime:lottery_state(player) end
        end)
    end,
    bind_blindbox_action = function(dispatch)
        _G.REUtil:GetRE("BlindboxAction").OnServerEvent:Connect(function(player, payload)
            if _G.REUtil:CheckRECD(player, "BlindboxAction", GameCfg.Blindbox.ActionCooldownSec) then return end
            dispatch(player, payload)
        end)
        _G.REUtil:GetRE("BlindboxStateRequest").OnServerEvent:Connect(function(player)
            if _G.REUtil:CheckRECD(player, "BlindboxStateRequest", GameCfg.Blindbox.ActionCooldownSec) then return end
            if WorldRuntime then WorldRuntime:blindbox_state(player) end
        end)
    end,
    bind_cast_action = function(dispatch)
        _G.REUtil:GetRE("CastAction").OnServerEvent:Connect(function(player, payload)
            if type(payload) ~= "table" then return end
            if _G.REUtil:CheckRECD(player, "CastAction", GameCfg.Items.ActionCooldownSec) then return end
            dispatch(player, payload)
        end)
        _G.REUtil:GetRE("RequestCastState").OnServerEvent:Connect(function(player)
            if _G.REUtil:CheckRECD(player, "RequestCastState", GameCfg.Items.ActionCooldownSec) then return end
            dispatch(player, { action = "Request" })
        end)
    end,
    bind_reel_action = function(dispatch)
        _G.REUtil:GetRE("ReelInRE").OnServerEvent:Connect(function(player, payload)
            if type(payload) ~= "table" then return end
            if _G.REUtil:CheckRECD(player, "ReelInRE", GameCfg.Items.ActionCooldownSec) then return end
            dispatch(player, "click", payload)
        end)
        _G.REUtil:GetRE("CloseReelIn").OnServerEvent:Connect(function(player, payload)
            if type(payload) ~= "table" then return end
            if _G.REUtil:CheckRECD(player, "CloseReelIn", GameCfg.Items.ActionCooldownSec) then return end
            dispatch(player, "close", payload)
        end)
    end,
    ability = { CastAbility = AbilityAPI.CastAbility },
    register_cast_guard = registerCastGuard,
    create_unit = function(unit_type, props)
        return WorldService:CreateUnit(unit_type, props)
    end,
    -- #309 官方 AI 叶子：注册/注销只沿 FishTree 公开宿主单向进入包适配层。
    ai = {
        start = function(_, fish_id)
            local host = WorldRuntime and WorldRuntime.fish_host
            local fish = host and host.Fish[fish_id]
            if not fish then return false end
            return FishAi:Attach(fish) == true
        end,
        stop = function(_, fish_id)
            local host = WorldRuntime and WorldRuntime.fish_host
            local fish = host and host.Fish[fish_id]
            if fish then FishAi:Remove(fish) end
            return true
        end,
        command = function(_, fish, ...)
            return FishAi:Command(fish, ...)
        end,
    },
    bait_spots = { Enabled = false },
    on_item_bar_state = function(player, snapshot)
        _G.REUtil:GetRE('ItemBarState'):FireClient(player, snapshot)
    end,
    player_effects = {
        on_dot_tick = function(pt, _kind, damage, source)
            applyDotHit(pt.player, damage, source)
        end,
    },
    attr_leaf = { attr_api = attrPackageApi },
    modifier_leaf = { modifier_api = modifierPackageApi },
    ability_leaf = {
        ability_api = abilityPackageApi,
        attach_anchor = AbilityAPI.AttachAnchor,
        register_cast_guard = registerCastGuard,
    },
    entity_modifiers = {
        modifier_api = modifierPackageApi,
        on_dot_tick = function(target, _kind, damage, source)
            local ref = type(target) == "table" and target.Ref or target
            applyDotHit(ref, damage, source)
        end,
    },
})
ServerRuntime.set_current(WorldRuntime)
local fishHost = WorldRuntime.fish_host
fishHost.Vitals = WorldRuntime.life
fishHost.Ai = FishAi
FishAi.FishUnit = fishHost
FishCarrier.DamageListener = function(carrier, actual, hit)
    local fish = carrier and fishHost:FindByCarrier(carrier)
    local attacker = hit and hit.sourcePlayer
    if fish and attacker then fishHost:NoteDamage(fish, attacker, actual) end
end
FishAi:Start()

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
