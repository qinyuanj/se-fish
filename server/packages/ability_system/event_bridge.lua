--技能系统 - server单位级事件中继
-- 把技能级关键事件（冷却完成/充能完成/降级）中继到「技能拥有者单位」的事件单位，
-- 供 ECA 预设路径事件（「当 此类角色/生物 冷却完成」等）按 unit:FindFirstChild(名) 绑定。
-- 事件单位平时为惰性创建；触发器脚本在初始化阶段即按名绑定，绑定时刻子单位不存在则绑不上，
-- 故需在触发脚本执行前预铺：
--   1) 模块加载后 Task:Delay(0) 扫描已有生命体单位补齐（对齐 BaseEca DiedWithSource 预铺做法）；
--   2) 监听 World:GetUnitAddedSignal('EggyUnit'/'HumanUnit') 增量补齐运行时新建单位
--      （对齐 modifier_system.event_bridge.watchObtainBeforeEvents）；
--   3) 主动触发路径（fireOnOwner）内先查后建兜底，保证任何时刻触发不丢。

local AbilityConstants = require("common.packages.ability_system.constants")

local EventBridge = {}

-- 预铺单位类型：角色/生物统一按生命体语义处理（EggyUnit / HumanUnit 两类生命体）
local PRESPAWN_UNIT_TYPES = { "EggyUnit", "HumanUnit" }

-- 先查后建（幂等）：同名事件单位已存在时直接复用
local function getOrCreateEventUnit(ownerUnit, name)
	local ok, existing = pcall(function()
		return ownerUnit:FindFirstChild(name)
	end)
	if ok and existing then
		return existing
	end
	local unit = game:CreateUnit("BindableEvent", { Name = name })
	unit.Parent = ownerUnit
	return unit
end

-- 是否预铺目标单位：按单位类型（UnitType）判定，读取异常时回退 IsA 探测
local function isPrespawnUnit(unit)
	local ok, unitType = pcall(function()
		return unit.UnitType
	end)
	if ok and unitType then
		for _, t in ipairs(PRESPAWN_UNIT_TYPES) do
			if unitType == t then
				return true
			end
		end
	end
	for _, t in ipairs(PRESPAWN_UNIT_TYPES) do
		local okIs, is = pcall(function()
			return unit:IsA(t)
		end)
		if okIs and is then
			return true
		end
	end
	return false
end

-- 为单位补齐全部中继事件单位（幂等，重复调用安全）
function EventBridge.ensureUnitEvents(ownerUnit)
	if not ownerUnit then
		return
	end
	for _, name in pairs(AbilityConstants.UnitEvent) do
		getOrCreateEventUnit(ownerUnit, name)
	end
end

-- 存量预铺：扫描 World 下已存在的生命体单位（幂等）
function EventBridge.prespawn()
	local world = game:GetService("World")
	if not world then
		return
	end
	local ok, descendants = pcall(function()
		return world:GetDescendants()
	end)
	if not ok or type(descendants) ~= "table" then
		return
	end
	for _, unit in ipairs(descendants) do
		if unit ~= nil and isPrespawnUnit(unit) then
			EventBridge.ensureUnitEvents(unit)
		end
	end
end

-- 增量监听：运行时新建的生命体单位实时补齐（先查后建，重复调用安全）
local _watching = false

function EventBridge.watchUnitAdded()
	if _watching then
		return
	end
	local world = game:GetService("World")
	if not world or not world.GetUnitAddedSignal then
		return
	end
	_watching = true
	for _, unitType in ipairs(PRESPAWN_UNIT_TYPES) do
		local ok, signal = pcall(function()
			return world:GetUnitAddedSignal(unitType)
		end)
		if ok and signal then
			signal:Connect(function(unit)
				if unit ~= nil then
					EventBridge.ensureUnitEvents(unit)
				end
			end)
		end
	end
end

-- 中继触发：找到技能拥有者单位（技能 -> 管理器 -> 角色/生物），
-- 确保事件单位存在后 Fire（惰性创建兜底，触发路径永不丢事件）
function EventBridge.fireOnOwner(abilityScript, eventName, ...)
	local manager = abilityScript and abilityScript.Parent
	local ownerUnit = manager and manager.Parent
	if not ownerUnit or not eventName then
		return
	end
	local ok, eventUnit = pcall(getOrCreateEventUnit, ownerUnit, eventName)
	if ok and eventUnit then
		eventUnit:Fire(...)
	end
end

-- 模块加载即预铺（对齐 BaseEca：server.main 阶段 require → Task:Delay(0) 等 World 单位装配；
-- 未覆盖到的单位由 fireOnOwner 惰性兜底）
pcall(function()
	game:GetService("Task"):Delay(0, function()
		EventBridge.prespawn()
		EventBridge.watchUnitAdded()
	end)
end)

return EventBridge
