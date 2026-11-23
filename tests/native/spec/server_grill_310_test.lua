-- #310 烧烤点宿主接缝（ADR-0032 / #292 Testing Decisions）
-- 失败方式先列：
--   1. 非鱼获、已烤鱼获或未确认信物被投入并扣物；校验失败后库存与会话同时变；
--   2. 曲线不按服务器时刻一次算出（1 / 2.25 / 3.5 / 4.5 秒读数错，或按帧数累加）；
--   3. 取出后倍率继续变、不回格位、不保持选中，或烤过的鱼还能抽奖、烤过的信物还能兑换；
--   4. 4.5 秒不烤糊、烤糊后物品还在、3 米内没吃 30 点、操作者收不到烤糊，或爆炸重复；
--   5. 濒死、死亡或离场不按当前倍率结算，满格时吞物或复制，重进后烤制单位还在；
--   6. 两名玩家互相取走对方的鱼，或麻痹中断烤制。
-- 接缝：ServerRuntime 进出、GrillAction 上行、SpokeClock 步进、GrillResult / GrillState /
-- 道具栏快照 / 角色血量 / 动态单位销毁。不窥探私有 Effect 拓扑。

local GameCfg = require("common.GameCfg")
local ServerRuntime = require("server.World.ServerRuntime")
local LotteryEligibility = require("common.LotteryEligibility")

local FISH = "carp"
local TOKEN = "eelHead"
local ITEM_BAR = GameCfg.Items.ContainerId.ItemBar
local BACKPACK = GameCfg.Items.ContainerId.Backpack

local function signal()
  local handlers = {}
  return {
    Connect = function(_, fn)
      handlers[#handlers + 1] = fn
      return { Disconnect = function() end }
    end,
    Fire = function(_, ...)
      for _, fn in ipairs(handlers) do fn(...) end
    end,
  }
end

local function grill_anchor()
  for _, entity in ipairs(GameCfg.Zones[3].Scene.Entities) do
    if entity.Role == "Grill" then return entity end
  end
end

describe("服务端烧烤点宿主接缝（#310）", function()
  local ctx

  local function drain()
    while #ctx.queue > 0 do table.remove(ctx.queue, 1)() end
  end

  local function make_player(id, at_grill)
    local anchor = ctx.anchor
    local player = {
      UserId = id,
      Name = "p" .. id,
      attrs = {},
      CharacterAdded = signal(),
      CharacterRemoving = signal(),
      Character = {
        Position = {
          x = anchor.x + (at_grill == false and 100 or 1),
          y = anchor.y,
          z = anchor.z,
        },
        Size = { y = 2 },
        Controller = {
          Health = GameCfg.Vitals.MaxHealth,
          TakeDamage = function(self, amount)
            self.Health = math.max(0, self.Health - amount)
          end,
        },
      },
    }
    function player:SetAttribute(key, value) self.attrs[key] = value end
    player._hp = GameCfg.Vitals.MaxHealth
    return player
  end

  local function make_data(player)
    local data = ctx.PlayerData.New(player)
    data:Init(true)
    ctx.save:LoadInto(player, data)
    drain()
    ctx.datas[player.UserId] = data
    return data
  end

  before_each(function()
    ctx = {
      values = {}, queue = {}, events = {}, datas = {}, units = {},
      unit_seq = 0, item_bars = {},
    }
    ctx.old_game, ctx.old_re = _G.game, _G.REUtil
    ctx.old_debug = GameCfg.Debug
    GameCfg.Debug = { Enabled = false }
    ctx.anchor_entity = grill_anchor()
    ctx.anchor = ctx.anchor_entity.Position
    ctx.store = {
      GetAsync = function(_, key) return ctx.values[key] end,
      UpdateAsync = function(_, key, transform)
        local value = transform(ctx.values[key])
        if value then ctx.values[key] = value end
        return value
      end,
      SetAsync = function(_, key, value) ctx.values[key] = value end,
    }
    ctx.players = {}
    _G.game = { GetService = function(_, name)
      if name == "Task" then
        return { Spawn = function(_, fn) ctx.queue[#ctx.queue + 1] = fn end, Wait = function() end }
      end
      if name == "DataStoreService" then return { GetDataStore = function() return ctx.store end } end
      if name == "World" then
        return {
          GetServerTime = function() return ctx.runtime and ctx.runtime.clock.now() or 1000 end,
          FindFirstChild = function(_, name)
            if name == ctx.anchor_entity.Name or name == GameCfg.Zones[3].Scene.GrillName then
              return { Name = name, Position = ctx.anchor, Destroy = function(self) self.Destroyed = true end }
            end
          end,
          CreateUnit = function(_, kind, props)
            ctx.unit_seq = ctx.unit_seq + 1
            local unit = {
              id = ctx.unit_seq, kind = kind, props = props, Name = props and props.Name,
              Destroy = function(self)
                self.Destroyed = true
                ctx.units[self.id] = nil
              end,
            }
            ctx.units[unit.id] = unit
            return unit
          end,
        }
      end
      if name == "Players" then
        return {
          GetPlayers = function() return ctx.players end,
          GetPlayerFromCharacter = function(_, character)
            for _, player in ipairs(ctx.players) do
              if player.Character == character then return player end
            end
          end,
        }
      end
    end }
    _G.REUtil = {
      CheckRECD = function() return false end,
      GetRE = function(_, name)
        if not ctx.events[name] then
          ctx.events[name] = {
            OnServerEvent = signal(),
            clients = {},
            FireClient = function(self, player, payload)
              self.clients[#self.clients + 1] = { player = player, value = payload }
              if name == "GrillResult" then
                player.grill_results = player.grill_results or {}
                player.grill_results[#player.grill_results + 1] = payload
              elseif name == "GrillState" then
                player.grill_state = payload
              elseif name == "ItemBarState" then
                ctx.item_bars[player.UserId] = payload
              end
            end,
          }
        end
        return ctx.events[name]
      end,
    }
    ctx.PlayerData = assert(loadfile("server/Data/PlayerData.lua"))()
    ctx.save = assert(loadfile("server/SaveHost.lua"))()
    ctx.runtime = ServerRuntime.new({
      initial_now = 1000,
      remote = _G.REUtil,
      player_data = { GetDataInst = function(_, player) return ctx.datas[player.UserId] end },
      save = ctx.save,
      players_service = _G.game:GetService("Players"),
      world_service = _G.game:GetService("World"),
      create_unit = function(kind, props)
        return _G.game:GetService("World"):CreateUnit(kind, props)
      end,
      on_item_bar_state = function(player, snapshot)
        _G.REUtil:GetRE("ItemBarState"):FireClient(player, snapshot)
      end,
      bind_grill_action = function(dispatch)
        ctx.events.GrillAction = ctx.events.GrillAction or _G.REUtil:GetRE("GrillAction")
        ctx.events.GrillAction.OnServerEvent:Connect(function(player, payload)
          dispatch(player, payload)
        end)
      end,
    })
    _G.REUtil:GetRE("GrillAction")
    _G.REUtil:GetRE("GrillResult")
    _G.REUtil:GetRE("GrillState")
    ctx.runtime:start()
    ctx.runtime:mark_started()
  end)

  after_each(function()
    if ctx.runtime then ctx.runtime:shutdown() end
    _G.game, _G.REUtil = ctx.old_game, ctx.old_re
    GameCfg.Debug = ctx.old_debug
  end)

  local function join(id, at_grill, before_ready)
    local player = make_player(id, at_grill)
    local data = make_data(player)
    if before_ready then before_ready(data) end
    ctx.players[#ctx.players + 1] = player
    ctx.runtime:on_player_added(player)
    ctx.runtime:on_save_ready(player, data)
    drain()
    return player, data
  end

  local function give_selected(data, item_id, mult, cooked)
    assert.is_true(data:AddItem(item_id, mult, cooked))
    assert.is_true(data:SelectSlot(1))
    local tree = ctx.runtime:get_player_tree(data.Player and data.Player.UserId or nil)
    -- AddItem 写在 PlayerData 上；入树前再同步一次，保证选中格是公开库存。
    local owner = nil
    for _, player in ipairs(ctx.players) do
      if ctx.datas[player.UserId] == data then owner = player break end
    end
    tree = owner and ctx.runtime:get_player_tree(owner.UserId)
    if tree then tree:sync_from_data(data) end
  end

  local function act(player, payload)
    ctx.seq = (ctx.seq or 0) + 1
    payload.seq = payload.seq or ctx.seq
    ctx.events.GrillAction.OnServerEvent:Fire(player, payload)
    drain()
    local results = player.grill_results
    return results and results[#results]
  end

  local function advance(seconds)
    ctx.runtime.clock:advance(seconds)
    drain()
  end

  local function count_item(data, item_id)
    local total = 0
    for _, container in pairs(data.Data.Containers) do
      for _, entry in pairs(container) do
        if entry.itemId == item_id and entry.count > 0 then total = total + entry.count end
      end
    end
    return total
  end

  local function find_entry(data, item_id)
    for _, container in pairs(data.Data.Containers) do
      for _, entry in pairs(container) do
        if entry.itemId == item_id and entry.count > 0 then return entry end
      end
    end
  end

  local function live_units()
    local n = 0
    for _, unit in pairs(ctx.units) do
      if not unit.Destroyed and type(unit.Name) == "string"
          and unit.Name:sub(1, 9) == "GrillFish" then
        n = n + 1
      end
    end
    return n
  end

  it("只有未烤鱼获能投入，信物须确认，校验失败不改库存", function()
    local player, data = join(9500)
    give_selected(data, "item126", 1)
    local rejected = act(player, { action = "Start" })
    assert.is_false(rejected.ok)
    assert.same("no-fish", rejected.reason)
    assert.same(1, count_item(data, "item126"))
    assert.same("idle", player.grill_state and player.grill_state.state)

    local other, other_data = join(9501)
    give_selected(other_data, FISH, 1.2, 1.2)
    local recook = act(other, { action = "Start" })
    assert.is_false(recook.ok)
    assert.same("no-fish", recook.reason)
    assert.same(1, count_item(other_data, FISH))

    local token_player, token_data = join(9502)
    give_selected(token_data, TOKEN)
    local warned = act(token_player, { action = "Start" })
    assert.is_false(warned.ok)
    assert.same("token-warn", warned.reason)
    assert.same(1, count_item(token_data, TOKEN))
    local started = act(token_player, { action = "Start", confirm = true })
    assert.is_true(started.ok)
    assert.same(0, count_item(token_data, TOKEN))
    assert.same("cooking", token_player.grill_state.state)
    assert.is_true(live_units() >= 1, "开烤要生成烤制单位")
  end)

  it("曲线按服务器时刻推进，取出冻结倍率并取消抽奖与兑换资格", function()
    local cases = {
      { 1, 1.25 },
      { 2.25, 1.5 },
      { 3.5, 0.75 },
    }
    for index, case in ipairs(cases) do
      local player, data = join(9510 + index)
      give_selected(data, FISH, 1.5)
      assert.is_true(act(player, { action = "Start" }).ok)
      advance(case[1])
      local reply = act(player, { action = "Takeout" })
      assert.is_true(reply.ok)
      assert.near(case[2], reply.rate, 0.001)
      local entry = data.Data.Containers[ITEM_BAR][1]
      assert.same(FISH, entry.itemId)
      assert.near(case[2], entry.cooked, 0.001)
      assert.same(1, data.Data.SelectedSlot)
      advance(20)
      assert.near(case[2], data.Data.Containers[ITEM_BAR][1].cooked, 0.001)
      assert.same("idle", player.grill_state.state)
      assert.same(0, live_units())
    end

    local premium, premium_data = join(9520)
    give_selected(premium_data, "item7", 1)
    assert.is_true(LotteryEligibility.Check(premium_data.Data.Containers[ITEM_BAR][1]))
    assert.is_true(act(premium, { action = "Start" }).ok)
    advance(2)
    assert.is_true(act(premium, { action = "Takeout" }).ok)
    local cooked_premium = premium_data.Data.Containers[ITEM_BAR][1]
    local ok_lottery, reason = LotteryEligibility.Check(cooked_premium)
    assert.is_false(ok_lottery)
    assert.same("cooked", reason)

    local token_player, token_data = join(9521)
    give_selected(token_data, TOKEN)
    assert.is_true(act(token_player, { action = "Start", confirm = true }).ok)
    advance(2)
    assert.is_true(act(token_player, { action = "Takeout" }).ok)
    local cooked_token = find_entry(token_data, TOKEN)
    assert.is_not_nil(GameCfg.Items.CookRate(cooked_token))
  end)

  it("4.5 秒烤糊损毁并只爆炸一次，满格取出冻结后可重试", function()
    local player, data = join(9530)
    local near = join(9531)
    local far = join(9532, false)
    give_selected(data, FISH, 1)
    assert.is_true(act(player, { action = "Start" }).ok)
    advance(GameCfg.Grill.BurnSec - 0.25)
    local early = act(player, { action = "Takeout" })
    assert.is_true(early.ok, "4.5 秒前取出不该烤糊")
    assert.is_true(early.rate > 0)

    local burner, burner_data = join(9533)
    join(9534)
    give_selected(burner_data, FISH, 1)
    assert.is_true(act(burner, { action = "Start" }).ok)
    local before = {}
    for _, member in ipairs({ burner, near, far }) do
      before[member.UserId] = member.Character.Controller.Health
    end
    advance(GameCfg.Grill.BurnSec)
    assert.same(0, count_item(burner_data, FISH))
    assert.same("burnt", burner.grill_state.state)
    assert.same(0, live_units())
    local after = act(burner, { action = "Takeout" })
    assert.is_false(after.ok)
    assert.same("no-session", after.reason)
    assert.same(before[burner.UserId] - GameCfg.Grill.BurnDamage, burner.Character.Controller.Health)
    assert.same(before[near.UserId] - GameCfg.Grill.BurnDamage, near.Character.Controller.Health)
    assert.same(before[far.UserId], far.Character.Controller.Health)
    advance(10)
    assert.same(before[burner.UserId] - GameCfg.Grill.BurnDamage, burner.Character.Controller.Health)

    local full_player, full_data = join(9535)
    give_selected(full_data, FISH, 1)
    assert.is_true(act(full_player, { action = "Start" }).ok)
    advance(2)
    while full_data:AddItem("tilapia") do end
    local tree = ctx.runtime:get_player_tree(full_player.UserId)
    tree:sync_from_data(full_data)
    local full = act(full_player, { action = "Takeout" })
    assert.is_false(full.ok)
    assert.same("full", full.reason)
    assert.same(0, count_item(full_data, FISH))
    advance(1.5)
    full_data.Data.Containers[BACKPACK][1] = nil
    tree:sync_from_data(full_data)
    local retry = act(full_player, { action = "Takeout" })
    assert.is_true(retry.ok)
    assert.near(1.5, retry.rate, 0.001)
  end)

  it("濒死、死亡与离场按当前倍率结算并清掉烤制单位", function()
    local downed, downed_data = join(9540)
    give_selected(downed_data, FISH, 1)
    assert.is_true(act(downed, { action = "Start" }).ok)
    advance(1)
    local tree = ctx.runtime:get_player_tree(downed.UserId)
    tree:apply_hit(tree:new_hit(nil, "test"), downed, GameCfg.Vitals.MaxHealth)
    drain()
    local entry = find_entry(downed_data, FISH)
    assert.is_not_nil(entry)
    assert.near(1.25, entry.cooked, 0.02)
    assert.same("idle", downed.grill_state.state)
    assert.same(0, live_units())
    advance(10)
    local health = select(1, ctx.runtime.life:SnapshotHealth(downed))
    assert.same(1, health)

    local leaver, leave_data = join(9541)
    give_selected(leave_data, FISH, 1.5)
    assert.is_true(act(leaver, { action = "Start" }).ok)
    advance(1)
    ctx.runtime:on_player_removing(leaver)
    drain()
    local left = find_entry(leave_data, FISH)
    assert.is_not_nil(left)
    assert.near(1.25, left.cooked, 0.02)
    assert.is_nil(leave_data.Extra.recovery and leave_data.Extra.recovery.grill)
    assert.same(0, live_units())

    local blocked, blocked_data = join(9542)
    give_selected(blocked_data, FISH, 1)
    assert.is_true(act(blocked, { action = "Start" }).ok)
    advance(2)
    while blocked_data:AddItem("tilapia") do end
    ctx.runtime:get_player_tree(blocked.UserId):sync_from_data(blocked_data)
    ctx.runtime:on_player_removing(blocked)
    drain()
    assert.same(0, count_item(blocked_data, FISH))
    local pending = blocked_data.Extra.recovery and blocked_data.Extra.recovery.grill
    assert.is_not_nil(pending)
    assert.near(1.5, pending.cooked, 0.001)
    assert.same(0, live_units())

    local paralyze, paralyze_data = join(9543)
    give_selected(paralyze_data, FISH, 1)
    assert.is_true(act(paralyze, { action = "Start" }).ok)
    ctx.runtime:get_player_tree(paralyze.UserId):apply_modifier("paralyze", { duration = 0.5 })
    advance(0.2)
    assert.same("cooking", paralyze.grill_state.state)
    assert.same(0, count_item(paralyze_data, FISH))
    local denied = act(paralyze, { action = "Takeout" })
    assert.is_false(denied.ok)
    assert.same("not-alive", denied.reason)
  end)

  it("重进按冻结倍率恢复，离线已烤糊只清标记不爆炸", function()
    local recovered, recovered_data = join(9560, true, function(data)
      data.Extra.recovery = data.Extra.recovery or {}
      data.Extra.recovery.grill = { itemId = FISH, mult = 1.5, cooked = 1.25 }
    end)
    local entry = find_entry(recovered_data, FISH)
    assert.is_not_nil(entry)
    assert.near(1.25, entry.cooked, 0.001)
    assert.is_nil(recovered_data.Extra.recovery.grill)
    assert.same(GameCfg.Vitals.MaxHealth, recovered.Character.Controller.Health)

    local burnt, burnt_data = join(9561, true, function(data)
      data.Extra.recovery = data.Extra.recovery or {}
      data.Extra.recovery.grill = { itemId = FISH, mult = 1.5, at = 990 }
    end)
    drain()
    assert.same(0, count_item(burnt_data, FISH))
    assert.is_nil(burnt_data.Extra.recovery.grill)
    assert.same(GameCfg.Vitals.MaxHealth, burnt.Character.Controller.Health)
    assert.same(GameCfg.Vitals.MaxHealth, recovered.Character.Controller.Health)
  end)

  it("离场后的迟到存档回调不复活烤制单位也不吞鱼", function()
    local player, data = join(9570)
    give_selected(data, FISH, 1.5)
    ctx.seq = (ctx.seq or 0) + 1
    ctx.events.GrillAction.OnServerEvent:Fire(player, { action = "Start", seq = ctx.seq })
    ctx.runtime:on_player_removing(player)
    drain()
    assert.same(0, live_units())
    assert.is_nil(ctx.runtime:get_player_tree(player.UserId))
    local pending = data.Extra.recovery and data.Extra.recovery.grill
    assert.is_true(count_item(data, FISH) == 1 or (pending and pending.itemId == FISH) ~= nil)
  end)

  it("会话按玩家隔离，重放不复制，走远不能取出", function()
    local a, data_a = join(9550)
    local b, data_b = join(9551)
    give_selected(data_a, FISH, 1)
    give_selected(data_b, "bass", 1)
    assert.is_true(act(a, { action = "Start" }).ok)
    advance(2)
    local stolen = act(b, { action = "Takeout" })
    assert.is_false(stolen.ok)
    assert.same("no-session", stolen.reason)
    assert.same(0, count_item(data_b, FISH))
    a.Character.Position = { x = ctx.anchor.x + 100, y = ctx.anchor.y, z = ctx.anchor.z }
    local far = act(a, { action = "Takeout" })
    assert.is_false(far.ok)
    assert.same("out-of-range", far.reason)
    assert.same(0, count_item(data_a, FISH))
    a.Character.Position = { x = ctx.anchor.x + 1, y = ctx.anchor.y, z = ctx.anchor.z }
    local first = act(a, { action = "Takeout" })
    assert.is_true(first.ok)
    act(a, { action = "Takeout", seq = first.seq })
    assert.same(1, count_item(data_a, FISH))
  end)
end)
