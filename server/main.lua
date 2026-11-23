
local Task = game:GetService("Task")
local RunService = game:GetService("RunService")
local Players = game:GetService("Players")
local WorldService = game:GetService("World")
local ZoneMarkers = require("common.ZoneMarkers")
ZoneMarkers.Start()
MgrUtil = require("server.MgrUtil")
MgrUtil:Start()
local Number = require("common.Number")
local GameCfg = require("common.GameCfg")
local AbilityAPI = require("server.AbilityAPI")
local ServerRuntime = require("server.World.ServerRuntime")
local AttrLeaf = require("server.World.AttrLeaf")
local FishCarrier = require("server.World.FishCarrier")
local FishAi = require("server.World.FishAi")

local MgrMap = {
    MgrPlayer = require("server.Mgr.MgrPlayer"),
    MgrPlayerData = require("server.Mgr.MgrPlayerData"),
    MgrCast = require("server.Mgr.MgrCast"),
    MgrAbility = require("server.Mgr.MgrAbility"),
    MgrReelIn = require("server.Mgr.MgrReelIn"),
    MgrInteract = require("server.Mgr.MgrInteract"),
    MgrGM = require("server.Mgr.MgrGM"),
    MgrShop = require("server.Mgr.MgrShop"),
    MgrLottery = require("server.Mgr.MgrLottery"),
    MgrQuest = require("server.Mgr.MgrQuest"),
    MgrStory = require("server.Mgr.MgrStory"),
    MgrFerry = require("server.Mgr.MgrFerry"),
    MgrSave = require("server.Mgr.MgrSave"),
    MgrParty = require("server.Mgr.MgrParty"),
    MgrCompendium = require("server.Mgr.MgrCompendium"),
    MgrRecords = require("server.Mgr.MgrRecords"),
    MgrAchievements = require("server.Mgr.MgrAchievements"),
    MgrGrill = require("server.Mgr.MgrGrill"),
    MgrPlatform = require("server.Mgr.MgrPlatform"),
    MgrBlindbox = require("server.Mgr.MgrBlindbox"),
}

local WorldRuntime

local function resolvePlayer(target)
    if not target then return nil end
    local okUid, uid = pcall(function() return target.UserId end) -- 兼容引擎 userdata 对象读取 UserId
    if okUid and uid ~= nil then return target end
    local okFind, found = pcall(Players.GetPlayerFromCharacter, Players, target) -- 兼容引擎 userdata 传入非角色对象
    if okFind and found then return found end
    return nil
end

local function resolvePlayerTree(target)
    local player = resolvePlayer(target)
    if not player or not WorldRuntime then return nil, player end
    return WorldRuntime:get_player_tree(player.UserId), player
end

local function syncPlayerTree(player)
    local pt = resolvePlayerTree(player)
    if pt and MgrMap.MgrPlayerData and MgrMap.MgrPlayerData.GetDataInst then
        local data = MgrMap.MgrPlayerData:GetDataInst(player)
        if data then pt:sync_from_data(data) end
    end
    return pt
end

local function resolveEntityTarget(target)
    if not target then return nil end
    local okCarrier, carrier = pcall(function() return target.Carrier end) -- 兼容引擎 userdata 读取 Carrier
    if okCarrier and carrier then return target end
    local resolved = FishCarrier:ResolveCarrier(target)
    if resolved then return resolved end
    return target
end

-- Spoke 持续效果过渡门面（L1 胶水层）：玩家路由至 PlayerTree/PlayerEffects，活鱼/非玩家路由至 entity_modifiers。
local ModifierBridge = {}

function ModifierBridge:Apply(source, target, kind, seconds)
    local pt = resolvePlayerTree(target)
    if pt then
        return pt:apply_modifier(kind, { duration = seconds, source = source })
    end
    local em = WorldRuntime and WorldRuntime:get_entity_modifiers()
    if em then
        return em:apply(source, resolveEntityTarget(target), kind, seconds)
    end
    return false, "no-effect-owner"
end

function ModifierBridge:ApplyWeaponEffect(source, target, effect)
    return self:Apply(source, target, type(effect) == "table" and effect.Kind or nil)
end

function ModifierBridge:GetRemaining(target, kind)
    local pt = resolvePlayerTree(target)
    if pt then
        return pt:get_modifier_remaining(kind)
    end
    local em = WorldRuntime and WorldRuntime:get_entity_modifiers()
    if em then
        return em:get_remaining(resolveEntityTarget(target), kind)
    end
    return 0
end

function ModifierBridge:IsControlled(target)
    local pt = resolvePlayerTree(target)
    if pt then
        return pt.states.is_paralyzed:now() == true
    end
    local em = WorldRuntime and WorldRuntime:get_entity_modifiers()
    if em then
        return em:is_controlled(resolveEntityTarget(target))
    end
    return false
end

function ModifierBridge:GetMoveMultiplier(target)
    local pt = resolvePlayerTree(target)
    if pt then
        return pt.memos.move_multiplier:now()
    end
    local em = WorldRuntime and WorldRuntime:get_entity_modifiers()
    if em then
        return em:get_move_multiplier(resolveEntityTarget(target))
    end
    return 1
end

function ModifierBridge:Clear(target, kind)
    local pt = resolvePlayerTree(target)
    if pt then
        return pt:clear_modifier(kind)
    end
    local em = WorldRuntime and WorldRuntime:get_entity_modifiers()
    if em then
        return em:clear(resolveEntityTarget(target), kind)
    end
    return false
end

function ModifierBridge:ClearTarget(target, keepWeak)
    local pt = resolvePlayerTree(target)
    if pt then
        pt:clear_all_modifiers(keepWeak)
        return
    end
    local em = WorldRuntime and WorldRuntime:get_entity_modifiers()
    if em then
        em:clear_target(resolveEntityTarget(target))
    end
end

function ModifierBridge:Update()
    local em = WorldRuntime and WorldRuntime:get_entity_modifiers()
    if em then
        em:step(WorldRuntime.clock.now())
    end
end

-- Spoke 属性派生过渡门面（L1 胶水层）：所有成长与属性读取由 PlayerTree 派生并经 AttrLeaf 单向投影。
local AttrBridge = {}

function AttrBridge:CaptureBaseSpeed(player)
    local pt = syncPlayerTree(player)
    if pt then return pt:capture_base_speed() end
    return nil
end

function AttrBridge:BodyPlan(player)
    local pt = syncPlayerTree(player)
    if not pt then return nil, "no-player-tree" end
    return pt.memos.attr_plan:now().Body
end

function AttrBridge:MaxHealth(player)
    local pt = syncPlayerTree(player)
    if pt then return pt.memos.max_health:now() end
    return GameCfg.Vitals.MaxHealth
end

function AttrBridge:RefreshMaxHealth(player)
    local pt = syncPlayerTree(player)
    if not pt or not pt.memos or not pt.memos.max_health then return false, "no-player-tree" end
    local cap = pt.memos.max_health:now()
    if not Number.IsFiniteNumber(cap) or cap < 1 then return false, "bad-max" end
    cap = math.floor(cap)
    local character = pt.states.character:now()
    local controller = character and character.Controller
    if not controller then return false, "no-controller" end
    local ok, err = pcall(function()
        controller.MaxHealth = cap
        if type(controller.Health) == "number" and controller.Health > cap then
            controller.Health = cap
        end
    end)
    if not ok then return false, tostring(err) end
    local life = WorldRuntime and WorldRuntime.life
    local current = pt.states.health:now()
    if life and Number.IsFiniteNumber(current) and current > cap then
        life:SetHealth(player, cap)
    end
    return true
end

function AttrBridge:RefreshMoveSpeed(player)
    local pt = syncPlayerTree(player)
    if not pt then return false, "no-player-tree" end
    local character = pt.states.character:now()
    return AttrLeaf.apply_walk_speed(character, pt.memos.walk_speed:now())
end

function AttrBridge:ApplyBodyScale(player)
    local pt = syncPlayerTree(player)
    if not pt then return { Ok = false, Error = "no-player-tree" } end
    local character = pt.states.character:now()
    if not character then return { Ok = false, Error = "no-character" } end
    local scale = pt.memos.body_scale:now()
    local capped = pt.memos.body_scale_capped:now()
    local ok, derivedOrErr = AttrLeaf.apply_body_presentation(character, scale, capped)
    return {
        Ok = ok,
        Error = not ok and tostring(derivedOrErr) or nil,
        Scale = scale,
        Health = pt.memos.max_health:now(),
        Capped = capped,
        Derived = ok and derivedOrErr or pt.memos.body_derived:now(),
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

function AttrBridge:RefreshAfterRevive(player)
    local uid = player and player.UserId
    local ok, result = pcall(self.ApplyGrowth, self, player)
    if not ok then
        print('[server.main.AttrBridge]', 'RefreshAfterRevive', uid, tostring(result))
        return false
    end
    if type(result) ~= "table" or result.Ok ~= true then
        print('[server.main.AttrBridge]', 'RefreshAfterRevive', uid, tostring(type(result) == "table" and result.Error or result))
        return false
    end
    return true
end

function AttrBridge:ProjectHunger(player, value)
    local pt = syncPlayerTree(player)
    local clamped = math.max(0, math.min(GameCfg.Vitals.MaxHunger, math.floor(value or 0)))
    if pt then
        pt.states.hunger:set(clamped)
    end
    return true, clamped
end

function AttrBridge:WeaponDamageScale(player, kind)
    if kind ~= "melee" and kind ~= "ranged" and kind ~= "explosive" then return 1 end
    local pt = syncPlayerTree(player)
    if not pt then return 1 end
    local scales = pt.memos.weapon_damage_scales:now()
    return scales and scales[kind] or 1
end

MgrMap.MgrAbility.BehaviorServices = {
    Vitals = nil,
    Modifier = ModifierBridge,
    GM = MgrMap.MgrGM,
}

MgrMap.MgrCast.ReelIn = MgrMap.MgrReelIn
MgrMap.MgrReelIn.Cast = MgrMap.MgrCast
MgrMap.MgrInteract.PlayerData = MgrMap.MgrPlayerData
MgrMap.MgrGM.PlayerData = MgrMap.MgrPlayerData
MgrMap.MgrGM.Cast = MgrMap.MgrCast
MgrMap.MgrShop.PlayerData = MgrMap.MgrPlayerData
MgrMap.MgrShop.Interact = MgrMap.MgrInteract
MgrMap.MgrInteract.Quest = MgrMap.MgrQuest
MgrMap.MgrShop.Quest = MgrMap.MgrQuest
MgrMap.MgrPlayerData.Quest = MgrMap.MgrQuest
MgrMap.MgrCast.Quest = MgrMap.MgrQuest
MgrMap.MgrPlayerData.Vitals = nil
MgrMap.MgrGM.Vitals = nil
MgrMap.MgrGM.Save = MgrMap.MgrSave
MgrMap.MgrFerry.PlayerData = MgrMap.MgrPlayerData
MgrMap.MgrFerry.Interact = MgrMap.MgrInteract
MgrMap.MgrPlayerData.Save = MgrMap.MgrSave
MgrMap.MgrQuest.PlayerData = MgrMap.MgrPlayerData
MgrMap.MgrQuest.Save = MgrMap.MgrSave
MgrMap.MgrStory.PlayerData = MgrMap.MgrPlayerData
MgrMap.MgrStory.Save = MgrMap.MgrSave
MgrMap.MgrInteract.Save = MgrMap.MgrSave
MgrMap.MgrInteract.Vitals = nil
MgrMap.MgrInteract.Survival = nil
MgrMap.MgrAchievements.PlayerData = MgrMap.MgrPlayerData
MgrMap.MgrAchievements.Save = MgrMap.MgrSave
MgrMap.MgrFerry.Save = MgrMap.MgrSave
MgrMap.MgrShop.Save = MgrMap.MgrSave
MgrMap.MgrFerry.Save = MgrMap.MgrSave
MgrMap.MgrSave.PlayerData = MgrMap.MgrPlayerData
MgrMap.MgrLottery.PlayerData = MgrMap.MgrPlayerData
MgrMap.MgrLottery.Save = MgrMap.MgrSave
MgrMap.MgrLottery.Interact = MgrMap.MgrInteract
MgrMap.MgrCompendium.Save = MgrMap.MgrSave
MgrMap.MgrCompendium.PlayerData = MgrMap.MgrPlayerData
MgrMap.MgrCompendium.Quest = MgrMap.MgrQuest
MgrMap.MgrCast.Compendium = MgrMap.MgrCompendium

MgrMap.MgrCompendium.Records = MgrMap.MgrRecords
MgrMap.MgrRecords.PlayerData = MgrMap.MgrPlayerData

MgrMap.MgrPlatform.Save = MgrMap.MgrSave
MgrMap.MgrPlatform.PlayerData = MgrMap.MgrPlayerData
MgrMap.MgrBlindbox.Save = MgrMap.MgrSave
MgrMap.MgrBlindbox.PlayerData = MgrMap.MgrPlayerData
MgrMap.MgrBlindbox.Platform = MgrMap.MgrPlatform

MgrMap.MgrAbility.Vitals = nil
MgrMap.MgrPlayerData.Ability = MgrMap.MgrAbility
MgrMap.MgrAbility.PlayerData = MgrMap.MgrPlayerData
MgrMap.MgrAbility.Attr = AttrBridge
MgrMap.MgrAbility.Modifier = ModifierBridge
MgrMap.MgrCast.Vitals = nil

MgrMap.MgrGrill.Vitals = nil
MgrMap.MgrGrill.PlayerData = MgrMap.MgrPlayerData
MgrMap.MgrGrill.Save = MgrMap.MgrSave


MgrMap.MgrParty.PlayerData = MgrMap.MgrPlayerData
MgrMap.MgrParty.Save = MgrMap.MgrSave
MgrMap.MgrParty.Vitals = nil

local PkDamageFilter = require("server.World.PkDamageFilter")
local pkDamageFilter = PkDamageFilter.make({
    party = MgrMap.MgrParty,
    zone_markers = ZoneMarkers,
})

local function invoke(name, mgr, method, ...)
    if not mgr[method] then return end
    local ok, err = pcall(mgr[method], mgr, ...)
    if not ok then print('[server.main]', name, method, tostring(err)) end
end

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

-- Spoke 服务端运行时主干（ADR-0032 / #295、#297）：装配官方包叶子投影与过渡期 L1 回调接缝。
WorldRuntime = ServerRuntime.new({
    initial_now = serverNow() or 0,
    remote = _G.REUtil,
    player_data = MgrMap.MgrPlayerData,
    save = MgrMap.MgrSave,
    platform = MgrMap.MgrPlatform,
    physics = game:GetService("PhysicsService"),
    players_service = Players,
    world_service = WorldService,
    party = MgrMap.MgrParty,
    zone_markers = ZoneMarkers,
    bind_weapon_action = function(dispatch)
        local event = _G.REUtil:GetRE("WeaponAction")
        event.OnServerEvent:Connect(function(player, payload)
            if _G.REUtil:CheckRECD(player, "WeaponAction", GameCfg.Ability.GunShared.ActionCooldownSec) then return end
            dispatch(player, payload)
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
            return FishAi:Sync(fish) ~= false
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
    on_player_join_start = function(player)
        invoke('MgrPlayerData', MgrMap.MgrPlayerData, 'OnPlayerAdded', player)
    end,
    is_player_data_current = function(player, data)
        return MgrMap.MgrPlayerData:GetDataInst(player) == data
    end,
    on_player_ready = function(player)
        for _, name in ipairs({ 'MgrPlayer', 'MgrAbility' }) do
            invoke(name, MgrMap[name], 'OnPlayerAdded', player)
        end
        for name, mgr in pairs(MgrMap) do
            if name ~= 'MgrPlayerData' and name ~= 'MgrPlayer'
                and name ~= 'MgrAbility' then
                invoke(name, mgr, 'OnPlayerAdded', player)
            end
        end
    end,
    flush_before_leave = function(player, resume)
        if MgrMap.MgrQuest:FlushBeforeLeave(player, resume) then return true end
        if MgrMap.MgrStory:FlushBeforeLeave(player, resume) then return true end
        return false
    end,
    on_leave_finalize = function(_, player)
        invoke('MgrGrill', MgrMap.MgrGrill, 'BeforeLeave', player)
    end,
    on_player_removing = function(player, active)
        invoke('MgrPlayerData', MgrMap.MgrPlayerData, 'OnPlayerRemoving', player)
        if active then
            for name, mgr in pairs(MgrMap) do
                if name ~= 'MgrPlayerData' then invoke(name, mgr, 'OnPlayerRemoving', player) end
            end
        end
    end,
    after_idle = function(userId, done)
        MgrMap.MgrSave:AfterIdle(userId, done)
    end,
})
ServerRuntime.set_current(WorldRuntime)
WorldRuntime.life:SetDamageFilter(pkDamageFilter)
local Life = WorldRuntime.life
-- #309 活鱼公开宿主接线：不再注册 MgrFishUnit/MgrFishCarrier/MgrAi。
local fishHost = WorldRuntime.fish_host
MgrMap.MgrCast.FishUnit = fishHost
fishHost.Cast = MgrMap.MgrCast
fishHost.Ability = MgrMap.MgrAbility
fishHost.AbilityApi = AbilityAPI
fishHost.Quest = MgrMap.MgrQuest
fishHost.Vitals = Life
fishHost.Ai = FishAi
FishAi.FishUnit = fishHost
MgrMap.MgrAbility.Ai = FishAi
FishCarrier.DamageListener = function(carrier, actual, hit)
    local fish = carrier and fishHost:FindByCarrier(carrier)
    local attacker = hit and hit.sourcePlayer
    if fish and attacker then fishHost:NoteDamage(fish, attacker, actual) end
end
FishAi:Start()
MgrMap.MgrPlayerData.Vitals = Life
MgrMap.MgrGM.Vitals = Life
MgrMap.MgrInteract.Vitals = Life
MgrMap.MgrInteract.Survival = Life
MgrMap.MgrAbility.Vitals = Life
MgrMap.MgrAbility.BehaviorServices.Vitals = Life
MgrMap.MgrCast.Vitals = Life
MgrMap.MgrGrill.Vitals = Life
MgrMap.MgrParty.Vitals = Life

MgrMap.MgrPlayerData.OnSyncPlayerTree = function(player, data, forcePush)
    local pt = WorldRuntime:get_player_tree(player.UserId)
    if not pt then return false end
    pt:sync_from_data(data, forcePush and { force_push = true } or nil)
    return true
end

MgrMap.MgrSave.OnReady = function(player, data)
    WorldRuntime:on_save_ready(player, data)
end

local function HandlePlayerAdded(player)
    WorldRuntime:on_player_added(player)
end

local function HandlePlayerRemoving(player)
    WorldRuntime:on_player_removing(player)
end

local function HandleTimeUpdate(deltaTime)
    WorldRuntime:step(deltaTime, serverNow())
    for k, mgr in pairs(MgrMap) do
        if mgr.Update then
            pcall(function() mgr:Update(deltaTime) end)
        end
    end
end

local function GameStart()
    WorldRuntime:start()
    for name, mgr in pairs(MgrMap) do invoke(name, mgr, 'Start') end
    WorldRuntime:mark_started()
end



Players.PlayerAdded:Connect(HandlePlayerAdded)
Players.PlayerRemoving:Connect(HandlePlayerRemoving)
local plst = Players:GetPlayers()
for _, player in pairs(plst)  do
    HandlePlayerAdded(player)
end

GameStart()
RunService.Heartbeat:Connect(HandleTimeUpdate)

return WorldRuntime
