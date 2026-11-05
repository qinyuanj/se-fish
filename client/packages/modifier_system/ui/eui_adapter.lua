--效果系统包 - 客户端EUI节点操作适配层
--封装 EUI 节点的可见性/文本/图片/百分比/位置/锚点/层级/触摸等读写与节点树查找，
--方法调用 pcall 包裹 + 属性直写兜底；setter 返回是否写入成功（供调用方决定是否重试，非强契约）。

local EuiAdapter = {}

local function hasMethod(node, methodName)
	return node ~= nil and type(node[methodName]) == "function"
end

-- 节点属性读写（返回值：是否写入成功）

function EuiAdapter.SetVisible(node, visible)
	if not node then
		return false
	end
	if hasMethod(node, "SetVisible") then
		local ok = pcall(function()
			node:SetVisible(visible)
		end)
		if ok then
			return true
		end
	end
	local ok = pcall(function()
		node.Visible = visible
	end)
	return ok
end

function EuiAdapter.SetImage(node, image)
	if not node or image == nil then
		return false
	end
	if hasMethod(node, "SetImage") then
		local ok = pcall(function()
			node:SetImage(image)
		end)
		if ok then
			return true
		end
	end
	local ok = pcall(function()
		node.Image = image
	end)
	return ok
end

function EuiAdapter.SetText(node, text)
	if not node then
		return false
	end
	if hasMethod(node, "SetText") then
		local ok = pcall(function()
			node:SetText(text)
		end)
		if ok then
			return true
		end
	end
	local ok = pcall(function()
		node.Text = text
	end)
	return ok
end

function EuiAdapter.SetPercent(node, percent)
	if not node then
		return false
	end
	if hasMethod(node, "SetPercent") then
		local ok = pcall(function()
			node:SetPercent(percent)
		end)
		if ok then
			return true
		end
	end
	local ok = pcall(function()
		node.Percent = percent
	end)
	return ok
end

function EuiAdapter.SetPosition(node, pos)
	if not node or pos == nil then
		return false
	end
	if hasMethod(node, "SetPosition") then
		local ok = pcall(function()
			node:SetPosition(pos)
		end)
		if ok then
			return true
		end
	end
	local ok = pcall(function()
		node.Position = pos
	end)
	return ok
end

function EuiAdapter.SetAnchor(node, anchor)
	if not node or anchor == nil then
		return false
	end
	if hasMethod(node, "SetAnchor") then
		local ok = pcall(function()
			node:SetAnchor(anchor)
		end)
		if ok then
			return true
		end
	end
	local ok = pcall(function()
		node.Anchor = anchor
	end)
	return ok
end

function EuiAdapter.SetZOrder(node, zOrder)
	if not node then
		return false
	end
	if hasMethod(node, "SetZOrder") then
		local ok = pcall(function()
			node:SetZOrder(zOrder)
		end)
		if ok then
			return true
		end
	end
	local ok = pcall(function()
		node.LocalZOrder = zOrder
	end)
	return ok
end

function EuiAdapter.SetTouchEnabled(node, enabled)
	if not node then
		return false
	end
	if hasMethod(node, "SetTouchEnabled") then
		local ok = pcall(function()
			node:SetTouchEnabled(enabled)
		end)
		if ok then
			return true
		end
	end
	local ok = pcall(function()
		node.TouchEnabled = enabled
	end)
	return ok
end

-- 节点树查找

function EuiAdapter.FindFirstChild(node, name, recursive)
	if not node then
		return nil
	end
	if hasMethod(node, "FindFirstChild") then
		local ok, result = pcall(function()
			return node:FindFirstChild(name, recursive)
		end)
		if ok and result then
			return result
		end
	end
	if hasMethod(node, "GetChildByName") then
		local ok, result = pcall(function()
			return node:GetChildByName(name)
		end)
		if ok and result then
			return result
		end
	end
	if hasMethod(node, "GetChildren") then
		local ok, children = pcall(function()
			return node:GetChildren()
		end)
		if ok and children then
			for _, child in ipairs(children) do
				local okName, childName = pcall(function()
					return child.Name
				end)
				if okName and childName == name then
					return child
				end
				if recursive then
					local sub = EuiAdapter.FindFirstChild(child, name, recursive)
					if sub then
						return sub
					end
				end
			end
		end
	end
	return nil
end

function EuiAdapter.GetDescendants(node)
	local result = {}
	if not node then
		return result
	end
	if hasMethod(node, "GetDescendants") then
		local ok, descendants = pcall(function()
			return node:GetDescendants()
		end)
		if ok and descendants then
			return descendants
		end
	end
	if hasMethod(node, "GetChildren") then
		local function walk(current)
			local ok, children = pcall(function()
				return current:GetChildren()
			end)
			if not ok or not children then
				return
			end
			for _, child in ipairs(children) do
				table.insert(result, child)
				walk(child)
			end
		end
		walk(node)
	end
	return result
end

function EuiAdapter.GetSize(node)
	if not node then
		return nil
	end
	if hasMethod(node, "GetSize") then
		local ok, size = pcall(function()
			return node:GetSize()
		end)
		if ok and size then
			return size
		end
	end
	local ok, size = pcall(function()
		return node.Size
	end)
	if ok and size ~= nil then
		return size
	end
	return nil
end

-- EuiManager 与根节点

-- 获取本地玩家的 EuiManager
function EuiAdapter.GetEuiManager()
	local player = game:GetService("Players").LocalPlayer
	if not player then
		return nil
	end
	local ok, playerGui = pcall(function()
		return player.PlayerGui
	end)
	if not ok or not playerGui then
		return nil
	end
	local okManager, euiManager = pcall(function()
		return playerGui.EuiManager
	end)
	if not okManager then
		return nil
	end
	return euiManager
end

-- 获取 UI 根节点（EUIRootNode）
function EuiAdapter.GetRootNode()
	local euiManager = EuiAdapter.GetEuiManager()
	if not euiManager or not hasMethod(euiManager, "GetRootNode") then
		return nil
	end
	local ok, root = pcall(function()
		return euiManager:GetRootNode()
	end)
	return ok and root or nil
end

return EuiAdapter
