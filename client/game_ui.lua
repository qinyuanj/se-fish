local GameUI = {}
local Players = game:GetService("Players")

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


function GameUI:ApplyText(target, text)
    if not target then return end
    if target.SetText then
        target:SetText(text)
    elseif target.SetButtonText then
        target:SetButtonText(text)
    end
end

function GameUI:ApplyTextColor(target, color)
    if not target or color == nil then return end
    if target.SetTextColor then
        target:SetTextColor(color)
    elseif target.SetButtonTextColor then
        target:SetButtonTextColor(color)
    end
end

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