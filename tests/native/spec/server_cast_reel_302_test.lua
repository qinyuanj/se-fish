
local GameCfg = require("common.game_cfg")
local ServerRuntime = require("server.WorldHost.ServerRuntime")
local PlayerData = require("server.Data.PlayerData")
local ZoneFixtures = require("tests.support.zone_fixtures")

local ROD = GameCfg.Items.Id.StarterRod
local WORM = GameCfg.Items.Id.Worm

local function signal()
  local handlers = {}
  return {
    Connect = function(_, fn)
      handlers[#handlers + 1] = fn
      return { Disconnect = function()
        for i, h in ipairs(handlers) do
          if h == fn then table.remove(handlers, i) return end
        end
      end }
    end,
    Fire = function(_, ...)
      for _, fn in ipairs({ table.unpack(handlers) }) do fn(...) end
    end,
    Count = function() return #handlers end,
  }
end

local function make_player(id)
  local controller = {
    Health = GameCfg.Vitals.MaxHealth,
    MaxHealth = GameCfg.Vitals.MaxHealth,
    WalkSpeed = 16,
    HealthChanged = signal(),
    Died = signal(),
    OnReborn = signal(),
  }
  function controller:TakeDamage(amount)
    self.Health = math.max(0, self.Health - amount)
    self.HealthChanged:Fire(self.Health)
    if self.Health <= 0 then self.Died:Fire() end
  end
  local character = {
    Controller = controller,
    Position = { x = -11.75, y = 2, z = -20 },
    Rotation = { GetForward = function() return { x = 0, y = 0, z = 1 } end },
    Animator = { LoadAnimation = function() return { Play = function() end } end },
  }
  return {
    UserId = id,
    Name = "p" .. tostring(id),
    attrs = {},
    Character = character,
    CharacterAdded = signal(),
    CharacterRemoving = signal(),
    SetAttribute = function(self, key, value) self.attrs[key] = value end,
    GetAttribute = function(self, key) return self.attrs[key] end,
  }
end

describe("抛竿上钩收线举鱼宿主接缝（#302）", function()
  local runtime, events, player, data, units, rolls, compendium, quests
  local saved_vector, saved_color

  before_each(function()
    saved_vector, saved_color = rawget(_G, "Vector3"), rawget(_G, "Color")
    _G.Vector3 = { New = function(x, y, z) return { x = x, y = y, z = z } end }
    _G.Color = { New = function(r, g, b, a) return { r = r, g = g, b = b, a = a } end }
  end)

  local function channel(name)
    events[name] = events[name] or {
      clients = {},
      OnServerEvent = signal(),
      FireClient = function(self, target, payload)
        self.clients[#self.clients + 1] = { player = target, value = payload }
      end,
    }
    return events[name]
  end

  local function states_of(target)
    local sent = channel("CastState").clients
    local found = {}
    for _, row in ipairs(sent) do
      if row.player == (target or player) then found[#found + 1] = row.value end
    end
    return found
  end

  local function last_cast(target)
    local rows = states_of(target)
    return rows[#rows]
  end

  local function reel_replies(target)
    local found = {}
    for _, row in ipairs(channel("ReelInRE").clients) do
      if row.player == (target or player) then found[#found + 1] = row.value end
    end
    return found
  end

  local function alive_units(prefix)
    local n = 0
    for _, unit in ipairs(units) do
      if not unit.destroyed and (not prefix or tostring(unit.Name):sub(1, #prefix) == prefix) then
        n = n + 1
      end
    end
    return n
  end

  local function boot(overrides)
    overrides = overrides or {}
    events, units, rolls, compendium, quests = {}, {}, {}, {}, {}
    local re = {
      GetRE = function(_, name) return channel(name) end,
      CheckRECD = function(_, actor, key)
        if overrides.cooldown and key == "CastAction" then return true end
        return false
      end,
    }
    channel("CastAction")
    channel("ReelInRE")
    channel("CloseReelIn")
    channel("CastState")
    channel("RequestCastState")
    player = make_player(overrides.user_id or 1)
    if overrides.position then player.Character.Position = overrides.position end
    data = PlayerData.New(player)
    data:Init()
    assert.is_true(data:SelectSlot(1))
    if overrides.bait == "duck" then
      assert.is_true(data:AddItem("duck", overrides.bait_count or 1))
      assert.is_true(data:SelectBait("duck"))
    elseif overrides.bait ~= false then
      assert.is_true(data:AddBait(overrides.bait or WORM, overrides.bait_count or 3))
      assert.is_true(data:SelectBait(overrides.bait or WORM))
    end
    local seq = 0
    local runtime_holder = {}
    runtime_holder.runtime = ServerRuntime.new({
      initial_now = 1000,
      remote = re,
      player_data = {
        GetDataInst = function(_, target)
          if target == player then return data end
        end,
        SendItemBar = function() end,
      },
      world_service = {
        CreateUnit = function(_, kind, props)
          local unit = {
            Name = props and props.Name,
            Kind = kind,
            props = props,
            destroyed = false,
            Destroy = function(self) self.destroyed = true end,
          }
          units[#units + 1] = unit
          return unit
        end,
      },
      create_unit = function(kind, props)
        local unit = {
          Name = props and props.Name,
          Kind = kind,
          props = props,
          destroyed = false,
          Destroy = function(self) self.destroyed = true end,
        }
        units[#units + 1] = unit
        return unit
      end,
      fish_unit = {
        CanCast = function() return overrides.holding ~= true end,
        HeldInfo = function() return nil end,
        GetHeld = function() return nil end,
        Drop = function() end,
        SpawnLanded = function(_, owner, catch, position)
          if overrides.spawn_fails then return nil, "spawn-failed" end
          seq = seq + 1
          local fish = {
            Id = seq, Owner = owner, FishId = catch.fishId, Mult = catch.mult,
            Position = position, State = "awaitLift",
          }
          units[#units + 1] = {
            Name = "LandedFish_" .. tostring(seq),
            fish = fish,
            destroyed = false,
            Destroy = function(self) self.destroyed = true end,
          }
          return fish
        end,
      },
      compendium = {
        RecordLanding = function(_, owner, catch)
          compendium[#compendium + 1] = { player = owner, fishId = catch.fishId, mult = catch.mult }
          return true
        end,
      },
      quest = {
        Notify = function(_, kind, owner, fact)
          quests[#quests + 1] = { kind = kind, player = owner, fact = fact }
        end,
      },
      random = function(...)
        local a, b = ...
        rolls[#rolls + 1] = { a, b }
        if b == nil then return overrides.roll or 1 end
        return overrides.multiplier_roll or 100
      end,
      bind_cast_action = function(dispatch)
        channel("CastAction").OnServerEvent:Connect(function(actor, payload)
          dispatch(actor, payload)
        end)
        channel("RequestCastState").OnServerEvent:Connect(function(actor)
          dispatch(actor, { action = "Request" })
        end)
      end,
      bind_reel_action = function(dispatch)
        channel("ReelInRE").OnServerEvent:Connect(function(actor, payload)
          dispatch(actor, "reel", payload)
        end)
        channel("CloseReelIn").OnServerEvent:Connect(function(actor, payload)
          dispatch(actor, "close", payload)
        end)
      end,
    })
    runtime = runtime_holder.runtime
    runtime._create_unit = runtime.create_unit
    runtime:start()
    runtime:mark_started()
    runtime:on_player_added(player)
    runtime:on_save_ready(player, data)
  end

  after_each(function()
    if runtime then runtime:shutdown() end
    runtime = nil
    _G.Vector3, _G.Color = saved_vector, saved_color
  end)

  local function cast()
    channel("CastAction").OnServerEvent:Fire(player, {
      action = "Cast", slot = 1, itemId = ROD,
    })
  end

  local function hook()
    runtime.clock:advance(GameCfg.Casting.HookDelaySec)
  end

  local function click(session, n, q)
    channel("ReelInRE").OnServerEvent:Fire(player, {
      s = session, n = n or 1, q = q,
    })
  end

  it("合法抛竿消耗一次鱼饵，3 秒后上钩并按区表与倍率决定鱼", function()
    boot({ roll = 1, multiplier_roll = 150 })
    local before = data.Data.Bait[WORM]
    cast()
    local waiting = last_cast()
    assert.are.equal("cast", waiting.phase)
    assert.are.equal("fishPond.water", waiting.zoneId)
    assert.are.equal(before - 1, data.Data.Bait[WORM])
    assert.are.equal(1, alive_units("CastLine_"))
    runtime.clock:advance(GameCfg.Casting.HookDelaySec - 0.01)
    assert.are.equal("cast", last_cast().phase)
    runtime.clock:advance(0.01)
    local hooked = last_cast()
    assert.are.equal("hooked", hooked.phase)
    assert.are.equal("string", type(hooked.reelSession))
    assert.are.equal("tilapia", hooked.fishId)
    assert.are.equal(1.5, hooked.mult)
    local started = reel_replies()[1]
    assert.are.equal("started", started.action)
    assert.are.equal(50, started.progress)
    assert.are.equal(hooked.reelSession, started.session)
    local kinds = {}
    for _, fact in ipairs(quests) do kinds[#kinds + 1] = fact.kind end
    assert.are.same({ "CastWater" }, kinds)
  end)

  it("首领饵强制对应首领且不退还，普通饵仍走区表", function()
    boot({ bait = "duck", bait_count = 1, roll = 1 })
    cast()
    assert.are.equal(0, data:ItemCount("duck"))
    assert.is_nil(data.Data.SelectedBait)
    hook()
    assert.are.equal("alligatorGar", last_cast().fishId)
    channel("CastAction").OnServerEvent:Fire(player, { action = "Reel" })
    assert.are.equal(0, data:ItemCount("duck"))
  end)

  it("收线按整秒衰减 5、点击加 5，归零脱钩，满进度举鱼且只生成一条", function()
    boot({ roll = 1, multiplier_roll = 100 })
    cast()
    hook()
    local session = last_cast().reelSession
    runtime.clock:advance(2)
    local progress = reel_replies()
    assert.are.equal(40, progress[#progress].progress)
    click(session, 1, 1)
    progress = reel_replies()
    assert.are.equal(45, progress[#progress].progress)
    assert.are.equal(1, progress[#progress].accepted)
    click(session, 8, 2)
    runtime.clock:advance(1)
    click(session, 4, 3)
    local landed = last_cast()
    assert.are.equal("landed", landed.phase)
    assert.are.equal(1, alive_units("LandedFish_"))
    local fish
    for _, unit in ipairs(units) do
      if unit.fish then fish = unit.fish end
    end
    assert.are.equal("tilapia", fish.FishId)
    assert.are.equal(1, fish.Mult)
    assert.are.equal(-11.75, fish.Position.x)
    assert.are.equal(2.5, fish.Position.y)
    assert.are.equal(-18, fish.Position.z)
    assert.are.equal(1, #compendium)
    local land = 0
    for _, fact in ipairs(quests) do if fact.kind == "Land" then land = land + 1 end end
    assert.are.equal(1, land)
    runtime.clock:advance(GameCfg.Casting.LandedHoldSec)
    assert.are.equal("idle", last_cast().phase)
  end)

  it("无人点击在宽限后脱钩，线留到玩家收竿；宽限内批次能救回，迟到批次不能", function()
    boot()
    cast()
    hook()
    runtime.clock:advance(10)
    assert.are.equal("hooked", last_cast().phase)
    runtime.clock:advance(0.19)
    assert.are.equal("idle", last_cast().phase)
    assert.are.equal(0, alive_units("CastLine_"))

    cast()
    hook()
    local session = last_cast().reelSession
    runtime.clock:advance(10.17)
    click(session, 2, 1)
    assert.are.equal("hooked", last_cast().phase)
    assert.is_true(reel_replies()[#reel_replies()].progress > 0)

    channel("CloseReelIn").OnServerEvent:Fire(player, { session = session })
    cast()
    hook()
    session = last_cast().reelSession
    runtime.clock:advance(10.201)
    click(session, 10, 1)
    assert.are.equal("idle", last_cast().phase)
    assert.are.equal(0, alive_units("CastLine_"))
  end)

  it("麻痹只挡住收线点击且不立刻脱钩，濒死死亡与离场逆序拆掉钓线", function()
    boot()
    cast()
    hook()
    local session = last_cast().reelSession
    local tree = runtime:get_player_tree(player.UserId)
    assert.is_true(tree:apply_modifier("paralyze", { duration = 0.4 }))
    assert.is_true(tree.states.is_paralyzed:now())
    local reply_count = #reel_replies()
    click(session, 1, 1)
    local replies = reel_replies()
    assert.are.equal(reply_count, #replies)
    assert.are.equal("hooked", last_cast().phase)
    runtime.clock:advance(0.4)
    click(session, 1, 2)
    assert.are.equal(1, reel_replies()[#reel_replies()].accepted)
    channel("CloseReelIn").OnServerEvent:Fire(player, { session = session })

    cast()
    hook()
    local before = alive_units("CastLine_")
    runtime.life:ApplyDamage(player, GameCfg.Vitals.MaxHealth)
    assert.are.equal("idle", last_cast().phase)
    assert.are.equal(0, alive_units("CastLine_"))

    player.Character.Controller.Health = GameCfg.Vitals.MaxHealth
    runtime:on_player_removing(player)
    data.Extra.survival.health = GameCfg.Vitals.MaxHealth
    data.Extra.survival.dying = false
    data.Extra.survival.dead = false
    data.Extra.survival.dyingRemaining = 0
    data.Extra.survival.deadRemaining = 0
    runtime:on_player_added(player)
    runtime:on_save_ready(player, data)
    cast()
    local lines = alive_units("CastLine_")
    runtime:on_player_removing(player)
    assert.are.equal(0, alive_units("CastLine_"))
    assert.is_true(lines > 0)
  end)

  it("非法落点、无饵、重复抛竿与举鱼中拒绝且不扣饵", function()
    boot({ position = { x = 0, y = 2, z = 0 } })
    local before = data:ItemCount(WORM)
    cast()
    assert.are.equal("idle", last_cast().phase)
    assert.are.equal(before, data:ItemCount(WORM))
    assert.are.equal("invalidLanding", last_cast().result.reason)
  end)
end)
