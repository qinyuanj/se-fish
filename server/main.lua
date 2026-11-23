
local Task = game:GetService("Task")
local RunService = game:GetService("RunService")
local Players = game:GetService("Players")
local WorldService = game:GetService("World")
local ZoneMarkers = require("common.ZoneMarkers")
ZoneMarkers.Start()
MgrUtil = require("server.MgrUtil")
MgrUtil:Start()
local ServerRuntime = require("server.World.ServerRuntime")

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
    MgrAttr = require("server.Mgr.MgrAttr"),
    MgrModifier = require("server.Mgr.MgrModifier"),
    MgrAi = require("server.Mgr.MgrAi"),
    MgrAiTarget = require("server.Mgr.MgrAiTarget"),
}

MgrMap.MgrAbility.BehaviorServices = {
    Vitals = MgrMap.MgrVitals,
    FishCarrier = MgrMap.MgrFishCarrier,
    Modifier = MgrMap.MgrModifier,
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
MgrMap.MgrAttr.PlayerData = MgrMap.MgrPlayerData
MgrMap.MgrAttr.Vitals = MgrMap.MgrVitals
MgrMap.MgrAttr.MoveMultiplierProvider = function(player) return MgrMap.MgrModifier:GetMoveMultiplier(player) end
MgrMap.MgrAbility.Attr = MgrMap.MgrAttr
MgrMap.MgrWeapon.Attr = MgrMap.MgrAttr
MgrMap.MgrVitals.Attr = MgrMap.MgrAttr
MgrMap.MgrAbility.Modifier = MgrMap.MgrModifier
MgrMap.MgrSurvival.Modifier = MgrMap.MgrModifier
MgrMap.MgrModifier.Ability = MgrMap.MgrAbility
MgrMap.MgrModifier.Vitals = MgrMap.MgrVitals
MgrMap.MgrAbility.Ai = MgrMap.MgrAi
MgrMap.MgrFishUnit.Ai = MgrMap.MgrAi
MgrMap.MgrFishUnit.AiTarget = MgrMap.MgrAiTarget
MgrMap.MgrAi.FishUnit = MgrMap.MgrFishUnit
MgrMap.MgrSurvival.SpeedWriter = MgrMap.MgrAbility
MgrMap.MgrVitals.ActGuard = function(player) return not MgrMap.MgrAbility:IsParalyzed(player) end
MgrMap.MgrVitals.MaxHealthProvider = function(player) return MgrMap.MgrAttr:MaxHealth(player) end
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
MgrMap.MgrWeapon.Modifier = MgrMap.MgrModifier

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
        local ok, now = pcall(WorldService.GetServerTime, WorldService)
        if ok and type(now) == "number" then return now end
    end
    return nil
end

-- Spoke 服务端运行时主干（ADR-0032 / #295）：过渡期旧管理器接缝全部由此 L1 入口以回调注入。
local WorldRuntime = ServerRuntime.new({
    initial_now = serverNow() or 0,
    on_player_join_start = function(player)
        invoke('MgrPlayerData', MgrMap.MgrPlayerData, 'OnPlayerAdded', player)
    end,
    is_player_data_current = function(player, data)
        return MgrMap.MgrPlayerData:GetDataInst(player) == data
    end,
    on_player_ready = function(player)
        for _, name in ipairs({ 'MgrAttr', 'MgrPlayer', 'MgrVitals', 'MgrModifier', 'MgrSurvival', 'MgrAbility', 'MgrFishUnit' }) do
            invoke(name, MgrMap[name], 'OnPlayerAdded', player)
        end
        for name, mgr in pairs(MgrMap) do
            if name ~= 'MgrPlayerData' and name ~= 'MgrPlayer' and name ~= 'MgrVitals'
                and name ~= 'MgrSurvival' and name ~= 'MgrAbility' and name ~= 'MgrFishUnit'
                and name ~= 'MgrAttr' and name ~= 'MgrModifier' then
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
