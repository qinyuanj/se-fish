--技能系统 - 蛋码（ECA）导出层
-- 只做参数降级与转发：公共操作走 api.lua，技能状态读写走 AbilityRegistry 的 handler，
-- 本文件不重复实现业务逻辑。
--
-- 文案来源：策划「SE蛋码总表_技能」表
--   ---@title  = FS描述列；---@desc = FS_CONTENT 列（可选段取自 <>，参数默认值取自 SE_参数默认值）
-- 展示顺序 = 本文件书写顺序（按总表顺序排列，调整顺序会影响蛋码面板排序，勿随意挪动）。
--
-- 事件类注解（---@export_eca_prefab_event）绑定运行时 BindableEvent 事件单位：
--   - @scope ability            → 技能预设触发器内的「此类技能」事件（事件单位挂技能脚本下）
--   - @scope ability_anchor     → 锚点预设触发器内的「当前锚点」事件（事件单位挂锚点脚本下）
--   - @scope LifeEntityInstance → 角色/生物触发器内的技能中继事件（事件单位挂单位下，event_bridge 预铺）
-- 注：自定义预设类型不生成「任意技能（指定技能）」Spec 变体，总表中指定技能冷却/充能完成等
--     仅依赖 Spec 变体的条目本期不处理（编辑器机制受限）。
--
-- 枚举声明不写在本文件：统一放 common/packages/ability_system/enums.lua，
-- 参数通过 style:abilityEnums.<枚举名> 引用。
--
-- 已知待办（注解先落地，运行时逐步补全）：
--   - 目标筛选空间查询（target_filter 候选列表为空壳）：获取符合目标选择类型的列表当前返回空列表；
--   - 复数指示器协议：复数施法目标点/方向当前返回单元素列表（客户端仅上报单点）。

local api = require("server.packages.ability_system.api")
local AbilityRegistry = require("common.packages.ability_system.registry")
local TargetFilter = require("common.packages.ability_system.target_filter")

local eca = {}

-- ============ 内部辅助 ============

-- 技能脚本单位 -> handler（未注册返回 nil）
local function getHandler(abilityScript)
	if not abilityScript then
		return nil
	end
	return AbilityRegistry.getAbilityHandler(abilityScript)
end

-- handler -> 拥有者单位（技能 -> 管理器 -> 角色/生物）
local function getOwnerOfHandler(handler)
	if not handler then
		return nil
	end
	local manager = handler.getManager and handler.getManager()
	return manager and manager.Parent or nil
end

-- 管理器 handler（槽位级操作）
local function getManagerHandlerOf(unit)
	local manager = api.GetManagerForUnit(unit)
	if not manager then
		return nil
	end
	return AbilityRegistry.getManagerHandler(manager)
end

-- UnitId -> 单位（锁定目标等）；0/无效/查不到返回 nil
local function resolveUnitById(unitId)
	if not unitId or unitId == 0 then
		return nil
	end
	local ok, unit = pcall(function()
		return game:GetService("World"):GetUnitByID(unitId)
	end)
	if ok and unit then
		return unit
	end
	ok, unit = pcall(function()
		return game:GetUnitByID(unitId)
	end)
	if ok and unit then
		return unit
	end
	return nil
end

-- ============ 动作 ============

---@export_eca_func
---@title 打断技能施法
---@category t_skill
---@desc 打断{#0}施法
---@param ability abilityInstance 技能
function eca.BreakCast(ability)
	local handler = getHandler(ability)
	if not handler then
		return false
	end
	handler.breakCast()
	return true
end

---@export_eca_func
---@title 打断技能蓄力
---@category t_skill
---@desc 打断{#0}蓄力
---@param ability abilityInstance 技能
function eca.BreakAccumulate(ability)
	local handler = getHandler(ability)
	if not handler then
		return false
	end
	-- 已进入施法时不起作用：仅打断蓄力态
	if not handler.isAccumulating() then
		return false
	end
	handler.endAccumulate(true)
	return true
end

---@export_eca_func
---@title 激活技能冷却
---@category t_skill
---@desc 激活{#0}冷却
---@param ability abilityInstance 技能
function eca.ActivateCD(ability)
	local handler = getHandler(ability)
	if not handler then
		return false
	end
	handler.enterCD()
	return true
end

---@export_eca_func
---@title 设置技能剩余冷却
---@category t_skill
---@desc 设置{#0}剩余冷却为{#1}
---@param ability abilityInstance 技能
---@param time Fixed 剩余冷却时间（秒）
function eca.SetLeftCD(ability, time)
	local handler = getHandler(ability)
	if not handler then
		return false
	end
	handler.setLeftCD(time or 0)
	return true
end

---@export_eca_func
---@title 设置技能充能冷却
---@category t_skill
---@desc 设置{#0}剩余充能时间为{#1}
---@param ability abilityInstance 技能
---@param time Fixed 剩余充能时间（秒）
function eca.SetChargeLeftTime(ability, time)
	local handler = getHandler(ability)
	if not handler then
		return false
	end
	-- 未在充能中先按当前充能间隔开启一轮（不受 ChargeType 策略限制）
	if not handler.getIsInCharge() then
		handler.startChargeCycle()
	end
	if not handler.getIsInCharge() then
		return false
	end
	handler.setChargeLeftTime(time or 0)
	return true
end

---@export_eca_func
---@title 设置技能释放次数
---@category t_skill
---@desc 设置{#0}释放次数为{#1}
---@param ability abilityInstance 技能
---@param count Int 目标释放次数
function eca.SetChargeCount(ability, count)
	local handler = getHandler(ability)
	if not handler then
		return false
	end
	handler.setChargeCount(count or 0)
	return true
end

---@export_eca_func
---@title 设置技能最大释放次数
---@category t_skill
---@desc 设置{#0}最大释放次数为{#1}
---@param ability abilityInstance 技能
---@param maxCount Int 最大释放次数
function eca.SetMaxChargeCount(ability, maxCount)
	local handler = getHandler(ability)
	if not handler then
		return false
	end
	handler.setMaxChargeCount(maxCount or 1)
	return true
end

---@export_eca_func
---@title 设置技能等级
---@category t_skill
---@desc 设置{#0}的当前等级{#1}
---@param ability abilityInstance 技能
---@param level Int 目标等级
function eca.SetLevel(ability, level)
	local handler = getHandler(ability)
	if not handler then
		return false
	end
	handler.setLevel(level or 1)
	return true
end

---@export_eca_func
---@title 设置技能最大等级
---@category t_skill
---@desc 设置{#0}的最大等级{#1}
---@param ability abilityInstance 技能
---@param maxLevel Int 最大等级
function eca.SetMaxLevel(ability, maxLevel)
	local handler = getHandler(ability)
	if not handler then
		return false
	end
	handler.setMaxLevel(maxLevel or 1)
	return true
end

---@export_eca_func
---@title 增加技能等级
---@category t_skill
---@desc {#0}的当前等级增加{#1}
---@param ability abilityInstance 技能
---@param delta Int 等级增量
function eca.IncreaseLevel(ability, delta)
	local handler = getHandler(ability)
	if not handler then
		return false
	end
	-- 受校验升级：遵循技能「能否升级 / 最大等级 / 学习等级需求」配置
	local newLevel = handler.upgrade(delta or 1)
	return newLevel ~= false
end

---@export_eca_func
---@title 设置技能施法距离
---@category t_skill
---@desc 设置{#0}的施法范围{#1}
---@param ability abilityInstance 技能
---@param distance Fixed 施法距离
function eca.SetReleaseDistance(ability, distance)
	local handler = getHandler(ability)
	if not handler then
		return false
	end
	handler.setReleaseDistance(distance or 0)
	return true
end

---@export_eca_func
---@title 增加技能施法距离
---@category t_skill
---@desc 增加{#0}的施法范围{#1}
---@param ability abilityInstance 技能
---@param delta Fixed 施法距离增量
function eca.AddReleaseDistance(ability, delta)
	local handler = getHandler(ability)
	if not handler then
		return false
	end
	handler.addReleaseDistance(delta or 0)
	return true
end

---@export_eca_func
---@title 设置技能作用宽度
---@category t_skill
---@desc 设置{#0}的作用宽度{#1}
---@param ability abilityInstance 技能
---@param width Fixed 作用宽度
function eca.SetAffectWidth(ability, width)
	local handler = getHandler(ability)
	if not handler then
		return false
	end
	handler.setAffectWidth(width or 0)
	return true
end

---@export_eca_func
---@title 增加技能作用宽度
---@category t_skill
---@desc 增加{#0}的作用宽度{#1}
---@param ability abilityInstance 技能
---@param delta Fixed 作用宽度增量
function eca.AddAffectWidth(ability, delta)
	local handler = getHandler(ability)
	if not handler then
		return false
	end
	handler.addAffectWidth(delta or 0)
	return true
end

---@export_eca_func
---@title 设置技能作用半径
---@category t_skill
---@desc 设置{#0}的作用半径{#1}
---@param ability abilityInstance 技能
---@param radius Fixed 作用半径
function eca.SetReleaseRadius(ability, radius)
	local handler = getHandler(ability)
	if not handler then
		return false
	end
	handler.setReleaseRadius(radius or 0)
	return true
end

---@export_eca_func
---@title 增加技能作用半径
---@category t_skill
---@desc 增加{#0}的作用半径{#1}
---@param ability abilityInstance 技能
---@param delta Fixed 作用半径增量
function eca.AddReleaseRadius(ability, delta)
	local handler = getHandler(ability)
	if not handler then
		return false
	end
	handler.addReleaseRadius(delta or 0)
	return true
end

---@export_eca_func
---@title 添加技能
---@category t_skill
---@desc 给{#0}<的{#1}上>添加技能{#2}
---@param unit LifeEntityInstance 目标单位
---@param slot Int 指定槽位 default:-1
---@param abilityKey abilityPrefab 技能预设
function eca.AddAbility(unit, slot, abilityKey)
	local targetSlot = nil
	if slot and slot >= 0 then
		targetSlot = slot
	end
	-- 指定槽位被占用时覆盖原技能；不指定槽位按顺序找空槽（api 内实现）
	local abilityScript = api.AddAbility(unit, abilityKey, targetSlot)
	return abilityScript ~= nil
end

---@export_eca_func
---@title 移除技能（指定槽位）
---@category t_skill
---@desc 移除{#0}的{#1}的技能
---@param unit LifeEntityInstance 目标单位
---@param slot Int 槽位
function eca.RemoveAbilityAtSlot(unit, slot)
	if slot == nil then
		return false
	end
	return api.RemoveAbility(unit, slot) ~= nil
end

---@export_eca_func
---@title 切换为父技能
---@category t_skill
---@desc {#0}切换为父技能
---@param ability abilityInstance 技能
function eca.SwitchToParent(ability)
	local ok = api.SwitchToParent(ability)
	return ok == true
end

---@export_eca_func
---@title 切换为子技能
---@category t_skill
---@desc {#0}切换为{#1}号子技能
---@param ability abilityInstance 技能
---@param childIndex Int 子技能序号（0 基）
function eca.SwitchToChild(ability, childIndex)
	local ok = api.SwitchToChild(ability, childIndex or 0)
	return ok == true
end

---@export_eca_func
---@title 替换技能
---@category t_skill
---@desc {#0}的{#2}号槽位替换为{#1}
---@param unit LifeEntityInstance 目标单位
---@param ability abilityInstance 技能
---@param slot Int 目标槽位
function eca.ReplaceAbility(unit, ability, slot)
	if slot == nil then
		return false
	end
	local ok = api.ReplaceAbility(unit, ability, slot)
	return ok == true
end

---@export_eca_func
---@title 降低技能等级
---@category t_skill
---@desc {#0}的当前等级降低{#1}
---@param ability abilityInstance 技能
---@param delta Int 等级降幅
function eca.DecreaseLevel(ability, delta)
	local handler = getHandler(ability)
	if not handler then
		return false
	end
	handler.decreaseLevel(delta or 1)
	return true
end

---@export_eca_func
---@title 移除技能（指定预设）
---@category t_skill
---@desc 移除{#0}技能预设为{#1}的技能
---@param unit LifeEntityInstance 目标单位
---@param abilityKey abilityPrefab 技能预设
function eca.RemoveAbilityByKey(unit, abilityKey)
	if not abilityKey or abilityKey == "" then
		return false
	end
	api.RemoveAbilityByKey(unit, abilityKey)
	return true
end

---@export_eca_func
---@title 禁用指定技能
---@category t_skill
---@desc 用{#0}标记禁用{#1}的{#2}，持续时间{#3}，将目标技能按钮置灰{#4}，标记技能施放结束后恢复{#5}
---@param marker Int 禁用标记
---@param unit LifeEntityInstance 目标单位
---@param ability abilityInstance 技能
---@param duration Fixed 持续时间（秒，0 表示不限时）
---@param grayout Boolean 是否置灰按钮
---@param recoverAfterCast Boolean 是否在技能施法结束后恢复
function eca.DisableAbility(marker, unit, ability, duration, grayout, recoverAfterCast)
	local ok = api.DisableAbility(
		marker or 0,
		unit,
		ability,
		duration or 0,
		grayout == true,
		recoverAfterCast == true
	)
	return ok == true
end

---@export_eca_func
---@title 切换一次技能
---@category t_skill
---@desc {#0}按照规则切换一次技能
---@param ability abilityInstance 技能
function eca.SwitchAbilityOnce(ability)
	local ok = api.SwitchAbilityNext(ability)
	return ok == true
end

---@export_eca_func
---@title 设置技能是否为充能技能
---@category t_skill
---@desc 设置{#0}为充能技能{#1}<，最大层数{#2}><，充能类型{#3}><，充能间隔{#4}><，充能数量{#5}>
---@param ability abilityInstance 技能
---@param enable Boolean 是否为充能技能 default:true
---@param maxCount Int 最大层数 default:3
---@param chargeType Int 充能类型 style:abilityEnums.ChargeType default:1
---@param interval Fixed 充能间隔 default:5
---@param amount Int 充能数量 default:1
function eca.SetChargeSkill(ability, enable, maxCount, chargeType, interval, amount)
	local handler = getHandler(ability)
	if not handler then
		return false
	end
	local wasConsuming = handler.getScript():GetAttribute("IsChargeConsuming") == true
	handler.setChargeConfig(enable == true, maxCount, chargeType, interval, amount)
	if enable == true then
		if not wasConsuming then
			-- 从非充能切换为充能：按上限补满释放次数（对齐技能初始化语义），后续由消耗/充能策略接管
			handler.setChargeCount(handler.getMaxChargeCount())
		end
	else
		handler.setChargeCount(0)
	end
	return true
end

---@export_eca_func
---@title 设置技能的施法限制
---@category t_skill
---@desc 设置{#0}的施法限制{#1}为{#2}
---@param ability abilityInstance 技能
---@param limitationType Int 施法限制 style:abilityEnums.UseLimitationItem default:1
---@param enable Boolean 是否可用 default:true
function eca.SetUseLimitation(ability, limitationType, enable)
	local handler = getHandler(ability)
	if not handler then
		return false
	end
	handler.setLimitation(limitationType or 1, enable == true)
	return true
end

---@export_eca_func
---@title 移除技能
---@category t_skill
---@desc 移除{#0}
---@param ability abilityInstance 技能
function eca.RemoveAbility(ability)
	return api.RemoveAbilityEntity(ability) ~= nil
end

---@export_eca_func
---@title 禁止技能槽位
---@category t_skill
---@desc 禁用{#0}的{#1}，按钮置灰{#2}
---@param unit LifeEntityInstance 目标单位
---@param slot Int 槽位
---@param grayout Boolean 是否置灰按钮
function eca.ForbidAbilitySlot(unit, slot, grayout)
	local managerHandler = getManagerHandlerOf(unit)
	if not managerHandler or slot == nil then
		return false
	end
	managerHandler.forbidSlot(slot, true, grayout == true)
	return true
end

---@export_eca_func
---@title 激活技能槽位
---@category t_skill
---@desc 启用{#0}的{#1}
---@param unit LifeEntityInstance 目标单位
---@param slot Int 槽位
function eca.ActivateAbilitySlot(unit, slot)
	local managerHandler = getManagerHandlerOf(unit)
	if not managerHandler or slot == nil then
		return false
	end
	managerHandler.forbidSlot(slot, false, false)
	return true
end

-- ============ 事件（技能预设触发器：「此类技能」） ============

---@export_eca_prefab_event
---@title 技能被获得
---@category t_skill
---@scope ability
---@event public Obtained 当 此类技能 被获得 params:[{"name":"ability","type":"abilityInstance","title":"技能"}]
eca.Obtained = nil

---@export_eca_prefab_event
---@title 技能升级
---@category t_skill
---@scope ability
---@event public Upgraded 当 此类技能 升级 params:[{"name":"ability","type":"abilityInstance","title":"技能"},{"name":"level","type":"Int","title":"新等级"}]
eca.Upgraded = nil

---@export_eca_prefab_event
---@title 技能失去
---@category t_skill
---@scope ability
---@event public Lost 当 此类技能 失去 params:[{"name":"ability","type":"abilityInstance","title":"技能"}]
eca.Lost = nil

---@export_eca_prefab_event
---@title 施法阶段结束
---@category t_skill
---@scope ability
---@event public CastEnd 当 此类技能 施法阶段结束 params:[{"name":"ability","type":"abilityInstance","title":"技能"}]
eca.CastEnd = nil

---@export_eca_prefab_event
---@title 施法阶段开始
---@category t_skill
---@scope ability
---@event public CastStart 当 此类技能 施法阶段开始 params:[{"name":"ability","type":"abilityInstance","title":"技能"}]
eca.CastStart = nil

---@export_eca_prefab_event
---@title 蓄力阶段结束
---@category t_skill
---@scope ability
---@event public AccumulateEnd 当 此类技能 蓄力阶段结束 params:[{"name":"ability","type":"abilityInstance","title":"技能"}]
eca.AccumulateEnd = nil

---@export_eca_prefab_event
---@title 蓄力阶段开始
---@category t_skill
---@scope ability
---@event public AccumulateStart 当 此类技能 蓄力阶段开始 params:[{"name":"ability","type":"abilityInstance","title":"技能"}]
eca.AccumulateStart = nil

---@export_eca_prefab_event
---@title 施法阶段被打断
---@category t_skill
---@scope ability
---@event public CastBreak 当 此类技能 施法阶段被打断 params:[{"name":"ability","type":"abilityInstance","title":"技能"}]
eca.CastBreak = nil

---@export_eca_prefab_event
---@title 蓄力阶段被打断
---@category t_skill
---@scope ability
---@event public AccumulateBreak 当 此类技能 蓄力阶段被打断 params:[{"name":"ability","type":"abilityInstance","title":"技能"}]
eca.AccumulateBreak = nil

---@export_eca_prefab_event
---@title 冷却完成
---@category t_skill
---@scope ability
---@event public CDEnd 当 此类技能 冷却完成 params:[{"name":"ability","type":"abilityInstance","title":"技能"}]
eca.CDEnd = nil

---@export_eca_prefab_event
---@title 技能充能完成
---@category t_skill
---@scope ability
---@event public ChargeFull 当 此类技能 充能完成 params:[{"name":"ability","type":"abilityInstance","title":"技能"}]
eca.ChargeFull = nil

---@export_eca_prefab_event
---@title 技能降级
---@category t_skill
---@scope ability
---@event public OnDowngrade 当 此类技能 降级 params:[{"name":"ability","type":"abilityInstance","title":"技能"},{"name":"level","type":"Int","title":"新等级"}]
eca.OnDowngrade = nil

---@export_eca_prefab_event
---@title 技能被切换前
---@category t_skill
---@scope ability
---@event public SwitchBefore 当 此类技能 被切换前 params:[{"name":"next","type":"abilityInstance","title":"即将切换到的技能"}]
eca.SwitchBefore = nil

---@export_eca_prefab_event
---@title 技能切换后
---@category t_skill
---@scope ability
---@event public Switched 当 此类技能 切换后 params:[{"name":"prev","type":"abilityInstance","title":"上一个技能"}]
eca.Switched = nil

-- ============ 事件（锚点预设触发器：「当前锚点」） ============

---@export_eca_prefab_event
---@title 当前锚点开始
---@category t_skill
---@scope ability_anchor
---@event public AnchorStart 当前锚点开始 params:[{"name":"ability","type":"abilityInstance","title":"宿主技能"}]
eca.AnchorStart = nil

---@export_eca_prefab_event
---@title 当前锚点结束
---@category t_skill
---@scope ability_anchor
---@event public AnchorEnd 当前锚点结束 params:[{"name":"ability","type":"abilityInstance","title":"宿主技能"}]
eca.AnchorEnd = nil

---@export_eca_prefab_event
---@title 当前锚点打断
---@category t_skill
---@scope ability_anchor
---@event public AnchorBreak 当前锚点打断 params:[{"name":"ability","type":"abilityInstance","title":"宿主技能"}]
eca.AnchorBreak = nil

---@export_eca_prefab_event
---@title 当前锚点停止
---@category t_skill
---@scope ability_anchor
---@event public AnchorStop 当前锚点停止 params:[{"name":"ability","type":"abilityInstance","title":"宿主技能"}]
eca.AnchorStop = nil

-- ============ 事件（角色/生物触发器：「此类角色/生物」技能中继） ============
-- 事件单位挂在拥有者单位下（名称见 constants.UnitEvent），由 event_bridge 预铺并在技能侧触发

---@export_eca_prefab_event
---@title 技能冷却完成
---@category t_skill
---@scope LifeEntityInstance
---@event public AbilityCDEnd 当 此类角色/生物 冷却完成 params:[{"name":"ability","type":"abilityInstance","title":"完成冷却的技能"}]
eca.AbilityCDEnd = nil

---@export_eca_prefab_event
---@title 技能充能完成
---@category t_skill
---@scope LifeEntityInstance
---@event public AbilityChargeFull 当 此类角色/生物 充能完成 params:[{"name":"ability","type":"abilityInstance","title":"完成充能的技能"}]
eca.AbilityChargeFull = nil

---@export_eca_prefab_event
---@title 生物技能降级
---@category t_skill
---@scope LifeEntityInstance
---@event public AbilityDowngrade 当 此类角色/生物 技能降级 params:[{"name":"ability","type":"abilityInstance","title":"降级的技能"},{"name":"level","type":"Int","title":"新等级"}]
eca.AbilityDowngrade = nil

-- ============ 条件 ============

---@export_eca_func
---@title 技能是否在冷却中
---@category t_skill
---@desc {#0}技能是否在冷却中
---@param ability abilityInstance 技能
---@return Bool
function eca.IsInCD(ability)
	local handler = getHandler(ability)
	return handler ~= nil and handler.getInCD() == true
end

---@export_eca_func
---@title 技能是否在充能中
---@category t_skill
---@desc {#0}是否处于充能中
---@param ability abilityInstance 技能
---@return Bool
function eca.IsInCharge(ability)
	local handler = getHandler(ability)
	return handler ~= nil and handler.getIsInCharge() == true
end

---@export_eca_func
---@title 是否符合技能施放条件
---@category t_skill
---@desc {#0}是否符合{#1}的施放条件
---@param target LifeEntityInstance 目标单位
---@param ability abilityInstance 技能
---@return Bool
function eca.CanUseAbility(target, ability)
	local handler = getHandler(ability)
	if not handler then
		return false
	end
	-- 目标可行性：距离 → 类型 → Tag；冷却/施法/充能由 IsInCD 等条件单独判定
	return handler.isValidTarget(target) == true
end

---@export_eca_func
---@title 判断技能的指示器类型
---@category t_skill
---@desc {#0}是否为{#1}
---@param ability abilityInstance 技能
---@param pointerType Int 指示器类型 style:abilityEnums.PointerType default:0
---@return Bool
function eca.IsPointerType(ability, pointerType)
	local handler = getHandler(ability)
	return handler ~= nil and handler.getPointerType() == (pointerType or 0)
end

---@export_eca_func
---@title 判断技能的目标类型
---@category t_skill
---@desc {#0}是否为{#1}
---@param ability abilityInstance 技能
---@param targetType Int 目标类型 style:abilityEnums.TargetType default:1
---@return Bool
function eca.IsTargetType(ability, targetType)
	local handler = getHandler(ability)
	return handler ~= nil and handler.getTargetType() == (targetType or 0)
end

---@export_eca_func
---@title 判断技能的施法限制
---@category t_skill
---@desc {#0}是否在{#1}可用
---@param ability abilityInstance 技能
---@param limitationType Int 施法限制 style:abilityEnums.UseLimitationItem default:1
---@return Bool
function eca.IsLimitationUsable(ability, limitationType)
	local handler = getHandler(ability)
	return handler ~= nil and handler.getLimitation(limitationType or 1) == true
end

-- ============ 获取 ============

---@export_eca_func
---@title 获取技能的预设
---@category t_skill
---@value_only
---@desc {#0}的预设
---@param ability abilityInstance 技能
---@return abilityPrefab
function eca.GetAbilityPreset(ability)
	local handler = getHandler(ability)
	if not handler then
		return ""
	end
	return handler.getPresetKey()
end

---@export_eca_func
---@title 获取技能施法方向
---@category t_skill
---@value_only
---@desc {#0}的施法方向
---@param ability abilityInstance 技能
---@return Vector3
function eca.GetCastDirection(ability)
	local handler = getHandler(ability)
	if not handler then
		return Vector3.New(0, 0, 0)
	end
	return handler.getReleaseDirection() or Vector3.New(0, 0, 0)
end

---@export_eca_func
---@title 获取技能施法目标点
---@category t_skill
---@value_only
---@desc {#0}的施法目标点
---@param ability abilityInstance 技能
---@return Vector3
function eca.GetCastPoint(ability)
	local handler = getHandler(ability)
	if not handler then
		return Vector3.New(0, 0, 0)
	end
	local point = handler.getReleasePoint()
	if not point then
		return Vector3.New(0, 0, 0)
	end
	-- 返回副本，避免调用方改写技能属性向量
	return Vector3.New(point.x, point.y, point.z)
end

---@export_eca_func
---@title 获取技能锁定生物
---@category t_skill
---@value_only
---@desc {#0}锁定生物
---@param ability abilityInstance 技能
---@return LifeEntityInstance
function eca.GetLockedUnit(ability)
	local handler = getHandler(ability)
	if not handler then
		return nil
	end
	return resolveUnitById(handler.getReleaseTarget())
end

---@export_eca_func
---@title 获取技能蓄力百分比
---@category t_skill
---@value_only
---@desc {#0}的蓄力百分比
---@param ability abilityInstance 技能
---@return Fixed
function eca.GetAccumulateRatio(ability)
	local handler = getHandler(ability)
	if not handler then
		return 0
	end
	return handler.getAccumulateRatio() or 0
end

---@export_eca_func
---@title 获取技能剩余冷却时间
---@category t_skill
---@value_only
---@desc {#0}剩余冷却时间
---@param ability abilityInstance 技能
---@return Fixed
function eca.GetLeftCDTime(ability)
	local handler = getHandler(ability)
	if not handler then
		return 0
	end
	return handler.getLeftCD() or 0
end

---@export_eca_func
---@title 拥有技能的生物
---@category t_skill
---@value_only
---@desc 拥有{#0}的生物
---@param ability abilityInstance 技能
---@return LifeEntityInstance
function eca.GetAbilityOwner(ability)
	local handler = getHandler(ability)
	if not handler then
		return nil
	end
	return getOwnerOfHandler(handler)
end

---@export_eca_func
---@title 获取技能等级
---@category t_skill
---@value_only
---@desc 获取{#0}的当前等级
---@param ability abilityInstance 技能
---@return Int
function eca.GetAbilityLevel(ability)
	local handler = getHandler(ability)
	if not handler then
		return 0
	end
	return handler.getLevel() or 1
end

---@export_eca_func
---@title 获取技能最大等级
---@category t_skill
---@value_only
---@desc 获取{#0}的最大等级
---@param ability abilityInstance 技能
---@return Int
function eca.GetAbilityMaxLevel(ability)
	local handler = getHandler(ability)
	if not handler then
		return 0
	end
	return handler.getMaxLevel() or 1
end

---@export_eca_func
---@title 获取技能剩余充能时间
---@category t_skill
---@value_only
---@desc 获取{#0}剩余充能时间
---@param ability abilityInstance 技能
---@return Fixed
function eca.GetChargeLeftTime(ability)
	local handler = getHandler(ability)
	if not handler then
		return 0
	end
	return handler.getChargeLeftTime() or 0
end

---@export_eca_func
---@title 获取技能施法距离
---@category t_skill
---@value_only
---@desc 获取{#0}的施法距离
---@param ability abilityInstance 技能
---@return Fixed
function eca.GetCastDistance(ability)
	local handler = getHandler(ability)
	if not handler then
		return 0
	end
	return handler.getReleaseDistance() or 0
end

---@export_eca_func
---@title 获取技能作用宽度
---@category t_skill
---@value_only
---@desc 获取{#0}的作用宽度
---@param ability abilityInstance 技能
---@return Fixed
function eca.GetAffectWidth(ability)
	local handler = getHandler(ability)
	if not handler then
		return 0
	end
	return handler.getAffectWidth() or 0
end

---@export_eca_func
---@title 获取技能作用半径
---@category t_skill
---@value_only
---@desc 获取{#0}的作用半径
---@param ability abilityInstance 技能
---@return Fixed
function eca.GetAffectRadius(ability)
	local handler = getHandler(ability)
	if not handler then
		return 0
	end
	return handler.getReleaseRadius() or 0
end

---@export_eca_func
---@title 获取技能的充能时间
---@category t_skill
---@value_only
---@desc 获取{#0}的充能时间
---@param ability abilityInstance 技能
---@return Fixed
function eca.GetChargeIntervalTime(ability)
	local handler = getHandler(ability)
	if not handler then
		return 0
	end
	return handler.getChargeInterval() or 0
end

---@export_eca_func
---@title 获取技能（指定预设）
---@category t_skill
---@value_only
---@desc 获取{#0}身上预设为{#1}的技能
---@param unit LifeEntityInstance 目标单位
---@param abilityKey abilityPrefab 技能预设
---@return abilityInstance
function eca.GetAbilityByPreset(unit, abilityKey)
	return api.GetAbilityByKey(unit, abilityKey)
end

---@export_eca_func
---@title 获取技能（指定槽位）
---@category t_skill
---@value_only
---@desc 获取{#0}在{#1}号槽位的技能
---@param unit LifeEntityInstance 目标单位
---@param slot Int 槽位
---@return abilityInstance
function eca.GetAbilityAtSlot(unit, slot)
	if slot == nil then
		return nil
	end
	return api.GetAbility(unit, slot)
end

---@export_eca_func
---@title 获取技能当前使用次数
---@category t_skill
---@value_only
---@desc 获取{#0}当前使用次数
---@param ability abilityInstance 技能
---@return Int
function eca.GetChargeCount(ability)
	local handler = getHandler(ability)
	if not handler then
		return 0
	end
	return handler.getChargeCount() or 0
end

---@export_eca_func
---@title 获取技能最大使用次数
---@category t_skill
---@value_only
---@desc 获取{#0}最大使用次数
---@param ability abilityInstance 技能
---@return Int
function eca.GetMaxChargeCount(ability)
	local handler = getHandler(ability)
	if not handler then
		return 0
	end
	return handler.getMaxChargeCount() or 0
end

---@export_eca_func
---@title 获取技能指示器水平速度
---@category t_skill
---@value_only
---@desc 获取{#0} 水平速度
---@param ability abilityInstance 技能
---@return Fixed
function eca.GetParabolaHorizontalSpeed(ability)
	local handler = getHandler(ability)
	if not handler then
		return 0
	end
	return handler.getParabolaHorizontalSpeed() or 0
end

---@export_eca_func
---@title 获取技能指示器垂直速度
---@category t_skill
---@value_only
---@desc 获取{#0} 垂直速度
---@param ability abilityInstance 技能
---@return Fixed
function eca.GetParabolaVerticalSpeed(ability)
	local handler = getHandler(ability)
	if not handler then
		return 0
	end
	return handler.getParabolaVerticalSpeed() or 0
end

---@export_eca_func
---@title 获取技能指示器目标选择类型的生物列表
---@category t_skill
---@value_only
---@desc 获取{#0}符合指示器目标选择类型，高度为{#1}内的所有生物
---@param ability abilityInstance 技能
---@param height Fixed 查询高度 default:10.0
---@return LifeEntityInstance[]
function eca.GetValidTargetsCreature(ability, height)
	local handler = getHandler(ability)
	if not handler then
		return {}
	end
	-- 注：空间查询候选列表尚未启用（target_filter 空壳），当前返回空列表
	return TargetFilter.getValidTargetsInRange(handler, getOwnerOfHandler(handler), height or 10.0)
end

---@export_eca_func
---@title 获取技能指示器目标选择类型的组件列表
---@category t_skill
---@value_only
---@desc 获取{#0}符合指示器目标选择类型，高度为{#1}内的所有组件
---@param ability abilityInstance 技能
---@param height Fixed 查询高度 default:10.0
---@return WorldUnit[]
function eca.GetValidTargetsComponent(ability, height)
	local handler = getHandler(ability)
	if not handler then
		return {}
	end
	-- 注：空间查询候选列表尚未启用（target_filter 空壳），当前返回空列表
	return TargetFilter.getValidTargetsInRange(handler, getOwnerOfHandler(handler), height or 10.0)
end

---@export_eca_func
---@title 获取技能最大冷却时间
---@category t_skill
---@value_only
---@desc 获取{#0}最大冷却时间
---@param ability abilityInstance 技能
---@return Fixed
function eca.GetMaxCDTime(ability)
	local handler = getHandler(ability)
	if not handler then
		return 0
	end
	-- 注：SE 技能无冷却公式系统，直接返回技能配置的冷却时间
	return handler.getCdTime() or 0
end

---@export_eca_func
---@title 获取技能指示器目标选择类型的角色/生物列表
---@category t_skill
---@value_only
---@desc 获取{#0}符合指示器目标选择类型，高度为{#1}内的所有角色/生物
---@param ability abilityInstance 技能
---@param height Fixed 查询高度 default:10.0
---@return LifeEntityInstance[]
function eca.GetValidTargetsRole(ability, height)
	local handler = getHandler(ability)
	if not handler then
		return {}
	end
	-- 注：空间查询候选列表尚未启用（target_filter 空壳），当前返回空列表
	return TargetFilter.getValidTargetsInRange(handler, getOwnerOfHandler(handler), height or 10.0)
end

---@export_eca_func
---@title 获取符合技能目标选择类型的生物列表
---@category t_skill
---@value_only
---@desc 获取{#0}，高度为{#1}内符合目标选择类型的生物列表<，是否固定施法位置{#2}>
---@param ability abilityInstance 技能
---@param height Fixed 查询高度 default:10.0
---@param fixedCastPoint Boolean 是否固定施法位置 default:false
---@return LifeEntityInstance[]
function eca.GetTargetTypeUnits(ability, height, fixedCastPoint)
	local handler = getHandler(ability)
	if not handler then
		return {}
	end
	-- 注：空间查询候选列表尚未启用（target_filter 空壳），当前返回空列表；
	-- fixedCastPoint（以施法落点为查询原点）随空间查询落地后对齐
	return TargetFilter.getValidTargetsInRange(handler, getOwnerOfHandler(handler), height or 10.0)
end

---@export_eca_func
---@title 获取符合技能目标选择类型的角色/生物列表
---@category t_skill
---@value_only
---@desc 获取{#0}，高度为{#1}内符合目标选择类型的角色/生物列表<，是否固定施法位置{#2}>
---@param ability abilityInstance 技能
---@param height Fixed 查询高度 default:10.0
---@param fixedCastPoint Boolean 是否固定施法位置 default:false
---@return LifeEntityInstance[]
function eca.GetTargetTypeRoles(ability, height, fixedCastPoint)
	local handler = getHandler(ability)
	if not handler then
		return {}
	end
	-- 注：空间查询候选列表尚未启用（target_filter 空壳），当前返回空列表；
	-- fixedCastPoint（以施法落点为查询原点）随空间查询落地后对齐
	return TargetFilter.getValidTargetsInRange(handler, getOwnerOfHandler(handler), height or 10.0)
end

---@export_eca_func
---@title 获取技能复数施法目标点
---@category t_skill
---@value_only
---@desc {#0}的复数施法目标点
---@param ability abilityInstance 技能
---@return Vector3[]
function eca.GetMultiCastPoints(ability)
	local handler = getHandler(ability)
	if not handler then
		return {}
	end
	-- v1：客户端仅上报单个释放点，返回单元素列表；复数指针协议扩展后改为返回全部点位
	local point = handler.getReleasePoint()
	if not point then
		return {}
	end
	return { point }
end

---@export_eca_func
---@title 获取技能复数施法方向
---@category t_skill
---@value_only
---@desc {#0}的复数施法方向
---@param ability abilityInstance 技能
---@return Vector3[]
function eca.GetMultiCastDirections(ability)
	local handler = getHandler(ability)
	if not handler then
		return {}
	end
	-- v1：客户端仅上报单个释放方向，返回单元素列表；复数指针协议扩展后改为返回全部方向
	local dir = handler.getReleaseDirection()
	if not dir then
		return {}
	end
	return { dir }
end

---@export_eca_func
---@title 获取指定槽位范围内的技能列表
---@category t_skill
---@value_only
---@desc 获取{#0}身上{#1}到{#2}槽位的技能列表
---@param unit LifeEntityInstance 目标单位
---@param startSlot Int 起始槽位
---@param endSlot Int 结束槽位
---@return abilityInstance[]
function eca.GetAbilitiesInSlots(unit, startSlot, endSlot)
	if startSlot == nil or endSlot == nil then
		return {}
	end
	return api.GetAbilitiesFromIndexRange(unit, startSlot, endSlot)
end

---@export_eca_func
---@title 获取技能的图标图片
---@category t_skill
---@value_only
---@desc 获取{#0}的图标图片
---@param ability abilityInstance 技能
---@return String
function eca.GetAbilityIcon(ability)
	local handler = getHandler(ability)
	if not handler then
		return ""
	end
	local scriptUnit = handler.getScript()
	-- 与客户端技能栏取图标同口径：遍历全部 PresetLink 取首个非空 PrefabIcon，兜底技能 Icon 属性
	local icon = nil
	local okChildren, children = pcall(function()
		return scriptUnit:GetChildren()
	end)
	if okChildren and children then
		for _, child in ipairs(children) do
			local okIs, isLink = pcall(function()
				return child:IsA("PresetLink")
			end)
			if okIs and isLink then
				local okIcon, value = pcall(function()
					return child:GetAttribute("PrefabIcon")
				end)
				if okIcon and value and value ~= "" then
					icon = value
					break
				end
			end
		end
	end
	if not icon or icon == "" then
		icon = scriptUnit:GetAttribute("Icon")
	end
	return icon or ""
end

---@export_eca_func
---@title 获取目标的所有技能
---@category t_skill
---@value_only
---@desc 获取{#0}拥有的所有技能列表
---@param unit LifeEntityInstance 目标单位
---@return abilityInstance[]
function eca.GetOwnedAbilities(unit)
	return api.GetAbilities(unit)
end

return eca

