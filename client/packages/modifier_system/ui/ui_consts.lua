--效果系统包 - 客户端UI常量
--状态栏/详情面板的节点标识、默认预设、刷新与交互参数。

local UIConsts = {}

-- UI 节点识别（节点自定义属性）：预设/画布节点上配置，运行时 GetAttribute 读取
UIConsts.UIType = {
	StatusBar = "EffectStatusBar",
	Slot = "EffectSlot",
	Detail = "EffectDetail",
}

-- 自定义属性键名（GetAttribute 的键；与技能系统 UIType/Index 约定一致）
UIConsts.ATTR_UI_TYPE = "UIType"
UIConsts.ATTR_SLOT_INDEX = "Index"

-- 节点名兜底（未配置自定义属性时按名字定位）
UIConsts.NodeName = {
	StatusBar = "效果状态栏",
	Detail = "效果详情",
}

-- 槽位名字兜底模式（Node_1 ... Node_16）
UIConsts.SLOT_NAME_PATTERN = "^Node_(%d+)$"

-- 详情预设（随平权包分发；预设 id 跨地图稳定，可用属性/接口覆盖）
UIConsts.DEFAULT_DETAIL_PRESET = "map://preset/402dcbd7f8d34cca9f80fdedb863b1ee"

-- 状态栏根可携带的自定义属性：覆盖详情预设 uri（可选）
UIConsts.ATTR_DETAIL_PRESET = "DetailPreset"

-- 槽位上限（状态栏固定槽位数）
UIConsts.MAX_SLOTS = 16

-- 刷新与交互参数
UIConsts.TICK_INTERVAL = 0.1 -- 刷新间隔（秒）
UIConsts.HOLD_TIME = 0.5 -- 长按判定时长（秒）
UIConsts.NODE_RETRY_INTERVAL = 0.5 -- 状态栏节点查找重试间隔（秒）
UIConsts.NODE_RETRY_MAX = 60 -- 状态栏节点查找最大重试次数（约 30s）
UIConsts.CREATE_RETRY_INTERVAL = 0.5 -- 详情预设创建重试间隔（秒）
UIConsts.CREATE_RETRY_MAX = 5 -- 详情预设创建最大重试次数
UIConsts.PANEL_Z_ORDER = 100 -- 详情面板层级（盖在状态栏之上）

-- 槽位子节点名（图标/进度环/层数文本）
UIConsts.SLOT_CHILD = {
	Icon = "Image_icon",
	Progress = "Progress_cd",
	Text = "Text_cd",
}

-- 详情子节点名（图标/名称/描述）
UIConsts.DETAIL_CHILD = {
	Icon = "image_icon",
	Name = "modifier_name",
	Desc = "modifier_desc",
}

-- 调试日志开关
UIConsts.DEBUG = false

-- 诊断日志开关：联调期打开（长按链路 / 图标来源 / 面板创建链路），验证完成后置 false
UIConsts.DIAG = false

return UIConsts
