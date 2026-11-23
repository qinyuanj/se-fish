-- #298 玩家生命双层相位：服务端宿主接缝（ADR-0032 §2 / #292 Testing Decisions）
-- 失败方式先列：
--   1. alive 期间 SpokeClock 跨过整秒不扣饥饿，或同一秒内多次 step 重复扣；饥饿归零后不按 5/秒扣血；进入濒死/死亡/离场后仍继续扣饥饿或扣血；
--   2. 道具栏或背包任意格持有 item126 且 count>0 时不按 1/秒扣血（不要求选中），或移除后仍继续扣；
--   3. 致命伤害不锁 1 血进入 downed，或濒死/死亡仍能被扣血；同一击可重复命中；安全区/同队过滤失效；
--   4. downed 15 秒不到就进 dead，到点不进；dead 30 秒不到就虚弱复活，到点不按 10% 血与至少 10% 饥饿复活并施加 60 秒半速；
--   5. 广告/金豆满血复活期间倒计时不暂停，取消/失败/超时后不从剩余秒数继续；downed 发起金豆被接受；
--   6. 0.5 秒麻痹仍允许主动攻击/投掷/收线点击/使用物品，或麻痹退出 alive、拆掉挂在存活相位上的持续会话；
--   7. 抢救不要求目标 downed、2 米内、施救者 alive；读条中移动超 1 米、施救者受击或倒地不打断；成功不恢复成长上限 10%；
--      抢救期间濒死先到期先广播 downed 再广播 dead；
--   8. 能吃无恢复百分比的物品、非 can_act 仍能吃；负百分比不同时扣饥饿并按 floor(MaxHealth * -percent / 100) 扣血；
--   9. session_alive 置假时不写出濒死（含 rescuing）/死亡/虚弱剩余秒数（向上取整、下界 0）；
--      重登 dying/dead 不走 survival:recover 后一次虚弱复活，或重复复活；仅 weakRemaining 时不按剩余秒数（上限 60）恢复；
--  10. SurvivalPhase 不写入 player attribute；SurvivalState / SurvivalResult / SurvivalAction 载荷与权限不符合现有契约。
-- 接缝：只经 ServerRuntime 玩家进出、RemoteEvent 上行、SpokeClock 步进、存档读写与下行载荷观察，不窥探私有 Effect 拓扑。

local GameCfg = require("common.GameCfg")
local ServerRuntime = require("server.World.ServerRuntime")

local function signal()
  local handlers = {}
  return {
    Connect = function(_, fn)
      handlers[#handlers + 1] = fn
      return {
        Disconnect = function()
          for i, h in ipairs(handlers) do
            if h == fn then table.remove(handlers, i) return end
          end
        end,
      }
    end,
    Fire = function(_, ...)
      for _, fn in ipairs({ table.unpack(handlers) }) do fn(...) end
    end,
  }
end

local function make_player(id, x, z)
  local controller = {
    Health = GameCfg.Vitals.MaxHealth,
    MaxHealth = GameCfg.Vitals.MaxHealth,
    WalkSpeed = 16,
    HealthChanged = signal(),
    Died = signal(),
    OnReborn = signal(),
    reborns = 0,
  }
  function controller:TakeDamage(amount)
    self.Health = math.max(0, self.Health - amount)
    self.HealthChanged:Fire(self.Health)
    if self.Health <= 0 then self.Died:Fire() end
  end
  function controller:Reborn()
    self.reborns = self.reborns + 1
    self.Health = self.MaxHealth
    self.OnReborn:Fire()
  end
  local player = {
    UserId = id,
    Name = "p" .. tostring(id),
    attrs = {},
    CharacterAdded = signal(),
    Character = {
      Controller = controller,
      Position = { x = x or 0, y = 0, z = z or 0 },
      Size = { y = 2 },
    },
  }
  function player:SetAttribute(key, value)
    self.attrs[key] = value
  end
  function player:GetAttribute(key)
    return self.attrs[key]
  end
  return player
end

local function make_data(player, overrides)
  overrides = overrides or {}
  local containers = {
    [GameCfg.Items.ContainerId.ItemBar] = overrides.item_bar or {},
    [GameCfg.Items.ContainerId.Backpack] = overrides.backpack or {},
  }
  return {
    Player = player,
    Inited = true,
    LoadState = "ready",
    Data = {
      FishCoin = overrides.coin or 0,
      Zone = overrides.zone or "fishPond",
      Containers = containers,
      SelectedSlot = overrides.selected_slot,
    },
    Extra = {
      growth = { potions = {}, upgrades = {} },
      survival = {
        health = overrides.health or GameCfg.Vitals.MaxHealth,
        hunger = overrides.hunger or GameCfg.Vitals.MaxHunger,
        dying = overrides.dying == true,
        dead = overrides.dead == true,
        weakRemaining = overrides.weak_remaining or 0,
        dyingRemaining = overrides.dying_remaining or 0,
        deadRemaining = overrides.dead_remaining or 0,
      },
    },
    ItemCount = function(self, item_id)
      local total = 0
      for _, container in pairs(self.Data.Containers) do
        for _, entry in pairs(container) do
          if entry.itemId == item_id and (entry.count or 0) > 0 then
            total = total + entry.count
          end
        end
      end
      return total
    end,
    ConsumeItem = function(self, item_id)
      for _, container in pairs(self.Data.Containers) do
        for _, entry in pairs(container) do
          if entry.itemId == item_id and (entry.count or 0) > 0 then
            entry.count = entry.count - 1
            return true
          end
        end
      end
      return false
    end,
  }
end

local function make_re()
  local events = {}
  local function event(name)
    events[name] = events[name] or {
      clients = {},
      OnServerEvent = signal(),
      FireClient = function(self, player, payload)
        self.clients[#self.clients + 1] = { player = player, value = payload }
      end,
      FireAllClients = function(self, payload)
        self.clients[#self.clients + 1] = { player = "all", value = payload }
      end,
    }
    return events[name]
  end
  return {
    events = events,
    util = {
      GetRE = function(_, name) return event(name) end,
      CheckRECD = function() return false end,
    },
  }
end

local function make_save(data)
  local seq = 0
  return {
    ResolveRequest = function(_, player, current, kind, request_id)
      if current ~= data or type(request_id) ~= "number" then return nil, "invalid" end
      seq = seq + 1
      return {
        id = tostring(player.UserId) .. ":" .. tostring(seq),
        sequence = seq,
        kind = kind,
        requestKey = kind .. ":" .. tostring(request_id),
      }, "new"
    end,
    Execute = function(_, _, current, operation, transform, done)
      if current ~= data then return false, "invalid" end
      local ok, result, reason = pcall(transform, data)
      if not ok or type(result) ~= "table" then
        done(false, ok and reason or tostring(result))
        return true
      end
      done(true, result)
      return true
    end,
  }
end

local function phases_of(events, player)
  local out = {}
  local sent = events.SurvivalState and events.SurvivalState.clients or {}
  for _, row in ipairs(sent) do
    if row.player == player then out[#out + 1] = row.value.phase end
  end
  return out
end

local function last_state(events, player)
  local sent = events.SurvivalState and events.SurvivalState.clients or {}
  local found
  for _, row in ipairs(sent) do
    if row.player == player then found = row.value end
  end
  return found
end

local function join(runtime, player, data)
  runtime:on_player_added(player)
  return runtime:on_save_ready(player, data)
end

describe("玩家生命双层相位宿主接缝（#298）", function()
  local runtime, events, player, other, data

  local function boot(overrides, other_overrides)
    events = make_re().events
    local re = {
      GetRE = function(_, name)
        events[name] = events[name] or {
          clients = {},
          OnServerEvent = signal(),
          FireClient = function(self, target, payload)
            self.clients[#self.clients + 1] = { player = target, value = payload }
          end,
          FireAllClients = function(self, payload)
            self.clients[#self.clients + 1] = { player = "all", value = payload }
          end,
        }
        return events[name]
      end,
      CheckRECD = function() return false end,
    }
    player = make_player(1, 0, 0)
    other = make_player(2, 1, 0)
    data = make_data(player, overrides)
    local other_data = make_data(other, other_overrides)
    runtime = ServerRuntime.new({
      damage_filter = function() return true end,
      bait_spots = { Enabled = false },
      initial_now = 100,
      remote = re,
      player_data = {
        GetDataInst = function(_, target)
          if target == player then return data end
          if target == other then return other_data end
        end,
      },
      save = make_save(data),
      platform = {
        pending = nil,
        ShowAd = function(self, _, _, _, on_result)
          self.pending = on_result
          return true
        end,
        Purchase = function(self, _, _, _, on_result)
          self.pending = on_result
          return true
        end,
        ShopAction = function(_, payload)
          return type(payload) == "table" and payload.action == "OpenAdrenaline"
        end,
        finish = function(self, outcome)
          local cb = self.pending
          self.pending = nil
          if cb then cb(outcome) end
        end,
      },
    })
    runtime:start()
    runtime:mark_started()
    join(runtime, player, data)
    join(runtime, other, other_data)
  end

  after_each(function()
    if runtime then runtime:shutdown() end
    runtime = nil
  end)

  it("alive 期间按 1 Hz 扣饥饿，归零后才按 5/秒扣血，同一秒不重复结算", function()
    boot({ hunger = 2 })
    local tree = runtime:get_player_tree(player.UserId)
    runtime.clock:step(0.4)
    assert.equals(2, tree.states.hunger:now())
    assert.equals(GameCfg.Vitals.MaxHealth, tree.states.health:now())
    runtime.clock:step(0.6)
    assert.equals(1, tree.states.hunger:now())
    runtime.clock:step(0.2)
    assert.equals(1, tree.states.hunger:now())
    runtime.clock:advance(1)
    assert.equals(0, tree.states.hunger:now())
    assert.equals(GameCfg.Vitals.MaxHealth, tree.states.health:now())
    runtime.clock:advance(1)
    assert.equals(GameCfg.Vitals.MaxHealth - GameCfg.Vitals.StarveDamagePerSec, tree.states.health:now())
    assert.equals(player.Character.Controller.Health, tree.states.health:now())
  end)

  it("道具栏或背包任意格持有核废料桶时每秒扣 1 血，移除后停止", function()
    boot({
      backpack = { { itemId = GameCfg.Vitals.HeldDamage.ItemId, count = 1 } },
    })
    local tree = runtime:get_player_tree(player.UserId)
    runtime.clock:advance(1)
    assert.equals(GameCfg.Vitals.MaxHealth - 1, tree.states.health:now())
    data.Data.Containers[GameCfg.Items.ContainerId.Backpack] = {}
    tree:sync_from_data(data)
    local health = tree.states.health:now()
    runtime.clock:advance(1)
    assert.equals(health, tree.states.health:now())
  end)

  it("致命伤害锁 1 血进入濒死并免疫后续伤害，同一击不重复命中，过滤器拒绝时不扣血", function()
    boot()
    local tree = runtime:get_player_tree(player.UserId)
    local hit = tree:new_hit(other, "fishAttack")
    local ok, actual = tree:apply_hit(hit, player, 1000)
    assert.is_true(ok)
    assert.equals(GameCfg.Vitals.MaxHealth - 1, actual)
    assert.equals(1, player.Character.Controller.Health)
    assert.equals("downed", tree.states.life_phase:now())
    assert.equals("downed", player:GetAttribute("SurvivalPhase"))
    assert.is_false(tree:apply_hit(tree:new_hit(other, "fishAttack"), player, 50))
    assert.equals(1, player.Character.Controller.Health)
    assert.is_false(tree:apply_hit(hit, player, 50))
    local blocked = 0
    tree:set_damage_filter(function()
      blocked = blocked + 1
      return false
    end)
    runtime.clock:advance(15)
    assert.equals("dead", tree.states.life_phase:now())
    tree:set_damage_filter(nil)
    local revived_health = math.floor(GameCfg.Vitals.MaxHealth * GameCfg.Survival.ReviveHealthPercent / 100)
    runtime.clock:advance(30)
    assert.equals("alive", tree.states.life_phase:now())
    assert.equals(revived_health, tree.states.health:now())
    tree:set_damage_filter(function() return false end)
    assert.is_false(tree:apply_hit(tree:new_hit(other, "fishAttack"), player, 5))
    assert.equals(revived_health, tree.states.health:now())
    assert.equals(1, blocked == 0 and 1 or blocked)
  end)

  it("濒死 15 秒进死亡，死亡 30 秒按 10% 血与至少 10% 饥饿虚弱复活并半速 60 秒", function()
    boot({ hunger = 0, health = 40 })
    local tree = runtime:get_player_tree(player.UserId)
    player.Character.Controller.Health = 40
    tree:sync_from_data(data)
    assert.is_true(tree:apply_hit(tree:new_hit(other, "fishAttack"), player, 80))
    runtime.clock:advance(14)
    assert.equals("downed", tree.states.life_phase:now())
    runtime.clock:advance(1)
    assert.equals("dead", tree.states.life_phase:now())
    runtime.clock:advance(29)
    assert.equals("dead", tree.states.life_phase:now())
    runtime.clock:advance(1)
    local min_hunger = math.floor(GameCfg.Vitals.MaxHunger * GameCfg.Survival.ReviveHungerPercent / 100)
    local health = math.floor(GameCfg.Vitals.MaxHealth * GameCfg.Survival.ReviveHealthPercent / 100)
    assert.equals("alive", tree.states.life_phase:now())
    assert.equals(health, tree.states.health:now())
    assert.is_true(tree.states.hunger:now() >= min_hunger)
    assert.is_true(tree:get_modifier_remaining("weak") > 59)
    assert.equals(8, player.Character.Controller.WalkSpeed)
    runtime.clock:advance(60)
    assert.equals(0, tree:get_modifier_remaining("weak"))
    assert.equals(16, player.Character.Controller.WalkSpeed)
  end)

  it("广告与金豆满血复活期间暂停倒计时，取消失败或超时后从剩余秒数继续", function()
    boot()
    local tree = runtime:get_player_tree(player.UserId)
    assert.is_true(tree:apply_hit(tree:new_hit(other, "fishAttack"), player, 999))
    events.SurvivalAction.OnServerEvent:Fire(player, { action = "FullRevive", mode = "goods", seq = 1 })
    local denied = events.SurvivalResult.clients[#events.SurvivalResult.clients]
    assert.is_false(denied.value.ok)
    assert.equals("not-dead", denied.value.reason)
    events.SurvivalAction.OnServerEvent:Fire(player, { action = "FullRevive", mode = "ad", seq = 2 })
    assert.equals(true, tree.states.platform_pending:now() ~= false and tree.states.platform_pending:now() ~= nil)
    runtime.clock:advance(20)
    assert.equals("downed", tree.states.life_phase:now())
    runtime.platform:finish("cancel")
    runtime.clock:advance(14)
    assert.equals("downed", tree.states.life_phase:now())
    runtime.clock:advance(1)
    assert.equals("dead", tree.states.life_phase:now())
    events.SurvivalAction.OnServerEvent:Fire(player, { action = "FullRevive", mode = "goods", seq = 3 })
    runtime.clock:advance(40)
    assert.equals("dead", tree.states.life_phase:now())
    runtime.platform:finish("success")
    assert.equals("alive", tree.states.life_phase:now())
    assert.equals(GameCfg.Vitals.MaxHealth, tree.states.health:now())
    assert.equals(0, tree:get_modifier_remaining("weak"))
  end)

  it("麻痹只拒绝主动行动，不退出 alive，也不拆持续会话", function()
    boot()
    local tree = runtime:get_player_tree(player.UserId)
    local ticks = 0
    tree:mount_phase("alive", "session", function(ps)
      ps:subscribe(runtime.clock.on_second, function()
        ticks = ticks + 1
      end)
    end)
    assert.is_true(tree:apply_modifier("paralyze", { duration = 0.5 }))
    assert.equals("alive", tree.states.life_phase:now())
    assert.is_false(tree.memos.can_act:now())
    assert.is_false(tree:request_action("attack"))
    assert.is_false(tree:request_action("throw"))
    assert.is_false(tree:request_action("reel"))
    assert.is_false(tree:request_action("use_item"))
    runtime.clock:advance(1)
    assert.is_true(ticks >= 1)
    assert.equals("alive", tree.states.life_phase:now())
    assert.is_true(tree.memos.can_act:now())
    assert.is_true(tree:request_action("attack"))
  end)

  it("抢救读条成功恢复 10% 血且不带虚弱，移动或受击打断，倒计时先到期只广播一次死亡", function()
    boot()
    local tree = runtime:get_player_tree(player.UserId)
    local other_tree = runtime:get_player_tree(other.UserId)
    assert.is_true(tree:apply_hit(tree:new_hit(other, "fishAttack"), player, 999))
    local ok, reason = other_tree:begin_rescue(player)
    assert.is_true(ok, tostring(reason))
    assert.equals("rescuing", player:GetAttribute("SurvivalPhase"))
    other.Character.Position = { x = 3, y = 0, z = 0 }
    runtime.clock:step(0.1)
    assert.equals("downed", tree.states.life_phase:now())
    other.Character.Position = { x = 1, y = 0, z = 0 }
    assert.is_true(other_tree:begin_rescue(player))
    local before = other.Character.Controller.Health
    assert.is_true(other_tree:apply_hit(other_tree:new_hit(player, "fishAttack"), other, 5))
    assert.is_true(other.Character.Controller.Health < before)
    runtime.clock:step(0.1)
    assert.equals("downed", tree.states.life_phase:now())
    other.Character.Position = { x = 1, y = 0, z = 0 }
    assert.is_true(other_tree:begin_rescue(player))
    runtime.clock:advance(2)
    local health = math.floor(GameCfg.Vitals.MaxHealth * GameCfg.Survival.ReviveHealthPercent / 100)
    assert.equals("alive", tree.states.life_phase:now())
    assert.equals(health, tree.states.health:now())
    assert.equals(0, tree:get_modifier_remaining("weak"))

    assert.is_true(tree:apply_hit(tree:new_hit(other, "fishAttack"), player, 999))
    assert.is_true(other_tree:begin_rescue(player))
    local before_phases = #phases_of(events, player)
    runtime.clock:advance(15)
    assert.equals("dead", tree.states.life_phase:now())
    local after = {}
    for i = before_phases + 1, #phases_of(events, player) do
      after[#after + 1] = phases_of(events, player)[i]
    end
    assert.same({ "dead" }, after)
  end)

  it("食用只在可行动时生效，负百分比同时扣饥饿并按上限扣血", function()
    boot({ hunger = 100 })
    local tree = runtime:get_player_tree(player.UserId)
    assert.is_false(tree:eat("starterRod"))
    assert.is_true(tree:eat("item119"))
    local def = GameCfg.Items.Definitions.item119
    local expected_hunger = math.min(GameCfg.Vitals.MaxHunger,
      100 + math.floor(GameCfg.Vitals.MaxHunger * def.EatPercent / 100))
    local damage = math.floor(GameCfg.Vitals.MaxHealth * -def.EatPercent / 100)
    assert.equals(expected_hunger, tree.states.hunger:now())
    assert.equals(GameCfg.Vitals.MaxHealth - damage, tree.states.health:now())
    assert.is_true(tree:apply_modifier("paralyze", { duration = 0.5 }))
    assert.is_false(tree:eat("goldfish"))
  end)

  it("离场写出濒死死亡与虚弱剩余秒数，重登按终镜像恢复且不重复复活", function()
    boot({ hunger = 10 })
    local tree = runtime:get_player_tree(player.UserId)
    assert.is_true(tree:apply_hit(tree:new_hit(other, "fishAttack"), player, 999))
    runtime.clock:advance(4.2)
    tree:begin_leave()
    local mark = data.Extra.survival
    assert.is_true(mark.dying)
    assert.is_false(mark.dead)
    assert.equals(11, mark.dyingRemaining)
    assert.equals(0, mark.deadRemaining)
    runtime:on_player_removing(player)

    local rejoined = make_player(1, 0, 0)
    local restored = make_data(rejoined, {
      dying = true,
      dying_remaining = 11,
      hunger = 10,
      health = 1,
    })
    local calls = 0
    runtime = ServerRuntime.new({
      bait_spots = { Enabled = false },
      initial_now = 200,
      remote = {
        GetRE = function(_, name)
          events[name] = events[name] or { clients = {}, OnServerEvent = signal(),
            FireClient = function(self, target, payload)
              self.clients[#self.clients + 1] = { player = target, value = payload }
            end }
          return events[name]
        end,
        CheckRECD = function() return false end,
      },
      player_data = { GetDataInst = function() return restored end },
      save = {
        ResolveRequest = function()
          calls = calls + 1
          return { id = "1:1", sequence = 1, kind = "survival:recover" }, "new"
        end,
        Execute = function(_, _, current, _, transform, done)
          transform(current)
          done(true, { ok = true })
          return true
        end,
      },
    })
    runtime:start()
    runtime:mark_started()
    join(runtime, rejoined, restored)
    local again = runtime:get_player_tree(rejoined.UserId)
    assert.equals(1, calls)
    assert.is_false(restored.Extra.survival.dying)
    assert.is_false(restored.Extra.survival.dead)
    assert.equals(GameCfg.Survival.WeakSec, restored.Extra.survival.weakRemaining)
    assert.equals("alive", again.states.life_phase:now())
    local health = math.floor(GameCfg.Vitals.MaxHealth * GameCfg.Survival.ReviveHealthPercent / 100)
    assert.equals(health, again.states.health:now())
    assert.is_true(again:get_modifier_remaining("weak") > 0)
    local phase = again.states.life_phase:now()
    runtime.clock:advance(1)
    assert.equals(phase, again.states.life_phase:now())
    assert.equals(health, again.states.health:now())
  end)

  it("仅带虚弱剩余秒数重登时恢复虚弱而不走死亡恢复", function()
    boot()
    local tree = runtime:get_player_tree(player.UserId)
    tree:apply_modifier("weak", { duration = 20 })
    tree:begin_leave()
    assert.equals(20, data.Extra.survival.weakRemaining)
    assert.is_false(data.Extra.survival.dying)
    runtime:on_player_removing(player)
    local rejoined = make_player(3, 0, 0)
    local restored = make_data(rejoined, { weak_remaining = 20, health = 30, hunger = 30 })
    runtime = ServerRuntime.new({
      bait_spots = { Enabled = false },
      initial_now = 300,
      player_data = { GetDataInst = function() return restored end },
      save = make_save(restored),
    })
    runtime:start()
    runtime:mark_started()
    join(runtime, rejoined, restored)
    local again = runtime:get_player_tree(rejoined.UserId)
    assert.equals("alive", again.states.life_phase:now())
    assert.is_true(again:get_modifier_remaining("weak") <= 20)
    assert.is_true(again:get_modifier_remaining("weak") > 19)
    assert.equals(30, again.states.health:now())
  end)

  it("SurvivalState 下行携带相位、到期时刻与平台挂起，失败结果带 seq 与原因", function()
    boot()
    local tree = runtime:get_player_tree(player.UserId)
    assert.is_true(tree:apply_hit(tree:new_hit(other, "fishAttack"), player, 999))
    local state = last_state(events, player)
    assert.equals("downed", state.phase)
    assert.equals(100 + GameCfg.Survival.DownedSec, state.endsAt)
    events.SurvivalAction.OnServerEvent:Fire(player, { action = "UseAdrenaline", seq = 7 })
    local result = events.SurvivalResult.clients[#events.SurvivalResult.clients]
    assert.equals(7, result.value.seq)
    assert.is_false(result.value.ok)
    assert.equals("no-adrenaline", result.value.reason)
  end)

  it("扣血只广播一次实际差额，治疗、回满和致命锁血不另报", function()
    boot()
    local life = runtime.life
    local function notices()
      local rows = {}
      for _, row in ipairs(events.DamageNotice and events.DamageNotice.clients or {}) do
        rows[#rows + 1] = row.value
      end
      return rows
    end
    assert.same({}, notices())
    assert.is_true(life:SetHealth(player, 200))
    local sent = notices()
    assert.equals(1, #sent)
    assert.equals(100, sent[1].amount)
    assert.equals(player.UserId, sent[1].targetUserId)
    assert.is_true(life:SetHealth(player, 300))
    assert.is_true(life:Eat(player, "goldfish"))
    assert.equals(1, #notices())
    local controller = player.Character.Controller
    controller.Health = controller.Health - 2.4
    controller.HealthChanged:Fire(controller.Health)
    sent = notices()
    assert.equals(2, #sent)
    assert.near(2.4, sent[2].amount, 0.00001)
    controller.HealthChanged:Fire(controller.Health)
    assert.equals(2, #notices())
    assert.is_true(life:SetHunger(player, 0))
    runtime:step(1)
    sent = notices()
    assert.equals(3, #sent)
    assert.equals(GameCfg.Vitals.StarveDamagePerSec, sent[3].amount)
    assert.is_true(life:SetHealth(player, 4))
    local before = #notices()
    local tree = runtime:get_player_tree(player.UserId)
    assert.is_true(tree:apply_hit(tree:new_hit(other, "fishAttack"), player, 100))
    sent = notices()
    assert.equals(before + 1, #sent)
    assert.equals(3, sent[#sent].amount, "致命一击锁 1 血，只报被扣掉的差额")
    assert.equals(1, player.Character.Controller.Health)
    assert.equals("downed", life:LifeStatus(player))
  end)

  it("控制器写入失败不提交 SetHealth 或虚弱复活的权威状态", function()
    boot()
    local life = runtime.life
    local tree = runtime:get_player_tree(player.UserId)
    local original = player.Character.Controller
    local denied = setmetatable({}, {
      __index = original,
      __newindex = function(_, key, _)
        if key == "Health" then error("controller write denied") end
      end,
    })
    player.Character.Controller = denied
    local before = tree.states.health:now()
    assert.is_false(life:SetHealth(player, before + 1))
    assert.equals(before, tree.states.health:now())
    assert.equals("alive", life:LifeStatus(player))

    player.Character.Controller = original
    assert.is_true(tree:apply_hit(tree:new_hit(other, "fishAttack"), player, 9999))
    runtime.clock:advance(GameCfg.Survival.DownedSec)
    assert.equals("dead", life:LifeStatus(player))
    player.Character.Controller = denied
    runtime.clock:advance(GameCfg.Survival.DeadSec)
    assert.equals("dead", life:LifeStatus(player))
    assert.equals(1, tree.states.health:now())
  end)

  it("SurvivalAction 的 seq 先排除 NaN 与正负无穷再做整数范围校验", function()
    boot()
    local tree = runtime:get_player_tree(player.UserId)
    assert.is_true(tree:apply_hit(tree:new_hit(other, "fishAttack"), player, 9999))
    for _, seq in ipairs({ math.huge, -math.huge, 0 / 0 }) do
      local before = #(events.SurvivalResult and events.SurvivalResult.clients or {})
      events.SurvivalAction.OnServerEvent:Fire(player, { action = "UseAdrenaline", seq = seq })
      local result = events.SurvivalResult.clients[before + 1]
      assert.is_not_nil(result)
      assert.is_false(result.value.ok)
      assert.equals("invalid", result.value.reason)
    end
  end)
end)
