-- 钓场商店入口（#48；#90 多摊位）：每个摊位（GameCfg.Shop.Stands）一个文字泡「看看有什么可买的」，
-- 本地角色在该摊位 Radius 米内（只看 x/z）才显示，点击打开 ScreenShop；商店界面的商品按当前摊位
-- 的等级（Stands.Level）上架。走出所有摊位范围自动关商店。购买结果 ShopResult 在这里统一转成消息条提示。
local GameCfg = require('common.GameCfg')
local BodyScale = require('common.BodyScale')
local OwnedUnits = require('common.OwnedUnits')
local REUtil = require('common.REUtil')
local Util = require('common.Util')
local SquareButtonImage = 'official://image/11017'

local LocalShop = { Bubbles = {} }

local World = game:GetService('World')
local Players = game:GetService('Players')

-- 失败提示（#130 扩展 limit/level 与金币页引导；#218 补 stand；#219 与金币页按钮同用术语「地图商店」）：
-- 服务端 reason 为准，未知原因兜底通用文案。
-- 商店界面的失败文案只认这一张表：界面侧本地拒绝（摊位等级不够 / 越级，见 ScreenShop）也读这里，不另写一套。
LocalShop.FailText = {
    coin = '金币不足，可在金币页打开地图商店购买金币',
    full = '背包已满',
    max = '已升至上限',
    range = '离钓场老板太远了',
    item = '这件商品暂不出售',
    limit = '该商品已达购买次数上限',
    level = '请先完成前一级升级',
    stand = '需要更高等级摊位', -- 客户端侧原因：货架行要求的 MinShopLevel 高于当前摊位等级
}
local FailText = LocalShop.FailText

-- 商店界面文案（#219）：ScreenShop 的玩家可见文字全部从这里取，界面文件不再自带第二套。
-- 失败原因仍以 FailText 为准（行上的越级原因直接复用 FailText.level），这里只补按钮、行状态与金币页提示。
-- 金币页只有提示与一个入口按钮：文案里不许出现汇率、价目换算或平台商品 ID（后台交付参数，不编造）。
LocalShop.ShopText = {
    Close = '关闭',
    Buy = '购买',
    GoPlatformShop = '去地图商店',      -- 余额不足时购买按钮就地变成的地图商店入口（#219）
    OpenPlatformShop = '打开地图商店',  -- 金币页的入口按钮
    CoinPageHint = '金币可在地图商店购买',
    PlatformUnavailable = '地图商店暂不可用，可返回其他分页',
    PlatformOpenFailed = '打开地图商店失败，可稍后重试或返回其他分页',
    PlatformOpened = '已请求打开地图商店，请在地图商店内完成操作',
    New = '新品',
    Owned = '已购',
    NoLimit = '不限购',
    StandLocked = '需 %d 级摊位',
    LimitText = '已购 %d / %d 次',
    UpgradeTarget = '当前 %d 级，买完升到 %d 级',
    UpgradeOwned = '当前 %d 级，本行已购买',
}

local function notice(msg)
    if _G.LocalMsgNotice then _G.LocalMsgNotice(msg) end
end

function LocalShop:CreateBubble(anchor)
    local cfg = GameCfg.Shop
    local offset = Vector3.New(0, cfg.BubbleHeight, 0)
    local ok, node = pcall(_G.GameUI.CreateSceneNode, _G.GameUI, cfg.BubblePreset, anchor, offset)
    if not ok or not node then
        print('[LocalShop] 文字泡预设创建失败，改用场景 UI', tostring(node))
        local eui = _G.GameUI:GetEuiManager()
        local center = anchor.Position
        ok, node = pcall(eui.CreateSceneNodeAtPosition, eui,
            Vector3.New(center.x, center.y + cfg.BubbleHeight, center.z))
        if not ok or not node then
            print('[LocalShop] 场景 UI 创建失败', tostring(node))
            return
        end
    end
    pcall(function()
        local title = node:FindFirstChild('LabelShopTitle', true)
        if title then title.Text = cfg.HintText end
    end)
    local okBtn, btn = pcall(World.CreateUnit, World, 'EUIButton', {
        Parent = node, Name = 'BtnShopEnter', Position = Vector2.New(0, 0), Size = Vector2.New(360, 72),
    })
    if okBtn and btn then
        OwnedUnits.Track(self, btn) -- 气泡按钮归本模块所有，Clear 时销毁
        btn.ButtonText = ''
        btn.NormalImage = SquareButtonImage
        btn.PressImage = SquareButtonImage
        btn.DisableImage = SquareButtonImage
        btn.ButtonNormalColor = Color.New(54, 100, 140, 255)
        btn.ButtonPressColor = Color.New(36, 130, 94, 255)
        btn.ButtonDisableColor = Color.New(120, 120, 120, 255)
        btn.TouchEnabled = true
        local label = World:CreateUnit('EUITextLabel', {
            Parent = node, Name = 'LabelShopEnterTheme', Position = btn.Position, Size = btn.Size,
            Text = cfg.HintText, FontSize = 26, TextColor = Color.New(255, 255, 255, 255),
        })
        if label then
            OwnedUnits.Track(self, label) -- 气泡文字同上
            label.TouchEnabled = false
            label.SwallowTouchEnabled = false
            label.LocalZOrder = 1
        end
        btn.OnClicked:Connect(function() self:Open() end)
    else
        print('[LocalShop] 入口按钮创建失败', tostring(btn))
    end
    node.Visible = false
    return node
end

---关闭本模块建的全部摊口气泡（幂等）：销毁名下按钮与文字，再销毁气泡根节点，登记表归空。
-- 气泡根节点是 EUI 场景节点（不在建点清单里），随气泡一起显式销毁，不留看不见的残留。
function LocalShop:Clear()
    OwnedUnits.Clear(self)
    for _, bubble in ipairs(self.Bubbles) do
        local ok, err = pcall(function() bubble.Node:Destroy() end)
        if not ok then print('[LocalShop] 气泡根节点销毁失败', tostring(err)) end
    end
    self.Bubbles = {}
    self.Stand = nil
end

function LocalShop:Open()
    if not self.Stand then return end
    print('[LocalShop] 打开商店', self.Stand.AnchorName, 'level=' .. tostring(self.Stand.Level))
    _G.MgrGameUI:OpenScreen('ScreenShop')
end

function LocalShop:Update()
    local character = Players.LocalPlayer and Players.LocalPlayer.Character
    local pos = character and character.Position
    local shop = GameCfg.Shop
    local nearStand
    for _, bubble in ipairs(self.Bubbles) do
        local near = false
        if pos then
            local dx, dz = pos.x - bubble.Center.x, pos.z - bubble.Center.z
            local radius = BodyScale.InteractionRadius(character, shop.Radius)
            near = dx * dx + dz * dz <= radius * radius
        end
        if near then nearStand = bubble.Stand end
        if bubble.Near ~= near then
            bubble.Near = near
            local ok, err = pcall(function() bubble.Node.Visible = near end)
            if not ok then print('[LocalShop] 气泡显隐失败', tostring(err)) end
        end
    end
    if self.Stand ~= nearStand then
        self.Stand = nearStand
        if not nearStand and _G.MgrGameUI:IsScreenOpen('ScreenShop') then
            print('[LocalShop] 离开钓场老板，关闭商店')
            _G.MgrGameUI:CloseScreen('ScreenShop')
        end
    end
end

function LocalShop:Start()
    self:Clear() -- 重建语义：重复启动先拆上一轮的摊口气泡，不叠第二套
    REUtil:GetRE('ShopResult').OnClientEvent:Connect(function(result)
        if type(result) ~= 'table' then return end
        local definition = GameCfg.Items.Definitions[result.itemId]
        if result.ok and result.action == 'UpgradeStorage' then
            notice('扩容成功：道具栏 ' .. tostring(GameCfg.Items.InitialItemBarSlots + result.level)
                .. ' 格，背包 ' .. tostring((result.level == #GameCfg.Items.UpgradePrices and GameCfg.Items.MaxBackpackSlots
                    or GameCfg.Items.InitialBackpackSlots + result.level * GameCfg.Items.BackpackSlotsPerUpgrade)) .. ' 格')
        elseif result.ok then
            -- 升级行无 itemKey，名称以服务端回包为准（#130）
            notice('购买成功：' .. tostring(result.name or definition and definition.Name or result.itemId)
                .. '，花费 ' .. tostring(result.price) .. ' 金币')
        else
            notice(FailText[result.reason] or '购买失败')
        end
    end)
    for _, stand in ipairs(GameCfg.Shop.Stands) do
        local anchor = Util:WaitForChild(World, stand.AnchorName)
        if anchor then
            local node = self:CreateBubble(anchor)
            if node then
                self.Bubbles[#self.Bubbles + 1] = { Node = node, Center = anchor.Position, Stand = stand, Near = false }
            end
        else
            print('[LocalShop] 找不到钓场老板单位', stand.AnchorName)
        end
    end
    game:GetService('RunService').Heartbeat:Connect(function() self:Update() end)
end

return LocalShop
