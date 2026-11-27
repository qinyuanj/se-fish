local EngineRead = require("common.engine_read")
local GameCfg = require("common.game_cfg")
local SpokeRuntime = require("common.packages.spoke.runtime.spoke_runtime")
local InteractionPoints = require("server.world_host.interaction_points")
local PlayerBehaviorKit = require("server.world_host.player_behavior_kit")

local PlayerFisherman = {}
local FishermanBehavior = {}
local ITEM_BAR = GameCfg.Items.ContainerId.ItemBar

local function selected_entry(data)
  local items = data.data.containers[ITEM_BAR]
  local slot = data.data.selected_slot
  local entry = slot and items[slot]
  if entry and entry.count > 0 then return slot, entry end
  return nil
end

local function fisherman_point(shared, npc)
  local point = {}
  for key, value in pairs(shared) do point[key] = value end
  point.ZoneId, point.AnchorNames = npc.ZoneId, npc.AnchorNames
  point.Exchange, point.Chain = npc.Exchange, npc.Chain
  return point
end

local function resolve_fisherman(player)
  local shared = GameCfg.Interact.Fisherman
  for _, npc in ipairs(GameCfg.Interact.Fishermen) do
    local anchor = InteractionPoints:in_range(player, {
      AnchorNames = npc.AnchorNames,
      Radius = shared.Radius,
      Slack = shared.Slack,
    })
    if anchor then return fisherman_point(shared, npc), anchor end
  end
  return nil, nil
end

local function saleable(data, point)
  local slot, entry = selected_entry(data)
  if entry then
    local rate = GameCfg.Items.cook_rate(entry)
    local price = GameCfg.Items.sale_price(entry.itemId, entry.mult, rate)
    if price then
      return price, function(d) d.containers[ITEM_BAR][slot] = nil end,
          entry.itemId, GameCfg.Fish[entry.itemId] and "fish" or "item"
    end
  end
  local bait_id = data.data.selected_bait
  local price = bait_id and point.BaitPrice[bait_id]
  local count = bait_id and data.data.Bait[bait_id]
  if price and type(count) == "number" and count >= 1 then
    return price, function(d) d.Bait[bait_id] = d.Bait[bait_id] - 1 end, bait_id, "bait"
  end
  return nil
end

local function item_count(data, item_id)
  return data.data.Bait[item_id] or data:ItemCount(item_id)
end

local function exchangeable(data, point)
  local slot, entry = selected_entry(data)
  local product = entry and GameCfg.Items.cook_rate(entry) == nil
      and point.Exchange and point.Exchange[entry.itemId]
  if not product then return nil end
  return { slot = slot, tokenId = entry.itemId, product = product }
end

local function product_of(product)
  if type(product) ~= "string" then return nil end
  local achievement = product:match("^achievement%.(.+)$")
  if achievement then return { achievement = achievement } end
  return { itemId = product }
end

local function deliver(target, exchange, product)
  local items = target.data.containers[ITEM_BAR]
  local kept = items[exchange.slot]
  if not kept or kept.count <= 0 or kept.itemId ~= exchange.tokenId then return false, "nothing" end
  if product.achievement and target.extra.achievements and target.extra.achievements[product.achievement] then
    return false, "already-completed"
  end
  items[exchange.slot] = nil
  if product.achievement then
    target.extra.achievements = target.extra.achievements or {}
    target.extra.achievements[product.achievement] = true
  elseif not target:CanGrant(product.itemId, 1) or not target:GrantItem(product.itemId, 1) then
    items[exchange.slot] = kept
    return false, "full"
  end
  if target.data.selected_slot == exchange.slot then target.data.selected_slot = nil end
  return true
end

--- 吃动作播放：仅日志兜底，不读 mount 的 upvalue（拆分前 mount 体内的 play_eat）。
local function play_eat(anchor, point)
  if not point.EatAnimation then return end
  local ok_read, play = pcall(function() return anchor.PlayAnimation end)
  if not ok_read or not play then return end
  local ok, err = pcall(play, anchor, point.EatAnimation)
  if not ok then print("[PlayerFisherman] 吃动作播放失败", tostring(err)) end
end

-- ===== 渔夫交互：拆分前 PlayerFisherman.mount 体内的闭包 =====
-- FishermanBehavior 是交互实例的方法表，方法名、参数顺序与返回值与拆分前的闭包一致；
-- 拆分前从 mount 的 upvalue 读取的依赖统一放进 fisherman.fisherman_env。

--- 结果下发（拆分前 mount 体内的 reply）：失败打印带模块标签，逻辑见 EngineRead.client_sender。
FishermanBehavior.reply = EngineRead.client_reply("fisherman_env", {
  tag = "PlayerFisherman", channel = "InteractResult", context = "PlayerFisherman.reply", field = "action",
})

--- 解析幂等请求（拆分前 mount 体内的 resolve）：重放命中时回放结果，逻辑见 PlayerBehaviorKit.resolve_fn。
FishermanBehavior.resolve = PlayerBehaviorKit.resolve_fn(FishermanBehavior, {
  env_field = "fisherman_env", kind = "interact:fisherman",
})

--- 信物兑换（拆分前 mount 体内的 exchange）。
function FishermanBehavior.exchange(self, operation, point, anchor, request)
  local env = self.fisherman_env
  local player, data, save = env.player, env.data, env.save
  local product = product_of(request.product)
  if not product then return false end
  if save:is_paused(player.UserId) then
    self:reply({ ok = false, reason = "临时本局暂停信物兑换，请先保存到存档" })
    return false
  end
  local result_value = nil
  local accepted = save:execute(player, data, operation, function(draft)
    local entry = draft.data.containers[ITEM_BAR][request.slot]
    if not entry or entry.itemId ~= request.tokenId then return nil, "nothing" end
    local before_token = item_count(draft, request.tokenId)
    local before_product = item_count(draft, request.product)
    local changed, failure = deliver(draft, request, product)
    if not changed then return nil, failure end
    local result = {
      ok = true, action = "Feed", exchange = { from = request.tokenId, to = request.product },
      coinBefore = draft.data.FishCoin, coinAfter = draft.data.FishCoin,
      tokenBefore = before_token, tokenAfter = item_count(draft, request.tokenId),
      itemBefore = before_product, itemAfter = item_count(draft, request.product),
    }
    if product.achievement then result.achievement = product.achievement end
    return result
  end, function(written, result)
    if env.cleaned then return end
    if not written then self:reply({ ok = false, reason = result }) return end
    result.operation = operation
    result_value = result
    SpokeRuntime.batch(function() env.tree:sync_from_data(data) end)
    self:reply(result)
    play_eat(anchor, point)
  end)
  if accepted ~= true then return false end
  return result_value ~= nil or true
end

--- 卖鱼与吃鱼（拆分前 mount 体内的 feed）。
function FishermanBehavior.feed(self, operation, point, anchor)
  local env = self.fisherman_env
  local player, data, save, opts = env.player, env.data, env.save, env.opts
  local selected_slot, selected_bait = data.data.selected_slot, data.data.selected_bait
  local result_value = nil
  local accepted = save:execute(player, data, operation, function(draft)
    draft.data.selected_slot, draft.data.selected_bait = selected_slot, selected_bait
    local earned, consume, item_id, category = saleable(draft, point)
    if not earned then return nil, "nothing" end
    local before_coin, before_item = draft.data.FishCoin, item_count(draft, item_id)
    if not draft:AddCoin(earned, consume, "feed") then return nil, "nothing" end
    if opts.quest and opts.quest.record_fact then
      opts.quest:record_fact(draft, "Feed", {
        itemId = item_id, category = category, eventId = operation.id,
      })
    end
    return {
      ok = true, action = "Feed", coins = earned, itemId = item_id, category = category,
      coinBefore = before_coin, coinAfter = draft.data.FishCoin,
      itemBefore = before_item, itemAfter = item_count(draft, item_id),
    }
  end, function(written, result)
    if env.cleaned then return end
    if not written then self:reply({ ok = false, reason = result }) return end
    result.operation = operation
    result_value = result
    SpokeRuntime.batch(function() env.tree:sync_from_data(data) end)
    self:reply(result)
    play_eat(anchor, point)
    if opts.quest and opts.quest.record_fact then
      if opts.quest.refresh_committed then opts.quest:refresh_committed(player, data) end
    elseif opts.quest and opts.quest.notify then
      opts.quest:notify("Feed", player, {
        itemId = result.itemId, category = result.category, eventId = operation.id,
      })
    end
  end)
  if accepted ~= true then return false end
  return result_value ~= nil or true
end

--- 动作处理（拆分前 mount 体内的 handle）。
function FishermanBehavior.handle(self, actor, payload)
  local env = self.fisherman_env
  local player, data = env.player, env.data
  if env.cleaned or actor ~= player or type(payload) ~= "table"
      or payload.target ~= "fisherman" or payload.action ~= "Feed" then return false end
  local seq = payload.seq
  if payload.operation == nil and (type(seq) ~= "number" or seq ~= math.floor(seq)
      or seq < 1 or seq > 2147483647) then return false end
  local operation, replayed = self:resolve(payload)
  if not operation then return replayed == true end
  if payload.operation == nil then
    if seq <= env.last_seq then return false end
    env.last_seq = seq
  end
  local point, anchor = resolve_fisherman(player)
  if not point then return false end
  local request = exchangeable(data, point)
  if request then return self:exchange(operation, point, anchor, request) end
  return self:feed(operation, point, anchor)
end

--- 装配渔夫交互实例：状态与依赖集中在 fisherman_env，方法由 FishermanBehavior 提供。
--- 对外仍是 handle(actor, payload)（点调用）：订阅与导出共用同一个入口函数。
PlayerFisherman.mount = PlayerBehaviorKit.mounter({
  env_field = "fisherman_env", behavior = FishermanBehavior, action_key = "interact",
})

return PlayerFisherman
