-- 抽奖机单玩家活跃会话（#312 / ADR-0032）。
-- 投注资格与范围先校验，MgrSave 隔离 draft 内一次完成消耗和金币/物品/武器大奖；
-- 写确认后由 PlayerTree 单批投影库存与金币，会话随 alive 相位和离场销毁。
local GameCfg = require("common.GameCfg")
local Eligibility = require("common.LotteryEligibility")
local Draw = require("common.LotteryDraw")

local PlayerLottery = {}
local ITEM_BAR = GameCfg.Items.ContainerId.ItemBar

local function copy(value)
  if type(value) ~= "table" then return value end
  local out = {}
  for key, item in pairs(value) do out[key] = copy(item) end
  return out
end

local function settle(target, slot, random)
  if type(slot) ~= "number" or slot ~= math.floor(slot)
    or slot < 1 or slot > target:ItemBarCapacity() then
    return nil, "slot"
  end
  local items = target.Data.Containers[ITEM_BAR]
  local entry = items[slot]
  if not entry or entry.count <= 0 then return nil, "slot" end
  local eligible, reason = Eligibility.Check(entry)
  if not eligible then return nil, reason end
  local price = GameCfg.Items.SalePrice(entry.itemId, entry.mult)
  if not price or price < 1 then return nil, "bad-item" end
  local axes = Draw.RollAxes(random)
  if not axes then return nil, "roll" end
  local outcome = Draw.Evaluate(axes)
  local definition = GameCfg.Items.Definitions[entry.itemId]
  local result = {
    ok = true, action = "Draw", slot = slot, itemId = entry.itemId,
    itemName = definition and definition.Name or entry.itemId,
    betValue = price, axes = axes, outcome = outcome.outcome,
    coinBefore = target.Data.FishCoin,
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
      local itemId = Draw.ChooseWeapon(pattern, random)
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
  result.coinAfter = target.Data.FishCoin
  return result
end

function PlayerLottery.mount(scope, tree, opts)
  opts = type(opts) == "table" and opts or {}
  local player, data = tree.player, tree.data
  local save, remote = opts.save, opts.remote
  local random = opts.random or math.random
  local disposed = false
  local lastSeq = nil

  local function reply(payload)
    if disposed or not remote or type(remote.GetRE) ~= "function" then return end
    local ok, event = pcall(remote.GetRE, remote, "LotteryResult")
    if ok and event then event:FireClient(player, payload) end
  end

  local function sync_tree()
    if not disposed then tree:sync_from_data(data) end
  end

  local function execute(operation, transform, done)
    if not operation or not save then return false end
    return save:Execute(player, data, operation, transform, function(written, result)
      if written then
        result.operation = operation
        sync_tree()
      end
      done(written, result, operation)
    end)
  end

  local function resolve(payload)
    local requestId = payload.operation
    if requestId ~= nil and type(requestId) ~= "table" then return nil, false end
    if requestId == nil then requestId = payload.seq end
    local operation, mode = save:ResolveRequest(player, data, "lottery", requestId)
    if not operation then return nil, false end
    if mode ~= "replay" then return operation end
    local accepted = execute(operation, function() return nil, "expired" end, function(ok, result)
      if ok then reply(result) end
    end)
    return nil, accepted
  end

  local function push_recovered()
    local meta = data and data.SaveMeta
    local operations = meta and meta.operations
    local last = operations and operations[#operations]
    if not last or last.kind ~= "lottery" or last.sequence ~= meta.sequence
      or type(last.result) ~= "table" or not last.result.ok then
      return
    end
    local result = copy(last.result)
    result.recovered = true
    result.operation = { id = last.id, sequence = last.sequence, kind = last.kind, requestKey = last.requestKey }
    reply(result)
  end

  local function on_action(actor, payload)
    if disposed or actor ~= player or type(payload) ~= "table" or payload.action ~= "Draw" then return false end
    local seq = payload.seq
    if payload.operation == nil and (type(seq) ~= "number" or seq ~= math.floor(seq)
      or seq < 1 or seq > 2147483647) then
      return false
    end
    if not save then return false end
    local operation, replayed = resolve(payload)
    if not operation then return replayed end
    if lastSeq and seq and seq <= lastSeq then return false end
    local slot = payload.slot
    if type(slot) ~= "number" or slot ~= math.floor(slot) then return false end
    lastSeq = seq

    if type(opts.in_range) ~= "function" or not opts.in_range(player) then
      reply({ ok = false, reason = "range" })
      return false
    end
    local items = data.Data.Containers[ITEM_BAR]
    local entry = slot >= 1 and slot <= data:ItemBarCapacity() and items[slot]
    if not entry or entry.count <= 0 then
      reply({ ok = false, reason = "slot" })
      return false
    end
    local eligible, reason = Eligibility.Check(entry)
    if not eligible then
      reply({ ok = false, reason = reason })
      return false
    end
    return execute(operation, function(draft)
      return settle(draft, slot, random)
    end, function(written, result)
      if not written then reply({ ok = false, reason = result }) return end
      reply(result)
    end)
  end

  scope:on_cleanup(function() disposed = true end)
  push_recovered()
  return { handle = on_action, push_state = push_recovered }
end

return PlayerLottery
