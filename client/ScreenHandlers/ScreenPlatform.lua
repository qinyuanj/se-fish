-- 平台购买客户端面板（#147 T26）：只消费服务端 PlatformResult 回包并上行 PlatformAction，不做本地结算。
--   * AdrenalineShop：濒死无药时服务端拉起的肾上腺素两份报价（1 金豆 ×1 / 4 金豆 ×5），点选后上行
--     Purchase；不可用（商品 ID 未交付且生产构建）明确提示，不伪成功；
--   * Grant：购买发货落账提示（满格溢出的件数落在面前地上）；Purchase/CoinShop 失败给可读原因；
--   * TestFlow：调试构建的测试 flow 开/关——显示「成功 / 取消 / 失败」驱动按钮，上行 PlatformTestAction；
--     生产构建服务端既不建测试 flow 也拒绝驱动器，这组按钮不会出现；
--   * PlaceholderFlow：占位支付通道的确认面板（#261，生产开关）——显示商品与占位价目、注明
--     「不发放真实付费权益」，确认/取消上行 PlatformAction{action='PlaceholderOutcome'}；服务端 open=false 时收起；
--   * CoinShop / CoinGrant：金币页报价（按服务端占位汇率渲染）与到账提示；点选上行 BuyCoin；
--   * _G.PlatformShop.Open：地图商店金币页入口（ScreenShop:OpenPlatformShop 与主 HUD BtnMapShopEntry 共用），上行 OpenCoinShop。HUD 按钮常驻在布局的 ShopEntry，经 OpenFromHud 调用 Open；平台能力缺失或打开失败用金币页同款文案，按钮留在 HUD 上。
-- 节点全部运行时创建（data/ 只读）；创建失败只记日志，不阻塞主流程。
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

---销毁平台界面建的全部节点并复位查找表（幂等，#211）：销毁只走归属登记，不从 Nodes 枚举。
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
        Color = Color.New(54, 100, 140, 255) })
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
    -- 重建前先清空上一轮尝试建出的节点：重试循环里一次只成功一半后再试，不叠重复报价 / 驱动面板。
    self:Clear()
    local resolution = GameUI:GetEuiManager():GetDeviceResolution() or { x = 1920, y = 1080 }
    local cx, cy = resolution.x / 2, resolution.y / 2
    -- #275：主 HUD 右上入口组的预留矩形。坐标是中心点，与图鉴入口同一口径。
    local entry = MainHudLayout.Compute({ width = resolution.x, height = resolution.y }).Rects.ShopEntry
    local button = self:Button(root, 'BtnMapShopEntry', entry.x, entry.y, entry.w, entry.h,
        '', function() self:OpenFromHud() end)
    -- 按钮下的文字子节点试玩不渲染（#174）。标签挂到同一父节点、同位同尺寸，与图鉴、盲盒入口一致。
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
    -- 占位支付通道的确认面板：生产构建唯一的购买面（调试构建走测试驱动器）
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

-- 报价面板：goods 模式按金豆价目渲染（价目以服务端 GameCfg.Platform.Goods 为准），
-- coin 模式按占位汇率渲染（价目与汇率以服务端 GameCfg.Platform.Placeholder.CoinPage 为准）。
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

-- 占位确认面板：服务端说 open 就按回包里的商品与价目显示，收起时清掉挂着的 flow
function Panel:ShowPlaceholder(payload)
    local open = payload.open == true
    self.Flow = open and payload or nil
    local title = self.Nodes.PlatformPlaceholderTitle
    if title then
        local name = payload.name or payload.key or ''
        local text
        -- 占位广告与占位支付各用各的标签：通道不同，「不发放真实付费权益」的说明也不同
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

-- 地图商店金币页入口（ScreenShop:OpenPlatformShop 经 rawget(_G, 'PlatformShop') 调用）
function Panel:Open()
    REUtil:GetRE('PlatformAction'):FireServer({ action = 'OpenCoinShop' })
end

-- 主 HUD 入口与金币页同一条打开路径。平台能力缺失或打开抛错时用金币页现有文案，
-- 错误串只进日志；按钮不拆，也不把失败记成已打开。
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
