--效果系统包 - 客户端效果详情面板
--职责：按住状态栏槽位时，动态创建详情预设到界面中心，展示对应效果的
--      图标/名称/描述；松开槽位隐藏。创建失败自动重试；实例缓存复用，
--      仅在重置（切控/重生）时销毁。

local World = game:GetService("World")
local Task = game:GetService("Task")

local UIConsts = require("client.packages.modifier_system.ui.ui_consts")
local EuiAdapter = require("client.packages.modifier_system.ui.eui_adapter")

local EffectDetailPanel = {}

local _panel = nil -- 已创建的详情根节点
local _children = nil -- 子节点引用 { Icon, Name, Desc }
local _panelUri = nil -- 详情预设 uri 覆盖值（可选）
local _wantVisible = false -- 期望可见状态
local _pendingData = nil -- 创建完成前最后一次请求的数据
local _renderKey = nil -- 渲染差量键
local _creating = false -- 创建中标记，防止并发重试
local _retryPending = false -- 重试排队中标记，避免重复 Show 拉起多条重试链
local _epoch = 0 -- 销毁代际，防止过期重试挂回旧实例

local function log(...)
	if UIConsts.DEBUG then
		print("[modifier_system][UI]", ...)
	end
end

-- 诊断日志（联调期开关 UIConsts.DIAG）
local function diag(...)
	if UIConsts.DIAG then
		print("[modifier_system][UI][diag]", ...)
	end
end

local function resolvePresetUri()
	if _panelUri and _panelUri ~= "" then
		return _panelUri
	end
	return UIConsts.DEFAULT_DETAIL_PRESET
end

---设置详情预设 uri（可选覆盖；缺省使用 UIConsts.DEFAULT_DETAIL_PRESET）
---@param uri string 详情预设 uri
function EffectDetailPanel.SetPresetUri(uri)
	_panelUri = uri
end

-- 子节点绑定（按名 + 常用大小写变体）
local function findChildVariant(node, names)
	for _, name in ipairs(names) do
		local child = EuiAdapter.FindFirstChild(node, name)
		if child then
			return child
		end
	end
	return nil
end

local function bindChildren(panel)
	return {
		Icon = findChildVariant(panel, { UIConsts.DETAIL_CHILD.Icon, "Image_icon" }),
		Name = findChildVariant(panel, { UIConsts.DETAIL_CHILD.Name, "Modifier_name" }),
		Desc = findChildVariant(panel, { UIConsts.DETAIL_CHILD.Desc, "Modifier_desc" }),
	}
end

-- 渲染内容（差量：内容不变不重写）
local function render(data)
	if not _panel or not _children then
		return
	end
	local key = tostring(data.icon) .. "\1" .. tostring(data.name) .. "\1" .. tostring(data.desc)
	if key == _renderKey then
		return
	end
	_renderKey = key
	if _children.Icon then
		if type(data.icon) == "string" and data.icon ~= "" then
			EuiAdapter.SetImage(_children.Icon, data.icon)
			EuiAdapter.SetVisible(_children.Icon, true)
		else
			-- 无图标效果：隐藏图标节点，避免复用面板时残留上一个效果的图标
			EuiAdapter.SetVisible(_children.Icon, false)
		end
	end
	if _children.Name then
		EuiAdapter.SetText(_children.Name, data.name or "")
	end
	if _children.Desc then
		EuiAdapter.SetText(_children.Desc, data.desc or "")
	end
end

-- 居中（EUI 根尺寸的一半）并入树；根尺寸读不到时保持预设位置
local function attachToRoot(panel)
	local euiRoot = EuiAdapter.GetRootNode()
	if not euiRoot then
		diag("attach failed: EUI root nil")
		return false
	end
	local size = EuiAdapter.GetSize(euiRoot)
	if size and type(size.x) == "number" and type(size.y) == "number" and size.x > 0 and size.y > 0 then
		if Vector2 and Vector2.New then
			EuiAdapter.SetAnchor(panel, Vector2.New(0.5, 0.5))
			EuiAdapter.SetPosition(panel, Vector2.New(size.x * 0.5, size.y * 0.5))
		end
	else
		log("EUI 根尺寸读取失败，详情面板保持预设位置")
	end
	EuiAdapter.SetZOrder(panel, UIConsts.PANEL_Z_ORDER)
	local okSet = pcall(function()
		panel.Parent = euiRoot
	end)
	if not okSet then
		diag("attach failed: parent set error")
		return false
	end
	local okGet, parent = pcall(function()
		return panel.Parent
	end)
	if okGet and parent ~= euiRoot then
		diag("attach failed: parent readback mismatch")
		return false
	end
	if panel.RefreshLayout then
		pcall(function()
			panel:RefreshLayout()
		end)
	end
	diag("panel attached to EUI root")
	return true
end

-- 从创建结果 units 中找详情根（UIType 属性优先，名字兜底）
local function findDetailRoot(units)
	for _, unit in ipairs(units) do
		local ok, attr = pcall(function()
			return unit.GetAttribute and unit:GetAttribute(UIConsts.ATTR_UI_TYPE)
		end)
		if ok and attr == UIConsts.UIType.Detail then
			return unit
		end
	end
	for _, unit in ipairs(units) do
		local ok, name = pcall(function()
			return unit.Name
		end)
		if ok and name == UIConsts.NodeName.Detail then
			return unit
		end
	end
	return nil
end

-- 创建详情面板（异步有界重试；epoch 失效丢弃）
local tryCreate
tryCreate = function(attempt, epoch)
	if _panel or _creating or _retryPending or epoch ~= _epoch then
		return
	end
	_creating = true
	diag("panel create attempt", attempt, "uri=", resolvePresetUri())
	local ok, units = pcall(function()
		return World:CreateAsset(resolvePresetUri())
	end)
	_creating = false
	local root = nil
	if ok and type(units) == "table" then
		root = findDetailRoot(units)
	end
	diag(
		"panel create result: ok=" .. tostring(ok),
		"units=" .. tostring(ok and type(units) == "table" and #units or "n/a"),
		"root=" .. (root and "found" or "nil")
	)
	if not root then
		if ok and type(units) == "table" then
			for _, unit in ipairs(units) do
				pcall(function()
					unit:Destroy()
				end)
			end
		end
		if attempt < UIConsts.CREATE_RETRY_MAX then
			_retryPending = true
			Task:Delay(UIConsts.CREATE_RETRY_INTERVAL, function()
				if epoch ~= _epoch then
					return -- 旧代际：不触碰新链的重试标记
				end
				_retryPending = false
				tryCreate(attempt + 1, epoch)
			end)
		else
			print(string.format("[modifier_system][UI] 详情面板创建失败：%s", resolvePresetUri()))
		end
		return
	end
	if not attachToRoot(root) then
		pcall(function()
			root:Destroy()
		end)
		if attempt < UIConsts.CREATE_RETRY_MAX then
			_retryPending = true
			Task:Delay(UIConsts.CREATE_RETRY_INTERVAL, function()
				if epoch ~= _epoch then
					return -- 旧代际：不触碰新链的重试标记
				end
				_retryPending = false
				tryCreate(attempt + 1, epoch)
			end)
		else
			print("[modifier_system][UI] EUI 根节点未就绪，详情面板创建失败")
		end
		return
	end
	_panel = root
	_children = bindChildren(root)
	_renderKey = nil
	EuiAdapter.SetVisible(root, false)
	if _wantVisible and _pendingData then
		render(_pendingData)
		EuiAdapter.SetVisible(root, true)
	end
	log("详情面板就绪")
	diag("panel ready; wantVisible=", tostring(_wantVisible))
end

-- 公开 API

---按住槽位时显示详情（面板未创建时触发懒创建）
---@param data table 效果展示数据（icon/name/desc）
function EffectDetailPanel.Show(data)
	if not data then
		return
	end
	diag(
		"panel show: icon=" .. tostring(data.icon),
		"name=" .. tostring(data.name),
		"desc=" .. tostring(data.desc),
		"created=" .. tostring(_panel ~= nil)
	)
	_pendingData = data
	_wantVisible = true
	if _panel then
		render(data)
		EuiAdapter.SetVisible(_panel, true)
		return
	end
	tryCreate(1, _epoch)
end

---隐藏面板（松开槽位 / 绑定失效）
function EffectDetailPanel.Hide()
	local wasVisible = _wantVisible
	_wantVisible = false
	_pendingData = nil
	if _panel then
		EuiAdapter.SetVisible(_panel, false)
	end
	if wasVisible then
		diag("panel hide")
	end
end

---跟随刷新（按住期间数据变化）
---@param data table 效果展示数据（icon/name/desc）
function EffectDetailPanel.Update(data)
	if not data then
		return
	end
	_pendingData = data
	if _panel and _wantVisible then
		render(data)
	end
end

---销毁面板（切控/重生重置；下次按住重新创建）
function EffectDetailPanel.Destroy()
	diag("panel destroy")
	_wantVisible = false
	_pendingData = nil
	_epoch = _epoch + 1
	_retryPending = false
	_renderKey = nil
	if _panel then
		pcall(function()
			_panel:Destroy()
		end)
	end
	_panel = nil
	_children = nil
end

return EffectDetailPanel
