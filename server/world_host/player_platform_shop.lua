local EngineRead = require("common.engine_read"); local GameCfg = require("common.game_cfg")
local DeepCopy = require("common.deep_copy")
local PlayerBehaviorKit = require("server.world_host.player_behavior_kit")

local PlayerPlatformShop = {}
-- 平台商店行为表：拆分前都是 PlayerPlatformShop.mount 体内的闭包，依赖统一从树上的 platform_shop_env 读取。
local PlatformShopBehavior = {}

---@return any
local function cfg() return GameCfg.Platform end
---@return boolean
local function debug_enabled() return GameCfg.Debug and GameCfg.Debug.Enabled == true end
---@return boolean
local function placeholder_allowed()
  local value = GameCfg.platform_placeholder()
  return value and value.Enabled == true and (debug_enabled() or value.AllowInPublish == true) or false
end
local function closed_reason()
  local value = GameCfg.platform_placeholder()
  return value and value.Enabled == true and "not_open" or "unavailable"
end
local function closed_text(reason)
  return reason == "not_open" and cfg().NotOpenText or cfg().UnavailableText
end
---@param offer table?
---@return integer?
local function coin_amount(offer)
  local value = GameCfg.platform_placeholder()
  local page = value and value.CoinPage
  local unit = page and page.CoinPerUnit
  if type(offer) ~= "table" or type(offer.price) ~= "number" or type(unit) ~= "number" or unit <= 0 then
    return nil
  end
  return math.floor(offer.price * unit + 0.5)
end
-- 意图袋与推进方法（帧活跃 / 同步树 / 令牌 / 单次写档）按存档键从共用件生成。
local box, bag = PlayerBehaviorKit.methods(PlatformShopBehavior, {
  env_field = "platform_shop_env", bag_key = "platformShop",
})
local sorted_keys = PlayerBehaviorKit.sorted_keys

-- ===== 环境与行为表 =====

-- 建平台商店环境：拆分前 mount 开头的局部变量全部收进 env，行为方法只从 platform_shop_env 取依赖。
function PlatformShopBehavior.new_env(tree, opts)
  opts = type(opts) == "table" and opts or {}
  local State = opts.state
  ---@type table<string, string?>
  local outcomes = {}
  return {
    tree = tree,
    opts = opts,
    player = tree.player,
    data = tree.data,
    save = opts.save,
    platform = opts.platform,
    remote = opts.remote,
    working = false, ---@type boolean?
    lifecycle = { disposed = false }, ---@type { disposed: boolean }
    outcomes = outcomes,
    frame_active = State.new("PlayerPlatformShop.frame_active", false),
  }
end

function PlatformShopBehavior.is_disposed(self)
  return self.platform_shop_env.lifecycle.disposed
end

-- 帧相位活跃判定：有待交付或未结清的 intent 才订阅 on_frame 推进。
PlatformShopBehavior.sync_frame_active = box.sync_frame_active

--- 结果下发：已销毁直接拒绝，失败打印并返回 ok, reason（生成器见 EngineRead.client_reply）。
PlatformShopBehavior.reply = EngineRead.client_reply("platform_shop_env", {
  tag = "PlayerPlatformShop", channel = "PlatformResult", context = "PlayerPlatformShop.reply", field = "action",
  returns = "status",
})

PlatformShopBehavior.sync_tree = box.sync_tree

PlatformShopBehavior.current_token = box.current_token

function PlatformShopBehavior.publish(self, result, key)
  local env = self.platform_shop_env
  local response = DeepCopy.copy(result)
  local pending = false
  for _, delivery in pairs(bag(env.data).deliveries) do
    if delivery.intent == key then pending = true end
  end
  local intent = bag(env.data).intents[key]
  response.requestId, response.seq = key, intent and intent.seq
  response.deliveryPending = pending or nil
  if pending then response.grounded = nil end
  if intent and intent.token ~= PlatformShopBehavior.current_token(self) then response.recovered = true end
  PlatformShopBehavior.reply(self, response)
end

PlatformShopBehavior.write = box.write

-- 结算：coin 档位按占位页汇率发金币，其余按 Goods 行发道具，放不下的进待交付。
function PlatformShopBehavior.settle(self, draft, intent, key)
  local env = self.platform_shop_env
  if intent.kind == "coin" then
    local offer = GameCfg.platform_coin_offer(intent.goods)
    if not offer then return nil, "unavailable" end
    local amount = coin_amount(offer)
    if not amount then return nil, "unavailable" end
    local before = draft.data.FishCoin
    if not draft:AddCoin(amount, nil, "coinpage:" .. intent.goods) then return nil, "coin" end
    return {
      ok = true, action = "CoinGrant", goods = intent.goods, name = offer.name,
      coin = amount, coinBefore = before, coinAfter = draft.data.FishCoin,
    }
  end
  local row = cfg().Goods[intent.goods]
  if not row or not row.itemId then return nil, "unavailable" end
  local total = row.count * math.max(1, intent.count or 1)
  local granted = 0
  local overflow = 0
  for index = 1, total do
    if draft:AddItem(row.itemId) then
      granted = granted + 1
    else
      overflow = overflow + 1
      bag(draft).deliveries[key .. ":" .. index] = {
        itemId = row.itemId, epoch = env.opts.delivery_epoch, intent = key,
      }
    end
  end
  return {
    ok = true, action = "Grant", goods = intent.goods, itemId = row.itemId,
    total = total, granted = granted, overflow = overflow,
  }
end

-- 推进机：先结清已付费 intent，再按顺序落地待交付；每次至多推进一个写档。
function PlatformShopBehavior.pump(self)
  local env = self.platform_shop_env
  local player, data = env.player, env.data
  if env.lifecycle.disposed then return end
  PlatformShopBehavior.sync_frame_active(self)
  if env.working then return end
  local value = bag(data)
  for _, key in ipairs(sorted_keys(value.intents)) do
    local intent = value.intents[key]
    local outcome = env.outcomes[key]
    if outcome then
      PlatformShopBehavior.write(self, "platform:paid", function(draft)
        local current = bag(draft).intents[key]
        if current then current.state = outcome == "success" and "paid" or "cancelled" end
        return { ok = true }
      end, function(ok)
        if ok then env.outcomes[key] = nil; PlatformShopBehavior.pump(self) end
      end)
      return
    elseif intent.state == "paid" then
      PlatformShopBehavior.write(self, intent.kind == "coin" and "platform:coin" or "platform:grant", function(draft)
        local result, reason = PlatformShopBehavior.settle(self, draft, intent, key)
        if not result then return nil, reason end
        local current = bag(draft).intents[key]
        current.state, current.result = "settled", result
        return result
      end, function(ok, result)
        if not ok then PlatformShopBehavior.reply(self, { ok = false, reason = result, requestId = key, deliveryPending = true }) return end
        PlatformShopBehavior.publish(self, result, key)
        PlatformShopBehavior.pump(self)
      end)
      return
    end
  end

  local origin = player.Character and player.Character.Position
  local world = env.opts.world
  if not origin or not world or type(world.place_delivery) ~= "function" then return end
  for _, key in ipairs(sorted_keys(value.deliveries)) do
    local delivery = value.deliveries[key]
    if delivery.epoch == nil then
      print("[PlayerPlatformShop] 跳过缺少 epoch 的遗留待交付", player.UserId, key)
    elseif delivery.epoch == env.opts.delivery_epoch then
      local receipt, reason = world:place_delivery(key, "fishPond", { kind = "item", itemId = delivery.itemId,
        count = 1, mult = 1, x = origin.x, y = origin.y, z = origin.z + 2 })
      if not receipt then
        print("[PlayerPlatformShop] 待交付保留", player.UserId, key, tostring(reason))
        return
      end
      PlatformShopBehavior.write(self, "platform:delivery", function(draft)
        bag(draft).deliveries[key] = nil
        return { ok = true }
      end, function(ok)
        if ok then
          local intent = bag(data).intents[delivery.intent]
          if intent and intent.result then PlatformShopBehavior.publish(self, intent.result, delivery.intent) end
          PlatformShopBehavior.pump(self)
        end
      end)
      return
    end
  end
end

function PlatformShopBehavior.open_adrenaline(self)
  local rows = cfg().Goods
  if not (debug_enabled() or placeholder_allowed()) then
    local reason = closed_reason()
    PlatformShopBehavior.reply(self, { ok = false, action = "AdrenalineShop", reason = reason, text = closed_text(reason) })
    return false
  end
  PlatformShopBehavior.reply(self, { ok = true, action = "AdrenalineShop", offers = {
    { key = "adrenaline1", beans = rows.adrenaline1.beans, count = rows.adrenaline1.count, name = rows.adrenaline1.name },
    { key = "adrenaline5", beans = rows.adrenaline5.beans, count = rows.adrenaline5.count, name = rows.adrenaline5.name },
  } })
  return true
end

function PlatformShopBehavior.open_coin_shop(self)
  local value = GameCfg.platform_placeholder()
  local page = value and value.CoinPage
  if not value or not placeholder_allowed() or type(page) ~= "table" or type(page.Offers) ~= "table" then
    local reason = closed_reason()
    PlatformShopBehavior.reply(self, { ok = false, action = "CoinShop", reason = reason, text = closed_text(reason) })
    return false
  end
  local offers = {}
  for _, offer in ipairs(page.Offers) do
    offers[#offers + 1] = {
      key = offer.key, goodsId = offer.goodsId, name = offer.name,
      price = offer.price, coin = coin_amount(offer),
    }
  end
  PlatformShopBehavior.reply(self, {
    ok = true, action = "CoinShop", offers = offers, rate = page.CoinPerUnit,
    currency = page.Unit, notice = value.Notice,
  })
  return true
end

-- 校验动作并解出购买上下文：不合法时返回 nil，调用方直接回 false。
local function read_purchase_request(self, env, payload)
  if payload.action ~= "Purchase" and payload.action ~= "BuyCoin" and payload.action ~= "Query" then return nil end
  local seq = payload.seq
  if type(seq) ~= "number" or seq ~= math.floor(seq) or seq < 1 or seq > 2147483647 or not env.save or not env.platform then
    return nil
  end
  local token = PlatformShopBehavior.current_token(self)
  if not token then return nil end
  local key = payload.action == "Query" and payload.requestId or (token .. ":platformShop:" .. seq)
  return { env = env, action = payload.action, seq = seq, goods = payload.goods, token = token, key = key }
end

-- 重复 key 的请求：有结果就回放，未结清回 cancel / pending。
local function reply_existing_intent(self, req)
  local existing = bag(req.env.data).intents[req.key]
  if not existing then return false end
  if existing.result then
    PlatformShopBehavior.publish(self, existing.result, req.key)
    PlatformShopBehavior.pump(self)
    return true
  end
  PlatformShopBehavior.reply(self, {
    ok = false, reason = existing.state == "cancelled" and "cancel" or "pending",
    requestId = req.key, seq = req.seq, deliveryPending = existing.state ~= "cancelled",
  })
  PlatformShopBehavior.pump(self)
  return true
end

-- Query 无 intent、平台流水线忙碌、代币关闭、商品不可购：都只回错误。
-- 返回 "reject" 表示商品表没有这一行，调用方按未处理返回 false。
local function reply_purchase_blocked(self, req)
  local env = req.env
  if req.action == "Query" then
    PlatformShopBehavior.reply(self, { ok = false, reason = "expired", seq = req.seq })
    return "blocked"
  end
  if env.platform:has_flow(env.player) or env.working then
    PlatformShopBehavior.reply(self, { ok = false, reason = "busy", seq = req.seq })
    return "blocked"
  end
  if req.action == "BuyCoin" then
    if GameCfg.platform_coin_offer(req.goods) and placeholder_allowed() then return nil end
    local reason = closed_reason()
    PlatformShopBehavior.reply(self, { ok = false, action = "BuyCoin", goods = req.goods, reason = reason, text = closed_text(reason) })
    return "blocked"
  end
  local row = cfg().Goods[req.goods]
  if not row or not row.itemId then return "reject" end
  local available, reason = env.platform:can_purchase(env.player, req.goods)
  if available then return nil end
  PlatformShopBehavior.reply(self, { ok = false, action = "Purchase", goods = req.goods, reason = reason, text = closed_text(reason) })
  return "blocked"
end

-- 落库 intent 再按 kind 打开平台流水线；写失败、打开失败与异步结果都回 reply + pump。
local function open_purchase(self, req)
  local env = req.env
  local kind = req.action == "BuyCoin" and "coin" or "goods" ---@type string
  local accepted, why = PlatformShopBehavior.write(self, "platform:intent", function(draft)
    local value = bag(draft)
    value.order = (value.order or 0) + 1
    value.intents[req.key] = {
      state = "awaiting", kind = kind, goods = req.goods, count = 1,
      token = req.token, seq = req.seq, order = value.order,
    }
    return { ok = true }
  end, function(written, failure)
    if not written then PlatformShopBehavior.reply(self, { ok = false, reason = failure }) return end
    local function on_outcome(outcome)
      if PlatformShopBehavior.is_disposed(self) then return end
      env.outcomes[req.key] = outcome
      if outcome ~= "success" then
        PlatformShopBehavior.reply(self, { ok = false, action = req.action, goods = req.goods, reason = outcome, requestId = req.key, seq = req.seq })
      end
      PlatformShopBehavior.pump(self)
    end
    local opened, open_failure
    if kind == "coin" then
      opened, open_failure = env.platform:open_coin_flow(env.player, req.goods, on_outcome)
    else
      opened, open_failure = env.platform:purchase(env.player, req.goods, "adrenaline", on_outcome)
    end
    if not opened then
      env.outcomes[req.key] = open_failure or "unavailable"
      PlatformShopBehavior.reply(self, { ok = false, action = req.action, goods = req.goods, reason = open_failure or "unavailable", requestId = req.key, seq = req.seq })
      PlatformShopBehavior.pump(self)
    end
  end)
  if not accepted then PlatformShopBehavior.reply(self, { ok = false, reason = why or "pending" }) end
end

function PlatformShopBehavior.on_action(self, actor, payload)
  local env = self.platform_shop_env
  if env.lifecycle.disposed or actor ~= env.player or type(payload) ~= "table" then return false end
  if payload.action == "OpenAdrenaline" then return PlatformShopBehavior.open_adrenaline(self) end
  if payload.action == "OpenCoinShop" then return PlatformShopBehavior.open_coin_shop(self) end
  local req = read_purchase_request(self, env, payload)
  if not req then return false end
  if reply_existing_intent(self, req) then return true end
  local verdict = reply_purchase_blocked(self, req)
  if verdict == "blocked" then return true end
  if verdict == "reject" then return false end
  open_purchase(self, req)
  return true
end

-- ===== 装配 =====

-- 把行为表挂到玩家树上；依赖统一从 tree.platform_shop_env 读取。
function PlatformShopBehavior.install(tree, env)
  tree.platform_shop_env = env
end

-- Spoke 作用域接线：注册顺序与拆分前 mount 内的 subscribe / phase / cleanup 一致。
function PlatformShopBehavior.wire(scope, tree)
  local env = tree.platform_shop_env
  if tree.actions and tree.actions.platform_shop then
    scope:subscribe(tree.actions.platform_shop, function(event)
      event.result = PlatformShopBehavior.on_action(tree, env.player, event.payload)
    end)
  end
  scope:phase("PlatformShopActiveFrame", env.frame_active, function(frame_scope)
    frame_scope:subscribe(tree.clock.on_frame, function() PlatformShopBehavior.pump(tree) end)
  end)
  scope:on_cleanup(function()
    env.lifecycle.disposed = true
    env.outcomes = {}
  end)
  PlatformShopBehavior.pump(tree)
end

-- 挂载平台商店模块：先建环境并装配行为表，再按拆分前的顺序接线。
function PlayerPlatformShop.mount(scope, tree, opts)
  local env = PlatformShopBehavior.new_env(tree, opts)
  PlatformShopBehavior.install(tree, env)
  PlatformShopBehavior.wire(scope, tree)
  return {
    handle = function(actor, payload)
      return PlatformShopBehavior.on_action(tree, actor, payload)
    end,
    step = function()
      PlatformShopBehavior.pump(tree)
    end,
  }
end

return PlayerPlatformShop
