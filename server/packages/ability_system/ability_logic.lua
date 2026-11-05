--技能系统 - server技能实例状态逻辑
--技能实例服务端共享逻辑：CD / 施法 / 蓄力 / 充能 四状态机。
-- 由技能预设壳（ability_script.lua）在服务端 require 并调用 Attach(script)。

local AbilityConstants = require("common.packages.ability_system.constants")
local AbilityEventDefs = require("common.packages.ability_system.event_defs")
local AbilityEventBridge = require("server.packages.ability_system.event_bridge")
local AbilityRegistry = require("common.packages.ability_system.registry")
local AbilityUtils = require("common.packages.ability_system.util")
local AbilityTargetFilter = require("common.packages.ability_system.target_filter")

local AbilityItemLogic = {}

local _attached = setmetatable({}, { __mode = "k" })

-- 业务逻辑

function AbilityItemLogic.Attach(abilityScript)
	local self = abilityScript
	local RunService = game:GetService("RunService")

	if not RunService:IsServer() then
		return
	end

	-- 重复挂载保护
	if _attached[self] then
		print("[AbilityItemLogic] Attach skipped (already attached): " .. tostring(self))
		return
	end
	_attached[self] = true
	print("[AbilityItemLogic] Attach start: " .. tostring(self))

	local World = game:GetService("World")
	local Task = game:GetService("Task")

	-- 注入时间函数
	AbilityUtils.setServerTimeFn(function()
		return World:GetServerTime()
	end)

	-- 初始化运行时状态

	-- 归属字段为字符串（玩家名）；真实值由 manager_logic.addAbility 继承管理器写入
	self:SetAttribute("OwnerId", "")
	-- Index 已由 AddAbility 写入时保留（AddAbility 先于本 Attach 执行的情况），
	-- 仅在未设置时初始化为未入槽哨兵（-1），避免覆盖真实槽位。
	-- 注意：0 是合法槽位（SLOT_BASE），哨兵必须用 SLOT_INDEX_UNASSIGNED。
	if self:GetAttribute("Index") == nil then
		self:SetAttribute("Index", AbilityConstants.SLOT_INDEX_UNASSIGNED)
	end
	self:SetAttribute("Level", 1)
	self:SetAttribute("InCD", false)
	self:SetAttribute("CdFinishTime", 0)
	self:SetAttribute("InCast", false)
	self:SetAttribute("CastStartTime", 0)
	self:SetAttribute("AccumulateStartTime", 0)
	-- 蓄力：本次施法捕获的蓄力比（0~1），startCast 时写入，作者可在 CastStart 钩子读取
	self:SetAttribute("AccumulateRatio", 0)
	local maxChargeCount = self:GetAttribute("MaxChargeCount") or 0
	if self:GetAttribute("IsChargeConsuming") then
		self:SetAttribute("ChargeCount", maxChargeCount)
	else
		self:SetAttribute("ChargeCount", 0)
	end
	self:SetAttribute("ReleasePoint", nil)
	self:SetAttribute("ReleaseDir", nil)
	self:SetAttribute("ReleaseTarget", 0)

	-- 创建能力级 signals（BindableEvent 事件单位挂在 abilityScript 下）
	local signals = AbilityEventDefs.createAbilitySignals(self)

	-- 单一 RemoteEvent 通道
	local remoteEvent = AbilityEventDefs.getRemote()

	-- ability 自身状态（仅本端可见，不同步）
	local state = {
		castTimer = nil, -- Task:Delay 句柄（施法）
		cdTimer = nil, -- Task:Delay 句柄（CD）
		chargeTimer = nil, -- Task:Delay 句柄（充能自动补充）
		chargeStartTime = nil, -- 当前充能周期开始时刻
		currentChargeInterval = nil, -- 当前充能周期间隔
		cdEnteredInUse = false, -- 本轮使用内是否已激活过 CD（锚点 enterCD 置真，供 endCast 兜底判重）
		accumulateBroken = false, -- 本轮蓄力已被打断（"松开先于广播"竞态守卫，客户端施法路径一次性消费）
	}

	-- UseCondition 外部条件注入
	local _useConditions = {}

	-- 标记

	AbilityRegistry.addTag(self, AbilityConstants.Tag.AbilityUnit)

	-- 辅助

	local function getAttrib(name)
		return self:GetAttribute(name)
	end

	local function setAttrib(name, value)
		self:SetAttribute(name, value)
	end

	-- 事件收口辅助

	-- 单位级事件中继：把技能级关键事件中继到拥有者单位的事件单位
	-- （ECA「当 此类角色/生物 冷却完成/充能完成/技能降级」的绑定目标）
	local function relayUnitEvent(eventName, ...)
		AbilityEventBridge.fireOnOwner(self, eventName, ...)
	end

	-- 冷却结束统一收口：属性复位 + CDEnd 事件 + 单位级中继
	local function finishCD()
		setAttrib("InCD", false)
		signals.CDEnd:Fire(self)
		remoteEvent:FireAllClients(AbilityEventDefs.packServerPayload(AbilityEventDefs.ServerAction.OnCDEnd, self.UnitId))
		relayUnitEvent(AbilityConstants.UnitEvent.CDEnd, self)
	end

	-- 充能完成统一收口：ChargeFull 事件 + 单位级中继
	local function fireChargeFull()
		signals.ChargeFull:Fire(self)
		relayUnitEvent(AbilityConstants.UnitEvent.ChargeFull, self)
	end

	-- 完成一次充能：计数 +1（夹取上限）、属性/事件/广播，返回新计数
	local function completeOneCharge()
		local cur = getAttrib("ChargeCount") or 0
		local max = getAttrib("MaxChargeCount") or 1
		local amount = getAttrib("ChargeAmount") or 1
		local newCount = math.min(cur + amount, max)
		setAttrib("ChargeCount", newCount)
		signals.Charge:Fire(self, newCount)
		remoteEvent:FireAllClients(
			AbilityEventDefs.packServerPayload(AbilityEventDefs.ServerAction.OnCharge, self.UnitId, newCount)
		)
		if newCount >= max then
			fireChargeFull()
		end
		return newCount
	end

	-- 技能降级统一收口：技能级 OnDowngrade + 单位级中继
	local function fireDowngrade(newLevel)
		signals.OnDowngrade:Fire(self, newLevel)
		relayUnitEvent(AbilityConstants.UnitEvent.Downgrade, self, newLevel)
	end

	-- 技能升级统一收口：技能级 Upgraded + 管理器级 AbilityUpgraded
	local function fireUpgraded(newLevel)
		signals.Upgraded:Fire(self, newLevel)
		local managerHandler = AbilityRegistry.getManagerHandler(self.Parent)
		if managerHandler then
			local ms = managerHandler.getSignals and managerHandler.getSignals()
			if ms and ms.AbilityUpgraded then
				ms.AbilityUpgraded:Fire(self, newLevel)
			end
		end
	end

	-- handler 接口

	local handler = {}

	function handler.getId()
		return self.UnitId
	end
	function handler.getSignals()
		return signals
	end

	function handler.ConnectEvent(eventName, func)
		local sig = signals[eventName]
		if not sig then
			return nil
		end
		return sig:Connect(func)
	end

	function handler.getScript()
		return self
	end
	function handler.getManager()
		return self.Parent
	end
	function handler._getRawAttribute(name)
		return getAttrib(name)
	end

	-- CD 状态机

	function handler.enterCD(cdTime)
		cdTime = cdTime or getAttrib("CdTime")
		-- 标记本轮使用已激活 CD：endCast 的兜底 CD 不再重复（CD 由 active_cd 锚点激活的场景）
		state.cdEnteredInUse = true
		setAttrib("InCD", true)
		setAttrib("CdFinishTime", AbilityUtils.getServerTime() + cdTime)
		signals.CDStart:Fire(self)
		remoteEvent:FireAllClients(
			AbilityEventDefs.packServerPayload("OnCDStart", self.UnitId, cdTime)
		)
		-- 清旧 timer
		if state.cdTimer then
			Task:Cancel(state.cdTimer)
			state.cdTimer = nil
		end
		-- 起新 timer
		state.cdTimer = Task:Delay(cdTime, function()
			state.cdTimer = nil
			finishCD()
		end)
	end

	-- 设置剩余冷却（ECA「设置技能剩余冷却」）：
	-- 直接改写剩余冷却时间并重排计时；time<=0 立即结束冷却（与自然走完同路径）。
	-- 不触发 CDStart（这是一次时长调整而非新一轮 CD 激活）。
	function handler.setLeftCD(cdTime)
		cdTime = cdTime or 0
		if state.cdTimer then
			Task:Cancel(state.cdTimer)
			state.cdTimer = nil
		end
		if cdTime <= 0 then
			setAttrib("CdFinishTime", 0)
			if getAttrib("InCD") then
				finishCD()
			end
			return
		end
		setAttrib("InCD", true)
		setAttrib("CdFinishTime", AbilityUtils.getServerTime() + cdTime)
		state.cdTimer = Task:Delay(cdTime, function()
			state.cdTimer = nil
			finishCD()
		end)
	end

	-- 施法状态机

	function handler.canUse()
		if getAttrib("InCD") then
			return false
		end
		local limitation = getAttrib("UseLimitation") or 0
		if getAttrib("InCast") and (limitation & 1) == 0 then
			return false
		end
		local owner = self.Parent and self.Parent.Parent
		local controller = owner and owner.Controller
		local state = controller and controller.GetState and controller:GetState() or nil
		local CST = Enums.ControllerStateType
		if CST and state == CST.LostControl and (limitation & 2) == 0 then
			return false
		end
		if CST and state == CST.EggyRoll and (limitation & 4) == 0 then
			return false
		end
		if (limitation & 8) == 0 and controller and controller.GetExtraStates then
			for _, extraState in ipairs(controller:GetExtraStates()) do
				if extraState == "Freezed" then
					return false
				end
			end
		end
		-- 充能消耗型技能需要检查充能次数
		if getAttrib("IsChargeConsuming") and (getAttrib("ChargeCount") or 0) <= 0 then
			return false
		end
		-- 遍历外部注入的条件
		for key, condFunc in pairs(_useConditions) do
			local ok = condFunc()
			if not ok then
				return false
			end
		end
		return true
	end

	function handler.startCast(releasePoint, releaseDir, releaseTarget)
		releasePoint = releasePoint or getAttrib("ReleasePoint")
		releaseDir = releaseDir or getAttrib("ReleaseDir")
		-- 使用尝试开始（合法性检查前触发，结果未定）
		signals.BeforeUse:Fire(self)
		if not handler.canUse() then
			-- 施法被拒但客户端已松开：处于蓄力时兜底退出蓄力态
			if handler.isAccumulating() then
				handler.endAccumulate(true)
			end
			return false
		end

		if state.castTimer then
			Task:Cancel(state.castTimer)
			state.castTimer = nil
		end

		-- 蓄力：进施法前捕获本次释放的蓄力比（作者可在 CastStart 钩子/ECA 读取），
		-- 随后结束蓄力态（AccumulateStartTime 清零）
		local isAccumulating = handler.isAccumulating()
		if isAccumulating then
			setAttrib("AccumulateRatio", handler.getAccumulateRatio())
			handler.endAccumulate(false)
		else
			setAttrib("AccumulateRatio", 0)
		end
		-- 非蓄力路径：本次施法即一轮新的使用，重置"本轮已进 CD"标记；
		-- 蓄力路径的轮次在 startAccumulate 开启（蓄力阶段锚点可能已激活过 CD），此处不重置
		if not isAccumulating then
			state.cdEnteredInUse = false
		end

		-- 可拦截事件
		AbilityEventDefs.fireBefore(signals, "BeforeCast", self, releasePoint, releaseDir)
		setAttrib("InCast", true)
		setAttrib("CastStartTime", AbilityUtils.getServerTime())
		setAttrib("ReleasePoint", releasePoint)
		setAttrib("ReleaseDir", releaseDir)
		if releaseTarget then
			setAttrib("ReleaseTarget", releaseTarget)
		end

		signals.CastStart:Fire(self)
		remoteEvent:FireAllClients(
			AbilityEventDefs.packServerPayload(AbilityEventDefs.ServerAction.OnCastStart, self.UnitId, releasePoint, releaseDir)
		)

		local castTime = getAttrib("CastTime") or AbilityConstants.DEFAULT_CAST_TIME
		state.castTimer = Task:Delay(castTime, function()
			handler.endCast(false)
		end)

		-- 消耗充能次数
		if getAttrib("IsChargeConsuming") then
			local curCharge = getAttrib("ChargeCount") or 0
			if curCharge > 0 then
				setAttrib("ChargeCount", curCharge - 1)
			end
			handler._tryStartCharge()
		end

		-- 本次使用已生效（合法性通过、蓄力放行、充能消耗之后）
		signals.Used:Fire(self)

		return true
	end

	function handler.endCast(broken)
		if not getAttrib("InCast") then
			return
		end
		setAttrib("InCast", false)

		if state.castTimer then
			Task:Cancel(state.castTimer)
			state.castTimer = nil
		end

		if broken then
			signals.CastBreak:Fire(self)
			remoteEvent:FireAllClients(
				AbilityEventDefs.packServerPayload(AbilityEventDefs.ServerAction.OnCastBreak, self.UnitId)
			)
		else
			signals.CastEnd:Fire(self)
			remoteEvent:FireAllClients(AbilityEventDefs.packServerPayload(AbilityEventDefs.ServerAction.OnCastEnd, self.UnitId))
		end

		-- 进入 CD（正常结束才进 CD；被打断可由作者在钩子决定是否进 CD）。
		-- 本轮使用若已由锚点激活过 CD（如 active_cd），则不再重复，避免同一轮进两次 CD
		if not broken and not state.cdEnteredInUse then
			handler.enterCD(getAttrib("CdTime"))
		end
		state.cdEnteredInUse = false
	end

	function handler.breakCast()
		if getAttrib("InCast") then
			handler.endCast(true)
		elseif handler.isAccumulating() then
			-- 蓄力处于施法前阶段：未进施法时的打断 = 退出蓄力态（取消区松开等路径）
			handler.endAccumulate(true)
		end
	end

	-- 蓄力状态机（仅时间式）

	-- 蓄力查询：处于蓄力态（已写开始时刻且未结束）
	function handler.isAccumulating()
		if not getAttrib("EnableAccumulate") then
			return false
		end
		return (getAttrib("AccumulateStartTime") or 0) > 0
	end

	-- 施法前按住进入蓄力态（不依赖 InCast，与客户端按下时机对齐）。
	-- 蓄力比 = 已蓄时长 / MaxAccumulateTime，由 getAccumulateRatio() 读出；
	-- startCast 时捕获进 AccumulateRatio 并结束蓄力。
	function handler.startAccumulate()
		if not getAttrib("EnableAccumulate") then
			return false
		end
		if handler.isAccumulating() then
			return false
		end -- 已在蓄力
		if not handler.canUse() then
			return false
		end -- CD/充能/外部条件不满足时不进蓄力
		-- 本轮使用开始：重置"本轮已进 CD"标记（蓄力阶段锚点在本窗口内激活 CD 时会再置真）
		state.cdEnteredInUse = false
		-- 新一轮使用开始：清除上一轮"已打断"标记（竞态守卫）
		state.accumulateBroken = false
		setAttrib("AccumulateStartTime", AbilityUtils.getServerTime())
		if signals.AccumulateStart then
			signals.AccumulateStart:Fire(self)
		end
		return true
	end

	-- ChargeType 自动充能

	function handler._stopCharge()
		if state.chargeTimer then
			Task:Cancel(state.chargeTimer)
			state.chargeTimer = nil
		end
		state.chargeStartTime = nil
		state.currentChargeInterval = nil
	end

	function handler._tryStartCharge()
		if state.chargeTimer then
			return
		end -- 已在充能
		-- 非充能技能不走自动充能（强制路径见 startChargeCycle）
		if not getAttrib("IsChargeConsuming") then
			return
		end

		local chargeType = getAttrib("ChargeType") or 0
		if chargeType == 0 then
			return
		end -- None

		local cur = getAttrib("ChargeCount") or 0
		local max = getAttrib("MaxChargeCount") or 1
		local needCharge = false
		if chargeType == AbilityConstants.ChargeType.WhenNotFull then
			needCharge = cur < max
		elseif chargeType == AbilityConstants.ChargeType.WhenEmpty then
			needCharge = cur <= 0
		end
		if not needCharge then
			return
		end

		state.chargeStartTime = World:GetServerTime()
		local interval = getAttrib("ChargeInterval") or 1.0
		state.currentChargeInterval = interval
		state.chargeTimer = Task:Delay(interval, function()
			state.chargeTimer = nil
			state.chargeStartTime = nil
			state.currentChargeInterval = nil
			completeOneCharge()
			handler._tryStartCharge() -- 递归：未满继续
		end)
	end

	-- 强制开启一轮充能计时（ECA「设置技能充能冷却」前置）：
	-- 与 _tryStartCharge 不同，不依赖 ChargeType 策略，只要未满且未在充能即可开启
	function handler.startChargeCycle(interval)
		if state.chargeTimer then
			return false
		end
		local cur = getAttrib("ChargeCount") or 0
		local max = getAttrib("MaxChargeCount") or 1
		if cur >= max then
			return false
		end
		local itv = interval or getAttrib("ChargeInterval") or 1.0
		state.chargeStartTime = World:GetServerTime()
		state.currentChargeInterval = itv
		state.chargeTimer = Task:Delay(itv, function()
			state.chargeTimer = nil
			state.chargeStartTime = nil
			state.currentChargeInterval = nil
			completeOneCharge()
			handler._tryStartCharge()
		end)
		return true
	end

	function handler.changeChargeCount(delta)
		if delta == 0 then
			return
		end
		local cur = getAttrib("ChargeCount") or 0
		local max = getAttrib("MaxChargeCount") or 1
		local newCount = cur + delta
		if newCount < 0 then
			newCount = 0
		elseif newCount > max then
			newCount = max
		end
		setAttrib("ChargeCount", newCount)
		if newCount >= max then
			handler._stopCharge()
			fireChargeFull()
		else
			handler._tryStartCharge()
		end
	end

	-- 设置释放次数（ECA「设置技能释放次数」）：绝对值写入并夹取到 [0, MaxChargeCount]；
	-- 达到上限停表并触发充能完成，未满则按充能策略续充
	function handler.setChargeCount(count)
		count = math.floor(count or 0)
		local max = getAttrib("MaxChargeCount") or 1
		if count < 0 then
			count = 0
		end
		if count > max then
			count = max
		end
		local cur = getAttrib("ChargeCount") or 0
		if count == cur then
			return count
		end
		setAttrib("ChargeCount", count)
		if count >= max then
			handler._stopCharge()
			fireChargeFull()
		else
			handler._tryStartCharge()
		end
		return count
	end

	-- 设置最大释放次数（ECA「设置技能最大释放次数」）：写属性并把当前次数夹取到新上限
	function handler.setMaxChargeCount(max)
		max = math.floor(max or 1)
		if max < 1 then
			max = 1
		end
		setAttrib("MaxChargeCount", max)
		local cur = getAttrib("ChargeCount") or 0
		if cur > max then
			handler.setChargeCount(max)
		elseif cur < max then
			handler._tryStartCharge()
		end
		return max
	end

	function handler.upgrade(delta)
		if not handler.canUpgrade() then
			return false
		end
		delta = delta or 1
		local newLevel = math.min((getAttrib("Level") or 1) + delta, getAttrib("MaxLevel") or 5)
		setAttrib("Level", newLevel)
		fireUpgraded(newLevel)
		return newLevel
	end

	function handler.canUpgrade()
		local upgradable = getAttrib("Upgradable")
		if upgradable == false then
			return false
		end
		local level = getAttrib("Level") or 1
		local maxLevel = getAttrib("MaxLevel") or 1
		if level >= maxLevel then
			return false
		end
		local requirements = getAttrib("LevelRequirements")
		if requirements and type(requirements) == "table" and #requirements > 0 then
			local nextLevel = level + 1
			local requiredOwnerLevel = requirements[nextLevel]
			if requiredOwnerLevel ~= nil then
				local owner = self.Parent and self.Parent.Parent
				local ownerLevel = owner
						and owner.CustomProperty
						and owner.CustomProperty.LevelRuleLevel
					or 0
				if ownerLevel < requiredOwnerLevel then
					return false
				end
			end
		end
		return true
	end

	function handler.decreaseLevel(delta)
		delta = delta or 1
		local oldLevel = getAttrib("Level") or 1
		local newLevel = math.max(1, oldLevel - delta)
		if newLevel == oldLevel then
			return newLevel
		end
		setAttrib("Level", newLevel)
		fireDowngrade(newLevel)
		return newLevel
	end

	-- 设置等级（ECA「设置技能等级」）：升/降都可能发生；
	-- 降低路径按「技能降级」语义补发 OnDowngrade（含单位级中继）
	function handler.setLevel(level)
		local max = getAttrib("MaxLevel") or 5
		level = math.max(1, math.min(level, max))
		local oldLevel = getAttrib("Level") or 1
		if level == oldLevel then
			return level
		end
		setAttrib("Level", level)
		if level < oldLevel then
			fireDowngrade(level)
		end
		return level
	end

	function handler.setMaxLevel(max)
		max = math.floor(max or 1)
		if max < 1 then
			max = 1
		end
		setAttrib("MaxLevel", max)
		local curLevel = getAttrib("Level") or 1
		if curLevel > max then
			setAttrib("Level", max)
			fireDowngrade(max)
		end
		return max
	end

	-- UseLimitation 位掩码

	function handler.getLimitation(limitationType)
		return ((getAttrib("UseLimitation") or 0) & limitationType) ~= 0
	end

	function handler.setLimitation(limitationType, enable)
		local current = getAttrib("UseLimitation") or 0
		if enable then
			setAttrib("UseLimitation", current | limitationType)
		else
			setAttrib("UseLimitation", current & ~limitationType)
		end
	end

	-- UseCondition 外部注入

	function handler.addUseCondition(key, func)
		_useConditions[key] = func
	end

	function handler.removeUseCondition(key)
		_useConditions[key] = nil
	end

	-- 蓄力辅助

	-- broken=false 蓄力成功转入施法（AccumulateRatio 已捕获）；true = 被打断/被拒未转施法。
	-- broken 时先发 AccumulateBreak，再无条件发 AccumulateEnd。
	function handler.endAccumulate(broken)
		if not getAttrib("EnableAccumulate") then
			return
		end
		-- 清开始时刻：退出蓄力态，getAccumulateRatio() 随之归零
		setAttrib("AccumulateStartTime", 0)
		-- "松开先于广播"竞态守卫：标记本轮使用已取消（由客户端施法请求路径一次性消费）
		if broken then
			state.accumulateBroken = true
		end
		if broken and signals.AccumulateBreak then
			signals.AccumulateBreak:Fire(self)
		end
		if signals.AccumulateEnd then
			signals.AccumulateEnd:Fire(self)
		end
		-- 同步客户端：蓄力结束/打断（broken=true 未转施法），客户端据此收掉
		-- 按触交互（指示器/拖拽指示/取消区）并作废本次触控序列；
		-- 在途的客户端施法请求由 state.accumulateBroken 守卫撤销（见 consumeAccumulateBroken）
		remoteEvent:FireAllClients(
			AbilityEventDefs.packServerPayload(
				AbilityEventDefs.ServerAction.OnAccumulateEnd,
				self.UnitId,
				broken and true or false
			)
		)
	end

	-- "松开先于广播"竞态守卫（一次性消费）：本轮蓄力已被打断且尚未重新进入蓄力时
	-- 返回 true 并清除标记；供客户端施法请求路径（AbilityServerAPI.CastAbility）调用。
	function handler.consumeAccumulateBroken()
		local broken = state.accumulateBroken == true
		state.accumulateBroken = false
		return broken
	end

	function handler.getAccumulateRatio()
		if not getAttrib("EnableAccumulate") then
			return 0
		end
		local startTime = getAttrib("AccumulateStartTime") or 0
		if startTime <= 0 then
			return 0
		end
		local elapsed = World:GetServerTime() - startTime
		if elapsed <= 0 then
			return 0
		end
		local maxTime = getAttrib("MaxAccumulateTime") or 1.0
		if maxTime <= 0 then
			return 1
		end
		return math.min(elapsed / maxTime, 1.0)
	end

	-- API 方法

	function handler.getLeftCD()
		local finishTime = getAttrib("CdFinishTime") or 0
		local curTime = World:GetServerTime()
		if finishTime <= curTime then
			return 0
		end
		return finishTime - curTime
	end

	function handler.getCdTime()
		return getAttrib("CdTime") or 0
	end

	function handler.getReleasePoint()
		return getAttrib("ReleasePoint")
	end

	function handler.getReleaseDirection()
		return getAttrib("ReleaseDir")
	end

	function handler.getReleaseTarget()
		return getAttrib("ReleaseTarget") or 0
	end

	function handler.getReleaseDistance()
		return getAttrib("ReleaseDistance") or 10.0
	end

	function handler.isValidTarget(target)
		local owner = self.Parent and self.Parent.Parent
		return AbilityTargetFilter.isValidTarget(handler, target, owner)
	end

	function handler.getValidTargetsInRange(height)
		local owner = self.Parent and self.Parent.Parent
		return AbilityTargetFilter.getValidTargetsInRange(handler, owner, height)
	end

	function handler.setReleaseDistance(d)
		setAttrib("ReleaseDistance", d)
	end

	function handler.setReleaseRadius(r)
		setAttrib("ReleaseRadius", r)
	end

	function handler.setAffectWidth(w)
		setAttrib("AffectWidth", w or 0)
	end

	-- 增加类（ECA「增加技能施法距离/作用宽度/作用半径」）：在现值上叠加增量
	function handler.addReleaseDistance(delta)
		setAttrib("ReleaseDistance", (getAttrib("ReleaseDistance") or 0) + (delta or 0))
	end

	function handler.addAffectWidth(delta)
		setAttrib("AffectWidth", (getAttrib("AffectWidth") or 0) + (delta or 0))
	end

	function handler.addReleaseRadius(delta)
		setAttrib("ReleaseRadius", (getAttrib("ReleaseRadius") or 0) + (delta or 0))
	end

	function handler.getReleaseDistance()
		return getAttrib("ReleaseDistance") or 0
	end

	function handler.getAffectWidth()
		return getAttrib("AffectWidth") or 0
	end

	function handler.getReleaseRadius()
		return getAttrib("ReleaseRadius") or 0
	end

	function handler.getParabolaHorizontalSpeed()
		return getAttrib("ParabolaHorizontalSpeed") or 0
	end

	function handler.getParabolaVerticalSpeed()
		return getAttrib("ParabolaVerticalSpeed") or 0
	end

	function handler.getPointerType()
		return getAttrib("PointerType") or 0
	end

	function handler.getTargetType()
		return getAttrib("TargetType") or 0
	end

	function handler.getPresetKey()
		return getAttrib("AbilityPresetKey") or ""
	end

	function handler.getInCD()
		return getAttrib("InCD") == true
	end

	function handler.getInCast()
		return getAttrib("InCast") == true
	end

	function handler.getLevel()
		return getAttrib("Level") or 1
	end

	function handler.getMaxLevel()
		return getAttrib("MaxLevel") or 1
	end

	function handler.getChargeCount()
		return getAttrib("ChargeCount") or 0
	end

	function handler.getMaxChargeCount()
		return getAttrib("MaxChargeCount") or 1
	end

	function handler.getChargeInterval()
		return getAttrib("ChargeInterval") or 1.0
	end

	function handler.getIsInCharge()
		if not getAttrib("IsChargeConsuming") then
			return false
		end
		return state.chargeTimer ~= nil
	end

	-- 获取当前充能周期剩余时间(秒);未在充能中返回 0
	function handler.getChargeLeftTime()
		if not state.chargeTimer then
			return 0
		end
		if not state.chargeStartTime or not state.currentChargeInterval then
			return 0
		end
		local elapsed = World:GetServerTime() - state.chargeStartTime
		local left = state.currentChargeInterval - elapsed
		if left < 0 then
			return 0
		end
		return left
	end

	-- 设置当前充能周期剩余时间(秒);会取消现有 timer 并按新剩余时间重新计时
	-- 传 0 表示立即完成本次充能
	function handler.setChargeLeftTime(time)
		if not state.chargeTimer then
			return
		end
		time = time or 0
		if time < 0 then
			time = 0
		end
		Task:Cancel(state.chargeTimer)
		if time == 0 then
			-- 立即触发本次充能完成
			state.chargeTimer = nil
			completeOneCharge()
			handler._tryStartCharge()
		else
			-- 按新剩余时间重新计时,保持 startTime 一致性
			state.currentChargeInterval = World:GetServerTime()
				- (state.chargeStartTime or World:GetServerTime())
				+ time
			state.chargeTimer = Task:Delay(time, function()
				state.chargeTimer = nil
				state.chargeStartTime = nil
				state.currentChargeInterval = nil
				completeOneCharge()
				handler._tryStartCharge()
			end)
		end
	end

	function handler.setChargeConfig(enable, maxCount, chargeType, interval, amount)
		setAttrib("IsChargeConsuming", enable)
		if maxCount then
			setAttrib("MaxChargeCount", maxCount)
		end
		if chargeType then
			setAttrib("ChargeType", chargeType)
		end
		if interval then
			setAttrib("ChargeInterval", interval)
		end
		if amount then
			setAttrib("ChargeAmount", amount)
		end
		-- 参数变更后按新配置重评估充能（禁用则停表）
		if getAttrib("IsChargeConsuming") then
			local cur = getAttrib("ChargeCount") or 0
			local max = getAttrib("MaxChargeCount") or 1
			if cur >= max then
				handler._stopCharge()
			else
				handler._tryStartCharge()
			end
		else
			handler._stopCharge()
		end
	end

	function handler.removeSelf()
		local managerHandler = AbilityRegistry.getManagerHandler(self.Parent)
		if managerHandler and managerHandler.removeAbility then
			managerHandler.removeAbility(getAttrib("Index"))
		end
	end

	function handler.canPick()
		return true
	end

	-- 设置当前 CD 时长（立即重置 CdTime 并重新进入 CD）
	function handler.setCurrentCD(cdTime)
		cdTime = cdTime or getAttrib("CdTime") or AbilityConstants.DEFAULT_CD_TIME
		setAttrib("CdTime", cdTime)
		handler.enterCD(cdTime)
	end

	-- 强制升级（跳过 canUpgrade 检查）
	function handler.increaseLevel(delta)
		delta = delta or 1
		local newLevel = math.min((getAttrib("Level") or 1) + delta, getAttrib("MaxLevel") or 5)
		setAttrib("Level", newLevel)
		fireUpgraded(newLevel)
		return newLevel
	end

	-- 注册 ability
	AbilityRegistry.registerAbility(self, handler)
	print("[AbilityItemLogic] Attach complete: " .. tostring(self))

	-- 场景摆放补偿：管理器扫描先于本脚本执行（AbilityUnit 标签未就绪）时反向补登入槽；
	-- 显式休眠哨兵（-1）与已登记来源跳过，幂等
	local managerScript = self.Parent
	local managerHandler = managerScript and AbilityRegistry.getManagerHandler(managerScript)
	if managerHandler and managerHandler.addAbility then
		local idx = getAttrib("Index")
		if idx ~= AbilityConstants.SLOT_INDEX_UNASSIGNED then
			local registered = false
			if idx ~= nil and idx >= AbilityConstants.SLOT_BASE then
				local registeredHandler = managerHandler.getAbility(idx)
				registered = registeredHandler ~= nil
					and registeredHandler.getScript ~= nil
					and registeredHandler.getScript() == self
			end
			if not registered then
				local targetSlot = nil
				if
					idx ~= nil
					and idx >= AbilityConstants.SLOT_BASE
					and managerHandler.getAbility(idx) == nil
				then
					targetSlot = idx
				end
				targetSlot = targetSlot or managerHandler.getFirstAvailableSlot()
				if targetSlot ~= nil then
					managerHandler.addAbility(self, targetSlot)
				end
			end
		end
	end

	-- 销毁清理

	self.Destroying:Connect(function()
		-- 清理所有 timer
		if state.castTimer then
			Task:Cancel(state.castTimer)
			state.castTimer = nil
		end
		if state.cdTimer then
			Task:Cancel(state.cdTimer)
			state.cdTimer = nil
		end
		if state.chargeTimer then
			Task:Cancel(state.chargeTimer)
			state.chargeTimer = nil
		end
		-- 反注册 ability
		AbilityRegistry.unregisterAbility(self)
		AbilityRegistry.clearTags(self)
		-- 触发销毁事件
		if signals.CastBreak then
			signals.CastBreak:Fire(self)
		end
		-- 技能失去统一收口（销毁/移除/被覆盖均经 Destroying 一次）：
		-- ECA「当 此类技能 失去」；先触发再销毁事件单位
		if signals.Lost then
			signals.Lost:Fire(self)
		end
		-- 销毁事件单位（先触发后销毁；不依赖父子级联销毁）
		AbilityEventDefs.destroySignals(signals)
	end)
end

return AbilityItemLogic
