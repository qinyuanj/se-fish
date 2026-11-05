--效果系统包 - 客户端状态栏槽位节点行为
--
-- 使用方式：EffectStatusBarUI 找到槽位节点后调用 Attach(node) 初始化，
-- 之后以 EffectSlotNode.xxx(node, ...) 形式驱动；Lua 侧 _nodeState 缓存状态
-- （EUI 节点是引擎 userdata，禁止挂自定义字段）。
--
-- 节点结构约定（作者在编辑器摆放）：
--   [槽位根] custom_kv: UIType="EffectSlot" + Index=<槽位号>
--     ├─ Image_icon  (EUIImage)          ← 效果图标
--     ├─ Progress_cd (EUIProgressTimer)  ← 倒计时进度环（能力探测：首个带 SetPercent 的后代）
--     └─ Text_cd     (EUITextLabel)      ← 层数文本（当前层数，整数）
--
-- 触摸约定：槽位根与全部覆盖层（Image_icon/Progress_cd/Text_cd）统一开关触摸，
-- 且每一层都在 EffectStatusBarUI 接线长按/松开信号——命中层级以引擎为准，
-- 避免"上层节点吞触摸但未接线"造成的静默无响应。
--
-- 生命周期：槽位节点与 UI 同寿（_nodeState 按节点数有界）；如未来引入 UI 树重建，
-- 需补充 Detach 清理接口并挂到销毁路径。

local UIConsts = require("client.packages.modifier_system.ui.ui_consts")
local EuiAdapter = require("client.packages.modifier_system.ui.eui_adapter")

local EffectSlotNode = {}

-- 诊断日志（联调期开关 UIConsts.DIAG）
local function diag(...)
	if UIConsts.DIAG then
		print("[modifier_system][UI][diag]", ...)
	end
end

local _nodeState = {} -- [node] = state table

local function getState(node)
	if not _nodeState[node] then
		_nodeState[node] = {
			attached = false,
			visibleState = nil, -- nil/true/false：避免重复写引擎
			Icon = nil,
			Progress = nil,
			Text = nil,
			textShown = false,
			textHidden = false,
			progressShown = false,
			iconHidden = false,
			lastIcon = nil,
			lastText = nil,
			lastPercent = nil,
		}
	end
	return _nodeState[node]
end

-- 取可直接 SetPercent 的节点：优先按名查找；节点缺失或没有 SetPercent 时
-- 取首个带 SetPercent 的后代（兼容 Layout 容器嵌套与命名差异）
local function resolveProgressNode(node)
	local progress = EuiAdapter.FindFirstChild(node, UIConsts.SLOT_CHILD.Progress)
	if progress and type(progress.SetPercent) == "function" then
		return progress
	end
	for _, child in ipairs(EuiAdapter.GetDescendants(node)) do
		if type(child.SetPercent) == "function" then
			return child
		end
	end
	return progress
end

-- Attach：绑定子节点引用（幂等）
function EffectSlotNode.Attach(node)
	if not node then
		return node
	end
	local st = getState(node)
	if st.attached then
		return node
	end
	st.attached = true
	st.Icon = EuiAdapter.FindFirstChild(node, UIConsts.SLOT_CHILD.Icon)
	st.Progress = resolveProgressNode(node)
	st.Text = EuiAdapter.FindFirstChild(node, UIConsts.SLOT_CHILD.Text)
	diag(
		"slot children:",
		"Icon=" .. tostring(st.Icon ~= nil),
		"Progress=" .. tostring(st.Progress ~= nil),
		"Text=" .. tostring(st.Text ~= nil)
	)
	return node
end

-- 可触摸层列表：槽位根 + 全部覆盖层（图标/进度环/层数文本，自上而下全覆盖）。
-- 两用：SetVisibleState 按列表统一开关触摸；EffectStatusBarUI 按列表逐一接线。
-- 目的：任一覆盖层命中（命中层级以引擎为准）都能触发长按，且不存在
-- "启用触摸但未接线"的静默吞触摸层
function EffectSlotNode.GetTouchTargets(node)
	local st = getState(node)
	local targets = {}
	local function add(target, label)
		if target then
			targets[#targets + 1] = { node = target, label = label }
		end
	end
	add(node, "root")
	add(st.Icon, "icon")
	add(st.Progress, "progress")
	add(st.Text, "text")
	return targets
end

-- 显隐（含触摸开关）：隐藏时复位内容缓存并收起功能子节点，
-- 确保再次显示时全量重写、不残留上一次的内容
function EffectSlotNode.SetVisibleState(node, visible)
	if not node then
		return
	end
	local st = getState(node)
	visible = visible and true or false
	if st.visibleState == visible then
		return
	end
	st.visibleState = visible
	EuiAdapter.SetVisible(node, visible)
	for _, target in ipairs(EffectSlotNode.GetTouchTargets(node)) do
		EuiAdapter.SetTouchEnabled(target.node, visible)
	end
	if not visible then
		st.textShown = false
		st.progressShown = false
		st.lastIcon = nil
		st.lastText = nil
		st.lastPercent = nil
		if st.Text then
			EuiAdapter.SetVisible(st.Text, false)
		end
		if st.Progress then
			EuiAdapter.SetVisible(st.Progress, false)
		end
	end
end

-- 设置图标：无图标效果隐藏图标节点（避免槽位复用后残留上一个效果的图标）；
-- 差量判断，写入成功才提交缓存以便下轮重试
function EffectSlotNode.SetIcon(node, icon)
	if not node then
		return
	end
	local st = getState(node)
	if not st.Icon then
		return
	end
	if type(icon) ~= "string" or icon == "" then
		if not st.iconHidden then
			st.iconHidden = true
			st.lastIcon = nil
			EuiAdapter.SetVisible(st.Icon, false)
		end
		return
	end
	if st.lastIcon == icon and not st.iconHidden then
		return
	end
	if EuiAdapter.SetImage(st.Icon, icon) then
		st.lastIcon = icon
		st.iconHidden = false
		EuiAdapter.SetVisible(st.Icon, true)
	end
end

-- 刷新层数展示：层数为有效正数时显示整数文本，否则隐藏；
-- 最大层数为 1 时不显示层数角标（单层效果层数无展示意义）
function EffectSlotNode.SetStackCount(node, count, maxStackCount)
	if not node then
		return
	end
	local st = getState(node)
	local value = tonumber(count)
	if value ~= nil then
		value = math.floor(value)
	end
	if value == nil or value <= 0 or tonumber(maxStackCount) == 1 then
		-- 幂等隐藏：首次也写一次（不依赖场景默认显隐），避免默认文本残留在角标上
		if not st.textHidden then
			st.textHidden = true
			st.textShown = false
			st.lastText = nil
			if st.Text then
				EuiAdapter.SetVisible(st.Text, false)
			end
		end
		return
	end
	if st.Text then
		local text = tostring(value)
		if not st.textShown or st.lastText ~= text then
			st.textShown = true
			st.textHidden = false
			st.lastText = text
			EuiAdapter.SetText(st.Text, text)
			EuiAdapter.SetVisible(st.Text, true)
		end
	end
end

-- 刷新倒计时进度环：
--   remaining == nil → 隐藏进度环（永久效果 / 数据缺失）
--   remaining 为数字 → 进度 = remaining/duration（duration 非法时隐藏进度环）
function EffectSlotNode.SetProgress(node, remaining, duration)
	if not node then
		return
	end
	if remaining ~= nil and type(remaining) ~= "number" then
		remaining = nil
	end
	local st = getState(node)

	if remaining == nil then
		st.progressShown = false
		st.lastPercent = nil
		if st.Progress then
			EuiAdapter.SetVisible(st.Progress, false)
		end
		return
	end

	if st.Progress then
		local percent = EffectSlotNode.CalcPercent(remaining, duration)
		if percent == nil then
			-- 总时长不可用：隐藏进度环（不显示错误比例）
			st.progressShown = false
			st.lastPercent = nil
			EuiAdapter.SetVisible(st.Progress, false)
		elseif not st.progressShown or st.lastPercent ~= percent then
			st.progressShown = true
			st.lastPercent = percent
			EuiAdapter.SetPercent(st.Progress, percent)
			EuiAdapter.SetVisible(st.Progress, true)
		end
	end
end

-- 进度百分比：仅当 duration 为有效正数时计算；越界封顶 100%
function EffectSlotNode.CalcPercent(remaining, duration)
	if type(duration) ~= "number" or duration <= 0 then
		return nil
	end
	local ratio = remaining / duration
	if ratio < 0 then
		ratio = 0
	end
	if ratio > 1 then
		ratio = 1
	end
	return ratio * 100
end

return EffectSlotNode
