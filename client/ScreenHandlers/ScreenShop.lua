-- 钓场商店界面（#48/#90 多摊位；#130 四页；#216 固定骨架 + 运行期填行；#217 行内容与选中）：
-- 骨架（标题、关闭、四页签、列表容器 ShopListPanel > ShopList、详情容器、金币页容器、底部金币条）
-- 由预制体摆好；本屏只读骨架节点（UINodes 登记 / UINodeMap 取用），不再运行时建页签、翻页按钮
-- 或补位行。商品行由本屏建在 ShopList（EUIListView）之下并按需复用，生命周期交给 OwnedUnits：
-- 换 RootNode 再 Init 时上一轮整体销毁、登记表归零。
-- 页签文字取 GameCfg.Shop.Pages；切页签 = 切容器可见性（ShopListPanel / ShopCoinPanel）+ 清空选中。
-- 行内容沿用 GameCfg.Shop.ListForPage 的排序口径（含锁定行），界面里不再排序；升级行没有 itemKey，
-- 购买一律发货架行编号 Number；结果以服务端 ShopResult 为准。
-- #217：行的新品标记、状态文字、灰显与选中高亮都从 DisplayRows 模型推出；点行只选中（不下单），
-- 购买入口是 #218 的唯一购买按钮（调到 Buy）。
-- 金币页是平台商店入口：平台不可用时提示并可返回其他分页，不伪成功（汇率与商品 ID 由后台交付）。
-- 唯一的测试接缝是 View()（纯显示快照）：单测只断言显示了什么、点了发出什么、登记表计数。
local GameCfg = require('common.GameCfg')
local OwnedUnits = require('common.OwnedUnits')
local LocalShop = require('client.LocalShop')

local TabNames = GameCfg.Shop.Pages
local CoinPage = TabNames[#TabNames]              -- 金币页是最后一个页签

-- 皮肤参数：图 ID、字号、色板、行高、行间距、行内子节点几何只在这里给一次，换美术只改这张表。
-- 数字出处：共享简报「骨架布局」「商品行几何」（ShopRoot 本地盒 1200×800，锚点统一左下对齐）。
local Skin = {
    -- 只有运行时新建的节点才从这里取图：预制体里的按钮与面板归编辑器，代码不覆盖它们的图。
    Image = {
        Panel = 'official://image/11017',   -- 官方正方形纯色块
        Row = 'official://image/11017',     -- 运行时新建的行按钮底图
        Coin = 'official://image/11017',    -- 金币图标占位：正式图随美术批次只改这一处
    },
    Font = { Row = 24, RowSmall = 20 },
    Color = {
        Text = { 255, 255, 255, 255 },
        TextNew = { 255, 214, 92, 255 },        -- 本摊新解锁的名字金色（#217）
        TextDisabled = { 150, 150, 150, 255 },  -- 锁定 / 已购行灰显（#217）
        Button = { 54, 100, 140, 255 },
        ButtonActive = { 36, 130, 94, 255 },
        ButtonPress = { 36, 130, 94, 255 },
        ButtonDisable = { 120, 120, 120, 255 },
        RowSelected = { 60, 132, 176, 255 },    -- 选中行高亮（#217）
    },
    -- 商品行：行间由列表视图的 ItemsMargin 负责；子节点坐标相对行左下角
    Row = {
        Width = 660, Height = 96, Margin = 8,
        Children = {
            { Key = 'Icon', Name = 'ShopRowIcon', Kind = 'EUIImage', X = 8, Y = 18, Width = 60, Height = 60 },
            { Key = 'New', Name = 'ShopRowNew', Kind = 'EUITextLabel', X = 76, Y = 54, Width = 84,
                Height = 36, Font = 'RowSmall' },
            { Key = 'Name', Name = 'ShopRowName', Kind = 'EUITextLabel', X = 76, Y = 10, Width = 320,
                Height = 44, Font = 'Row' },
            { Key = 'Coin', Name = 'ShopRowCoin', Kind = 'EUIImage', X = 470, Y = 26, Width = 32, Height = 32 },
            { Key = 'Price', Name = 'ShopRowPrice', Kind = 'EUITextLabel', X = 506, Y = 14, Width = 140,
                Height = 44, Font = 'Row' },
            { Key = 'State', Name = 'ShopRowState', Kind = 'EUITextLabel', X = 300, Y = 54, Width = 340,
                Height = 34, Font = 'RowSmall' },
        },
    },
}

local function color(spec) return Color.New(spec[1], spec[2], spec[3], spec[4]) end

-- 骨架按钮只改颜色与文字：按钮图与面板图由预制体摆好，运行时覆盖会让所有按钮变成同一块纯色方块。
local function styleButton(button)
    if not button then return end
    button.ButtonNormalColor = color(Skin.Color.Button)
    button.ButtonPressColor = color(Skin.Color.ButtonPress)
    button.ButtonDisableColor = color(Skin.Color.ButtonDisable)
end

-- 行状态文案（#217 口径，与共享简报「商品行」一致）：已购 / 需 N 级摊位 / 请先完成前一级升级。
-- 玩家可见文案不用术语表禁用的「强化」。
local function stateText(state, goods, level)
    if state == 'owned' then return '已购' end
    if state == 'locked' then
        if goods.MinShopLevel > level then return '需 ' .. goods.MinShopLevel .. ' 级摊位' end
        return '请先完成前一级升级'
    end
    return ''
end

-- 本摊新解锁标记（#217）：MinShopLevel == 当前摊位等级即新品，不新增数据字段。
local NewBadgeText = '新品'

-- 行文字颜色：禁用（锁定/已购）灰显 > 本摊新品金色 > 常规白色。色值只在皮肤表里出现一次。
local function rowTextColor(model)
    if model.state ~= 'buy' then return Skin.Color.TextDisabled end
    if model.isNew then return Skin.Color.TextNew end
    return Skin.Color.Text
end

local ScreenHandler = {
    UINodes = { 'BtnShopClose', 'LabelShopClose', 'LabelCurCoin', 'ShopListPanel', 'ShopList', 'ShopCoinPanel',
        'LabelCoinPageHint', 'BtnOpenPlatformShop', 'LabelOpenPlatformShop' },
    UINodeMap = {}, Connections = {}, Seq = 0,
    Page = TabNames[1], Selected = nil, Purchases = {}, UpgradeLevels = {},
    DisplayRows = {}, RowCount = 0, Panels = { list = false, coin = false },
}

-- 四页签：按钮与文字都由骨架提供，这里只登记名字（顺序即 GameCfg.Shop.Pages）
for index = 1, #TabNames do
    ScreenHandler.UINodes[#ScreenHandler.UINodes + 1] = 'BtnShopPage' .. index
    ScreenHandler.UINodes[#ScreenHandler.UINodes + 1] = 'LabelShopPage' .. index
end

-- 行状态：locked（摊位等级不够或升级越级，灰显）/ owned（限购已满或升级级别已购）/ buy（可购买）
function ScreenHandler:RowState(goods, level)
    if goods.MinShopLevel > level then return 'locked' end
    if goods.Upgrade then
        local current = self:CurrentUpgradeLevel(goods.Upgrade.kind)
        if goods.Upgrade.level <= current then return 'owned' end
        if goods.Upgrade.level > current + 1 then return 'locked' end
    end
    if (goods.PurchaseLimit or 0) > 0 and (self.Purchases[goods.Number] or 0) >= goods.PurchaseLimit then
        return 'owned'
    end
    return 'buy'
end

function ScreenHandler:CurrentUpgradeLevel(kind)
    if kind == 'backpack' then return self.UpgradeLevel or 0 end
    return self.UpgradeLevels[kind] or 0
end

-- 公开显示快照：本屏唯一的测试接缝。纯函数，只读——不发指令、不建节点、不改状态。
function ScreenHandler:View()
    local rows = {}
    for index, row in ipairs(self.DisplayRows or {}) do
        rows[index] = { index = index, number = row.number, name = row.name, priceText = row.priceText,
            state = row.state, stateText = row.stateText,
            isNew = row.isNew == true, newText = row.isNew and NewBadgeText or '',
            selected = index == self.Selected }
    end
    return {
        page = self.Page,
        tabs = TabNames,
        selected = self.Selected,
        rows = rows,
        coinText = self.CoinText or '0',
        coinHint = self.CoinHintText,
        panels = { list = self.Panels.list, coin = self.Panels.coin },
    }
end

-- 选中只是显示状态：任何一行都能选中（禁用行是否拒绝属 #218），重绘后高亮仍落在同一行下标。
function ScreenHandler:Select(index)
    if index ~= nil and not (self.DisplayRows or {})[index] then return false end
    self.Selected = index
    self:RenderRows()
    return true
end

function ScreenHandler:SetPage(page)
    local known = false
    for _, name in ipairs(TabNames) do
        if name == page then known = true end
    end
    if not known then return false end
    self.Page, self.Selected = page, nil
    self:ShowGoods()
    return true
end

function ScreenHandler:Buy(index)
    local row = (self.DisplayRows or {})[index]
    if not row or not self.IsOpen then return end
    if row.state ~= 'buy' then return end
    self.Seq = self.Seq + 1
    _G.REUtil:GetRE('ShopAction'):FireServer({ action = 'Buy', number = row.number, seq = self.Seq })
end

function ScreenHandler:ShowCoin()
    local player = game:GetService('Players').LocalPlayer
    local coin = player and tonumber(player:GetAttribute('FishCoin')) or 0
    self.CoinText = tostring(math.floor(coin or 0))
    local label = self.UINodeMap.LabelCurCoin
    if label then label.Text = self.CoinText end
end

-- 容器切换：列表页与金币页各看各的容器，其余骨架（标题/页签/详情/金币条）常驻
function ScreenHandler:ShowPanels()
    local coin = self.Page == CoinPage
    local listPanel, coinPanel = self.UINodeMap.ShopListPanel, self.UINodeMap.ShopCoinPanel
    if listPanel then listPanel.Visible = not coin end
    if coinPanel then coinPanel.Visible = coin end
    self.Panels = { list = listPanel ~= nil and listPanel.Visible == true,
        coin = coinPanel ~= nil and coinPanel.Visible == true }
end

function ScreenHandler:StyleTabs()
    for index, name in ipairs(TabNames) do
        local tab = self.UINodeMap['BtnShopPage' .. index]
        if tab then
            tab.ButtonNormalColor = color(name == self.Page and Skin.Color.ButtonActive or Skin.Color.Button)
        end
    end
end

-- 金币页：平台商店入口（降级口径）。平台不可用时只提示、停留本屏（页签可返回），不伪成功。
function ScreenHandler:OpenPlatformShop()
    local platform = rawget(_G, 'PlatformShop')
    local hint
    if type(platform) ~= 'table' or type(platform.Open) ~= 'function' then
        hint = '平台商店暂不可用，请稍后再试；可返回其他分页继续购买金币商品'
    else
        local ok, err = pcall(function() platform:Open() end)
        if ok then
            hint = '已请求打开平台商店，请在平台侧完成购买'
        else
            print('[ScreenShop] 平台商店打开失败', tostring(err))
            hint = '平台商店打开失败：' .. tostring(err) .. '；可返回其他分页'
        end
    end
    self.CoinHintText = hint
    local label = self.UINodeMap.LabelCoinPageHint
    if label then label.Text = hint end
end

function ScreenHandler:RowModel(goods, level)
    local state = self:RowState(goods, level)
    local definition = goods.ItemId and GameCfg.Items.Definitions[goods.ItemId] or nil
    return { number = goods.Number, goods = goods, name = goods.Name, priceText = tostring(goods.Price),
        state = state, stateText = stateText(state, goods, level),
        isNew = goods.MinShopLevel == level,
        icon = definition and definition.Icon or Skin.Image.Panel }
end

-- 建一行：行归本屏所有（OwnedUnits）。行内子节点不单独登记——EUINode:Destroy() 递归带走子节点，
-- 登记两遍会在清场时把同一节点拆两次。
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
    -- 行是运行时新建的按钮：底图从皮肤表取（骨架按钮的图归预制体），颜色随后由 PaintRow 按状态刷
    row.NormalImage, row.PressImage, row.DisableImage = Skin.Image.Row, Skin.Image.Row, Skin.Image.Row
    styleButton(row)
    row.ButtonText = ''
    row.TouchEnabled = true
    for _, child in ipairs(Skin.Row.Children) do
        local kind = child.Kind
        local node
        if kind == 'EUIImage' then
            node = world:CreateUnit(kind, {
                Parent = row, Name = child.Name .. index,
                Position = Vector2.New(child.X, child.Y), Size = Vector2.New(child.Width, child.Height),
                Image = child.Key == 'Coin' and Skin.Image.Coin or Skin.Image.Panel,
                TouchEnabled = false, SwallowTouchEnabled = false, LocalZOrder = 1,
            })
        else
            node = world:CreateUnit(kind, {
                Parent = row, Name = child.Name .. index,
                Position = Vector2.New(child.X, child.Y), Size = Vector2.New(child.Width, child.Height),
                Text = '', FontSize = Skin.Font[child.Font], TextColor = color(Skin.Color.Text),
                TouchEnabled = false, SwallowTouchEnabled = false, LocalZOrder = 1,
            })
        end
        if not node then print('[ScreenShop] 商品行子节点创建失败', child.Name, index) end
    end
    OwnedUnits.Track(self, row)
    self.Connections[#self.Connections + 1] = row.OnClicked:Connect(function() self:Select(index) end)
    return row
end

function ScreenHandler:PaintRow(row, index, model)
    local textColor = color(rowTextColor(model))
    for _, child in ipairs(Skin.Row.Children) do
        local node = row:FindFirstChild(child.Name .. index)
        if node then
            if child.Key == 'Icon' then
                node.Image = model.icon
            elseif child.Key == 'Name' then
                node.Text, node.TextColor = model.name, textColor
            elseif child.Key == 'New' then
                node.Text, node.TextColor = model.isNew and NewBadgeText or '', color(Skin.Color.TextNew)
            elseif child.Key == 'Price' then
                node.Text, node.TextColor = model.priceText, textColor
            elseif child.Key == 'State' then
                node.Text, node.TextColor = model.stateText, textColor
            end
        end
    end
    -- 行是选择器：点行只改选中与高亮，下单由 #218 的唯一购买按钮发起；禁用行的「不可买」由 Buy 拦。
    row.ButtonNormalColor = color(index == self.Selected and Skin.Color.RowSelected or Skin.Color.Button)
end

-- 把当前显示模型刷到 ShopList 下：缺行就建，多出来的行隐藏（行按序号复用，不重建）
function ScreenHandler:RenderRows()
    local list = self.UINodeMap.ShopList
    if not list then return end
    local shown = #self.DisplayRows
    for index = 1, math.max(shown, self.RowCount or 0) do
        local model = self.DisplayRows[index]
        local row = list:FindFirstChild('ShopRow' .. index)
        if model and not row then row = self:CreateRow(list, index) end
        if row then
            row.Visible = model ~= nil
            if model then self:PaintRow(row, index, model) end
        end
    end
    self.RowCount = shown
end

function ScreenHandler:ShowGoods()
    local shop = GameCfg.Shop
    -- 站在哪个摊位旁开的商店就用哪个摊位的等级；兜底取第一个摊位（等级最低）
    local level = (LocalShop.Stand and LocalShop.Stand.Level) or shop.Stands[1].Level
    self.Level = level
    self:ShowPanels()
    self:StyleTabs()
    if self.Page == CoinPage then
        self.DisplayRows = {}
    else
        local goods = shop.ListForPage(level, self.Page, true)
        local rows = {}
        for index, row in ipairs(goods) do rows[index] = self:RowModel(row, level) end
        self.DisplayRows = rows
    end
    self:RenderRows()
end

-- 购买结果回包：会话内累计购买次数与升级等级（服务端仍是唯一权威，失败不回包计数）
function ScreenHandler:NoteResult(result)
    if type(result) ~= 'table' then return end
    if result.ok then
        if result.number then self.Purchases[result.number] = (self.Purchases[result.number] or 0) + 1 end
        if result.kind and result.level then
            self.UpgradeLevels[result.kind] = math.max(self.UpgradeLevels[result.kind] or 0, result.level)
        end
        if result.action == 'UpgradeStorage' and result.level then self.UpgradeLevel = result.level end
    end
    if self.IsOpen then self:ShowGoods() self:ShowCoin() end
end

-- 只接线、不渲染：重建（换 RootNode 再 Init）时先按归属登记清掉上一轮的运行期建点，
-- 清完登记表归零，第一批行要等 OpenScreen / 刷新事件才建。
function ScreenHandler:Init()
    if self.Inited and self.BoundRootNode == self.RootNode then return end
    for _, connection in ipairs(self.Connections or {}) do connection:Disconnect() end
    OwnedUnits.Clear(self)
    self.Connections = {}
    self.RowCount, self.DisplayRows = 0, {}
    self.Selected, self.Page = nil, TabNames[1]
    self.Panels = { list = false, coin = false }
    local function listen(signal, callback)
        if signal then self.Connections[#self.Connections + 1] = signal:Connect(callback) end
    end
    -- 四页签：文字取 GameCfg.Shop.Pages（钓具/武器/升级/金币），骨架里已有按钮与文字节点
    for index, name in ipairs(TabNames) do
        local tab, label = self.UINodeMap['BtnShopPage' .. index], self.UINodeMap['LabelShopPage' .. index]
        if label then label.Text = name end
        if tab then
            styleButton(tab)
            tab.ButtonText = ''
            tab.TouchEnabled = true
            listen(tab.OnClicked, function() self:SetPage(name) end)
        end
    end
    local close = self.UINodeMap.BtnShopClose
    if close then
        styleButton(close)
        -- 关闭按钮的文字在子节点 LabelShopClose（按钮自身的 ButtonText 由 styleButton 清空）
        local closeLabel = self.UINodeMap.LabelShopClose
        if closeLabel then closeLabel.Text = '关闭' end
        listen(close.OnClicked, function() _G.MgrGameUI:CloseScreen('ScreenShop') end)
    end
    -- 行间距只在皮肤表里写一次，落在列表视图的 ItemsMargin 上
    local list = self.UINodeMap.ShopList
    if list then list.ItemsMargin = Skin.Row.Margin end
    local platform = self.UINodeMap.BtnOpenPlatformShop
    if platform then
        styleButton(platform)
        platform.ButtonText = ''
        listen(platform.OnClicked, function() self:OpenPlatformShop() end)
    end
    local hint = self.UINodeMap.LabelCoinPageHint
    if hint then self.CoinHintText = hint.Text end
    listen(_G.REUtil:GetRE('ItemBarState').OnClientEvent, function(state)
        if state and state.upgradeLevel then self.UpgradeLevel = state.upgradeLevel end
        if self.IsOpen then self:ShowGoods() self:ShowCoin() end
    end)
    listen(_G.REUtil:GetRE('ShopResult').OnClientEvent, function(result) self:NoteResult(result) end)
    self.BoundRootNode = self.RootNode
    self.Inited = true
end

-- 打开商店：回到钓具页、清空选中、刷新金币条（关掉再开不残留上一次的页与选中）
function ScreenHandler:OpenScreen()
    self.IsOpen = true
    self.Page, self.Selected = TabNames[1], nil
    self:ShowGoods()
    self:ShowCoin()
end

function ScreenHandler:CloseScreen()
    self.IsOpen = false
end

return ScreenHandler
