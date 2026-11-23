local GameCfg = require('common.GameCfg')
local ServerRuntime = require('server.World.ServerRuntime')

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

function Mgr:HasFlow(player)
    local flow = player and self.Flows[player.UserId]
    return flow ~= nil and flow.player == player
end

local function notifyTestFlow(mgr, player, flow, open)
    if flow.real then return end
    local ok, err = pcall(mgr.Reply, mgr, player, { ok = true, action = 'TestFlow', open = open,
        kind = flow.kind, key = flow.goods or flow.ad, purpose = flow.purpose })
    if not ok then print('[MgrPlatform] 测试 flow 通知失败', player.UserId, tostring(err)) end
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
        local callback = flow.onResult
        local function deliver()
            local ok, err = pcall(callback, outcome, payload)
            if not ok then print('[MgrPlatform] flow 回调失败', player.UserId, tostring(err)) end
        end
        local task = game and game.GetService and game:GetService('Task')
        if task and type(task.Spawn) == 'function' then task:Spawn(deliver) else deliver() end
    end
end

function Mgr:CanPurchase(player, goodsKey)
    if type(cfg().Goods[goodsKey]) ~= 'table' then return false, 'invalid' end
    if debugEnabled() then return true end
    if placeholderAllowed() and placeholderGoodsId('goods', goodsKey) then return true end
    return false, closedReason()
end

local function openFlow(self, player, intent, onResult)
    if not player or not player.UserId then return false, 'invalid' end
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
    print('[MgrPlatform] flow 建立', player.UserId, intent.kind, tostring(key), label,
        'flow=' .. tostring(flow.id))
    notifyFlow(self, player, flow, true)
    return true
end

function Mgr:Purchase(player, goodsKey, purpose, onResult)
    return openFlow(self, player, { kind = 'purchase', goods = goodsKey, purpose = purpose }, onResult)
end

function Mgr:ShowAd(player, adKey, purpose, onResult)
    return openFlow(self, player, { kind = 'ad', ad = adKey, purpose = purpose }, onResult)
end

function Mgr:CancelFlow(player)
    if not self:HasFlow(player) then return false end
    print('[MgrPlatform] flow 被业务取消', player.UserId)
    local flow = self.Flows[player.UserId]
    self.Flows[player.UserId] = nil
    notifyFlow(self, player, flow, false)
    return true
end

function Mgr:OpenAdrenalineShop(player)
    local rows = cfg().Goods
    if not (debugEnabled() or placeholderAllowed()) then
        local reason = closedReason()
        self:Reply(player, { ok = false, action = 'AdrenalineShop', reason = reason, text = closedText(reason) })
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

function Mgr:OpenCoinShop(player)
    local config = placeholder()
    local page = config and config.CoinPage
    if not placeholderAllowed() or type(page) ~= 'table' or type(page.Offers) ~= 'table' then
        local reason = closedReason()
        self:Reply(player, { ok = false, action = 'CoinShop', reason = reason, text = closedText(reason) })
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

function Mgr:PurchaseCoin(player, key)
    if not coinOffer(key) then return false end
    return openFlow(self, player, { kind = 'coin', coin = key, purpose = 'coinpage' }, function(outcome)
        if outcome == 'success' then return self:GrantCoin(player, key) end
        self:Reply(player, { ok = false, action = 'BuyCoin', goods = key, reason = outcome })
        return false
    end)
end

function Mgr:GrantCoin(player, key, requestId)
    local offer = coinOffer(key)
    local amount = coinAmount(offer)
    if not amount then return false end
    local data = self.PlayerData and self.PlayerData:GetDataInst(player)
    if not data or not self.Save then return false end
    if requestId == nil then
        self.CoinSeq[player.UserId] = (self.CoinSeq[player.UserId] or 0) + 1
        requestId = self.CoinSeq[player.UserId]
    end
    local operation, mode = self.Save:ResolveRequest(player, data, 'platform:coin', requestId)
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
            coin = result.coin, coinBefore = result.coinBefore, coinAfter = result.coinAfter,
            operation = operation })
    end)
end

function Mgr:ResolvePlaceholder(player, outcome)
    if outcome ~= 'success' and outcome ~= 'cancel' and outcome ~= 'fail' then return false end
    local flow = player and self.Flows[player.UserId]
    if not flow or flow.player ~= player or not flow.placeholder then return false end
    resolve(self, player, flow, outcome, { placeholder = true })
    return true
end

function Mgr:GrantGoods(player, goodsKey, num, requestId)
    local row = cfg().Goods[goodsKey]
    if not row or not row.itemId then return false end
    local data = self.PlayerData and self.PlayerData:GetDataInst(player)
    if not data or not self.Save then return false end
    if requestId == nil then
        self.GrantSeq[player.UserId] = (self.GrantSeq[player.UserId] or 0) + 1
        requestId = self.GrantSeq[player.UserId]
    end
    local operation, mode = self.Save:ResolveRequest(player, data, 'platform:grant', requestId)
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
    local executed = self.Save:Execute(player, data, operation, function(draft)
        local granted = 0
        for _ = 1, total do
            if not draft:AddItem(row.itemId) then break end
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
            granted = result.granted, overflow = result.overflow, operation = operation })
        if result.overflow > 0 then
            local origin = player.Character and player.Character.Position
            for _ = 1, result.overflow do
                local runtime = ServerRuntime.current and ServerRuntime.current()
                local world = runtime and runtime:get_world()
                local spawned = world and origin and world:place_ground_item('fishPond', {
                    kind = 'item', itemId = row.itemId, count = 1,
                    x = origin.x, y = origin.y, z = origin.z + 2 })
                if not spawned then
                    print('[MgrPlatform] 溢出落地失败（待对账）', player.UserId, row.itemId)
                end
            end
        end
    end)
    return executed, operation
end

function Mgr:OnGoodsPurchaseCompleted(goodsId, num, player)
    -- 公开信号无订单身份，旧单/重复单无法与当前 flow 安全关联，保持关闭。
    print('[MgrPlatform] 缺可信交付身份，忽略真实购买信号', tostring(goodsId))
end

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
    if not flow or flow.player ~= player or flow.placeholder then return false end
    resolve(self, player, flow, payload.outcome, { driver = true })
    return true
end

function Mgr:Share(player, purpose)
    if type(player) ~= 'table' or player.UserId == nil then return false, 'invalid' end
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

function Mgr:HandleAction(player, payload)
    if type(payload) ~= 'table' then return false end
    if payload.action == 'OpenAdrenaline' then return self:OpenAdrenalineShop(player) end
    if payload.action == 'OpenCoinShop' then return self:OpenCoinShop(player) end
    if payload.action == 'Share' then
        self:Share(player, payload.purpose)
        return true
    end
    if payload.action == 'BuyCoin' then
        local opened, reason = self:PurchaseCoin(player, payload.goods)
        if not opened then
            reason = reason or 'invalid'
            self:Reply(player, { ok = false, action = 'BuyCoin', goods = payload.goods,
                reason = reason, text = closedText(reason) })
        end
        return opened
    end
    if payload.action == 'PlaceholderOutcome' then
        return self:ResolvePlaceholder(player, payload.outcome)
    end
    if payload.action == 'Purchase' then
        local goodsKey = payload.goods
        local row = cfg().Goods[goodsKey]
        if not row or not row.itemId then return false end
        local opened, reason = self:Purchase(player, goodsKey, 'adrenaline', function(outcome)
            if outcome == 'success' then
                self:GrantGoods(player, goodsKey, 1)
            else
                self:Reply(player, { ok = false, action = 'Purchase', goods = goodsKey, reason = outcome })
            end
        end)
        if not opened then
            reason = reason or 'unavailable'
            self:Reply(player, { ok = false, action = 'Purchase', goods = goodsKey,
                reason = reason, text = closedText(reason) })
        end
        return opened
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
                self.PendingGrants[userId] = nil
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
