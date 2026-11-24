local GameCfg = require("common.game_cfg")
local BlindboxDraw = require("common.blindbox_draw")

local PlayerBlindbox = {}

local function cfg() return GameCfg.Blindbox end
local function goods(count) return count == 10 and "blindboxTen" or "blindboxSingle" end
local function bag(data)
  local extra = data.Extra
  if type(extra) ~= "table" then extra = {}; data.Extra = extra end
  local value = extra.lottery
  if type(value) ~= "table" then value = {}; extra.lottery = value end
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

function PlayerBlindbox.mount(scope, tree, opts)
  opts = type(opts) == "table" and opts or {}
  local player, data = tree.player, tree.data
  local save, platform, remote = opts.save, opts.platform, opts.remote
  local random = opts.random or math.random
  local working = false
  local disposed = false
  local outcomes = {}
  local lastSeq = nil

  local function reply(payload)
    if disposed or not remote or type(remote.GetRE) ~= "function" then return end
    local ok, event = pcall(remote.GetRE, remote, "BlindboxResult")
    if ok and event then event:FireClient(player, payload) end
  end
  local function sync_tree()
    if not disposed then tree:sync_from_data(data) end
  end
  local function current_token()
    local session = save and save.Sessions[player.UserId]
    return session and session.Token or nil
  end
  local function pending_for(key)
    for _, delivery in pairs(bag(data).deliveries) do
      if delivery.intent == key then return true end
    end
    return false
  end
  local function publish(result, key)
    local response = copy(result)
    local pending = pending_for(key)
    local intent = bag(data).intents[key]
    response.deliveryPending = pending
    response.seq, response.requestId = intent and intent.seq, key
    if intent and intent.token ~= current_token() then response.recovered = true end
    if pending then response.grounded = 0 end
    reply(response)
  end
  local function write(kind, transform, done)
    if disposed or working then return false, "pending" end
    local op, why = save:NextOperation(player, kind)
    if not op then return false, why or "pending" end
    working = true
    local accepted, reason = save:Execute(player, data, op, transform, function(ok, result)
      working = nil
      if ok then sync_tree() end
      done(ok, result, op)
    end)
    if not accepted then
      working = nil
      reply({ ok = false, reason = reason, deliveryPending = true })
    end
    return accepted, reason
  end

  local settle
  local pump

  settle = function(draft, count, key)
    local value = bag(draft)
    local before = value.pity or 0
    local draws, after = BlindboxDraw.DrawMany(count, before, random)
    if not draws then return nil, "roll" end
    local grounded = 0
    for index, draw in ipairs(draws) do
      for fishId, fish in pairs(GameCfg.Fish) do
        for _, drop in ipairs(fish.Drops or {}) do
          if drop.ItemId == draw.itemKey then draft.Extra.collection.unlocked[fishId] = true end
        end
      end
      draw.landed = not draft:AddItem(draw.itemKey, 1)
      if draw.landed then
        grounded = grounded + 1
        local deliveryKey = key .. ":" .. index
        value.deliveries[deliveryKey] = {
          itemId = draw.itemKey, epoch = opts.delivery_epoch, intent = key,
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

  pump = function()
    if disposed or working then return end
    local value = bag(data)
    for _, key in ipairs(sorted_keys(value.intents)) do
      local intent = value.intents[key]
      local outcome = outcomes[key]
      if outcome then
        write("blindbox:paid", function(draft)
          local intentDraft = bag(draft).intents[key]
          if intentDraft then
            intentDraft.state = outcome == "success" and "paid" or "cancelled"
          end
          prune(bag(draft))
          return { ok = true }
        end, function(ok)
          if ok then outcomes[key] = nil; pump() end
        end)
        return
      elseif intent.state == "paid" then
        write("blindbox", function(draft)
          local result, reason = settle(draft, intent.count, key)
          if not result then return nil, reason end
          local intentDraft = bag(draft).intents[key]
          intentDraft.state, intentDraft.result = "settled", result
          prune(bag(draft))
          return result
        end, function(ok, result)
          if not ok then reply({ ok = false, reason = result, deliveryPending = true }) return end
          publish(result, key)
          pump()
        end)
        return
      end
    end

    local origin = player.Character and player.Character.Position
    if not origin then return end
    local world = opts.world
    if not world or type(world.place_delivery) ~= "function" then return end
    for _, key in ipairs(sorted_keys(value.deliveries)) do
      local delivery = value.deliveries[key]
      if delivery.epoch == nil or delivery.epoch == opts.delivery_epoch then
        local receipt, reason = world:place_delivery(key, "fishPond", {
          kind = "item", itemId = delivery.itemId, count = 1, mult = 1,
          x = origin.x, y = origin.y, z = origin.z + 2,
        })
        if not receipt then
          print("[PlayerBlindbox] 待交付保留", player.UserId, key, tostring(reason))
          return
        end
        write("blindbox:delivery", function(draft)
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

  local function push_state()
    local recovery
    for _, key in ipairs(sorted_keys(bag(data).intents)) do
      local intent = bag(data).intents[key]
      if intent.state == "awaiting" or intent.state == "paid" then
        recovery = {
          requestId = key, seq = intent.seq,
          reason = intent.state == "awaiting" and not outcomes[key]
            and not platform:HasFlow(player) and "unknown" or "pending",
        }
        break
      end
    end
    reply({
      ok = true, action = "State", recovery = recovery,
      pity = bag(data).pity or 0, guaranteeAt = cfg().Pity.afterMisses + 1,
    })
  end

  local function on_action(actor, payload)
    if disposed or actor ~= player or type(payload) ~= "table"
      or (payload.action ~= "Draw" and payload.action ~= "Query") then
      return false
    end
    local count, seq = payload.count, payload.seq
    if (count ~= 1 and count ~= 10) or type(seq) ~= "number" or seq ~= math.floor(seq)
      or seq < 1 or seq > 2147483647 or not save or not platform then
      return false
    end
    local token = current_token()
    if not token then return false end
    local key = payload.action == "Query" and payload.requestId or nil
    key = key or token .. ":blindbox:" .. seq
    local existing = bag(data).intents[key]
    if existing then
      if existing.result then
        publish(existing.result, key)
        pump()
        return true
      end
      local reason = existing.state == "cancelled" and "cancel"
        or (existing.token ~= token and existing.state == "awaiting" and not outcomes[key] and "unknown")
        or "pending"
      reply({ ok = false, reason = reason, requestId = key, seq = seq, deliveryPending = reason ~= "cancel" })
      pump()
      return true
    end
    if payload.action == "Query" then
      reply({ ok = false, reason = "expired", seq = seq })
      return true
    end
    local available, unavailable = platform:CanPurchase(player, goods(count))
    if not available then
      reply({ ok = false, reason = unavailable })
      return true
    end
    for pendingKey, intent in pairs(bag(data).intents) do
      if intent.state == "awaiting" or intent.state == "paid" then
        reply({
          ok = false,
          reason = intent.token ~= token and intent.state == "awaiting" and not outcomes[pendingKey]
            and "unknown" or "busy",
          requestId = pendingKey, originalSeq = intent.seq, seq = seq, deliveryPending = true,
        })
        return true
      end
    end
    local value = bag(data)
    if value.seqToken == token and seq <= (value.highSeq or 0) then
      reply({ ok = false, reason = "expired" })
      return true
    end
    if platform:HasFlow(player) or working then
      reply({ ok = false, reason = "busy" })
      return true
    end
    if lastSeq and seq <= lastSeq then return false end
    lastSeq = seq
    local accepted, why = write("blindbox:intent", function(draft)
      local draftBag = bag(draft)
      draftBag.order = (draftBag.order or 0) + 1
      draftBag.seqToken, draftBag.highSeq = token, seq
      draftBag.intents[key] = { state = "awaiting", count = count, token = token, seq = seq, order = draftBag.order }
      return { ok = true }
    end, function(written, reason)
      if not written then reply({ ok = false, reason = reason }) return end
      local opened, failure = platform:Purchase(player, goods(count), "blindbox", function(outcome)
        if disposed then return end
        outcomes[key] = outcome
        if outcome ~= "success" then
          reply({ ok = false, reason = outcome, seq = seq, requestId = key })
        end
        pump()
      end)
      if not opened then
        outcomes[key] = failure or "unavailable"
        reply({ ok = false, reason = failure or "unavailable", seq = seq, requestId = key })
        pump()
      end
    end)
    if not accepted then reply({ ok = false, reason = why or "pending" }) end
    return true
  end

  scope:on_cleanup(function()
    disposed = true
    outcomes = {}
  end)
  push_state()
  pump()
  return { handle = on_action, step = pump, push_state = push_state }
end

return PlayerBlindbox
