-- 钓场商店界面（#48/#90 多摊位；#130 四页；#216 固定骨架 + 运行期填行；#217 行内容与选中；
-- #218 详情区与唯一购买入口；#219 金币不足就地引导）：
-- 骨架（标题、关闭、四页签、列表容器 ShopListPanel > ShopList、详情容器、金币页容器、底部金币条）
-- 由预制体摆好；本屏只读骨架节点——Init 按 UINodes 从 RootNode 重新取一遍填表，不再运行时建页签、
-- 翻页按钮或补位行。商品行由本屏建在 ShopList（EUIListView）之下并按序号复用，生命周期交给 OwnedUnits：
-- 换 RootNode 再 Init 时上一轮整体销毁、登记表归零、节点表换新。
-- 页签文字取 GameCfg.Shop.Pages；切页签 = 切容器可见性（ShopListPanel / ShopCoinPanel）+ 清空选中。
-- 行内容沿用 GameCfg.Shop.ListForPage 的排序口径（含锁定行），界面里不再排序；升级行没有 itemKey，
-- 购买一律发货架行编号 Number；结果以服务端 ShopResult 为准。
--
-- 显示模型只算一次（Model）：行、详情、金币条、容器与页签高亮都从这一份模型出。View() 返回它，是本屏
-- 唯一的测试接缝；生产渲染 Render() = View() + Apply()，单测看到的模型就是玩家看到的界面。
-- 行的两个概念互相独立（#214 用户故事 8 / 20 / 21）：
--   selectable  能不能点：已购行不可点（故事 20：买满限购不让白点）；锁定行可点（故事 8 / 21：点了看详情与原因）；
--   purchasable 能不能买：只有已解锁且未买满的行能买；锁定行在详情区照常给描述、价格与原因，购买按钮禁用。
-- 锁定与已购行的行底与文字都用禁用色（故事 21「灰显」），颜色只来自 Skin；行状态只在 Model 里判一次。
--
-- #218：详情区（ShopDetailPanel）显示选中行的名字、描述、价格、限购次数与升级等级；没选中就是空态
-- （文字清空、购买按钮禁用），切页签与重开商店都不留上一条的残留。全屏只有 BtnShopBuyDetail 能下单；
-- 不可买的行把原因写在按钮上（需 N 级摊位 / 请先完成前一级升级 / 已购）并禁用。
-- 买成后金币条取服务端回包的 coinAfter、行与详情立刻刷新；服务端拒绝时不改本地金币与行状态。
-- 玩家可见文案只来自 client/LocalShop.lua（FailText 与 ShopText 同一处真源），界面里不另写一套。
-- #219：余额买不起选中行时，详情区购买按钮就地变成「去地图商店」，点了切到金币页、不发购买请求；
-- 金币页是地图商店入口：平台能力缺失或打开失败只提示、不发请求、不伪成功，页签照常可切
-- （汇率与商品 ID 由后台交付，界面里不出现）。
local GameCfg = require('common.GameCfg')
local OwnedUnits = require('common.OwnedUnits')
local LocalShop = require('client.LocalShop')

local TabNames = GameCfg.Shop.Pages
local CoinPage = TabNames[#TabNames]              -- 金币页是最后一个页签

-- 玩家可见文案统一取 client/LocalShop.lua（#219）：界面里不写第二套字符串。
local Text, FailText = LocalShop.ShopText, LocalShop.FailText

local function color(spec) return Color.New(spec[1], spec[2], spec[3], spec[4]) end

local Skin                                       -- 皮肤表在下面填：行内子节点的写入函数要引用 Skin

-- 行文字颜色：禁用（已购 / 锁定灰显）> 本摊新品金色 > 常规白；色值只在皮肤表里出现一次。
-- 判据是行模型的 purchasable / isNew，这里不重判行状态。
local function rowTextColor(row)
    if not row.purchasable then return Skin.Color.TextDisabled end
    if row.isNew then return Skin.Color.TextNew end
    return Skin.Color.Text
end

-- 行底色：选中高亮 > 禁用灰 > 常规。锁定与已购整天灰显（#214 故事 21），不是只换后缀文字的颜色。
local function rowBaseColor(row)
    if row.selected then return Skin.Color.RowSelected end
    if not row.purchasable then return Skin.Color.RowDisabled end
    return Skin.Color.Row
end

local function writeText(node, text, tone)
    node.Text, node.TextColor = text or '', color(tone)
end

-- 皮肤参数：图 ID、字号、色板、行高、行间距与行内子节点的几何 / 建点 / 写入方式只在这里给一次，
-- 换美术只改这张表。数字出处：共享简报「骨架布局」「商品行几何」（ShopRoot 本地盒 1200×800，锚点左下对齐）。
do
    -- 只有运行时新建的节点才从这里取图：预制体里的按钮与面板归编辑器，代码不覆盖它们的图。
    local Image = {
        Panel = 'official://image/11017',   -- 官方正方形纯色块
        Row = 'official://image/11017',     -- 运行时新建的行按钮底图
        Coin = 'official://image/11017',    -- 金币图标占位：正式图随美术批次只改这一处
    }
    local Font = { Row = 24, RowSmall = 20 }
    local Palette = {
        Text = { 255, 255, 255, 255 },
        TextNew = { 255, 214, 92, 255 },        -- 本摊新解锁的名字金色（#217）
        TextDisabled = { 150, 150, 150, 255 },  -- 锁定 / 已购行的文字灰显（#217）
        Button = { 54, 100, 140, 255 },
        ButtonActive = { 36, 130, 94, 255 },
        ButtonPress = { 36, 130, 94, 255 },
        ButtonDisable = { 120, 120, 120, 255 },
        ButtonGuide = { 36, 130, 94, 255 },     -- 金币不足时按钮变「去地图商店」（#219）
        Row = { 54, 100, 140, 255 },            -- 可买行的行底
        RowSelected = { 60, 132, 176, 255 },    -- 选中行高亮（#217）
        RowDisabled = { 74, 78, 86, 255 },      -- 锁定 / 已购行的行底灰显（#214 故事 21）
    }
    -- 商品行内子节点：每个条目自带建点类型与参数（Kind / Create）和写入方式（Paint）。
    -- 建行与刷行读同一份驱动数据，加一种子节点只加一个条目，不必同时改建点与刷点两处；
    -- Paint 为 nil 表示不随行模型变（纯装饰，如金币图标）。
    local Children = {
        { Name = 'ShopRowIcon', Kind = 'EUIImage', X = 8, Y = 18, Width = 60, Height = 60,
            Create = { Image = Image.Coin },
            Paint = function(node, row) node.Image = row.icon end },
        { Name = 'ShopRowNew', Kind = 'EUITextLabel', X = 76, Y = 54, Width = 84, Height = 36,
            Create = { Text = '', FontSize = Font.RowSmall, TextColor = color(Palette.Text) },
            Paint = function(node, row) writeText(node, row.newText, rowTextColor(row)) end },
        { Name = 'ShopRowName', Kind = 'EUITextLabel', X = 76, Y = 10, Width = 320, Height = 44,
            Create = { Text = '', FontSize = Font.Row, TextColor = color(Palette.Text) },
            Paint = function(node, row) writeText(node, row.name, rowTextColor(row)) end },
        { Name = 'ShopRowCoin', Kind = 'EUIImage', X = 470, Y = 26, Width = 32, Height = 32,
            Create = { Image = Image.Coin } },
        { Name = 'ShopRowPrice', Kind = 'EUITextLabel', X = 506, Y = 14, Width = 140, Height = 44,
            Create = { Text = '', FontSize = Font.Row, TextColor = color(Palette.Text) },
            Paint = function(node, row) writeText(node, row.priceText, rowTextColor(row)) end },
        { Name = 'ShopRowState', Kind = 'EUITextLabel', X = 300, Y = 54, Width = 340, Height = 34,
            Create = { Text = '', FontSize = Font.RowSmall, TextColor = color(Palette.Text) },
            Paint = function(node, row) writeText(node, row.stateText, rowTextColor(row)) end },
    }
    -- 商品行：行间由列表视图的 ItemsMargin 负责；子节点坐标相对行左下角
    Skin = {
        Image = Image, Font = Font, Color = Palette,
        Row = { Width = 660, Height = 96, Margin = 8, Children = Children },
    }
end

-- 骨架按钮只改颜色与文字：按钮图与面板图由预制体摆好，运行时覆盖会让所有按钮变成同一块纯色方块。
local function styleButton(button)
    if not button then return end
    button.ButtonNormalColor = color(Skin.Color.Button)
    button.ButtonPressColor = color(Skin.Color.ButtonPress)
    button.ButtonDisableColor = color(Skin.Color.ButtonDisable)
end

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

-- 当前摊位等级：站在哪个摊位旁就按哪个摊位的等级上架；兜底取第一个摊位（等级最低）。
-- 每次算模型时现取，换摊位再开商店不必重建 handler。
local function standLevel()
    return (LocalShop.Stand and LocalShop.Stand.Level) or GameCfg.Shop.Stands[1].Level
end

local ScreenHandler = {
    UINodes = { 'BtnShopClose', 'LabelShopClose', 'LabelCurCoin', 'ShopListPanel', 'ShopList', 'ShopCoinPanel',
        'LabelCoinPageHint', 'BtnOpenPlatformShop', 'LabelOpenPlatformShop',
        -- 详情区（#218）：全部由预制体摆好，代码只改文字、可见性与按钮可用性
        'ShopDetailPanel', 'ImageShopDetailIcon', 'ImageShopDetailCoin', 'LabelShopDetailName',
        'LabelShopDetailDesc', 'LabelShopDetailPrice', 'LabelShopDetailLimit', 'LabelShopDetailUpgrade',
        'BtnShopBuyDetail', 'LabelShopBuyDetail' },
    -- 会话内的显示状态（模型从这几项派生）；节点表、连接与请求序号随 Init 刷新
    UINodeMap = {}, Connections = {}, Seq = 0,
    Page = TabNames[1], Selected = nil, Purchases = {}, UpgradeLevels = {}, UpgradeLevel = 0,
    RowCount = 0, Coin = 0, CoinState = 'idle', CoinHintText = nil,
}

-- 四页签：按钮与文字都由骨架提供，这里只登记名字（顺序即 GameCfg.Shop.Pages）
for index = 1, #TabNames do
    ScreenHandler.UINodes[#ScreenHandler.UINodes + 1] = 'BtnShopPage' .. index
    ScreenHandler.UINodes[#ScreenHandler.UINodes + 1] = 'LabelShopPage' .. index
end

function ScreenHandler:CurrentUpgradeLevel(kind)
    if kind == 'backpack' then return self.UpgradeLevel or 0 end
    return self.UpgradeLevels[kind] or 0
end

-- 行状态、不可买原因与行后缀文案一次给出（#217 / #218）：
--   locked（摊位等级不够 / 升级越级：灰显、可点，详情写原因）
--   owned （限购已满或该级升级已买过：不可点）
--   buy   （可买）
-- reason 对应 client/LocalShop.lua 的 FailText 原因键：本地拒绝的提示与行后缀文案都从这一处推。
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

-- 行模型：state / reason / stateText 一次算好，selectable 与 purchasable 是两个独立概念（#214 故事 8 / 20 / 21）。
-- 已购行不可点；锁定行可点（详情区写清为什么不能买）；可买行两者皆真。
function ScreenHandler:BuildRow(index, goods, level)
    -- 升级类商品的当前等级只算一次：行状态（越级判断）与详情文案共用同一个值
    local upgradeLevel = goods.Upgrade and self:CurrentUpgradeLevel(goods.Upgrade.kind) or nil
    local state, reason, stateText = self:RowState(goods, level, upgradeLevel)
    local definition = goods.ItemId and GameCfg.Items.Definitions[goods.ItemId] or nil
    local isNew = goods.MinShopLevel == level
    return {
        index = index, number = goods.Number, goods = goods,
        name = goods.Name, priceText = tostring(goods.Price),
        state = state, reason = reason, stateText = stateText, upgradeLevel = upgradeLevel,
        isNew = isNew, newText = isNew and Text.New or '',
        icon = definition and definition.Icon or Skin.Image.Panel,
        selectable = state ~= 'owned',
        purchasable = state == 'buy',
        selected = index == self.Selected,
    }
end

-- 详情模型（#218）：选中行 → 名字 / 描述 / 价格 / 限购次数 / 升级等级与购买按钮的文案、动作、可用性；
-- 没选中 → 空态（文字全空、按钮禁用），切页签与重开商店都不留上一条的残留。
-- 不可买的行把原因写在按钮上（已购 / 需 N 级摊位 / 请先完成前一级升级）并禁用——玩家知道差什么。
function ScreenHandler:BuildDetail(row, coin)
    if not row then
        return { number = nil, name = '', desc = '', icon = nil, priceText = '', limitText = '',
            upgradeText = '', buyText = Text.Buy, buyAction = nil, buyEnabled = false }
    end
    local goods = row.goods
    -- 买得起才下单；买不起就地引导到金币页（#219）——同一个按钮，换的是动作与文案
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

-- 显示模型：本屏唯一的派生处。行、详情、金币条、容器与页签高亮全部从这里出；
-- View() 返回它，Render() 把它刷到节点——单测看的模型就是生产路径上那一份。
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
        -- 金币页把内容区整块让给 ShopCoinPanel：列表与详情都不出现（详情区不压在金币页上）
        panels = { list = not coinPage, coin = coinPage, detail = not coinPage },
    }
end

-- 公开显示快照：本屏唯一的测试接缝。纯函数，只读——不发指令、不建节点、不改状态。
function ScreenHandler:View() return self:Model() end

-- 把模型刷到骨架节点：只改文字、颜色、可见性与可用性；按钮图与几何归预制体。
function ScreenHandler:Apply(model)
    local nodes = self.UINodeMap
    local listPanel, coinPanel, detailPanel = nodes.ShopListPanel, nodes.ShopCoinPanel, nodes.ShopDetailPanel
    if listPanel then listPanel.Visible = model.panels.list end
    if coinPanel then coinPanel.Visible = model.panels.coin end
    if detailPanel then detailPanel.Visible = model.panels.detail end
    for index, name in ipairs(TabNames) do
        local tab = nodes['BtnShopPage' .. index]
        if tab then
            tab.ButtonNormalColor = color(name == model.page and Skin.Color.ButtonActive or Skin.Color.Button)
        end
    end
    local coinLabel = nodes.LabelCurCoin
    if coinLabel then coinLabel.Text = model.coinText end
    local hintLabel = nodes.LabelCoinPageHint
    if hintLabel then hintLabel.Text = model.coinHint or '' end
    self:RenderRows(model)
    self:RenderDetail(model.detail)
end

-- 生产渲染路径：算一次模型再落节点（View 的派生就是玩家看到的那份）
function ScreenHandler:Render() self:Apply(self:View()) end

-- 选中只是显示状态（#218）：「能不能点」只看模型的 selectable——已购行不可点（#214 故事 20，玩家不白点），
-- 锁定行可点，点了详情区照常给描述、价格与不能买的原因（故事 8 / 21）。nil 照旧表示清空选中。
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
    -- 从别的页进金币页时回到默认提示：上一次的「打开失败」不跨次残留（#219）
    if changed and page == CoinPage then self.CoinState, self.CoinHintText = 'idle', Text.CoinPageHint end
    self:Render()
    return true
end

-- 下单（#218）：唯一入口是详情区的 BtnShopBuyDetail（Init 里接线），行点击只选中。
-- 不可买的行在这里兜底拒绝，但仍用同一份文案说明原因，不许静默；服务端复验仍是唯一权威。
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

-- 详情区唯一的购买按钮（#218）：买得起就下单；买不起就地引导到金币页（#219），这一步不发购买请求。
function ScreenHandler:ConfirmBuy()
    -- 现算模型：按钮动作跟着当前余额走，不读上一次渲染的缓存（#219）
    if self:View().detail.buyAction == 'coin' then return self:SetPage(CoinPage) end
    return self:Buy(self.Selected)
end

-- 本地拒绝的提示：文案与 ShopResult 通道同一份（LocalShop.FailText），界面里不另写一套。
function ScreenHandler:NoteFail(reason)
    local text = reason and FailText[reason]
    if text and _G.LocalMsgNotice then _G.LocalMsgNotice(text) end
end

-- 余额只存一份（Coin）：金币条的数字由模型出，不再另存一份字符串。
function ScreenHandler:SetCoin(coin) self.Coin = math.floor(coin or 0) end

function ScreenHandler:ShowCoin()
    local player = game:GetService('Players').LocalPlayer
    self:SetCoin(player and tonumber(player:GetAttribute('FishCoin')) or 0)
end

-- 金币页提示（#219）：文案只从 LocalShop.ShopText 取；状态进模型，节点文字由 Render 刷。
function ScreenHandler:SetCoinHint(state, text)
    self.CoinState, self.CoinHintText = state, text
    self:Render()
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
    -- 子节点的类型、建点参数与写入方式都来自同一个条目（Skin.Row.Children），这里不再按 Kind 分支
    for _, child in ipairs(Skin.Row.Children) do
        local attrs = { Parent = row, Name = child.Name .. index,
            Position = Vector2.New(child.X, child.Y), Size = Vector2.New(child.Width, child.Height),
            TouchEnabled = false, SwallowTouchEnabled = false, LocalZOrder = 1 }
        for key, value in pairs(child.Create) do attrs[key] = value end
        local node = world:CreateUnit(child.Kind, attrs)
        if not node then print('[ScreenShop] 商品行子节点创建失败', child.Name, index) end
    end
    OwnedUnits.Track(self, row)
    self.Connections[#self.Connections + 1] = row.OnClicked:Connect(function() self:Select(index) end)
    return row
end

-- 刷行：子节点各按条目自带的写入函数刷，文字与行底色都从同一个行模型出。
function ScreenHandler:PaintRow(row, model)
    local index = model.index
    for _, child in ipairs(Skin.Row.Children) do
        local node = row:FindFirstChild(child.Name .. index)
        if node and child.Paint then child.Paint(node, model) end
    end
    -- 行是选择器：点行只改选中与高亮，下单由详情区的唯一购买按钮发起（#218）。
    -- 已购行不可点（#214 故事 20）；锁定行可点，点了在详情区看到描述、价格与原因（故事 8 / 21）。
    row.TouchEnabled = model.selectable
    row.ButtonNormalColor = color(rowBaseColor(model))
end

-- 把模型的行刷到 ShopList 下：缺行就建，多出来的行隐藏（行按序号复用，不重建）
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

-- 把详情模型刷到骨架节点：只改文字、图标可见性与按钮可用性/颜色，几何与按钮图归预制体。
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
        icon.Visible = hasRow
        if model.icon then icon.Image = model.icon end
    end
    if coinIcon then coinIcon.Visible = hasRow end
    -- 按钮图归预制体，这里只刷颜色：引导态换另一色，玩家一眼看出这一下不是下单（#219）
    local button = nodes.BtnShopBuyDetail
    if button then
        button.Disabled = not model.buyEnabled
        local tone = Skin.Color.ButtonDisable
        if model.buyEnabled then tone = model.buyAction == 'coin' and Skin.Color.ButtonGuide or Skin.Color.Button end
        button.ButtonNormalColor = color(tone)
    end
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
    self:Render()
end

-- 只接线、不渲染：重建（换 RootNode 再 Init）时先按归属登记清掉上一轮的运行期建点，
-- 清完登记表归零，行与详情要等 OpenScreen / 刷新事件时的 Render 才刷。
function ScreenHandler:Init()
    if self.Inited and self.BoundRootNode == self.RootNode then return end
    for _, connection in ipairs(self.Connections or {}) do connection:Disconnect() end
    OwnedUnits.Clear(self)
    self.Connections = {}
    -- 换一张新节点表再填：换 RootNode 时上一轮的同名节点已随旧树销毁，留着引用就是残留
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
    listen(_G.REUtil:GetRE('ItemBarState').OnClientEvent, function(state)
        if state and state.upgradeLevel then self.UpgradeLevel = state.upgradeLevel end
        if self.IsOpen then self:ShowCoin() self:Render() end -- 先读余额再重绘（#219）
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
    self:Render()
end

function ScreenHandler:CloseScreen()
    self.IsOpen = false
end

return ScreenHandler
