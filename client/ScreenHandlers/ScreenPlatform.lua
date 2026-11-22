local GameCfg = require('common.GameCfg')
local OwnedUnits = require('common.OwnedUnits')
local REUtil = require('common.REUtil')
local GameUI = require('client.GameUI')
local MainHudLayout = require('client.MainHudLayout')

local ColorBlockImage = 'official://image/11017'

local Panel = { Nodes = {} }

local function cfg()
    return GameCfg.Platform
end

local function notice(msg)
    if _G.LocalMsgNotice then _G.LocalMsgNotice(msg) end
end

local function reasonText(reason)
    return cfg().ReasonText[reason] or cfg().UnavailableText
end

function Panel:Create(kind, parent, name, x, y, w, h, props)
    props = props or {}
    props.Parent = parent
    props.Name = name
    props.Position = Vector2.New(x, y)
    props.Size = Vector2.New(w, h)
    local world = game:GetService('World')
    local ok, node = pcall(world.CreateUnit, world, kind, props)
    if not ok or not node then
        print('[ScreenPlatform] 节点创建失败', name, tostring(node))
        return nil
    end
    if kind == 'EUITextLabel' then
        node.TouchEnabled = false
        node.SwallowTouchEnabled = false
    end
    self.Nodes[name] = node
    return OwnedUnits.Track(self, node)
end

function Panel:Clear()
    OwnedUnits.Clear(self)
    self.Nodes = {}
    self.Offers = nil
    self.OfferMode = nil
    self.OfferUnit = nil
    self.Flow = nil
end

function Panel:Button(parent, name, x, y, w, h, text, onClick)
    local button = self:Create('EUIButton', parent, name, x, y, w, h, {
        ButtonText = '', NormalImage = ColorBlockImage, PressImage = ColorBlockImage,
        ButtonNormalColor = Color.New(54, 100, 140, 255) })
    if not button then return nil end
    button.TouchEnabled = true
    self:Create('EUITextLabel', button, name .. 'Text', 0, 0, w, h, {
        Text = text, FontSize = 26, TextColor = Color.New(255, 255, 255, 255), LocalZOrder = 1 })
    if button.OnClicked then button.OnClicked:Connect(onClick) end
    return button
end

function Panel:SetVisible(name, visible)
    local node = self.Nodes[name]
    if node then pcall(function() node.Visible = visible end) end
end

function Panel:BuildNodes()
    local root = GameUI:GetUIRoot()
    if not root then return false end
    self:Clear()
    local resolution = GameUI:GetEuiManager():GetDeviceResolution() or { x = 1920, y = 1080 }
    local cx, cy = resolution.x / 2, resolution.y / 2
    local entry = MainHudLayout.Compute({ width = resolution.x, height = resolution.y }).Rects.ShopEntry
    local button = self:Button(root, 'BtnMapShopEntry', entry.x, entry.y, entry.w, entry.h,
        '', function() self:OpenFromHud() end)
    if button then
        local label = self:Create('EUITextLabel', root, 'BtnMapShopEntryText', entry.x, entry.y, entry.w, entry.h, {
            Text = '地图商店', FontSize = 26, TextColor = Color.New(255, 255, 255, 255), LocalZOrder = 1 })
        if label then
            label.TextHorizontalAlignment = 1
            label.TextVerticalAlignment = 1
        end
    end
    local offers = self:Create('EUIImage', root, 'PlatformOffers', cx - 300, cy + 120, 600, 220, {
        Image = ColorBlockImage, Color = Color.New(0, 0, 0, 180), Visible = false })
    if offers then
        self:Create('EUITextLabel', offers, 'PlatformOffersTitle', 0, -80, 600, 50, {
            Text = cfg().OfferTitle, FontSize = 30, TextColor = Color.New(255, 255, 255, 255) })
        for index = 1, 2 do
            self:Button(offers, 'BtnPlatformOffer' .. index, -150 + (index - 1) * 300, 0, 260, 80, '',
                function() self:Buy(index) end)
        end
        self:Button(offers, 'BtnPlatformOffersClose', 0, 80, 200, 50, '关闭',
            function() self:SetVisible('PlatformOffers', false) end)
    end
    local placeholder = self:Create('EUIImage', root, 'PlatformPlaceholder', cx - 300, cy - 320, 600, 260, {
        Image = ColorBlockImage, Color = Color.New(0, 0, 0, 210), Visible = false })
    if placeholder then
        self:Create('EUITextLabel', placeholder, 'PlatformPlaceholderTitle', 0, -90, 600, 50, {
            Text = cfg().Placeholder.Label, FontSize = 28, TextColor = Color.New(255, 255, 255, 255) })
        self:Create('EUITextLabel', placeholder, 'PlatformPlaceholderNotice', 0, -35, 580, 40, {
            Text = cfg().Placeholder.Notice, FontSize = 20, TextColor = Color.New(255, 200, 200, 255) })
        self:Button(placeholder, 'BtnPlatformPlaceholderConfirm', -160, 40, 260, 80, '确认支付',
            function() self:ConfirmFlow('success') end)
        self:Button(placeholder, 'BtnPlatformPlaceholderCancel', 160, 40, 260, 80, '取消',
            function() self:ConfirmFlow('cancel') end)
    end
    local driver = self:Create('EUIImage', root, 'PlatformTestDriver', resolution.x - 360, 260, 340, 200, {
        Image = ColorBlockImage, Color = Color.New(80, 0, 0, 180), Visible = false })
    if driver then
        self:Create('EUITextLabel', driver, 'PlatformTestDriverTitle', 0, -70, 340, 50, {
            Text = cfg().TestDriverTitle, FontSize = 22, TextColor = Color.New(255, 220, 220, 255) })
        local outcomes = { { 'success', '成功' }, { 'cancel', '取消' }, { 'fail', '失败' } }
        for index, entry in ipairs(outcomes) do
            self:Button(driver, 'BtnPlatformTest_' .. entry[1], -110 + (index - 1) * 110, 10, 100, 60, entry[2],
                function() self:Drive(entry[1]) end)
        end
    end
    return true
end

function Panel:ShowOffers(offers, mode, unit)
    self.Offers = type(offers) == 'table' and offers or {}
    self.OfferMode = mode or 'goods'
    self.OfferUnit = unit
    for index = 1, 2 do
        local offer = self.Offers[index]
        self:SetVisible('BtnPlatformOffer' .. index, offer ~= nil)
        local label = self.Nodes['BtnPlatformOffer' .. index .. 'Text']
        if offer and label then
            pcall(function()
                if self.OfferMode == 'coin' then
                    label.Text = string.format('%s（%d%s → %d%s）', offer.name or offer.key,
                        offer.price or 0, unit or '', offer.coin or 0, cfg().BeanCurrency)
                else
                    label.Text = string.format('%s（%d%s）', offer.name or offer.key, offer.beans or 0,
                        cfg().BeanCurrency)
                end
            end)
        end
    end
    self:SetVisible('PlatformOffers', true)
end

function Panel:Buy(index)
    local offer = self.Offers and self.Offers[index]
    if not offer then return false end
    self:SetVisible('PlatformOffers', false)
    local action = self.OfferMode == 'coin' and 'BuyCoin' or 'Purchase'
    REUtil:GetRE('PlatformAction'):FireServer({ action = action, goods = offer.key })
    return true
end

function Panel:ShowPlaceholder(payload)
    local open = payload.open == true
    self.Flow = open and payload or nil
    local title = self.Nodes.PlatformPlaceholderTitle
    if title then
        local name = payload.name or payload.key or ''
        local text
        local label = payload.kind == 'ad'
            and (cfg().Placeholder.AdsLabel or cfg().Placeholder.Label) or cfg().Placeholder.Label
        if payload.kind == 'coin' then
            text = string.format('%s：%s %d%s → %d%s', label, name,
                payload.price or 0, payload.currency or '', payload.coin or 0, cfg().BeanCurrency)
        elseif payload.beans then
            text = string.format('%s：%s %d%s', label, name, payload.beans,
                cfg().BeanCurrency)
        else
            text = string.format('%s：%s', label, name)
        end
        pcall(function() title.Text = text end)
    end
    local label = self.Nodes.PlatformPlaceholderNotice
    if label then
        pcall(function() label.Text = payload.notice or cfg().Placeholder.Notice end)
    end
    self:SetVisible('PlatformPlaceholder', open)
end

function Panel:ConfirmFlow(outcome)
    if not self.Flow then return false end
    self.Flow = nil
    self:SetVisible('PlatformPlaceholder', false)
    REUtil:GetRE('PlatformAction'):FireServer({ action = 'PlaceholderOutcome', outcome = outcome })
    return true
end

function Panel:Drive(outcome)
    REUtil:GetRE('PlatformTestAction'):FireServer({ action = 'ResolveFlow', outcome = outcome })
end

function Panel:Open()
    REUtil:GetRE('PlatformAction'):FireServer({ action = 'OpenCoinShop' })
end

function Panel:OpenFromHud()
    local texts = require('client.LocalShop').ShopText
    local platform = rawget(_G, 'PlatformShop')
    if type(platform) ~= 'table' or type(platform.Open) ~= 'function' then
        notice(texts.PlatformUnavailable)
        return false
    end
    local ok, err = pcall(function() platform:Open() end)
    if not ok then
        print('[ScreenPlatform] 打开地图商店失败', tostring(err))
        notice(texts.PlatformOpenFailed)
        return false
    end
    return true
end

function Panel:NoteResult(result)
    if type(result) ~= 'table' then return end
    local action = result.action
    if action == 'TestFlow' then
        self:SetVisible('PlatformTestDriver', result.open == true)
        local title = self.Nodes.PlatformTestDriverTitle
        if title then
            pcall(function()
                title.Text = cfg().TestDriverTitle .. (result.open and ('：' .. tostring(result.key)) or '')
            end)
        end
    elseif action == 'PlaceholderFlow' then
        self:ShowPlaceholder(result)
    elseif action == 'CoinShop' then
        if result.ok then
            self:ShowOffers(result.offers, 'coin', result.currency)
        else
            notice(reasonText(result.reason))
        end
    elseif action == 'CoinGrant' and result.ok then
        notice(string.format(cfg().Placeholder.CoinGrantText, result.coin or 0, cfg().BeanCurrency,
            tostring(result.name or result.goods)))
    elseif action == 'AdrenalineShop' then
        if result.ok then self:ShowOffers(result.offers) else notice(cfg().UnavailableText) end
    elseif action == 'Grant' and result.ok then
        local row = cfg().Goods[result.goods]
        local text = string.format('获得 %s', row and row.name or tostring(result.goods))
        if (result.overflow or 0) > 0 then
            text = text .. string.format('，背包已满：%d 件落在面前地上', result.overflow)
        end
        notice(text)
    elseif not result.ok then
        notice(reasonText(result.reason))
    end
end

function Panel:Start()
    _G.PlatformShop = self
    REUtil:GetRE('PlatformResult').OnClientEvent:Connect(function(result) self:NoteResult(result) end)
    local task = game:GetService('Task')
    task:Spawn(function()
        for _ = 1, 50 do
            if self:BuildNodes() then return end
            task:Wait(0.2)
        end
        print('[ScreenPlatform] UIRoot 未就绪，平台购买面板不可用')
    end)
end

return Panel
