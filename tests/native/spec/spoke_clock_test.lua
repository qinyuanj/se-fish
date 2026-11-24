-- spoke_clock 纯契约测试（#294 / ADR-0032 §4）：
-- 失败方式先列：
--   1. 读取引擎全局对象 → 脱离引擎的离线环境或双端初始化阶段即炸；
--   2. 亚秒步进误触发 1 Hz 整秒状态/触发 → 秒级倒计时与周期结算提前触发或按帧重跑；
--   3. 跨整秒时 second 与 on_second 不在同一触发批内 → 同时观察两者的 Auto 树 Effect 看到中间态并多跑一次；
--   4. 跨多秒 advance 未逐秒结算 → 前一秒卸载的 Phase 在后续整秒里仍误跑周期回调；
--   5. on_frame 未传出 { dt, now } 或短寿命 Phase 卸载后未退订 → 帧动画/飞行拿不到步长或泄漏订阅；
--   6. 暴露逐帧刷新的响应式时刻 State → 60 FPS 重建 Effect attachments；
--   7. 非法时间参数（NaN/inf/负 dt）或宿主时钟轻微回拨未防御 → 污染全树状态。

local spoke = require("common.packages.spoke.api")
local SpokeTree = spoke.SpokeTree
local Effect = spoke.Effect
local State = spoke.State
local Phase = spoke.Phase

describe("spoke_clock 消费方确定性时钟契约", function()
  local saved_globals

  before_each(function()
    saved_globals = {
      game = rawget(_G, "game"),
      World = rawget(_G, "World"),
      RunService = rawget(_G, "RunService"),
      TimerService = rawget(_G, "TimerService"),
      Players = rawget(_G, "Players"),
    }
    _G.game = nil
    _G.World = nil
    _G.RunService = nil
    _G.TimerService = nil
    _G.Players = nil
  end)

  after_each(function()
    for name, value in pairs(saved_globals) do
      _G[name] = value
    end
  end)

  it("零引擎全局依赖，支持默认与自定义初始时刻并拒绝非法初值", function()
    local spoke_clock = require("common.spoke_clock")

    local default_clock = spoke_clock.new()
    assert.equals(0, default_clock.now())
    assert.equals(0, default_clock.second:now())

    local offset_clock = spoke_clock.new(12.75)
    assert.equals(12.75, offset_clock.now())
    assert.equals(12, offset_clock.second:now())

    assert.has_error(function() spoke_clock.new(0 / 0) end)
    assert.has_error(function() spoke_clock.new(math.huge) end)
    assert.has_error(function() spoke_clock.new(-math.huge) end)
    assert.has_error(function() spoke_clock.new("10") end)
  end)

  it("亚秒步进只更新 now()，跨整秒才推进 1 Hz second 与 on_second", function()
    local spoke_clock = require("common.spoke_clock")
    local clock = spoke_clock.new(10.0)

    local second_events = {}
    local effect_values = {}
    local tree = SpokeTree.spawn("Clock1Hz", Effect.new(function(s)
      s:subscribe(clock.on_second, function(sec)
        second_events[#second_events + 1] = { sec = sec, state = clock.second:now(), now = clock.now() }
      end)
      s:effect(function(es)
        effect_values[#effect_values + 1] = es:d(clock.second)
      end)
    end))

    assert.same({ 10 }, effect_values)
    assert.same({}, second_events)

    -- 亚秒推进：now() 精确变化，1 Hz 状态与触发保持静默
    clock:step(0.25, 10.25)
    clock:step(0.5, 10.75)
    assert.equals(10.75, clock.now())
    assert.equals(10, clock.second:now())
    assert.same({ 10 }, effect_values)
    assert.same({}, second_events)

    -- 跨入第 11 秒
    clock:step(0.3, 11.05)
    assert.equals(11.05, clock.now())
    assert.equals(11, clock.second:now())
    assert.same({ 10, 11 }, effect_values)
    assert.same({ { sec = 11, state = 11, now = 11 } }, second_events)

    -- 省略 now 时按 now + dt 推进；宿主时钟轻微回拨时保持单调不倒退
    clock:step(0.2)
    assert.is_true(math.abs(clock.now() - 11.25) < 1e-9)
    clock:step(0.016, 11.10)
    assert.is_true(math.abs(clock.now() - 11.25) < 1e-9)
    assert.equals(11, clock.second:now())

    -- 非法步进参数直接拒绝
    assert.has_error(function() clock:step(-0.1) end)
    assert.has_error(function() clock:step(0 / 0) end)
    assert.has_error(function() clock:step(0.1, math.huge) end)
    assert.has_error(function() clock:advance(-1) end)
    assert.has_error(function() clock:advance(math.huge) end)

    tree:dispose()
  end)

  it("单次整秒推进将 second 与 on_second 合并在同一触发批内，Auto 树只 flush 一次", function()
    local spoke_clock = require("common.spoke_clock")
    local clock = spoke_clock.new(0)
    local hunger = State.new("hunger", 100)
    local snapshots = {}

    local tree = SpokeTree.spawn("ClockBatch", Effect.new(function(s)
      s:subscribe(clock.on_second, function()
        hunger:set(hunger:now() - 1)
      end)
      s:effect(function(es)
        local sec = es:d(clock.second)
        local h = es:d(hunger)
        snapshots[#snapshots + 1] = { sec = sec, hunger = h }
      end, { clock.on_second })
    end))

    assert.same({ { sec = 0, hunger = 100 } }, snapshots)

    clock:advance(1)
    assert.same({
      { sec = 0, hunger = 100 },
      { sec = 1, hunger = 99 },
    }, snapshots)

    tree:dispose()
  end)

  it("多秒 advance 逐秒推进并排空，前一秒卸载的 Phase 不会在后续秒里误跑", function()
    local spoke_clock = require("common.spoke_clock")
    local clock = spoke_clock.new(0)
    local alive = State.new("alive", true)
    local hp = State.new("hp", 2)
    local seen_seconds = {}

    local tree = SpokeTree.spawn("ClockMultiAdvance", Effect.new(function(s)
      s:call(Phase.new("Alive", alive, function(ps)
        ps:subscribe(clock.on_second, function(sec)
          seen_seconds[#seen_seconds + 1] = { sec = sec, now = clock.now() }
          local next_hp = hp:now() - 1
          hp:set(next_hp)
          if next_hp <= 0 then
            alive:set(false)
          end
        end)
      end))
    end))

    clock:advance(5)
    assert.equals(5, clock.now())
    assert.equals(5, clock.second:now())
    assert.is_false(alive:now())
    assert.equals(0, hp:now())
    assert.same({
      { sec = 1, now = 1 },
      { sec = 2, now = 2 },
    }, seen_seconds)

    tree:dispose()
  end)

  it("on_frame 每帧传出 dt 与 now，仅供短寿命活跃 Phase 按需订阅且不重建 Effect", function()
    local spoke_clock = require("common.spoke_clock")
    local clock = spoke_clock.new(5.0)
    local active = State.new("active", false)
    local mounts = 0
    local frames = {}

    local tree = SpokeTree.spawn("ClockFramePhase", Effect.new(function(s)
      s:call(Phase.new("Active", active, function(ps)
        mounts = mounts + 1
        ps:subscribe(clock.on_frame, function(frame)
          frames[#frames + 1] = { dt = frame.dt, now = frame.now }
        end)
      end))
    end))

    -- 未激活时不收帧事件
    clock:step(0.016, 5.016)
    assert.equals(0, mounts)
    assert.same({}, frames)

    -- 激活后按帧收到 { dt, now }，且不重建 Phase
    active:set(true)
    clock:step(0.016, 5.032)
    clock:step(0.032, 5.064)
    assert.equals(1, mounts)
    assert.same({
      { dt = 0.016, now = 5.032 },
      { dt = 0.032, now = 5.064 },
    }, frames)

    -- 相位卸载后自动退订
    active:set(false)
    clock:step(0.016, 5.080)
    assert.equals(2, #frames)

    tree:dispose()
  end)

  it("now() 为非响应式只读函数，严禁暴露逐帧刷新的响应式时刻 State", function()
    local spoke_clock = require("common.spoke_clock")
    local clock = spoke_clock.new(1.0)

    assert.equals("function", type(clock.now))
    assert.equals(1.0, clock.now())

    local exposed_signals = {}
    for key, value in pairs(clock) do
      if type(value) == "table" and type(value.now) == "function" and type(value.subscribe) == "function" then
        exposed_signals[#exposed_signals + 1] = key
      end
    end
    table.sort(exposed_signals)
    assert.same({ "second" }, exposed_signals)

    -- 同一秒内高频 step 60 帧，唯一公开 State (second) 零通知
    local state_notifies = 0
    local handle = clock.second:subscribe(function()
      state_notifies = state_notifies + 1
    end)
    for i = 1, 60 do
      clock:step(0.01, 1.0 + i * 0.01)
    end
    assert.equals(0, state_notifies)
    assert.is_true(math.abs(clock.now() - 1.6) < 1e-9)
    handle:dispose()
  end)
end)
