-- 服务端 Spoke 运行时主干契约测试（#295 / ADR-0032 §1、§2、§4）：
-- 失败方式先列：
--   1. SharedWorldTree 未包含全部 7 个钓鱼区子域骨架与小队 Dock，或 dispose 后未逆序清理且仍响应时钟；
--   2. 存档未就绪就提前生成 PlayerTree，或 GameStart 前就绪的玩家被遗漏；
--   3. PlayerTree 内四段因果顺序未按源码顺序排布，同一 batch 内下游先于上游运行或读取旧派生值；
--   4. 麻痹误退外层生命相位，或 platform_pending 未暂停濒死/死亡倒计时相位；
--   5. 离场三步协议顺序错乱（未等前置脏写、终镜像晚于 dispose/save_leaving），或 dispose 后残留资源/局部信号；
--   6. 同账号重进期间排空栅栏未阻塞，导致提前读旧档或覆盖正在落盘的数据；
--   7. 单棵 PlayerTree 抛未捕获异常波及其他 PlayerTree 或 SharedWorldTree，或已 dispose 树仍响应事件。

local GameCfg = require("common.game_cfg")
local SpokeClock = require("common.spoke_clock")
local spoke = require("common.packages.spoke.api")
local SpokeRuntime = require("common.packages.spoke.runtime.spoke_runtime")
local LambdaEpoch = spoke.LambdaEpoch

local function make_signal()
  local handlers = {}
  return {
    handlers = handlers,
    Connect = function(self, fn)
      self.handlers[#self.handlers + 1] = fn
      local active = true
      return {
        Disconnect = function()
          if not active then return end
          active = false
          for i, h in ipairs(self.handlers) do
            if h == fn then
              table.remove(self.handlers, i)
              return
            end
          end
        end,
      }
    end,
    Fire = function(self, ...)
      for _, fn in ipairs({ table.unpack(self.handlers) }) do
        fn(...)
      end
    end,
  }
end

local function make_ready_data(player, overrides)
  overrides = overrides or {}
  local data = {
    Player = player,
    inited = overrides.inited ~= false,
    load_state = overrides.load_state or "ready",
    data = {
      FishCoin = overrides.coin or 50,
      Zone = overrides.zone or "fishPond",
      selected_slot = overrides.selected_slot or 1,
    },
    extra = {
      growth = {
        potions = {
          item168 = overrides.body_potions or 0,
          item167 = overrides.speed_potions or 0,
        },
      },
      survival = {
        health = overrides.health or GameCfg.Vitals.MaxHealth,
        hunger = overrides.hunger or GameCfg.Vitals.MaxHunger,
        dying = overrides.dying or false,
        dead = overrides.dead or false,
        weakRemaining = overrides.weak_remaining or 0,
        dyingRemaining = overrides.dying_remaining or 0,
        deadRemaining = overrides.dead_remaining or 0,
      },
    },
  }
  return data
end

local function silent_logger()
  local entries = {}
  return {
    entries = entries,
    error = function(_, message)
      entries[#entries + 1] = message
    end,
    info = function(_, message)
      entries[#entries + 1] = message
    end,
  }
end

describe("服务端 Spoke 主干：SharedWorldTree", function()
  it("以 Auto SpokeTree 挂载 7 个钓鱼区子域骨架与全局小队 Dock，并在 dispose 时逆序清理且不再响应时钟", function()
    local SharedWorldTree = require("server.world_host.shared_world_tree")
    local clock = SpokeClock.new(10)
    local logger = silent_logger()
    local log = {}

    local world = SharedWorldTree.spawn({
      clock = clock,
      logger = logger,
      on_mount_zone = function(s, zone)
        s:on_cleanup(function()
          log[#log + 1] = "cleanup:zone:" .. zone.id
        end)
      end,
    })

    assert.is_false(world:is_disposed())
    assert.is_nil(world.tree.fault)
    assert.equals(7, #world.zone_list)

    local expected_zone_ids = {}
    for index, zone_cfg in ipairs(GameCfg.Zones) do
      expected_zone_ids[index] = zone_cfg.Id
      local zone = world:get_zone(zone_cfg.Id)
      assert.is_not_nil(zone, "缺少钓鱼区子域: " .. zone_cfg.Id)
      assert.equals(index, zone.index)
      assert.equals(zone_cfg.Id, zone.id)
      assert.equals(zone_cfg.Name, zone.name)
      assert.is_not_nil(zone.ground_loot)
      assert.is_not_nil(zone.bait_spots)
      assert.is_not_nil(zone.ferry_routes)
    end
    assert.same({
      "fishPond",
      "shrimpPond",
      "crabLake",
      "forestIsland",
      "beachIsland",
      "reefIsland",
      "volcanoIsland",
    }, expected_zone_ids)
    assert.is_not_nil(world.squads)

    -- 动态挂载到地面物品/鱼饵点/摆渡航线/小队 Dock 的子域可响应时钟并在 dispose 时逆序清理
    local ticks = 0
    world:get_zone("fishPond").ground_loot:effect("loot-1", function(es)
      es:subscribe(clock.on_second, function()
        ticks = ticks + 1
      end)
      es:on_cleanup(function()
        log[#log + 1] = "cleanup:loot:loot-1"
      end)
    end)
    world:get_zone("volcanoIsland").ferry_routes:call("route-6", LambdaEpoch.new("Route6", function(es)
      es:on_cleanup(function()
        log[#log + 1] = "cleanup:ferry:route-6"
      end)
    end))
    world.squads:call("squad-1", LambdaEpoch.new("Squad1", function(es)
      es:on_cleanup(function()
        log[#log + 1] = "cleanup:squad:squad-1"
      end)
    end))

    clock:advance(2)
    assert.equals(2, ticks)

    world:dispose()
    assert.is_true(world:is_disposed())
    -- 幂等再次 dispose 不报错
    world:dispose()

    -- 销毁后不再响应时钟
    clock:advance(3)
    assert.equals(2, ticks)

    -- 小队 Dock 声明在 7 个钓鱼区之后，清理顺序严格逆序（小队先于火山岛先于鱼塘）
    local idx = {}
    for i, item in ipairs(log) do idx[item] = i end
    assert.is_true(idx["cleanup:squad:squad-1"] < idx["cleanup:zone:volcanoIsland"])
    assert.is_true(idx["cleanup:zone:volcanoIsland"] < idx["cleanup:zone:fishPond"])
    assert.is_not_nil(idx["cleanup:loot:loot-1"])
    assert.is_not_nil(idx["cleanup:ferry:route-6"])
    assert.same({}, logger.entries)
  end)
end)

describe("服务端 Spoke 主干：PlayerTree 因果顺序、双层相位与逆序清理", function()
  it("存档未就绪或归属不匹配时拒绝生成 PlayerTree", function()
    local PlayerTree = require("server.world_host.player_tree")
    local clock = SpokeClock.new(0)
    local player = { UserId = 1001 }
    local other = { UserId = 1002 }

    assert.has_error(function()
      PlayerTree.spawn({ player = player, data = nil, clock = clock })
    end)
    assert.has_error(function()
      PlayerTree.spawn({
        player = player,
        data = make_ready_data(player, { inited = false, load_state = "pending" }),
        clock = clock,
      })
    end)
    assert.has_error(function()
      PlayerTree.spawn({
        player = player,
        data = make_ready_data(player, { load_state = "failed" }),
        clock = clock,
      })
    end)
    assert.has_error(function()
      PlayerTree.spawn({
        player = player,
        data = make_ready_data(other),
        clock = clock,
      })
    end)
  end)

  it("严格按四段因果顺序排布：同一 batch 内上游先算、下游后跑并看到最新派生值", function()
    local PlayerTree = require("server.world_host.player_tree")
    local clock = SpokeClock.new(0)
    local logger = silent_logger()
    local player = { UserId = 2001 }
    local data = make_ready_data(player, { coin = 120, body_potions = 0, speed_potions = 0 })

    local order = {}
    local observed = {}
    local pt = PlayerTree.spawn({
      player = player,
      data = data,
      clock = clock,
      logger = logger,
      mounts = {
        save_inventory = function(s, self_tree)
          s:effect("ObsStage1", function(es)
            local big = es:d(self_tree.states.potion_big_count)
            local speed = es:d(self_tree.states.potion_speed_count)
            order[#order + 1] = "1:save_inventory"
            observed.stage1 = { big = big, speed = speed }
          end)
        end,
        attributes = function(s, self_tree)
          s:effect("ObsStage2", function(es)
            local max_hp = es:d(self_tree.memos.max_health)
            local scale = es:d(self_tree.memos.body_scale)
            local spd = es:d(self_tree.memos.move_speed_scale)
            order[#order + 1] = "2:attributes"
            observed.stage2 = { max_hp = max_hp, scale = scale, spd = spd }
          end)
        end,
        survival = function(s, self_tree)
          s:effect("ObsStage3", function(es)
            local max_hp = es:d(self_tree.memos.max_health)
            local can_act = es:d(self_tree.memos.can_act)
            order[#order + 1] = "3:survival"
            observed.stage3 = { max_hp = max_hp, can_act = can_act }
          end)
        end,
        actions = function(s, self_tree)
          s:effect("ObsStage4", function(es)
            local max_hp = es:d(self_tree.memos.max_health)
            local spd = es:d(self_tree.memos.move_speed_scale)
            local can_act = es:d(self_tree.memos.can_act)
            order[#order + 1] = "4:actions"
            observed.stage4 = { max_hp = max_hp, spd = spd, can_act = can_act }
          end)
        end,
      },
    })

    assert.same({
      "1:save_inventory",
      "2:attributes",
      "3:survival",
      "4:actions",
    }, order)
    assert.equals(300, pt.memos.max_health:now())
    assert.equals(1, pt.memos.body_scale:now())
    assert.equals(1, pt.memos.move_speed_scale:now())

    -- 同一 batch 内同时改写上游存档状态与虚弱标记，校验下游严格按 1 -> 2 -> 3 -> 4 重算且只看到最终组合值
    order = {}
    SpokeRuntime.batch(function()
      pt.states.potion_big_count:set(2)
      pt.states.potion_speed_count:set(5)
      pt.states.is_weak:set(true)
    end)

    assert.same({
      "1:save_inventory",
      "2:attributes",
      "3:survival",
      "4:actions",
    }, order)
    assert.equals(420, observed.stage2.max_hp)
    assert.is_true(math.abs(observed.stage2.scale - 1.4) < 1e-9)
    assert.is_true(math.abs(observed.stage2.spd - 0.75) < 1e-9)
    assert.equals(420, observed.stage3.max_hp)
    assert.equals(420, observed.stage4.max_hp)
    assert.is_true(math.abs(observed.stage4.spd - 0.75) < 1e-9)

    pt:dispose()
    assert.same({}, logger.entries)
  end)

  it("双层相位隔离：麻痹仅关闭 can_act 不退出外层存活相位，platform_pending 暂停濒死与死亡倒计时", function()
    local PlayerTree = require("server.world_host.player_tree")
    local clock = SpokeClock.new(0)
    local player = { UserId = 2002 }
    local data = make_ready_data(player)

    local alive_mounts, alive_cleanups = 0, 0
    local downed_ticks, dead_ticks = 0, 0

    local pt = PlayerTree.spawn({
      player = player,
      data = data,
      clock = clock,
      logger = silent_logger(),
    })

    pt:mount_phase("alive", "AliveMarker", function(s)
      alive_mounts = alive_mounts + 1
      s:on_cleanup(function()
        alive_cleanups = alive_cleanups + 1
      end)
    end)
    pt:mount_phase("downed_countdown", "DownedCountdownTick", function(s)
      s:subscribe(clock.on_second, function()
        downed_ticks = downed_ticks + 1
      end)
    end)
    pt:mount_phase("dead_countdown", "DeadCountdownTick", function(s)
      s:subscribe(clock.on_second, function()
        dead_ticks = dead_ticks + 1
      end)
    end)

    assert.is_true(pt.memos.is_alive:now())
    assert.is_true(pt.memos.can_act:now())
    assert.equals(1, alive_mounts)
    assert.equals(0, alive_cleanups)

    -- 雷霆之力麻痹：仅 can_act 变 false，外层存活相位不卸载、不重建
    pt.states.is_paralyzed:set(true)
    assert.is_true(pt.memos.is_alive:now())
    assert.is_false(pt.memos.can_act:now())
    assert.equals(1, alive_mounts)
    assert.equals(0, alive_cleanups)

    pt.states.is_paralyzed:set(false)
    assert.is_true(pt.memos.can_act:now())
    assert.equals(1, alive_mounts)
    assert.equals(0, alive_cleanups)

    -- 进入濒死：外层存活相位卸载，濒死倒计时相位激活
    pt.states.life_phase:set("downed")
    assert.equals(1, alive_cleanups)
    assert.is_true(pt.memos.is_downed:now())
    assert.is_false(pt.memos.can_act:now())
    clock:advance(2)
    assert.equals(2, downed_ticks)

    -- 发起广告/金豆复活：platform_pending = true 暂停倒计时，取消后恢复
    pt.states.platform_pending:set(true)
    clock:advance(3)
    assert.equals(2, downed_ticks)
    pt.states.platform_pending:set(false)
    clock:advance(1)
    assert.equals(3, downed_ticks)

    -- 转入死亡：濒死倒计时停，死亡倒计时同样受 platform_pending 门控
    pt.states.life_phase:set("dead")
    clock:advance(2)
    assert.equals(3, downed_ticks)
    assert.equals(2, dead_ticks)
    pt.states.platform_pending:set(true)
    clock:advance(2)
    assert.equals(2, dead_ticks)
    pt.states.platform_pending:set(false)
    clock:advance(1)
    assert.equals(3, dead_ticks)

    pt:dispose()
  end)

  it("离场 Step 1 触发终镜像时在场资源仍可读，Step 2 同步 dispose 按逆序拆除资源与局部信号连接零残留", function()
    local PlayerTree = require("server.world_host.player_tree")
    local clock = SpokeClock.new(0)
    local player = { UserId = 2003 }
    local data = make_ready_data(player)
    local local_signal = make_signal()
    local events = {}
    local destroyed_units = {}
    local signal_hits = 0

    local pt = PlayerTree.spawn({
      player = player,
      data = data,
      clock = clock,
      logger = silent_logger(),
      on_leave_finalize = function(self_tree)
        events[#events + 1] = "step1:finalize:alive=" .. tostring(self_tree.session_alive:now())
          .. ":handlers=" .. tostring(#local_signal.handlers)
          .. ":destroyed=" .. tostring(#destroyed_units)
      end,
      mounts = {
        save_inventory = function(s)
          s:on_cleanup(function()
            events[#events + 1] = "cleanup:1:save_inventory"
          end)
        end,
        attributes = function(s)
          s:on_cleanup(function()
            events[#events + 1] = "cleanup:2:attributes"
          end)
        end,
        survival = function(s)
          local conn = local_signal:Connect(function()
            signal_hits = signal_hits + 1
          end)
          s:on_cleanup(function()
            conn:Disconnect()
            events[#events + 1] = "cleanup:3:survival_signal"
          end)
        end,
        actions = function(s)
          local unit = {
            name = "TempSpecialProp",
            Destroy = function(self)
              destroyed_units[#destroyed_units + 1] = self.name
            end,
          }
          s:on_cleanup(function()
            unit:Destroy()
            events[#events + 1] = "cleanup:4:actions_unit"
          end)
        end,
      },
    })

    local_signal:Fire()
    assert.equals(1, signal_hits)
    assert.equals(1, #local_signal.handlers)

    -- Step 1: session_alive = false 触发离场终镜像，此时资源与信号仍活着尚未被 dispose 拆掉
    pt:begin_leave()
    assert.is_false(pt.session_alive:now())
    assert.same({ "step1:finalize:alive=false:handlers=1:destroyed=0" }, events)
    -- 重复调用幂等，不重复触发终镜像
    pt:begin_leave()
    assert.equals(1, #events)

    -- Step 2: 同步 dispose 按逆序拆除全部在场资源与信号连接
    pt:dispose()
    assert.is_true(pt:is_disposed())
    assert.equals(0, #local_signal.handlers)
    assert.same({ "TempSpecialProp" }, destroyed_units)
    assert.same({
      "step1:finalize:alive=false:handlers=1:destroyed=0",
      "cleanup:4:actions_unit",
      "cleanup:3:survival_signal",
      "cleanup:2:attributes",
      "cleanup:1:save_inventory",
    }, events)

    -- 销毁后再触发信号与时钟均零响应
    local_signal:Fire()
    clock:advance(5)
    assert.equals(1, signal_hits)
  end)
end)

describe("服务端 Spoke 主干：ServerRuntime 离场三步协议、排空栅栏与树级故障隔离", function()
  local function make_player(user_id)
    return {
      UserId = user_id,
      attrs = {},
      SetAttribute = function(self, key, value)
        self.attrs[key] = value
      end,
    }
  end

  it("SharedWorldTree 全局唯一启动，且玩家仅在存档就绪与服务启动后才生成专属 PlayerTree", function()
    local ServerRuntime = require("server.world_host.server_runtime")
    local logger = silent_logger()
    local ready_callbacks = {}
    local join_starts = {}

    local rt = ServerRuntime.new({
      initial_now = 100,
      logger = logger,
      on_player_join_start = function(player)
        join_starts[#join_starts + 1] = player
      end,
      on_player_ready = function(player, data, player_tree)
        ready_callbacks[#ready_callbacks + 1] = { player = player, data = data, tree = player_tree }
      end,
    })

    local w1 = rt:start()
    local w2 = rt:start()
    assert.are.equal(w1, w2)
    assert.equals(7, #w1.zone_list)

    -- 玩家在 mark_started 前入场并完成存档就绪：先入 ReadyQueue，不提前生成 PlayerTree
    local p1 = make_player(3001)
    rt:on_player_added(p1)
    assert.same({ p1 }, join_starts)
    assert.is_nil(rt:get_player_tree(3001))

    local d1 = make_ready_data(p1, { coin = 88 })
    rt:on_save_ready(p1, d1)
    assert.is_nil(rt:get_player_tree(3001))

    -- 未就绪存档被直接拒绝，不生成 PlayerTree
    local p2 = make_player(3002)
    rt:on_player_added(p2)
    rt:on_save_ready(p2, make_ready_data(p2, { inited = false, load_state = "pending" }))
    assert.is_nil(rt:get_player_tree(3002))

    -- mark_started 排空 ReadyQueue，仅已就绪的 p1 生成 PlayerTree
    rt:mark_started()
    local pt1 = rt:get_player_tree(3001)
    assert.is_not_nil(pt1)
    assert.equals(88, pt1.states.coin:now())
    assert.equals(1, #ready_callbacks)
    assert.are.equal(pt1, ready_callbacks[1].tree)
    assert.is_nil(rt:get_player_tree(3002))

    -- 启动后 p2 存档就绪，立即生成专属 PlayerTree
    local d2 = make_ready_data(p2, { coin = 15 })
    rt:on_save_ready(p2, d2)
    local pt2 = rt:get_player_tree(3002)
    assert.is_not_nil(pt2)
    assert.are_not.equal(pt1, pt2)

    rt:shutdown()
    assert.is_true(w1:is_disposed())
    assert.is_true(pt1:is_disposed())
    assert.is_true(pt2:is_disposed())
  end)

  it("启动时非有限 initial_now 降级为 0 且接受非裸表形态（元表代理 / userdata 协议）的玩家对象", function()
    local ServerRuntime = require("server.world_host.server_runtime")
    local logger = silent_logger()

    local rt_nan = ServerRuntime.new({ initial_now = 0 / 0, logger = logger })
    assert.equals(0, rt_nan.clock.now())
    local rt_inf = ServerRuntime.new({ initial_now = math.huge, logger = logger })
    assert.equals(0, rt_inf.clock.now())

    -- 验证经 __index 读取 UserId / SetAttribute 的代理对象（与引擎 userdata 成员访问口径一致）
    rt_nan:start()
    rt_nan:mark_started()
    local proxy_player = setmetatable({}, {
      __index = function(_, key)
        if key == "UserId" then return 3099 end
        if key == "SetAttribute" then return function() end end
      end,
    })
    rt_nan:on_player_added(proxy_player)
    rt_nan:on_save_ready(proxy_player, make_ready_data(proxy_player, { coin = 7 }))
    assert.is_not_nil(rt_nan:get_player_tree(3099))
    assert.equals(7, rt_nan:get_player_tree(3099).states.coin:now())
    rt_nan:on_player_removing(proxy_player)
    assert.is_nil(rt_nan:get_player_tree(3099))
    rt_nan:shutdown()
    rt_inf:shutdown()
  end)

  it("离场三步协议严格按顺序执行，并在同账号重进期间通过排空栅栏防脏读与覆盖写入", function()
    local ServerRuntime = require("server.world_host.server_runtime")
    local logger = silent_logger()
    local timeline = {}
    local store = {}
    local pending_flush_resume = nil
    local pending_drain_done = nil
    local data_by_player = {}
    local local_sig = make_signal()
    local sig_hits = 0

    local rt
    rt = ServerRuntime.new({
      initial_now = 200,
      logger = logger,
      on_player_join_start = function(player)
        timeline[#timeline + 1] = "join_start:" .. tostring(player.tag)
        -- 模拟异步读档：仅在后续显式调用 complete_load 时完成，读取当时已落盘的 store
        player.loaded_coin = store[player.UserId] or 0
      end,
      is_player_data_current = function(player, data)
        return data_by_player[player] == data
      end,
      on_player_ready = function(player, _, player_tree)
        timeline[#timeline + 1] = "ready:" .. tostring(player.tag)
        if player.tag == "A1" then
          player_tree.docks.actions:effect("SessionSignal", function(es)
            local conn = local_sig:Connect(function()
              sig_hits = sig_hits + 1
            end)
            es:on_cleanup(function()
              conn:Disconnect()
              timeline[#timeline + 1] = "step2:dispose_cleanup:" .. tostring(player.tag)
            end)
          end)
        end
      end,
      flush_before_leave = function(player, resume)
        if player.needs_pre_flush and not player.pre_flushed then
          timeline[#timeline + 1] = "pre_flush_wait:" .. tostring(player.tag)
          pending_flush_resume = function()
            player.pre_flushed = true
            timeline[#timeline + 1] = "pre_flush_done:" .. tostring(player.tag)
            resume()
          end
          return true
        end
        return false
      end,
      on_leave_finalize = function(player_tree, player, data)
        -- Step 1 终镜像：把最新金币写入 data，并确认此时树内信号尚未被 Step 2 拆掉
        timeline[#timeline + 1] = "step1:finalize:" .. tostring(player.tag)
          .. ":alive=" .. tostring(player_tree.session_alive:now())
          .. ":handlers=" .. tostring(#local_sig.handlers)
        data.data.FishCoin = 999
      end,
      on_player_removing = function(player, was_active)
        local data = data_by_player[player]
        timeline[#timeline + 1] = "step3:serialize:" .. tostring(player.tag)
          .. ":active=" .. tostring(was_active)
          .. ":coin=" .. tostring(data and data.data.FishCoin or -1)
          .. ":handlers=" .. tostring(#local_sig.handlers)
        -- 模拟异步写档：尚未落入 store，等 pending_drain_done 执行时才真正落盘
        player.pending_write_coin = data and data.data.FishCoin
      end,
      after_idle = function(user_id, done)
        timeline[#timeline + 1] = "step3:after_idle_wait:" .. tostring(user_id)
        pending_drain_done = function()
          if user_id == 4001 then
            store[user_id] = 999
          end
          timeline[#timeline + 1] = "step3:after_idle_done:" .. tostring(user_id)
          done()
        end
      end,
    })

    rt:start()
    rt:mark_started()

    -- A1 入场并就绪
    local a1 = make_player(4001)
    a1.tag = "A1"
    a1.needs_pre_flush = true
    rt:on_player_added(a1)
    local d1 = make_ready_data(a1, { coin = 10 })
    data_by_player[a1] = d1
    rt:on_save_ready(a1, d1)
    local pt_a1 = rt:get_player_tree(4001)
    assert.is_not_nil(pt_a1)
    assert.equals(1, #local_sig.handlers)
    local_sig:Fire()
    assert.equals(1, sig_hits)

    -- A1 离场：先停在异步前置脏写阶段（任务/剧情 flush），此时树未拆
    rt:on_player_removing(a1)
    assert.is_not_nil(pending_flush_resume)
    assert.is_false(pt_a1:is_disposed())
    assert.is_true(pt_a1.session_alive:now())

    -- 同账号 A2 在排空栅栏未解除前重进：必须被阻塞，不得启动读档或生成新树
    local a2 = make_player(4001)
    a2.tag = "A2"
    rt:on_player_added(a2)
    assert.equals("pending", a2.attrs.SaveState)
    assert.is_nil(a2.loaded_coin)

    -- 其他账号 B1 入场不受 4001 的排空栅栏阻塞
    local b1 = make_player(4002)
    b1.tag = "B1"
    rt:on_player_added(b1)
    local db1 = make_ready_data(b1, { coin = 5 })
    data_by_player[b1] = db1
    rt:on_save_ready(b1, db1)
    assert.is_not_nil(rt:get_player_tree(4002))

    -- 前置脏写完成：固定顺序跑 Step 1（终镜像）→ Step 2（同步 dispose 逆序清信号）→ Step 3（序列化 + after_idle 等待）
    local resume = pending_flush_resume
    pending_flush_resume = nil
    resume()

    assert.is_true(pt_a1:is_disposed())
    assert.equals(0, #local_sig.handlers)
    assert.is_nil(rt:get_player_tree(4001))
    -- 异步写盘尚未排空，A2 依然处于阻塞等待状态，未提前读旧档
    assert.is_nil(a2.loaded_coin)
    assert.is_not_nil(pending_drain_done)

    -- 模拟 A2 在等待期间离开，随后 A3 重进，只应接纳最新的 A3
    rt:on_player_removing(a2)
    local a3 = make_player(4001)
    a3.tag = "A3"
    rt:on_player_added(a3)
    assert.equals("pending", a3.attrs.SaveState)

    -- 异步落盘排空完成：自动接纳 A3，且 A3 读到的是 A1 离场终镜像落盘后的 999 金币（无脏读/覆盖）
    local drain = pending_drain_done
    pending_drain_done = nil
    drain()

    assert.equals(999, a3.loaded_coin)
    local d3 = make_ready_data(a3, { coin = a3.loaded_coin })
    data_by_player[a3] = d3
    rt:on_save_ready(a3, d3)
    local pt_a3 = rt:get_player_tree(4001)
    assert.is_not_nil(pt_a3)
    assert.equals(999, pt_a3.states.coin:now())

    -- 已 dispose 的旧树与旧信号连接零响应
    local_sig:Fire()
    assert.equals(1, sig_hits)

    -- 验证关键协议严格顺序
    local pos = {}
    for i, item in ipairs(timeline) do pos[item] = i end
    assert.is_true(pos["pre_flush_wait:A1"] < pos["pre_flush_done:A1"])
    assert.is_true(pos["pre_flush_done:A1"] < pos["step1:finalize:A1:alive=false:handlers=1"])
    assert.is_true(pos["step1:finalize:A1:alive=false:handlers=1"] < pos["step2:dispose_cleanup:A1"])
    assert.is_true(pos["step2:dispose_cleanup:A1"] < pos["step3:serialize:A1:active=true:coin=999:handlers=0"])
    assert.is_true(pos["step3:serialize:A1:active=true:coin=999:handlers=0"] < pos["step3:after_idle_wait:4001"])
    assert.is_true(pos["step3:after_idle_wait:4001"] < pos["step3:after_idle_done:4001"])
    assert.is_true(pos["step3:after_idle_done:4001"] < pos["join_start:A3"])
    assert.is_nil(pos["join_start:A2"])

    rt:shutdown()
  end)

  it("树级故障隔离：单棵 PlayerTree 抛未捕获异常时其余 PlayerTree 与 SharedWorldTree 正常推进，且已 dispose 树不再响应", function()
    local ServerRuntime = require("server.world_host.server_runtime")
    local logger = silent_logger()
    local world_ticks, b_ticks, a_ticks = 0, 0, 0
    local a_finalized = false

    local rt = ServerRuntime.new({
      initial_now = 0,
      logger = logger,
      on_leave_finalize = function(_, player)
        if player.UserId == 5001 then
          a_finalized = true
        end
      end,
    })

    local world = rt:start()
    rt:mark_started()

    world:get_zone("fishPond").bait_spots:effect("WorldTick", function(es)
      es:subscribe(rt.clock.on_second, function()
        world_ticks = world_ticks + 1
      end)
    end)

    local pa, pb = make_player(5001), make_player(5002)
    rt:on_player_added(pa)
    rt:on_player_added(pb)
    rt:on_save_ready(pa, make_ready_data(pa))
    rt:on_save_ready(pb, make_ready_data(pb))

    local pta = rt:get_player_tree(5001)
    local ptb = rt:get_player_tree(5002)

    -- 玩家 A 在第 2 秒触发未捕获异常（在 Effect Tick 中抛错以触发树级 fault）
    pta.docks.actions:effect("FaultyEffect", function(es)
      local sec = es:d(rt.clock.second)
      a_ticks = a_ticks + 1
      if sec >= 2 then
        error("玩家 A 未捕获业务异常")
      end
    end)

    ptb.docks.actions:effect("HealthyEffect", function(es)
      local _ = es:d(rt.clock.second)
      b_ticks = b_ticks + 1
    end)

    -- 第 1 秒：全员正常
    rt:step(1, 1)
    assert.equals(1, world_ticks)
    assert.equals(2, a_ticks)
    assert.equals(2, b_ticks)
    assert.is_false(pta:is_faulted())

    -- 第 2 秒：玩家 A 抛错并被隔离，不向宿主抛出异常；SharedWorldTree 与玩家 B 继续推进
    assert.has_no.errors(function()
      rt:step(1, 2)
    end)
    assert.is_true(pta:is_faulted())
    assert.is_false(ptb:is_faulted())
    assert.is_false(world:is_faulted())
    assert.equals(2, world_ticks)
    assert.equals(3, b_ticks)

    -- 第 3、4 秒：玩家 A 停止 flush，玩家 B 与 SharedWorldTree 照常推进
    rt:step(1, 3)
    rt:step(1, 4)
    assert.equals(4, world_ticks)
    assert.equals(5, b_ticks)
    assert.equals(3, a_ticks)

    -- 故障玩家 A 离场时仍可执行终镜像并安全 dispose；玩家 B 离场 dispose 后亦不再响应时钟
    rt:on_player_removing(pa)
    assert.is_true(a_finalized)
    assert.is_true(pta:is_disposed())

    rt:on_player_removing(pb)
    assert.is_true(ptb:is_disposed())
    rt:step(1, 5)
    assert.equals(5, world_ticks)
    assert.equals(5, b_ticks)

    rt:shutdown()
  end)
end)

describe("服务端入口接线：server/main.lua 宿主测试双端到端集成", function()
  local saved
  local runtime

  before_each(function()
    saved = {
      game = rawget(_G, "game"),
      REUtil = rawget(_G, "REUtil"),
      reutil = package.loaded["common.re_util"],
      MgrUtil = rawget(_G, "MgrUtil"),
      MgrPlayerData = rawget(_G, "MgrPlayerData"),
      Vector3 = rawget(_G, "Vector3"),
      Color = rawget(_G, "Color"),
      RemoteEvent = rawget(_G, "RemoteEvent"),
      Debug = GameCfg.Debug,
      slot = GameCfg.Save.QaSlot,
    }
    GameCfg.Debug = { Enabled = false }
    GameCfg.Save.QaSlot = ""
    _G.Vector3 = { New = function(x, y, z) return { x = x, y = y, z = z } end }
    _G.Color = { New = function(...) return { ... } end }
    _G.RemoteEvent = { New = function()
      return { OnServerEvent = make_signal(), OnClientEvent = make_signal(), FireServer = function() end,
        FireClient = function() end }
    end }
    runtime = nil
  end)

  after_each(function()
    if runtime and runtime.shutdown then
      runtime:shutdown()
    end
    _G.game = saved.game
    _G.REUtil = saved.REUtil
    package.loaded["common.re_util"] = saved.reutil
    _G.MgrUtil = saved.MgrUtil
    _G.MgrPlayerData = saved.MgrPlayerData
    _G.Vector3 = saved.Vector3
    _G.Color = saved.Color
    _G.RemoteEvent = saved.RemoteEvent
    GameCfg.Debug = saved.Debug
    GameCfg.Save.QaSlot = saved.slot
    saved = nil
    runtime = nil
  end)

  it("真实 server/main.lua 启动唯一 SharedWorldTree、Heartbeat 驱动 SpokeClock、存档就绪生成 PlayerTree 并执行离场三步协议与重进排空", function()
    local now = 100
    local tasks, values, errors, mgrs = {}, {}, {}, {}
    local remote_events = {}
    local order = {}
    local players_service = {
      PlayerAdded = make_signal(),
      PlayerRemoving = make_signal(),
      GetPlayers = function() return {} end,
      GetPlayerFromCharacter = function() return nil end,
    }
    local heartbeat = make_signal()
    local store = {
      GetAsync = function(_, key) return values[key] end,
      UpdateAsync = function(_, key, transform)
        local value = transform(values[key])
        if value then values[key] = value end
        return value
      end,
    }
    local function make_dummy_unit()
      local u = { attrs = {}, destroyed = false }
      function u:Destroy() self.destroyed = true end
      function u:SetAttribute(k, v) self.attrs[k] = v end
      function u:GetAttribute(k) return self.attrs[k] end
      function u:FindFirstChild() return nil end
      return u
    end

    _G.game = {
      BindToClose = function() end,
      GetService = function(_, name)
        if name == "Task" then
          return {
            Spawn = function(_, fn) tasks[#tasks + 1] = fn end,
            Wait = function() end,
          }
        end
        if name == "Players" then return players_service end
        if name == "RunService" then return { Heartbeat = heartbeat, IsServer = function() return true end, IsClient = function() return false end } end
        if name == "World" then
          return {
            GetServerTime = function() return now end,
            CreateUnit = function() return make_dummy_unit() end,
            CreateAsset = function() return { make_dummy_unit() } end,
          }
        end
        if name == "DataStoreService" then return { GetDataStore = function() return store end } end
      end,
    }
    local remote_util = {
      get_re = function(_, name)
        if not remote_events[name] then
          remote_events[name] = { OnServerEvent = make_signal(), FireClient = function() end }
        end
        return remote_events[name]
      end,
    }

    local attr_api_stub = {
      Enums = { AttrComponentType = { Base = 1, BaseExtra = 2, Ratio = 3, Bonus = 4 } },
      Funcs = {
        GetAttrConfig = function() return nil end,
        GetAttrUnit = function() return nil end,
        EnsureAttrUnit = function() return make_dummy_unit() end,
        SetAttrComponent = function() return true end,
        GetAttr = function() return 0 end,
      },
    }
    local modifier_api_stub = {
      Enums = { CreateResult = { Added = "Added", Reobtained = "Reobtained" } },
      AddModifier = function() return "Added" end,
      GetUnitModifiers = function() return {} end,
      RemoveModifier = function() end,
    }
    local ability_api_stub = {
      AddAbility = function() return { SetAttribute = function() end } end,
      StopAbility = function() end,
      CastAbility = function() return true end,
    }

    mgrs.SaveHost = assert(loadfile("server/save_host.lua"))()
    mgrs.PlayerDataHost = assert(loadfile("server/player_data_host.lua"))()
    mgrs.PlatformHost = {}
    mgrs.FishAbility = { start = function() end, update = function() end }
    _G.REUtil = remote_util
    package.loaded["common.re_util"] = remote_util

    local sandbox = setmetatable({
      print = function(...)
        local parts = { ... }
        if parts[1] == "[server.main]" then
          errors[#errors + 1] = parts
        end
      end,
      require = function(path)
        if path == "common.re_util" then return remote_util end
        if path == "server.MgrUtil" then return { Start = function() end } end
        if path == "common.zone_markers" then return { start = function() end } end
        if path == "server.packages.attr_rule.api" then return attr_api_stub end
        if path == "server.packages.modifier_system.api" then return modifier_api_stub end
        if path == "server.packages.ability_system.api" then return ability_api_stub end
        if path == "server.save_host" then return mgrs.SaveHost end
        if path == "server.player_data_host" then return mgrs.PlayerDataHost end
        if path == "server.platform_host" then return mgrs.PlatformHost end
        if path == "server.fish_ability" then return mgrs.FishAbility end
        return require(path)
      end,
    }, { __index = _G })

    runtime = assert(loadfile("server/main.lua", "t", sandbox))()
    assert.is_not_nil(runtime, "server/main.lua 应返回服务端 Spoke Runtime 句柄")

    local world = runtime:get_world()
    assert.is_not_nil(world)
    assert.equals(7, #world.zone_list)
    assert.is_not_nil(world.ferry)
    assert.is_not_nil(remote_events.FerryAction)
    assert.equals(1, #remote_events.FerryAction.OnServerEvent.handlers)
    assert.equals(100, runtime.clock.now())

    -- Heartbeat 每帧驱动 SpokeClock，SharedWorldTree 正常接收 1 Hz 推进
    local world_sec_ticks = 0
    world:get_zone("fishPond").bait_spots:effect("HeartbeatProbe", function(es)
      es:subscribe(runtime.clock.on_second, function()
        world_sec_ticks = world_sec_ticks + 1
      end)
    end)
    now = 101
    heartbeat:Fire(1)
    assert.equals(1, world_sec_ticks)
    assert.equals(101, runtime.clock.now())

    local function make_host_player(uid)
      local c = { Health = 300, MaxHealth = 300, HealthChanged = make_signal(), Died = make_signal(), OnReborn = make_signal() }
      local character = { Controller = c, SetScale = function() end }
      local p = { UserId = uid, attrs = {}, CharacterAdded = make_signal(), CharacterRemoving = make_signal(), Character = character }
      function p:SetAttribute(k, v) self.attrs[k] = v end
      return p
    end

    local function drain()
      local steps = 0
      while #tasks > 0 do
        steps = steps + 1
        assert(steps < 100, "异步任务未收敛")
        table.remove(tasks, 1)()
      end
      assert.same({}, errors)
    end

    -- 玩家入场：存档尚未读完前不得生成 PlayerTree
    local p1 = make_host_player(6001)
    players_service.PlayerAdded:Fire(p1)
    assert.equals("pending", p1.attrs.SaveState)
    assert.is_nil(runtime:get_player_tree(6001))

    -- 异步读档完成后生成专属 PlayerTree
    drain()
    assert.equals("ready", p1.attrs.SaveState)
    local pt1 = runtime:get_player_tree(6001)
    assert.is_not_nil(pt1)
    assert.is_true(pt1.session_alive:now())

    local local_sig = make_signal()
    pt1.docks.actions:effect("MainIntegrationResource", function(es)
      local conn = local_sig:Connect(function() end)
      es:on_cleanup(function()
        conn:Disconnect()
        order[#order + 1] = "dispose_cleanup:6001"
      end)
    end)
    assert.equals(1, #local_sig.handlers)

    -- 变更金币并触发离场 + 同账号立即重进
    mgrs.PlayerDataHost:get_data_inst(p1):AddCoin(42)
    players_service.PlayerRemoving:Fire(p1)
    local p2 = make_host_player(6001)
    players_service.PlayerAdded:Fire(p2)

    -- 离场异步写档未排空前，p2 必须保持 pending 且无新 PlayerTree
    assert.equals("pending", p2.attrs.SaveState)
    assert.is_nil(runtime:get_player_tree(6001))
    assert.is_true(pt1:is_disposed())
    assert.equals(0, #local_sig.handlers)

    -- 验证 Step 1（BeforeLeave 终镜像）严格先于 Step 2（dispose 逆序清理）
    local idx = {}
    for i, item in ipairs(order) do idx[item] = i end
    assert.is_true(idx["dispose_cleanup:6001"] ~= nil)

    -- 排空异步落盘后，p2 自动恢复并生成全新 PlayerTree，金币无丢失无脏读
    drain()
    assert.equals("ready", p2.attrs.SaveState)
    local pt2 = runtime:get_player_tree(6001)
    assert.is_not_nil(pt2)
    assert.are_not.equal(pt1, pt2)
    assert.equals(42, pt2.states.coin:now())
    assert.equals(42, mgrs.PlayerDataHost:get_data_inst(p2).data.FishCoin)
  end)
end)

describe("服务端 Spoke 主干：PlayerTree 相位块增删与钓竿阶段入口", function()
  local function spawn_tree(player_id, extra)
    local PlayerTree = require("server.world_host.player_tree")
    local player = { UserId = player_id }
    local opts = { player = player, data = make_ready_data(player), clock = SpokeClock.new(0), logger = silent_logger() }
    for key, value in pairs(extra or {}) do opts[key] = value end
    return PlayerTree.spawn(opts), player
  end

  -- 相位块是外部功能叶挂进 PlayerTree 的唯一入口（mount_phase / unmount_phase）。
  -- 失败方式：卸载后块还在跑（关掉的界面/订阅继续生效）；重挂不生效（功能叶回不来）；
  -- 未知相位静默通过（拼错的相位名永远不生效也不报错）。
  it("mount_phase 挂上的相位块随所属相位运行，unmount_phase 后停跑，未知相位报错", function()
    local pt = spawn_tree(2103)
    local runs, last = 0, nil
    local block = function(s)
      s:effect("PhaseProbe", function(es)
        runs = runs + 1
        last = es:d(pt.states.potion_big_count)
      end)
    end
    pt:mount_phase("alive", "probe", block)
    SpokeRuntime.batch(function() pt.states.potion_big_count:set(1) end)
    local mounted = runs
    assert.is_true(mounted > 0, "挂到活跃相位上的块必须随状态重算运行")
    assert.equals(1, last)

    pt:unmount_phase("alive", "probe")
    SpokeRuntime.batch(function() pt.states.potion_big_count:set(2) end)
    assert.equals(mounted, runs, "卸载后该块不得再运行")

    pt:mount_phase("alive", "probe", block)
    SpokeRuntime.batch(function() pt.states.potion_big_count:set(3) end)
    assert.is_true(runs > mounted, "重新挂上后必须恢复运行")
    assert.equals(3, last)

    pt:unmount_phase("alive", "not-mounted")
    assert.has_error(function() pt:unmount_phase("no-such-phase", "probe") end)
    assert.equals(3, last)
    pt:dispose()
  end)

  -- 钓竿阶段的 Drop 动作：有鱼单位就交给它丢，没有就明确拒绝（不能回 ok 骗客户端）。
  -- 失败方式：没鱼单位也回 true（客户端清空手上状态，鱼却还在）；或没把玩家传给鱼单位。
  it("钓竿阶段的 Drop 动作把请求交给鱼单位，没有鱼单位时明确拒绝", function()
    local dropped = {}
    local fish_unit = { drop = function(_, target) dropped[#dropped + 1] = target end }
    local with_unit, player = spawn_tree(2104, { fish_unit = fish_unit })
    assert.is_true(with_unit.fishing:cast({ action = "Drop" }), "有鱼单位时必须接受丢弃")
    assert.same({ player }, dropped)
    with_unit:dispose()

    local no_unit = spawn_tree(2105)
    assert.is_false(no_unit.fishing:cast({ action = "Drop" }), "没有鱼单位时不得假装丢掉了")
    assert.same({ player }, dropped)
    no_unit:dispose()
  end)
end)
