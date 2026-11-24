local GameCfg = {}
local ContentItems = require('common.cfg.items')
local ContentFish = require('common.cfg.fish')
local ContentShop = require('common.cfg.shop')
local ContentLottery = require('common.cfg.lottery')
local ContentBlindbox = require('common.cfg.blindbox')
local BossMoves = require('common.cfg.boss_moves')
local FishCatch = require('common.fish_catch')

GameCfg.Zones = {
    { Id = 'fishPond', Name = '鱼塘', WaterId = 'fishPond.water', BaitItemId = 'worm', source = '钓鱼表!R2' },
    { Id = 'shrimpPond', Name = '虾池', WaterId = 'shrimpPond.water', BaitItemId = 'sausage', source = '钓鱼表!R16' },
    { Id = 'crabLake', Name = '蟹湖', WaterId = 'crabLake.water', BaitItemId = 'item115', source = '钓鱼表!R30' },
    { Id = 'forestIsland', Name = '树林岛', WaterId = 'forestIsland.water', BaitItemId = 'item116', source = '钓鱼表!R44' },
    { Id = 'beachIsland', Name = '沙滩岛', WaterId = 'beachIsland.water', BaitItemId = 'item117', source = '钓鱼表!R58' },
    { Id = 'reefIsland', Name = '礁石岛', WaterId = 'reefIsland.water', BaitItemId = 'item118', source = '钓鱼表!R72' },
    { Id = 'volcanoIsland', Name = '火山岛', WaterId = 'volcanoIsland.water', BaitItemId = 'item119', source = '钓鱼表!R86' },
}
GameCfg.LegacyZoneIdMap = { fishPond1 = 'fishPond', shrimpPond = 'shrimpPond' }

function GameCfg.resolve_zone_id(id)
    return GameCfg.LegacyZoneIdMap[id] or id
end


GameCfg.InteractionBubble = {
    Width = 220,
    Height = 84,
    FontSize = 40,
    Gap = 20,
    Image = 'official://image/11017',
    BackgroundColor = { 35, 57, 78, 245 },
}

GameCfg.Items = {
    ContainerId = { ItemBar = 'itemBar', Backpack = 'backpack', Bait = 'bait' },
    ItemBarSlots = 8,
    InitialItemBarSlots = 2,
    InitialBackpackSlots = 5,
    BackpackSlotsPerUpgrade = 5,
    MaxBackpackSlots = 40,
    UpgradePrices = { 100, 200, 400, 800, 1600, 3200 },
    Id = { Tilapia = 'tilapia', Carp = 'carp', KnifeFish = 'knifeFish', Bass = 'bass', Catfish = 'catfish', Goldfish = 'goldfish', Worm = 'worm', Sausage = 'sausage', StarterRod = 'starterRod',
        Shrimp = 'shrimp', RiverShrimp = 'riverShrimp', Crayfish = 'crayfish', BostonLobster = 'bostonLobster', AussieLobster = 'aussieLobster', MilkLobster = 'milkLobster',
        RareShrimp = 'rareShrimp', RareRiverShrimp = 'rareRiverShrimp', RareCrayfish = 'rareCrayfish',
        RareBostonLobster = 'rareBostonLobster', RareAussieLobster = 'rareAussieLobster', RareMilkLobster = 'rareMilkLobster',
        EelMeat = 'eelMeat', EelHead = 'eelHead', GarMeat = 'garMeat', GarHead = 'garHead', Duck = 'duck', ShrimpTicket = 'shrimpTicket',
        ShrimpRod = 'shrimpRod', CrabRod = 'crabRod', NormalRod = 'normalRod', ProRod = 'proRod', AirforceRod = 'airforceRod', UnscientificRod = 'unscientificRod' },
    ActionCooldownSec = 0.12,
    PotionLimits = { item167 = 20, item168 = 10 },
    RodVisual = {
        Mesh = 'official://mesh/50450',
        Socket = 'l_weapon',
        Scale = { x = 0.2, y = 0.25, z = 0.2 },
    },
    Definitions = ContentItems.Definitions,
    SourceIdMap = ContentItems.SourceIdMap,
    LegacyIdMap = ContentItems.LegacyIdMap,
}
GameCfg.Vitals = {
    HeldDamage = { ItemId = 'item126', DamagePerSec = 1 },
    MaxHealth = 300,
    MaxHunger = 300,
    HungerPerSec = 1,
    StarveDamagePerSec = 5,
    MaxCatchUpSec = 5,
    ReviveDelaySec = 5,
    ReviveGraceSec = 2,
    FlashPeriodSec = 0.5,
    WarnIntervalSec = 5,
    WarnText = '我要饿死了！',
    HealthRing = 'official://image/30013',
    HungerRing = 'official://image/30013',
    RingBg = 'official://image/30014',
    HealthColor = { 230, 60, 60, 255 },
    HungerColor = { 240, 170, 40, 255 },
    FlashImage = 'official://image/11081',
    FlashColor = { 255, 0, 0, 150 },
    FlashThickness = 40,
}

GameCfg.Survival = {
    DownedSec = 15,
    DeadSec = 30,
    ReviveHealthPercent = 10,
    ReviveHungerPercent = 10,
    WeakSec = 60,
    WeakSpeedScale = 0.5,
    AdrenalineItemId = 'item171',
    HelpCries = { '要死啦！', '救救我！' },
    HelpRadius = 30,
    HelpCooldownSec = 1,
    DownedTitle = '你还能再抢救一下！',
    DeadTitle = '你已经死了！倒计时结束后虚弱复活。',
    AdrenalineText = '给自己一针肾上腺素',
    CallHelpText = '向队友呼救',
    AdReviveText = '看广告满血复活',
    PaidReviveText = '5金豆满血复活',
    NoAdrenalineText = '没有肾上腺素，可前往地图商店购买',
    PlatformPendingText = '平台复活即将开放，请等待倒计时虚弱复活',
    PlatformWaitText = '平台处理中，复活倒计时已暂停',
    PlatformResumeText = '未完成满血复活，免费复活倒计时继续',
    WeakText = '虚弱中：移动速度减半',
    UnavailableText = '操作暂时不可用，请稍后再试',
}

GameCfg.Rescue = {
    Target = 'downedPlayer',
    Action = 'Rescue',
    PromptText = '抢救',
    RescuingTitle = '正在抢救…',
    BusyText = '正在抢救中',
    Range = 2,
    BubbleHeight = 1.2,
    DurationSec = 2,
    InterruptMoveMeters = 1,
    InterruptOnDamage = true,
}

GameCfg.Party = {
    MaxMembers = 3,
    MinMembers = 2,
    InviteRange = 2,
    InviteTimeoutSec = 10,
    ActionCooldownSec = 0.2,
    StateCooldownSec = 0.5,
    HealthSyncIntervalSec = 0.5,
    HUD = {
        ColorBlockImage = 'official://image/11017',
        RowWidth = 240,
        RowHeight = 56,
        MarginRight = 24,
        MarginTop = 220,
        MaxRows = 2,
        BarWidth = 120,
        BarHeight = 12,
        InviteWidth = 360,
        InviteHeight = 96,
        InviteTop = 24,
        InviteText = '收到了组队邀请',
        InviteCountdownText = '秒后自动拒绝',
        AcceptText = '接受',
        DeclineText = '拒绝',
        DisbandText = '小队已解散',
        LeftText = '你已离开小队',
        RestoredText = '已回到原来的小队',
        RestoreFullText = '原小队已满 3 人，暂时回不去',
        UnavailableText = '组队操作暂时不可用',
        TooFarText = '距离太远，走到 2 米内再邀请',
        FullText = '小队已满 3 人',
        OfflineText = '对方不在线',
        TargetInPartyText = '对方已在别的队伍里',
        NoInviteText = '邀请已失效'
    },
}

GameCfg.Debug = {
    Enabled = false,
    InitialGrants = {
        { itemId = GameCfg.Items.Id.StarterRod, count = 1, containerId = GameCfg.Items.ContainerId.ItemBar },
        { itemId = GameCfg.Items.Id.Worm, count = 10, containerId = GameCfg.Items.ContainerId.Bait },
    },
}

GameCfg.Fish = ContentFish.Definitions
GameCfg.FishSourceIdMap = ContentFish.SourceIdMap
GameCfg.LegacyFishIdMap = ContentFish.LegacyIdMap

GameCfg.FishUnit = {
    LiftSocket = 'origin',
    LiftSocketOffset = { x = 0, y = 1.9, z = 0 },
    -- 服务端 Lift() 后等 OnLiftedBegin 的确认窗；没确认才重试，最多 LiftAttempts 次
    -- （Lift 是占用语义，确认前连调会把刚抓起的鱼放开）
    LiftConfirmSec = 1,
    LiftAttempts = 3,
    AwaitDriftTolerance = 0.05,
    LinearDamping = 0.5,
    AngularDamping = 0.5,
    DropOffset = 1.5,
    DropHeight = 0.5,
    EscapeSpeed = 3,
    TurnSec = 3,
    RayHz = 8,
    RayDistance = 1.5,
    RayRetries = 3,
    PerPlayerEscapeCap = 1,
    GlobalEscapePerPlayer = 2,
}

GameCfg.Loot = {
    PickupRadius = 2,
    PickupSlack = 0.5,
    GroundRayUp = 1,
    GroundRayDown = 20,
    Height = 0.2,
    BubbleHeight = 1.2,
    DropSpacing = 1,
    PerZoneCap = 200,
    FlashBeforeRecycleSec = 30,
    RecycleRetrySec = 5,
    FlashIntervalSec = 0.5,
    PendingCap = 40,
    DropOffset = 1.5,
    ItemMesh = 'official://mesh/7000571',
    ItemScale = 0.3,
}

GameCfg.Save = {
    Store = 'sefish_save_v1',
    KeyPrefix = 'u',
    QaSlot = '',
    MaxRetries = 3,
    RetryDelaySec = 1,
    AutosaveSec = 60,
}

GameCfg.Records = {
    Store = 'sefish_records_v1',
    KeyPrefix = 'rec:',
    Scale = 100,
    MaxScaled = 1e9,
    MaxNameLength = 32,
    HolderFallback = '玩家%s',
    HolderCacheTtlSec = 30,
    MissCacheTtlSec = 5,
    FlushIntervalSec = 5,
    MaxRetries = 3,
    RetryDelaySec = 1,
    RequestCooldownSec = 0.2,
    Texts = {
        Format = '全服纪录：%.2f kg（%s）',
        Missing = '全服纪录：未取得数据',
        Unavailable = '全服纪录：未取得数据',
    },
}

GameCfg.BaitSpots = {
    RespawnSec = 15,
    Mesh = 'official://mesh/7000571',
    Scale = 0.3,
    Spots = {},
}

GameCfg.Quest = {
    Title = '新手任务',
    NextNotice = '任务完成，下一步：%s',
    DoneText = '新手任务完成！',
    Steps = {
        { Kind = 'PickBait', ItemId = 'worm', Need = 5, Text = '拾取 5 只蚯蚓' },
        { Kind = 'Feed', ItemId = 'worm', Need = 5, Text = '喂钓鱼佬吃 5 只蚯蚓' },
        { Kind = 'Buy', ItemId = 'starterRod', Need = 1, Text = '向钓场老板购买 1 把新手鱼竿' },
        { Kind = 'EquipBait', ItemId = 'worm', Need = 1, Text = '拾取蚯蚓，选中鱼饵栏挂饵' },
        { Kind = 'CastWater', Need = 1, Text = '水边第一次抛竿' },
        { Kind = 'Land', Need = 1, Text = '上钩后连续点击收线，将鱼钓上岸' },
        { Kind = 'DropShore', Need = 1, Text = '将活鱼放在岸上' },
        { Kind = 'Kill', Need = 1, Text = '揍它！把鱼打死！' },
        { Kind = 'Feed', Category = 'fish', Need = 1, Text = '拾取鱼获，再喂给钓鱼佬' },
    },
}

GameCfg.Story = {
    StoryId = nil,
    ReadKey = 'opening',
    Title = '钓鱼怎么这么危险啊喂！',
    StartTimeoutSec = 3,
    FallbackText = '欢迎来到钓场！钓鱼佬什么都吃，钓场老板卖鱼竿——跟着左上角的新手任务开始吧。',
    Lines = {
        '欢迎来到钓场！这里的鱼可不会乖乖束手就擒。',
        '先拾取蚯蚓、挂饵抛竿。上钩后连续收线，把活鱼钓上岸。',
        '将活鱼放在岸上，打死后拾取鱼获。喂给钓鱼佬就能换金币。',
        '钓场老板售卖鱼竿、鱼饵和武器。信物能换首领饵和下一钓鱼区的船票。',
        '跟着左上角的九步新手任务开始吧！任务本身不额外发奖励。',
    },
}

GameCfg.HookAlert = {
    DurationSec = 3,
    Text = '鱼上钩了！狂点收线',
    HighlightColor = { 255, 190, 40, 255 },
    BreathPeriodSec = 0.6,
    Sound = 'official://audio/10001',
    Volume = 100,
}

GameCfg.CastFeedback = {
    SplashDurationSec = 2.5,
    FloatSize = 56,
    FloatColor = { 255, 225, 70, 255 },
}

GameCfg.Interact = {
    Fisherman = {
        Radius = 5,
        Slack = 0.5,
        BubbleHeight = 3,
        DialogText = '我好饿啊，什么都吃！',
        BaitPrice = { worm = 1 },
    },
}

GameCfg.Shop = {
    Stands = {
        { AnchorName = 'TGUnitShop', Level = 1 },
        { AnchorName = 'TGUnitShopShrimp', Level = 2 },
        { AnchorName = 'Z3_Shop', Level = 3 },
        { AnchorName = 'Z4_Shop', Level = 4 },
        { AnchorName = 'Z5_Shop', Level = 5 },
        { AnchorName = 'Z6_Shop', Level = 6 },
        { AnchorName = 'Z7_Shop', Level = 7 },
    },
    BubblePreset = 'map://preset/uf5ad80a4c6a40d59b7f6e0eb99a58c0',
    BubbleHeight = 7,
    HintText = '看看有什么可买的',
    Radius = 5,
    Slack = 0.5,
    Pages = ContentShop.Pages,
    Goods = {},
}

for _, row in ipairs(ContentShop.Goods) do
    GameCfg.Shop.Goods[#GameCfg.Shop.Goods + 1] = {
        Number = row.number,
        ItemId = row.itemKey,
        Name = row.itemName,
        Desc = row.description,
        Price = row.price,
        Page = row.page,
        MinShopLevel = row.minShopLevel,
        PurchaseLimit = row.purchaseLimit,
        Upgrade = row.upgrade,
        source = row.source,
    }
end

GameCfg.Shop.UpgradeKinds = {}
for _, row in ipairs(ContentShop.Goods) do
    local upgrade = row.upgrade
    if upgrade then
        local kind = GameCfg.Shop.UpgradeKinds[upgrade.kind]
        if not kind then
            kind = { Increment = upgrade.increment, MaxLevel = 0,
                RoundUp = upgrade.roundUp == true, Prices = {} }
            GameCfg.Shop.UpgradeKinds[upgrade.kind] = kind
        end
        kind.MaxLevel = math.max(kind.MaxLevel, upgrade.level)
        kind.Prices[upgrade.level] = row.price
    end
end

function GameCfg.Shop.list_for_page(level, page, includeLocked)
    local rows = {}
    if type(level) ~= 'number' or type(page) ~= 'string' then return rows end
    for _, row in ipairs(GameCfg.Shop.Goods) do
        if row.Page == page and (includeLocked or row.MinShopLevel <= level) then rows[#rows + 1] = row end
    end
    table.sort(rows, function(a, b)
        local aNew = a.MinShopLevel == level and 0 or 1
        local bNew = b.MinShopLevel == level and 0 or 1
        if aNew ~= bNew then return aNew < bNew end
        return a.Number < b.Number
    end)
    return rows
end

function GameCfg.Shop.damage_scale(kind, level)
    local spec = GameCfg.Shop.UpgradeKinds[kind]
    if not spec or not spec.Increment or spec.RoundUp or type(level) ~= 'number' then return nil end
    level = math.max(0, math.min(spec.MaxLevel, math.floor(level)))
    return 1 + spec.Increment * level
end

function GameCfg.Shop.magazine_size(base, level)
    local spec = GameCfg.Shop.UpgradeKinds.magazine
    if type(base) ~= 'number' or base ~= base or not spec then return nil end
    level = math.max(0, math.min(spec.MaxLevel, math.floor(level or 0)))
    return math.ceil(base * (1 + spec.Increment * level))
end

GameCfg.Content = { Shop = ContentShop, Lottery = ContentLottery, Blindbox = ContentBlindbox }
GameCfg.Content.Exchanges = {
    { ZoneId = 'fishPond', EliteFish = 'eel', EliteToken = 'eelHead', BossBait = 'duck', BossFish = 'alligatorGar', BossToken = 'garHead', Result = 'shrimpTicket', source = 'GameSpec.md#8.1-鱼塘' },
    { ZoneId = 'shrimpPond', EliteFish = 'fish15Elite', EliteToken = 'item31', BossBait = 'item121', BossFish = 'fish16Boss', BossToken = 'item32', Result = 'item147', source = 'GameSpec.md#8.1-虾池' },
    { ZoneId = 'crabLake', EliteFish = 'fish23Elite', EliteToken = 'item47', BossBait = 'item122', BossFish = 'fish24Boss', BossToken = 'item48', Result = 'item148', source = 'GameSpec.md#8.1-蟹湖' },
    { ZoneId = 'forestIsland', EliteFish = 'fish31Elite', EliteToken = 'item63', BossBait = 'item123', BossFish = 'fish32Boss', BossToken = 'item64', Result = 'item149', source = 'GameSpec.md#8.1-树林岛' },
    { ZoneId = 'beachIsland', EliteFish = 'fish39Elite', EliteToken = 'item79', BossBait = 'item124', BossFish = 'fish40Boss', BossToken = 'item80', Result = 'item150', source = 'GameSpec.md#8.1-沙滩岛' },
    { ZoneId = 'reefIsland', EliteFish = 'fish47Elite', EliteToken = 'item95', BossBait = 'item125', BossFish = 'fish48Boss', BossToken = 'item96', Result = 'item151', source = 'GameSpec.md#8.1-礁石岛' },
    { ZoneId = 'volcanoIsland', EliteFish = 'fish55Elite', EliteToken = 'item111', BossBait = 'item126', BossFish = 'fish56Boss', BossToken = 'item112', Result = 'achievement.final', source = 'GameSpec.md#8.1-火山岛' },
}
GameCfg.Items.CookedFlag = 'cooked'
GameCfg.Items.CookedPriceScale = 1.5
function GameCfg.Items.cook_rate(entry)
    if type(entry) ~= 'table' then return nil end
    local rate = entry.cooked
    if type(rate) ~= 'number' and type(entry.saved) == 'table' then
        rate = entry.saved.k
        if type(rate) ~= 'number' and entry.saved[GameCfg.Items.CookedFlag] == true then
            rate = GameCfg.Items.CookedPriceScale
        end
    end
    if type(rate) ~= 'number' or rate <= 0 or rate ~= rate or rate >= math.huge then return nil end
    return rate
end
function GameCfg.Items.sale_price(itemId, mult, cooked)
    local rate = cooked == true and GameCfg.Items.CookedPriceScale
        or type(cooked) == 'number' and cooked or nil
    local species = type(itemId) == 'string' and GameCfg.Fish[itemId]
    if species then
        return rate and FishCatch.cooked_price(species, mult, rate) or FishCatch.Price(species, mult)
    end
    local definition = type(itemId) == 'string' and GameCfg.Items.Definitions[itemId]
    local base = definition and definition.BasePrice
    if type(base) ~= 'number' then return nil end
    local factor = type(mult) == 'number' and mult or 1
    return math.floor(base * factor * (rate or 1) + 1e-9)
end

GameCfg.Achievements = {
    final = { Name = '通关成就', PlatformId = nil, PlaceholderId = 390001 },
}
GameCfg.Compendium = { RefreshSec = 3, RootPollSec = 0.5, RequestCooldownSec = 0.2 }
GameCfg.AchievementDelivery = { RetrySec = 15 }
GameCfg.Shop.Catalog = ContentShop.Goods
GameCfg.Shop.Excluded = ContentShop.Excluded
local LotteryCfg = {}
for key, value in pairs(ContentLottery) do LotteryCfg[key] = value end
GameCfg.Lottery = LotteryCfg
GameCfg.Lottery.Radius = 5
GameCfg.Lottery.Slack = 0.5
GameCfg.Lottery.BubbleHeight = 7
GameCfg.Lottery.BubblePreset = GameCfg.Shop.BubblePreset
GameCfg.Lottery.HintText = '极品食物换大奖'
GameCfg.Lottery.RuleHintText = '抽奖规则'
GameCfg.Lottery.ActionCooldownSec = 1
GameCfg.Lottery.SpinSec = 3
GameCfg.Lottery.AxisStopIntervalSec = 0.5
GameCfg.Lottery.AxisOrder = { 'left', 'right', 'middle' }
GameCfg.Lottery.ResultTimeoutSec = 5
function GameCfg.Lottery.machine_anchors()
    local names = {}
    for _, zone in ipairs(GameCfg.Zones) do
        if zone.Scene and zone.Scene.lottery_name then names[#names + 1] = zone.Scene.lottery_name end
    end
    return names
end
local BlindboxCfg = {}
for key, value in pairs(ContentBlindbox) do BlindboxCfg[key] = value end
GameCfg.Blindbox = BlindboxCfg
GameCfg.Blindbox.ActionCooldownSec = 1
GameCfg.Blindbox.ResultTimeoutSec = 65
GameCfg.Blindbox.HintText = '盲盒'
GameCfg.Blindbox.FullNoticeText = '道具栏和背包已满：抽中的物品将落在面前地上，其他玩家可拾取'
GameCfg.Blindbox.UnavailableText = '盲盒暂未开放，请稍后再试'

-- 官方购买无订单 ID，也没有取消/失败事件，且禁止用 UserId+goodsId 自行防重。
-- 本地适配器只能关联 pending flow 并超时兜底；跨会话防重、补发与对账依赖真实平台能力。
GameCfg.Platform = {
    BeanCurrency = '金豆',
    FlowTimeoutSec = 60,
    ActionCooldownSec = 1,
    Goods = {
        blindboxSingle = { beans = 10, name = '盲盒单抽' },
        blindboxTen = { beans = 90, name = '盲盒十连' },
        reviveFull = { beans = 5, name = '满血复活' },
        adrenaline1 = { beans = 1, count = 1, name = '肾上腺素', itemId = GameCfg.Survival.AdrenalineItemId },
        adrenaline5 = { beans = 4, count = 5, name = '肾上腺素×5', itemId = GameCfg.Survival.AdrenalineItemId },
    },
    Ads = {
        revive = { name = '广告满血复活' },
    },
    UnavailableText = '平台功能暂不可用，请稍后再试',
    Share = { Enabled = false, UnavailableText = '分享功能暂未开放' },
    NotOpenText = '占位支付与广告通道未开放，请稍后再试',
    ReasonText = {
        busy = '已有一笔平台购买正在处理，请稍候',
        cancel = '已取消购买',
        fail = '购买未完成，请查看平台订单状态',
        timeout = '平台未响应，本次购买已结束',
        pending = '存档同步中，请稍后再试',
        ['not_open'] = '占位支付与广告通道未开放，请稍后再试',
    },
    OfferTitle = '购买肾上腺素',
    TestDriverTitle = '测试支付（仅调试构建）',
}

GameCfg.Platform.Placeholder = {
    Enabled = true,
    AllowInPublish = false,
    Label = '占位支付通道',
    Notice = '占位支付通道：不发放真实付费权益',
    Goods = {
        blindboxSingle = 'placeholder.goods.blindbox.single',
        blindboxTen = 'placeholder.goods.blindbox.ten',
        reviveFull = 'placeholder.goods.revive.full',
        adrenaline1 = 'placeholder.goods.adrenaline.single',
        adrenaline5 = 'placeholder.goods.adrenaline.five',
    },
    Ads = {
        revive = 'placeholder.ad.revive',
    },
    AdsLabel = '占位广告通道',
    AdsNotice = '占位广告通道：不发放真实付费权益',
    CoinGrantText = '到账 %d%s（%s）',
    CoinPage = {
        Unit = '元',
        CoinPerUnit = 100,
        Offers = {
            { key = 'coinPouch', goodsId = 'placeholder.goods.coin.pouch', name = '金币小袋', price = 6 },
            { key = 'coinBag', goodsId = 'placeholder.goods.coin.bag', name = '金币大袋', price = 30 },
        },
    },
}

GameCfg.Ferry = {
}

GameCfg.Casting = {
    Distance = 5,
    HookDelaySec = 3,
    ActionCooldownSec = 0.12,
    LandedHoldSec = 1.2,
    LandedAnimation = 'official://animation/24450',
    -- 活鱼落在玩家正前方的水平距离与离地高度（米），要在原生抓举的命中范围内（#27 接口契约）；
    -- 取 M0 抓举夹具实测能抓中的角色局部 (0, 0.5, 2)（issue #25 台账 §6.5，tmp/qa25/lift-unforced.lua）
    LandingOffset = 2,
    LandingHeight = 0.5,
    AirSourceHeight = 12,
    LineEffect = 'official://effect/5379',
    Zones = {
        WaterCircle2 = {
            { Id = 'tilapia', Bait = 0, RodLevel = 1, DrawWeight = 8 },
            { Id = 'carp', Bait = 'worm', RodLevel = 1, DrawWeight = 8 },
            { Id = 'knifeFish', Bait = 'worm', RodLevel = 1, DrawWeight = 8 },
            { Id = 'bass', Bait = 'worm', RodLevel = 1, DrawWeight = 32 },
            { Id = 'catfish', Bait = 'worm', RodLevel = 1, DrawWeight = 24 },
            { Id = 'goldfish', Bait = 'worm', RodLevel = 1, DrawWeight = 16 },
            { Id = 'eel', Bait = 'worm', RodLevel = 1, DrawWeight = 10 },
            { Id = 'item7', Bait = 0, RodLevel = 1, DrawWeight = 2 },
            { Id = 'item8', Bait = 'worm', RodLevel = 1, DrawWeight = 2 },
            { Id = 'item9', Bait = 'worm', RodLevel = 1, DrawWeight = 2 },
            { Id = 'item10', Bait = 'worm', RodLevel = 1, DrawWeight = 8 },
            { Id = 'item11', Bait = 'worm', RodLevel = 1, DrawWeight = 6 },
            { Id = 'item12', Bait = 'worm', RodLevel = 1, DrawWeight = 4 },
        },
        ['reefIsland.water'] = {
            { Id = 'item81', Bait = 0, RodLevel = 1, DrawWeight = 8 },
            { Id = 'item82', Bait = 'item118', RodLevel = 1, DrawWeight = 8 },
            { Id = 'item83', Bait = 'item118', RodLevel = 1, DrawWeight = 8 },
            { Id = 'item84', Bait = 'item118', RodLevel = 6, DrawWeight = 32 },
            { Id = 'item85', Bait = 'item118', RodLevel = 6, DrawWeight = 24 },
            { Id = 'item86', Bait = 'item118', RodLevel = 6, DrawWeight = 16 },
            { Id = 'item87', Bait = 0, RodLevel = 1, DrawWeight = 2 },
            { Id = 'item88', Bait = 'item118', RodLevel = 1, DrawWeight = 2 },
            { Id = 'item89', Bait = 'item118', RodLevel = 1, DrawWeight = 2 },
            { Id = 'item90', Bait = 'item118', RodLevel = 6, DrawWeight = 8 },
            { Id = 'item91', Bait = 'item118', RodLevel = 6, DrawWeight = 6 },
            { Id = 'item92', Bait = 'item118', RodLevel = 6, DrawWeight = 4 },
            { Id = 'fish47Elite', Bait = 'item118', RodLevel = 6, DrawWeight = 10 },
        },
        ['shrimpPond.water'] = {
            { Id = 'shrimp', Bait = 0, RodLevel = 1, DrawWeight = 8 },
            { Id = 'riverShrimp', Bait = 'sausage', RodLevel = 1, DrawWeight = 8 },
            { Id = 'crayfish', Bait = 'sausage', RodLevel = 1, DrawWeight = 8 },
            { Id = 'bostonLobster', Bait = 'sausage', RodLevel = 2, DrawWeight = 32 },
            { Id = 'aussieLobster', Bait = 'sausage', RodLevel = 2, DrawWeight = 24 },
            { Id = 'milkLobster', Bait = 'sausage', RodLevel = 2, DrawWeight = 16 },
            { Id = 'rareShrimp', Bait = 0, RodLevel = 1, DrawWeight = 2 },
            { Id = 'rareRiverShrimp', Bait = 'sausage', RodLevel = 1, DrawWeight = 2 },
            { Id = 'rareCrayfish', Bait = 'sausage', RodLevel = 1, DrawWeight = 2 },
            { Id = 'rareBostonLobster', Bait = 'sausage', RodLevel = 2, DrawWeight = 8 },
            { Id = 'rareAussieLobster', Bait = 'sausage', RodLevel = 2, DrawWeight = 6 },
            { Id = 'rareMilkLobster', Bait = 'sausage', RodLevel = 2, DrawWeight = 4 },
            { Id = 'fish15Elite', Bait = 'sausage', RodLevel = 2, DrawWeight = 10 },
        },
        ['crabLake.water'] = {
            { Id = 'item33', Bait = 0, RodLevel = 1, DrawWeight = 8 },
            { Id = 'item34', Bait = 'item115', RodLevel = 1, DrawWeight = 8 },
            { Id = 'item35', Bait = 'item115', RodLevel = 1, DrawWeight = 8 },
            { Id = 'item36', Bait = 'item115', RodLevel = 3, DrawWeight = 32 },
            { Id = 'item37', Bait = 'item115', RodLevel = 3, DrawWeight = 24 },
            { Id = 'item38', Bait = 'item115', RodLevel = 3, DrawWeight = 16 },
            { Id = 'item39', Bait = 0, RodLevel = 1, DrawWeight = 2 },
            { Id = 'item40', Bait = 'item115', RodLevel = 1, DrawWeight = 2 },
            { Id = 'item41', Bait = 'item115', RodLevel = 1, DrawWeight = 2 },
            { Id = 'item42', Bait = 'item115', RodLevel = 3, DrawWeight = 8 },
            { Id = 'item43', Bait = 'item115', RodLevel = 3, DrawWeight = 6 },
            { Id = 'item44', Bait = 'item115', RodLevel = 3, DrawWeight = 4 },
            { Id = 'fish23Elite', Bait = 'item115', RodLevel = 3, DrawWeight = 10 },
        },
        ['forestIsland.water'] = {
            { Id = 'item49', Bait = 0, RodLevel = 1, DrawWeight = 8 },
            { Id = 'item50', Bait = 'item116', RodLevel = 1, DrawWeight = 8 },
            { Id = 'item51', Bait = 'item116', RodLevel = 1, DrawWeight = 8 },
            { Id = 'item52', Bait = 'item116', RodLevel = 4, DrawWeight = 32 },
            { Id = 'item53', Bait = 'item116', RodLevel = 4, DrawWeight = 24 },
            { Id = 'item54', Bait = 'item116', RodLevel = 4, DrawWeight = 16 },
            { Id = 'item55', Bait = 0, RodLevel = 1, DrawWeight = 2 },
            { Id = 'item56', Bait = 'item116', RodLevel = 1, DrawWeight = 2 },
            { Id = 'item57', Bait = 'item116', RodLevel = 1, DrawWeight = 2 },
            { Id = 'item58', Bait = 'item116', RodLevel = 4, DrawWeight = 8 },
            { Id = 'item59', Bait = 'item116', RodLevel = 4, DrawWeight = 6 },
            { Id = 'item60', Bait = 'item116', RodLevel = 4, DrawWeight = 4 },
            { Id = 'fish31Elite', Bait = 'item116', RodLevel = 4, DrawWeight = 10 },
        },
        ['beachIsland.water'] = {
            { Id = 'item65', Bait = 0, RodLevel = 1, DrawWeight = 8 },
            { Id = 'item66', Bait = 'item117', RodLevel = 1, DrawWeight = 8 },
            { Id = 'item67', Bait = 'item117', RodLevel = 1, DrawWeight = 8 },
            { Id = 'item68', Bait = 'item117', RodLevel = 5, DrawWeight = 32 },
            { Id = 'item69', Bait = 'item117', RodLevel = 5, DrawWeight = 24 },
            { Id = 'item70', Bait = 'item117', RodLevel = 5, DrawWeight = 16 },
            { Id = 'item71', Bait = 0, RodLevel = 1, DrawWeight = 2 },
            { Id = 'item72', Bait = 'item117', RodLevel = 1, DrawWeight = 2 },
            { Id = 'item73', Bait = 'item117', RodLevel = 1, DrawWeight = 2 },
            { Id = 'item74', Bait = 'item117', RodLevel = 5, DrawWeight = 8 },
            { Id = 'item75', Bait = 'item117', RodLevel = 5, DrawWeight = 6 },
            { Id = 'item76', Bait = 'item117', RodLevel = 5, DrawWeight = 4 },
            { Id = 'fish39Elite', Bait = 'item117', RodLevel = 5, DrawWeight = 10 },
        },
    },
    BossBait = { duck = 'alligatorGar', item121 = 'fish16Boss', item122 = 'fish24Boss', item123 = 'fish32Boss',
        item124 = 'fish40Boss', item125 = 'fish48Boss', item126 = 'fish56Boss' },
}

local sourceCastRows = {}
local bossBaitCatalog = {}
for _, species in pairs(GameCfg.Fish) do
    if species.Grade == 'boss' then
        bossBaitCatalog[species.Bait] = species.Id
    else
        local rows = sourceCastRows[species.ZoneId] or {}
        rows[#rows + 1] = { Id = species.Id, Bait = species.Bait,
            RodLevel = species.RodLevel, DrawWeight = species.DrawWeight, source = species.source }
        sourceCastRows[species.ZoneId] = rows
    end
end
for _, rows in pairs(sourceCastRows) do
    table.sort(rows, function(a, b)
        return tonumber(a.source:match('R(%d+)$')) < tonumber(b.source:match('R(%d+)$'))
    end)
end
GameCfg.Casting.Catalog = sourceCastRows
GameCfg.Casting.BossBaitCatalog = bossBaitCatalog
GameCfg.Casting.Zones['fishPond.water'] = GameCfg.Casting.Zones.WaterCircle2

GameCfg.Casting.Zones['volcanoIsland.water'] = sourceCastRows.volcanoIsland
for _, species in pairs(GameCfg.Fish) do
    if species.ZoneId == 'volcanoIsland' then
        species.Model = '7000546'
        if species.Grade == 'elite' then species.Combat = 'mosasaur' end
        if species.Grade == 'boss' then species.Combat = 'godzilla' end
    end
end

GameCfg.FishCombat = {
    shrimp = { BiteRange = 2.5, BiteCooldownSec = 2, HeadHalfAngleDeg = 90,
        ActiveSec = 15, StunSec = 5, ClawDamage = 20, TailDamage = 20, KnockHorizontal = 3, KnockUp = 1 },
    dragon = { BiteRange = 2.5, BiteCooldownSec = 1.5, HeadHalfAngleDeg = 90,
        SpecialSec = 30, RainSec = 6, RainRadius = 10, RainDamage = 50, PeckDamage = 50,
        RainEffect = 'official://preset/1850',
        DiveSec = 2, DiveHeight = 6, DiveRadius = 2.5, DiveDamage = 50, StunSec = 5 },
    gar = { BiteRange = 2.5, BiteCooldownSec = 1.5, HeadHalfAngleDeg = 90, ModelYawOffset = 0,
        Warning = { EffectPreset = 'official://preset/7190', EffectLength = 10, GroundOffset = 0.1,
            -- 官方技能包 CirclePointer 使用7191，基准半径10米；高跃整圆落点共用此预设。
            CirclePreset = 'official://preset/7191', CircleRadius = 10,
            EffectYawOffset = 0, GraceSec = 0.5 } },
    kingCrab = { BiteRange = 2.5, HeadHalfAngleDeg = 90,
        JabIntervalSec = 5, JabsPerSide = 3, JabStepSec = 0.2, JabDamage = 15,
        ActiveSec = 30, StunSec = 5 },
    crabBoss = { BiteRange = 2.5, HeadHalfAngleDeg = 90,
        PinchDamage = 20, PinchCooldownSec = 4, PinchStrikes = 2, PinchStepSec = 0.2,
        ChargeSec = 30, ChargeDamage = 20, ChargeWindowSec = 1.2, ChargeRange = 2.5,
        SpinSec = 25, SpinDurationSec = 5, SpinDamage = 30, SpinRadius = 3 },
    swordfish = { BiteRange = 2.5, HeadHalfAngleDeg = 90,
        SwingDamage = 20, SwingCooldownSec = 2,
        JumpIntervalSec = 50, JumpDistance = 10, JumpRadius = 5, JumpDamage = 100,
        JumpSec = 1.5, JumpHeight = 6 },
    shark = { BiteRange = 2.5, HeadHalfAngleDeg = 90,
        SweepDamage = 25, SweepCooldownSec = 3,
        RollDamage = 25,
        JumpIntervalSec = 20, JumpDistance = 15, JumpRadius = 10, JumpDamage = 200,
        JumpSec = 1.5, JumpHeight = 6 },
    walrus = { BiteRange = 2.5, HeadHalfAngleDeg = 90,
        SwingDamage = 25, SwingCooldownSec = 2,
        ChargeSec = 40, ChargeDamage = 120, ChargeDistance = 20,
        ChargeWindupSec = 1, ChargeSpeed = 20, ChargeContactRange = 2.5 },
    orca = { BiteRange = 2.5, HeadHalfAngleDeg = 90,
        ClawDamage = 30, ClawCooldownSec = 2, ClawWindupSec = 1,
        RoarSec = 10, RoarDamage = 30, RoarWindupSec = 1, RoarRange = 15,
        TailSec = 10, TailDamage = 160, TailWindupSec = 0.8, TailRadius = 4,
        JumpIntervalSec = 25, JumpDistance = 15, JumpRadius = 10, JumpDamage = 240,
        JumpSec = 1.5, JumpHeight = 6 },
}

-- 编辑器不认包内 ---@export_prefab_type 自定义预设类型；锚点壳会在 Parent=World 时提前执行。
-- change-asset-value 不覆盖壳内已声明属性；AnchorAttributes 须在挂接前 SetAttribute（含 melee_hit 的 Duration > 0）。
-- data/OfficialAsset.lua 的 motion 段 ID 不是运行时 ID（同名「钓鱼」那里是 20880，运行时是 24450），不要从那里取。
local AttackAnim = {
    Fist = 'official://animation/24318',
    Knuckle = 'official://animation/24315',
    Dagger = 'official://animation/24287',
    Axe = 'official://animation/24358',
    Pistol = 'official://animation/24322',
    Rifle = 'official://animation/24323',
    Auto = 'official://animation/24324',
    Rocket = 'official://animation/24325',
    Throw = 'official://animation/26646',    -- 攻击（目录里的投掷类 25860、26649–26651 运行时加载长度为 0，试玩实测不播）
}
GameCfg.Ability = {
    ManagerPreset = "map://preset/ubdb4a7e737d4eddb87729e9055ba375",
    -- 每次放电 = 一次技能施法（复用挥砍预设，CastSec 是单次施法窗口，须小于放电间隔，否则下一次会被 InCast 拒绝）；
    FishAbilities = {
        eel = {
            AssetId = "map://preset/ucc31d1999a543a7ab329eff1fd3c00d",
            Index = 0,
            Anchor = "map://preset/u471a1004c1f43f1ae6ebe4ee2bcd080",
            AnchorBehavior = "eel_discharge",
            Radius = 5,
            Damage = 10,
            DischargeCount = 5,
            DischargeIntervalSec = 1,
            CastSec = 0.5,
            SleepSec = 10,
            SleepRollRadians = math.pi / 2,
            FlailRadians = 0.45,
            FlailHz = 8,
        },
    },
    InitialAbilities = {
        {
            AssetId = "map://preset/ucc31d1999a543a7ab329eff1fd3c00d",
            Index = 0,
            Anchor = "map://preset/u471a1004c1f43f1ae6ebe4ee2bcd080",
            AnchorBehavior = "melee_hit",
            CdSec = 0,
            CastSec = 0.3,
            AnchorAttributes = {
                Duration = 0.3,
                ABILITY_ANOSTATE_HITBOX_OFFSET = { x = 0, y = 1, z = 2 },
                ABILITY_ANOSTATE_HITBOX_SCALE = { x = 3, y = 2, z = 3 },
                ABILITY_ANOSTATE_BULLET_DAMAGE = 25.0,
                ABILITY_ANOSTATE_HITPOWER = 0.0,
            },
        },
    },
    Unarmed = { Damage = 5, IntervalSec = 0.5, Range = 2, Anim = AttackAnim.Fist },
    MeleeWeapons = {
        item134 = { Damage = 10, IntervalSec = 0.5, Range = 2, Anim = AttackAnim.Knuckle },
        item135 = { Damage = 15, IntervalSec = 0.5, Range = 3, Anim = AttackAnim.Dagger },
        item136 = { Damage = 40, IntervalSec = 1.0, Range = 4, Anim = AttackAnim.Axe },
        item152 = { Damage = 15, IntervalSec = 0.5, Range = 3, Anim = AttackAnim.Dagger,
                    Effect = { Kind = 'poison' } },
        item153 = { Damage = 18, IntervalSec = 0.5, Range = 3, Anim = AttackAnim.Dagger },
        item154 = { Damage = 18, IntervalSec = 0.5, Range = 3, Anim = AttackAnim.Dagger },
        item155 = { Damage = 18, IntervalSec = 0.5, Range = 3, Anim = AttackAnim.Dagger },
        item156 = { Damage = 18, IntervalSec = 0.5, Range = 3, Anim = AttackAnim.Dagger },
        item157 = { Damage = 52, IntervalSec = 1.0, Range = 4, Anim = AttackAnim.Axe },
        item158 = { Damage = 52, IntervalSec = 1.0, Range = 4, Anim = AttackAnim.Axe },
        item159 = { Damage = 40, IntervalSec = 1.0, Range = 4, Anim = AttackAnim.Axe,
                    Effect = { Kind = 'burn' } },
        item160 = { Damage = 60, IntervalSec = 1.0, Range = 4, Anim = AttackAnim.Axe },
        item161 = { Damage = 68, IntervalSec = 1.0, Range = 4, Anim = AttackAnim.Axe },
    },
    AiTarget = { PriorityMode = 1 },
    GunShared = { ReloadSec = 2, Range = 30, ActionCooldownSec = 0.1 },
    Guns = {
        item137 = { Damage = 10, IntervalSec = 1.0, Magazine = 10, Anim = AttackAnim.Pistol },
        item138 = { Damage = 20, Pellets = 5, IntervalSec = 1.5, Magazine = 2, Anim = AttackAnim.Rifle },
        item139 = { Damage = 13, IntervalSec = 0.15, Magazine = 30, Auto = true, Anim = AttackAnim.Auto },
        item140 = { Damage = 20, IntervalSec = 0.2, Magazine = 30, Auto = true, Anim = AttackAnim.Auto },
        item141 = { Damage = 200, IntervalSec = 1.5, Magazine = 5, Anim = AttackAnim.Rifle },
        item142 = { Damage = 500, IntervalSec = 2.0, Magazine = 1, Anim = AttackAnim.Rocket,
                    Splash = { Damage = 100, Radius = 5 } },
        item162 = { Damage = 15, IntervalSec = 1.0, Magazine = 15, Anim = AttackAnim.Pistol },
        item163 = { Damage = 10, IntervalSec = 1.0, Magazine = 10, Anim = AttackAnim.Pistol,
                    Effect = { Kind = 'frost' } },
        item164 = { Damage = 10, IntervalSec = 1.0, Magazine = 10, Anim = AttackAnim.Pistol,
                    Effect = { Kind = 'paralyze' } },
        item165 = { Damage = 30, IntervalSec = 0.2, Magazine = 30, Auto = true, Anim = AttackAnim.Auto },
        item166 = { Damage = 500, IntervalSec = 1.0, Magazine = 10, Auto = true, Anim = AttackAnim.Rocket,
                    Splash = { Damage = 100, Radius = 5 } },
    },
    ModifierPresets = {
        poison = 'map://preset/u9e43507fb284064a1e74f5f803eb121',
        burn = 'map://preset/u48318ffad0d437b91ce40317261af23',
        frost = 'map://preset/u082e5229ff6481484d21b70d55d3088',
        paralyze = 'map://preset/ud998c96a7da4f148825cc0b76ee525b',
        weak = 'map://preset/uc03ba59d2344d85985be11d0a7af2d6',
    },
    StatusEffects = {
        poison = { MaxStacks = 5, TickSec = 1, DamagePerStack = 1, DurationSec = 3 },
        burn = { MaxStacks = 5, TickSec = 1, DamagePerStack = 4, DurationSec = 3 },
        frost = { SlowPercent = 30, DurationSec = 3, Stackable = false },
        paralyze = { DurationSec = 0.5, Stackable = false },
    },
    SpeedPotion = { Item = 'item167', StepPercent = 10, MaxPotions = 20, MaxFactor = 3 },
    -- 角色基础移速：BaseController 默认 WalkSpeed 7.0（editor-cli manual BaseController.mdx 已核实）；
    -- 运行时以角色入图时捕获的控制器速度为准（MgrAbility:capture_base_speed），此值仅为兜底。
    MoveSpeed = { Base = 7 },
    Explosives = {
        item143 = { Damage = 50 },
        item144 = { Damage = 100 },
        item145 = { Damage = 150 },
    },
    Throw = {
        Range = 20,
        ExplosionRadius = 5,
        FishMin = 3, FishMax = 5,
        FishRodLevel = 1,
        FishTtlSec = 60,
        FlightSec = 0.8,
        ArcHeight = 3,
        LongPressSec = 0.35,
        Anim = AttackAnim.Throw,
    },
    BodyScale = {
        Base = 1, Step = 0.2, Max = 3, MaxPotions = 10,
        HealthBase = 300, HealthStepPercent = 20, HealthMax = 900,
        CapsuleHeight = 2, CameraDistance = 13, InteractRange = 2,
        PotionItem = 'item168',
    },
    Flight = {
        MaxHeight = 20, MaxStepSec = 0.25, DriftTolerance = 4,
        Speed = 20,
        CruiseHeight = 12,
        DiveSpeed = 30,
        ClimbSpeed = 8,
        DiveSec = 3,
        DiveIntervalSec = 20,
        DiveDamage = 30,
        LeapHeight = 8,
        LeapSec = 1.5,
        AggroRange = 60,
        DiveRadius = 5,
        ReefDiveWarnSec = 1, ReefDiveSec = 0.8,
        ThrowFlightSec = 1.2,
        ThrowMesh = 'official://mesh/7000546',
        Species = {
            fish47Elite = { CruiseHeight = 12, DiveIntervalSec = 20, DiveDamage = 30 },
            fish48Boss = { CruiseHeight = 15, DiveIntervalSec = 20, DiveDamage = 260,
                ThrowIntervalSec = 4, ThrowRadius = 5, ThrowDamage = 100 },
            fish55Elite = { Mode = 'leap', CruiseHeight = 0, DiveIntervalSec = 15, DiveDamage = 100 },
        },
        FallbackBounds = nil,
    },
    Carry = {
        Socket = 'LiftSocket',
        Offset = { x = 0, y = 1.6, z = 2.0 },
        HostHalfHeight = 1.2,
        CarriedHalfHeight = 1.0,
        GrabRange = 2.5,
        GrabDamage = 300,
        FollowTolerance = 3,
        DropHeight = 1.5, DropForward = 2,
        MaxCarrySec = 20,
        ContactIntervalSec = 1, ContactDamage = 150,
        FallDamage = 0,
    },
    Aquatic = {
        LeapIntervalSec = BossMoves.get('mosasaur', 'leap').Schedule.Sec,
        LeapWindupSec = 1, LeapSec = 1.5, LeapHeight = 8,
        LeapRadius = BossMoves.get('mosasaur', 'leap').Range,
        LeapDamage = BossMoves.get('mosasaur', 'leap').Damage.Value,
        HeadRadius = BossMoves.get('mosasaur', 'head').Range,
        HeadWindupSec = BossMoves.get('mosasaur', 'head').Warning.WindupSec,
        HeadDamage = BossMoves.get('mosasaur', 'head').Damage.Value,
        GrabDamage = BossMoves.get('mosasaur', 'bite').Damage.Value,
        ContactDamage = BossMoves.get('mosasaur', 'contact').Damage.Value,
        ContactRange = BossMoves.get('mosasaur', 'contact').Range,
    },
    BossPhase = {
        Thresholds = BossMoves.Phases.godzilla.Thresholds,
        AttackSets = BossMoves.Phases.godzilla.AttackSets,
        Attacks = BossMoves.attack_table('godzilla'),
        Species = { fish56Boss = true },
        Chase = { BiteRange = 4, BiteCooldownSec = 2 },
    },
    SpecialItem = {
        Items = { item169 = 'wings', item170 = 'godzilla' },
        ReLimitSec = 0.1,
        Wings = {
            ClimbSpeed = 8,
            DescendSpeed = 3,
            MaxStepSec = 0.25,
            LandEpsilon = 0.05,
            AppearanceAssetId = nil,
            Socket = 'Spine',
            Offset = { x = 0, y = 0, z = 0 },
        },
        Godzilla = {
            AppearanceAssetId = nil,
            Breath = {
                DurationSec = 3, Range = 30, TotalDamage = 1000,
                TickSec = 0.25,
                Width = 3,
                CooldownSec = 20,
            },
        },
    },
}

-- 判定语义见 common/math_water_judge.lua。标记 Position.y 是底面，水面 SurfaceY = Position.y + Size.y；
-- 运行时 Size 已含 Scale，半宽直接取 Size/2（#12 W-4、#31 实测）。
GameCfg.Water = { Zones = {}, ZoneIdByWater = {}, ContentWaterIds = {} }

GameCfg.Ferry.Routes = {}
local ferryLegGeometry = { BoatRange = 6, Radius = 5, Slack = 0.5, BubbleHeight = 6 }
local returnPrices = { 10, 30, 90, 270, 810, 2430 }
for index = 1, 6 do
    local from, to = GameCfg.Zones[index], GameCfg.Zones[index + 1]
    local outbound = { AnchorName = index == 1 and 'FerryBoat' or ('Z' .. index .. '_FerryOut'),
        Ticket = GameCfg.Content.Exchanges[index].Result, CountdownSec = 5, Zone = to.Id }
    local back = { AnchorName = index == 1 and 'FerryReturn' or ('Z' .. (index + 1) .. '_FerryReturn'),
        Price = returnPrices[index], Zone = from.Id }
    for key, value in pairs(ferryLegGeometry) do outbound[key], back[key] = value, value end
    GameCfg.Ferry.Routes[index] = { Id = from.Id .. '>' .. to.Id,
        FromZoneId = from.Id, ToZoneId = to.Id, Outbound = outbound, Return = back }
end
GameCfg.Ferry.HomeZone = GameCfg.Zones[1].Id
GameCfg.Ferry.Outbound = GameCfg.Ferry.Routes[1].Outbound
GameCfg.Ferry.Return = GameCfg.Ferry.Routes[1].Return
function GameCfg.Ferry.route(routeId)
    if type(routeId) ~= 'string' then return nil end
    for _, route in ipairs(GameCfg.Ferry.Routes) do
        if route.Id == routeId then return route end
    end
end

GameCfg.Interact.Fishermen = {}
for index, chain in ipairs(GameCfg.Content.Exchanges) do
    local zone = GameCfg.Zones[index]
    local fishermanName = index == 1 and 'TGUnitFish' or index == 2 and 'TGUnitFishShrimp' or ('Z' .. index .. '_Fisherman')
    GameCfg.Interact.Fishermen[index] = {
        ZoneId = zone.Id, AnchorNames = { fishermanName },
        ModelName = index == 1 and 'FishermanModel' or ('Z' .. index .. '_FishermanModel'),
        Exchange = { [chain.EliteToken] = chain.BossBait, [chain.BossToken] = chain.Result }, Chain = index,
    }
end

GameCfg.Grill = {
    Radius = 2, Slack = 0.5, BubbleHeight = 2.5, RiseSec = 2, HoldSec = 0.5, FallSec = 2,
    MaxRate = 1.5, BurnSec = 4.5, BurnDamage = 30, BurnRadius = 3, BubbleText = '烧烤',
    NoFishText = '你没有可烤的鱼', BurntText = '你的鱼烤糊了！', CookedPrefix = '烤',
    TokenWarnText = '信物烤制后将失去兑换和抽奖资格，再次点击确认烤制',
    FullText = '背包已满，烤好的鱼先留在烤炉上', TakeoutText = '取出',
    source = '策划案--渔力全开.docx#烧烤',
}
GameCfg.Grill.Points = {}
for index = 3, #GameCfg.Zones do
    GameCfg.Grill.Points[#GameCfg.Grill.Points + 1] = {
        ZoneId = GameCfg.Zones[index].Id, AnchorName = 'Z' .. index .. '_Grill',
    }
end

GameCfg.HighFreqInput = {
    WindowSec = 1.0,
    MaxCount = 10,
    AggregateSec = 0.1,
}
GameCfg.ReelIn = {
    Initial = 50,
    DecayPerSec = 5,
    ClickGain = 5,
    GraceSec = 0.18,
    Tolerance = 5,
    ChaseSec = 0.18,
    PendingTimeoutSec = 1,
}

-- RenderMeshId 的写法：**official://mesh/<模型号>**；PhysicsMeshId 创建时可省略，缺省就取 RenderMeshId
--   反面样例：official://preset/9000092 也能建出来，但那是空壳（Size=(1,1,1)、无几何）——
--   别拿预设号当 mesh id。
GameCfg.FishCarrier = {
    Models = {
        ["7000544"] = { Name = "大马哈鱼", Mesh = "official://mesh/7000544", Preset = "official://preset/9000092" },
        ["7000545"] = { Name = "旗鱼",    Mesh = "official://mesh/7000545", Preset = "official://preset/9000093" },
        ["7000546"] = { Name = "鲨鱼",    Mesh = "official://mesh/7000546", Preset = "official://preset/9000094" },
        ["7000547"] = { Name = "鳐鱼",    Mesh = "official://mesh/7000547", Preset = "official://preset/9000095" },
        ["7000548"] = { Name = "彩圆儿",  Mesh = "official://mesh/7000548", Preset = "official://preset/9000096" },
        ["7000549"] = { Name = "蝴蝶鱼",  Mesh = "official://mesh/7000549", Preset = "official://preset/9000097" },
        ["7000550"] = { Name = "海龟",    Mesh = "official://mesh/7000550", Preset = "official://preset/9000098" },
        ["7000551"] = { Name = "黑鱼",    Mesh = "official://mesh/7000551", Preset = "official://preset/9000099" },
        ["7000552"] = { Name = "锦鲤",    Mesh = "official://mesh/7000552", Preset = "official://preset/9000110" },
        ["7000553"] = { Name = "鲶鱼",    Mesh = "official://mesh/7000553", Preset = "official://preset/9000111" },
        ["7000554"] = { Name = "螃蟹",    Mesh = "official://mesh/7000554", Preset = "official://preset/9000112" },
        ["7000555"] = { Name = "七彩鱼",  Mesh = "official://mesh/7000555", Preset = "official://preset/9000113" },
        ["7000556"] = { Name = "三文鱼",  Mesh = "official://mesh/7000556", Preset = "official://preset/9000114" },
        ["7000557"] = { Name = "鳊鱼",    Mesh = "official://mesh/7000557", Preset = "official://preset/9000115" },
        ["7000558"] = { Name = "草鱼",    Mesh = "official://mesh/7000558", Preset = "official://preset/9000116" },
        ["7000559"] = { Name = "金鱼",    Mesh = "official://mesh/7000559", Preset = "official://preset/9000117" },
        ["7000560"] = { Name = "鲫鱼",    Mesh = "official://mesh/7000560", Preset = "official://preset/9000118" },
        ["7000561"] = { Name = "兰寿",    Mesh = "official://mesh/7000561", Preset = "official://preset/9000119" },
        ["7000562"] = { Name = "食人鱼",  Mesh = "official://mesh/7000562", Preset = "official://preset/9000120" },
        ["7000563"] = { Name = "小丑鱼",  Mesh = "official://mesh/7000563", Preset = "official://preset/9000121" },
    },
}

GameCfg.DamageFloat = {
    DurationSec = 1,
    RisePixels = 90,
    SpreadPixels = 32,
    HeadHeight = 1.6,
    Width = 130,
    Height = 70,
    NormalFontSize = 36,
    CriticalFontSize = 48,
    NormalColor = { 255, 255, 255, 255 },
    CriticalColor = { 255, 185, 45, 255 },
    PoolSize = 24,
}

GameCfg.FishCombatLabel = {
    MovingRefreshSec = 0.5,
    HeadHeight = 2.4,
    Width = 640,
    Height = 90,
    FontSize = 30,
    BarCells = 10,
    AttackColor = { 255, 230, 60, 255 },
    SleepColor = { 140, 200, 255, 255 },
    IdleColor = { 255, 255, 255, 255 },
}

GameCfg.PlaceholderAssets = require('common.cfg.placeholder_assets')
GameCfg.PlaceholderAssets.apply(GameCfg)

return GameCfg
