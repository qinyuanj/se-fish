local EngineRead = require("common.engine_read")
local GameCfg = require("common.game_cfg")
local Number = require("common.number")
local SpokeRuntime = require("common.packages.spoke.runtime.spoke_runtime")
local InteractionPoints = require("server.world_host.interaction_points")
local PlayerBehaviorKit = require("server.world_host.player_behavior_kit")

local PlayerShop = {}
local ShopBehavior = {}

local function item_count(data, item_id)
  return data.data.Bait[item_id] or data:ItemCount(item_id)
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
    local before_coin = draft.data.FishCoin
    if not draft:SpendCoin(goods.Price, function() draft:ApplyShopUpgrade(goods.Upgrade) end,
        "shop:" .. goods.Number) then
      return nil, "coin"
    end
    draft:NotePurchase(goods.Number)
    return {
      ok = true, action = "Upgrade", number = goods.Number, name = goods.Name, price = goods.Price,
      kind = goods.Upgrade.kind, level = goods.Upgrade.level,
      coinBefore = before_coin, coinAfter = draft.data.FishCoin,
    }
  end
  local item_id = goods.ItemId
  local allowed, failure = draft:CanGrant(item_id, 1)
  if not allowed then return nil, failure == "full" and "full" or "item" end
  local before_coin, before_item = draft.data.FishCoin, item_count(draft, item_id)
  if not draft:SpendCoin(goods.Price, function() draft:GrantItem(item_id, 1) end, "shop:" .. item_id) then
    return nil, "coin"
  end
  draft:NotePurchase(goods.Number)
  return {
    ok = true, itemId = item_id, number = goods.Number, name = goods.Name, price = goods.Price,
    coinBefore = before_coin, coinAfter = draft.data.FishCoin,
    itemBefore = before_item, itemAfter = item_count(draft, item_id),
  }
end

-- ===== 商店动作：拆分前 PlayerShop.mount 体内的闭包 =====
-- ShopBehavior 是商店实例的方法表，方法名、参数顺序与返回值与拆分前的闭包一致；
-- 拆分前从 mount 的 upvalue 读取的依赖统一放进 shop.shop_env。

--- 结果下发（拆分前 mount 体内的 reply）：失败打印带模块标签，逻辑见 EngineRead.client_sender。
ShopBehavior.reply = EngineRead.client_reply("shop_env", {
  tag = "PlayerShop", channel = "ShopResult", context = "PlayerShop.reply", field = "action",
})

--- 失败回包（拆分前 mount 体内的 fail）。
function ShopBehavior.fail(self, item_id, reason, number)
  self:reply({ ok = false, itemId = item_id, number = number, reason = reason })
  return false
end

--- 解析幂等请求（拆分前 mount 体内的 resolve）：重放命中时回放结果，逻辑见 PlayerBehaviorKit.resolve_fn。
ShopBehavior.resolve = PlayerBehaviorKit.resolve_fn(ShopBehavior, { env_field = "shop_env", kind = "shop" })

--- 背包升级（拆分前 mount 体内的 upgrade_storage）。
function ShopBehavior.upgrade_storage(self, operation)
  local env = self.shop_env
  local player, data, save = env.player, env.data, env.save
  local stand = stand_for(player)
  if not stand then return self:fail(nil, "range") end
  local row, reason = backpack_row(data, stand.Level)
  if not row then return self:fail(nil, reason) end
  local result_value = nil
  local accepted = save:execute(player, data, operation, function(draft)
    local draft_row, failure = backpack_row(draft, stand.Level)
    if not draft_row then return nil, failure end
    local before_coin, before_level = draft.data.FishCoin, draft.data.upgrade_level
    local upgraded, cost = draft:UpgradeStorage()
    if not upgraded then return nil, cost end
    draft:NotePurchase(draft_row.Number)
    return {
      ok = true, action = "UpgradeStorage", price = cost, level = draft.data.upgrade_level,
      coinBefore = before_coin, coinAfter = draft.data.FishCoin, levelBefore = before_level,
    }
  end, function(written, result)
    if env.cleaned then return end
    if not written then self:fail(nil, result) return end
    result.operation = operation
    result_value = result
    SpokeRuntime.batch(function() env.tree:sync_from_data(data) end)
    self:reply(result)
  end)
  if accepted ~= true then return false end
  return result_value ~= nil or true
end

--- Buy 请求必须带合法 number，或带字符串 itemId。
local function valid_buy_payload(payload)
  if payload.number == nil then return type(payload.itemId) == "string" end
  return type(payload.number) == "number" and payload.number == math.floor(payload.number)
    and payload.number >= 1 and payload.number <= 2147483647
end

--- 校验动作并解出请求上下文：不合法时返回 nil，调用方直接回 false。
local function read_shop_request(self, actor, payload)
  local env = self.shop_env
  if env.cleaned or actor ~= env.player or type(payload) ~= "table"
      or (payload.action ~= "Buy" and payload.action ~= "UpgradeStorage") then return nil end
  local seq = payload.seq
  if payload.operation == nil and (type(seq) ~= "number" or seq ~= math.floor(seq)
      or seq < 1 or seq > 2147483647) then return nil end
  if payload.action == "Buy" and payload.operation == nil and not valid_buy_payload(payload) then return nil end
  return { env = env, action = payload.action, seq = seq, payload = payload }
end

--- 解析幂等操作：已解析出 operation 时推进 last_seq。
--- 返回布尔表示本次不继续（true = 重放已处理，false = 未处理），否则返回 operation 表。
local function take_operation(self, req)
  local operation, replayed = self:resolve(req.payload)
  if not operation then return replayed == true end
  if req.payload.operation == nil then
    if req.seq <= req.env.last_seq then return false end
    req.env.last_seq = req.seq
  end
  return operation
end

--- 取柜台与商品并检查限购；不可买时返回 self:fail 的结果与 true。
local function find_purchase(self, req)
  local payload = req.payload
  local stand = stand_for(req.env.player)
  if not stand then return self:fail(payload.itemId, "range", payload.number), true end
  local goods
  if payload.number ~= nil then
    goods = find_goods_by_number(payload.number, stand.Level)
  else
    goods = find_goods(payload.itemId, stand.Level)
  end
  if not goods then return self:fail(payload.itemId, "item", payload.number), true end
  if (goods.PurchaseLimit or 0) > 0 and req.env.data:PurchaseCount(goods.Number) >= goods.PurchaseLimit then
    return self:fail(payload.itemId, "limit", payload.number), true
  end
  return goods, false
end

--- 落库结算一次购买：写失败回 fail，成功回 reply 并同步树与任务事实。
local function commit_purchase(self, req, operation, goods)
  local env, payload, opts = req.env, req.payload, req.env.opts
  local player, data = env.player, env.data
  local result_value = nil
  local accepted = env.save:execute(player, data, operation, function(draft)
    local result, failure = settle_purchase(draft, goods)
    if not result then return nil, failure end
    if opts.quest and opts.quest.record_fact then
      opts.quest:record_fact(draft, "Buy", { itemId = result.itemId, eventId = operation.id })
    end
    return result
  end, function(written, result)
    if env.cleaned then return end
    if not written then self:fail(payload.itemId, result, payload.number) return end
    result.operation = operation
    result_value = result
    SpokeRuntime.batch(function()
      env.tree:sync_from_data(data)
    end)
    self:reply(result)
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

--- 动作处理（拆分前 mount 体内的 handle）。
function ShopBehavior.handle(self, actor, payload)
  local req = read_shop_request(self, actor, payload)
  if not req then return false end
  local operation = take_operation(self, req)
  if type(operation) == "boolean" then return operation end
  if req.action == "UpgradeStorage" then return self:upgrade_storage(operation) end
  local goods, failed = find_purchase(self, req)
  if failed then return goods end
  return commit_purchase(self, req, operation, goods)
end

--- 装配商店句柄：状态与依赖集中在 shop_env，方法由 ShopBehavior 提供。
--- 对外仍是 handle(actor, payload)（点调用）：订阅与导出共用同一个入口函数。
PlayerShop.mount = PlayerBehaviorKit.mounter({
  env_field = "shop_env", behavior = ShopBehavior, action_key = "shop",
})

return PlayerShop
