-- 平台适配管理器（#147 T26，GameSpec §7/§11/§15，docs/技术难点识别.md §4）：
-- 商品购买（金豆价目）与激励广告的唯一服务端入口，业务（盲盒 / 满血复活 / 肾上腺素）只依赖本模块。
-- 真实商品 ID / 广告标签 / 金币汇率是商业化后台交付参数（#148）：未交付时一切购买入口明确不可用、
-- 不发付费权益；Debug 开关打开时同一路径转为「pending flow + 测试驱动器（PlatformTestAction）结算」，
-- 生产构建（GameCfg.Debug.Enabled=false）测试驱动器整体拒绝，不存在伪造支付成功的入口。
-- #261 占位支付通道（ADR-0029 第三、四节）：真实商品 ID / 金币汇率未交付期间，同一适配层按共享配置
-- GameCfg.Platform.Placeholder 建「占位 flow」，由客户端占位确认结算，把金币页购买与地图盲盒的完整路径走通；
-- 占位路径不调用真实平台、不发真实付费权益，真实通道（无可信订单身份）继续关闭。真实参数到位只换配置。
-- #262 占位广告位同理：真实广告位（Platform.Ads.revive 的 goodsId/adTag）未交付期间，广告满血复活经
-- Placeholder.Ads.revive 建同一种占位 flow，成功结算交给 MgrSurvival 的 FullRevive 发地图内资源，
-- 不发任何平台权益；真实广告位到位后只替换那行参数。
-- 已知平台边界（不宣称已解决，归 #148 真实验收）：
--   * GoodsPurchaseCompleted 只有 goodsId/goodsNum/player，没有订单 ID，官方教程禁止拼 UserId+goodsId
--     防重——缺可信交付身份时忽略真实信号，配置 goodsId 也不放行；订单适配/补发/对账归#148；
--   * 购买没有取消 / 失败事件，广告 failEvent 也不保证触发：flow 统一按 FlowTimeoutSec 超时兜底结算；
--   * ShowGoodsPurchasePanel 的 showTime 语义未查证，调用不传；广告成功以平台发放商品奖励
--     （同一 GoodsPurchaseCompleted 信号）为准，真实事件名接线未查证。
local GameCfg = require('common.GameCfg')

local Mgr = { Flows = {}, GrantSeq = {}, CoinSeq = {}, PendingGrants = {}, NextFlowId = 0 }

local function cfg()
    return GameCfg.Platform
end

function Mgr:Now()
    self.World = self.World or game:GetService('World')
    return self.World:GetServerTime()
end

function Mgr:Reply(player, payload)
    _G.REUtil:GetRE('PlatformResult'):FireClient(player, payload)
end

local function service(name)
    local ok, svc = pcall(function() return game:GetService(name) end)
    return ok and svc or nil
end

local function debugEnabled()
    return GameCfg.Debug and GameCfg.Debug.Enabled == true
end

-- 商品行已交付后台 ID 才可用真实购买
local function configured(row)
    return type(row) == 'table' and type(row.goodsId) == 'string' and row.goodsId ~= ''
end

-- #261 占位参数是共享配置里的一张表（生产开关）：真实商品 ID / 汇率交付后只替换它，判定不动。
local function placeholder()
    local config = cfg().Placeholder
    return type(config) == 'table' and config or nil
end

local function placeholderEnabled()
    local config = placeholder()
    return config ~= nil and config.Enabled == true
end

-- 金币页报价行：占位汇率与占位商品 ID 都在这张表里
local function coinOffer(key)
    local config = placeholder()
    local page = config and config.CoinPage
    local offers = type(page) == 'table' and page.Offers or nil
    if type(offers) ~= 'table' or type(key) ~= 'string' then return nil end
    for _, offer in ipairs(offers) do
        if offer.key == key then return offer end
    end
end

-- 到账金币 = 单价 × 占位汇率；汇率换成真值只改配置，这一行不动
local function coinAmount(offer)
    local config = placeholder()
    local unit = config and config.CoinPage and config.CoinPage.CoinPerUnit
    if type(offer) ~= 'table' or type(offer.price) ~= 'number' then return nil end
    if type(unit) ~= 'number' or unit <= 0 then return nil end
    return math.floor(offer.price * unit + 0.5)
end

-- 占位商品 ID：goods / ad / coin 三类键各查各的表；未配置返回 nil（占位通道也不放行）
local function placeholderGoodsId(kind, key)
    local config = placeholder()
    if not config or type(key) ~= 'string' then return nil end
    local id
    if kind == 'coin' then
        local offer = coinOffer(key)
        id = offer and offer.goodsId
    else
        local ids = kind == 'ad' and config.Ads or config.Goods
        id = type(ids) == 'table' and ids[key] or nil
    end
    if type(id) ~= 'string' or id == '' then return nil end
    return id
end

function Mgr:HasFlow(player)
    local flow = player and self.Flows[player.UserId]
    return flow ~= nil and flow.player == player
end

-- 结算在飞 flow：清空后回调 onResult(outcome, payload)，回调报错只记日志
-- 测试 flow（Debug 构建、未走真实平台）开 / 关时通知客户端显示或收起测试驱动按钮；
-- 生产构建不会建测试 flow，所以这条通知在生产不出现
local function notifyTestFlow(mgr, player, flow, open)
    if flow.real then return end
    local ok, err = pcall(mgr.Reply, mgr, player, { ok = true, action = 'TestFlow', open = open,
        kind = flow.kind, key = flow.goods or flow.ad, purpose = flow.purpose })
    if not ok then print('[MgrPlatform] 测试 flow 通知失败', player.UserId, tostring(err)) end
end

-- 占位通道开 / 关时通知客户端显示或收起占位确认面板（生产构建的唯一购买面）
local function notifyPlaceholder(mgr, player, flow, open)
    local config = placeholder() or {}
    local page = config.CoinPage or {}
    local offer = flow.kind == 'coin' and coinOffer(flow.coin) or nil
    local row = flow.goods and cfg().Goods[flow.goods] or nil
    -- #262 广告通道有自己的「不发放真实付费权益」提示：占位支付与占位广告各说各的通道
    local adRow = flow.kind == 'ad' and flow.ad and cfg().Ads[flow.ad] or nil
    local ok, err = pcall(mgr.Reply, mgr, player, {
        ok = true, action = 'PlaceholderFlow', open = open, kind = flow.kind,
        key = offer and offer.key or flow.goods or flow.ad, goodsId = flow.goodsId,
        purpose = flow.purpose,
        name = (offer and offer.name) or (row and row.name) or (adRow and adRow.name),
        beans = row and row.beans,
        price = offer and offer.price,
        coin = offer and coinAmount(offer),
        currency = (offer and page.Unit) or (row and cfg().BeanCurrency),
        notice = (flow.kind == 'ad' and config.AdsNotice) or config.Notice,
    })
    if not ok then print('[MgrPlatform] 占位通道通知失败', player.UserId, tostring(err)) end
end

local function notifyFlow(mgr, player, flow, open)
    if flow.placeholder then return notifyPlaceholder(mgr, player, flow, open) end
    return notifyTestFlow(mgr, player, flow, open)
end

local function resolve(mgr, player, flow, outcome, payload)
    if mgr.Flows[player.UserId] == flow then mgr.Flows[player.UserId] = nil end
    notifyFlow(mgr, player, flow, false)
    print('[MgrPlatform] flow 结算', player.UserId, flow.kind, tostring(flow.goods or flow.ad), outcome)
    if type(flow.onResult) == 'function' then
        local ok, err = pcall(flow.onResult, outcome, payload)
        if not ok then print('[MgrPlatform] flow 回调失败', player.UserId, tostring(err)) end
    end
end

-- 这件商品当前有没有可结算的通道：调试构建看测试 flow，生产构建看占位通道
function Mgr:CanPurchase(player, goodsKey)
    if type(cfg().Goods[goodsKey]) ~= 'table' then return false, 'invalid' end
    if debugEnabled() then return true end
    -- 生产构建：真实通道仍关闭（无可信订单/交付身份），占位通道按共享配置放行
    if placeholderEnabled() and placeholderGoodsId('goods', goodsKey) then return true end
    return false, 'unavailable'
end

-- intent = { kind='purchase', goods=key } / { kind='ad', ad=key } / { kind='coin', coin=key }；
-- onResult(outcome, payload)。流程分三类：调试构建建测试 flow（测试驱动器结算）、
-- 生产构建建占位 flow（占位确认结算，不发真实付费权益）、真实通道（无可信交付身份）继续关闭。
local function openFlow(self, player, intent, onResult)
    if not player or not player.UserId then return false, 'invalid' end
    if self:HasFlow(player) then return false, 'busy' end
    local key = intent.kind == 'coin' and intent.coin or (intent.kind == 'ad' and intent.ad or intent.goods)
    local row = intent.kind == 'coin' and coinOffer(key)
        or (intent.kind == 'ad' and cfg().Ads[key] or cfg().Goods[key])
    if type(row) ~= 'table' then return false, 'invalid' end
    local label, goodsId
    if debugEnabled() then
        label = '测试' -- 本地测试 flow 永不调用真实平台
    elseif placeholderEnabled() then
        -- #148 尚无可信订单/交付身份：真实通道关闭，只有共享配置里的占位商品 ID 能开通道
        goodsId = placeholderGoodsId(intent.kind, key)
        if not goodsId then return false, 'unavailable' end
        label = '占位'
    else
        return false, 'unavailable'
    end
    self.NextFlowId = self.NextFlowId + 1
    local now = self:Now()
    local flow = { id = self.NextFlowId, player = player, kind = intent.kind, goods = intent.goods,
        ad = intent.ad, coin = intent.coin, purpose = intent.purpose, goodsId = goodsId, real = nil,
        placeholder = label == '占位', onResult = onResult, startedAt = now,
        deadline = now + cfg().FlowTimeoutSec }
    self.Flows[player.UserId] = flow
    print('[MgrPlatform] flow 建立', player.UserId, intent.kind, tostring(key), label,
        'flow=' .. tostring(flow.id))
    notifyFlow(self, player, flow, true)
    return true
end

-- 购买一件商品；onResult('success', { goodsId, num }) 或 ('cancel'/'fail'/'timeout')
function Mgr:Purchase(player, goodsKey, purpose, onResult)
    return openFlow(self, player, { kind = 'purchase', goods = goodsKey, purpose = purpose }, onResult)
end

-- 播放激励广告；onResult 口径同上（成功载荷来自平台发放的商品奖励信号）
function Mgr:ShowAd(player, adKey, purpose, onResult)
    return openFlow(self, player, { kind = 'ad', ad = adKey, purpose = purpose }, onResult)
end

-- 业务主动取消（如免费复活抢先结算）：清 flow 不回调，返回是否有 flow 被清
function Mgr:CancelFlow(player)
    if not self:HasFlow(player) then return false end
    print('[MgrPlatform] flow 被业务取消', player.UserId)
    local flow = self.Flows[player.UserId]
    self.Flows[player.UserId] = nil
    notifyFlow(self, player, flow, false)
    return true
end

-- 肾上腺素购买入口（MgrSurvival 濒死无药时拉起）：两份报价由客户端选择后各自走 Purchase；
-- 未配置且非 Debug → 明确回包不可用（客户端展示「平台复活即将开放」口径）
function Mgr:OpenAdrenalineShop(player)
    local rows = cfg().Goods
    local available = debugEnabled()
    if not available then
        self:Reply(player, { ok = false, action = 'AdrenalineShop', reason = 'unavailable' })
        return false
    end
    self:Reply(player, { ok = true, action = 'AdrenalineShop', offers = {
        { key = 'adrenaline1', beans = rows.adrenaline1.beans, count = rows.adrenaline1.count,
            name = rows.adrenaline1.name },
        { key = 'adrenaline5', beans = rows.adrenaline5.beans, count = rows.adrenaline5.count,
            name = rows.adrenaline5.name },
    } })
    return true
end

-- 地图商店金币页（ScreenShop 入口）：真实汇率与真实商品 ID 未交付时，用共享配置的占位汇率与
-- 占位商品 ID 走通报价 → 购买 → 到账；占位关闭（或未配置）时明确不可用。
function Mgr:OpenCoinShop(player)
    local config = placeholder()
    local page = config and config.CoinPage
    if not placeholderEnabled() or type(page) ~= 'table' or type(page.Offers) ~= 'table' then
        self:Reply(player, { ok = false, action = 'CoinShop', reason = 'unavailable' })
        return false
    end
    local offers = {}
    for _, offer in ipairs(page.Offers) do
        offers[#offers + 1] = { key = offer.key, goodsId = offer.goodsId, name = offer.name,
            price = offer.price, coin = coinAmount(offer) }
    end
    self:Reply(player, { ok = true, action = 'CoinShop', offers = offers, rate = page.CoinPerUnit,
        currency = page.Unit, notice = config.Notice })
    return true
end

-- 金币页购买：经同一条平台流程收费，成功才到账（失败/取消/超时不到账，也不扣金币余额）
function Mgr:PurchaseCoin(player, key)
    if not coinOffer(key) then return false end
    return openFlow(self, player, { kind = 'coin', coin = key, purpose = 'coinpage' }, function(outcome)
        if outcome == 'success' then return self:GrantCoin(player, key) end
        self:Reply(player, { ok = false, action = 'BuyCoin', goods = key, reason = outcome })
        return false
    end)
end

-- 金币页到账（持久操作，#123 协议）：只入账、不扣金币余额（金币页商品不参与金币扣减结算）
function Mgr:GrantCoin(player, key)
    local offer = coinOffer(key)
    local amount = coinAmount(offer)
    if not amount then return false end
    local data = self.PlayerData and self.PlayerData:GetDataInst(player)
    if not data or not self.Save then return false end
    self.CoinSeq[player.UserId] = (self.CoinSeq[player.UserId] or 0) + 1
    local operation, mode = self.Save:ResolveRequest(player, data, 'platform:coin', self.CoinSeq[player.UserId])
    if not operation then
        print('[MgrPlatform] 金币到账被拒', player.UserId, key, tostring(mode))
        self:Reply(player, { ok = false, action = 'BuyCoin', goods = key, reason = mode or 'pending' })
        return false
    end
    return self.Save:Execute(player, data, operation, function(draft)
        local before = draft.Data.FishCoin
        if not draft:AddCoin(amount, nil, 'coinpage:' .. key) then return nil, 'coin' end
        return { ok = true, goods = key, name = offer.name, coin = amount,
            coinBefore = before, coinAfter = draft.Data.FishCoin }
    end, function(written, result)
        if not written then
            print('[MgrPlatform] 金币到账未落账', player.UserId, key, tostring(result))
            self:Reply(player, { ok = false, action = 'BuyCoin', goods = key, reason = result })
            return
        end
        print('[MgrPlatform] 金币到账落账', player.UserId, key,
            'coinBefore=' .. tostring(result.coinBefore), 'coinAfter=' .. tostring(result.coinAfter))
        self:Reply(player, { ok = true, action = 'CoinGrant', goods = key, name = result.name,
            coin = result.coin, coinBefore = result.coinBefore, coinAfter = result.coinAfter })
    end)
end

-- 占位通道的确认 / 取消 / 失败：只结算占位 flow（调试驱动器结算不到它，反之亦然）。
-- #262：'fail' 是激励广告的真实结局之一（平台 failEvent 不保证触发），占位通道也要能走通失败路径
-- （ADR-0029 第三节第 2 条「成功与失败两条路径都要能走通」）；客户端确认面板只发前两种。
function Mgr:ResolvePlaceholder(player, outcome)
    if outcome ~= 'success' and outcome ~= 'cancel' and outcome ~= 'fail' then return false end
    local flow = player and self.Flows[player.UserId]
    if not flow or flow.player ~= player or not flow.placeholder then return false end
    resolve(self, player, flow, outcome, { placeholder = true })
    return true
end

-- 占格商品测试发货（持久操作，#123 协议）；真实信号不进入此路径。
function Mgr:GrantGoods(player, goodsKey, num)
    local row = cfg().Goods[goodsKey]
    if not row or not row.itemId then return false end
    local data = self.PlayerData and self.PlayerData:GetDataInst(player)
    if not data or not self.Save then return false end
    self.GrantSeq[player.UserId] = (self.GrantSeq[player.UserId] or 0) + 1
    local operation, mode = self.Save:ResolveRequest(player, data, 'platform:grant',
        self.GrantSeq[player.UserId])
    if not operation then
        if mode == 'pending' then
            local queue = self.PendingGrants[player.UserId]
            if not queue or queue.player ~= player then
                queue = { player = player, jobs = {} }
                self.PendingGrants[player.UserId] = queue
            end
            queue.jobs[#queue.jobs + 1] = { goods = goodsKey, num = num }
            print('[MgrPlatform] 发货排队', player.UserId, goodsKey)
            return true
        end
        print('[MgrPlatform] 发货被拒', player.UserId, goodsKey, tostring(mode))
        return false
    end
    local total = row.count * math.max(1, num or 1)
    return self.Save:Execute(player, data, operation, function(draft)
        local granted = 0
        for _ = 1, total do
            if not draft:AddItem(row.itemId) then break end -- 空格不够发几件是几件，余下落地
            granted = granted + 1
        end
        return { ok = true, goods = goodsKey, itemId = row.itemId, total = total, granted = granted,
            overflow = total - granted }
    end, function(written, result)
        if not written then
            print('[MgrPlatform] 发货未落账', player.UserId, goodsKey, tostring(result))
            return
        end
        print('[MgrPlatform] 发货落账', player.UserId, goodsKey,
            'granted=' .. tostring(result.granted), 'overflow=' .. tostring(result.overflow))
        if self.PlayerData.SendItemBar then self.PlayerData:SendItemBar(player) end
        self:Reply(player, { ok = true, action = 'Grant', goods = goodsKey,
            granted = result.granted, overflow = result.overflow })
        -- 满格溢出落地（与盲盒同一口径，计入全区预算）；无 Loot 注入时只记日志留对账线索
        if result.overflow > 0 then
            local origin = player.Character and player.Character.Position
            for _ = 1, result.overflow do
                local spawned = self.Loot and origin
                    and self.Loot:SpawnItem(row.itemId, nil, nil,
                        { x = origin.x, y = origin.y, z = origin.z + 2 })
                if not spawned then
                    print('[MgrPlatform] 溢出落地失败（待对账）', player.UserId, row.itemId)
                end
            end
        end
    end)
end

-- 购买完成信号（真实平台回调；测试里可直接调用）：goodsId → 商品/广告行。
-- 无可信订单/flow代次，不能匹配在飞flow，也不能按未关联信号发货。
function Mgr:OnGoodsPurchaseCompleted(goodsId, num, player)
    -- 公开信号无订单身份，旧单/重复单无法与当前 flow 安全关联，保持关闭。
    print('[MgrPlatform] 缺可信交付身份，忽略真实购买信号', tostring(goodsId))
end

-- 仅测试可用的回调驱动器：生产构建整体拒绝（验收：生产不能进入测试支付成功入口）。
-- Debug 开时把 outcome（success/cancel/fail）结算到调用者当前在飞 flow。
function Mgr:HandleTestAction(player, payload)
    if not debugEnabled() then
        print('[MgrPlatform] 生产构建拒绝测试驱动器', player and player.UserId)
        return false
    end
    if type(payload) ~= 'table' or payload.action ~= 'ResolveFlow'
        or (payload.outcome ~= 'success' and payload.outcome ~= 'cancel' and payload.outcome ~= 'fail') then
        return false
    end
    local flow = player and self.Flows[player.UserId]
    -- 占位 flow 只由占位确认结算；测试驱动器碰不到它（反之亦然）
    if not flow or flow.player ~= player or flow.placeholder then return false end
    resolve(self, player, flow, payload.outcome, { driver = true })
    return true
end

-- 17-18 分享任务入口：平台分享能力未开通时给明确占位回包，不静默吞掉（点了没反应）。
-- 真实分享能力由平台侧交付后替换共享配置并接真实回调，判定不动；占位不发任何权益。
function Mgr:Share(player, purpose)
    if type(player) ~= 'table' or player.UserId == nil then return false, 'invalid' end
    local share = cfg().Share or {}
    -- 未开通（占位）与「配置已打开但真实能力还没接」都明确回不可用，不伪装成已分享。
    local reason = share.Enabled == true and 'unavailable' or 'placeholder'
    self:Reply(player, { ok = false, action = 'Share', purpose = purpose, reason = reason,
        text = share.UnavailableText })
    return false, reason
end

-- 客户端平台操作通道：打开肾上腺素 / 金币购买入口，或发起肾上腺素购买
function Mgr:HandleAction(player, payload)
    if type(payload) ~= 'table' then return false end
    if payload.action == 'OpenAdrenaline' then return self:OpenAdrenalineShop(player) end
    if payload.action == 'OpenCoinShop' then return self:OpenCoinShop(player) end
    if payload.action == 'Share' then
        self:Share(player, payload.purpose)
        return true
    end
    if payload.action == 'BuyCoin' then return self:PurchaseCoin(player, payload.goods) end
    if payload.action == 'PlaceholderOutcome' then
        return self:ResolvePlaceholder(player, payload.outcome)
    end
    if payload.action == 'Purchase' then
        local goodsKey = payload.goods
        local row = cfg().Goods[goodsKey]
        -- 客户端只能直接发起占格商品（肾上腺素）购买；盲盒/复活由对应管理器服务端发起
        if not row or not row.itemId then return false end
        return self:Purchase(player, goodsKey, 'adrenaline', function(outcome)
            if outcome == 'success' then
                self:GrantGoods(player, goodsKey, 1)
            else
                self:Reply(player, { ok = false, action = 'Purchase', goods = goodsKey, reason = outcome })
            end
        end)
    end
    return false
end

function Mgr:Update()
    local now = self:Now()
    for userId, flow in pairs(self.Flows) do
        if now >= flow.deadline then
            resolve(self, flow.player, flow, 'timeout') -- 平台无取消/失败事件，超时是唯一兜底
        end
    end
    for userId, queue in pairs(self.PendingGrants) do
        if queue.player and #queue.jobs > 0 then
            local job = queue.jobs[1]
            if self:GrantGoods(queue.player, job.goods, job.num) then
                table.remove(queue.jobs, 1)
            else
                self.PendingGrants[userId] = nil -- 存档不可用：记日志保线索，不无限重试
                print('[MgrPlatform] 发货重试放弃（待对账）', userId, job.goods)
            end
        else
            self.PendingGrants[userId] = nil
        end
    end
end

function Mgr:OnPlayerRemoving(player)
    self.Flows[player.UserId] = nil
    self.GrantSeq[player.UserId] = nil
    self.CoinSeq[player.UserId] = nil
    self.PendingGrants[player.UserId] = nil
end

function Mgr:Start()
    local commodity = service('CommodityService')
    if commodity and commodity.GoodsPurchaseCompleted then
        local ok, err = pcall(function()
            commodity.GoodsPurchaseCompleted:Connect(function(goodsId, goodsNum, player)
                self:OnGoodsPurchaseCompleted(goodsId, goodsNum, player)
            end)
        end)
        if not ok then print('[MgrPlatform] 订阅购买完成信号失败', tostring(err)) end
    else
        print('[MgrPlatform] CommodityService 不可用，平台购买入口全部降级为不可用')
    end
    _G.REUtil:GetRE('PlatformAction').OnServerEvent:Connect(function(player, payload)
        if _G.REUtil:CheckRECD(player, 'PlatformAction', cfg().ActionCooldownSec) then return end
        self:HandleAction(player, payload)
    end)
    _G.REUtil:GetRE('PlatformTestAction').OnServerEvent:Connect(function(player, payload)
        if _G.REUtil:CheckRECD(player, 'PlatformTestAction', 0.2) then return end
        self:HandleTestAction(player, payload)
    end)
end

return Mgr
