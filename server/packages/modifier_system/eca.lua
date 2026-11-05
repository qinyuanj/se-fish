--效果系统包 - 蛋码（ECA）导出层
--只做参数降级与转发：公共操作走 api.lua，细粒度状态查询走包内管理器，本文件不重复实现业务逻辑。

local api = require("server.packages.modifier_system.api")
local modifierSystem = require("server.packages.modifier_system.modifier_system")

local CreateResult = api.Enums.CreateResult

local eca = {}

---@export_eca_func
---@title 添加效果
---@category t_buff
---@desc {#0}添加效果{#1}<，持续时间{#2}><，来源{#3}>
---@param unit LifeEntityInstance 目标单位
---@param assetId modifierPrefab 效果预设
---@param duration Fixed 持续时间，单位秒，为空时用效果默认值
---@param sourceUnit LifeEntityInstance 来源生物，可为空
function eca.AddModifierByKey(unit, assetId, duration, sourceUnit)
	if not unit or not assetId or assetId == "" then
		return false
	end
	local durationValue = nil
	if duration and duration > 0 then
		durationValue = duration
	end
	local result = api.AddModifier(unit, assetId, {
		duration = durationValue,
		source = sourceUnit,
	})
	-- 新实例与叠加均视为添加成功；被拒绝/失败返回 false
	return result == CreateResult.Added or result == CreateResult.Reobtained
end

---@export_eca_func
---@title 移除效果
---@category t_buff
---@desc 给{#0}移除{#1}的效果
---@param unit LifeEntityInstance 目标单位
---@param modifierKey modifierPrefab 效果预设
function eca.RemoveModifierByKey(unit, modifierKey)
	print("RemoveModifierByKey", unit, modifierKey)
	if not modifierKey then
		return 0
	end
	return api.ClearUnitModifiers(unit, modifierKey) or 0
end

---@export_eca_func
---@title 销毁效果
---@category t_buff
---@desc 销毁{#0}
---@param modifier modifierInstance 效果实体
function eca.RemoveModifierEntity(modifier)
	return api.RemoveModifier(modifier) or false
end

---@export_eca_func
---@title 设置效果层数
---@category t_buff
---@desc 设置{#0}的层数为{#1}
---@param modifier modifierInstance 效果实体，由"效果获得/失去"等事件参数提供
---@param count Int 目标层数
function eca.SetStackCountOfEntity(modifier, count)
	if not modifier then
		return false
	end
	return api.SetModifierStackCount(modifier, count or 0)
end

---@export_eca_func
---@title 增加效果层数
---@category t_buff
---@desc 增加{#0}层数{#1}
---@param modifier modifierInstance 效果实体，由"效果获得/失去"等事件参数提供
---@param delta Int 层数增量，可为负
function eca.AddStackCountOfEntity(modifier, delta)
	if not modifier then
		return 0
	end
	return api.AddModifierStackCount(modifier, delta or 0)
end

---@export_eca_func
---@value_only
---@title 获取目标身上所有效果
---@category t_buff
---@desc 获取{#0}身上所有效果
---@param unit LifeEntityInstance 目标单位
---@return modifierInstance[]
function eca.GetModifiers(unit)
	return api.GetUnitModifiers(unit)
end

---@export_eca_func
---@value_only
---@title 获取角色/生物拥有的效果
---@category t_buff
---@desc 获取{#0}预设为{#1}的效果
---@param unit LifeEntityInstance 目标单位
---@param modifierKey modifierPrefab 效果预设
---@return modifierInstance
function eca.GetModifierByKey(unit, modifierKey)
	return modifierSystem:getModifierByKey(unit, modifierKey)
end

---@export_eca_func
---@value_only
---@title 获取效果的预设
---@category t_buff
---@desc {#0}的预设
---@param modifier modifierInstance 效果实体
---@return modifierPrefab
function eca.GetModifierKeyOfEntity(modifier)
	return modifierSystem:getModifierKeyOfEntity(modifier)
end

---@export_eca_func
---@value_only
---@title 拥有效果的生物
---@category t_buff
---@desc 拥有{#0}的生物
---@param modifier modifierInstance 效果实体，由"效果获得/失去"等事件参数提供
---@return LifeEntityInstance
function eca.GetModifierOwnerOfEntity(modifier)
	return api.GetModifierOwner(modifier)
end

---@export_eca_func
---@value_only
---@title 获取效果当前层数
---@category t_buff
---@desc 获取{#0}的当前层数
---@param modifier modifierInstance 效果实体，由"效果获得/失去"等事件参数提供
---@return Int
function eca.GetStackCountOfEntity(modifier)
	return modifierSystem:getStackCountOfEntity(modifier) or 0
end

---@export_eca_func
---@value_only
---@title 获取效果的最大层数
---@category t_buff
---@desc 获取{#0}的最大层数
---@param modifier modifierInstance 效果实体，由"效果获得/失去"等事件参数提供
---@return Int
function eca.GetMaxStackCountOfEntity(modifier)
	return modifierSystem:getMaxStackCountOfEntity(modifier) or 0
end

---@export_eca_func
---@value_only
---@title 获取效果剩余持续时间
---@category t_buff
---@desc 获取{#0}剩余持续时间
---@param modifier modifierInstance 效果实体，由"效果获得/失去"等事件参数提供
---@return Fixed
function eca.GetRemainTimeOfEntity(modifier)
	return modifierSystem:getRemainTimeOfEntity(modifier) or 0
end

---@export_eca_func
---@value_only
---@title 获取效果的图标图片
---@category t_buff
---@desc 获取{#0}的图标图片
---@param modifier modifierInstance 效果实体，由"效果获得/失去"等事件参数提供
---@return String
function eca.GetIconOfEntity(modifier)
	return modifierSystem:getIconOfEntity(modifier) or ""
end

---@export_eca_func
---@title 阻止本次效果获得
---@category t_buff
---@desc 阻止本次效果获得，只能在"即将获得效果"事件中使用，用于拦截该次获得
function eca.SetInterruptModifierObtain()
	print("SetInterruptModifierObtain")
	api.SetInterruptModifierObtain()
end

-- 效果事件，参数首项为 modifier 效果实体，其余参数见各事件 params
-- 效果自身事件：仅挂在效果预设上的 ECA 可选用，绑定名与 config.EventType 的事件单位一致

---@export_eca_prefab_event
---@title 效果获得
---@category t_buff
---@scope modifier
---@event public ModifierObtain 当 此类效果 获得 params:[{"name":"modifier","type":"modifierInstance","title":"效果实体"},{"name":"owner","type":"LifeEntityInstance","title":"拥有者"}]
eca.ModifierObtain = nil

---@export_eca_prefab_event
---@title 效果失去
---@category t_buff
---@scope modifier
---@event public ModifierLoss 当 此类效果 失去 params:[{"name":"modifier","type":"modifierInstance","title":"效果实体"},{"name":"owner","type":"LifeEntityInstance","title":"拥有者"}]
eca.ModifierLoss = nil

---@export_eca_prefab_event
---@title 效果被覆盖
---@category t_buff
---@scope modifier
---@event public ModifierReobtain 当 此类效果 被覆盖 params:[{"name":"modifier","type":"modifierInstance","title":"效果实体"},{"name":"owner","type":"LifeEntityInstance","title":"拥有者"}]
eca.ModifierReobtain = nil

---@export_eca_prefab_event
---@title 层数变化
---@category t_buff
---@scope modifier
---@event public StackChange 当 此类效果层数变化 params:[{"name":"modifier","type":"modifierInstance","title":"效果实体"},{"name":"oldCount","type":"Int","title":"旧层数"},{"name":"newCount","type":"Int","title":"新层数"}]
eca.StackChange = nil

-- 生物事件，参数为 modifier 效果实体与 owner 拥有者
-- 仅挂在生物上的 ECA 可选用，绑定名与 config.ManagerEvent.ObtainBefore 的事件单位一致；
-- 「指定生物即将获得效果」全局变体由事件机制生成

---@export_eca_prefab_event
---@title 生物即将获得效果
---@category t_buff
---@scope EggyUnit
---@event public ModifierObtainBefore 即将获得效果 params:[{"name":"modifier","type":"modifierInstance","title":"效果实体"},{"name":"owner","type":"LifeEntityInstance","title":"拥有者"}]
eca.ModifierObtainBefore = nil

return eca
