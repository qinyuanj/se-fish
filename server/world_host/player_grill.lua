
local GameCfg = require("common.game_cfg")
local BodyScale = require("common.body_scale")
local GrillCurve = require("common.grill_curve")
local Spoke = require("common.packages.spoke.api")
local SpokeRuntime = require("common.packages.spoke.runtime.spoke_runtime")

local State = Spoke.State
local PlayerGrill = {}

local ITEM_BAR = GameCfg.Items.ContainerId.ItemBar
local BACKPACK = GameCfg.Items.ContainerId.Backpack

local function cfg()
  return GameCfg.Grill
end

local function flat_distance(a, b)
  if not a or not b then return math.huge end
  local dx, dz = (a.x or 0) - (b.x or 0), (a.z or 0) - (b.z or 0)
  return math.sqrt(dx * dx + dz * dz)
end

local function is_token(item_id)
  local exchanges = GameCfg.Content and GameCfg.Content.Exchanges or {}
  for _, chain in ipairs(exchanges) do
    if chain.EliteToken == item_id or chain.BossToken == item_id then return true end
  end
  return false
end

local function grillable(entry)
  if type(entry) ~= "table" or (entry.count or 0) <= 0 then return false end
  local definition = GameCfg.Items.Definitions[entry.itemId]
  if not definition then return false end
  if definition.Type ~= "食物" and definition.Type ~= "极品食物" then return false end
  return GameCfg.Items.cook_rate(entry) == nil
end

local function selected_entry(data)
  local items = data and data.Data and data.Data.Containers and data.Data.Containers[ITEM_BAR]
  local slot = data and data.Data and data.Data.SelectedSlot
  local entry = slot and items and items[slot]
  if type(entry) == "table" and (entry.count or 0) > 0 then return slot, entry end
  return nil, nil
end

local function place(data, item_id, mult, rate, select_slot)
  local pairs_ = {
    { ITEM_BAR, data:ItemBarCapacity() },
    { BACKPACK, data:BackpackCapacity() },
  }
  for _, pair in ipairs(pairs_) do
    local items = data.Data.Containers[pair[1]]
    for index = 1, pair[2] do
      local entry = items[index]
      if not entry or (entry.count or 0) <= 0 then
        items[index] = {
          itemId = item_id,
          count = 1,
          containerId = pair[1],
          mult = mult,
          cooked = rate,
          saved = rate and { k = rate } or nil,
        }
        if select_slot and pair[1] == ITEM_BAR then data.Data.SelectedSlot = index end
        return true
      end
    end
  end
  return false
end

local function ensure_recovery(data)
  if type(data.Extra) ~= "table" then data.Extra = {} end
  if type(data.Extra.recovery) ~= "table" then data.Extra.recovery = {} end
  return data.Extra.recovery
end

local function reply(remote, player, payload)
  if remote and type(remote.get_re) == "function" then
    local ok, event = pcall(remote.get_re, remote, "GrillResult")
    if ok and event and type(event.FireClient) == "function" then
      pcall(event.FireClient, event, player, payload)
    end
  end
  return payload
end

local function push_state(remote, player, payload)
  if remote and type(remote.get_re) == "function" then
    local ok, event = pcall(remote.get_re, remote, "GrillState")
    if ok and event and type(event.FireClient) == "function" then
      pcall(event.FireClient, event, player, payload)
    end
  end
  return payload
end

local function fail(remote, player, reason, seq)
  return reply(remote, player, { seq = seq, ok = false, reason = reason })
end

local function find_anchor(world, name, cache)
  if cache[name] then return cache[name] end
  if not world or type(world.FindFirstChild) ~= "function" then return nil end
  local ok, unit = pcall(world.FindFirstChild, world, name, true)
  if not ok then
    print("[PlayerGrill] 查找场景锚点失败", name, tostring(unit))
    return nil
  end
  if unit then cache[name] = unit end
  return unit
end

local function anchor_in_range(player, world, cache)
  local character = player and player.Character
  local pos = character and character.Position
  if not pos then return nil, nil end
  for _, point in ipairs(cfg().Points or {}) do
    local anchor = find_anchor(world, point.AnchorName, cache)
    local center = anchor and anchor.Position
    local radius = BodyScale.interaction_radius(character, cfg().Radius) + (cfg().Slack or 0)
    if center and flat_distance(pos, center) <= radius then
      return point.AnchorName, anchor
    end
  end
  return nil, nil
end

local function rate_of(session, now)
  if session.rate ~= nil then return session.rate end
  local elapsed = now - (session.startedAt or now)
  if GrillCurve.is_burnt(elapsed, cfg()) then return 0 end
  return GrillCurve.rate(elapsed, cfg())
end

local function pending_rate(pending, now)
  if type(pending) ~= "table" then return nil end
  if pending.cooked ~= nil then return pending.cooked end
  if type(pending.at) ~= "number" then return nil end
  local elapsed = now - pending.at
  if GrillCurve.is_burnt(elapsed, cfg()) then return 0 end
  return GrillCurve.rate(elapsed, cfg())
end

function PlayerGrill.mount(scope, tree, opts)
  opts = type(opts) == "table" and opts or {}
  local player = tree.player
  local data = tree.data
  local remote = opts.remote
  local save = opts.save
  local clock = tree.clock
  local session = {
    player = player,
    state = "idle",
    anchors = {},
    world = opts.world,
    create_unit = opts.create_unit,
  }
  local cleaned = false
  local is_cooking = State.new("PlayerGrill.is_cooking", false)

  local function set_cooking(active)
    if not cleaned and is_cooking:now() ~= active then
      is_cooking:set(active)
    end
  end

  local function sync_tree()
    if type(tree.sync_from_data) == "function" then
      tree:sync_from_data(data)
    end
  end

  local function public_state()
    if session.state == "idle" then return { state = "idle" } end
    return {
      state = session.state,
      itemId = session.itemId,
      mult = session.mult,
      startedAt = session.startedAt,
      rate = session.rate,
    }
  end

  local function publish()
    push_state(remote, player, public_state())
  end

  local function destroy_visual()
    local unit = session.visual
    session.visual = nil
    if unit and type(unit.Destroy) == "function" then
      pcall(function() -- 兼容引擎 userdata 读取 Destroyed 或单位已被引擎先行销毁
        if not unit.Destroyed then unit:Destroy() end
      end)
    end
  end

  local function clear_memory()
    session.state = "idle"
    session.itemId = nil
    session.mult = nil
    session.startedAt = nil
    session.rate = nil
    session.anchorName = nil
    session.anchor = nil
    set_cooking(false)
    destroy_visual()
  end

  local function spawn_visual()
    if session.visual or type(session.create_unit) ~= "function" then return end
    local center = session.anchor and session.anchor.Position
    local ok, unit = pcall(session.create_unit, "WorldUnit", {
      Name = "GrillFish" .. tostring(player.UserId),
      Position = center,
    })
    if ok and unit then
      session.visual = unit
      return
    end
    print("[PlayerGrill] 烤制单位创建失败", tostring(unit))
  end

  local function explode()
    if session.exploded then return end
    session.exploded = true
    local center = session.anchor and session.anchor.Position
    if not center or type(opts.new_hit) ~= "function" or type(opts.apply_hit) ~= "function" then
      return
    end
    local hit = opts.new_hit(nil, "grillBurn")
    local players = {}
    if type(opts.players) == "function" then
      local ok, list = pcall(opts.players)
      if ok and type(list) == "table" then players = list end
    end
    for _, other in pairs(players) do
      local pos = other and other.Character and other.Character.Position
      if pos and flat_distance(pos, center) <= cfg().BurnRadius then
        opts.apply_hit(hit, other, cfg().BurnDamage)
      end
    end
  end

  local function execute(kind, seq, transform, done)
    if not save or not data then return false, "unavailable" end
    local operation, mode
    if seq == nil then
      operation = save:next_operation(player, kind)
      mode = operation and "new" or "pending"
    else
      operation, mode = save:resolve_request(player, data, kind, seq)
    end
    if not operation then
      if mode == "replay" then return true, "replay" end
      return false, tostring(mode or "invalid")
    end
    local accepted = save:execute(player, data, operation, transform, function(written, result)
      if done then done(written == true, result) end
    end)
    return accepted == true, accepted and "accepted" or "rejected"
  end

  local function settle_burn()
    if session.state ~= "cooking" and session.state ~= "ready" then return false end
    local item_id = session.itemId
    session.state = "burnt"
    explode()
    destroy_visual()
    execute("grill:burn", nil, function(draft)
      ensure_recovery(draft).grill = nil
      return { ok = true, action = "Burn", itemId = item_id }
    end, function(written)
      if written then sync_tree() end
    end)
    clear_memory()
    push_state(remote, player, { state = "burnt" })
    print("[PlayerGrill] 烤糊", player.UserId, item_id)
    return true
  end

  local function settle_current(now, reason)
    if session.state ~= "cooking" and session.state ~= "ready" then return false end
    local rate = rate_of(session, now)
    if not rate or rate <= 0 then return settle_burn() end
    local item_id, mult = session.itemId, session.mult
    local placed = false
    local accepted = execute("grill:settle", nil, function(draft)
      ensure_recovery(draft).grill = nil
      placed = place(draft, item_id, mult, rate, false)
      if not placed then
        ensure_recovery(draft).grill = { itemId = item_id, mult = mult, cooked = rate }
      end
      return { ok = true, action = "Settle", itemId = item_id, rate = rate, pending = not placed }
    end, function(written)
      if written then sync_tree() end
    end)
    if not accepted then return false end
    destroy_visual()
    clear_memory()
    publish()
    print("[PlayerGrill] 自动结算", player.UserId, item_id, reason, "rate=" .. tostring(rate))
    return true
  end

  local function try_recover(now)
    if session.state ~= "idle" then return false end
    local pending = data and data.Extra and data.Extra.recovery and data.Extra.recovery.grill
    if type(pending) ~= "table" or type(pending.itemId) ~= "string" then return false end
    local rate = pending_rate(pending, now)
    if not rate or rate <= 0 then
      execute("grill:recover", nil, function(draft)
        ensure_recovery(draft).grill = nil
        return { ok = true, action = "Recover", itemId = pending.itemId, rate = 0 }
      end, function(written)
        if written then sync_tree() end
      end)
      return true
    end
    if data.CanGrant and not data:CanGrant(pending.itemId, 1) then return false end
    local accepted = execute("grill:recover", nil, function(draft)
      ensure_recovery(draft).grill = nil
      if not place(draft, pending.itemId, pending.mult, rate, false) then
        ensure_recovery(draft).grill = {
          itemId = pending.itemId, mult = pending.mult, cooked = rate,
        }
        return nil, "full"
      end
      return { ok = true, action = "Recover", itemId = pending.itemId, rate = rate }
    end, function(written)
      if written then sync_tree() end
    end)
    if accepted then
      publish()
      print("[PlayerGrill] 重进恢复", player.UserId, pending.itemId, "rate=" .. tostring(rate))
    end
    return accepted
  end

  local function request_start(payload)
    local seq = payload.seq
    if session.state == "cooking" or session.state == "ready" then
      return fail(remote, player, "busy", seq)
    end
    if tree.memos.can_act:now() ~= true then
      return fail(remote, player, "not-alive", seq)
    end
    local anchor_name, anchor = anchor_in_range(player, session.world, session.anchors)
    if not anchor_name then return fail(remote, player, "out-of-range", seq) end
    local slot, entry = selected_entry(data)
    if not grillable(entry) then return fail(remote, player, "no-fish", seq) end
    if is_token(entry.itemId) and payload.confirm ~= true then
      return fail(remote, player, "token-warn", seq)
    end
    local item_id, mult = entry.itemId, entry.mult
    local started_at = clock.now()
    local result = nil
    local accepted, mode = execute("grill:start", seq, function(draft)
      local draft_slot, draft_entry = selected_entry(draft)
      if draft_slot ~= slot or not grillable(draft_entry) or draft_entry.itemId ~= item_id then
        return nil, "no-fish"
      end
      draft.Data.Containers[ITEM_BAR][slot] = nil
      if draft.Data.SelectedSlot == slot then draft.Data.SelectedSlot = nil end
      local pending = draft.Extra and draft.Extra.recovery and draft.Extra.recovery.grill
      if type(pending) == "table" then
        local recovered = pending_rate(pending, started_at)
        ensure_recovery(draft).grill = nil
        if recovered and recovered > 0 and not place(draft, pending.itemId, pending.mult, recovered, false) then
          ensure_recovery(draft).grill = {
            itemId = pending.itemId, mult = pending.mult, cooked = recovered,
          }
          return nil, "full"
        end
      end
      ensure_recovery(draft).grill = {
        itemId = item_id, mult = mult, at = started_at, anchor = anchor_name,
      }
      return {
        ok = true, action = "Start", seq = seq, itemId = item_id, mult = mult, startedAt = started_at,
      }
    end, function(written, value)
      if not written or cleaned then
        if not written then fail(remote, player, tostring(value or "rejected"), seq) end
        return
      end
      result = value
      SpokeRuntime.batch(function()
        sync_tree()
        session.state = "cooking"
        session.itemId = item_id
        session.mult = mult
        session.startedAt = started_at
        session.rate = nil
        session.anchorName = anchor_name
        session.anchor = anchor
        session.exploded = nil
        set_cooking(true)
      end)
      spawn_visual()
      reply(remote, player, value)
      publish()
      print("[PlayerGrill] 开烤", player.UserId, item_id, mult)
    end)
    if mode == "replay" then return true end
    if not accepted then return fail(remote, player, mode, seq) end
    return result or true
  end

  local function request_takeout(payload)
    local seq = payload.seq
    if session.state ~= "cooking" and session.state ~= "ready" then
      return fail(remote, player, "no-session", seq)
    end
    if tree.memos.can_act:now() ~= true then
      return fail(remote, player, "not-alive", seq)
    end
    if not anchor_in_range(player, session.world, session.anchors) then
      return fail(remote, player, "out-of-range", seq)
    end
    local now = clock.now()
    if session.state == "cooking" and GrillCurve.is_burnt(now - (session.startedAt or now), cfg()) then
      settle_burn()
      return fail(remote, player, "burnt", seq)
    end
    local rate = session.rate or GrillCurve.rate(now - session.startedAt, cfg())
    local item_id, mult = session.itemId, session.mult
    local frozen = false
    local accepted, mode = execute("grill:takeout", seq, function(draft)
      ensure_recovery(draft).grill = nil
      if not place(draft, item_id, mult, rate, true) then
        ensure_recovery(draft).grill = { itemId = item_id, mult = mult, cooked = rate }
        frozen = true
        return nil, "full"
      end
      return { ok = true, action = "Takeout", seq = seq, itemId = item_id, mult = mult, rate = rate }
    end, function(written, value)
      if cleaned then return end
      if not written then
        if tostring(value) == "full" then
          session.state = "ready"
          session.rate = rate
          set_cooking(false)
          publish()
        end
        fail(remote, player, tostring(value or "rejected"), seq)
        return
      end
      SpokeRuntime.batch(function()
        sync_tree()
        clear_memory()
      end)
      reply(remote, player, value)
      publish()
      print("[PlayerGrill] 取出", player.UserId, item_id, "rate=" .. tostring(rate))
    end)
    if mode == "replay" then return true end
    if not accepted then return fail(remote, player, mode, seq) end
    if frozen then return fail(remote, player, "full", seq) end
    return true
  end

  local function on_action(actor, payload)
    if actor ~= player or type(payload) ~= "table" then return false end
    local seq = payload.seq
    if type(seq) ~= "number" or seq ~= math.floor(seq) or seq < 1 or seq > 2147483647 then
      return false
    end
    if payload.action == "Start" then return request_start(payload) end
    if payload.action == "Takeout" then return request_takeout(payload) end
    if payload.action == "Query" then
      publish()
      return true
    end
    return false
  end

  try_recover(clock.now())
  if session.state == "idle" then publish() end

  scope:subscribe(clock.on_second, function()
    if session.state == "idle" then
      try_recover(clock.now())
    end
  end)

  scope:phase("GrillCooking", is_cooking, function(ps)
    ps:subscribe(clock.on_frame, function(frame)
      local now = frame and frame.now or clock.now()
      if session.state ~= "cooking" then return end
      if tree.memos.is_alive:now() ~= true then
        settle_current(now, "downed")
        return
      end
      if GrillCurve.is_burnt(now - (session.startedAt or now), cfg()) then
        settle_burn()
      end
    end)
  end)

  scope:on_cleanup(function()
    cleaned = true
    if session.state == "cooking" or session.state == "ready" then
      settle_current(clock.now(), "leave")
    end
    destroy_visual()
  end)

  return { handle = on_action }
end

return PlayerGrill
