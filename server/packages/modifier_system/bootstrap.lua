-- 效果系统 - 启动引导清单（引导脚本单位在地图加载时最先调用）
-- 新增引导逻辑：在本文件添加导出函数即可（按名称排序执行，单个失败不阻断）。

local config = require("common.packages.modifier_system.config")
local eventDefs = require("common.packages.modifier_system.event_defs")

local bootstrap = {}

---为全部蛋仔预建「即将获得效果」事件单位（先查后建，幂等）
function bootstrap.ensureObtainBeforeEvents()
	local world = game:GetService("World")
	if not world then
		return
	end
	local scanned, matched = 0, 0
	for _, unit in ipairs(world:GetDescendants()) do
		scanned = scanned + 1
		if unit ~= nil and (unit:IsA("EggyUnit") == true or unit.UnitType == "EggyUnit") then
			matched = matched + 1
			eventDefs.getOrCreateEventUnit(unit, config.ManagerEvent.ObtainBefore)
		end
	end
	print(string.format("[modifier_system] ensure scan: total=%d eggy=%d", scanned, matched))
end

-- 预放置效果：编辑器里预摆在生物下的效果实例
local function collectPreplacedModifiers(world)
	local list, total = {}, 0
	for _, unit in ipairs(world:GetDescendants()) do
		total = total + 1
		if unit ~= nil and unit.UnitType == "Script" and unit:GetAttribute("UgcModifierType") ~= nil then
			list[#list + 1] = unit
		end
	end
	return list, total
end

---为预放置的效果预建事件单位（先查后建，幂等）
function bootstrap.ensureModifierEvents()
	local world = game:GetService("World")
	if not world then
		return
	end
	local modifiers, total = collectPreplacedModifiers(world)
	for i = 1, #modifiers do
		eventDefs.createModifierSignals(modifiers[i])
	end
	print(string.format("[modifier_system] ensure modifier events: total=%d modifier=%d", total, #modifiers))
end

-- 补发调度幂等标记
local _replayScheduled = false

---启动完成后，为仍生效的预放置效果补发一次「获得」事件（每次开图至多一次）
function bootstrap.replayPreplacedModifierObtain()
	-- 每次开图最多补发一次
	if _replayScheduled then
		return
	end
	local world = game:GetService("World")
	if not world then
		return
	end
	local modifiers = collectPreplacedModifiers(world)
	if #modifiers == 0 then
		return
	end
	_replayScheduled = true
	-- 延后补发；单条失败不阻断其余
	local Task = game:GetService("Task")
	Task:Defer(function()
		local replayed, failed = 0, 0
		for i = 1, #modifiers do
			local unit = modifiers[i]
			local ok = pcall(function()
				if unit ~= nil and unit:GetAttribute("IsActive") == true then
					local signal = unit:FindFirstChild(config.EventType.Obtain)
					if signal then
						signal:Fire(unit, unit.Parent)
						replayed = replayed + 1
					end
				end
			end)
			if not ok then
				failed = failed + 1
			end
		end
		print(string.format("[modifier_system] replay preplaced obtain: replayed=%d failed=%d", replayed, failed))
	end)
end

-- 监听句柄：重复调用时先断旧再重建
local _watchConnection = nil

---监听后续新出现的蛋仔，实时补齐事件单位。
function bootstrap.watchObtainBeforeEvents()
	local world = game:GetService("World")
	if not world then
		return
	end
	local signal = world:GetUnitAddedSignal("EggyUnit")
	if _watchConnection then
		_watchConnection:Disconnect()
	end
	_watchConnection = signal:Connect(function(unit)
		if unit ~= nil then
			eventDefs.getOrCreateEventUnit(unit, config.ManagerEvent.ObtainBefore)
		end
	end)
end

return bootstrap
