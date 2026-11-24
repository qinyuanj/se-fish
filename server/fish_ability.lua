
local World = game:GetService("World")
local Task = game:GetService("Task")

local game_cfg = require("common.game_cfg")
local ability_api = require("server.ability_api")
local ability_package_api = require("server.packages.ability_system.api")

local fish_ability = { SpokeHost = true, PendingFishCleanup = {} }

local EQUIP_RETRY_INTERVAL = 0.1
local EQUIP_RETRY_COUNT = 50

local function createManager(character, presetKey)
	local assets = World:CreateAsset(presetKey)
	local manager = assets and assets[1]
	if not manager then
		print("[fish_ability] 技能管理器预设创建失败: " .. tostring(presetKey))
		return nil
	end
	manager.Parent = character
	return manager
end

-- 锚点实例属性覆盖：预设里「已声明的属性」改不动默认值（issue #7 坑 2），
-- 关键值在挂接前直接 SetAttribute 到实例；{x,y,z} 表转成 Vector3（game_cfg 要保持纯数据可单测）。
local function applyAnchorAttributes(anchor, attrs, presetKey)
	if not attrs then
		return
	end
	for key, value in pairs(attrs) do
		if type(value) == "table" then
			value = Vector3.New(value.x or 0, value.y or 0, value.z or 0)
		end
		local ok, err = pcall(anchor.SetAttribute, anchor, key, value)
		if not ok then
			print("[fish_ability] 锚点属性覆盖失败: " .. tostring(presetKey) .. " " .. tostring(key) .. " " .. tostring(err))
            return false
		end
	end
    return true
end

local function createAnchor(abilityScript, entry)
	local assets = World:CreateAsset(entry.Anchor)
	local anchor = assets and assets[1]
	if not anchor then
		print("[fish_ability] 锚点预设创建失败: " .. tostring(entry.Anchor))
		return nil
	end
	anchor.Parent = abilityScript
	if applyAnchorAttributes(anchor, entry.AnchorAttributes, entry.Anchor) == false then
        anchor:Destroy()
        return nil
    end
	local ok, err = pcall(ability_api.AttachAnchor, anchor, entry.AnchorBehavior)
	if not ok or err ~= true then
		print("[fish_ability] 锚点挂接失败: " .. tostring(err))
        local removed, removeError = pcall(function() anchor:Destroy() end)
        if not removed then print('[fish_ability] 回收失败锚点', tostring(removeError)) end
        return nil
	end
	return anchor
end

function fish_ability:RemoveFish(fish)
    if self.Modifier then self.Modifier:ClearTarget(fish) end
    local record = fish.AbilityRecord
    if not record then return end
    record.Cancelled = true
    if record.Ready then
        local ok, err = pcall(ability_package_api.StopAbility, record.Receiver, record.Entry.Index)
        if not ok then print('[fish_ability] 停止鱼技能失败', fish.Id, tostring(err)) end
    end
    local ok, err = pcall(function() record.Manager:Destroy() end)
    if not ok then
        if not self.PendingFishCleanup[fish] then
            print('[fish_ability] 回收鱼技能管理器失败，将重试', fish.Id, tostring(err))
        end
        self.PendingFishCleanup[fish] = true
        return
    end
    self.PendingFishCleanup[fish] = nil
    fish.AbilityRecord = nil
end

function fish_ability:EquipFish(fish)
    if fish.AbilityRecord then return true end
    local species = game_cfg.Fish[fish.FishId]
    local entry = game_cfg.Ability.FishAbilities[species.Combat]
    local receiver = fish.Carrier.Receiver
    if not entry or not receiver then return false end
    local manager = createManager(receiver, game_cfg.Ability.ManagerPreset)
    if not manager then return false end
    local record = { Manager = manager, Receiver = receiver, Entry = entry }
    fish.AbilityRecord = record
    Task:Spawn(function()
        local ok, err = pcall(function()
        for _ = 1, EQUIP_RETRY_COUNT do
            if record.Cancelled then return end
            if fish.Carrier.Dead then self:RemoveFish(fish) return end
            local ability = ability_package_api.AddAbility(receiver, entry.AssetId, entry.Index)
            if ability then
                ability:SetAttribute('CastTime', entry.CastSec)
                ability:SetAttribute('CdTime', 0)
                local anchor = createAnchor(ability, {
                    Anchor = entry.Anchor,
                    AnchorBehavior = entry.AnchorBehavior,
                    AnchorAttributes = { Duration = 0, StartTime = 0, DischargeRadius = entry.Radius,
                        DischargeDamage = entry.Damage or species.Attack },
                })
                if not anchor then self:RemoveFish(fish) return end
                record.Ready = true
                print('[fish_ability] 电鳗技能就绪', fish.Id)
                return
            end
            Task:Wait(EQUIP_RETRY_INTERVAL)
        end
        if not record.Cancelled then
            print('[fish_ability] 电鳗技能装配超时', fish.Id)
            self:RemoveFish(fish)
        end
        end)
        if not ok then
            print('[fish_ability] 电鳗技能装配失败', fish.Id, tostring(err))
            self:RemoveFish(fish)
        end
    end)
    return true
end

function fish_ability:CastFish(fish)
    local record = fish.AbilityRecord
    if not record or not record.Ready or record.Cancelled or fish.Carrier.Dead then return false end
    if self.Ai then return self.Ai:CastFish(fish) end
    return ability_api.CastAbility(record.Receiver, record.Entry.Index)
end

function fish_ability:CanCast(unit)
	local player = unit and unit.UserId and unit or nil
	if not player and unit then
		local players = game:GetService("Players")
		if players and players.GetPlayerFromCharacter then
			local ok, found = pcall(players.GetPlayerFromCharacter, players, unit)
			if ok then player = found
			else print('[fish_ability] 玩家解析失败', tostring(found)) end
		end
	end
	if not player then return true end
	if not self.vitals then return true end
	return self.vitals:CanAct(player)
end

function fish_ability:PotionCount(player, itemId)
	if not self.player_data or not self.player_data.GetDataInst then return 0 end
	local ok, count = pcall(function()
		local data = self.player_data:GetDataInst(player)
		return data and data:PotionCount(itemId) or 0
	end)
	if ok and type(count) == 'number' then return count end
	return 0
end

function fish_ability:BodyPlan(player)
	return self.Attr:BodyPlan(player)
end

function fish_ability:ApplyBodyScale(player)
	return self.Attr:ApplyBodyScale(player)
end


function fish_ability:CaptureBaseSpeed(player)
	return self.Attr:CaptureBaseSpeed(player)
end

function fish_ability:MaxHealth(player)
	return self.Attr:MaxHealth(player)
end

local function queueSpeed(self, player, err)
	self.PendingSpeed = self.PendingSpeed or {}
	if not self.PendingSpeed[player.UserId] then
		print('[fish_ability] 移速写入失败', player.UserId, tostring(err))
	end
	self.PendingSpeed[player.UserId] = player
	return false, tostring(err)
end

function fish_ability:RefreshMoveSpeed(player)
	local ok, err = self.Attr:RefreshMoveSpeed(player)
	if not ok then
		return queueSpeed(self, player, err)
	end
	if self.PendingSpeed then self.PendingSpeed[player.UserId] = nil end
	return true
end

function fish_ability:ApplyGrowth(player)
	local applied = self.Attr:ApplyGrowth(player)
	local retryGrowth = not applied.Ok
	if retryGrowth then
		self.PendingGrowth = self.PendingGrowth or {}
		self.PendingGrowth[player.UserId] = player
	elseif self.PendingGrowth then self.PendingGrowth[player.UserId] = nil end
	return applied
end


function fish_ability:Now()
	local ok, now = pcall(function() return World:GetServerTime() end)
	return ok and now or 0
end

function fish_ability:UpdateEffects()
	return self.Modifier:Update()
end

function fish_ability:IsParalyzed(player)
	return self.Modifier:IsControlled(player)
end

function fish_ability:FishSpeedFactor(fish)
	return self.Modifier:GetMoveMultiplier(fish)
end

function fish_ability:FishParalyzed(fish)
	return self.Modifier:IsControlled(fish)
end

function fish_ability:Start()
	ability_api.BehaviorServices = self.BehaviorServices
	ability_api.SetCastGuard(function(unit, index) return self:CanCast(unit) end)
end

function fish_ability:OnPlayerAdded(player)
	-- 玩家角色能力管理器挂载与角色生命周期监听已迁至 player_tree / ability_leaf；
	-- 角色就绪时补做一次成长与血量上限首刷。
	if player and player.Character then
		self:CaptureBaseSpeed(player)
		self:ApplyGrowth(player)
	end
end

function fish_ability:OnPlayerRemoving(player)
	if self.PendingGrowth then self.PendingGrowth[player.UserId] = nil end
	if self.PendingSpeed then self.PendingSpeed[player.UserId] = nil end
end

function fish_ability:Update(deltaTime)
    for fish in pairs(self.PendingFishCleanup) do self:RemoveFish(fish) end
    local retrySpeed = {}
    for uid, player in pairs(self.PendingSpeed or {}) do retrySpeed[uid] = player end
    for uid, player in pairs(retrySpeed) do
        if self.PendingSpeed and self.PendingSpeed[uid] == player then self:RefreshMoveSpeed(player) end
    end
    for _, player in pairs(self.PendingGrowth or {}) do self:ApplyGrowth(player) end
end

return fish_ability
