local MgrGameUI = {}
local StarterGui = game:GetService("StarterGui")
local GameUI = require("client.GameUI")
local REUtil = require("common.REUtil")
local OpenScreenRE = REUtil:GetRE("OpenScreenRE")
local CloseScreenRE = REUtil:GetRE("CloseScreenRE")
local curShowMap = {}

local ScreenHandlerLoaders = {
    ScreenCompendium = function() return require("client.ScreenHandlers.ScreenCompendium") end,
    ScreenGM = function() return require("client.ScreenHandlers.ScreenGM") end,
    ScreenMain = function() return require("client.ScreenHandlers.ScreenMain") end,
    ScreenMsg = function() return require("client.ScreenHandlers.ScreenMsg") end,
}

function MgrGameUI:GetScreen(screenName)
    local UIRoot = GameUI:GetUIRoot()
    if not UIRoot then
        print("[MgrGameUI] GetScreen() no UIRoot now!")
        return 
    end
    
    local screenNode = UIRoot:FindFirstChild(screenName)
     if not screenNode then
        print("[MgrGameUI] 找不到界面节点", screenName)
        return
    end
    local loadHandler = ScreenHandlerLoaders[screenName]
    if not loadHandler then
        error("[MgrGameUI] 界面 handler 未登记: " .. tostring(screenName), 2)
    end
    local screenHandler = loadHandler()

    screenHandler.ScreenName = screenName
    screenHandler.RootNode = screenNode
    if (not screenHandler.Inited or screenHandler.BoundRootNode and screenHandler.BoundRootNode ~= screenNode)
        and screenHandler.UINodes and screenHandler.UINodeMap then
        for k, v in pairs(screenHandler.UINodes) do
            local uiNode = screenNode:FindFirstChild(v, true)
            if uiNode then
                screenHandler.UINodeMap[v] = uiNode
            else
                print("[MgrGameUI] 找不到界面子节点", screenName, v)
            end
        end
        screenHandler:Init()
    end

    return screenHandler
end 

function MgrGameUI:OpenScreen(screenName, passBy, useAnim)
    local screenHandler = MgrGameUI:GetScreen(screenName)
    if not screenHandler then return end

    local root = screenHandler.RootNode
    local animationGeneration = (screenHandler.AnimationGeneration or 0) + 1
    screenHandler.AnimationGeneration = animationGeneration
    screenHandler.AnimOpen = nil
    screenHandler.AnimClosing = nil
    if not root.Visible then
        if useAnim then
            root.Opacity = 0
            root.Visible = true
            local duration = 0.5
            screenHandler.AnimOpen = true
            root:TweenOpacity(1, Enums.EasingDirection.Out, Enums.EasingStyle.Quad, duration, true, function()
                if screenHandler.RootNode ~= root
                    or screenHandler.AnimationGeneration ~= animationGeneration then return end
                screenHandler.AnimOpen = nil
                root.Opacity = 1
            end)

        else
            root.Opacity = 1
            root.Visible = true
        end
    end

    curShowMap[screenName] = true
    if screenHandler.OpenScreen then
        screenHandler:OpenScreen(passBy)
    end
end

function MgrGameUI:CloseScreen(screenName, useAnim)
    local screenHandler = MgrGameUI:GetScreen(screenName)
    if not screenHandler then return end

    local root = screenHandler.RootNode
    local animationGeneration = (screenHandler.AnimationGeneration or 0) + 1
    screenHandler.AnimationGeneration = animationGeneration
    screenHandler.AnimOpen = nil
    screenHandler.AnimClosing = nil
    if root.Visible then
        if useAnim then
            root.Opacity = 1
            local duration = 0.5
            screenHandler.AnimClosing = true
            root:TweenOpacity(0, Enums.EasingDirection.Out, Enums.EasingStyle.Quad, duration, true, function()
                if screenHandler.RootNode ~= root
                    or screenHandler.AnimationGeneration ~= animationGeneration then return end
                root.Visible = false
                screenHandler.AnimClosing = false
            end)
        else
            root.Visible = false
        end
    end

    curShowMap[screenName] = nil
    if screenHandler.CloseScreen then
        screenHandler:CloseScreen()
    end
end

OpenScreenRE.OnClientEvent:Connect(function(screenName, passBy, useAnim) 
    MgrGameUI:OpenScreen(screenName, passBy, useAnim)
end)

CloseScreenRE.OnClientEvent:Connect(function(screenName, useAnim)
    MgrGameUI:CloseScreen(screenName, useAnim)
end)

function MgrGameUI:IsScreenOpen(screenName)
    local screenHandler = MgrGameUI:GetScreen(screenName)
    if not screenHandler then return end
   return screenHandler.RootNode.Visible
end

function MgrGameUI:IsAnyScreenOpen(exceptLst)
    local exceptMap = {}
    for _, screenName in pairs(exceptLst) do
        exceptMap[screenName] = true
    end
    local showLst = {}
    for screenName,show in pairs(curShowMap) do
        if not exceptMap[screenName] and show then
            table.insert(showLst, screenName)
        end
    end
    return showLst
end

local AllCustomUINodeMap = {}
function MgrGameUI:SetCustomControlUI(uiNode, value)
    AllCustomUINodeMap[uiNode] = value
end

function MgrGameUI:HideLiftButton()
    pcall(function() StarterGui:SetCoreGuiEnabled(Enums.CoreGuiType.LiftButton, false) end)
end

function MgrGameUI:HideNativeHealth()
    pcall(function() StarterGui:SetCoreGuiEnabled(Enums.CoreGuiType.Health, false) end)
end

function MgrGameUI:SetControlUI(visible)
    StarterGui:SetCoreGuiEnabled(Enums.CoreGuiType.All, visible)
    self:HideLiftButton()
    self:HideNativeHealth()
    for k, v in pairs(AllCustomUINodeMap) do
        k.Visible = visible
    end
end

function MgrGameUI:StartGM()
    local GameCfg = require('common.GameCfg')
    if not (GameCfg.Debug and GameCfg.Debug.Enabled) then return end
    local handler = require('client.ScreenHandlers.ScreenGM')
    if handler then handler:Start() end
end

_G.MgrGameUI = MgrGameUI
return MgrGameUI