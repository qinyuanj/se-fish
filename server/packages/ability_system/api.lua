--技能系统 - server端api
--服务端权威技能 API 实现；仅由根 AbilityAPI.lua 在服务端加载。

local AbilityConstants = require("common.packages.ability_system.constants")
local AbilityRegistry = require("common.packages.ability_system.registry")
local SubAbilityPlugin = require("server.packages.ability_system.sub_ability_plugin")

local Task = game:GetService("Task")

local AbilityServerAPI = {}

local function addExistingAbility(config)
	local managerHandler = AbilityRegistry.getManagerHandler(config.manager)
	if not managerHandler or not config.existingScript then
		return false
	end
	local abilityScript = config.existingScript
	local def = AbilityRegistry.getDefinition(config.name)
	if def then
		abilityScript:SetAttribute("AbilityName", config.name)
		abilityScript:SetAttribute("CdTime", def.cdTime)
		abilityScript:SetAttribute("CastTime", def.castTime)
		if def.maxLevel then
			abilityScript:SetAttribute("MaxLevel", def.maxLevel)
		end
		if def.maxChargeCount then
			abilityScript:SetAttribute("MaxChargeCount", def.maxChargeCount)
		end
		if def.pointerType then
			abilityScript:SetAttribute("PointerType", def.pointerType)
		end
		if def.releaseType then
			abilityScript:SetAttribute("ReleaseType", def.releaseType)
		end
	end
	abilityScript:SetAttribute("Index", config.slotIndex)
	AbilityRegistry.addTag(abilityScript, AbilityConstants.Tag.AbilityUnit)
	abilityScript.Parent = config.manager
	local added = managerHandler.addAbility(abilityScript, config.slotIndex)
	if added then
		-- 装好后按配置自动建子技能组（无子技能则内部跳过）
		SubAbilityPlugin.OnAbilityReady(abilityScript)
	end
	return added
end

local function getManagerForUnit(unit)
	if not unit then
		return nil
	end
	if AbilityRegistry.getManagerHandler(unit) then
		return unit
	end
	for _, child in ipairs(unit:GetChildren()) do
		if AbilityRegistry.hasTag(child, AbilityConstants.Tag.AbilityManager) then
			return child
		end
	end
	return nil
end

-- 按技能脚本单位反查其所属子技能组：
-- 组以父脚本为键注册；槽位可能已切为子成员，故需再按子成员反查（与 SwitchNextAbility 同口径）
local function findGroupOfAbility(abilityScript)
	if not abilityScript then
		return nil
	end
	return AbilityRegistry.findGroup(abilityScript) or AbilityRegistry.findGroupByChild(abilityScript)
end

---获取单位身上的技能管理器（按 AbilityManager 标签反查自身或子节点）
---@param unit Unit 目标单位
---@return Script? 技能管理器脚本单位，未找到返回 nil
function AbilityServerAPI.GetManagerForUnit(unit)
	return getManagerForUnit(unit)
end

---给单位装备技能到指定槽位（不传槽位自动找空槽；同槽同预设复用现有实例；
---指定槽位被其他技能占用时覆盖原技能——先移除旧技能再装配，对齐 FS「添加技能」语义）
---@param unit Unit 目标单位
---@param abilityKey string 技能预设 Key
---@param slotIndex integer? 槽位索引（0 基），不传自动找空槽
---@return Script? 技能脚本单位
---@return string? err 失败原因（带 [ability_system] 前缀）
function AbilityServerAPI.AddAbility(unit, abilityKey, slotIndex)
	local manager = getManagerForUnit(unit)
	if not manager or not abilityKey or abilityKey == "" then
		return nil, "[ability_system] AddAbility: manager or abilityKey is invalid"
	end
	local managerHandler = AbilityRegistry.getManagerHandler(manager)
	if not managerHandler then
		return nil, "[ability_system] AddAbility: manager handler not ready"
	end
	slotIndex = slotIndex or managerHandler.getFirstAvailableSlot()
	if not slotIndex then
		return nil, "[ability_system] AddAbility: no available slot"
	end

	local existingHandler = managerHandler.getAbility(slotIndex)
	if existingHandler then
		local existingScript = existingHandler.getScript()
		if existingScript:GetAttribute("AbilityPresetKey") == abilityKey then
			return existingScript
		end
		-- 覆盖添加：移除旧技能（触发「技能失去」+ 客户端槽位摘除），再装配新技能
		managerHandler.removeAbility(slotIndex)
		AbilityRegistry.unregisterAbility(existingScript)
		existingScript:Destroy()
	end

	local World = game:GetService("World")
	local assets = World:CreateAsset(abilityKey)
	local abilityScript = assets and assets[1]
	if not abilityScript then
		return nil, "[ability_system] AddAbility: failed to create ability asset"
	end

	local abilityName = abilityScript:GetAttribute("AbilityName")
	if not abilityName or abilityName == "" then
		abilityName = abilityKey
	end
	abilityScript:SetAttribute("AbilityPresetKey", abilityKey)
	local added = addExistingAbility({
		name = abilityName,
		slotIndex = slotIndex,
		manager = manager,
		existingScript = abilityScript,
	})
	if not added then
		abilityScript:Destroy()
		return nil, "[ability_system] AddAbility: failed to register ability"
	end
	return abilityScript
end

---获取指定槽位的技能脚本单位
---@param unit Unit 目标单位
---@param abilityIndex integer 槽位索引（0 基）
---@return Script? 技能脚本单位，未找到返回 nil
function AbilityServerAPI.GetAbility(unit, abilityIndex)
	local manager = getManagerForUnit(unit)
	if not manager then
		return nil
	end
	local managerHandler = AbilityRegistry.getManagerHandler(manager)
	if not managerHandler then
		return nil
	end
	local abilityHandler = managerHandler.getAbility(abilityIndex)
	if not abilityHandler then
		return nil
	end
	return abilityHandler.getScript()
end

---按技能脚本单位反查其 handler
---@param abilityScript Script 技能脚本单位
---@return table? handler，未注册返回 nil
function AbilityServerAPI.GetAbilityByScript(abilityScript)
	return AbilityRegistry.getAbilityHandler(abilityScript)
end

---施放指定槽位的技能
---@param unit Unit 目标单位
---@param abilityIndex integer 槽位索引（0 基）
---@param releasePoint Vector3? 释放点
---@param releaseDir Vector3? 释放方向
---@param releaseTarget integer? 释放目标
---@param fromClient boolean? 是否来自客户端请求（true 时启用"蓄力已打断"竞态守卫）
---@return boolean 是否成功开始施法
function AbilityServerAPI.CastAbility(unit, abilityIndex, releasePoint, releaseDir, releaseTarget, fromClient)
	local manager = getManagerForUnit(unit)
	if not manager then
		return false, "[ability_system] CastAbility: manager not found"
	end
	local managerHandler = AbilityRegistry.getManagerHandler(manager)
	if not managerHandler then
		return false, "[ability_system] CastAbility: manager handler not ready"
	end
	local abilityHandler = managerHandler.getAbility(abilityIndex)
	if not abilityHandler then
		return false, "[ability_system] CastAbility: ability not found in slot"
	end
	-- "松开先于广播"竞态守卫：本轮蓄力已被打断时，撤销本次在途客户端施法请求
	-- （一次性消费；ECA/服务端主动施法不走 fromClient=true 路径）
	if fromClient and abilityHandler.consumeAccumulateBroken and abilityHandler.consumeAccumulateBroken() then
		return false, "[ability_system] CastAbility: accumulate broken, in-flight cast cancelled"
	end
	return abilityHandler.startCast(releasePoint, releaseDir, releaseTarget)
end

---打断指定槽位技能的施法
---@param unit Unit 目标单位
---@param abilityIndex integer 槽位索引（0 基）
---@return boolean 是否成功打断
function AbilityServerAPI.StopAbility(unit, abilityIndex)
	local manager = getManagerForUnit(unit)
	if not manager then
		return false, "[ability_system] StopAbility: manager not found"
	end
	local managerHandler = AbilityRegistry.getManagerHandler(manager)
	if not managerHandler then
		return false, "[ability_system] StopAbility: manager handler not ready"
	end
	local abilityHandler = managerHandler.getAbility(abilityIndex)
	if not abilityHandler then
		return false, "[ability_system] StopAbility: ability not found in slot"
	end
	abilityHandler.breakCast()
	return true
end

---让指定槽位的技能进入蓄力
---@param unit Unit 目标单位
---@param abilityIndex integer 槽位索引（0 基）
---@return boolean 是否成功进入蓄力
function AbilityServerAPI.AccumulateAbility(unit, abilityIndex)
	local manager = getManagerForUnit(unit)
	if not manager then
		return false, "[ability_system] AccumulateAbility: manager not found"
	end
	local managerHandler = AbilityRegistry.getManagerHandler(manager)
	if not managerHandler then
		return false, "[ability_system] AccumulateAbility: manager handler not ready"
	end
	local abilityHandler = managerHandler.getAbility(abilityIndex)
	if not abilityHandler then
		return false, "[ability_system] AccumulateAbility: ability not found in slot"
	end
	return abilityHandler.startAccumulate()
end

-- 切换子技能组下一个成员（客户端 SwitchNext 请求的服务端入口；
-- 对任意 SwitchMode 的组均可显式调用，Manual 模式依赖此入口触发轮转）
---切换子技能组到下一个成员（任意 SwitchMode 均可显式调用）
---@param unit Unit 目标单位
---@param parentSlotIndex integer 父技能槽位索引（0 基）
---@return boolean 是否成功切换
function AbilityServerAPI.SwitchNextAbility(unit, parentSlotIndex)
	local manager = getManagerForUnit(unit)
	if not manager or not parentSlotIndex then
		return false, "[ability_system] SwitchNextAbility: manager or parentSlotIndex is invalid"
	end
	local managerHandler = AbilityRegistry.getManagerHandler(manager)
	local abilityHandler = managerHandler and managerHandler.getAbility(parentSlotIndex)
	local abilityScript = abilityHandler and abilityHandler.getScript()
	-- 组以父脚本为键注册；切换后槽位可能已是子技能，故需再按子成员反查
	local group = abilityScript
		and (
			AbilityRegistry.findGroup(abilityScript)
			or AbilityRegistry.findGroupByChild(abilityScript)
		)
	if not group or not group.activateNext then
		return false, "[ability_system] SwitchNextAbility: no switchable group at slot"
	end
	return group.activateNext() or false
end

-- 技能实体版切换入口（ECA「切换为父技能 / 切换为子技能 / 切换一次技能」）；
-- 组反查失败（该技能未建组/无子技能）时返回 false，无事发生

---切换为父技能（子技能组第 1 位成员）
---@param abilityScript Script 技能脚本单位
---@return boolean 是否成功切换
function AbilityServerAPI.SwitchToParent(abilityScript)
	local group = findGroupOfAbility(abilityScript)
	if not group or not group.switchTo then
		return false, "[ability_system] SwitchToParent: no switchable group"
	end
	return group.switchTo(1) or false
end

---切换为指定子技能（子技能序号 0 基，对应 SubAbilities 列表下标）
---@param abilityScript Script 技能脚本单位
---@param childIndex integer 子技能序号（0 基）
---@return boolean 是否成功切换
function AbilityServerAPI.SwitchToChild(abilityScript, childIndex)
	if childIndex == nil or childIndex < 0 then
		return false, "[ability_system] SwitchToChild: invalid childIndex"
	end
	local group = findGroupOfAbility(abilityScript)
	if not group or not group.switchTo then
		return false, "[ability_system] SwitchToChild: no switchable group"
	end
	-- 组成员：[1]=父技能，[2..]=子技能（SubAbilities[0] 对应 members[2]）
	local targetIndex = childIndex + 2
	if targetIndex > #group.members then
		return false
	end
	return group.switchTo(targetIndex) or false
end

---按切换规则切换一次技能（子技能组下一个成员）
---@param abilityScript Script 技能脚本单位
---@return boolean 是否成功切换
function AbilityServerAPI.SwitchAbilityNext(abilityScript)
	local group = findGroupOfAbility(abilityScript)
	if not group or not group.activateNext then
		return false, "[ability_system] SwitchAbilityNext: no switchable group"
	end
	return group.activateNext() or false
end

---把已装备技能移动到指定槽位
---@param unit Unit 目标单位
---@param ability Script 技能脚本单位
---@param slotIndex integer 目标槽位索引（0 基）
---@return Script? 技能脚本单位，失败返回 nil
function AbilityServerAPI.SetAbilityToSlot(unit, ability, slotIndex)
	local manager = getManagerForUnit(unit)
	if not manager or not ability or not slotIndex then
		return nil
	end
	local managerHandler = AbilityRegistry.getManagerHandler(manager)
	if not managerHandler then
		return nil
	end
	local abilityHandler = AbilityRegistry.getAbilityHandler(ability)
	if not abilityHandler then
		return nil
	end
	local abilityScript = abilityHandler.getScript()
	local fromIndex = abilityScript:GetAttribute("Index")
	if not fromIndex then
		return nil
	end
	if fromIndex == slotIndex then
		return abilityScript
	end
	if not managerHandler.moveAbility(fromIndex, slotIndex) then
		return nil
	end
	return abilityScript
end

---把技能替换到指定槽位（ECA「替换技能」）：
---被替换的技能不删除，与目标技能交换槽位位置（目标槽位为空时即搬移）
---@param unit Unit 目标单位
---@param ability Script 技能脚本单位
---@param slotIndex integer 目标槽位索引（0 基）
---@return boolean 是否成功替换
function AbilityServerAPI.ReplaceAbility(unit, ability, slotIndex)
	local manager = getManagerForUnit(unit)
	if not manager or not ability or slotIndex == nil then
		return false, "[ability_system] ReplaceAbility: manager/ability/slotIndex is invalid"
	end
	if slotIndex < AbilityConstants.SLOT_BASE then
		return false, "[ability_system] ReplaceAbility: invalid slotIndex"
	end
	local managerHandler = AbilityRegistry.getManagerHandler(manager)
	if not managerHandler then
		return false, "[ability_system] ReplaceAbility: manager handler not ready"
	end
	local abilityHandler = AbilityRegistry.getAbilityHandler(ability)
	if not abilityHandler then
		return false, "[ability_system] ReplaceAbility: ability handler not found"
	end
	local abilityScript = abilityHandler.getScript()
	local fromIndex = abilityScript:GetAttribute("Index")
	if fromIndex == nil or fromIndex < AbilityConstants.SLOT_BASE then
		return false, "[ability_system] ReplaceAbility: ability not in slot"
	end
	if fromIndex == slotIndex then
		return true
	end
	return managerHandler.moveAbility(fromIndex, slotIndex) and true or false
end

---按技能预设 Key 移除该单位所有对应技能
---@param unit Unit 目标单位
---@param abilityKey string 技能预设 Key
function AbilityServerAPI.RemoveAbilityByKey(unit, abilityKey)
	local manager = getManagerForUnit(unit)
	if not manager or not abilityKey then
		return
	end
	local managerHandler = AbilityRegistry.getManagerHandler(manager)
	if not managerHandler then
		return
	end
	-- 先快照再逐个移除（getAbilities 返回新数组，遍历中改槽位是安全的）
	for _, abilityScript in ipairs(managerHandler.getAbilities()) do
		if abilityScript:GetAttribute("AbilityPresetKey") == abilityKey then
			local slotIndex = abilityScript:GetAttribute("Index")
			if slotIndex ~= nil then
				managerHandler.removeAbility(slotIndex)
			end
			AbilityRegistry.unregisterAbility(abilityScript)
			abilityScript:Destroy()
		end
	end
end

-- 移除指定槽位的技能
---移除指定槽位的技能
---@param unit Unit 目标单位
---@param slotIndex integer 槽位索引（0 基）
---@return Script? 被移除的技能脚本单位
function AbilityServerAPI.RemoveAbility(unit, slotIndex)
	local manager = getManagerForUnit(unit)
	if not manager or not slotIndex then
		return nil
	end
	local managerHandler = AbilityRegistry.getManagerHandler(manager)
	if not managerHandler then
		return nil
	end
	local abilityScript = managerHandler.removeAbility(slotIndex)
	if abilityScript then
		AbilityRegistry.unregisterAbility(abilityScript)
		abilityScript:Destroy()
	end
	return abilityScript
end

-- 按技能脚本单位移除技能（ECA「移除技能」）：
-- 已入槽走槽位移除；未入槽（休眠子技能等）直接反注册并销毁
---@param abilityScript Script 技能脚本单位
---@return Script? 被移除的技能脚本单位
function AbilityServerAPI.RemoveAbilityEntity(abilityScript)
	if not abilityScript then
		return nil
	end
	local manager = abilityScript.Parent
	local managerHandler = manager and AbilityRegistry.getManagerHandler(manager)
	local slotIndex = abilityScript:GetAttribute("Index")
	if
		managerHandler
		and slotIndex ~= nil
		and slotIndex >= AbilityConstants.SLOT_BASE
	then
		return AbilityServerAPI.RemoveAbility(managerHandler.getOwner(), slotIndex)
	end
	AbilityRegistry.unregisterAbility(abilityScript)
	abilityScript:Destroy()
	return abilityScript
end

-- 获取单位所有已装备的技能列表
---获取单位所有已装备的技能脚本单位列表
---@param unit Unit 目标单位
---@return Script[] 技能脚本单位列表
function AbilityServerAPI.GetAbilities(unit)
	local manager = getManagerForUnit(unit)
	if not manager then
		return {}
	end
	local managerHandler = AbilityRegistry.getManagerHandler(manager)
	return managerHandler.getAbilities()
end

---按技能预设 Key 获取单位身上的技能脚本单位（同预设多实例时返回第一个）
---@param unit Unit 目标单位
---@param abilityKey string 技能预设 Key
---@return Script? 技能脚本单位，未找到返回 nil
function AbilityServerAPI.GetAbilityByKey(unit, abilityKey)
	local manager = getManagerForUnit(unit)
	if not manager or not abilityKey or abilityKey == "" then
		return nil
	end
	local managerHandler = AbilityRegistry.getManagerHandler(manager)
	for _, abilityScript in ipairs(managerHandler.getAbilities()) do
		if abilityScript:GetAttribute("AbilityPresetKey") == abilityKey then
			return abilityScript
		end
	end
	return nil
end

-- 获取指定槽位范围内的技能列表
---获取指定槽位范围内的技能脚本单位列表
---@param unit Unit 目标单位
---@param startIndex integer 起始槽位（0 基）
---@param endIndex integer 结束槽位（0 基）
---@return Script[] 技能脚本单位列表
function AbilityServerAPI.GetAbilitiesFromIndexRange(unit, startIndex, endIndex)
	local manager = getManagerForUnit(unit)
	if not manager or not startIndex or not endIndex then
		return {}
	end
	local managerHandler = AbilityRegistry.getManagerHandler(manager)
	return managerHandler.getAbilitiesInSlotRange(startIndex, endIndex)
end

-- 禁用 / 恢复技能（ECA「禁用指定技能」）
--
-- 语义：按「标记」禁用指定技能——禁用期间不能施放（canUse 恒 false，施法/蓄力入口均被拦截），
-- 可选将技能槽位按钮置灰（广播 ForbidSlot），可选在技能本次施法结束后自动恢复；
-- 持续时间到期或施法结束自动恢复；同一标记重复调用按「先恢复旧状态再重新禁用」处理。
-- 状态存模块本地表（技能销毁时随 Destroying 清理，避免 timer/连接泄漏）。

local _disableStates = setmetatable({}, { __mode = "k" })

-- 恢复指定标记的禁用状态（内部与公开入口共用）
local function _clearDisableMarker(ability, marker)
	local st = _disableStates[ability]
	if not st then
		return
	end
	local entry = st.markers[marker]
	if not entry then
		return
	end
	st.markers[marker] = nil

	-- 1) 撤除施放条件注入
	local handler = AbilityRegistry.getAbilityHandler(ability)
	if handler then
		handler.removeUseCondition("__disable_" .. tostring(marker))
	end
	-- 2) 清理计时/连接
	if entry.timer then
		Task:Cancel(entry.timer)
		entry.timer = nil
	end
	if entry.conn then
		entry.conn:Disconnect()
		entry.conn = nil
	end
	-- 3) 置灰恢复：全部置灰标记清空后恢复槽位
	if entry.grayout then
		st.grayCount = (st.grayCount or 0) - 1
		if st.grayCount <= 0 and ability then
			local okSlot, slot = pcall(function()
				return ability:GetAttribute("Index")
			end)
			local manager = ability.Parent
			local managerHandler = manager and AbilityRegistry.getManagerHandler(manager)
			if managerHandler and okSlot and slot ~= nil and slot >= AbilityConstants.SLOT_BASE then
				managerHandler.forbidSlot(slot, false, false)
			end
		end
	end
	-- 4) 全部标记清空：回收状态与销毁监听
	if next(st.markers) == nil then
		if st.destroyConn then
			st.destroyConn:Disconnect()
			st.destroyConn = nil
		end
		_disableStates[ability] = nil
	end
end

-- 取（或惰性创建）技能禁用状态表；创建时挂 Destroying 清理
local function _ensureDisableState(ability)
	local st = _disableStates[ability]
	if st then
		return st
	end
	st = { markers = {}, grayCount = 0 }
	_disableStates[ability] = st
	-- 技能销毁时清理全部禁用状态（timer / 连接）
	if ability.Destroying then
		st.destroyConn = ability.Destroying:Connect(function()
			local cur = _disableStates[ability]
			if not cur then
				return
			end
			-- 先快照标记再逐个恢复（遍历中会删表项）
			local markerList = {}
			for m in pairs(cur.markers) do
				markerList[#markerList + 1] = m
			end
			for _, m in ipairs(markerList) do
				_clearDisableMarker(ability, m)
			end
		end)
	end
	return st
end

---禁用指定技能
---@param marker integer 标记（同标记重复调用按重启处理）
---@param unit Unit 目标单位（技能拥有者）
---@param ability Script 技能脚本单位
---@param duration number 持续时间（秒；<=0 表示不按时间恢复）
---@param grayout boolean 是否将技能按钮置灰
---@param recoverAfterCast boolean 是否在技能本次施法结束后恢复
---@return boolean 是否成功禁用
function AbilityServerAPI.DisableAbility(marker, unit, ability, duration, grayout, recoverAfterCast)
	marker = marker or 0
	if not ability then
		return false, "[ability_system] DisableAbility: ability is invalid"
	end
	local handler = AbilityRegistry.getAbilityHandler(ability)
	if not handler then
		return false, "[ability_system] DisableAbility: ability handler not found"
	end
	local manager = ability.Parent
	local managerHandler = manager and AbilityRegistry.getManagerHandler(manager)

	-- 同标记重入：先还原旧状态（可能整体回收），再重新取/建状态表
	local st = _disableStates[ability]
	if st and st.markers[marker] then
		_clearDisableMarker(ability, marker)
	end
	st = _ensureDisableState(ability)

	local entry = {}
	st.markers[marker] = entry

	-- 1) 施放条件注入：禁用期间 canUse 恒 false（startCast / startAccumulate 均被拦截）
	handler.addUseCondition("__disable_" .. tostring(marker), function()
		return false
	end)
	-- 2) 按钮置灰：广播槽位禁用（grayout 关闭时不动 UI）
	if grayout then
		entry.grayout = true
		st.grayCount = (st.grayCount or 0) + 1
		local slot = ability:GetAttribute("Index")
		if managerHandler and slot ~= nil and slot >= AbilityConstants.SLOT_BASE then
			managerHandler.forbidSlot(slot, true, true)
		end
	end
	-- 3) 持续时间到期恢复
	if duration and duration > 0 then
		entry.timer = Task:Delay(duration, function()
			entry.timer = nil
			_clearDisableMarker(ability, marker)
		end)
	end
	-- 4) 本次施法结束后恢复
	if recoverAfterCast then
		local signals = handler.getSignals and handler.getSignals()
		if signals and signals.CastEnd then
			entry.conn = signals.CastEnd:Connect(function()
				_clearDisableMarker(ability, marker)
			end)
		end
	end
	return true
end

---恢复指定标记的技能禁用（与 DisableAbility 的标记对应）
---@param marker integer 标记
---@param unit Unit 目标单位（技能拥有者）
---@param ability Script 技能脚本单位
---@return boolean 是否成功恢复
function AbilityServerAPI.EnableAbility(marker, unit, ability)
	marker = marker or 0
	if not ability or not _disableStates[ability] then
		return false
	end
	if not _disableStates[ability].markers[marker] then
		return false
	end
	_clearDisableMarker(ability, marker)
	return true
end

-- 客户端施法请求监听（事件分发入口）
--
-- RemoteEvent 契约：OnServerEvent(player, payload)，
-- 客户端载荷为单参数 table：{ action, ownerId, index, args = {...} }。
-- 模块加载时自动注册（幂等）。

local _eventsRegistered = false

---注册客户端施法请求监听（模块加载时自动调用，幂等）
function AbilityServerAPI.RegisterEvents()
	if _eventsRegistered then
		return
	end
	_eventsRegistered = true

	local AbilityEventDefs = require("common.packages.ability_system.event_defs")
	local remoteEvent = AbilityEventDefs.getRemote()

	remoteEvent.OnServerEvent:Connect(function(player, payload)
		-- 单参数解包
		local action, index, releasePoint, releaseDir, releaseTarget
		if type(payload) == "table" and payload.action then
			action = payload.action
			index = payload.index
			local args = payload.args or {}
			releasePoint, releaseDir, releaseTarget = args[1], args[2], args[3]
		else
			action = payload
		end

		if not action then
			return
		end

		local character = player and player.Character
		if not character then
			return
		end

		if action == AbilityEventDefs.ClientAction.Cast then
			AbilityServerAPI.CastAbility(character, index, releasePoint, releaseDir, releaseTarget, true)
		elseif action == AbilityEventDefs.ClientAction.BreakCast then
			AbilityServerAPI.StopAbility(character, index)
		elseif action == AbilityEventDefs.ClientAction.Accumulate then
			AbilityServerAPI.AccumulateAbility(character, index)
		elseif action == AbilityEventDefs.ClientAction.SwitchNext then
			-- 切换子技能组下一个成员（组反查失败=该槽位无子技能组，安全忽略）
			AbilityServerAPI.SwitchNextAbility(character, index)
		end
	end)
end

-- 模块加载即注册（服务端上下文；幂等防重复）

local RunService = game:GetService("RunService")
if RunService:IsServer() then
	AbilityServerAPI.RegisterEvents()
end

return AbilityServerAPI
