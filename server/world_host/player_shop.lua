local GameCfg = require("common.game_cfg")
local Number = require("common.number")
local SpokeRuntime = require("common.packages.spoke.runtime.spoke_runtime")
local InteractionPoints = require("server.world_host.interaction_points")

local PlayerShop = {}

local function item_count(data, item_id)
  return data.Data.Bait[item_id] or data:ItemCount(item_id)
end

local function find_goods(item_id, level)
  for _, goods in ipairs(GameCfg.Shop.Goods) do
    if goods.ItemId == item_id and goods.MinShopLevel <= level then return goods end
  end
  return nil
end

local function find_goods_by_number(number, level)
  if not Number.is_finite_number(number) or number ~= math.floor(number) or number < 1 then return nil end
  for _, goods in ipairs(GameCfg.Shop.Goods) do
    if goods.Number == number and goods.MinShopLevel <= level then return goods end
  end
  return nil
end

local function stand_for(player)
  for _, stand in ipairs(GameCfg.Shop.Stands) do
    if InteractionPoints:in_range(player, {
      AnchorName = stand.AnchorName,
      Radius = GameCfg.Shop.Radius,
      Slack = GameCfg.Shop.Slack,
    }) then
      return stand
    end
  end
  return nil
end

local function backpack_row(data, stand_level)
  local spec = GameCfg.Shop.UpgradeKinds.backpack
  local next_level = data:shop_upgrade_level("backpack") + 1
  if not spec or next_level > spec.MaxLevel then return nil, "max" end
  local row
  for _, goods in ipairs(GameCfg.Shop.Goods) do
    if goods.Upgrade and goods.Upgrade.kind == "backpack" and goods.Upgrade.level == next_level
        and goods.MinShopLevel <= stand_level then
      row = goods
      break
    end
  end
  if not row then return nil, "level" end
  if (row.PurchaseLimit or 0) > 0 and data:PurchaseCount(row.Number) >= row.PurchaseLimit then
    return nil, "limit"
  end
  return row
end

local function settle_purchase(draft, goods)
  if (goods.PurchaseLimit or 0) > 0 and draft:PurchaseCount(goods.Number) >= goods.PurchaseLimit then
    return nil, "limit"
  end
  if goods.Upgrade then
    local allowed, failure = draft:CanShopUpgrade(goods.Upgrade)
    if not allowed then return nil, failure end
    local before_coin = draft.Data.FishCoin
    if not draft:SpendCoin(goods.Price, function() draft:ApplyShopUpgrade(goods.Upgrade) end,
        "shop:" .. goods.Number) then
      return nil, "coin"
    end
    draft:NotePurchase(goods.Number)
    return {
      ok = true, action = "Upgrade", number = goods.Number, name = goods.Name, price = goods.Price,
      kind = goods.Upgrade.kind, level = goods.Upgrade.level,
      coinBefore = before_coin, coinAfter = draft.Data.FishCoin,
    }
  end
  local item_id = goods.ItemId
  local allowed, failure = draft:CanGrant(item_id, 1)
  if not allowed then return nil, failure == "full" and "full" or "item" end
  local before_coin, before_item = draft.Data.FishCoin, item_count(draft, item_id)
  if not draft:SpendCoin(goods.Price, function() draft:GrantItem(item_id, 1) end, "shop:" .. item_id) then
    return nil, "coin"
  end
  draft:NotePurchase(goods.Number)
  return {
    ok = true, itemId = item_id, number = goods.Number, name = goods.Name, price = goods.Price,
    coinBefore = before_coin, coinAfter = draft.Data.FishCoin,
    itemBefore = before_item, itemAfter = item_count(draft, item_id),
  }
end

function PlayerShop.mount(scope, tree, opts)
  opts = type(opts) == "table" and opts or {}
  local player, data, save, remote = tree.player, tree.data, opts.save, opts.remote
  local cleaned = false
  local last_seq = 0

  local function reply(payload)
    if remote and type(remote.get_re) == "function" then
      remote:get_re("ShopResult"):FireClient(player, payload)
    end
    return payload
  end

  local function fail(item_id, reason, number)
    reply({ ok = false, itemId = item_id, number = number, reason = reason })
    return false
  end

  local function resolve(payload)
    local request_id = payload.operation
    if request_id ~= nil and type(request_id) ~= "table" then return nil, false end
    if request_id == nil then request_id = payload.seq end
    local operation, mode = save:resolve_request(player, data, "shop", request_id)
    if not operation then return nil, false end
    if mode ~= "replay" then return operation end
    local accepted = save:execute(player, data, operation, function() return nil, "expired" end,
      function(ok, result)
        if ok then result.operation = operation reply(result) end
      end)
    return nil, accepted
  end

  local function upgrade_storage(operation)
    local stand = stand_for(player)
    if not stand then return fail(nil, "range") end
    local row, reason = backpack_row(data, stand.Level)
    if not row then return fail(nil, reason) end
    local result_value = nil
    local accepted = save:execute(player, data, operation, function(draft)
      local draft_row, failure = backpack_row(draft, stand.Level)
      if not draft_row then return nil, failure end
      local before_coin, before_level = draft.Data.FishCoin, draft.Data.UpgradeLevel
      local upgraded, cost = draft:UpgradeStorage()
      if not upgraded then return nil, cost end
      draft:NotePurchase(draft_row.Number)
      return {
        ok = true, action = "UpgradeStorage", price = cost, level = draft.Data.UpgradeLevel,
        coinBefore = before_coin, coinAfter = draft.Data.FishCoin, levelBefore = before_level,
      }
    end, function(written, result)
      if cleaned then return end
      if not written then fail(nil, result) return end
      result.operation = operation
      result_value = result
      SpokeRuntime.batch(function() tree:sync_from_data(data) end)
      reply(result)
    end)
    if accepted ~= true then return false end
    return result_value ~= nil or true
  end

  local function handle(actor, payload)
    if cleaned or actor ~= player or type(payload) ~= "table"
        or (payload.action ~= "Buy" and payload.action ~= "UpgradeStorage") then return false end
    local seq = payload.seq
    if payload.operation == nil and (type(seq) ~= "number" or seq ~= math.floor(seq)
        or seq < 1 or seq > 2147483647) then return false end
    if payload.action == "Buy" and payload.operation == nil then
      if payload.number ~= nil then
        if type(payload.number) ~= "number" or payload.number ~= math.floor(payload.number)
            or payload.number < 1 or payload.number > 2147483647 then return false end
      elseif type(payload.itemId) ~= "string" then
        return false
      end
    end
    local operation, replayed = resolve(payload)
    if not operation then return replayed == true end
    if payload.operation == nil then
      if seq <= last_seq then return false end
      last_seq = seq
    end
    if payload.action == "UpgradeStorage" then return upgrade_storage(operation) end
    local stand = stand_for(player)
    if not stand then return fail(payload.itemId, "range", payload.number) end
    local goods
    if payload.number ~= nil then
      goods = find_goods_by_number(payload.number, stand.Level)
    else
      goods = find_goods(payload.itemId, stand.Level)
    end
    if not goods then return fail(payload.itemId, "item", payload.number) end
    if (goods.PurchaseLimit or 0) > 0 and data:PurchaseCount(goods.Number) >= goods.PurchaseLimit then
      return fail(payload.itemId, "limit", payload.number)
    end
    local result_value = nil
    local accepted = save:execute(player, data, operation, function(draft)
      local result, failure = settle_purchase(draft, goods)
      if not result then return nil, failure end
      if opts.quest and opts.quest.record_fact then
        opts.quest:record_fact(draft, "Buy", { itemId = result.itemId, eventId = operation.id })
      end
      return result
    end, function(written, result)
      if cleaned then return end
      if not written then fail(payload.itemId, result, payload.number) return end
      result.operation = operation
      result_value = result
      SpokeRuntime.batch(function()
        tree:sync_from_data(data)
      end)
      reply(result)
      if opts.quest and opts.quest.record_fact then
        if opts.quest.refresh_committed then opts.quest:refresh_committed(player, data) end
      elseif opts.quest and opts.quest.notify then
        opts.quest:notify("Buy", player, {
          itemId = result.itemId, number = result.number, eventId = operation.id,
        })
      end
    end)
    if accepted ~= true then return false end
    return result_value ~= nil or true
  end

  scope:on_cleanup(function() cleaned = true end)
  return { handle = handle }
end

return PlayerShop
