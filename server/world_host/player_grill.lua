local EngineRead = require("common.engine_read")
local GameCfg = require("common.game_cfg")
local BodyScale = require("common.body_scale")
local GrillCurve = require("common.grill_curve")
local Spoke = require("common.packages.spoke.api")
local SpokeRuntime = require("common.packages.spoke.runtime.spoke_runtime")

local State = Spoke.State
local PlayerGrill = {}
-- 烧烤行为表：拆分前都是 PlayerGrill.mount 体内的闭包，依赖统一从树上的 grill_env 读取。
local GrillBehavior = {}

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
  local items = data and data.data and data.data.containers and data.data.containers[ITEM_BAR]
  local slot = data and data.data and data.data.selected_slot
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
    local items = data.data.containers[pair[1]]
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
        if select_slot and pair[1] == ITEM_BAR then data.data.selected_slot = index end
        return true
      end
    end
  end
  return false
end

local function ensure_recovery(data)
  if type(data.extra) ~= "table" then data.extra = {} end
  if type(data.extra.recovery) ~= "table" then data.extra.recovery = {} end
  return data.extra.recovery
end

-- 结果回包与状态推送只有频道与载荷字段不同，共用 EngineRead.client_sender 生成。
local reply = EngineRead.client_sender({
  tag = "PlayerGrill", channel = "GrillResult", context = "PlayerGrill.reply", field = "action",
})

-- 推送当前烧烤状态到客户端，失败记录带上下文日志。
local push_state = EngineRead.client_sender({
  tag = "PlayerGrill", channel = "GrillState", context = "PlayerGrill.push_state", field = "state", verb = "推送失败",
})

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

-- ===== 环境与行为表 =====

-- 建烧烤环境：拆分前 mount 开头的局部变量全部收进 env，行为方法只从 self.grill_env 取依赖。
function GrillBehavior.new_env(tree, opts)
  opts = type(opts) == "table" and opts or {}
  local player = tree.player
  ---@type table<string, any>
  local session = {
    player = player,
    state = "idle",
    anchors = {},
    world = opts.world,
    create_unit = opts.create_unit,
  }
  return {
    tree = tree,
    opts = opts,
    player = player,
    data = tree.data,
    remote = opts.remote,
    save = opts.save,
    clock = tree.clock,
    session = session,
    cleaned = false,
    is_cooking = State.new("PlayerGrill.is_cooking", false),
  }
end

function GrillBehavior.set_cooking(self, active)
  local env = self.grill_env
  if not env.cleaned and env.is_cooking:now() ~= active then
    env.is_cooking:set(active)
  end
end

function GrillBehavior.sync_tree(self)
  local env = self.grill_env
  if type(env.tree.sync_from_data) == "function" then
    env.tree:sync_from_data(env.data)
  end
end

function GrillBehavior.public_state(self)
  local session = self.grill_env.session
  if session.state == "idle" then return { state = "idle" } end
  return {
    state = session.state,
    itemId = session.itemId,
    mult = session.mult,
    startedAt = session.startedAt,
    rate = session.rate,
  }
end

function GrillBehavior.publish(self)
  local env = self.grill_env
  push_state(env.remote, env.player, GrillBehavior.public_state(self))
end

function GrillBehavior.destroy_visual(self)
  local env = self.grill_env
  local session = env.session
  local unit = session.visual
  session.visual = nil
  if unit then
    local ok_d, _, reason_d = EngineRead.destroy_unit(unit, "PlayerGrill.destroy_visual")
    if not ok_d and reason_d ~= "destroyed" then
      print("[PlayerGrill] 烤制单位销毁失败", env.player and env.player.UserId, tostring(reason_d))
    end
  end
end

function GrillBehavior.clear_memory(self)
  local session = self.grill_env.session
  session.state = "idle"
  session.itemId = nil
  session.mult = nil
  session.startedAt = nil
  session.rate = nil
  session.anchorName = nil
  session.anchor = nil
  GrillBehavior.set_cooking(self, false)
  GrillBehavior.destroy_visual(self)
end

function GrillBehavior.spawn_visual(self)
  local env = self.grill_env
  local session = env.session
  if session.visual or type(session.create_unit) ~= "function" then return end
  local center = session.anchor and session.anchor.Position
  local ok, unit = pcall(session.create_unit, "WorldUnit", {
    Name = "GrillFish" .. tostring(env.player.UserId),
    Position = center,
  })
  if ok and unit then
    session.visual = unit
    return
  end
  print("[PlayerGrill] 烤制单位创建失败", tostring(unit))
end

function GrillBehavior.explode(self)
  local env = self.grill_env
  local session, opts, player = env.session, env.opts, env.player
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
    if ok and type(list) == "table" then players = list else print("[PlayerGrill] 读取爆炸范围内玩家失败", player and player.UserId, ok and ("invalid=" .. type(list)) or tostring(list)) end
  end
  for _, other in pairs(players) do
    local pos = other and other.Character and other.Character.Position
    if pos and flat_distance(pos, center) <= cfg().BurnRadius then
      opts.apply_hit(hit, other, cfg().BurnDamage)
    end
  end
end

function GrillBehavior.execute(self, kind, seq, transform, done)
  local env = self.grill_env
  local save, data, player = env.save, env.data, env.player
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

function GrillBehavior.settle_burn(self)
  local env = self.grill_env
  local session = env.session
  if session.state ~= "cooking" and session.state ~= "ready" then return false end
  local item_id = session.itemId
  session.state = "burnt"
  GrillBehavior.explode(self)
  GrillBehavior.destroy_visual(self)
  GrillBehavior.execute(self, "grill:burn", nil, function(draft)
    ensure_recovery(draft).grill = nil
    return { ok = true, action = "Burn", itemId = item_id }
  end, function(written)
    if written then GrillBehavior.sync_tree(self) end
  end)
  GrillBehavior.clear_memory(self)
  push_state(env.remote, env.player, { state = "burnt" })
  print("[PlayerGrill] 烤糊", env.player.UserId, item_id)
  return true
end

function GrillBehavior.settle_current(self, now, reason)
  local env = self.grill_env
  local session = env.session
  if session.state ~= "cooking" and session.state ~= "ready" then return false end
  local rate = rate_of(session, now)
  if not rate or rate <= 0 then return GrillBehavior.settle_burn(self) end
  local item_id, mult = session.itemId, session.mult
  local placed = false
  local accepted = GrillBehavior.execute(self, "grill:settle", nil, function(draft)
    ensure_recovery(draft).grill = nil
    placed = place(draft, item_id, mult, rate, false)
    if not placed then
      ensure_recovery(draft).grill = { itemId = item_id, mult = mult, cooked = rate }
    end
    return { ok = true, action = "Settle", itemId = item_id, rate = rate, pending = not placed }
  end, function(written)
    if written then GrillBehavior.sync_tree(self) end
  end)
  if not accepted then return false end
  GrillBehavior.destroy_visual(self)
  GrillBehavior.clear_memory(self)
  GrillBehavior.publish(self)
  print("[PlayerGrill] 自动结算", env.player.UserId, item_id, reason, "rate=" .. tostring(rate))
  return true
end

function GrillBehavior.try_recover(self, now)
  local env = self.grill_env
  local session, data = env.session, env.data
  if session.state ~= "idle" then return false end
  local pending = data and data.extra and data.extra.recovery and data.extra.recovery.grill
  if type(pending) ~= "table" or type(pending.itemId) ~= "string" then return false end
  local rate = pending_rate(pending, now)
  if not rate or rate <= 0 then
    GrillBehavior.execute(self, "grill:recover", nil, function(draft)
      ensure_recovery(draft).grill = nil
      return { ok = true, action = "Recover", itemId = pending.itemId, rate = 0 }
    end, function(written)
      if written then GrillBehavior.sync_tree(self) end
    end)
    return true
  end
  if data.CanGrant and not data:CanGrant(pending.itemId, 1) then return false end
  local accepted = GrillBehavior.execute(self, "grill:recover", nil, function(draft)
    ensure_recovery(draft).grill = nil
    if not place(draft, pending.itemId, pending.mult, rate, false) then
      ensure_recovery(draft).grill = {
        itemId = pending.itemId, mult = pending.mult, cooked = rate,
      }
      return nil, "full"
    end
    return { ok = true, action = "Recover", itemId = pending.itemId, rate = rate }
  end, function(written)
    if written then GrillBehavior.sync_tree(self) end
  end)
  if accepted then
    GrillBehavior.publish(self)
    print("[PlayerGrill] 重进恢复", env.player.UserId, pending.itemId, "rate=" .. tostring(rate))
  end
  return accepted
end

function GrillBehavior.request_start(self, payload)
  local env = self.grill_env
  local session, player, data = env.session, env.player, env.data
  local remote, clock = env.remote, env.clock
  local seq = payload.seq
  if session.state == "cooking" or session.state == "ready" then
    return fail(remote, player, "busy", seq)
  end
  if env.tree.memos.can_act:now() ~= true then
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
  local accepted, mode = GrillBehavior.execute(self, "grill:start", seq, function(draft)
    local draft_slot, draft_entry = selected_entry(draft)
    if draft_slot ~= slot or not grillable(draft_entry) or draft_entry.itemId ~= item_id then
      return nil, "no-fish"
    end
    draft.data.containers[ITEM_BAR][slot] = nil
    if draft.data.selected_slot == slot then draft.data.selected_slot = nil end
    local pending = draft.extra and draft.extra.recovery and draft.extra.recovery.grill
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
    if not written or env.cleaned then
      if not written then fail(remote, player, tostring(value or "rejected"), seq) end
      return
    end
    result = value
    SpokeRuntime.batch(function()
      GrillBehavior.sync_tree(self)
      session.state = "cooking"
      session.itemId = item_id
      session.mult = mult
      session.startedAt = started_at
      session.rate = nil
      session.anchorName = anchor_name
      session.anchor = anchor
      session.exploded = nil
      GrillBehavior.set_cooking(self, true)
    end)
    GrillBehavior.spawn_visual(self)
    reply(remote, player, value)
    GrillBehavior.publish(self)
    print("[PlayerGrill] 开烤", player.UserId, item_id, mult)
  end)
  if mode == "replay" then return true end
  if not accepted then return fail(remote, player, mode, seq) end
  return result or true
end

function GrillBehavior.request_takeout(self, payload)
  local env = self.grill_env
  local session, player, remote = env.session, env.player, env.remote
  local seq = payload.seq
  if session.state ~= "cooking" and session.state ~= "ready" then
    return fail(remote, player, "no-session", seq)
  end
  if env.tree.memos.can_act:now() ~= true then
    return fail(remote, player, "not-alive", seq)
  end
  if not anchor_in_range(player, session.world, session.anchors) then
    return fail(remote, player, "out-of-range", seq)
  end
  local now = env.clock.now()
  if session.state == "cooking" and GrillCurve.is_burnt(now - (session.startedAt or now), cfg()) then
    GrillBehavior.settle_burn(self)
    return fail(remote, player, "burnt", seq)
  end
  local rate = session.rate or GrillCurve.rate(now - session.startedAt, cfg())
  local item_id, mult = session.itemId, session.mult
  local frozen = false
  local accepted, mode = GrillBehavior.execute(self, "grill:takeout", seq, function(draft)
    ensure_recovery(draft).grill = nil
    if not place(draft, item_id, mult, rate, true) then
      ensure_recovery(draft).grill = { itemId = item_id, mult = mult, cooked = rate }
      frozen = true
      return nil, "full"
    end
    return { ok = true, action = "Takeout", seq = seq, itemId = item_id, mult = mult, rate = rate }
  end, function(written, value)
    if env.cleaned then return end
    if not written then
      if tostring(value) == "full" then
        session.state = "ready"
        session.rate = rate
        GrillBehavior.set_cooking(self, false)
        GrillBehavior.publish(self)
      end
      fail(remote, player, tostring(value or "rejected"), seq)
      return
    end
    SpokeRuntime.batch(function()
      GrillBehavior.sync_tree(self)
      GrillBehavior.clear_memory(self)
    end)
    reply(remote, player, value)
    GrillBehavior.publish(self)
    print("[PlayerGrill] 取出", player.UserId, item_id, "rate=" .. tostring(rate))
  end)
  if mode == "replay" then return true end
  if not accepted then return fail(remote, player, mode, seq) end
  if frozen then return fail(remote, player, "full", seq) end
  return true
end

function GrillBehavior.on_action(self, actor, payload)
  local player = self.grill_env.player
  if actor ~= player or type(payload) ~= "table" then return false end
  local seq = payload.seq
  if type(seq) ~= "number" or seq ~= math.floor(seq) or seq < 1 or seq > 2147483647 then
    return false
  end
  if payload.action == "Start" then return GrillBehavior.request_start(self, payload) end
  if payload.action == "Takeout" then return GrillBehavior.request_takeout(self, payload) end
  if payload.action == "Query" then
    GrillBehavior.publish(self)
    return true
  end
  return false
end

-- ===== 装配 =====

-- 把行为表挂到玩家树上；依赖统一从 tree.grill_env 读取。
function GrillBehavior.install(tree, env)
  tree.grill_env = env
end

-- Spoke 作用域接线：注册顺序与拆分前 mount 内的 subscribe / phase / cleanup 一致。
function GrillBehavior.wire(scope, tree)
  local env = tree.grill_env
  local session, clock = env.session, env.clock
  if tree.actions and tree.actions.grill then
    scope:subscribe(tree.actions.grill, function(event)
      event.result = GrillBehavior.on_action(tree, env.player, event.payload)
    end)
  end

  GrillBehavior.try_recover(tree, clock.now())
  if session.state == "idle" then GrillBehavior.publish(tree) end

  scope:subscribe(clock.on_second, function()
    if session.state == "idle" then
      GrillBehavior.try_recover(tree, clock.now())
    end
  end)

  scope:phase("GrillCooking", env.is_cooking, function(ps)
    ps:subscribe(clock.on_frame, function(frame)
      local now = frame and frame.now or clock.now()
      if session.state ~= "cooking" then return end
      if tree.memos.is_alive:now() ~= true then
        GrillBehavior.settle_current(tree, now, "downed")
        return
      end
      if GrillCurve.is_burnt(now - (session.startedAt or now), cfg()) then
        GrillBehavior.settle_burn(tree)
      end
    end)
  end)

  scope:on_cleanup(function()
    env.cleaned = true
    if session.state == "cooking" or session.state == "ready" then
      GrillBehavior.settle_current(tree, clock.now(), "leave")
    end
    GrillBehavior.destroy_visual(tree)
  end)
end

-- 挂载烧烤模块：先建环境并装配行为表，再按拆分前的顺序接线。
function PlayerGrill.mount(scope, tree, opts)
  local env = GrillBehavior.new_env(tree, opts)
  GrillBehavior.install(tree, env)
  GrillBehavior.wire(scope, tree)
  return {
    handle = function(actor, payload)
      return GrillBehavior.on_action(tree, actor, payload)
    end,
  }
end

return PlayerGrill
