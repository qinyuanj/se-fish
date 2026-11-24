local game_cfg = require("common.game_cfg")

local player_platform_shop = {}

local function cfg() return game_cfg.Platform end
local function placeholder()
  local value = cfg().Placeholder
  return type(value) == "table" and value or nil
end
local function debug_enabled() return game_cfg.Debug and game_cfg.Debug.Enabled == true end
local function placeholder_allowed()
  local value = placeholder()
  return value and value.Enabled == true and (debug_enabled() or value.AllowInPublish == true) or false
end
local function closed_reason()
  local value = placeholder()
  return value and value.Enabled == true and "not_open" or "unavailable"
end
local function closed_text(reason)
  return reason == "not_open" and cfg().NotOpenText or cfg().UnavailableText
end
local function coin_offer(key)
  local page = placeholder() and placeholder().CoinPage
  local offers = type(page) == "table" and page.Offers or nil
  if type(offers) ~= "table" or type(key) ~= "string" then return nil end
  for _, offer in ipairs(offers) do
    if offer.key == key then return offer end
  end
end
local function coin_amount(offer)
  local page = placeholder() and placeholder().CoinPage
  local unit = page and page.CoinPerUnit
  if type(offer) ~= "table" or type(offer.price) ~= "number" or type(unit) ~= "number" or unit <= 0 then
    return nil
  end
  return math.floor(offer.price * unit + 0.5)
end
local function bag(data)
  local extra = data.Extra
  if type(extra) ~= "table" then extra = {}; data.Extra = extra end
  local value = extra.platformShop
  if type(value) ~= "table" then
    value = {}
    extra.platformShop = value
  end
  value.intents, value.deliveries = value.intents or {}, value.deliveries or {}
  return value
end
local function copy(value)
  if type(value) ~= "table" then return value end
  local out = {}
  for key, item in pairs(value) do out[key] = copy(item) end
  return out
end
local function sorted_keys(map)
  local keys = {}
  for key in pairs(map or {}) do keys[#keys + 1] = key end
  table.sort(keys)
  return keys
end

function player_platform_shop.mount(scope, tree, opts)
  opts = type(opts) == "table" and opts or {}
  local player, data = tree.player, tree.data
  local save, platform, remote = opts.save, opts.platform, opts.remote
  local working = false
  local disposed = false
  local outcomes = {}

  local function reply(payload)
    if disposed or not remote or type(remote.GetRE) ~= "function" then return end
    local ok, event = pcall(remote.GetRE, remote, "PlatformResult")
    if ok and event then event:FireClient(player, payload) end
  end
  local function sync_tree()
    if not disposed then tree:sync_from_data(data) end
  end
  local function current_token()
    local session = save and save.Sessions[player.UserId]
    return session and session.Token or nil
  end
  local function publish(result, key)
    local response = copy(result)
    local pending = false
    for _, delivery in pairs(bag(data).deliveries) do
      if delivery.intent == key then pending = true end
    end
    local intent = bag(data).intents[key]
    response.requestId, response.seq = key, intent and intent.seq
    response.deliveryPending = pending or nil
    if pending then response.grounded = nil end
    if intent and intent.token ~= current_token() then response.recovered = true end
    reply(response)
  end
  local function write(kind, transform, done)
    if disposed or working then return false, "pending" end
    local operation, reason = save:NextOperation(player, kind)
    if not operation then return false, reason or "pending" end
    working = true
    local accepted, failure = save:Execute(player, data, operation, transform, function(ok, result)
      working = nil
      if ok then sync_tree() end
      done(ok, result, operation)
    end)
    if not accepted then
      working = nil
      reply({ ok = false, reason = failure, deliveryPending = true })
    end
    return accepted, failure
  end

  local pump
  local function settle(draft, intent, key)
    if intent.kind == "coin" then
      local offer = coin_offer(intent.goods)
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
          itemId = row.itemId, epoch = opts.delivery_epoch, intent = key,
        }
      end
    end
    return {
      ok = true, action = "Grant", goods = intent.goods, itemId = row.itemId,
      total = total, granted = granted, overflow = overflow,
    }
  end

  pump = function()
    if disposed or working then return end
    local value = bag(data)
    for _, key in ipairs(sorted_keys(value.intents)) do
      local intent = value.intents[key]
      local outcome = outcomes[key]
      if outcome then
        write("platform:paid", function(draft)
          local current = bag(draft).intents[key]
          if current then current.state = outcome == "success" and "paid" or "cancelled" end
          return { ok = true }
        end, function(ok)
          if ok then outcomes[key] = nil; pump() end
        end)
        return
      elseif intent.state == "paid" then
        write(intent.kind == "coin" and "platform:coin" or "platform:grant", function(draft)
          local result, reason = settle(draft, intent, key)
          if not result then return nil, reason end
          local current = bag(draft).intents[key]
          current.state, current.result = "settled", result
          return result
        end, function(ok, result)
          if not ok then reply({ ok = false, reason = result, requestId = key, deliveryPending = true }) return end
          publish(result, key)
          pump()
        end)
        return
      end
    end

    local origin = player.Character and player.Character.Position
    local world = opts.world
    if not origin or not world or type(world.place_delivery) ~= "function" then return end
    for _, key in ipairs(sorted_keys(value.deliveries)) do
      local delivery = value.deliveries[key]
      if delivery.epoch == nil or delivery.epoch == opts.delivery_epoch then
        local receipt, reason = world:place_delivery(key, "fishPond", {
          kind = "item", itemId = delivery.itemId, count = 1, mult = 1,
          x = origin.x, y = origin.y, z = origin.z + 2,
        })
        if not receipt then
          print("[player_platform_shop] 待交付保留", player.UserId, key, tostring(reason))
          return
        end
        write("platform:delivery", function(draft)
          bag(draft).deliveries[key] = nil
          return { ok = true }
        end, function(ok)
          if ok then
            local intent = bag(data).intents[delivery.intent]
            if intent and intent.result then publish(intent.result, delivery.intent) end
            pump()
          end
        end)
        return
      end
    end
  end

  local function open_adrenaline()
    if not (debug_enabled() or placeholder_allowed()) then
      local reason = closed_reason()
      reply({ ok = false, action = "AdrenalineShop", reason = reason, text = closed_text(reason) })
      return false
    end
    local rows = cfg().Goods
    reply({ ok = true, action = "AdrenalineShop", offers = {
      { key = "adrenaline1", beans = rows.adrenaline1.beans, count = rows.adrenaline1.count, name = rows.adrenaline1.name },
      { key = "adrenaline5", beans = rows.adrenaline5.beans, count = rows.adrenaline5.count, name = rows.adrenaline5.name },
    } })
    return true
  end
  local function open_coin_shop()
    local page = placeholder() and placeholder().CoinPage
    if not placeholder_allowed() or type(page) ~= "table" or type(page.Offers) ~= "table" then
      local reason = closed_reason()
      reply({ ok = false, action = "CoinShop", reason = reason, text = closed_text(reason) })
      return false
    end
    local offers = {}
    for _, offer in ipairs(page.Offers) do
      offers[#offers + 1] = {
        key = offer.key, goodsId = offer.goodsId, name = offer.name,
        price = offer.price, coin = coin_amount(offer),
      }
    end
    reply({
      ok = true, action = "CoinShop", offers = offers, rate = page.CoinPerUnit,
      currency = page.Unit, notice = placeholder().Notice,
    })
    return true
  end

  local function on_action(actor, payload)
    if disposed or actor ~= player or type(payload) ~= "table" then return false end
    if payload.action == "OpenAdrenaline" then return open_adrenaline() end
    if payload.action == "OpenCoinShop" then return open_coin_shop() end
    if payload.action ~= "Purchase" and payload.action ~= "BuyCoin" and payload.action ~= "Query" then return false end
    local seq = payload.seq
    if type(seq) ~= "number" or seq ~= math.floor(seq) or seq < 1 or seq > 2147483647 or not save or not platform then
      return false
    end
    local token = current_token()
    if not token then return false end
    local key = payload.action == "Query" and payload.requestId or (token .. ":platformShop:" .. seq)
    local existing = bag(data).intents[key]
    if existing then
      if existing.result then publish(existing.result, key); pump(); return true end
      reply({
        ok = false, reason = existing.state == "cancelled" and "cancel" or "pending",
        requestId = key, seq = seq, deliveryPending = existing.state ~= "cancelled",
      })
      pump()
      return true
    end
    if payload.action == "Query" then
      reply({ ok = false, reason = "expired", seq = seq })
      return true
    end
    if platform:HasFlow(player) or working then
      reply({ ok = false, reason = "busy", seq = seq })
      return true
    end
    local kind = payload.action == "BuyCoin" and "coin" or "goods"
    local goodsKey = payload.goods
    if kind == "coin" then
      if not coin_offer(goodsKey) or not placeholder_allowed() then
        local reason = closed_reason()
        reply({ ok = false, action = "BuyCoin", goods = goodsKey, reason = reason, text = closed_text(reason) })
        return true
      end
    else
      local row = cfg().Goods[goodsKey]
      if not row or not row.itemId then return false end
      local available, reason = platform:CanPurchase(player, goodsKey)
      if not available then
        reply({ ok = false, action = "Purchase", goods = goodsKey, reason = reason, text = closed_text(reason) })
        return true
      end
    end
    local accepted, reason = write("platform:intent", function(draft)
      local value = bag(draft)
      value.order = (value.order or 0) + 1
      value.intents[key] = {
        state = "awaiting", kind = kind, goods = goodsKey, count = 1,
        token = token, seq = seq, order = value.order,
      }
      return { ok = true }
    end, function(written, failure)
      if not written then reply({ ok = false, reason = failure }) return end
      local function on_outcome(outcome)
        if disposed then return end
        outcomes[key] = outcome
        if outcome ~= "success" then
          reply({ ok = false, action = payload.action, goods = goodsKey, reason = outcome, requestId = key, seq = seq })
        end
        pump()
      end
      local opened, openFailure
      if kind == "coin" then
        opened, openFailure = platform:OpenCoinFlow(player, goodsKey, on_outcome)
      else
        opened, openFailure = platform:Purchase(player, goodsKey, "adrenaline", on_outcome)
      end
      if not opened then
        outcomes[key] = openFailure or "unavailable"
        reply({ ok = false, action = payload.action, goods = goodsKey, reason = openFailure or "unavailable", requestId = key, seq = seq })
        pump()
      end
    end)
    if not accepted then reply({ ok = false, reason = reason or "pending" }) end
    return true
  end

  scope:on_cleanup(function()
    disposed = true
    outcomes = {}
  end)
  pump()
  return { handle = on_action, step = pump }
end

return player_platform_shop
