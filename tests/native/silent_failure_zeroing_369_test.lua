-- Issue #369 反向单测：清零业务静默失败，验证错误日志、失败回传与推送重试保护。
-- 失败方式清单：
--   1. ServerRuntime:_publish_fish 发送/取通道失败提前推进签名 → 后续帧不再重试，客户端永久丢状态；
--   2. FishTree:damage_fish 底层血量/状态写入失败仍返回 true → 上游误判扣血成功；
--   3. PlayerLife 移速写入、growth/speed writer、fire_client、publish_notice 静默吞错 → 故障不可观测；
--   4. FerryRoute 的 event / online_players / data_of 把故障伪装成空结果 → 误判空船或静默吞退票；
--   5. PlayerWeapon / PlayerGrill / PlayerBlindbox / PlayerLottery / PlayerPlatformShop 失败静默；
--   6. server/main.lua / client/main.lua 存在无日志裸 pcall(... SetCoreGuiEnabled ...)。

local GameCfg = require("common.game_cfg")
local ServerRuntime = require("server.world_host.server_runtime")
local Spoke = require("common.packages.spoke.api")
local SpokeClock = require("common.spoke_clock")
local SharedWorldTree = require("server.world_host.shared_world_tree")
local FerryRoute = require("server.world_host.ferry_route")
local PlayerWeapon = require("server.world_host.player_weapon")
local PlayerGrill = require("server.world_host.player_grill")
local PlayerBlindbox = require("server.world_host.player_blindbox")
local PlayerLottery = require("server.world_host.player_lottery")
local PlayerPlatformShop = require("server.world_host.player_platform_shop")
local fs = require("tests.support.fs_fixture")

local function signal()
  local handlers = {}
  return {
    Connect = function(_, fn)
      handlers[#handlers + 1] = fn
      return { Disconnect = function() end }
    end,
    Fire = function(_, ...)
      for _, fn in ipairs({ table.unpack(handlers) }) do fn(...) end
    end,
  }
end

local function capture_prints(fn)
  local logs = {}
  local real_print = _G.print
  _G.print = function(...)
    local parts = {}
    for i = 1, select("#", ...) do
      parts[i] = tostring(select(i, ...))
    end
    logs[#logs + 1] = table.concat(parts, " ")
  end
  local ok, r1, r2, r3 = pcall(fn)
  _G.print = real_print
  if not ok then error(r1, 0) end
  return logs, r1, r2, r3
end

local function has_log(logs, ...)
  local needles = { ... }
  for _, line in ipairs(logs) do
    local matched = true
    for _, needle in ipairs(needles) do
      if not line:find(needle, 1, true) then
        matched = false
        break
      end
    end
    if matched then return true end
  end
  return false
end

local function make_player(id, x, z)
  local controller = {
    Health = GameCfg.Vitals.MaxHealth,
    MaxHealth = GameCfg.Vitals.MaxHealth,
    WalkSpeed = 16,
    HealthChanged = signal(),
    Died = signal(),
  }
  function controller:TakeDamage(amount)
    self.Health = math.max(0, self.Health - amount)
    self.HealthChanged:Fire(self.Health)
    if self.Health <= 0 then self.Died:Fire() end
  end
  local player = {
    UserId = id,
    Name = "p" .. tostring(id),
    attrs = {},
    CharacterAdded = signal(),
    CharacterRemoving = signal(),
    SetAttribute = function(self, key, value) self.attrs[key] = value end,
    GetAttribute = function(self, key) return self.attrs[key] end,
    Character = {
      Controller = controller,
      Position = { x = x or 10, y = 2, z = z or -20 },
      Size = { y = 2 },
      Rotation = { GetForward = function() return { x = 0, y = 0, z = 1 } end },
    },
  }
  function controller:Lift(body)
    if body and body.OnLiftedBegin then body.OnLiftedBegin:Fire(player.Character) end
  end
  return player
end

local function make_data(player)
  return {
    Player = player,
    inited = true,
    load_state = "ready",
    data = {
      FishCoin = 100,
      Zone = "fishPond",
      weapons = { item137 = 1 },
      containers = {
        [GameCfg.Items.ContainerId.ItemBar] = {},
        [GameCfg.Items.ContainerId.Backpack] = {},
      },
    },
    extra = {
      growth = { potions = {}, upgrades = {} },
      inventory = { selection = { held = { kind = "weapon", id = "item137" } } },
      survival = { health = GameCfg.Vitals.MaxHealth, hunger = GameCfg.Vitals.MaxHunger },
    },
  }
end

local function ensure_engine()
  if rawget(_G, "Quaternion") == nil then
    _G.Quaternion = { FromEulerAngles = function()
      return { GetForward = function() return { x = 0, y = 0, z = 1 } end }
    end }
  end
  if rawget(_G, "Color") == nil then
    _G.Color = { New = function(r, g, b, a) return { r = r, g = g, b = b, a = a } end }
  end
end

local function make_fish_runtime(overrides)
  ensure_engine()
  local seq = 0
  local options = {
    initial_now = 1000,
    players_service = { GetPlayers = function() return {} end },
    remote = {
      get_re = function()
        return {
          OnServerEvent = signal(),
          FireClient = function() end,
          FireAllClients = function() end,
        }
      end,
      check_recd = function() return false end,
    },
    player_data = { get_data_inst = function() return nil end },
    create_unit = function(_, props)
      seq = seq + 1
      local unit = {
        UnitId = seq,
        Name = props and props.Name,
        Position = props and props.Position or { x = 10, y = 2, z = -18 },
        Rotation = { GetForward = function() return { x = 0, y = 0, z = 1 } end },
        Destroyed = false,
        Destroy = function(self) self.Destroyed = true end,
        AddNoCollisionPairWithUnit = function() end,
        OnLiftedBegin = signal(),
        OnLiftedEnd = signal(),
      }
      if props and props.EnableController then
        unit.Controller = {
          Health = 300,
          MaxHealth = 300,
          HealthChanged = signal(),
          Died = signal(),
        }
      end
      return unit
    end,
  }
  for k, v in pairs(overrides or {}) do options[k] = v end
  local runtime = ServerRuntime.new(options)
  runtime:start()
  runtime:mark_started()
  return runtime
end

describe("业务静默失败清零与推送重试保护（#369）", function()
  it("ServerRuntime:_publish_fish 发送失败时不推进签名并记日志，后续重试成功后推进", function()
    local attempts, sent, err_logs = 0, {}, {}
    local fail_send = true
    local runtime = make_fish_runtime({
      logger = { error = function(_, msg) err_logs[#err_logs + 1] = tostring(msg) end },
      remote = {
        get_re = function(_, name)
          return {
            OnServerEvent = signal(),
            FireClient = function() end,
            FireAllClients = function(_, payload)
              if name == "FishCombatState" then
                attempts = attempts + 1
                if fail_send then error("network-down") end
                sent[#sent + 1] = payload
              end
            end,
          }
        end,
        check_recd = function() return false end,
      },
    })
    local player = make_player(101)
    local data = make_data(player)
    runtime:on_player_added(player)
    runtime:on_save_ready(player, data)

    -- 首次发布失败：receive_landed 内部会调一次 _publish_fish
    assert.is_true(runtime:receive_landed(player, { fishId = "bass", mult = 1, x = 10, y = 2, z = -18 }))
    assert.equals(1, attempts)
    assert.equals(0, #sent)
    assert.is_true(has_log(err_logs, "[ServerRuntime]", "_publish_fish"))

    -- 仍失败时继续重试（证明签名未推进）
    assert.is_false(runtime:_publish_fish())
    assert.equals(2, attempts)
    assert.equals(0, #sent)

    -- 恢复后重试成功并推进签名，再步进不再重复发送
    fail_send = false
    runtime:step(0.1, 1000.1)
    assert.equals(3, attempts)
    assert.equals(1, #sent)
    assert.equals(1, #sent[1].list)

    runtime:step(0.1, 1000.2)
    assert.equals(3, attempts, "重试发送成功后已推进签名，状态不变时不得重复发送")
    runtime:shutdown()
  end)

  it("FishTree:damage_fish 底层控制器血量或载体状态写入失败时返回 false, err 并产出日志", function()
    local err_logs = {}
    local runtime = make_fish_runtime({
      logger = { error = function(_, msg) err_logs[#err_logs + 1] = tostring(msg) end },
    })
    local player = make_player(102)
    local data = make_data(player)
    runtime:on_player_added(player)
    runtime:on_save_ready(player, data)

    local ok_land, fish_id = runtime:receive_landed(player, { fishId = "bass", mult = 1, x = 10, y = 2, z = -18 })
    assert.is_true(ok_land)
    local fish = runtime.fish_host.Fish[fish_id]
    local before_health = fish.carrier.Health

    -- 场景 A：Controller.Health 写入抛错，不得改写 carrier.Health 且返回 false, err
    local locked_ctrl = setmetatable({}, {
      __index = { Health = before_health },
      __newindex = function() error("controller-readonly") end,
    })
    fish.carrier.Controller = locked_ctrl
    local ok_dmg, dmg_err = runtime:damage_fish(fish_id, 50)
    assert.is_false(ok_dmg)
    assert.is_not_nil(dmg_err)
    assert.equals(before_health, fish.carrier.Health, "底层控制器写入失败时不得修改载体血量")
    assert.is_not_nil(runtime.fish_host.Fish[fish_id], "写入失败不得误杀活鱼")
    assert.is_true(has_log(err_logs, "[FishTree]", "damage_fish"))

    -- 场景 B：carrier.Health 写入抛错时回滚 Controller.Health 并返回 false, err
    local ctrl_backing = { Health = before_health }
    local locked_carrier = setmetatable({}, {
      __index = { Health = before_health, Controller = ctrl_backing },
      __newindex = function() error("carrier-readonly") end,
    })
    fish.carrier = locked_carrier
    err_logs = {}
    local ok_c, err_c = runtime.fish_host:damage_fish(fish, 20)
    assert.is_false(ok_c)
    assert.is_not_nil(err_c)
    assert.equals(before_health, ctrl_backing.Health, "载体写入失败时须回滚已写入的控制器血量")
    assert.is_true(has_log(err_logs, "[FishTree]", "damage_fish"))

    runtime:shutdown()
  end)

  it("PlayerLife 移速写入、writer 回调与下行/伤害通知失败均记录日志且返回失败状态", function()
    local player = make_player(103)
    local data = make_data(player)
    local runtime
    local broken_remote = {
      get_re = function(_, name)
        if name == "DamageNotice" then
          return { FireAllClients = function() error("notice-boom") end }
        end
        return {
          OnServerEvent = signal(),
          FireClient = function() error("client-boom") end,
          FireAllClients = function() end,
        }
      end,
      check_recd = function() return false end,
    }
    local speed_fail = false
    local growth_fail = false
    local logs = capture_prints(function()
      runtime = ServerRuntime.new({
        initial_now = 100,
        remote = broken_remote,
        players_service = { GetPlayers = function() return { player } end },
        player_data = { get_data_inst = function(_, p) return p == player and data or nil end },
        damage_filter = function() return true end,
        speed_writer = function()
          if speed_fail then error("speed-writer-boom") end
        end,
        growth_writer = function()
          if growth_fail then return { Ok = false, Error = "growth-denied" } end
        end,
      })
      runtime:start()
      runtime:mark_started()
      runtime:on_player_added(player)
      runtime:on_save_ready(player, data)
    end)

    local tree = runtime:get_player_tree(player.UserId)
    assert.is_not_nil(tree)

    -- 1. WalkSpeed 写入失败
    local real_ctrl = player.Character.Controller
    player.Character.Controller = setmetatable({}, {
      __index = real_ctrl,
      __newindex = function(_, k)
        if k == "WalkSpeed" then error("walkspeed-denied") end
      end,
    })
    local walk_logs, ok_walk, err_walk = capture_prints(function()
      return tree:apply_walk(18)
    end)
    assert.is_false(ok_walk)
    assert.is_not_nil(err_walk)
    assert.is_true(has_log(walk_logs, "[PlayerLife]", "apply_walk", "103"))
    player.Character.Controller = real_ctrl

    -- 2. speed_writer 抛错
    speed_fail = true
    local sw_logs, ok_sw, err_sw = capture_prints(function()
      return tree:apply_walk(18)
    end)
    assert.is_false(ok_sw)
    assert.is_true(tostring(err_sw):find("speed-writer-boom", 1, true) ~= nil)
    assert.is_true(has_log(sw_logs, "[PlayerLife]", "speed_writer", "103"))
    speed_fail = false

    -- 3. growth_writer 返回 { Ok = false }
    growth_fail = true
    local gw_logs, ok_gw, err_gw = capture_prints(function()
      return tree:reapply_growth()
    end)
    assert.is_false(ok_gw)
    assert.equals("growth-denied", err_gw)
    assert.is_true(has_log(gw_logs, "[PlayerLife]", "growth_writer", "103"))
    growth_fail = false

    -- 4. publish_notice 广播失败 + fire_client 下发失败
    local dmg_logs = capture_prints(function()
      local ok_hit = tree:apply_hit(tree:new_hit(nil, "fishAttack"), player, 10)
      assert.is_true(ok_hit)
      tree:handle_survival_action({ action = "UseAdrenaline", seq = 1 }, true)
    end)
    assert.is_true(has_log(dmg_logs, "[PlayerLife]", "DamageNotice", "103"))
    assert.is_true(has_log(dmg_logs, "[PlayerLife]", "SurvivalResult", "103"))
    assert.is_not_nil(logs)
    runtime:shutdown()
  end)

  it("FerryRoute 明确区分正常为空与服务/数据异常，故障时记日志并暴露失败状态", function()
    local clock = SpokeClock.new(100)
    local world = SharedWorldTree.spawn({ clock = clock })
    local players_mode = "empty"
    local data_mode = "missing"
    local broadcasts = {}
    local replies = {}
    local remote_broken = false

    local ferry = FerryRoute.mount(world, {
      remote = {
        get_re = function(_, name)
          if remote_broken then error("re-down") end
          return {
            FireClient = function(_, p, payload) replies[#replies + 1] = { p = p, payload = payload } end,
            FireAllClients = function(_, payload) broadcasts[#broadcasts + 1] = payload end,
          }
        end,
      },
      players_service = {
        GetPlayers = function()
          if players_mode == "error" then error("players-service-down") end
          return {}
        end,
      },
      player_data = {
        get_data_inst = function()
          if data_mode == "error" then error("player-data-down") end
          return nil
        end,
      },
      interact = {
        find_anchor = function() return { Position = { x = 0, y = 0, z = 0 } } end,
      },
    })

    -- 1. online_players: 正常为空返回 {}, nil；异常返回 nil, err 且记日志
    local empty_list, empty_err = ferry:online_players()
    assert.same({}, empty_list)
    assert.is_nil(empty_err)

    players_mode = "error"
    local op_logs, bad_list, bad_err = capture_prints(function()
      return ferry:online_players()
    end)
    assert.is_nil(bad_list)
    assert.is_not_nil(bad_err)
    assert.is_true(has_log(op_logs, "[FerryRoute]", "读取在线玩家失败"))

    -- 2. depart 遇到 online_players 故障：不伪装为 empty，广播 service_error 并返回 false, err
    local payer = make_player(201)
    local route = GameCfg.Ferry.Routes[1]
    local dep_logs, dep_ok, dep_err = capture_prints(function()
      return ferry:depart(route, { player = payer, operation = "op-1", route_id = route.Id })
    end)
    assert.is_false(dep_ok)
    assert.is_not_nil(dep_err)
    assert.is_true(has_log(dep_logs, "[FerryRoute]", "发船中止"))
    assert.equals("service_error", broadcasts[#broadcasts].reason)

    -- 3. data_of: 正常 nil 与异常区分
    data_mode = "missing"
    local ok_missing, err_missing = ferry:handle(payer, { action = "Board", route_id = route.Id, seq = 1 })
    assert.is_false(ok_missing)
    assert.is_nil(err_missing)

    data_mode = "error"
    local data_logs, ok_err, err_data = capture_prints(function()
      return ferry:handle(payer, { action = "Board", route_id = route.Id, seq = 2 })
    end)
    assert.is_false(ok_err)
    assert.is_not_nil(err_data)
    assert.is_true(has_log(data_logs, "[FerryRoute]", "读取玩家数据失败", "201"))
    assert.equals("data_error", replies[#replies].payload.reason)

    -- 4. event 故障：reply / broadcast 返回 false, err 并记日志
    remote_broken = true
    local ev_logs, rep_ok, rep_err = capture_prints(function()
      return ferry:reply(payer, { ok = true })
    end)
    assert.is_false(rep_ok)
    assert.is_not_nil(rep_err)
    assert.is_true(has_log(ev_logs, "[FerryRoute]", "获取远程通道失败", "FerryResult"))

    world:dispose()
  end)

  it("PlayerWeapon 的 magazine_size、service、reply 与 step_flights 视觉失败均有明确日志", function()
    local clock = SpokeClock.new(100)
    local player = make_player(301)
    local data = make_data(player)
    data.magazine_size = function() error("mag-boom") end
    -- 在道具栏放一颗炸药供投掷视觉失败测试
    local explosive_id = next(GameCfg.Ability.Explosives)
    data.data.containers[GameCfg.Items.ContainerId.ItemBar][1] = { itemId = explosive_id, count = 1 }

    local locked_visual = setmetatable({ Destroy = function() end }, {
      __newindex = function(_, k)
        if k == "Position" then error("visual-pos-denied") end
      end,
    })

    local tree = {
      player = player,
      data = data,
      clock = clock,
      states = {
        held = Spoke.State.new("t.held", { kind = "weapon", id = "item137" }),
        selected_weapon = Spoke.State.new("t.sw", "item137"),
        weapons = Spoke.State.new("t.w", { item137 = 1 }),
      },
      memos = {
        can_act = Spoke.State.new("t.act", true),
        weapon_damage_scales = Spoke.State.new("t.scale", {}),
      },
      get_item_bar_snapshot = function()
        return { selectedSlot = 1, slots = { [1] = { itemId = explosive_id, count = 1 } } }
      end,
    }

    local old_game = _G.game
    local old_vec3 = _G.Vector3
    _G.Vector3 = { New = function(x, y, z) return { x = x, y = y, z = z } end }
    _G.game = { GetService = function() error("service-down") end }

    local weapon
    local root_tree
    local ok_run, run_err = pcall(function()
      root_tree = Spoke.SpokeTree.spawn("TestWeapon369", Spoke.Effect.new("W", function(scope)
        weapon = PlayerWeapon.mount(scope, tree, {
          remote = {
            get_re = function()
              return { FireClient = function() error("weapon-reply-down") end }
            end,
          },
          world = {
            CreateUnit = function() return locked_visual end,
          },
          new_hit = function() return {} end,
          apply_hit = function() return false end,
        })
      end))

      local logs = capture_prints(function()
        -- 触发 magazine_size 异常、service("PhysicsService") 异常与 reply 异常
        weapon:handle({ action = "attack", aim = { x = 0, y = 0, z = 1 } })
        -- 触发 throw 创建视觉并步进触发 step_flights 视觉位姿更新失败
        weapon:handle({ action = "throw", slot = 1, target = { x = 12, y = 2, z = -18 } })
        clock:step(0.2)
      end)
      assert.is_true(has_log(logs, "[PlayerWeapon]", "magazine_size", "301"))
      assert.is_true(has_log(logs, "[PlayerWeapon]", "获取服务失败", "PhysicsService"))
      assert.is_true(has_log(logs, "[PlayerWeapon]", "WeaponResult 下发失败", "301"))
      assert.is_true(has_log(logs, "[PlayerWeapon]", "投掷物视觉位姿更新失败", "301"))
    end)

    if root_tree then root_tree:dispose() end
    _G.game = old_game
    _G.Vector3 = old_vec3
    if not ok_run then error(run_err, 0) end
  end)

  it("PlayerGrill、PlayerBlindbox、PlayerLottery、PlayerPlatformShop 的下发失败均有明确日志", function()
    local clock = SpokeClock.new(100)
    local player = make_player(401)
    local data = make_data(player)
    data.extra.lottery = { intents = {}, deliveries = {} }
    data.extra.platformShop = { intents = {}, deliveries = {} }

    local tree = {
      player = player,
      data = data,
      clock = clock,
      memos = { can_act = Spoke.State.new("e.act", true), is_alive = Spoke.State.new("e.alive", true) },
      sync_from_data = function() end,
    }
    local broken_remote = {
      get_re = function() return { FireClient = function() error("send-failed") end } end,
    }
    local dummy_save = { sessions = { [401] = { token = "tok" } }, resolve_request = function() return nil, "invalid" end }
    local dummy_platform = { has_flow = function() return false end, can_purchase = function() return false, "closed" end }

    local grill, blindbox, lottery, shop
    local logs = capture_prints(function()
      local root_tree = Spoke.SpokeTree.spawn("TestEconomy369", Spoke.Effect.new("E", function(scope)
        grill = PlayerGrill.mount(scope, tree, { remote = broken_remote, save = dummy_save })
        blindbox = PlayerBlindbox.mount(scope, tree, { remote = broken_remote, save = dummy_save, platform = dummy_platform })
        lottery = PlayerLottery.mount(scope, tree, { remote = broken_remote, save = dummy_save })
        shop = PlayerPlatformShop.mount(scope, tree, { remote = broken_remote, save = dummy_save, platform = dummy_platform })
      end))
      grill.handle(player, { action = "Start", seq = 1 })
      blindbox.handle(player, { action = "Query", count = 1, seq = 1, requestId = "missing" })
      lottery.handle(player, { action = "Draw", seq = 1, slot = 1 })
      -- lottery 需经过 save.resolve_request 才 reply；直接触发 in_range 失败路径
      local lottery_root = Spoke.SpokeTree.spawn("TestLottery369", Spoke.Effect.new("L", function(scope)
        local l2 = PlayerLottery.mount(scope, tree, {
          remote = broken_remote,
          save = { resolve_request = function() return { id = "op1" }, "new" end },
          in_range = function() return false end,
        })
        l2.handle(player, { action = "Draw", seq = 1, slot = 1 })
      end))
      shop.handle(player, { action = "OpenAdrenaline" })
      lottery_root:dispose()
      root_tree:dispose()
    end)

    assert.is_true(has_log(logs, "[PlayerGrill]", "GrillState 推送失败", "401"))
    assert.is_true(has_log(logs, "[PlayerGrill]", "GrillResult 下发失败", "401"))
    assert.is_true(has_log(logs, "[PlayerBlindbox]", "BlindboxResult 下发失败", "401"))
    assert.is_true(has_log(logs, "[PlayerLottery]", "LotteryResult 下发失败", "401"))
    assert.is_true(has_log(logs, "[PlayerPlatformShop]", "PlatformResult 下发失败", "401"))
  end)

  it("server/main.lua 与 client/main.lua 不存在无日志的裸 pcall(SetCoreGuiEnabled)", function()
    local server_src = assert(fs.slurp("server/main.lua"))
    local client_src = assert(fs.slurp("client/main.lua"))
    assert.is_nil(server_src:find("SetCoreGuiEnabled", 1, true), "server/main.lua 不应存在裸 SetCoreGuiEnabled")
    for line in (client_src .. "\n"):gmatch("([^\n]*)\n") do
      if line:find("SetCoreGuiEnabled", 1, true) then
        assert.is_nil(line:match("^%s*pcall%s*%("), "client/main.lua 不得保留无日志的裸 pcall(SetCoreGuiEnabled)")
        assert.is_not_nil(line:find("ok, err = pcall", 1, true), "SetCoreGuiEnabled 须捕获 ok, err")
        assert.is_not_nil(line:find("print(", 1, true), "SetCoreGuiEnabled 失败须打印明确日志")
        assert.is_not_nil(line:find("CoreGuiType.", 1, true), "SetCoreGuiEnabled 日志须包含 CoreGuiType")
      end
    end
  end)
end)
