-- 钓场商店界面（#48/#90 多摊位；#130 四页；#216 固定骨架 + 运行期填行；#217 行内容与选中；
-- #218 详情区与唯一购买入口）：
-- 骨架（标题、关闭、四页签、列表容器 ShopListPanel > ShopList、详情容器、金币页容器、底部金币条）
-- 由预制体摆好；本屏只读骨架节点（UINodes 登记 / UINodeMap 取用），不再运行时建页签、翻页按钮
-- 或补位行。商品行由本屏建在 ShopList（EUIListView）之下并按需复用，生命周期交给 OwnedUnits：
-- 换 RootNode 再 Init 时上一轮整体销毁、登记表归零。
-- 页签文字取 GameCfg.Shop.Pages；切页签 = 切容器可见性（ShopListPanel / ShopCoinPanel）+ 清空选中。
-- 行内容沿用 GameCfg.Shop.ListForPage 的排序口径（含锁定行），界面里不再排序；升级行没有 itemKey，
-- 购买一律发货架行编号 Number；结果以服务端 ShopResult 为准。
-- #217：行的新品标记、状态文字、灰显与选中高亮都从 DisplayRows 模型推出；点行只选中（不下单）。
-- #218：详情区（ShopDetailPanel）显示选中行的名字、描述、价格、限购次数与升级等级；没选中就是空态
-- （文字清空、购买按钮禁用），切页签与重开商店都不留上一条的残留。全屏只有 BtnShopBuyDetail 能下单；
-- 锁定与已购行在节点层禁用、Select 也拒绝（这是对 #217「锁定行同样可选中」的反转，依据 #214 用户故事 20）。
-- 买成后金币条取服务端回包的 coinAfter、行与详情立刻刷新；服务端拒绝时不改本地金币与行状态。
-- 玩家可见文案只来自 client/LocalShop.lua（FailText 与 ShopText 同一处真源），界面里不另写一套。
-- #219：余额买不起选中行时，详情区购买按钮就地变成「去地图商店」，点了切到金币页、不发购买请求；
-- 金币页是地图商店入口：平台能力缺失或打开失败只提示、不发请求、不伪成功，页签照常可切
-- （汇率与商品 ID 由后台交付，界面里不出现）。
-- 唯一的测试接缝是 View()（纯显示快照）：单测只断言显示了什么、点了发出什么、登记表计数。
local GameCfg = require('common.GameCfg')
local OwnedUnits = require('common.OwnedUnits')
local LocalShop = require('client.LocalShop')

local TabNames = GameCfg.Shop.Pages
local CoinPage = TabNames[#TabNames]              -- 金币页是最后一个页签

-- 玩家可见文案统一取 client/LocalShop.lua（#219）：界面里不写第二套字符串。
local Text, FailText = LocalShop.ShopText, LocalShop.FailText

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
        ButtonGuide = { 36, 130, 94, 255 },     -- 金币不足时按钮变「去地图商店」（#219）
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
    if state == 'owned' then return Text.Owned end
    if state == 'locked' then
        if goods.MinShopLevel > level then return string.format(Text.StandLocked, goods.MinShopLevel) end
        return FailText.level -- 越级原因与本地拒绝文案同一句，不另写一份
    end
    return ''
end

-- 本摊新解锁标记（#217）：MinShopLevel == 当前摊位等级即新品，不新增数据字段。
-- 限购文案（#218）：已买几次 / 上限几次；没有限购的行明确写「不限购」，不留一个空格子。
local function limitText(goods, bought)
    local limit = goods.PurchaseLimit or 0
    if limit <= 0 then return Text.NoLimit end
    return string.format(Text.LimitText, bought, limit)
end

-- 升级类商品的等级（#218）：当前几级、买完升到几级；非升级行留空。买到这一级之后如实说已购买。
local function upgradeText(goods, current)
    local upgrade = goods.Upgrade
    if not upgrade then return '' end
    if current >= upgrade.level then return string.format(Text.UpgradeOwned, current) end
    return string.format(Text.UpgradeTarget, current, upgrade.level)
end

-- 行文字颜色：禁用（锁定/已购）灰显 > 本摊新品金色 > 常规白色。色值只在皮肤表里出现一次。
local function rowTextColor(model)
    if model.state ~= 'buy' then return Skin.Color.TextDisabled end
    if model.isNew then return Skin.Color.TextNew end
    return Skin.Color.Text
end

local ScreenHandler = {
    UINodes = { 'BtnShopClose', 'LabelShopClose', 'LabelCurCoin', 'ShopListPanel', 'ShopList', 'ShopCoinPanel',
        'LabelCoinPageHint', 'BtnOpenPlatformShop', 'LabelOpenPlatformShop',
        -- 详情区（#218）：全部由预制体摆好，代码只改文字、可见性与按钮可用性
        'ShopDetailPanel', 'ImageShopDetailIcon', 'ImageShopDetailCoin', 'LabelShopDetailName',
        'LabelShopDetailDesc', 'LabelShopDetailPrice', 'LabelShopDetailLimit', 'LabelShopDetailUpgrade',
        'BtnShopBuyDetail', 'LabelShopBuyDetail' },
    UINodeMap = {}, Connections = {}, Seq = 0,
    Page = TabNames[1], Selected = nil, Purchases = {}, UpgradeLevels = {},
    DisplayRows = {}, RowCount = 0, Panels = { list = false, coin = false, detail = false },
    -- 余额同时进显示与模型（#219）：详情区按钮是「购买」还是「去地图商店」由 Coin 决定
    Coin = 0, CoinText = '0', CoinState = 'idle',
}

-- 四页签：按钮与文字都由骨架提供，这里只登记名字（顺序即 GameCfg.Shop.Pages）
for index = 1, #TabNames do
    ScreenHandler.UINodes[#ScreenHandler.UINodes + 1] = 'BtnShopPage' .. index
    ScreenHandler.UINodes[#ScreenHandler.UINodes + 1] = 'LabelShopPage' .. index
end

-- 行状态与不可买原因一起给出（#218）：原因键对应 client/LocalShop.lua 的 FailText，
-- 行文字与本地拒绝的提示文案都从这一处推，界面里不再各写一份。
-- locked（摊位等级不够 / 升级越级，灰显不可点）/ owned（限购已满或该级升级已买过）/ buy（可购买）
function ScreenHandler:RowBlock(goods, level)
    if goods.MinShopLevel > level then return 'locked', 'stand' end
    if goods.Upgrade then
        local current = self:CurrentUpgradeLevel(goods.Upgrade.kind)
        if goods.Upgrade.level <= current then return 'owned', 'level' end
        if goods.Upgrade.level > current + 1 then return 'locked', 'level' end
    end
    if (goods.PurchaseLimit or 0) > 0 and (self.Purchases[goods.Number] or 0) >= goods.PurchaseLimit then
        return 'owned', 'limit'
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
            isNew = row.isNew == true, newText = row.isNew and Text.New or '',
            selectable = row.state == 'buy',
            selected = index == self.Selected }
    end
    return {
        page = self.Page,
        tabs = TabNames,
        selected = self.Selected,
        rows = rows,
        detail = self.Detail or self:DetailModel(),
        coinText = self.CoinText or '0',
        coinHint = self.CoinHintText,
        coinState = self.CoinState,
        panels = { list = self.Panels.list, coin = self.Panels.coin, detail = self.Panels.detail },
    }
end

-- 选中只是显示状态（#218）：只有可购买行能选中——锁定与已购行在节点层已禁用，这里再兜一次，
-- 免得程序化调用或状态切换的瞬间把选中挪到买不了的行上（玩家白点）。nil 照旧表示清空选中。
function ScreenHandler:Select(index)
    local row = index ~= nil and (self.DisplayRows or {})[index] or nil
    if index ~= nil and not row then return false end
    if row and row.state ~= 'buy' then return false end
    self.Selected = index
    self:RenderRows()
    self:RenderDetail()
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
    -- 从别的页进金币页时回到默认提示：上一次的「打开失败」不跨次残留（#219）
    if changed and page == CoinPage then self:SetCoinHint('idle', Text.CoinPageHint) end
    self:ShowGoods()
    return true
end

-- 下单（#218）：唯一入口是详情区的 BtnShopBuyDetail（Init 里接线），行点击只选中。
-- 不可买状态在这里兜底拒绝，但仍用同一份文案说明原因，不许静默；服务端复验仍是唯一权威。
function ScreenHandler:Buy(index)
    local row = (self.DisplayRows or {})[index]
    if not row or not self.IsOpen then return false end
    if row.state ~= 'buy' then
        self:NoteFail(row.reason)
        return false
    end
    self.Seq = self.Seq + 1
    _G.REUtil:GetRE('ShopAction'):FireServer({ action = 'Buy', number = row.number, seq = self.Seq })
    return true
end

-- 详情区唯一的购买按钮（#218）：买得起就下单；买不起就地引导到金币页（#219），这一步不发购买请求。
function ScreenHandler:ConfirmBuy()
    -- 现算模型：按钮动作跟着当前余额走，不读上一次渲染的缓存（#219）
    if self:DetailModel().buyAction == 'coin' then return self:SetPage(CoinPage) end
    return self:Buy(self.Selected)
end

-- 本地拒绝的提示：文案与 ShopResult 通道同一份（LocalShop.FailText），界面里不另写一套。
function ScreenHandler:NoteFail(reason)
    local text = reason and FailText[reason]
    if text and _G.LocalMsgNotice then _G.LocalMsgNotice(text) end
end

-- 余额既进显示（金币条）也进模型（#219）：详情区买不买得起据此判断，不在渲染时另读属性。
function ScreenHandler:SetCoin(coin)
    self.Coin = math.floor(coin or 0)
    self.CoinText = tostring(self.Coin)
    local label = self.UINodeMap.LabelCurCoin
    if label then label.Text = self.CoinText end
end

function ScreenHandler:ShowCoin()
    local player = game:GetService('Players').LocalPlayer
    self:SetCoin(player and tonumber(player:GetAttribute('FishCoin')) or 0)
end

-- 容器切换：列表页与金币页各看各的容器，其余骨架（标题/页签/详情/金币条）常驻
function ScreenHandler:ShowPanels()
    local coin = self.Page == CoinPage
    local listPanel, coinPanel = self.UINodeMap.ShopListPanel, self.UINodeMap.ShopCoinPanel
    local detailPanel = self.UINodeMap.ShopDetailPanel
    if listPanel then listPanel.Visible = not coin end
    if coinPanel then coinPanel.Visible = coin end
    -- 详情区只跟商品页一起出现：金币页整块内容区让给 ShopCoinPanel（否则详情区压在金币页上）
    if detailPanel then detailPanel.Visible = not coin end
    self.Panels = { list = listPanel ~= nil and listPanel.Visible == true,
        coin = coinPanel ~= nil and coinPanel.Visible == true,
        detail = detailPanel ~= nil and detailPanel.Visible == true }
end

function ScreenHandler:StyleTabs()
    for index, name in ipairs(TabNames) do
        local tab = self.UINodeMap['BtnShopPage' .. index]
        if tab then
            tab.ButtonNormalColor = color(name == self.Page and Skin.Color.ButtonActive or Skin.Color.Button)
        end
    end
end

-- 金币页提示（#219）：文案只从 LocalShop.ShopText 取；状态进 View 快照，单测据此断言降级。
function ScreenHandler:SetCoinHint(state, text)
    self.CoinState, self.CoinHintText = state, text
    local label = self.UINodeMap.LabelCoinPageHint
    if label then label.Text = text end
end

-- 金币页：地图商店入口（#219，口径照 ScreenPlatform）。平台能力缺失或打开失败只提示、不发请求、
-- 不伪成功；页签照常可切，玩家不会卡在金币页。打开成功也只给中性提示：买没买到以平台侧回执为准。
function ScreenHandler:OpenPlatformShop()
    local platform = rawget(_G, 'PlatformShop')
    if type(platform) ~= 'table' or type(platform.Open) ~= 'function' then
        self:SetCoinHint('unavailable', Text.PlatformUnavailable)
        return false
    end
    local ok, err = pcall(function() platform:Open() end)
    if not ok then
        print('[ScreenShop] 打开地图商店失败', tostring(err)) -- 错误串只进日志，不拼进玩家文案
        self:SetCoinHint('failed', Text.PlatformOpenFailed)
        return false
    end
    self:SetCoinHint('opened', Text.PlatformOpened)
    return true
end

function ScreenHandler:RowModel(goods, level)
    local state, reason = self:RowBlock(goods, level)
    local definition = goods.ItemId and GameCfg.Items.Definitions[goods.ItemId] or nil
    return { number = goods.Number, goods = goods, name = goods.Name, priceText = tostring(goods.Price),
        state = state, reason = reason, stateText = stateText(state, goods, level),
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
                node.Text, node.TextColor = model.isNew and Text.New or '', color(Skin.Color.TextNew)
            elseif child.Key == 'Price' then
                node.Text, node.TextColor = model.priceText, textColor
            elseif child.Key == 'State' then
                node.Text, node.TextColor = model.stateText, textColor
            end
        end
    end
    -- 行是选择器：点行只改选中与高亮，下单由详情区的唯一购买按钮发起（#218）。
    -- 锁定与已购行在节点层就禁用（#214 用户故事 20：已买满限购的商品不可点，玩家才不会白点）。
    row.TouchEnabled = model.state == 'buy'
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

-- 详情区显示模型（#218）：选中行 → 名字/描述/价格/限购次数/升级等级与购买按钮可用性；
-- 没选中 → 空态（文字全空、按钮禁用），切页签与重开商店都不留上一条的残留。
function ScreenHandler:DetailModel()
    local row = self.Selected and (self.DisplayRows or {})[self.Selected] or nil
    if not row then
        return { number = nil, name = '', desc = '', priceText = '', limitText = '', upgradeText = '',
            buyText = Text.Buy, buyAction = nil, buyEnabled = false }
    end
    local goods = row.goods
    local current = goods.Upgrade and self:CurrentUpgradeLevel(goods.Upgrade.kind) or 0
    -- 买得起才下单；买不起时就地引导到金币页（#219）——同一个按钮，换的是动作与文案。
    -- 不可买的行（锁定 / 已购）不给动作，按钮按空态禁用。
    local action
    if row.state == 'buy' then
        action = (self.Coin or 0) >= (goods.Price or 0) and 'buy' or 'coin'
    end
    return {
        number = row.number, name = row.name, desc = goods.Desc or '', icon = row.icon,
        priceText = row.priceText,
        limitText = limitText(goods, self.Purchases[goods.Number] or 0),
        upgradeText = upgradeText(goods, current),
        buyText = action == 'coin' and Text.GoPlatformShop or Text.Buy,
        buyAction = action,
        buyEnabled = action ~= nil,
    }
end

-- 把详情模型刷到骨架节点：只改文字、可见性与按钮可用性/颜色，几何与按钮图归预制体。
function ScreenHandler:RenderDetail()
    local model = self:DetailModel()
    self.Detail = model
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
    local icon, coinIcon = nodes.ImageShopDetailIcon, nodes.ImageShopDetailCoin
    if icon then
        icon.Visible = model.number ~= nil
        if model.icon then icon.Image = model.icon end
    end
    if coinIcon then coinIcon.Visible = model.number ~= nil end
    -- 按钮图归预制体，这里只刷颜色：引导态换另一色，玩家一眼看出这一下不是下单（#219）
    local button = nodes.BtnShopBuyDetail
    if button then
        button.Disabled = not model.buyEnabled
        local tone = Skin.Color.ButtonDisable
        if model.buyEnabled then tone = model.buyAction == 'coin' and Skin.Color.ButtonGuide or Skin.Color.Button end
        button.ButtonNormalColor = color(tone)
    end
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
    self:RenderDetail()
end

-- 购买结果回包：会话内累计购买次数与升级等级（服务端仍是唯一权威，失败不回包计数）。
-- 失败回包不动本地金币与行状态（不伪成功，也不提前扣本地金钱）；成功时金币条取回包里的 coinAfter，
-- 属性下发滞后也当场看到扣款——不等属性刷新，也不自行推算。
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
    -- 先定余额再重绘：详情按钮是「购买」还是「去地图商店」取决于更新后的金币（#219）
    self:ShowCoin()
    if result.ok and type(result.coinAfter) == 'number' then self:SetCoin(result.coinAfter) end
    self:ShowGoods()
end

-- 只接线、不渲染：重建（换 RootNode 再 Init）时先按归属登记清掉上一轮的运行期建点，
-- 清完登记表归零，第一批行要等 OpenScreen / 刷新事件才建。
function ScreenHandler:Init()
    if self.Inited and self.BoundRootNode == self.RootNode then return end
    for _, connection in ipairs(self.Connections or {}) do connection:Disconnect() end
    OwnedUnits.Clear(self)
    self.Connections = {}
    self.RowCount, self.DisplayRows = 0, {}
    self.Selected, self.Page, self.Detail = nil, TabNames[1], nil
    self.Coin, self.CoinText = 0, '0'
    self.Panels = { list = false, coin = false, detail = false }
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
        if closeLabel then closeLabel.Text = Text.Close end
        listen(close.OnClicked, function() _G.MgrGameUI:CloseScreen('ScreenShop') end)
    end
    -- 详情区（#218）：唯一购买入口。按钮图归预制体，这里只接线、清文字，未选中时按空态禁用。
    local buy = self.UINodeMap.BtnShopBuyDetail
    if buy then
        styleButton(buy)
        buy.ButtonText = ''
        buy.Disabled = true
        listen(buy.OnClicked, function() self:ConfirmBuy() end)
    end
    local buyLabel = self.UINodeMap.LabelShopBuyDetail
    if buyLabel then buyLabel.Text = Text.Buy end
    -- 行间距只在皮肤表里写一次，落在列表视图的 ItemsMargin 上
    local list = self.UINodeMap.ShopList
    if list then list.ItemsMargin = Skin.Row.Margin end
    local platform = self.UINodeMap.BtnOpenPlatformShop
    if platform then
        styleButton(platform)
        platform.ButtonText = ''
        listen(platform.OnClicked, function() self:OpenPlatformShop() end)
    end
    local openLabel = self.UINodeMap.LabelOpenPlatformShop
    if openLabel then openLabel.Text = Text.OpenPlatformShop end
    self:SetCoinHint('idle', Text.CoinPageHint)
    listen(_G.REUtil:GetRE('ItemBarState').OnClientEvent, function(state)
        if state and state.upgradeLevel then self.UpgradeLevel = state.upgradeLevel end
        if self.IsOpen then self:ShowCoin() self:ShowGoods() end -- 先读余额再重绘（#219）
    end)
    listen(_G.REUtil:GetRE('ShopResult').OnClientEvent, function(result) self:NoteResult(result) end)
    self.BoundRootNode = self.RootNode
    self.Inited = true
end

-- 打开商店：回到钓具页、清空选中、刷新金币条（关掉再开不残留上一次的页与选中）
function ScreenHandler:OpenScreen()
    self.IsOpen = true
    self.Page, self.Selected = TabNames[1], nil
    self:ShowCoin() -- 先读余额：详情按钮是「购买」还是「去地图商店」取决于它（#219）
    self:ShowGoods()
end

function ScreenHandler:CloseScreen()
    self.IsOpen = false
end

return ScreenHandler
