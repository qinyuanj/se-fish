
local GameCfg = require("common.game_cfg")
local ServerRuntime = require("server.world_host.server_runtime")

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

local function vec(x, y, z)
  return { x = x, y = y, z = z }
end

local function make_character(x, y, z, fx, fz)
  local character = {
    Position = vec(x, y, z),
    Rotation = { GetForward = function() return { x = fx or 0, y = 0, z = fz or 1 } end },
    Controller = {
      GravityEnabled = true,
      WalkSpeed = 6,
      Health = GameCfg.Vitals.MaxHealth,
      TakeDamage = function(self, amount) self.Health = self.Health - amount end,
    },
    Calls = {},
    Units = {},
  }
  character.EggyAppearance = {
    BindAppearance = function(_, asset_id, socket, offset, rot, scale)
      character.Calls[#character.Calls + 1] = { "bind", asset_id, socket, offset, rot, scale }
      return 77
    end,
    UnbindAppearance = function(_, bind_id)
      character.Calls[#character.Calls + 1] = { "unbind", bind_id }
      return true
    end,
    SetAppearanceByAssetId = function(_, asset_id)
      character.Calls[#character.Calls + 1] = { "skin", asset_id }
      return true
    end,
    ResetAppearance = function()
      character.Calls[#character.Calls + 1] = { "resetSkin" }
      return true
    end,
  }
  return character
end

local function has_call(character, kind)
  for _, call in ipairs(character.Calls) do
    if call[1] == kind then return true end
  end
  return false
end

local function make_player(id, x, y, z, fx, fz)
  local attributes = {}
  return {
    UserId = id,
    Character = make_character(x, y or 5.01, z, fx, fz),
    GetAttribute = function(_, key) return attributes[key] end,
    SetAttribute = function(_, key, value) attributes[key] = value end,
  }
end

local function make_data(player, item_id, zone)
  local bar = {}
  if item_id then bar[1] = { itemId = item_id, count = 1 } end
  return {
    Player = player,
    inited = true,
    load_state = "ready",
    data = {
      FishCoin = 0,
      Zone = zone or "fishPond",
      selected_slot = item_id and 1 or nil,
      upgrade_level = 0,
      containers = {
        [GameCfg.Items.ContainerId.ItemBar] = bar,
        [GameCfg.Items.ContainerId.Backpack] = {},
      },
      Bait = {},
      weapons = {},
    },
    extra = {
      cooldowns = {},
      survival = { health = GameCfg.Vitals.MaxHealth, hunger = GameCfg.Vitals.MaxHunger },
    },
  }
end

local function make_re()
  local events = {}
  return {
    events = events,
    check_recd = function() return false end,
    get_re = function(_, name)
      events[name] = events[name] or {
        clients = {},
        OnServerEvent = signal(),
        FireClient = function(self, target, payload)
          self.clients[#self.clients + 1] = { player = target, value = payload }
          if name == "SpecialItemResult" then target.last_result = payload end
          if name == "SpecialItemState" then target.lastState = payload end
        end,
      }
      return events[name]
    end,
  }
end

local function last_state(events, player)
  local sent = events.SpecialItemState and events.SpecialItemState.clients or {}
  local found
  for _, row in ipairs(sent) do
    if row.player == player then found = row.value end
  end
  return found
end

describe("风神之翼与哥斯拉存活相位宿主接缝（#299）", function()
  local runtime, events, re, player, other, data, other_data
  local saved_assets
  local created
  local fail_model

  local function select_item(target, item_id)
    local record = target == player and data or other_data
    local bar = record.data.containers[GameCfg.Items.ContainerId.ItemBar]
    bar[1] = item_id and { itemId = item_id, count = 1 } or nil
    record.data.selected_slot = item_id and 1 or nil
    runtime:get_player_tree(target.UserId):sync_from_data(record)
  end

  local function act(target, payload)
    events.SpecialItemAction.OnServerEvent:Fire(target, payload)
  end

  local function boot(item_id, other_item)
    created = {}
    re = make_re()
    events = re.events
    player = make_player(1, 6, 5.01, 40)
    other = make_player(2, 8, 5.01, 40)
    data = make_data(player, item_id)
    other_data = make_data(other, other_item)
    runtime = ServerRuntime.new({
      damage_filter = function() return true end,
      initial_now = 1000,
      remote = re,
      player_data = {
        get_data_inst = function(_, target)
          if target == player then return data end
          if target == other then return other_data end
        end,
      },
      create_unit = function(unit_type, props)
        if fail_model and unit_type == "WorldUnit" then error("no-model") end
        local unit = {
          UnitType = unit_type,
          Name = props and props.Name,
          Parent = props and props.Parent,
          Destroyed = false,
          Destroy = function(self) self.Destroyed = true end,
        }
        created[#created + 1] = unit
        return unit
      end,
      fish_carrier = {
        Fish = {},
        resolve_carrier = function(_, target)
          return type(target) == "table" and target.carrier or nil
        end,
        Damage = function(_, carrier, amount)
          carrier.Damage = (carrier.Damage or 0) + amount
          carrier.hits = (carrier.hits or 0) + 1
          return true, amount
        end,
      },
    })
    runtime:start()
    runtime:mark_started()
    runtime:on_player_added(player)
    runtime:on_save_ready(player, data)
    runtime:on_player_added(other)
    runtime:on_save_ready(other, other_data)
    runtime.clock:step(0.05)
  end

  before_each(function()
    saved_assets = {
      wing = GameCfg.Ability.SpecialItem.Wings.AppearanceAssetId,
      skin = GameCfg.Ability.SpecialItem.Godzilla.AppearanceAssetId,
    }
    fail_model = false
    GameCfg.Ability.SpecialItem.Wings.AppearanceAssetId = "wingAssetPlaceholder"
    GameCfg.Ability.SpecialItem.Godzilla.AppearanceAssetId = "godzillaSkinPlaceholder"
    _G.Vector3 = { New = vec }
    _G.Quaternion = { Identity = function() return { x = 0, y = 0, z = 0, w = 1 } end }
    _G.Enums = { SkeletalSocketType = { Spine = "socket_body" } }
  end)

  after_each(function()
    if runtime then runtime:shutdown() end
    runtime = nil
    GameCfg.Ability.SpecialItem.Wings.AppearanceAssetId = saved_assets.wing
    GameCfg.Ability.SpecialItem.Godzilla.AppearanceAssetId = saved_assets.skin
  end)

  it("选中风神之翼绑定外观且地面保留重力，长按才接管并升到天花板后缓降落地", function()
    boot("item169")
    assert.is_true(has_call(player.Character, "bind"))
    local bind
    for _, call in ipairs(player.Character.Calls) do
      if call[1] == "bind" then bind = call end
    end
    assert.equals(_G.Enums.SkeletalSocketType.Spine, bind[3])
    assert.same({ x = 0, y = 0, z = 0 }, bind[4])
    assert.same({ x = 0, y = 0, z = 0, w = 1 }, bind[5])
    assert.same({ x = 1, y = 1, z = 1 }, bind[6])
    assert.is_true(player.Character.Controller.GravityEnabled)
    local state = last_state(events, player)
    assert.equals("wings", state and state.effect)

    act(player, { action = "fly", holding = true })
    runtime.clock:step(0.05)
    assert.is_false(player.Character.Controller.GravityEnabled)
    runtime.clock:step(6)
    assert.near(25.01, player.Character.Position.y, 0.05)

    player.Character.Position = vec(999, player.Character.Position.y, 40)
    runtime.clock:step(0.05)
    assert.is_true(player.Character.Position.x <= 69)
    player.Character.Position = vec(6, player.Character.Position.y, -500)
    runtime.clock:step(0.05)
    assert.is_true(player.Character.Position.z >= -59)

    act(player, { action = "fly", holding = false })
    runtime.clock:step(8)
    assert.near(5.01, player.Character.Position.y, 0.05)
    assert.is_true(player.Character.Controller.GravityEnabled)
    assert.is_false(last_state(events, player).airborne)
  end)

  it("未选中翅膀时飞行被拒绝，半空切槽或丢弃立即解绑并交还重力", function()
    boot("carp")
    local y = player.Character.Position.y
    act(player, { action = "fly", holding = true })
    runtime.clock:step(0.5)
    assert.equals(y, player.Character.Position.y)
    assert.is_true(player.Character.Controller.GravityEnabled)
    assert.is_false(player.last_result.ok)
    assert.equals("not-wings", player.last_result.reason)

    select_item(player, "item169")
    act(player, { action = "fly", holding = true })
    runtime.clock:step(1)
    assert.is_true(player.Character.Position.y > 6)
    select_item(player, "carp")
    assert.is_true(has_call(player.Character, "unbind"))
    assert.is_true(player.Character.Controller.GravityEnabled)
    assert.is_nil(last_state(events, player).effect)

    select_item(player, "item169")
    act(player, { action = "fly", holding = true })
    runtime.clock:step(0.2)
    select_item(player, nil)
    assert.is_true(player.Character.Controller.GravityEnabled)
    assert.is_nil(last_state(events, player).effect)
  end)

  it("缓降被高于起飞点的地形托住时判落地并交还重力", function()
    boot("item169")
    act(player, { action = "fly", holding = true })
    runtime.clock:step(1)
    local risen = player.Character.Position.y
    act(player, { action = "fly", holding = false })
    runtime.clock:step(0.05)
    player.Character.Position = vec(6, risen, 40)
    runtime.clock:step(0.2)
    assert.is_true(player.Character.Controller.GravityEnabled)
    assert.is_false(last_state(events, player).airborne)
  end)

  it("选中哥斯拉换皮肤且不改移速，切走后复位", function()
    boot("item170")
    assert.is_true(has_call(player.Character, "skin"))
    assert.equals(6, player.Character.Controller.WalkSpeed)
    assert.equals("godzilla", last_state(events, player).effect)
    select_item(player, nil)
    assert.is_true(has_call(player.Character, "resetSkin"))
    assert.is_nil(last_state(events, player).effect)
  end)

  it("哥斯拉吐息按走廊分段结算其他玩家与活鱼，冷却中、未变身与打自己都被拒绝", function()
    boot("item170")
    local carrier = { dead = false, body = { Position = vec(6, 5.01, 55) }, Damage = 0, hits = 0 }
    runtime.fish_carrier = runtime.fish_carrier or {}
    local tree = runtime:get_player_tree(player.UserId)
    tree.fish_units = { { Id = "f1", carrier = carrier } }

    act(player, { action = "breath" })
    assert.is_true(player.last_result.ok)
    runtime.clock:step(3)
    local breath = GameCfg.Ability.SpecialItem.Godzilla.Breath
    assert.equals(1, other.Character.Controller.Health)
    assert.equals("downed", runtime:get_player_tree(other.UserId).states.life_phase:now())
    assert.equals(breath.TotalDamage, carrier.Damage)
    assert.equals(math.floor(breath.DurationSec / breath.TickSec), carrier.hits)
    assert.equals(GameCfg.Vitals.MaxHealth, player.Character.Controller.Health)

    local behind = make_player(3, 6, 5.01, 5)
    local behind_data = make_data(behind, nil)
    runtime:on_player_added(behind)
    runtime:on_save_ready(behind, behind_data)
    local far = make_player(4, 6, 5.01, 80)
    runtime:on_player_added(far)
    runtime:on_save_ready(far, make_data(far, nil))
    act(player, { action = "breath" })
    assert.is_false(player.last_result.ok)
    assert.equals("cooldown", player.last_result.reason)

    select_item(player, "carp")
    runtime.clock:advance(breath.CooldownSec)
    act(player, { action = "breath" })
    assert.equals("not-godzilla", player.last_result.reason)
    assert.equals(GameCfg.Vitals.MaxHealth, behind.Character.Controller.Health)
    assert.equals(GameCfg.Vitals.MaxHealth, far.Character.Controller.Health)
  end)

  -- #365 失败方式：角色旋转读取失败若回退 (0,0,1)，哥斯拉吐息会朝 +Z 造成伤害并误进冷却。
  it("哥斯拉吐息在旋转读取失败时拒绝触发、不朝 +Z 结算伤害也不进冷却", function()
    boot("item170")
    local target_z = make_player(3, 6, 5.01, 55)
    runtime:on_player_added(target_z)
    runtime:on_save_ready(target_z, make_data(target_z, nil))
    local carrier = { dead = false, body = { Position = vec(6, 5.01, 55) }, Damage = 0, hits = 0 }
    runtime:get_player_tree(player.UserId).fish_units = { { Id = "f1", carrier = carrier } }

    local logs, raw_print = {}, print
    local ok_run, err = pcall(function()
      _G.print = function(...)
        local parts = {}
        for i = 1, select("#", ...) do parts[i] = tostring(select(i, ...)) end
        logs[#logs + 1] = table.concat(parts, "\t")
      end
      local orig_char = player.Character
      local orig_rot = orig_char.Rotation
      local cases = {
        function() orig_char.Rotation = nil end,
        function()
          orig_char.Rotation = { GetForward = function() error("rot-denied") end }
        end,
        function()
          orig_char.Rotation = { GetForward = function() return { x = 0, y = 1, z = 0 } end }
        end,
        function()
          orig_char.Rotation = { GetForward = function() return { x = 0 / 0, y = 0, z = 1 } end }
        end,
        function()
          player.Character = setmetatable({ Position = orig_char.Position, Controller = orig_char.Controller }, {
            __index = function(_, key)
              if key == "Rotation" then error("rotation-prop-denied") end
            end,
          })
          runtime:get_player_tree(player.UserId).states.character:set(player.Character)
        end,
      }
      for _, corrupt in ipairs(cases) do
        player.Character = orig_char
        orig_char.Rotation = orig_rot
        runtime:get_player_tree(player.UserId).states.character:set(orig_char)
        local before_logs = #logs
        corrupt()
        act(player, { action = "breath" })
        assert.is_false(player.last_result.ok)
        assert.equals("no-forward", player.last_result.reason)
        runtime.clock:step(3)
        assert.equals(GameCfg.Vitals.MaxHealth, target_z.Character.Controller.Health)
        assert.equals(0, carrier.Damage)
        local state = last_state(events, player)
        assert.equals(0, state and state.breathRemaining or 0)
        local logged = false
        for i = before_logs + 1, #logs do
          if logs[i]:find("[SpecialItemPhase]", 1, true) then logged = true break end
        end
        assert.is_true(logged)
      end
      -- 恢复正常旋转后立刻可成功吐息（说明未误扣冷却）
      player.Character = orig_char
      orig_char.Rotation = orig_rot
      runtime:get_player_tree(player.UserId).states.character:set(orig_char)
      act(player, { action = "breath" })
      assert.is_true(player.last_result.ok)
    end)
    _G.print = raw_print
    if not ok_run then error(err, 0) end
  end)

  it("麻痹只拒绝起飞和吐息，不解除翅膀或哥斯拉", function()
    boot("item169")
    local tree = runtime:get_player_tree(player.UserId)
    assert.is_true(tree:apply_modifier("paralyze", { duration = 0.5 }))
    act(player, { action = "fly", holding = true })
    runtime.clock:step(0.2)
    assert.is_true(player.Character.Controller.GravityEnabled)
    assert.equals(5.01, player.Character.Position.y)
    assert.equals("wings", last_state(events, player).effect)
    assert.is_true(has_call(player.Character, "bind"))
    assert.is_false(has_call(player.Character, "unbind"))

    select_item(player, "item170")
    assert.equals("godzilla", last_state(events, player).effect)
    act(player, { action = "breath" })
    assert.is_false(player.last_result.ok)
    assert.is_false(has_call(player.Character, "resetSkin"))
    runtime.clock:advance(1)
    assert.is_true(tree.memos.can_act:now())
    assert.equals("godzilla", last_state(events, player).effect)
    act(player, { action = "breath" })
    assert.is_true(player.last_result.ok)
  end)

  it("濒死、死亡与离场对称回收外观和重力，复活后不残留翅膀", function()
    boot("item169")
    act(player, { action = "fly", holding = true })
    runtime.clock:step(1)
    assert.is_false(player.Character.Controller.GravityEnabled)
    local tree = runtime:get_player_tree(player.UserId)
    assert.is_true(tree:apply_hit(tree:new_hit(other, "fishAttack"), player, 9999))
    assert.equals("downed", tree.states.life_phase:now())
    assert.is_true(player.Character.Controller.GravityEnabled)
    assert.is_true(has_call(player.Character, "unbind"))
    assert.is_nil(last_state(events, player).effect)

    runtime.clock:advance(15)
    assert.equals("dead", tree.states.life_phase:now())
    runtime.clock:advance(30)
    assert.equals("alive", tree.states.life_phase:now())
    assert.is_true(has_call(player.Character, "bind"))
    assert.is_true(player.Character.Controller.GravityEnabled)

    act(player, { action = "fly", holding = true })
    runtime.clock:step(0.4)
    runtime:on_player_removing(player)
    assert.is_true(player.Character.Controller.GravityEnabled)
    assert.is_nil(runtime:get_player_tree(player.UserId))
  end)

  it("离场终镜像写下吐息剩余冷却，重登后续上且不复活滞空", function()
    boot("item170")
    act(player, { action = "breath" })
    assert.is_true(player.last_result.ok)
    runtime.clock:advance(2)
    runtime:on_player_removing(player)
    local remaining = data.extra.cooldowns.godzillaBreath
    assert.near(18, remaining, 0.05)
    assert.is_true(has_call(player.Character, "resetSkin"))
    assert.is_true(player.Character.Controller.GravityEnabled)

    local rejoined = make_player(1, 6, 5.01, 40)
    local next_data = make_data(rejoined, "item170")
    next_data.extra.cooldowns.godzillaBreath = remaining
    data = next_data
    runtime:on_player_added(rejoined)
    runtime:on_save_ready(rejoined, next_data)
    runtime.clock:advance(6)
    act(rejoined, { action = "breath" })
    assert.is_false(rejoined.last_result.ok)
    assert.equals("cooldown", rejoined.last_result.reason)
    assert.equals("godzilla", last_state(events, rejoined).effect)
    assert.is_true(rejoined.Character.Controller.GravityEnabled)
    assert.near(12, last_state(events, rejoined).breathRemaining, 0.6)
  end)

  it("切槽和濒死不清空吐息冷却，松开飞行不受限频影响", function()
    boot("item170")
    act(player, { action = "breath" })
    local cast_remaining = data.extra.cooldowns.godzillaBreath
    select_item(player, "item169")
    local tree = runtime:get_player_tree(player.UserId)
    assert.is_true(tree:apply_hit(tree:new_hit(other, "fishAttack"), player, 9999))
    assert.near(cast_remaining, data.extra.cooldowns.godzillaBreath, 0.05)

    runtime.clock:advance(46)
    assert.equals("alive", tree.states.life_phase:now())
    re.check_recd = function() return true end
    act(player, { action = "fly", holding = true })
    act(player, { action = "fly", holding = false })
    runtime.clock:step(0.5)
    assert.is_true(player.Character.Controller.GravityEnabled)
    assert.near(5.01, player.Character.Position.y, 0.05)
  end)

  it("未登记玩家不能经请求创建会话，摆渡传送结束滞空并按新区重挂外观", function()
    boot("item169")
    local stranger = make_player(9, 6, 5.01, 40)
    act(stranger, { action = "fly", holding = true })
    runtime.clock:step(0.3)
    assert.equals(5.01, stranger.Character.Position.y)
    assert.is_nil(stranger.last_result)

    act(player, { action = "fly", holding = true })
    runtime.clock:step(1)
    assert.is_false(player.Character.Controller.GravityEnabled)
    data.data.Zone = "coralCoast"
    runtime:get_player_tree(player.UserId):sync_from_data(data)
    assert.is_true(player.Character.Controller.GravityEnabled)
    assert.is_true(has_call(player.Character, "unbind"))
    assert.is_nil(last_state(events, player).effect)
    select_item(player, nil)
    select_item(player, "item169")
    local binds = 0
    for _, call in ipairs(player.Character.Calls) do
      if call[1] == "bind" then binds = binds + 1 end
    end
    assert.is_true(binds >= 2)
    assert.equals("wings", last_state(events, player).effect)
    assert.is_true(player.Character.Controller.GravityEnabled)
  end)

  it("外观创建失败时不报告已生效，随后重试成功且失败挂点不残留", function()
    GameCfg.Ability.SpecialItem.Wings.AppearanceAssetId = nil
    GameCfg.Ability.SpecialItem.Godzilla.AppearanceAssetId = nil
    fail_model = true
    boot("item169")
    assert.is_nil(last_state(events, player) and last_state(events, player).effect)
    assert.is_true(created[1] == nil or created[1].Destroyed == true)
    fail_model = false
    runtime.clock:advance(1.1)
    local alive_units = 0
    for _, unit in ipairs(created) do
      if not unit.Destroyed then alive_units = alive_units + 1 end
    end
    assert.equals(2, alive_units)
    assert.equals("wings", last_state(events, player).effect)
    select_item(player, nil)
    for _, unit in ipairs(created) do
      assert.is_true(unit.Destroyed)
    end
  end)
end)
