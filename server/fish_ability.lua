
local World = game:GetService("World")
local Task = game:GetService("Task")

local GameCfg = require("common.game_cfg")
local AbilityAPI = require("server.ability_api")
local AbilityPackageAPI = require("server.packages.ability_system.api")

local FishAbility = { SpokeHost = true, PendingFishCleanup = {} }

local EQUIP_RETRY_INTERVAL = 0.1
local EQUIP_RETRY_COUNT = 50

local function createManager(character, presetKey)
	local assets = World:CreateAsset(presetKey)
	local manager = assets and assets[1]
	if not manager then
		print("[FishAbility] 技能管理器预设创建失败: " .. tostring(presetKey))
		return nil
	end
	manager.Parent = character
	return manager
end

-- 锚点实例属性覆盖：预设里「已声明的属性」改不动默认值（issue #7 坑 2），
-- 关键值在挂接前直接 SetAttribute 到实例；{x,y,z} 表转成 Vector3（GameCfg 要保持纯数据可单测）。
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
			print("[FishAbility] 锚点属性覆盖失败: " .. tostring(presetKey) .. " " .. tostring(key) .. " " .. tostring(err))
            return false
		end
	end
    return true
end

local function createAnchor(abilityScript, entry)
	local assets = World:CreateAsset(entry.Anchor)
	local anchor = assets and assets[1]
	if not anchor then
		print("[FishAbility] 锚点预设创建失败: " .. tostring(entry.Anchor))
		return nil
	end
	anchor.Parent = abilityScript
	if applyAnchorAttributes(anchor, entry.AnchorAttributes, entry.Anchor) == false then
        anchor:Destroy()
        return nil
    end
	local ok, err = pcall(AbilityAPI.attach_anchor, anchor, entry.AnchorBehavior)
	if not ok or err ~= true then
		print("[FishAbility] 锚点挂接失败: " .. tostring(err))
        local removed, removeError = pcall(function() anchor:Destroy() end)
        if not removed then print('[FishAbility] 回收失败锚点', tostring(removeError)) end
        return nil
	end
	return anchor
end

function FishAbility:remove_fish(fish)
    if self.Modifier then self.Modifier:clear_target(fish) end
    local record = fish.AbilityRecord
    if not record then return end
    record.Cancelled = true
    if record.Ready then
        local ok, err = pcall(AbilityPackageAPI.StopAbility, record.Receiver, record.entry.Index)
        if not ok then print('[FishAbility] 停止鱼技能失败', fish.Id, tostring(err)) end
    end
    local ok, err = pcall(function() record.Manager:Destroy() end)
    if not ok then
        if not self.PendingFishCleanup[fish] then
            print('[FishAbility] 回收鱼技能管理器失败，将重试', fish.Id, tostring(err))
        end
        self.PendingFishCleanup[fish] = true
        return
    end
    self.PendingFishCleanup[fish] = nil
    fish.AbilityRecord = nil
end

function FishAbility:equip_fish(fish)
    if fish.AbilityRecord then return true end
    local species = GameCfg.Fish[fish.FishId]
    local entry = GameCfg.Ability.FishAbilities[species.Combat]
    local receiver = fish.Carrier.Receiver
    if not entry or not receiver then return false end
    local manager = createManager(receiver, GameCfg.Ability.ManagerPreset)
    if not manager then return false end
    local record = { Manager = manager, Receiver = receiver, entry = entry }
    fish.AbilityRecord = record
    Task:Spawn(function()
        local ok, err = pcall(function()
        for _ = 1, EQUIP_RETRY_COUNT do
            if record.Cancelled then return end
            if fish.Carrier.Dead then self:remove_fish(fish) return end
            local ability = AbilityPackageAPI.add_ability(receiver, entry.AssetId, entry.Index)
            if ability then
                ability:SetAttribute('CastTime', entry.CastSec)
                ability:SetAttribute('CdTime', 0)
                local anchor = createAnchor(ability, {
                    Anchor = entry.Anchor,
                    AnchorBehavior = entry.AnchorBehavior,
                    AnchorAttributes = { Duration = 0, StartTime = 0, DischargeRadius = entry.Radius,
                        DischargeDamage = entry.Damage or species.Attack },
                })
                if not anchor then self:remove_fish(fish) return end
                record.Ready = true
                print('[FishAbility] 电鳗技能就绪', fish.Id)
                return
            end
            Task:Wait(EQUIP_RETRY_INTERVAL)
        end
        if not record.Cancelled then
            print('[FishAbility] 电鳗技能装配超时', fish.Id)
            self:remove_fish(fish)
        end
        end)
        if not ok then
            print('[FishAbility] 电鳗技能装配失败', fish.Id, tostring(err))
            self:remove_fish(fish)
        end
    end)
    return true
end

function FishAbility:cast_fish(fish)
    local record = fish.AbilityRecord
    if not record or not record.Ready or record.Cancelled or fish.Carrier.Dead then return false end
    if self.Ai then return self.Ai:cast_fish(fish) end
    return AbilityAPI.cast_ability(record.Receiver, record.entry.Index)
end

function FishAbility:can_cast(unit)
	local player = unit and unit.UserId and unit or nil
	if not player and unit then
		local players = game:GetService("Players")
		if players and players.GetPlayerFromCharacter then
			local ok, found = pcall(players.GetPlayerFromCharacter, players, unit)
			if ok then player = found
			else print('[FishAbility] 玩家解析失败', tostring(found)) end
		end
	end
	if not player then return true end
	if not self.Vitals then return true end
	return self.Vitals:can_act(player)
end

function FishAbility:potion_count(player, itemId)
	if not self.PlayerData or not self.PlayerData.get_data_inst then return 0 end
	local ok, count = pcall(function()
		local data = self.PlayerData:get_data_inst(player)
		return data and data:potion_count(itemId) or 0
	end)
	if ok and type(count) == 'number' then return count end
	return 0
end

function FishAbility:body_plan(player)
	return self.Attr:body_plan(player)
end

function FishAbility:apply_body_scale(player)
	return self.Attr:apply_body_scale(player)
end


function FishAbility:capture_base_speed(player)
	return self.Attr:capture_base_speed(player)
end

function FishAbility:MaxHealth(player)
	return self.Attr:MaxHealth(player)
end

local function queueSpeed(self, player, err)
	self.PendingSpeed = self.PendingSpeed or {}
	if not self.PendingSpeed[player.UserId] then
		print('[FishAbility] 移速写入失败', player.UserId, tostring(err))
	end
	self.PendingSpeed[player.UserId] = player
	return false, tostring(err)
end

function FishAbility:refresh_move_speed(player)
	local ok, err = self.Attr:refresh_move_speed(player)
	if not ok then
		return queueSpeed(self, player, err)
	end
	if self.PendingSpeed then self.PendingSpeed[player.UserId] = nil end
	return true
end

function FishAbility:apply_growth(player)
	local applied = self.Attr:apply_growth(player)
	local retryGrowth = not applied.Ok
	if retryGrowth then
		self.PendingGrowth = self.PendingGrowth or {}
		self.PendingGrowth[player.UserId] = player
	elseif self.PendingGrowth then self.PendingGrowth[player.UserId] = nil end
	return applied
end


function FishAbility:now()
	local ok, now = pcall(function() return World:GetServerTime() end)
	return ok and now or 0
end

function FishAbility:update_effects()
	return self.Modifier:update()
end

function FishAbility:is_paralyzed(player)
	return self.Modifier:is_controlled(player)
end

function FishAbility:fish_speed_factor(fish)
	return self.Modifier:get_move_multiplier(fish)
end

function FishAbility:fish_paralyzed(fish)
	return self.Modifier:is_controlled(fish)
end

function FishAbility:Start()
	AbilityAPI.BehaviorServices = self.BehaviorServices
	AbilityAPI.set_cast_guard(function(unit, index) return self:can_cast(unit) end)
end

function FishAbility:on_player_added(player)
	-- 玩家角色能力管理器挂载与角色生命周期监听已迁至 PlayerTree / AbilityLeaf；
	-- 角色就绪时补做一次成长与血量上限首刷。
	if player and player.Character then
		self:capture_base_speed(player)
		self:apply_growth(player)
	end
end

function FishAbility:on_player_removing(player)
	if self.PendingGrowth then self.PendingGrowth[player.UserId] = nil end
	if self.PendingSpeed then self.PendingSpeed[player.UserId] = nil end
end

function FishAbility:update(deltaTime)
    for fish in pairs(self.PendingFishCleanup) do self:remove_fish(fish) end
    local retrySpeed = {}
    for uid, player in pairs(self.PendingSpeed or {}) do retrySpeed[uid] = player end
    for uid, player in pairs(retrySpeed) do
        if self.PendingSpeed and self.PendingSpeed[uid] == player then self:refresh_move_speed(player) end
    end
    for _, player in pairs(self.PendingGrowth or {}) do self:apply_growth(player) end
end

return FishAbility
