local GameCfg = require("common.game_cfg")
local ServerRuntime = require("server.world_host.server_runtime")
local PlayerData = require("server.data.player_data")

local Host = {}
local ROD = GameCfg.Items.Id.StarterRod
local WORM = GameCfg.Items.Id.Worm

local function signal()
  local handlers = {}
  return {
    Connect = function(_, fn)
      handlers[#handlers + 1] = fn
      return { Disconnect = function()
        for i, h in ipairs(handlers) do if h == fn then table.remove(handlers, i) return end end
      end }
    end,
    Fire = function(_, ...)
      for _, fn in ipairs({ table.unpack(handlers) }) do fn(...) end
    end,
    Count = function() return #handlers end,
  }
end

local function make_player(id, opts)
  local controller = {
    Health = GameCfg.Vitals.MaxHealth, MaxHealth = GameCfg.Vitals.MaxHealth, WalkSpeed = 16,
    HealthChanged = signal(), Died = signal(), OnReborn = signal(),
  }
  function controller:TakeDamage(amount)
    self.Health = math.max(0, self.Health - amount)
    self.HealthChanged:Fire(self.Health)
    if self.Health <= 0 then self.Died:Fire() end
  end
  local character = {
    Controller = controller,
    Position = opts.position or { x = -11.75, y = 2, z = -20 },
    Rotation = { GetForward = function() return opts.forward or { x = 0, y = 0, z = 1 } end },
    Animator = { LoadAnimation = function() return { Play = function() end } end },
  }
  return {
    UserId = id, Name = "p" .. tostring(id), attrs = {}, Character = character,
    CharacterAdded = signal(), CharacterRemoving = signal(),
    SetAttribute = function(self, key, value) self.attrs[key] = value end,
    GetAttribute = function(self, key) return self.attrs[key] end,
  }
end

function Host.new(opts)
  opts = opts or {}
  local env = {
    events = {}, units = {}, compendium = {}, quests = {}, rolls = {}, now = 1000,
    saved_vector = rawget(_G, "Vector3"), saved_color = rawget(_G, "Color"),
  }
  _G.Vector3 = { New = function(x, y, z) return { x = x, y = y, z = z } end }
  _G.Color = { New = function(r, g, b, a) return { r = r, g = g, b = b, a = a } end }
  local function channel(name)
    env.events[name] = env.events[name] or {
      clients = {}, OnServerEvent = signal(),
      FireClient = function(self, target, payload)
        self.clients[#self.clients + 1] = { player = target, value = payload }
      end,
    }
    return env.events[name]
  end
  env.channel = channel
  local remote = {
    get_re = function(_, name) return channel(name) end,
    check_recd = function(_, _, key)
      return opts.cooldown == true and key == "CastAction"
    end,
  }
  for _, name in ipairs({ "CastAction", "ReelInRE", "CloseReelIn", "CastState", "RequestCastState" }) do channel(name) end
  env.player = make_player(opts.user_id or 1, opts)
  env.data = PlayerData.new(env.player)
  env.data:Init()
  assert(env.data:SelectSlot(1))
  if opts.bait and GameCfg.Casting.BossBait[opts.bait] then
    for _ = 1, opts.bait_count or 1 do assert(env.data:AddItem(opts.bait)) end
    assert(env.data:SelectBait(opts.bait))
  elseif opts.bait == false then
    env.data:SelectBait(nil)
  else
    assert(env.data:AddBait(opts.bait or WORM, opts.bait_count or 3))
    assert(env.data:SelectBait(opts.bait or WORM))
  end
  local seq = 0
  local function create_unit(kind, props)
    local unit = {
      Name = props and props.Name, Kind = kind, props = props, destroyed = false,
      Destroy = function(self) self.destroyed = true end,
    }
    env.units[#env.units + 1] = unit
    return unit
  end
  env.runtime = ServerRuntime.new({
    initial_now = env.now,
    remote = remote,
    player_data = {
      get_data_inst = function(_, target) if target == env.player then return env.data end end,
      send_item_bar = function() end,
    },
    world_service = { CreateUnit = function(_, kind, props) return create_unit(kind, props) end },
    create_unit = create_unit,
    fish_unit = {
      can_cast = function() return opts.holding ~= true end,
      held_info = function() return nil end,
      get_held = function() return nil end,
      drop = function() end,
      spawn_landed = function(_, owner, catch, position)
        if opts.spawn_fails then return nil, "spawn-failed" end
        seq = seq + 1
        local fish = { Id = seq, Owner = owner, fish_id = catch.fishId, mult = catch.mult,
          Position = position, State = "awaitLift" }
        env.units[#env.units + 1] = { Name = "LandedFish_" .. tostring(seq), fish = fish,
          destroyed = false, Destroy = function(self) self.destroyed = true end }
        return fish
      end,
    },
    compendium = { record_landing = function(_, owner, catch)
      env.compendium[#env.compendium + 1] = { player = owner, fishId = catch.fishId, mult = catch.mult }
      return true
    end },
    quest = { notify = function(_, kind, owner, fact)
      env.quests[#env.quests + 1] = { kind = kind, player = owner, fact = fact }
    end },
    random = function(...)
      local a, b = ...
      env.rolls[#env.rolls + 1] = { a, b }
      if b == nil then return opts.roll or 1 end
      return opts.multiplier_roll or 100
    end,
    bind_cast_action = function(dispatch)
      channel("CastAction").OnServerEvent:Connect(function(actor, payload) dispatch(actor, payload) end)
      channel("RequestCastState").OnServerEvent:Connect(function(actor) dispatch(actor, { action = "Request" }) end)
    end,
    bind_reel_action = function(dispatch)
      channel("ReelInRE").OnServerEvent:Connect(function(actor, payload) dispatch(actor, "reel", payload) end)
      channel("CloseReelIn").OnServerEvent:Connect(function(actor, payload) dispatch(actor, "close", payload) end)
    end,
  })
  env.runtime:start()
  env.runtime:mark_started()
  env.runtime:on_player_added(env.player)
  env.runtime:on_save_ready(env.player, env.data)

  function env:cast(payload)
    channel("CastAction").OnServerEvent:Fire(self.player, payload or { action = "Cast", slot = 1, itemId = ROD })
  end
  function env:reel_back()
    channel("CastAction").OnServerEvent:Fire(self.player, { action = "Reel" })
  end
  function env:request()
    channel("RequestCastState").OnServerEvent:Fire(self.player)
  end
  function env:click(session, n, q)
    channel("ReelInRE").OnServerEvent:Fire(self.player, { s = session, n = n or 1, q = q })
  end
  function env:close(session)
    channel("CloseReelIn").OnServerEvent:Fire(self.player, { session = session })
  end
  function env:advance(seconds)
    self.now = self.now + seconds
    self.runtime:step(seconds, self.now)
  end
  function env:hook()
    self:advance(GameCfg.Casting.HookDelaySec)
  end
  function env:states(target)
    local rows, found = channel("CastState").clients, {}
    for _, row in ipairs(rows) do if row.player == (target or self.player) then found[#found + 1] = row.value end end
    return found
  end
  function env:last_state(target)
    local rows = self:states(target)
    return rows[#rows]
  end
  function env:reel_replies(target)
    local found = {}
    for _, row in ipairs(channel("ReelInRE").clients) do
      if row.player == (target or self.player) then found[#found + 1] = row.value end
    end
    return found
  end
  function env:alive_units(prefix)
    local n = 0
    for _, unit in ipairs(self.units) do
      if not unit.destroyed and (not prefix or tostring(unit.Name):sub(1, #prefix) == prefix) then n = n + 1 end
    end
    return n
  end
  function env:dispose()
    if self.runtime then self.runtime:shutdown() end
    self.runtime = nil
    _G.Vector3, _G.Color = self.saved_vector, self.saved_color
  end
  return env
end

return Host
