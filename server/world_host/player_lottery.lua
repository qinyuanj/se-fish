local EngineRead = require("common.engine_read"); local GameCfg = require("common.game_cfg")
local DeepCopy = require("common.deep_copy")
local Eligibility = require("common.lottery_eligibility")
local Draw = require("common.lottery_draw")

local PlayerLottery = {}
local LotteryBehavior = {}
local ITEM_BAR = GameCfg.Items.ContainerId.ItemBar

local function settle(target, slot, random)
  if type(slot) ~= "number" or slot ~= math.floor(slot)
    or slot < 1 or slot > target:ItemBarCapacity() then
    return nil, "slot"
  end
  local items = target.data.containers[ITEM_BAR]
  local entry = items[slot]
  if not entry or entry.count <= 0 then return nil, "slot" end
  local eligible, reason = Eligibility.check(entry)
  if not eligible then return nil, reason end
  local price = GameCfg.Items.sale_price(entry.itemId, entry.mult)
  if not price or price < 1 then return nil, "bad-item" end
  local axes = Draw.roll_axes(random)
  if not axes then return nil, "roll" end
  local outcome = Draw.evaluate(axes)
  local definition = GameCfg.Items.Definitions[entry.itemId]
  local result = {
    ok = true, action = "Draw", slot = slot, itemId = entry.itemId,
    itemName = definition and definition.Name or entry.itemId,
    betValue = price, axes = axes, outcome = outcome.outcome,
    coinBefore = target.data.FishCoin,
  }
  items[slot] = nil
  if outcome.outcome == "pair" then
    local pattern = GameCfg.Lottery.Patterns[outcome.pattern]
    local coins = price * pattern.pairMultiplier
    target:AddCoin(coins, nil, "lottery:pair")
    result.coins, result.multiplier, result.patternName = coins, pattern.pairMultiplier, pattern.name
  elseif outcome.outcome == "triple" then
    local pattern = GameCfg.Lottery.Patterns[outcome.pattern]
    local reward = pattern.tripleReward
    if reward.kind == "weaponChoice" then
      local itemId = Draw.choose_weapon(pattern, random)
      if not itemId then
        items[slot] = entry
        return nil, "roll"
      end
      target:GrantWeapon(itemId, 1)
      local prizeDef = GameCfg.Items.Definitions[itemId]
      result.prize = { kind = "weapon", itemId = itemId, name = prizeDef and prizeDef.Name or itemId }
    else
      items[slot] = { itemId = reward.itemKey, count = 1, containerId = ITEM_BAR }
      result.prize = { kind = "item", itemId = reward.itemKey, name = reward.itemName }
    end
    result.patternName = pattern.name
  end
  result.coinAfter = target.data.FishCoin
  return result
end

-- ===== 抽奖动作：拆分前 PlayerLottery.mount 体内的闭包 =====
-- LotteryBehavior 是抽奖实例的方法表，方法名、参数顺序与返回值与拆分前的闭包一致；
-- 拆分前从 mount 的 upvalue 读取的依赖统一放进 lottery.lottery_env。

--- 结果下发（拆分前 mount 体内的 reply）。
--- 结果下发：已销毁直接拒绝，失败打印并返回 ok, reason（生成器见 EngineRead.client_reply）。
--- 抽奖环境的销毁态直接挂在 env.disposed 上（与盲盒/平台商店的 lifecycle 不同）。
LotteryBehavior.reply = EngineRead.client_reply("lottery_env", {
  tag = "PlayerLottery", channel = "LotteryResult", context = "PlayerLottery.reply", field = "action",
  returns = "status", disposed_on = "env",
})

--- 数据同步（拆分前 mount 体内的 sync_tree）。
function LotteryBehavior.sync_tree(self)
  local env = self.lottery_env
  if not env.disposed then env.tree:sync_from_data(env.data) end
end

--- 幂等执行包裹（拆分前 mount 体内的 execute）。
function LotteryBehavior.execute(self, operation, transform, done)
  local env = self.lottery_env
  local save = env.save
  if not operation or not save then return false end
  return save:execute(env.player, env.data, operation, transform, function(written, result)
    if written then
      result.operation = operation
      self:sync_tree()
    end
    done(written, result, operation)
  end)
end

--- 解析幂等请求（拆分前 mount 体内的 resolve）。
function LotteryBehavior.resolve(self, payload)
  local env = self.lottery_env
  local requestId = payload.operation
  if requestId ~= nil and type(requestId) ~= "table" then return nil, false end
  if requestId == nil then requestId = payload.seq end
  local operation, mode = env.save:resolve_request(env.player, env.data, "lottery", requestId)
  if not operation then return nil, false end
  if mode ~= "replay" then return operation end
  local accepted = self:execute(operation, function() return nil, "expired" end, function(ok, result)
    if ok then self:reply(result) end
  end)
  return nil, accepted
end

--- 恢复上一局已落账的抽奖结果（拆分前 mount 体内的 push_recovered）。
function LotteryBehavior.push_recovered(self)
  local env = self.lottery_env
  local data = env.data
  local meta = data and data.save_meta
  local operations = meta and meta.operations
  local last = operations and operations[#operations]
  if not last or last.kind ~= "lottery" or last.sequence ~= meta.sequence
    or type(last.result) ~= "table" or not last.result.ok then
    return
  end
  local result = DeepCopy.copy(last.result)
  result.recovered = true
  result.operation = { id = last.id, sequence = last.sequence, kind = last.kind, request_key = last.request_key }
  self:reply(result)
end

--- 动作处理（拆分前 mount 体内的 on_action）。
function LotteryBehavior.on_action(self, actor, payload)
  local env = self.lottery_env
  local player, data, opts = env.player, env.data, env.opts
  if env.disposed or actor ~= player or type(payload) ~= "table" or payload.action ~= "Draw" then return false end
  local seq = payload.seq
  if payload.operation == nil and (type(seq) ~= "number" or seq ~= math.floor(seq)
    or seq < 1 or seq > 2147483647) then
    return false
  end
  if not env.save then return false end
  local operation, replayed = self:resolve(payload)
  if not operation then return replayed end
  if env.last_seq and seq and seq <= env.last_seq then return false end
  local slot = payload.slot
  if type(slot) ~= "number" or slot ~= math.floor(slot) then return false end
  env.last_seq = seq

  if type(opts.in_range) ~= "function" or not opts.in_range(player) then
    self:reply({ ok = false, reason = "range" })
    return false
  end
  local items = data.data.containers[ITEM_BAR]
  local entry = slot >= 1 and slot <= data:ItemBarCapacity() and items[slot]
  if not entry or entry.count <= 0 then
    self:reply({ ok = false, reason = "slot" })
    return false
  end
  local eligible, reason = Eligibility.check(entry)
  if not eligible then
    self:reply({ ok = false, reason = reason })
    return false
  end
  return self:execute(operation, function(draft)
    return settle(draft, slot, env.random)
  end, function(written, result)
    if not written then self:reply({ ok = false, reason = result }) return end
    self:reply(result)
  end)
end

--- 装配抽奖实例：状态与依赖集中在 lottery_env，方法由 LotteryBehavior 提供。
--- 对外仍是 handle(actor, payload) 与 push_state()（点调用）：订阅、首推与导出共用同一入口函数。
function PlayerLottery.mount(scope, tree, opts)
  opts = type(opts) == "table" and opts or {}
  ---@type table<string, any>
  local lottery = {
    lottery_env = {
      player = tree.player,
      data = tree.data,
      save = opts.save,
      remote = opts.remote,
      random = opts.random or math.random,
      tree = tree,
      opts = opts,
      disposed = false,
      last_seq = nil,
    },
  }
  for name, method in pairs(LotteryBehavior) do
    lottery[name] = method
  end
  local function handle_action(actor, payload)
    return lottery:on_action(actor, payload)
  end
  local function push_state()
    return lottery:push_recovered()
  end
  if tree.actions and tree.actions.lottery then
    scope:subscribe(tree.actions.lottery, function(event)
      event.result = handle_action(tree.player, event.payload)
    end)
    scope:subscribe(tree.actions.lottery_state, function(event)
      push_state()
      event.result = true
    end)
  end
  scope:on_cleanup(function() lottery.lottery_env.disposed = true end)
  push_state()
  return { handle = handle_action, push_state = push_state }
end

return PlayerLottery
