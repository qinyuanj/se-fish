--技能系统 - 枚举
-- 供编辑器反射的枚举声明：ECA 参数通过 style:abilityEnums.PointerType 等引用，
-- 运行时代码不依赖本文件（运行时取值见 constants.lua，数值与其保持一致）。
-- 文件位置对齐工程惯例：common/packages/<包名>/enums.lua

local abilityEnums = {}

---@export_enum
---@name 指示器类型
---@inherit Int
---@default 0
---@enum PointerType
abilityEnums.PointerType = {
	---@enumValue 无指示器
	None = 0,
	---@enumValue 矩形
	Rectangle = 1,
	---@enumValue 圆形
	Circle = 2,
	---@enumValue 扇形
	Sector = 3,
	---@enumValue 抛物线
	Parabola = 4,
}

---@export_enum
---@name 目标类型
---@inherit Int
---@default 1
---@enum TargetType
abilityEnums.TargetType = {
	---@enumValue 无目标
	NoTarget = 0,
	---@enumValue 方向
	Direction = 1,
	---@enumValue 点
	Point = 2,
	---@enumValue 单位
	Unit = 3,
}

---@export_enum
---@name 施法限制
---@inherit Int
---@default 1
---@enum UseLimitationItem
abilityEnums.UseLimitationItem = {
	---@enumValue 施法中
	InCast = 1,
	---@enumValue 失控中
	UnControllable = 2,
	---@enumValue 滚动中
	Roll = 4,
	---@enumValue 冰冻中
	Freezed = 8,
}

---@export_enum
---@name 充能类型
---@inherit Int
---@default 1
---@enum ChargeType
abilityEnums.ChargeType = {
	---@enumValue 不充能
	None = 0,
	---@enumValue 不满时充能
	WhenNotFull = 1,
	---@enumValue 用完后充能
	WhenEmpty = 2,
}

local Enums = {
	PointerType = abilityEnums.PointerType,
	TargetType = abilityEnums.TargetType,
	UseLimitationItem = abilityEnums.UseLimitationItem,
	ChargeType = abilityEnums.ChargeType,
}

return Enums
