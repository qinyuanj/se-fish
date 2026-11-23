
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

local MgrMap = {
    MgrPlayer = require("server.Mgr.MgrPlayer"),
    MgrPlayerData = require("server.Mgr.MgrPlayerData"),
    MgrCast = require("server.Mgr.MgrCast"),
    MgrAbility = require("server.Mgr.MgrAbility"),
    MgrReelIn = require("server.Mgr.MgrReelIn"),
    MgrFishCarrier = require("server.Mgr.MgrFishCarrier"),
    MgrFishUnit = require("server.Mgr.MgrFishUnit"),
    MgrLoot = require("server.Mgr.MgrLoot"),
    MgrInteract = require("server.Mgr.MgrInteract"),
    MgrGM = require("server.Mgr.MgrGM"),
    MgrShop = require("server.Mgr.MgrShop"),
    MgrLottery = require("server.Mgr.MgrLottery"),
    MgrQuest = require("server.Mgr.MgrQuest"),
    MgrVitals = require("server.Mgr.MgrVitals"),
    MgrStory = require("server.Mgr.MgrStory"),
    MgrFerry = require("server.Mgr.MgrFerry"),
    MgrSave = require("server.Mgr.MgrSave"),
    MgrSurvival = require("server.Mgr.MgrSurvival"),
    MgrWeapon = require("server.Mgr.MgrWeapon"),
    MgrSpecialItem = require("server.Mgr.MgrSpecialItem"),
    MgrParty = require("server.Mgr.MgrParty"),
    MgrCompendium = require("server.Mgr.MgrCompendium"),
    MgrRecords = require("server.Mgr.MgrRecords"),
    MgrAchievements = require("server.Mgr.MgrAchievements"),
    MgrGrill = require("server.Mgr.MgrGrill"),
    MgrPlatform = require("server.Mgr.MgrPlatform"),
    MgrBlindbox = require("server.Mgr.MgrBlindbox"),
    MgrAi = require("server.Mgr.MgrAi"),
    MgrAiTarget = require("server.Mgr.MgrAiTarget"),
}

local WorldRuntime

local function resolvePlayer(target)
    if not target then return nil end
    local okUid, uid = pcall(function() return target.UserId end) -- 兼容引擎 userdata 对象读取 UserId
    if okUid and uid ~= nil then return target end
    if Players and Players.GetPlayerFromCharacter then
        local okFind, found = pcall(Players.GetPlayerFromCharacter, Players, target) -- 兼容离线替身无 GetPlayerFromCharacter
        if okFind and found then return found end
    end
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
    if MgrMap.MgrFishCarrier and MgrMap.MgrFishCarrier.ResolveCarrier then
        local resolved = MgrMap.MgrFishCarrier:ResolveCarrier(target)
        if resolved then return { Carrier = resolved, Ref = target } end
    end
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
    if MgrMap.MgrVitals and (not MgrMap.MgrVitals.GetState or MgrMap.MgrVitals:GetState(player)) then
        local called, ok, err = pcall(MgrMap.MgrVitals.RefreshMaxHealth, MgrMap.MgrVitals, player) -- 隔离旧 MgrVitals 刷新异常
        if not called or not ok then errors[#errors + 1] = "MaxHealth:" .. tostring(called and err or ok) end
    end
    local okSpeed, speedErr = self:RefreshMoveSpeed(player)
    if not okSpeed then errors[#errors + 1] = tostring(speedErr) end
    applied.Ok = #errors == 0
    if not applied.Ok then applied.Error = table.concat(errors, "; ") end
    return applied
end

function AttrBridge:RefreshAfterRevive(player)
    local ok, result = pcall(self.ApplyGrowth, self, player) -- 复活期角色可能延迟就绪
    return ok and type(result) == "table" and result.Ok == true
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
    Vitals = MgrMap.MgrVitals,
    FishCarrier = MgrMap.MgrFishCarrier,
    Modifier = ModifierBridge,
    GM = MgrMap.MgrGM,
}

MgrMap.MgrCast.ReelIn = MgrMap.MgrReelIn
MgrMap.MgrReelIn.Cast = MgrMap.MgrCast
MgrMap.MgrCast.FishUnit = MgrMap.MgrFishUnit
MgrMap.MgrFishUnit.Cast = MgrMap.MgrCast
MgrMap.MgrFishUnit.Ability = MgrMap.MgrAbility
MgrMap.MgrLoot.FishUnit = MgrMap.MgrFishUnit
MgrMap.MgrLoot.PlayerData = MgrMap.MgrPlayerData
MgrMap.MgrPlayerData.Loot = MgrMap.MgrLoot
MgrMap.MgrInteract.PlayerData = MgrMap.MgrPlayerData
MgrMap.MgrGM.PlayerData = MgrMap.MgrPlayerData
MgrMap.MgrGM.Cast = MgrMap.MgrCast
MgrMap.MgrShop.PlayerData = MgrMap.MgrPlayerData
MgrMap.MgrShop.Interact = MgrMap.MgrInteract
MgrMap.MgrLoot.Quest = MgrMap.MgrQuest
MgrMap.MgrInteract.Quest = MgrMap.MgrQuest
MgrMap.MgrShop.Quest = MgrMap.MgrQuest
MgrMap.MgrPlayerData.Quest = MgrMap.MgrQuest
MgrMap.MgrCast.Quest = MgrMap.MgrQuest
MgrMap.MgrFishUnit.Quest = MgrMap.MgrQuest
MgrMap.MgrPlayerData.Vitals = MgrMap.MgrVitals
MgrMap.MgrVitals.PlayerData = MgrMap.MgrPlayerData
MgrMap.MgrGM.Vitals = MgrMap.MgrVitals
MgrMap.MgrGM.Save = MgrMap.MgrSave
MgrMap.MgrFerry.PlayerData = MgrMap.MgrPlayerData
MgrMap.MgrFerry.Interact = MgrMap.MgrInteract
MgrMap.MgrPlayerData.Save = MgrMap.MgrSave
MgrMap.MgrQuest.PlayerData = MgrMap.MgrPlayerData
MgrMap.MgrQuest.Save = MgrMap.MgrSave
MgrMap.MgrStory.PlayerData = MgrMap.MgrPlayerData
MgrMap.MgrStory.Save = MgrMap.MgrSave
MgrMap.MgrInteract.Save = MgrMap.MgrSave
MgrMap.MgrInteract.Vitals = MgrMap.MgrVitals
MgrMap.MgrInteract.Survival = MgrMap.MgrSurvival
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
MgrMap.MgrPlatform.Loot = MgrMap.MgrLoot
MgrMap.MgrBlindbox.Save = MgrMap.MgrSave
MgrMap.MgrBlindbox.PlayerData = MgrMap.MgrPlayerData
MgrMap.MgrBlindbox.Platform = MgrMap.MgrPlatform
MgrMap.MgrBlindbox.Loot = MgrMap.MgrLoot
MgrMap.MgrSurvival.Platform = MgrMap.MgrPlatform

MgrMap.MgrAbility.Vitals = MgrMap.MgrVitals
MgrMap.MgrFishUnit.Vitals = MgrMap.MgrVitals
MgrMap.MgrPlayerData.Ability = MgrMap.MgrAbility
MgrMap.MgrAbility.PlayerData = MgrMap.MgrPlayerData
MgrMap.MgrAbility.Survival = MgrMap.MgrSurvival
MgrMap.MgrAbility.Attr = AttrBridge
MgrMap.MgrWeapon.Attr = AttrBridge
MgrMap.MgrVitals.Attr = AttrBridge
MgrMap.MgrAbility.Modifier = ModifierBridge
MgrMap.MgrSurvival.Modifier = ModifierBridge
MgrMap.MgrAbility.Ai = MgrMap.MgrAi
MgrMap.MgrFishUnit.Ai = MgrMap.MgrAi
MgrMap.MgrFishUnit.AiTarget = MgrMap.MgrAiTarget
MgrMap.MgrAi.FishUnit = MgrMap.MgrFishUnit
MgrMap.MgrSurvival.SpeedWriter = MgrMap.MgrAbility
MgrMap.MgrVitals.ActGuard = function(player) return not MgrMap.MgrAbility:IsParalyzed(player) end
MgrMap.MgrVitals.MaxHealthProvider = function(player) return AttrBridge:MaxHealth(player) end
MgrMap.MgrVitals.FishCarrier = MgrMap.MgrFishCarrier
MgrMap.MgrCast.Vitals = MgrMap.MgrVitals
MgrMap.MgrSurvival.Vitals = MgrMap.MgrVitals
MgrMap.MgrSurvival.FishUnit = MgrMap.MgrFishUnit
MgrMap.MgrSurvival.ReelIn = MgrMap.MgrReelIn
MgrMap.MgrSurvival.PlayerData = MgrMap.MgrPlayerData
MgrMap.MgrSurvival.Save = MgrMap.MgrSave
MgrMap.MgrVitals:SetLifeHooks(MgrMap.MgrSurvival:Hooks())
MgrMap.MgrFishCarrier.DamageListener = function(carrier, actual, hit)
    local fish = carrier and MgrMap.MgrFishUnit:FindByCarrier(carrier)
    local attacker = hit and hit.sourcePlayer
    if fish and attacker and type(actual) == 'number' and actual > 0 then
        MgrMap.MgrFishUnit:NoteDamage(fish, attacker, actual)
    end
end

MgrMap.MgrWeapon.Vitals = MgrMap.MgrVitals
MgrMap.MgrWeapon.PlayerData = MgrMap.MgrPlayerData
MgrMap.MgrWeapon.FishUnit = MgrMap.MgrFishUnit
MgrMap.MgrWeapon.FishCarrier = MgrMap.MgrFishCarrier
MgrMap.MgrWeapon.Save = MgrMap.MgrSave
MgrMap.MgrWeapon.Modifier = ModifierBridge

MgrMap.MgrGrill.Vitals = MgrMap.MgrVitals
MgrMap.MgrGrill.PlayerData = MgrMap.MgrPlayerData
MgrMap.MgrGrill.Save = MgrMap.MgrSave

MgrMap.MgrSpecialItem.Vitals = MgrMap.MgrVitals
MgrMap.MgrSpecialItem.PlayerData = MgrMap.MgrPlayerData
MgrMap.MgrSpecialItem.FishUnit = MgrMap.MgrFishUnit
MgrMap.MgrFerry.SpecialItem = MgrMap.MgrSpecialItem

MgrMap.MgrParty.PlayerData = MgrMap.MgrPlayerData
MgrMap.MgrParty.Save = MgrMap.MgrSave
MgrMap.MgrParty.Vitals = MgrMap.MgrVitals

local makePkDamageFilter = require("server.Mgr.MgrPkFilter").Make
MgrMap.MgrVitals.ZoneMarkers = ZoneMarkers
MgrMap.MgrVitals.Party = MgrMap.MgrParty
MgrMap.MgrVitals.DamageFilter = makePkDamageFilter()

local function invoke(name, mgr, method, ...)
    if not mgr[method] then return end
    local ok, err = pcall(mgr[method], mgr, ...)
    if not ok then print('[server.main]', name, method, tostring(err)) end
end

local function serverNow()
    if WorldService and WorldService.GetServerTime then
        local ok, now = pcall(WorldService.GetServerTime, WorldService) -- 兼容引擎早期阶段或离线替身未提供 GetServerTime
        if ok and Number.IsFiniteNumber(now) then return now end
    end
    return nil
end

local function optionalPackage(loader)
    local ok, api = pcall(loader) -- 离线最小测试替身未提供官方包依赖的引擎服务时降级跳过叶子挂载
    if ok and type(api) == "table" then return api end
    return nil
end

local attrPackageApi = optionalPackage(function() return require("server.packages.attr_rule.api") end)
local modifierPackageApi = optionalPackage(function() return require("server.packages.modifier_system.api") end)
local abilityPackageApi = optionalPackage(function() return require("server.packages.ability_system.api") end)

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
    if MgrMap.MgrVitals and MgrMap.MgrVitals.NewHit and MgrMap.MgrVitals.ApplyHit then
        local hit = MgrMap.MgrVitals:NewHit(source, "dot")
        MgrMap.MgrVitals:ApplyHit(hit, target, damage)
    end
end

-- Spoke 服务端运行时主干（ADR-0032 / #295、#297）：装配官方包叶子投影与过渡期 L1 回调接缝。
WorldRuntime = ServerRuntime.new({
    initial_now = serverNow() or 0,
    create_unit = function(unit_type, props)
        return WorldService:CreateUnit(unit_type, props)
    end,
    player_effects = {
        on_dot_tick = function(pt, _kind, damage, source)
            applyDotHit(pt.player, damage, source)
        end,
    },
    attr_leaf = attrPackageApi and { attr_api = attrPackageApi } or nil,
    modifier_leaf = modifierPackageApi and { modifier_api = modifierPackageApi } or nil,
    ability_leaf = abilityPackageApi and {
        ability_api = abilityPackageApi,
        attach_anchor = AbilityAPI.AttachAnchor,
        register_cast_guard = registerCastGuard,
    } or nil,
    entity_modifiers = modifierPackageApi and {
        modifier_api = modifierPackageApi,
        on_dot_tick = function(target, _kind, damage, source)
            local ref = type(target) == "table" and target.Ref or target
            applyDotHit(ref, damage, source)
        end,
    } or nil,
    on_player_join_start = function(player)
        invoke('MgrPlayerData', MgrMap.MgrPlayerData, 'OnPlayerAdded', player)
    end,
    is_player_data_current = function(player, data)
        return MgrMap.MgrPlayerData:GetDataInst(player) == data
    end,
    on_player_ready = function(player)
        for _, name in ipairs({ 'MgrPlayer', 'MgrVitals', 'MgrSurvival', 'MgrAbility', 'MgrFishUnit' }) do
            invoke(name, MgrMap[name], 'OnPlayerAdded', player)
        end
        for name, mgr in pairs(MgrMap) do
            if name ~= 'MgrPlayerData' and name ~= 'MgrPlayer' and name ~= 'MgrVitals'
                and name ~= 'MgrSurvival' and name ~= 'MgrAbility' and name ~= 'MgrFishUnit' then
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
        invoke('MgrSurvival', MgrMap.MgrSurvival, 'BeforeLeave', player)
        invoke('MgrGrill', MgrMap.MgrGrill, 'BeforeLeave', player)
        invoke('MgrSpecialItem', MgrMap.MgrSpecialItem, 'BeforeLeave', player)
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

MgrMap.MgrPlayerData.OnSyncPlayerTree = function(player, data)
    local pt = WorldRuntime:get_player_tree(player.UserId)
    if pt then pt:sync_from_data(data) end
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
