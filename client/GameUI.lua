local GameUI = {}
local Players = game:GetService("Players")

--- 获取本地玩家的 EuiManager
function GameUI:GetEuiManager()
    local lp = Players.LocalPlayer
    if not lp then return nil end
    return lp.PlayerGui.EuiManager
end

function GameUI:GetUIRoot()
    local euiMgr = self:GetEuiManager()
    if not euiMgr then return end

    return euiMgr:GetRootNode()
end

-- 在节点子树中递归查找指定名字的子节点
---@param node any
---@param name string
---@return any|nil
function GameUI:FindChildUINode(node, name)
    if not node or not name then return nil end
    if not node.GetChildren then return nil end
    local children = node:GetChildren()
    if not children then return nil end
    for _, child in ipairs(children) do
        if child and child.Name == name then
            return child
        end
        local nested = GameUI:FindLabelChild(child, name)
        if nested then return nested end
    end
    return nil
end


--- 文本写入抽象：兼容 EUIButton 内置文字与独立 EUITextLabel 两种节点
---@param target any UI 节点
---@param text string
function GameUI:ApplyText(target, text)
    if not target then return end
    if target.SetText then
        target:SetText(text)
    elseif target.SetButtonText then
        target:SetButtonText(text)
    end
end

--- 文本颜色写入抽象：兼容两种节点
---@param target any
---@param color any
function GameUI:ApplyTextColor(target, color)
    if not target or color == nil then return end
    if target.SetTextColor then
        target:SetTextColor(color)
    elseif target.SetButtonTextColor then
        target:SetButtonTextColor(color)
    end
end

--- 文本颜色读取抽象：兼容两种节点；返回 nil 表示无可读取来源
---@param target any
---@return any|nil
function GameUI:ReadTextColor(target)
    if not target then return nil end
    if target.GetTextColor then
        return target:GetTextColor()
    elseif target.GetButtonTextColor then
        return target:GetButtonTextColor()
    end
    return nil
end

function GameUI:CreateSceneNode(prefabKey, attachUnit, Offset)
    local eui = self:GetEuiManager()
    local Socket = "AttachPoint"

    if not Offset then Offset = Vector3(0, 5, 0) end

    local InheritVisible = true
    local sceneNode = eui:CreateSceneUIByPrefabKeyAttachUnit(prefabKey, attachUnit, Socket, Offset, InheritVisible) 
    return sceneNode
end

_G.GameUI = GameUI

return GameUI