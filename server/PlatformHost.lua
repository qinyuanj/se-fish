local GameCfg = require('common.GameCfg')

local PlatformHost = { SpokeHost = true, Flows = {}, NextFlowId = 0 }

local function isValidPlayer(player)
    local kind = type(player)
    return (kind == 'table' or kind == 'userdata') and player.UserId ~= nil
end

local function cfg()
    return GameCfg.Platform
end

function PlatformHost:Now()
    self.World = self.World or game:GetService('World')
    return self.World:GetServerTime()
end

function PlatformHost:Reply(player, payload)
    _G.REUtil:GetRE('PlatformResult'):FireClient(player, payload)
end

local function service(name)
    local ok, svc = pcall(function() return game:GetService(name) end)
    return ok and svc or nil
end

local function debugEnabled()
    return GameCfg.Debug and GameCfg.Debug.Enabled == true
end

local function configured(row)
    return type(row) == 'table' and type(row.goodsId) == 'string' and row.goodsId ~= ''
end

local function placeholder()
    local config = cfg().Placeholder
    return type(config) == 'table' and config or nil
end

local function placeholderConfigured()
    local config = placeholder()
    return config ~= nil and config.Enabled == true
end

local function placeholderAllowed()
    if not placeholderConfigured() then return false end
    if debugEnabled() then return true end
    return placeholder().AllowInPublish == true
end

local function closedReason()
    return placeholderConfigured() and 'not_open' or 'unavailable'
end

local function closedText(reason)
    return reason == 'not_open' and cfg().NotOpenText or cfg().UnavailableText
end

local function coinOffer(key)
    local config = placeholder()
    local page = config and config.CoinPage
    local offers = type(page) == 'table' and page.Offers or nil
    if type(offers) ~= 'table' or type(key) ~= 'string' then return nil end
    for _, offer in ipairs(offers) do
        if offer.key == key then return offer end
    end
end

local function coinAmount(offer)
    local config = placeholder()
    local unit = config and config.CoinPage and config.CoinPage.CoinPerUnit
    if type(offer) ~= 'table' or type(offer.price) ~= 'number' then return nil end
    if type(unit) ~= 'number' or unit <= 0 then return nil end
    return math.floor(offer.price * unit + 0.5)
end

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

function PlatformHost:HasFlow(player)
    local flow = player and self.Flows[player.UserId]
    return flow ~= nil and flow.player == player
end

local function notifyTestFlow(mgr, player, flow, open)
    if flow.real then return end
    local ok, err = pcall(mgr.Reply, mgr, player, { ok = true, action = 'TestFlow', open = open,
        kind = flow.kind, key = flow.goods or flow.ad, purpose = flow.purpose })
    if not ok then print('[PlatformHost] 测试 flow 通知失败', player.UserId, tostring(err)) end
end

local function notifyPlaceholder(mgr, player, flow, open)
    local config = placeholder() or {}
    local page = config.CoinPage or {}
    local offer = flow.kind == 'coin' and coinOffer(flow.coin) or nil
    local row = flow.goods and cfg().Goods[flow.goods] or nil
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
    if not ok then print('[PlatformHost] 占位通道通知失败', player.UserId, tostring(err)) end
end

local function notifyFlow(mgr, player, flow, open)
    if flow.placeholder then return notifyPlaceholder(mgr, player, flow, open) end
    return notifyTestFlow(mgr, player, flow, open)
end

local function resolve(mgr, player, flow, outcome, payload)
    if mgr.Flows[player.UserId] == flow then mgr.Flows[player.UserId] = nil end
    notifyFlow(mgr, player, flow, false)
    print('[PlatformHost] flow 结算', player.UserId, flow.kind, tostring(flow.goods or flow.ad), outcome)
    if type(flow.onResult) == 'function' then
        local callback = flow.onResult
        local function deliver()
            local ok, err = pcall(callback, outcome, payload)
            if not ok then print('[PlatformHost] flow 回调失败', player.UserId, tostring(err)) end
        end
        local task = game and game.GetService and game:GetService('Task')
        if task and type(task.Spawn) == 'function' then task:Spawn(deliver) else deliver() end
    end
end

function PlatformHost:CanPurchase(player, goodsKey)
    if type(cfg().Goods[goodsKey]) ~= 'table' then return false, 'invalid' end
    if debugEnabled() then return true end
    if placeholderAllowed() and placeholderGoodsId('goods', goodsKey) then return true end
    return false, closedReason()
end

local function openFlow(self, player, intent, onResult)
    if not isValidPlayer(player) then return false, 'invalid' end
    if self:HasFlow(player) then return false, 'busy' end
    local key = intent.kind == 'coin' and intent.coin or (intent.kind == 'ad' and intent.ad or intent.goods)
    local row = intent.kind == 'coin' and coinOffer(key)
        or (intent.kind == 'ad' and cfg().Ads[key] or cfg().Goods[key])
    if type(row) ~= 'table' then return false, 'invalid' end
    local label, goodsId
    if placeholderAllowed() then
        goodsId = placeholderGoodsId(intent.kind, key)
        if goodsId then label = '占位' end
    end
    if not label and debugEnabled() then label = '测试' end
    if not label then return false, closedReason() end
    self.NextFlowId = self.NextFlowId + 1
    local now = self:Now()
    local flow = { id = self.NextFlowId, player = player, kind = intent.kind, goods = intent.goods,
        ad = intent.ad, coin = intent.coin, purpose = intent.purpose, goodsId = goodsId, real = nil,
        placeholder = label == '占位', onResult = onResult, startedAt = now,
        deadline = now + cfg().FlowTimeoutSec }
    self.Flows[player.UserId] = flow
    print('[PlatformHost] flow 建立', player.UserId, intent.kind, tostring(key), label,
        'flow=' .. tostring(flow.id))
    notifyFlow(self, player, flow, true)
    return true
end

function PlatformHost:Purchase(player, goodsKey, purpose, onResult)
    return openFlow(self, player, { kind = 'purchase', goods = goodsKey, purpose = purpose }, onResult)
end

function PlatformHost:ShowAd(player, adKey, purpose, onResult)
    return openFlow(self, player, { kind = 'ad', ad = adKey, purpose = purpose }, onResult)
end

function PlatformHost:CancelFlow(player)
    if not self:HasFlow(player) then return false end
    print('[PlatformHost] flow 被业务取消', player.UserId)
    local flow = self.Flows[player.UserId]
    self.Flows[player.UserId] = nil
    notifyFlow(self, player, flow, false)
    return true
end

function PlatformHost:OpenCoinFlow(player, key, onResult)
    if not coinOffer(key) or type(onResult) ~= 'function' then return false end
    return openFlow(self, player, { kind = 'coin', coin = key, purpose = 'coinpage' }, onResult)
end

function PlatformHost:ResolvePlaceholder(player, outcome)
    if outcome ~= 'success' and outcome ~= 'cancel' and outcome ~= 'fail' then return false end
    local flow = player and self.Flows[player.UserId]
    if not flow or flow.player ~= player or not flow.placeholder then return false end
    resolve(self, player, flow, outcome, { placeholder = true })
    return true
end

function PlatformHost:OnGoodsPurchaseCompleted(goodsId, num, player)
    -- 公开信号无订单身份，旧单/重复单无法与当前 flow 安全关联，保持关闭。
    print('[PlatformHost] 缺可信交付身份，忽略真实购买信号', tostring(goodsId))
end

function PlatformHost:HandleTestAction(player, payload)
    if not debugEnabled() then
        print('[PlatformHost] 生产构建拒绝测试驱动器', player and player.UserId)
        return false
    end
    if type(payload) ~= 'table' or payload.action ~= 'ResolveFlow'
        or (payload.outcome ~= 'success' and payload.outcome ~= 'cancel' and payload.outcome ~= 'fail') then
        return false
    end
    local flow = player and self.Flows[player.UserId]
    if not flow or flow.player ~= player or flow.placeholder then return false end
    resolve(self, player, flow, payload.outcome, { driver = true })
    return true
end

function PlatformHost:Share(player, purpose)
    if not isValidPlayer(player) then return false, 'invalid' end
    local share = cfg().Share or {}
    local reason
    if share.Enabled ~= true and not placeholderAllowed() then
        reason = closedReason()
    else
        reason = share.Enabled == true and 'unavailable' or 'placeholder'
    end
    local text = share.UnavailableText
    if reason == 'not_open' then text = cfg().NotOpenText end
    self:Reply(player, { ok = false, action = 'Share', purpose = purpose, reason = reason, text = text })
    return false, reason
end

function PlatformHost:HandleAction(player, payload)
    if type(payload) ~= 'table' then return false end
    if self.ShopAction and (payload.action == 'OpenAdrenaline' or payload.action == 'OpenCoinShop'
        or payload.action == 'Purchase' or payload.action == 'BuyCoin' or payload.action == 'Query') then
        return self.ShopAction(player, payload)
    end
    if payload.action == 'Share' then
        self:Share(player, payload.purpose)
        return true
    end
    if payload.action == 'PlaceholderOutcome' then
        return self:ResolvePlaceholder(player, payload.outcome)
    end
    return false
end

function PlatformHost:Update()
    local now = self:Now()
    for userId, flow in pairs(self.Flows) do
        if now >= flow.deadline then
            resolve(self, flow.player, flow, 'timeout') -- 平台无取消/失败事件，超时是唯一兜底
        end
    end
end

function PlatformHost:OnPlayerRemoving(player)
    self.Flows[player.UserId] = nil
end

function PlatformHost:Start()
    local commodity = service('CommodityService')
    if commodity and commodity.GoodsPurchaseCompleted then
        local ok, err = pcall(function()
            commodity.GoodsPurchaseCompleted:Connect(function(goodsId, goodsNum, player)
                self:OnGoodsPurchaseCompleted(goodsId, goodsNum, player)
            end)
        end)
        if not ok then print('[PlatformHost] 订阅购买完成信号失败', tostring(err)) end
    else
        print('[PlatformHost] CommodityService 不可用，平台购买入口全部降级为不可用')
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

return PlatformHost
