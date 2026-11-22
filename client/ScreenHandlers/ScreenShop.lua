local GameCfg = require('common.GameCfg')
local OwnedUnits = require('common.OwnedUnits')
local LocalShop = require('client.LocalShop')

local TabNames = GameCfg.Shop.Pages
local CoinPage = TabNames[#TabNames]

local Text, FailText = LocalShop.ShopText, LocalShop.FailText

local function color(spec) return Color.New(spec[1], spec[2], spec[3], spec[4]) end

local Skin

local function rowTextColor(row)
    if row.selected then return Skin.Color.TextSelected end
    if not row.purchasable then return Skin.Color.TextDisabled end
    if row.isNew then return Skin.Color.TextNew end
    return Skin.Color.TextOnPaper
end

local function rowBaseColor(row)
    if row.selected then return Skin.Color.RowSelected end
    if not row.purchasable then return Skin.Color.RowDisabled end
    return Skin.Color.Row
end

local function writeText(node, text, tone)
    node.Text, node.TextColor = text or '', color(tone)
end

local function createChildNode(world, kind, attrs)
    return world:CreateUnit(kind, attrs)
end

do
    local Image = {
        Panel = 'official://image/11017',
        Primary = 'official://image/10066',
        Coin = 'official://image/16878',
    }
    local Font = { Row = 28, RowSmall = 20, Price = 26 }
    local Palette = {
        Text = { 232, 225, 207, 255 },
        TextMuted = { 157, 171, 151, 255 },
        TextOnPaper = { 41, 56, 47, 255 },
        TextSelected = { 240, 231, 208, 255 },
        TextOnActive = { 41, 56, 47, 255 },
        TextNew = { 128, 83, 26, 255 },
        TextDisabled = { 57, 65, 54, 255 },
        Button = { 255, 255, 255, 255 },
        ButtonPress = { 224, 224, 224, 255 },
        ButtonDisable = { 74, 86, 74, 255 },
        ButtonGuide = { 62, 112, 91, 255 },
        Row = { 229, 220, 194, 255 },
        RowSelected = { 62, 112, 91, 255 },
        RowDisabled = { 174, 170, 148, 255 },
        Brass = { 214, 168, 62, 255 },
    }
    local Children = {
        { Name = 'ShopRowBackground', Kind = 'EUIImage', X = 330, Y = 44, Width = 660, Height = 88, Z = 0,
            Create = { Image = Image.Panel, Color = color(Palette.Row) },
            Paint = function(node, row) node.Color = color(rowBaseColor(row)) end },
        { Name = 'ShopRowIcon', Kind = 'EUIImage', X = 48, Y = 44, Width = 56, Height = 56,
            Create = { Image = Image.Coin },
            Paint = function(node, row)
                node.Visible = row.icon ~= nil and row.icon ~= ''
                if row.icon then node.Image = row.icon end
            end },
        { Name = 'ShopRowNew', Kind = 'EUITextLabel', X = 132, Y = 20, Width = 80, Height = 24,
            Create = { Text = '', FontSize = Font.RowSmall, TextColor = color(Palette.TextNew),
                TextHorizontalAlignment = 0, TextVerticalAlignment = 1 },
            Paint = function(node, row) writeText(node, row.newText, rowTextColor(row)) end },
        { Name = 'ShopRowName', Kind = 'EUITextLabel', X = 262, Y = 56, Width = 340, Height = 40,
            Create = { Text = '', FontSize = Font.Row, TextColor = color(Palette.TextOnPaper),
                TextHorizontalAlignment = 0, TextVerticalAlignment = 1 },
            Paint = function(node, row) writeText(node, row.name, rowTextColor(row)) end },
        { Name = 'ShopRowCoin', Kind = 'EUIImage', X = 498, Y = 56, Width = 28, Height = 28,
            Create = { Image = Image.Coin } },
        { Name = 'ShopRowPrice', Kind = 'EUITextLabel', X = 580, Y = 56, Width = 120, Height = 40,
            Create = { Text = '', FontSize = Font.Price, TextColor = color(Palette.TextOnPaper),
                TextHorizontalAlignment = 2, TextVerticalAlignment = 1 },
            Paint = function(node, row) writeText(node, row.priceText, rowTextColor(row)) end },
        { Name = 'ShopRowState', Kind = 'EUITextLabel', X = 480, Y = 20, Width = 300, Height = 24,
            Create = { Text = '', FontSize = Font.RowSmall, TextColor = color(Palette.TextDisabled),
                TextHorizontalAlignment = 2, TextVerticalAlignment = 1 },
            Paint = function(node, row) writeText(node, row.stateText, rowTextColor(row)) end },
    }
    Skin = {
        Image = Image, Font = Font, Color = Palette,
        Row = { Width = 660, Height = 88, Margin = 4, Children = Children },
    }
end

local function styleButton(button)
    if not button then return end
    button.ButtonNormalColor = color(Skin.Color.Button)
    button.ButtonPressColor = color(Skin.Color.ButtonPress)
    button.ButtonDisableColor = color(Skin.Color.ButtonDisable)
end

local function limitText(goods, bought)
    local limit = goods.PurchaseLimit or 0
    if limit <= 0 then return Text.NoLimit end
    return string.format(Text.LimitText, bought, limit)
end

local function upgradeText(goods, current)
    local upgrade = goods.Upgrade
    if not upgrade then return '' end
    if current >= upgrade.level then return string.format(Text.UpgradeOwned, current) end
    return string.format(Text.UpgradeTarget, current, upgrade.level)
end

local function standLevel()
    return (LocalShop.Stand and LocalShop.Stand.Level) or GameCfg.Shop.Stands[1].Level
end

local ScreenHandler = {
    UINodes = { 'BtnShopClose', 'LabelShopClose', 'LabelCurCoin', 'ShopListPanel', 'ShopList', 'ShopCoinPanel',
        'LabelCoinPageHint', 'BtnOpenPlatformShop', 'LabelOpenPlatformShop',
        'ShopDetailPanel', 'ImageShopDetailIcon', 'ImageShopDetailCoin', 'LabelShopDetailName',
        'LabelShopDetailDesc', 'LabelShopDetailPrice', 'LabelShopDetailLimit', 'LabelShopDetailUpgrade',
        'BtnShopBuyDetail', 'LabelShopBuyDetail' },
    UINodeMap = {}, Connections = {}, Seq = 0,
    Page = TabNames[1], Selected = nil, Purchases = {}, UpgradeLevels = {}, UpgradeLevel = 0,
    RowCount = 0, Coin = 0, CoinState = 'idle', CoinHintText = nil,
}

for index = 1, #TabNames do
    ScreenHandler.UINodes[#ScreenHandler.UINodes + 1] = 'BtnShopPage' .. index
    ScreenHandler.UINodes[#ScreenHandler.UINodes + 1] = 'LabelShopPage' .. index
end

function ScreenHandler:CurrentUpgradeLevel(kind)
    if kind == 'backpack' then return self.UpgradeLevel or 0 end
    return self.UpgradeLevels[kind] or 0
end

function ScreenHandler:RowState(goods, level, upgradeLevel)
    if goods.MinShopLevel > level then
        return 'locked', 'stand', string.format(Text.StandLocked, goods.MinShopLevel)
    end
    if goods.Upgrade then
        local current = upgradeLevel or 0
        if goods.Upgrade.level <= current then return 'owned', 'level', Text.Owned end
        if goods.Upgrade.level > current + 1 then return 'locked', 'level', FailText.level end
    end
    if (goods.PurchaseLimit or 0) > 0 and (self.Purchases[goods.Number] or 0) >= goods.PurchaseLimit then
        return 'owned', 'limit', Text.Owned
    end
    return 'buy', nil, ''
end

function ScreenHandler:BuildRow(index, goods, level)
    local upgradeLevel = goods.Upgrade and self:CurrentUpgradeLevel(goods.Upgrade.kind) or nil
    local state, reason, stateText = self:RowState(goods, level, upgradeLevel)
    local definition = goods.ItemId and GameCfg.Items.Definitions[goods.ItemId] or nil
    local isNew = goods.MinShopLevel == level
    return {
        index = index, number = goods.Number, goods = goods,
        name = goods.Name, priceText = tostring(goods.Price),
        state = state, reason = reason, stateText = stateText, upgradeLevel = upgradeLevel,
        isNew = isNew, newText = isNew and Text.New or '',
        icon = definition and definition.Icon or nil,
        selectable = state ~= 'owned',
        purchasable = state == 'buy',
        selected = index == self.Selected,
    }
end

function ScreenHandler:BuildDetail(row, coin)
    if not row then
        return { number = nil, name = '', desc = '', icon = nil, priceText = '', limitText = '',
            upgradeText = '', buyText = Text.Buy, buyAction = nil, buyEnabled = false }
    end
    local goods = row.goods
    local action
    if row.purchasable then action = coin >= (goods.Price or 0) and 'buy' or 'coin' end
    local buyText = Text.Buy
    if action == 'coin' then
        buyText = Text.GoPlatformShop
    elseif not action then
        buyText = row.stateText
    end
    return {
        number = row.number, name = row.name, desc = goods.Desc or '', icon = row.icon,
        priceText = row.priceText,
        limitText = limitText(goods, self.Purchases[row.number] or 0),
        upgradeText = upgradeText(goods, row.upgradeLevel or 0),
        buyText = buyText, buyAction = action, buyEnabled = action ~= nil,
    }
end

function ScreenHandler:Model()
    local coinPage = self.Page == CoinPage
    local level = standLevel()
    local rows = {}
    if not coinPage then
        for index, goods in ipairs(GameCfg.Shop.ListForPage(level, self.Page, true)) do
            rows[index] = self:BuildRow(index, goods, level)
        end
    end
    local coin = self.Coin or 0
    local selected = rows[self.Selected or 0] and self.Selected or nil
    return {
        page = self.Page,
        tabs = TabNames,
        selected = selected,
        rows = rows,
        detail = self:BuildDetail(rows[selected or 0], coin),
        coinText = tostring(coin),
        coinHint = self.CoinHintText,
        coinState = self.CoinState,
        panels = { list = not coinPage, coin = coinPage, detail = not coinPage },
    }
end

function ScreenHandler:View() return self:Model() end

function ScreenHandler:Apply(model)
    local nodes = self.UINodeMap
    local listPanel, coinPanel, detailPanel = nodes.ShopListPanel, nodes.ShopCoinPanel, nodes.ShopDetailPanel
    if listPanel then listPanel.Visible = model.panels.list end
    if coinPanel then coinPanel.Visible = model.panels.coin end
    if detailPanel then detailPanel.Visible = model.panels.detail end
    for index, name in ipairs(TabNames) do
        local selected = name == model.page
        local label = nodes['LabelShopPage' .. index]
        if label then label.TextColor = color(selected and Skin.Color.Brass or Skin.Color.TextMuted) end
        local indicator = nodes['ImageShopTabIndicator' .. index]
        if indicator then indicator.Visible = selected end
    end
    local coinLabel = nodes.LabelCurCoin
    if coinLabel then coinLabel.Text = model.coinText end
    local hintLabel = nodes.LabelCoinPageHint
    if hintLabel then hintLabel.Text = model.coinHint or '' end
    self:RenderRows(model)
    self:RenderDetail(model.detail)
end

function ScreenHandler:Render() self:Apply(self:View()) end

function ScreenHandler:Select(index)
    if index ~= nil then
        local row = self:View().rows[index]
        if not row or not row.selectable then return false end
    end
    self.Selected = index
    self:Render()
    return true
end

function ScreenHandler:SetPage(page)
    local known = false
    for _, name in ipairs(TabNames) do
        if name == page then known = true end
    end
    if not known then return false end
    local changed = self.Page ~= page
    self.Page, self.Selected = page, nil
    if changed and page == CoinPage then self.CoinState, self.CoinHintText = 'idle', Text.CoinPageHint end
    self:Render()
    return true
end

function ScreenHandler:Buy(index)
    if not self.IsOpen then return false end
    local row = index ~= nil and self:View().rows[index] or nil
    if not row then return false end
    if not row.purchasable then
        self:NoteFail(row.reason)
        return false
    end
    self.Seq = self.Seq + 1
    _G.REUtil:GetRE('ShopAction'):FireServer({ action = 'Buy', number = row.number, seq = self.Seq })
    return true
end

function ScreenHandler:ConfirmBuy()
    if self:View().detail.buyAction == 'coin' then return self:SetPage(CoinPage) end
    return self:Buy(self.Selected)
end

function ScreenHandler:NoteFail(reason)
    local text = reason and FailText[reason]
    if text and _G.LocalMsgNotice then _G.LocalMsgNotice(text) end
end

function ScreenHandler:SetCoin(coin) self.Coin = math.floor(coin or 0) end

function ScreenHandler:ShowCoin()
    local player = game:GetService('Players').LocalPlayer
    self:SetCoin(player and tonumber(player:GetAttribute('FishCoin')) or 0)
end

function ScreenHandler:SetCoinHint(state, text)
    self.CoinState, self.CoinHintText = state, text
    self:Render()
end

function ScreenHandler:OpenPlatformShop()
    local platform = rawget(_G, 'PlatformShop')
    if type(platform) ~= 'table' or type(platform.Open) ~= 'function' then
        self:SetCoinHint('unavailable', Text.PlatformUnavailable)
        return false
    end
    local ok, err = pcall(function() platform:Open() end)
    if not ok then
        print('[ScreenShop] 打开地图商店失败', tostring(err))
        self:SetCoinHint('failed', Text.PlatformOpenFailed)
        return false
    end
    self:SetCoinHint('opened', Text.PlatformOpened)
    return true
end

function ScreenHandler:CreateRow(list, index)
    local world = game:GetService('World')
    local ok, row = pcall(world.CreateUnit, world, 'EUIButton', {
        Parent = list, Name = 'ShopRow' .. index,
        Position = Vector2.New(0, 0), Size = Vector2.New(Skin.Row.Width, Skin.Row.Height),
    })
    if not ok or not row then
        print('[ScreenShop] 商品行创建失败', index, tostring(row))
        return nil
    end
    row.NormalImage, row.PressImage, row.DisableImage = '', '', ''
    styleButton(row)
    row.ButtonText = ''
    row.TouchEnabled = true
    for _, child in ipairs(Skin.Row.Children) do
        local attrs = { Parent = row, Name = child.Name .. index,
            Position = Vector2.New(child.X, child.Y), Size = Vector2.New(child.Width, child.Height),
            Anchor = Vector2.New(0.5, 0.5), TouchEnabled = false, SwallowTouchEnabled = false,
            LocalZOrder = child.Z or 1 }
        for key, value in pairs(child.Create) do attrs[key] = value end
        local node = createChildNode(world, child.Kind, attrs)
        if not node then print('[ScreenShop] 商品行子节点创建失败', child.Name, index) end
    end
    OwnedUnits.Track(self, row)
    self.Connections[#self.Connections + 1] = row.OnClicked:Connect(function() self:Select(index) end)
    return row
end

function ScreenHandler:PaintRow(row, model)
    local index = model.index
    for _, child in ipairs(Skin.Row.Children) do
        local node = row:FindFirstChild(child.Name .. index)
        if node and child.Paint then child.Paint(node, model) end
    end
    row.TouchEnabled = model.selectable
    row.Opacity = 1.0
end

function ScreenHandler:RenderRows(model)
    local list = self.UINodeMap.ShopList
    if not list then return end
    local shown = #model.rows
    for index = 1, math.max(shown, self.RowCount or 0) do
        local rowModel = model.rows[index]
        local row = list:FindFirstChild('ShopRow' .. index)
        if rowModel and not row then row = self:CreateRow(list, index) end
        if row then
            row.Visible = rowModel ~= nil
            if rowModel then self:PaintRow(row, rowModel) end
        end
    end
    self.RowCount = shown
end

function ScreenHandler:RenderDetail(model)
    local nodes = self.UINodeMap
    local function setText(name, text)
        local node = nodes[name]
        if node then node.Text = text end
    end
    setText('LabelShopDetailName', model.name)
    setText('LabelShopDetailDesc', model.desc)
    setText('LabelShopDetailPrice', model.priceText)
    setText('LabelShopDetailLimit', model.limitText)
    setText('LabelShopDetailUpgrade', model.upgradeText)
    setText('LabelShopBuyDetail', model.buyText)
    local hasRow = model.number ~= nil
    local icon, coinIcon = nodes.ImageShopDetailIcon, nodes.ImageShopDetailCoin
    if icon then
        icon.Visible = hasRow and model.icon ~= nil and model.icon ~= ''
        if model.icon then icon.Image = model.icon end
    end
    if coinIcon then coinIcon.Visible = hasRow end
    -- #235：Disabled 只换禁用图，不恢复触摸。Init 的空态禁用把它关掉之后没人再打开，
    -- 渲染成可买也就是一块点不动的图。有选中行就重开触摸（不可买时仍要能点出原因）；
    -- 空态没商品可谈，点下去只会静默，保持不可触摸。
    local button = nodes.BtnShopBuyDetail
    if button then
        button.Disabled = not model.buyEnabled
        button.TouchEnabled = hasRow
        local image, tone, labelTone = Skin.Image.Panel, Skin.Color.ButtonDisable, Skin.Color.Text
        if model.buyEnabled and model.buyAction == 'coin' then
            tone = Skin.Color.ButtonGuide
        elseif model.buyEnabled then
            image, tone, labelTone = Skin.Image.Primary, Skin.Color.Button, Skin.Color.TextOnActive
        end
        button.NormalImage = image
        button.ButtonNormalColor = color(tone)
        local label = nodes.LabelShopBuyDetail
        if label then label.TextColor = color(labelTone) end
    end
end

function ScreenHandler:NoteResult(result)
    if type(result) ~= 'table' then return end
    if result.ok then
        if result.number then self.Purchases[result.number] = (self.Purchases[result.number] or 0) + 1 end
        if result.kind and result.level then
            self.UpgradeLevels[result.kind] = math.max(self.UpgradeLevels[result.kind] or 0, result.level)
        end
        if result.action == 'UpgradeStorage' and result.level then self.UpgradeLevel = result.level end
    end
    if not self.IsOpen then return end
    self:ShowCoin()
    if result.ok and type(result.coinAfter) == 'number' then self:SetCoin(result.coinAfter) end
    self:Render()
end

function ScreenHandler:EnsureTabIndicator(index, tab)
    local name = 'ImageShopTabIndicator' .. index
    local node = tab and tab:FindFirstChild(name)
    if not node and tab then
        node = createChildNode(game:GetService('World'), 'EUIImage', {
            Parent = tab, Name = name, Position = Vector2.New(110, 7), Size = Vector2.New(56, 4),
            Anchor = Vector2.New(0.5, 0.5), TouchEnabled = false, SwallowTouchEnabled = false, LocalZOrder = 2,
        })
        if node then
            node.Image = Skin.Image.Panel
            node.Color = color(Skin.Color.Brass)
            OwnedUnits.Track(self, node)
        else
            print('[ScreenShop] 页签下划线创建失败', index)
        end
    end
    self.UINodeMap[name] = node
end

function ScreenHandler:Init()
    if self.Inited and self.BoundRootNode == self.RootNode then return end
    for _, connection in ipairs(self.Connections or {}) do connection:Disconnect() end
    OwnedUnits.Clear(self)
    self.Connections = {}
    self.UINodeMap = {}
    for _, name in ipairs(self.UINodes) do
        local node = self.RootNode and self.RootNode:FindFirstChild(name, true)
        if node then
            self.UINodeMap[name] = node
        else
            print('[ScreenShop] 找不到界面子节点', name)
        end
    end
    self.RowCount, self.Selected, self.Page = 0, nil, TabNames[1]
    self.Coin, self.CoinState, self.CoinHintText = 0, 'idle', Text.CoinPageHint
    local function listen(signal, callback)
        if signal then self.Connections[#self.Connections + 1] = signal:Connect(callback) end
    end
    for index, name in ipairs(TabNames) do
        local tab, label = self.UINodeMap['BtnShopPage' .. index], self.UINodeMap['LabelShopPage' .. index]
        if label then label.Text, label.FontSize, label.LocalZOrder = name, 28, 10 end
        if tab then
            self:EnsureTabIndicator(index, tab)
            styleButton(tab)
            tab.NormalImage, tab.PressImage, tab.DisableImage = '', '', ''
            tab.ButtonText = ''
            tab.TouchEnabled = true
            listen(tab.OnClicked, function() self:SetPage(name) end)
        end
    end
    local close = self.UINodeMap.BtnShopClose
    if close then
        styleButton(close)
        local closeLabel = self.UINodeMap.LabelShopClose
        if closeLabel then
            closeLabel.Text, closeLabel.FontSize, closeLabel.LocalZOrder = Text.Close, 24, 10
            closeLabel.TextColor = color(Skin.Color.Text)
        end
        listen(close.OnClicked, function() _G.MgrGameUI:CloseScreen('ScreenShop') end)
    end
    local buy = self.UINodeMap.BtnShopBuyDetail
    if buy then
        styleButton(buy)
        buy.NormalImage = Skin.Image.Primary
        buy.ButtonText = ''
        buy.Disabled = true
        listen(buy.OnClicked, function() self:ConfirmBuy() end)
    end
    local buyLabel = self.UINodeMap.LabelShopBuyDetail
    if buyLabel then
        buyLabel.Text, buyLabel.TextColor, buyLabel.LocalZOrder = Text.Buy, color(Skin.Color.TextOnActive), 10
    end
    local list = self.UINodeMap.ShopList
    if list then list.ItemsMargin = Skin.Row.Margin end
    local platform = self.UINodeMap.BtnOpenPlatformShop
    if platform then
        styleButton(platform)
        platform.NormalImage = Skin.Image.Primary
        platform.ButtonText = ''
        listen(platform.OnClicked, function() self:OpenPlatformShop() end)
    end
    local openLabel = self.UINodeMap.LabelOpenPlatformShop
    if openLabel then
        openLabel.Text, openLabel.TextColor, openLabel.LocalZOrder = Text.OpenPlatformShop, color(Skin.Color.TextOnActive), 10
    end
    listen(_G.REUtil:GetRE('ItemBarState').OnClientEvent, function(state)
        if state and state.upgradeLevel then self.UpgradeLevel = state.upgradeLevel end
        if self.IsOpen then self:ShowCoin() self:Render() end
    end)
    listen(_G.REUtil:GetRE('ShopResult').OnClientEvent, function(result) self:NoteResult(result) end)
    self.BoundRootNode = self.RootNode
    self.Inited = true
end

function ScreenHandler:OpenScreen()
    self.IsOpen = true
    self.Page, self.Selected = TabNames[1], nil
    self:ShowCoin()
    self:Render()
end

function ScreenHandler:CloseScreen()
    self.IsOpen = false
end

return ScreenHandler
