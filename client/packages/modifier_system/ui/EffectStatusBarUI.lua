--效果系统包 - 客户端效果状态栏
--职责：定位预先摆放的状态栏节点；跟踪当前控制角色；把角色身上"生效中"的效果
--      按顺序实时映射到固定槽位（不出现空槽）；按住槽位时显示效果详情、松开隐藏。
--数据只读：消费 CModifierSystemManager 的容器（slots/order），不改动包内既有逻辑。

local RunService = game:GetService("RunService")
local Players = game:GetService("Players")
local Task = game:GetService("Task")

local UIConsts = require("client.packages.modifier_system.ui.ui_consts")
local EuiAdapter = require("client.packages.modifier_system.ui.eui_adapter")
local EffectSlotNode = require("client.packages.modifier_system.ui.EffectSlotNode")
local EffectDetailPanel = require("client.packages.modifier_system.ui.EffectDetailPanel")
local util = require("common.packages.modifier_system.util")

local EffectStatusBarUI = {}

local _state = nil -- 单例状态

local function log(...)
	if UIConsts.DEBUG then
		print("[modifier_system][UI]", ...)
	end
end

-- 诊断日志（联调期开关 UIConsts.DIAG）：长按链路 / 图标来源 / 面板创建
local function diag(...)
	if UIConsts.DIAG then
		print("[modifier_system][UI][diag]", ...)
	end
end

local function nodeLabel(node)
	local ok, name = pcall(function()
		return node.Name
	end)
	if ok and name then
		return tostring(name)
	end
	return tostring(node)
end

-- 节点定位

local function nodeMatchesAttr(node, key, value)
	if not node or not node.GetAttribute then
		return false
	end
	local ok, attr = pcall(function()
		return node:GetAttribute(key)
	end)
	return ok and attr == value
end

local function nodeNameEquals(node, name)
	local ok, nodeName = pcall(function()
		return node.Name
	end)
	return ok and nodeName == name
end

-- 在状态栏子树中收集槽位节点（UIType=EffectSlot + Index；兜底 Node_N 名字），按 Index 升序
local function collectSlots(barNode)
	local entries = {}
	for _, node in ipairs(EuiAdapter.GetDescendants(barNode)) do
		local isSlot = false
		local index = nil
		if nodeMatchesAttr(node, UIConsts.ATTR_UI_TYPE, UIConsts.UIType.Slot) then
			isSlot = true
			local ok, idx = pcall(function()
				return node:GetAttribute(UIConsts.ATTR_SLOT_INDEX)
			end)
			index = ok and tonumber(idx) or nil
		else
			local ok, nodeName = pcall(function()
				return node.Name
			end)
			if ok and type(nodeName) == "string" then
				local num = string.match(nodeName, UIConsts.SLOT_NAME_PATTERN)
				if num then
					isSlot = true
					index = tonumber(num)
				end
			end
		end
		if isSlot then
			-- index 缺省排到显式 Index 之后；ordinal 保证排序稳定
			table.insert(entries, { node = node, index = index or math.huge, ordinal = #entries + 1 })
		end
	end
	table.sort(entries, function(a, b)
		if a.index ~= b.index then
			return a.index < b.index
		end
		return a.ordinal < b.ordinal
	end)
	local slots = {}
	for i, entry in ipairs(entries) do
		slots[i] = entry.node
	end
	return slots
end

-- 长按显示 / 松开隐藏（前置声明：供触摸接线引用）
local onHoldBegin
local onHoldEnd

-- 在单个节点上接线两路触摸信号：两路都成功才算该节点接线成功；
-- 任一失败即断开本目标已连句柄（避免半接线残留），成功才并入外层句柄表
local function bindTouchTarget(self, target, label, slotNode, conns)
	local targetConns = {}
	local function connect(signal, fn)
		if signal and type(signal.Connect) == "function" then
			local ok, conn = pcall(function()
				return signal:Connect(fn)
			end)
			if ok and conn then
				table.insert(targetConns, conn)
				return true
			end
		end
		return false
	end
	local boundBegan = connect(target.OnTouchBegan, function()
		diag("touch began on", label, "→ slot", nodeLabel(slotNode))
		onHoldBegin(self, slotNode)
	end)
	local boundEnded = connect(target.OnTouchEnded, function()
		diag("touch ended on", label, "→ slot", nodeLabel(slotNode))
		onHoldEnd(self, slotNode)
	end)
	-- 诊断：点击信号（快按快放）——仅记录事件来自哪一层，不参与长按逻辑
	connect(target.OnClicked, function()
		diag("clicked on", label, "→ slot", nodeLabel(slotNode))
	end)
	if not (boundBegan and boundEnded) then
		for _, conn in ipairs(targetConns) do
			pcall(function()
				conn:Disconnect()
			end)
		end
		return false
	end
	for _, conn in ipairs(targetConns) do
		table.insert(conns, conn)
	end
	return true
end

-- 槽位触摸接线：按住 → 详情；松开 → 隐藏。
-- 接线槽位全部可触摸层（根 + 图标/进度环/层数文本，命中层级以引擎为准）：
-- 任一覆盖层命中都能触发，避免"上层节点吞触摸但未接线"造成的静默无响应；
-- 失败不置位，由刷新循环重试（句柄留存以便清理）
local function bindSlotTouch(self, node)
	if self.touchBound[node] then
		return
	end
	local conns = {}
	local results = {}
	local anyBound = false
	for _, target in ipairs(EffectSlotNode.GetTouchTargets(node)) do
		local ok = bindTouchTarget(self, target.node, target.label, node, conns)
		results[#results + 1] = target.label .. "=" .. tostring(ok)
		if ok then
			anyBound = true
		end
	end
	if not anyBound then
		for _, conn in ipairs(conns) do
			pcall(function()
				conn:Disconnect()
			end)
		end
		if not self.touchBindWarned then
			self.touchBindWarned = true
			diag("bind touch 失败（槽位全部可触摸层均未接线成功），将随刷新循环重试")
		end
		return
	end
	self.touchBound[node] = true
	self.touchConns[node] = conns
	diag("bind touch:", nodeLabel(node), table.concat(results, " "))
end

-- 节点缺失/未就绪时的限流重试计数与一次性告警（返回 false 供调用方直接返回）
local function noteNodeNotReady(self, reason)
	local now = util.getServerTime()
	if now - self.nodeRetryAt < UIConsts.NODE_RETRY_INTERVAL then
		return false
	end
	self.nodeRetryAt = now
	self.nodeRetry = self.nodeRetry + 1
	if self.nodeRetry >= UIConsts.NODE_RETRY_MAX and not self.nodeWarned then
		self.nodeWarned = true
		print(string.format(
			"[modifier_system][UI] 未找到可用的效果状态栏（%s：UIType=%s 或 名字=%s）；" ..
				"将持续低频率重试，请检查状态栏摆放与自定义属性配置",
			reason,
			UIConsts.UIType.StatusBar,
			UIConsts.NodeName.StatusBar
		))
	end
	return false
end

-- 状态栏节点准备（有界重试；未就绪返回 false，由刷新循环下一轮继续）
local function tryAttachStatusBar(self)
	local root = EuiAdapter.GetRootNode()
	if not root then
		return false
	end
	local descendants = EuiAdapter.GetDescendants(root)
	local barNode = nil
	for _, node in ipairs(descendants) do
		if nodeMatchesAttr(node, UIConsts.ATTR_UI_TYPE, UIConsts.UIType.StatusBar) then
			barNode = node
			break
		end
	end
	if not barNode then
		for _, node in ipairs(descendants) do
			if nodeNameEquals(node, UIConsts.NodeName.StatusBar) then
				barNode = node
				break
			end
		end
	end
	if not barNode then
		return noteNodeNotReady(self, "节点缺失")
	end
	-- 槽位为空（子树未就绪/未配置）同样按未就绪处理，保留重试预算
	local slots = collectSlots(barNode)
	if #slots == 0 then
		return noteNodeNotReady(self, "槽位为空")
	end
	self.statusBar = barNode
	self.nodeRetry = 0
	-- 可选：状态栏根携带 DetailPreset 属性时覆盖详情预设 uri
	local okDetail, detailUri = pcall(function()
		return barNode:GetAttribute(UIConsts.ATTR_DETAIL_PRESET)
	end)
	if okDetail and type(detailUri) == "string" and detailUri ~= "" then
		EffectDetailPanel.SetPresetUri(detailUri)
	end
	-- 初始化槽位：全部隐藏
	self.slots = slots
	for _, node in ipairs(self.slots) do
		EffectSlotNode.Attach(node)
		EffectSlotNode.SetVisibleState(node, false)
		bindSlotTouch(self, node)
	end
	log("状态栏就绪，槽位数量=", #self.slots)
	diag("status bar ready, slots=", #self.slots)
	return true
end

-- 长按显示 / 松开隐藏

onHoldBegin = function(self, node)
	local token = {}
	self.holding[node] = token
	local epoch = self.epoch
	diag("hold begin:", nodeLabel(node))
	Task:Delay(UIConsts.HOLD_TIME, function()
		local epochOK = self.epoch == epoch
		local tokenOK = self.holding[node] == token
		local view = self.slotView[node]
		diag(
			"hold fired:",
			nodeLabel(node),
			"epochOK=" .. tostring(epochOK),
			"tokenOK=" .. tostring(tokenOK),
			"hasView=" .. tostring(view ~= nil)
		)
		if not (epochOK and tokenOK and view) then
			return
		end
		self.panelSource = node
		EffectDetailPanel.Show(view)
	end)
end

onHoldEnd = function(self, node)
	self.holding[node] = nil
	if self.panelSource == node then
		self.panelSource = nil
		diag("hold end → hide:", nodeLabel(node))
		EffectDetailPanel.Hide()
	end
end

-- 静态时长：效果单位 Duration 属性（预放置=预设字段；动态添加=addConfig 覆盖写入），
-- 需为有效正数；非法返回 nil（进度环隐藏，不显示错误比例）。只缓存有效值，
-- 失败值不缓存、下轮重试；作为 TotalDuration 不可用时的进度环回退分母。
local function resolveDuration(self, data)
	local unit = data.unit
	if not unit then
		return nil
	end
	local unitId = unit.UnitId
	local cached = self.durationCache[unitId]
	if cached ~= nil then
		return cached or nil
	end
	local ok, raw = pcall(function()
		return unit:GetAttribute("Duration")
	end)
	raw = ok and tonumber(raw) or nil
	if raw and raw > 0 then
		self.durationCache[unitId] = raw
		return raw
	end
	-- 未解析到：不缓存失败值（属性复制可能迟到），下轮重试
	return nil
end

-- 进度环总时长：优先读效果单位 TotalDuration 属性（服务端在叠加延长时累计推进，
-- 保证总时长始终覆盖剩余时间），回退静态 Duration；属性随叠加变化，逐轮读取不做值缓存，
-- 复制滞后/异常时短暂回退，下一轮自然收敛
local function resolveTotalDuration(self, data)
	local unit = data.unit
	if not unit then
		return resolveDuration(self, data)
	end
	local ok, raw = pcall(function()
		return unit:GetAttribute("TotalDuration")
	end)
	if ok and raw ~= nil then
		raw = tonumber(raw)
		-- TotalDuration 已存在但尚未复制出有效值时，不用旧 Duration 猜测分母，
		-- 等权威值到达后再显示进度，避免首帧出现错误比例。
		if raw and raw > 0 then
			return raw
		end
		return nil
	end
	return resolveDuration(self, data)
end

-- 读取效果实体的实时 EndTime：容器条目可能在属性复制完成前建立，
-- 此时 slot.endTime 可能是 0；逐轮读取实体属性，待复制就绪后自动收敛。
local function resolveEndTime(data)
	local endTime = data.endTime
	local unit = data.unit
	if not unit then
		return endTime
	end
	local ok, raw = pcall(function()
		return unit:GetAttribute("EndTime")
	end)
	raw = ok and tonumber(raw) or nil
	if raw ~= nil and (raw > 0 or raw == -1) then
		endTime = raw
		data.endTime = raw
	end
	return endTime
end

-- 图标解析：优先效果单位 PresetLink 子节点的 PrefabIcon（编辑器在效果预设"预设-图标"处
-- 配置，运行时物化到 PresetLink 属性；与技能系统同款逻辑），其次推送的 slot.icon（= 单位
-- Icon 属性）。解析值按效果缓存；未解析到不缓存失败值（PresetLink 复制可能迟到），下轮重试。
local function resolveIcon(self, data)
	local unit = data.unit
	if not unit then
		local pushed = data.icon
		if type(pushed) == "string" and pushed ~= "" then
			return pushed
		end
		return nil
	end
	local unitId = unit.UnitId
	local cached = self.iconCache[unitId]
	if cached ~= nil then
		return cached or nil
	end
	local icon = nil
	local okFind, presetLink = pcall(function()
		return unit:FindFirstChildWhichIsA("PresetLink")
	end)
	if okFind and presetLink then
		local okIcon, prefabIcon = pcall(function()
			return presetLink:GetAttribute("PrefabIcon")
		end)
		if okIcon and type(prefabIcon) == "string" and prefabIcon ~= "" then
			icon = prefabIcon
		end
	end
	if not icon then
		local pushed = data.icon
		if type(pushed) == "string" and pushed ~= "" then
			icon = pushed
		end
	end
	if not icon then
		local okUnitIcon, unitIcon = pcall(function()
			return unit:GetAttribute("Icon")
		end)
		if okUnitIcon and type(unitIcon) == "string" and unitIcon ~= "" then
			icon = unitIcon
		end
	end
	if icon then
		self.iconCache[unitId] = icon
		if self.iconMiss[unitId] then
			diag("icon resolved (late): unitId=", unitId, "icon=", icon)
		end
		return icon
	end
	-- 未解析到：不缓存失败值（PresetLink 可能迟到），下轮重试；诊断一次
	if not self.iconMiss[unitId] then
		self.iconMiss[unitId] = true
		diag("icon unresolved: unitId=", unitId, "（PresetLink.PrefabIcon / 推送 / Icon 属性均为空）")
	end
	return nil
end

-- 重置（切控/重生）：隐藏全部槽位、销毁详情面板、清缓存；
-- 长按延时回调按 epoch 失效
local function reset(self)
	self.epoch = self.epoch + 1
	self.holding = {}
	self.panelSource = nil
	EffectDetailPanel.Destroy()
	for _, node in ipairs(self.slots) do
		self.slotEffect[node] = nil
		EffectSlotNode.SetVisibleState(node, false)
	end
	self.durationCache = {}
	self.durationFallbackCache = {}
	self.durationOffsetCache = {}
	self.displayRemainingCache = {}
	self.lastServerTime = nil
	self.iconCache = {}
	self.iconMiss = {}
	self.slotView = {}
	self.container = nil
end

-- 每 tick 刷新：角色跟踪 → 容器 → 展示列表 → 槽位映射 → 详情同步
local function refreshOnce(self)
	local player = Players.LocalPlayer
	if not player then
		return
	end
	if not self.statusBar then
		if not tryAttachStatusBar(self) then
			return
		end
	end
	-- 当前控制角色（切控不触发 CharacterAdded，逐 tick 比对兜底）
	local okChar, char = pcall(function()
		return player.Character
	end)
	char = okChar and char or nil
	if char ~= self.char then
		reset(self)
		self.char = char
	end
	if not char then
		return
	end
	-- 容器：getContainer 是客户端容器唯一创建入口，同时保证服务端推送可分发
	if not self.container then
		local ok, container = pcall(function()
			return self.manager:getContainer(char)
		end)
		self.container = ok and container or nil
		if not self.container then
			return
		end
	end
	-- 生效中的展示列表（按容器插入顺序）；倒计时已归零的条目立即从展示列表剔除，
	-- 不等待服务端 OnLoss/OnRemoved 回推，避免 CD 结束后图标残留
	local list = {}
	local now = util.getServerTime()
	local elapsed = now - (self.lastServerTime or now)
	if elapsed <= 0 or elapsed > 0.5 then
		elapsed = UIConsts.TICK_INTERVAL
	end
	self.lastServerTime = now
	for _, unitId in ipairs(self.container.order) do
		local slot = self.container.slots[unitId]
		if slot and slot.isActive then
			local endTime = resolveEndTime(slot)
			local unitId = slot.unit and slot.unit.UnitId or nil
			local offset = unitId and self.durationOffsetCache[unitId] or 0
			if type(endTime) ~= "number" or endTime <= 0 or endTime - offset > now then
				table.insert(list, slot)
			end
		end
	end
	-- 固定槽位映射：第 i 个效果 → 第 i 个槽位（紧凑排列，不出现空槽）
	local maxShow = math.min(#self.slots, UIConsts.MAX_SLOTS)
	for i = 1, #self.slots do
		local node = self.slots[i]
		-- 触摸接线失败时（信号暂不可用）每轮重试
		if not self.touchBound[node] then
			bindSlotTouch(self, node)
		end
		local data = i <= maxShow and list[i] or nil
		if data then
			EffectSlotNode.SetVisibleState(node, true)
			local view = {
				icon = resolveIcon(self, data),
				name = data.name,
				desc = data.desc,
			}
			self.slotView[node] = view
			if self.slotEffect[node] ~= data then
				diag(
					"slot bind:",
					nodeLabel(node),
					"unitId=" .. tostring(data.unit and data.unit.UnitId or "-"),
					"icon=" .. tostring(view.icon)
				)
			end
			EffectSlotNode.SetIcon(node, view.icon)
			EffectSlotNode.SetStackCount(node, data.currCount, data.maxStackCount)
			local endTime = resolveEndTime(data)
			local unitId = data.unit and data.unit.UnitId or nil
			local remainingRaw = nil
			local remaining = nil
			if type(endTime) == "number" and endTime > 0 then
				remainingRaw = math.max(0, endTime - now)
			end
			local duration = nil
			local offset = 0
			if remainingRaw ~= nil then
				duration = resolveTotalDuration(self, data)
				if not duration and unitId then
					local fallback = self.durationFallbackCache[unitId]
					if not fallback then
						fallback = remainingRaw
						self.durationFallbackCache[unitId] = fallback
					end
					duration = fallback
				end
				if duration and unitId then
					offset = self.durationOffsetCache[unitId]
					if offset == nil then
						offset = math.max(0, remainingRaw - duration)
						self.durationOffsetCache[unitId] = offset
					end
				end
				remaining = math.max(0, remainingRaw - offset)
				if unitId then
					local display = self.displayRemainingCache[unitId]
					if display == nil then
						display = math.min(duration or remaining, remaining)
					else
						if not data.isPaused then
							display = display - elapsed
						end
						if duration and display > duration then
							display = duration
						end
						if remaining > display + 0.25 then
							display = remaining
						end
						if display < 0 then
							display = 0
						end
					end
					self.displayRemainingCache[unitId] = display
					remaining = display
				end
			end
			EffectSlotNode.SetProgress(node, remaining, duration)
			self.slotEffect[node] = data
		else
			if self.slotEffect[node] then
				diag("slot unbind:", nodeLabel(node))
			end
			EffectSlotNode.SetVisibleState(node, false)
			self.slotEffect[node] = nil
			self.slotView[node] = nil
		end
	end
	-- 裁剪总时长缓存：仅保留当前展示列表中的效果（防长会话内单调增长）
	local activeIds = {}
	for _, slot in ipairs(list) do
		if slot.unit then
			activeIds[slot.unit.UnitId] = true
		end
	end
	for unitId in pairs(self.durationCache) do
		if not activeIds[unitId] then
			self.durationCache[unitId] = nil
		end
	end
	for unitId in pairs(self.durationFallbackCache) do
		if not activeIds[unitId] then
			self.durationFallbackCache[unitId] = nil
		end
	end
	for unitId in pairs(self.durationOffsetCache) do
		if not activeIds[unitId] then
			self.durationOffsetCache[unitId] = nil
		end
	end
	for unitId in pairs(self.displayRemainingCache) do
		if not activeIds[unitId] then
			self.displayRemainingCache[unitId] = nil
		end
	end
	for unitId in pairs(self.iconCache) do
		if not activeIds[unitId] then
			self.iconCache[unitId] = nil
		end
	end
	for unitId in pairs(self.iconMiss) do
		if not activeIds[unitId] then
			self.iconMiss[unitId] = nil
		end
	end
	-- 详情面板同步：来源槽位内容变化 → 跟随刷新；绑定失效 → 隐藏
	if self.panelSource then
		local view = self.slotView[self.panelSource]
		if view then
			EffectDetailPanel.Update(view)
		else
			self.panelSource = nil
			EffectDetailPanel.Hide()
		end
	end
end

-- 启动（幂等）：由客户端管理器 new() 自动调用；也可作者手动调用预启动

---启动常驻刷新循环（幂等，可重入补挂）：循环创建在无归属上下文中，
---避免随首个 require 本模块的效果脚本销毁被连带回收（静默停止刷新）；
---引导跳约一帧后异步执行，丢失（引导脚本先于触发被销毁）时再次调用即可补挂
---@param self table 状态栏 UI 单例状态
local function startLoop(self)
	if self.loopStarted then
		return
	end
	util.runDetached(function()
		if self.loopStarted then
			return
		end
		self.loopStarted = true
		-- 常驻刷新循环（VM 生命周期；单次异常不终止）
		Task:Spawn(function()
			while self.running do
				local ok, err = pcall(function()
					refreshOnce(self)
				end)
				if not ok then
					-- 首次异常必打（持续异常只告警一次），其余细节走调试日志
					if not self.tickErrorWarned then
						self.tickErrorWarned = true
						print("[modifier_system][UI] 状态栏刷新异常：" .. tostring(err))
					end
					log("refresh error:", err)
				end
				Task:Wait(UIConsts.TICK_INTERVAL)
			end
		end)
	end)
end

---启动状态栏 UI（幂等；manager 缺省时惰性获取客户端效果管理器）
---@param manager table? CModifierSystemManager 客户端效果管理器
---@return boolean 是否已启动
function EffectStatusBarUI.ensureStarted(manager)
	if not RunService:IsClient() then
		return false
	end
	if _state then
		if manager and not _state.manager then
			_state.manager = manager
		end
		startLoop(_state)
		return true
	end
	if not manager then
		local ok, instance = pcall(function()
			return require("client.packages.modifier_system.modifier_system")
		end)
		manager = ok and instance or nil
	end
	if _state then
		if manager and not _state.manager then
			_state.manager = manager
		end
		startLoop(_state)
		return true
	end
	if not manager then
		return false
	end
	local self = {
		manager = manager,
		epoch = 0,
		running = true,
		loopStarted = false,
		statusBar = nil,
		slots = {},
		slotEffect = {},
		slotView = {},
		iconCache = {},
		iconMiss = {},
		holding = {},
		touchBound = {},
		touchConns = {},
		durationCache = {},
		durationFallbackCache = {},
		durationOffsetCache = {},
		displayRemainingCache = {},
		lastServerTime = nil,
		panelSource = nil,
		char = nil,
		container = nil,
		nodeRetry = 0,
		nodeRetryAt = 0,
		nodeWarned = false,
		tickErrorWarned = false,
		touchBindWarned = false,
	}
	_state = self
	startLoop(self)
	return true
end

return EffectStatusBarUI

