-- L3 统一引擎对象读写适配器 common.engine_read 单元测试与业务侧反向回归测试（#366）。
-- 失败方式（先列后写）：
--   1. 入参为空/字段缺失/已销毁/宿主抛错四条路径返回的 reason 混同或缺失；
--   2. read_error / write_error 静默吞错不产生带上下文的日志；
--   3. 已销毁单位在 GroundLoot / CastSourceView 清理阶段因 pcall 外裸读 Destroyed/Destroy 抛未捕获异常；
--   4. PlayerLife 在控制器/健康值/回调状态未确认时静默继续结算扣血、切濒死或写入权威状态；
--   5. PlayerTree.sync_from_data 在读取玩家 Character 失败时静默保留陈旧角色引用；
--   6. PlayerWeapon 在 Vector3 缺失时退回普通 Lua table 冒充引擎向量。

local EngineRead = require("common.engine_read")
local GameCfg = require("common.game_cfg")
local Spoke = require("common.packages.spoke.api")
local SpokeClock = require("common.spoke_clock")
local EngineDouble = require("tests.support.engine_double")
local Eui = require("tests.support.eui_double")
local ClientStore = require("client.store.client_store")
local RootView = require("client.views.root_view")
local CastSourceView = require("client.views.cast_source_view")
local GroundLoot = require("server.world_host.ground_loot")
local PlayerTree = require("server.world_host.player_tree")
local ServerRuntime = require("server.world_host.server_runtime")
local PlayerWeapon = require("server.world_host.player_weapon")

local function capture_prints(fn)
  local logs = {}
  local raw_print = _G.print
  _G.print = function(...)
    local parts = {}
    for i = 1, select("#", ...) do
      parts[i] = tostring((select(i, ...)))
    end
    logs[#logs + 1] = table.concat(parts, " ")
  end
  local ok, err = pcall(fn)
  _G.print = raw_print
  if not ok then
    error(err, 0)
  end
  return logs
end

local function has_log(logs, needle)
  for _, line in ipairs(logs) do
    if line:find(needle, 1, true) then
      return true
    end
  end
  return false
end

local function make_signal()
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
      for _, h in ipairs({ table.unpack(handlers) }) do h(...) end
    end,
  }
end

describe("common.engine_read 引擎对象读取适配器（#366）", function()
  local saved_game, saved_v3

  before_each(function()
    saved_game = rawget(_G, "game")
    saved_v3 = rawget(_G, "Vector3")
  end)

  after_each(function()
    _G.game = saved_game
    _G.Vector3 = saved_v3
  end)

  it("运行时自定义类型：Player、Players 与 EggyUnit 仍可按公共接口读取和调用（#392）", function()
    local native_type = type
    local character = { Controller = { Health = 100 } }
    local player = { UserId = "runtime-player", Character = character }
    local players = { GetPlayers = function() return { player } end }
    local engine_game = { GetService = function(_, name) return name == "Players" and players or nil end }
    local engine_types = {
      [player] = "Player", [players] = "Players", [character] = "EggyUnit", [engine_game] = "Game",
    }
    local env = setmetatable({
      game = engine_game,
      type = function(value) return engine_types[value] or native_type(value) end,
    }, { __index = _G })
    -- 原语层已拆到 common.engine_read_core（#414）：注入的运行时 type 必须同时进入两层，
    -- 否则 #392 的沙盒覆盖会在拆分后静默失效。
    env.require = function(name)
      if name == "common.engine_read_core" then
        return assert(loadfile("common/engine_read_core.lua", "t", env))()
      end
      return require(name)
    end
    local runtime_read = assert(loadfile("common/engine_read.lua", "t", env))()

    assert.is_true(runtime_read.is_object(player))
    assert.is_true(runtime_read.is_object(players))
    assert.is_true(runtime_read.is_valid_player(player))

    local ok_uid, uid, reason_uid = runtime_read.read_user_id(player)
    assert.is_true(ok_uid)
    assert.equals("runtime-player", uid)
    assert.is_nil(reason_uid)

    local ok_players, result, reason_players = runtime_read.call_method(players, "GetPlayers")
    assert.is_true(ok_players)
    assert.same({ player }, result)
    assert.is_nil(reason_players)

    local ok_character, result_character, reason_character = runtime_read.read_character(player)
    assert.is_true(ok_character)
    assert.equals(character, result_character)
    assert.is_nil(reason_character)

    local ok_service, service, reason_service = runtime_read.get_service("Players")
    assert.is_true(ok_service)
    assert.equals(players, service)
    assert.is_nil(reason_service)

    for _, scalar in ipairs({ false, 0, "Player" }) do
      assert.is_false(runtime_read.is_object(scalar))
    end
    assert.is_false(runtime_read.is_object(nil))
    -- 搬出的原语层必须跑在注入的运行时 type 下：自定义类型名同样按宿主对象处理。
    -- 若主文件接到的是全局 type 下的旧实例，read_user_id 会退化为 missing 而不是 read_error。
    local runtime_unit = function() end
    engine_types[runtime_unit] = "EggyUnit"
    local unit_logs = capture_prints(function()
      local ok_unit, value_unit, reason_unit = runtime_read.read_user_id(runtime_unit)
      assert.is_false(ok_unit)
      assert.is_nil(value_unit)
      assert.equals("read_error", reason_unit)
    end)
    assert.is_true(has_log(unit_logs, "operation=read_user_id reason=read_error"))
  end)

  it("正常读取路径：覆盖字段/玩家/角色/控制器/血量/向量/属性/服务与销毁操作", function()
    local attrs = { SurvivalPhase = "alive" }
    local destroyed = false
    local disconnected = false
    local controller = { Health = 240, WalkSpeed = 16 }
    local unit = EngineDouble.Unit({
      Name = "ProbeUnit",
      Position = { x = 10, y = 2, z = -4 },
    })
    local player = {
      UserId = 101,
      Character = {
        Controller = controller,
        Position = EngineDouble.vector(10, 2, -4),
      },
      GetAttribute = function(_, k) return attrs[k] end,
      SetAttribute = function(_, k, v) attrs[k] = v end,
    }
    local world_svc = { GetServerTime = function() return 42 end }
    _G.game = {
      GetService = function(_, name)
        if name == "World" then return world_svc end
        return nil
      end,
    }

    local ok_uid, uid, reason_uid = EngineRead.read_user_id(player, "spec")
    assert.is_true(ok_uid)
    assert.equals(101, uid)
    assert.is_nil(reason_uid)
    assert.is_true(EngineRead.is_valid_player(player))

    local ok_ch, ch, reason_ch = EngineRead.read_character(player)
    assert.is_true(ok_ch)
    assert.equals(player.Character, ch)
    assert.is_nil(reason_ch)

    local ok_ctrl, ctrl = EngineRead.read_controller(player)
    assert.is_true(ok_ctrl)
    assert.equals(controller, ctrl)

    local ok_h, h = EngineRead.read_health(player)
    assert.is_true(ok_h)
    assert.equals(240, h)

    local ok_wh, wh = EngineRead.write_health(player, 180)
    assert.is_true(ok_wh)
    assert.equals(180, wh)
    assert.equals(180, controller.Health)

    local ok_pos, pos = EngineRead.read_position(unit)
    assert.is_true(ok_pos)
    assert.same({ x = 10, y = 2, z = -4 }, pos)

    local ok_ppos, ppos = EngineRead.read_player_position(player)
    assert.is_true(ok_ppos)
    assert.same({ x = 10, y = 2, z = -4 }, ppos)

    local ok_v2, v2 = EngineRead.read_vec2({ x = 3, y = 4 })
    assert.is_true(ok_v2)
    assert.same({ x = 3, y = 4 }, v2)

    local ok_attr, attr_val = EngineRead.read_attribute(player, "SurvivalPhase")
    assert.is_true(ok_attr)
    assert.equals("alive", attr_val)

    local ok_wattr = EngineRead.write_attribute(player, "SurvivalPhase", "downed")
    assert.is_true(ok_wattr)
    assert.equals("downed", attrs.SurvivalPhase)

    local ok_svc, svc = EngineRead.get_service("World")
    assert.is_true(ok_svc)
    assert.equals(world_svc, svc)

    local ok_call, time_val = EngineRead.call_method(svc, "GetServerTime")
    assert.is_true(ok_call)
    assert.equals(42, time_val)

    local ok_v3, v3 = EngineRead.new_vector3(1, 2, 3)
    assert.is_true(ok_v3)
    assert.equals(1, v3.x)

    local target_unit = { Destroy = function() destroyed = true end }
    local ok_d, d_res = EngineRead.destroy_unit(target_unit)
    assert.is_true(ok_d)
    assert.is_true(d_res)
    assert.is_true(destroyed)

    local conn = { Disconnect = function() disconnected = true end }
    local ok_dc = EngineRead.disconnect(conn)
    assert.is_true(ok_dc)
    assert.is_true(disconnected)
  end)

  it("missing 路径：入参为空、非对象或目标字段/构造器缺失时返回 reason='missing' 且不误报异常日志", function()
    local logs = capture_prints(function()
      local ok1, v1, r1 = EngineRead.read_user_id(nil)
      assert.is_false(ok1); assert.is_nil(v1); assert.equals("missing", r1)

      local ok2, v2, r2 = EngineRead.read_character({ UserId = 1 })
      assert.is_false(ok2); assert.is_nil(v2); assert.equals("missing", r2)

      local ok3, v3, r3 = EngineRead.read_controller({ UserId = 1, Character = {} })
      assert.is_false(ok3); assert.is_nil(v3); assert.equals("missing", r3)

      local ok4, v4, r4 = EngineRead.read_vec3({ x = 1, y = 2 })
      assert.is_false(ok4); assert.is_nil(v4); assert.equals("missing", r4)

      local ok5, v5, r5 = EngineRead.read_attribute({ GetAttribute = function() return nil end }, "MissingAttr")
      assert.is_false(ok5); assert.is_nil(v5); assert.equals("missing", r5)

      local ok6, v6, r6 = EngineRead.destroy_unit({})
      assert.is_false(ok6); assert.is_nil(v6); assert.equals("missing", r6)
    end)
    assert.equals(0, #logs)

    _G.Vector3 = nil
    local vec_logs = capture_prints(function()
      local ok, val, reason = EngineRead.new_vector3(1, 2, 3, "test_missing_v3")
      assert.is_false(ok)
      assert.is_nil(val)
      assert.equals("missing", reason)
    end)
    assert.is_true(has_log(vec_logs, "test_missing_v3"))
  end)

  it("destroyed 路径：Destroyed=true 或抛销毁异常时返回 reason='destroyed'，且不抛未捕获异常", function()
    local flagged_unit = { Destroyed = true, Position = { x = 1, y = 2, z = 3 }, Destroy = function() error("should-not-call") end }
    local logs = capture_prints(function()
      local ok1, v1, r1 = EngineRead.read_position(flagged_unit, "ctx_flagged")
      assert.is_false(ok1); assert.is_nil(v1); assert.equals("destroyed", r1)

      local ok2, v2, r2 = EngineRead.destroy_unit(flagged_unit, "ctx_flagged_destroy")
      assert.is_false(ok2); assert.is_nil(v2); assert.equals("destroyed", r2)

      local ok_flag, is_d = EngineRead.is_destroyed(flagged_unit)
      assert.is_true(ok_flag); assert.is_true(is_d)

      local destroyed_userdata = setmetatable({}, {
        __index = function()
          error("attempt to index a destroyed userdata")
        end,
      })
      local ok3, v3, r3 = EngineRead.read_field(destroyed_userdata, "Position", "ctx_ud")
      assert.is_false(ok3); assert.is_nil(v3); assert.equals("destroyed", r3)

      local ok4, v4, r4 = EngineRead.destroy_unit(destroyed_userdata, "ctx_ud_destroy")
      assert.is_false(ok4); assert.is_nil(v4); assert.equals("destroyed", r4)
    end)
    assert.equals(0, #logs)
  end)

  it("read_error / write_error 路径：宿主访问抛非销毁异常或非有限数值时返回对应 reason 并产出带上下文日志", function()
    local error_obj = setmetatable({}, {
      __index = function() error("host index boom") end,
      __newindex = function() error("host write denied") end,
    })
    local logger_msgs = {}
    local ctx = {
      context = "SpecContext",
      logger = { error = function(_, msg) logger_msgs[#logger_msgs + 1] = msg end },
    }

    local logs = capture_prints(function()
      local ok1, v1, r1 = EngineRead.read_field(error_obj, "Character", "ReadErrorCtx")
      assert.is_false(ok1); assert.is_nil(v1); assert.equals("read_error", r1)

      local ok2, v2, r2 = EngineRead.write_field(error_obj, "Health", 50, ctx)
      assert.is_false(ok2); assert.is_nil(v2); assert.equals("write_error", r2)

      local ok3, v3, r3 = EngineRead.read_vec3({ x = 0 / 0, y = 1, z = 2 }, "NanVecCtx")
      assert.is_false(ok3); assert.is_nil(v3); assert.equals("read_error", r3)

      local ok4, v4, r4 = EngineRead.read_health({
        UserId = 7,
        Character = { Controller = { Health = math.huge } },
      }, "InfHealthCtx")
      assert.is_false(ok4); assert.is_nil(v4); assert.equals("read_error", r4)
    end)

    assert.is_true(has_log(logs, "reason=read_error"))
    assert.is_true(has_log(logs, "context=ReadErrorCtx"))
    assert.is_true(has_log(logs, "host index boom"))
    assert.is_true(has_log(logs, "context=NanVecCtx"))
    assert.is_true(has_log(logs, "context=InfHealthCtx"))

    assert.equals(1, #logger_msgs)
    assert.is_true(logger_msgs[1]:find("reason=write_error", 1, true) ~= nil)
    assert.is_true(logger_msgs[1]:find("context=SpecContext", 1, true) ~= nil)
    assert.is_true(logger_msgs[1]:find("host write denied", 1, true) ~= nil)
  end)
end)

describe("业务侧反向回归测试（#366）", function()
  local saved_v3, saved_color

  before_each(function()
    saved_v3 = rawget(_G, "Vector3")
    saved_color = rawget(_G, "Color")
  end)

  after_each(function()
    _G.Vector3 = saved_v3
    _G.Color = saved_color
  end)

  it("GroundLoot 清理阶段遇到已销毁或销毁后访问即报错的单位不抛未捕获异常", function()
    local clock = SpokeClock.new(100)
    local root = Spoke.SpokeTree.spawn(Spoke.Effect.new("TestGroundLootCleanup", function(scope)
      local zone_dock = scope:dock("LootZone")
      local world = {
        clock = clock,
        zones = { fishPond = { id = "fishPond", ground_loot = zone_dock } },
        zone_list = { { id = "fishPond" } },
        is_disposed = function() return false end,
      }
      local poisoned_unit = setmetatable({}, {
        __index = function()
          error("attempt to index destroyed userdata")
        end,
      })
      local flagged_unit = {
        Destroyed = true,
        Destroy = function() error("must-not-destroy-twice") end,
      }
      local idx = 0
      GroundLoot.mount(world, {
        scope = scope,
        bait_spots = { Enabled = false },
        create_unit = function()
          idx = idx + 1
          return idx == 1 and poisoned_unit or flagged_unit
        end,
      })
      assert.is_true(world:place_ground_item("fishPond", { itemId = "tilapia", x = 1, y = 0, z = 1 }))
      assert.is_true(world:place_ground_item("fishPond", { itemId = "tilapia", x = 2, y = 0, z = 1 }))
    end))
    assert.has_no.errors(function()
      root:dispose()
    end)
  end)

  it("CastSourceView 清理阶段遇到已销毁或销毁态读取报错的单位不抛未捕获异常", function()
    _G.Vector3 = { New = function(x, y, z) return { x = x, y = y, z = z } end }
    _G.Color = { New = function(r, g, b, a) return { r = r, g = g, b = b, a = a } end }
    local clock = SpokeClock.new(0)
    local store, writer = ClientStore.new({ clock = clock })
    local root = Eui.node({ Name = "UIRoot" })
    local created_units = {}
    local view = RootView.mount(root, store, {
      services = {
        create_unit = function(kind, props)
          local u = Eui.node({ Name = props.Name, Kind = kind, Position = props.Position })
          created_units[#created_units + 1] = u
          return u
        end,
        reel = { active = function() return true end, progress = function() return 75 end },
      },
      hud = { CastSourceView.spec() },
      create_node = function(kind, props) return Eui.node({ Kind = kind, Name = props.Name, Parent = props.Parent }) end,
    })
    writer:ingest_event("CastState", {
      phase = "hooked", castId = 51, fishId = "item81", reelSession = "s51",
      hookPosition = { x = 880, y = 15, z = 144 },
    })
    assert.equals(2, #created_units)
    -- 模拟单位已被引擎先一步销毁，再次访问 Destroy 键即抛销毁异常
    setmetatable(created_units[1], {
      __index = function() error("attempt to index destroyed unit") end,
    })
    created_units[2].Destroyed = true
    assert.has_no.errors(function()
      writer:ingest_event("CastState", { phase = "unhooked", castId = 51 })
      view:dispose()
    end)
  end)

  it("PlayerLife 在控制器缺失、读取抛错或回调状态未确认时中止结算，不静默兜底扣血或切状态", function()
    local events = {}
    local re = {
      get_re = function(_, name)
        events[name] = events[name] or {
          clients = {},
          OnServerEvent = make_signal(),
          FireClient = function(self, target, payload)
            self.clients[#self.clients + 1] = { player = target, value = payload }
          end,
          FireAllClients = function(self, payload)
            self.clients[#self.clients + 1] = { player = "all", value = payload }
          end,
        }
        return events[name]
      end,
      check_recd = function() return false end,
    }
    local controller = {
      Health = 100,
      MaxHealth = 300,
      WalkSpeed = 16,
      HealthChanged = make_signal(),
      Died = make_signal(),
      TakeDamage = function(self, amount)
        self.Health = math.max(0, self.Health - amount)
      end,
    }
    local player = {
      UserId = 801,
      Name = "p801",
      attrs = {},
      CharacterAdded = make_signal(),
      CharacterRemoving = make_signal(),
      Character = { Controller = controller, Position = { x = 0, y = 0, z = 0 } },
      SetAttribute = function(self, k, v) self.attrs[k] = v end,
      GetAttribute = function(self, k) return self.attrs[k] end,
    }
    local data = {
      Player = player,
      inited = true,
      load_state = "ready",
      data = { FishCoin = 0, Zone = "fishPond", containers = { {}, {} } },
      extra = { growth = { potions = {}, upgrades = {} }, survival = { health = 100, hunger = 100 } },
    }
    local fail_data = false
    local fail_max_hp = false
    local runtime = ServerRuntime.new({
      damage_filter = function() return true end,
      bait_spots = { Enabled = false },
      initial_now = 10,
      remote = re,
      player_data = {
        get_data_inst = function(_, target)
          if fail_data then error("host data unavailable") end
          return target == player and data or nil
        end,
      },
      max_health_of = function()
        if fail_max_hp then error("host max health unavailable") end
        return 300
      end,
    })
    runtime:start()
    runtime:mark_started()
    runtime:on_player_added(player)
    runtime:on_save_ready(player, data)

    local tree = runtime:get_player_tree(player.UserId)
    assert.is_not_nil(tree)

    -- 1. Controller 缺失时 apply_damage 不再用 states.health 兜底扣血，也不进入 downed
    local saved_ctrl = player.Character.Controller
    player.Character.Controller = nil
    local ok_missing = tree:apply_hit(tree:new_hit(nil, "fishAttack"), player, 999)
    assert.is_false(ok_missing)
    assert.equals("alive", tree.states.life_phase:now())
    assert.equals(100, tree.states.health:now())
    assert.equals(0, #(events.DamageNotice and events.DamageNotice.clients or {}))

    -- 2. Controller.Health 读取抛错时中止结算并产出日志
    player.Character.Controller = setmetatable({}, {
      __index = function(_, key)
        if key == "Health" then error("controller read boom") end
        return saved_ctrl[key]
      end,
    })
    local logs = capture_prints(function()
      local ok_err = tree:apply_hit(tree:new_hit(nil, "fishAttack"), player, 20)
      assert.is_false(ok_err)
    end)
    assert.is_true(has_log(logs, "reason=read_error"))
    assert.equals("alive", tree.states.life_phase:now())
    assert.equals(100, tree.states.health:now())

    -- 3. max_health_of 宿主抛错时 eat 中止，不按默认上限结算
    player.Character.Controller = saved_ctrl
    fail_max_hp = true
    local mh_logs = capture_prints(function()
      assert.is_false(tree:eat("goldfish"))
    end)
    assert.is_true(has_log(mh_logs, "operation=max_health"))
    assert.equals(100, saved_ctrl.Health)

    -- 4. current_data 宿主抛错时 UseAdrenaline 明确失败（unavailable），不回退陈旧数据
    fail_max_hp = false
    assert.is_true(tree:apply_hit(tree:new_hit(nil, "fishAttack"), player, 999))
    assert.equals("downed", tree.states.life_phase:now())
    fail_data = true
    local cd_logs = capture_prints(function()
      assert.is_true(tree:handle_survival_action({ action = "UseAdrenaline", seq = 1 }, true))
    end)
    assert.is_true(has_log(cd_logs, "operation=current_data"))
    local last_res = events.SurvivalResult.clients[#events.SurvivalResult.clients]
    assert.is_false(last_res.value.ok)
    assert.equals("unavailable", last_res.value.reason)

    runtime:shutdown()
  end)

  it("PlayerTree.sync_from_data 在 Character 缺失、销毁或读取抛错时清除陈旧角色引用", function()
    local clock = SpokeClock.new(100)
    local char1 = { Position = { x = 1, y = 2, z = 3 } }
    local read_fail = false
    local current_char = char1
    local player = setmetatable({
      UserId = 9201,
      CharacterAdded = make_signal(),
      CharacterRemoving = make_signal(),
      SetAttribute = function() end,
    }, {
      __index = function(_, key)
        if key == "Character" then
          if read_fail then error("character read failed") end
          return current_char
        end
      end,
    })
    local data = {
      Player = player,
      inited = true,
      load_state = "ready",
      data = { FishCoin = 0, Zone = "fishPond", containers = { {}, {} } },
      extra = { growth = { potions = {}, upgrades = {} }, survival = {} },
    }
    local pt = PlayerTree.spawn({ player = player, data = data, clock = clock })
    assert.equals(char1, pt.states.character:now())

    -- 情况 1：读取 Character 抛错时必须清除陈旧引用，不能保留 char1
    read_fail = true
    local logs = capture_prints(function()
      assert.is_true(pt:sync_from_data(data))
    end)
    assert.is_true(has_log(logs, "PlayerTree.sync_from_data"))
    assert.is_nil(pt.states.character:now())

    -- 恢复后同步回新角色，再测试 Destroyed = true 时同样不保留陈旧引用
    read_fail = false
    local char2 = { Position = { x = 2, y = 2, z = 3 } }
    current_char = char2
    assert.is_true(pt:sync_from_data(data))
    assert.equals(char2, pt.states.character:now())

    char2.Destroyed = true
    assert.is_true(pt:sync_from_data(data))
    assert.is_nil(pt.states.character:now())

    -- 角色恢复正常后再变 nil（missing）时也不保留陈旧引用
    local char3 = { Position = { x = 3, y = 2, z = 3 } }
    current_char = char3
    assert.is_true(pt:sync_from_data(data))
    assert.equals(char3, pt.states.character:now())

    current_char = nil
    assert.is_true(pt:sync_from_data(data))
    assert.is_nil(pt.states.character:now())

    pt:dispose()
  end)

  it("PlayerWeapon 在 Vector3 缺失时不退回普通 table 冒充引擎向量", function()
    local clock = SpokeClock.new(100)
    local ray_called = false
    local visual_created = false
    local player = {
      UserId = 9301,
      Character = {
        Position = { x = 0, y = 2, z = 0 },
        Rotation = { GetForward = function() return { x = 0, y = 0, z = 1 } end },
      },
    }
    local gun_id = "item137"
    local throw_id = "item143"
    local tree = {
      player = player,
      clock = clock,
      data = {
        data = {
          containers = {
            [GameCfg.Items.ContainerId.ItemBar] = {
              [1] = { itemId = throw_id, count = 1 },
            },
          },
        },
      },
      states = {
        held = Spoke.State.new("test.held", { kind = "weapon", id = gun_id }),
        selected_weapon = Spoke.State.new("test.sel", gun_id),
        weapons = Spoke.State.new("test.weapons", { [gun_id] = 1 }),
      },
      memos = {
        can_act = Spoke.State.new("test.can_act", true),
        weapon_damage_scales = Spoke.State.new("test.scales", { melee = 1, ranged = 1, explosive = 1 }),
      },
      get_item_bar_snapshot = function()
        return {
          selectedSlot = 1,
          slots = { [1] = { itemId = throw_id, count = 1 } },
        }
      end,
    }
    local weapon_handle
    local root = Spoke.SpokeTree.spawn(Spoke.Effect.new("TestWeaponVec", function(scope)
      weapon_handle = PlayerWeapon.mount(scope, tree, {
        physics = { Raycast = function() ray_called = true; return nil end },
        world = { CreateUnit = function() visual_created = true; return {} end },
        new_hit = function(src, cat) return { id = 1, source = src, category = cat } end,
        apply_hit = function() return true end,
      })
    end))

    _G.Vector3 = nil
    local logs = capture_prints(function()
      assert.is_true(weapon_handle:handle({ action = "attack", aim = { x = 0, y = 0, z = 1 } }))
      assert.is_true(weapon_handle:handle({ action = "throw", slot = 1, target = { x = 1, y = 0, z = 2 } }))
    end)

    assert.is_false(ray_called)
    assert.is_false(visual_created)
    assert.is_true(has_log(logs, "Vector3.New unavailable"))

    root:dispose()
  end)
end)
