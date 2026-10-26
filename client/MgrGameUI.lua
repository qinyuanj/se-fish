local MgrGameUI = {}
local StarterGui = game:GetService("StarterGui")
local GameUI = require("client.GameUI")
local REUtil = require("common.REUtil")
local OpenScreenRE = REUtil:GetRE("OpenScreenRE")
local CloseScreenRE = REUtil:GetRE("CloseScreenRE")
local curShowMap = {}

-- 界面 handler 登记表：键是 EUI 节点名（与 ScreenHandlers/ 下文件同名），值按需加载 handler。
-- 用字面量 require 而非拼路径，依赖才能被静态解析；新增 handler 须在此登记。
local ScreenHandlerLoaders = {
    DialogNoticeConfirm = function() return require("client.ScreenHandlers.DialogNoticeConfirm") end,
    ScreenBlindbox = function() return require("client.ScreenHandlers.ScreenBlindbox") end,
    ScreenCompendium = function() return require("client.ScreenHandlers.ScreenCompendium") end,
    ScreenFerry = function() return require("client.ScreenHandlers.ScreenFerry") end,
    ScreenGM = function() return require("client.ScreenHandlers.ScreenGM") end,
    ScreenGrill = function() return require("client.ScreenHandlers.ScreenGrill") end,
    ScreenLottery = function() return require("client.ScreenHandlers.ScreenLottery") end,
    ScreenMain = function() return require("client.ScreenHandlers.ScreenMain") end,
    ScreenMsg = function() return require("client.ScreenHandlers.ScreenMsg") end,
    ScreenPlatform = function() return require("client.ScreenHandlers.ScreenPlatform") end,
    ScreenShop = function() return require("client.ScreenHandlers.ScreenShop") end,
    ScreenSurvival = function() return require("client.ScreenHandlers.ScreenSurvival") end,
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
        print("[MgrGameUI] 界面 handler 未登记", screenName)
        return
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

    if not screenHandler.RootNode.Visible then
      
        if useAnim then
            screenHandler.RootNode.Opacity = 0
            screenHandler.RootNode.Visible = true
            local duration = 0.5
            screenHandler.AnimOpen = true
            screenHandler.RootNode:TweenOpacity(1, Enums.EasingDirection.Out, Enums.EasingStyle.Quad, duration, true, function()
                screenHandler.AnimOpen = nil
                screenHandler.RootNode.Opacity = 1
            end)

        else
            screenHandler.RootNode.Opacity = 1
            screenHandler.RootNode.Visible = true
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

    if screenHandler.RootNode.Visible then
        if useAnim then
            screenHandler.RootNode.Opacity = 1
            local duration = 0.5
            screenHandler.AnimClosing = true
            screenHandler.RootNode:TweenOpacity(0, Enums.EasingDirection.Out, Enums.EasingStyle.Quad, true, function()
                screenHandler.RootNode.Visible = false 
                screenHandler.AnimClosing = false
            end)
        end
        screenHandler.RootNode.Visible = false
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

-- 原生血条与 ScreenMain 自绘血球重复（#53），关掉；SetCoreGuiEnabled(All) 会把它重新打开，之后要再关一次
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