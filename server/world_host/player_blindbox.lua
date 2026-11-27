local EngineRead = require("common.engine_read"); local GameCfg = require("common.game_cfg")
local DeepCopy = require("common.deep_copy")
local BlindboxDraw = require("common.blindbox_draw")
local PlayerBehaviorKit = require("server.world_host.player_behavior_kit")

local PlayerBlindbox = {}
-- 盲盒行为表：拆分前都是 PlayerBlindbox.mount 体内的闭包，依赖统一从树上的 blindbox_env 读取。
local BlindboxBehavior = {}

local function cfg() return GameCfg.Blindbox end
local function goods(count) return count == 10 and "blindboxTen" or "blindboxSingle" end
-- 意图袋与推进方法（帧活跃 / 同步树 / 令牌 / 单次写档）按存档键从共用件生成。
local box, bag = PlayerBehaviorKit.methods(BlindboxBehavior, { env_field = "blindbox_env", bag_key = "lottery" })
local sorted_keys = PlayerBehaviorKit.sorted_keys
local function prune(value)
  local keep = {}
  for key, intent in pairs(value.intents) do
    local pending = false
    for _, delivery in pairs(value.deliveries) do
      if delivery.intent == key then pending = true end
    end
    if not pending and (intent.state == "settled" or intent.state == "cancelled") then
      keep[#keep + 1] = { key = key, order = intent.order or 0 }
    end
  end
  table.sort(keep, function(a, b) return a.order < b.order end)
  for index = 1, #keep - 32 do value.intents[keep[index].key] = nil end
end

-- ===== 环境与行为表 =====

-- 建盲盒环境：拆分前 mount 开头的局部变量全部收进 env，行为方法只从 blindbox_env 取依赖。
function BlindboxBehavior.new_env(tree, opts)
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
    random = opts.random or math.random,
    working = false, ---@type boolean?
    lifecycle = { disposed = false }, ---@type { disposed: boolean }
    outcomes = outcomes,
    last_seq = nil, ---@type number?
    frame_active = State.new("PlayerBlindbox.frame_active", false),
  }
end

function BlindboxBehavior.is_disposed(self)
  return self.blindbox_env.lifecycle.disposed
end

-- 帧相位活跃判定：有待交付或未结清的 intent 才订阅 on_frame 推进。
BlindboxBehavior.sync_frame_active = box.sync_frame_active

--- 结果下发：已销毁直接拒绝，失败打印并返回 ok, reason（生成器见 EngineRead.client_reply）。
BlindboxBehavior.reply = EngineRead.client_reply("blindbox_env", {
  tag = "PlayerBlindbox", channel = "BlindboxResult", context = "PlayerBlindbox.reply", field = "action",
  returns = "status",
})

BlindboxBehavior.sync_tree = box.sync_tree

BlindboxBehavior.current_token = box.current_token

function BlindboxBehavior.pending_for(self, key)
  for _, delivery in pairs(bag(self.blindbox_env.data).deliveries) do
    if delivery.intent == key then return true end
  end
  return false
end

function BlindboxBehavior.publish(self, result, key)
  local env = self.blindbox_env
  local response = DeepCopy.copy(result)
  local pending = BlindboxBehavior.pending_for(self, key)
  local intent = bag(env.data).intents[key]
  response.deliveryPending = pending
  response.seq, response.requestId = intent and intent.seq, key
  if intent and intent.token ~= BlindboxBehavior.current_token(self) then response.recovered = true end
  if pending then response.grounded = 0 end
  BlindboxBehavior.reply(self, response)
end

BlindboxBehavior.write = box.write

-- 抽卡结算：在写档草稿上落 collection / pity / 待交付。
function BlindboxBehavior.settle(self, draft, count, key)
  local env = self.blindbox_env
  local value = bag(draft)
  local before = value.pity or 0
  local draws, after = BlindboxDraw.draw_many(count, before, env.random)
  if not draws then return nil, "roll" end
  local grounded = 0
  for index, draw in ipairs(draws) do
    for fishId, fish in pairs(GameCfg.Fish) do
      for _, drop in ipairs(fish.Drops or {}) do
        if drop.ItemId == draw.itemKey then draft.extra.collection.unlocked[fishId] = true end
      end
    end
    draw.landed = not draft:AddItem(draw.itemKey, 1)
    if draw.landed then
      grounded = grounded + 1
      local deliveryKey = key .. ":" .. index
      value.deliveries[deliveryKey] = {
        itemId = draw.itemKey, epoch = env.opts.delivery_epoch, intent = key,
      }
    end
    draw.pityBefore, draw.index = nil, nil
  end
  value.pity = after
  return {
    ok = true, action = "Draw", count = count, draws = draws,
    pityBefore = before, pityAfter = after, grounded = grounded,
    operation = { id = key },
  }
end

-- 推进机：先结清已付费 intent，再按顺序落地待交付；每次至多推进一个写档。
function BlindboxBehavior.pump(self)
  local env = self.blindbox_env
  local player, data = env.player, env.data
  if env.lifecycle.disposed then return end
  BlindboxBehavior.sync_frame_active(self)
  if env.working then return end
  local value = bag(data)
  for _, key in ipairs(sorted_keys(value.intents)) do
    local intent = value.intents[key]
    local outcome = env.outcomes[key]
    if outcome then
      BlindboxBehavior.write(self, "blindbox:paid", function(draft)
        local intentDraft = bag(draft).intents[key]
        if intentDraft then
          intentDraft.state = outcome == "success" and "paid" or "cancelled"
        end
        prune(bag(draft))
        return { ok = true }
      end, function(ok)
        if ok then env.outcomes[key] = nil; BlindboxBehavior.pump(self) end
      end)
      return
    elseif intent.state == "paid" then
      BlindboxBehavior.write(self, "blindbox", function(draft)
        local result, reason = BlindboxBehavior.settle(self, draft, intent.count, key)
        if not result then return nil, reason end
        local intentDraft = bag(draft).intents[key]
        intentDraft.state, intentDraft.result = "settled", result
        prune(bag(draft))
        return result
      end, function(ok, result)
        if not ok then BlindboxBehavior.reply(self, { ok = false, reason = result, deliveryPending = true }) return end
        BlindboxBehavior.publish(self, result, key)
        BlindboxBehavior.pump(self)
      end)
      return
    end
  end

  local origin = player.Character and player.Character.Position
  if not origin then return end
  local world = env.opts.world
  if not world or type(world.place_delivery) ~= "function" then return end
  for _, key in ipairs(sorted_keys(value.deliveries)) do
    local delivery = value.deliveries[key]
    if delivery.epoch == nil then
      print("[PlayerBlindbox] 跳过缺少 epoch 的遗留待交付", player.UserId, key)
    elseif delivery.epoch == env.opts.delivery_epoch then
      local receipt, reason = world:place_delivery(key, "fishPond", { kind = "item", itemId = delivery.itemId,
        count = 1, mult = 1, x = origin.x, y = origin.y, z = origin.z + 2 })
      if not receipt then
        print("[PlayerBlindbox] 待交付保留", player.UserId, key, tostring(reason))
        return
      end
      BlindboxBehavior.write(self, "blindbox:delivery", function(draft)
        bag(draft).deliveries[key] = nil
        return { ok = true }
      end, function(ok)
        if ok then
          local intent = bag(data).intents[delivery.intent]
          if intent and intent.result then BlindboxBehavior.publish(self, intent.result, delivery.intent) end
          BlindboxBehavior.pump(self)
        end
      end)
      return
    end
  end
end

function BlindboxBehavior.push_state(self)
  local env = self.blindbox_env
  local data = env.data
  local recovery
  for _, key in ipairs(sorted_keys(bag(data).intents)) do
    local intent = bag(data).intents[key]
    if intent.state == "awaiting" or intent.state == "paid" then
      recovery = {
        requestId = key, seq = intent.seq,
        reason = intent.state == "awaiting" and not env.outcomes[key]
          and not env.platform:has_flow(env.player) and "unknown" or "pending",
      }
      break
    end
  end
  BlindboxBehavior.reply(self, {
    ok = true, action = "State", recovery = recovery,
    pity = bag(data).pity or 0, guaranteeAt = cfg().Pity.afterMisses + 1,
  })
end

-- 校验请求并解出购买上下文：不合法时返回 nil，调用方直接回 false。
local function read_draw_request(self, actor, payload)
  local env = self.blindbox_env
  if env.lifecycle.disposed or actor ~= env.player or type(payload) ~= "table"
    or (payload.action ~= "Draw" and payload.action ~= "Query") then
    return nil
  end
  local count, seq = payload.count, payload.seq
  if (count ~= 1 and count ~= 10) or type(seq) ~= "number" or seq ~= math.floor(seq)
    or seq < 1 or seq > 2147483647 or not env.save or not env.platform then
    return nil
  end
  local token = BlindboxBehavior.current_token(self)
  if not token then return nil end
  local key = payload.action == "Query" and payload.requestId or nil
  return {
    env = env, action = payload.action, count = count, seq = seq, token = token,
    key = key or token .. ":blindbox:" .. seq,
  }
end

-- 同一个 key 的重复请求：有结果就回放，否则回 cancel / unknown / pending。
local function reply_existing_intent(self, req)
  local existing = bag(req.env.data).intents[req.key]
  if not existing then return false end
  if existing.result then
    BlindboxBehavior.publish(self, existing.result, req.key)
    BlindboxBehavior.pump(self)
    return true
  end
  local reason = existing.state == "cancelled" and "cancel"
    or (existing.token ~= req.token and existing.state == "awaiting" and not req.env.outcomes[req.key] and "unknown")
    or "pending"
  BlindboxBehavior.reply(self, { ok = false, reason = reason, requestId = req.key, seq = req.seq, deliveryPending = reason ~= "cancel" })
  BlindboxBehavior.pump(self)
  return true
end

-- Query 只认已有 intent；新建请求先过商品可购检查。
local function reply_expired_or_unpurchasable(self, req)
  if req.action == "Query" then
    BlindboxBehavior.reply(self, { ok = false, reason = "expired", seq = req.seq })
    return true
  end
  local available, unavailable = req.env.platform:can_purchase(req.env.player, goods(req.count))
  if available then return false end
  BlindboxBehavior.reply(self, { ok = false, reason = unavailable })
  return true
end

-- 还有未结清的 intent 时拒绝并发抽奖，并带上原请求信息。
local function reply_pending_conflict(self, req)
  local env = req.env
  for pending_key, intent in pairs(bag(env.data).intents) do
    if intent.state == "awaiting" or intent.state == "paid" then
      BlindboxBehavior.reply(self, {
        ok = false,
        reason = intent.token ~= req.token and intent.state == "awaiting" and not env.outcomes[pending_key]
          and "unknown" or "busy",
        requestId = pending_key, originalSeq = intent.seq, seq = req.seq, deliveryPending = true,
      })
      return true
    end
  end
  return false
end

-- 过期序号与平台流水线忙碌：只回错误，不改状态。
local function reply_stale_or_busy(self, req)
  local env = req.env
  local value = bag(env.data)
  if value.seqToken == req.token and req.seq <= (value.highSeq or 0) then
    BlindboxBehavior.reply(self, { ok = false, reason = "expired" })
    return true
  end
  if env.platform:has_flow(env.player) or env.working then
    BlindboxBehavior.reply(self, { ok = false, reason = "busy" })
    return true
  end
  return false
end

-- 记下本回合最高序号；等于旧序号的重发按未处理返回，让上层静默丢弃。
local function accept_sequence(req)
  local env = req.env
  if env.last_seq and req.seq <= env.last_seq then return false end
  env.last_seq = req.seq
  return true
end

-- 落库 intent 再发起平台购买；写失败、打开失败与异步结果都回 reply + pump。
local function open_purchase(self, req)
  local env = req.env
  local accepted, why = BlindboxBehavior.write(self, "blindbox:intent", function(draft)
    local draft_bag = bag(draft)
    draft_bag.order = (draft_bag.order or 0) + 1
    draft_bag.seqToken, draft_bag.highSeq = req.token, req.seq
    draft_bag.intents[req.key] = { state = "awaiting", count = req.count, token = req.token, seq = req.seq, order = draft_bag.order }
    return { ok = true }
  end, function(written, reason)
    if not written then BlindboxBehavior.reply(self, { ok = false, reason = reason }) return end
    local opened, failure = env.platform:purchase(env.player, goods(req.count), "blindbox", function(outcome)
      if BlindboxBehavior.is_disposed(self) then return end
      env.outcomes[req.key] = outcome
      if outcome ~= "success" then
        BlindboxBehavior.reply(self, { ok = false, reason = outcome, seq = req.seq, requestId = req.key })
      end
      BlindboxBehavior.pump(self)
    end)
    if not opened then
      env.outcomes[req.key] = failure or "unavailable"
      BlindboxBehavior.reply(self, { ok = false, reason = failure or "unavailable", seq = req.seq, requestId = req.key })
      BlindboxBehavior.pump(self)
    end
  end)
  if not accepted then BlindboxBehavior.reply(self, { ok = false, reason = why or "pending" }) end
end

function BlindboxBehavior.on_action(self, actor, payload)
  local req = read_draw_request(self, actor, payload)
  if not req then return false end
  if reply_existing_intent(self, req) then return true end
  if reply_expired_or_unpurchasable(self, req) then return true end
  if reply_pending_conflict(self, req) then return true end
  if reply_stale_or_busy(self, req) then return true end
  if not accept_sequence(req) then return false end
  open_purchase(self, req)
  return true
end

-- ===== 装配 =====

-- 把行为表挂到玩家树上；依赖统一从 tree.blindbox_env 读取。
function BlindboxBehavior.install(tree, env)
  tree.blindbox_env = env
end

-- Spoke 作用域接线：注册顺序与拆分前 mount 内的 subscribe / phase / cleanup 一致。
function BlindboxBehavior.wire(scope, tree)
  local env = tree.blindbox_env
  if tree.actions and tree.actions.blindbox then
    scope:subscribe(tree.actions.blindbox, function(event)
      event.result = BlindboxBehavior.on_action(tree, env.player, event.payload)
    end)
    scope:subscribe(tree.actions.blindbox_state, function(event)
      BlindboxBehavior.push_state(tree)
      event.result = true
    end)
  end
  scope:phase("BlindboxActiveFrame", env.frame_active, function(frame_scope)
    frame_scope:subscribe(tree.clock.on_frame, function() BlindboxBehavior.pump(tree) end)
  end)
  scope:on_cleanup(function()
    env.lifecycle.disposed = true
    env.outcomes = {}
  end)
  BlindboxBehavior.push_state(tree)
  BlindboxBehavior.pump(tree)
end

-- 挂载盲盒模块：先建环境并装配行为表，再按拆分前的顺序接线。
function PlayerBlindbox.mount(scope, tree, opts)
  local env = BlindboxBehavior.new_env(tree, opts)
  BlindboxBehavior.install(tree, env)
  BlindboxBehavior.wire(scope, tree)
  return {
    handle = function(actor, payload)
      return BlindboxBehavior.on_action(tree, actor, payload)
    end,
    step = function()
      BlindboxBehavior.pump(tree)
    end,
    push_state = function()
      BlindboxBehavior.push_state(tree)
    end,
  }
end

return PlayerBlindbox
