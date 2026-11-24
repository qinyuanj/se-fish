-- #297-B 客户端 ClientStore 状态聚合与 Spoke 相机距离投影测试（取代旧 LocalAttr）。
-- 失败方式先列：
--   1. ClientStore.vitals / coin / camera_distance 未深冻结只读或漏同步 ItemBarState.coin → 视图篡改或金币漂移；
--   2. 玩家属性信号连接未随 bind_host:dispose() 断开 → 重复绑定/重连监听泄漏；
--   3. 相机在他人/玩家手动改距后仍强制覆写，或角色更换/视图销毁后未恢复原始距离 → 相机抢权与残留。

local Eui = require("tests.support.eui_double")
local ClientStore = require("client.store.client_store")
local RootView = require("client.views.root_view")
local CameraZoomView = require("client.views.camera_zoom_view")

describe("ClientStore 属性汇聚与 CameraZoomView（#297-B）", function()
  it("ClientStore 深冻结汇聚 vitals / coin / local_character / camera_distance 且在 dispose 后零残留", function()
    local store, writer = ClientStore.new({ initial_now = 10 })

    -- 只读契约校验
    assert.is_nil(store.vitals.set)
    assert.is_nil(store.coin.set)
    assert.is_nil(store.camera_distance.set)
    assert.is_nil(store.local_character.set)
    assert.has_error(function() store.vitals:now().health = 1 end)

    local attrs = { Health = 240, MaxHealth = 300, Hunger = 80, MaxHunger = 100, FishCoin = 15 }
    local attr_signals = {}
    local function get_sig(key)
      attr_signals[key] = attr_signals[key] or Eui.Signal()
      return attr_signals[key]
    end
    local player = { Name = "LocalPlayer" }
    local character = { Name = "Hero", CameraDistance = 26 }
    local heartbeat = Eui.Signal()
    local remote_events = {}
    local function get_re(name)
      remote_events[name] = remote_events[name] or { OnClientEvent = Eui.Signal() }
      return remote_events[name]
    end

    local binding = writer:bind_host({
      get_re = get_re,
      heartbeat = heartbeat,
      get_server_time = function() return 11 end,
      get_local_player = function() return player end,
      get_local_character = function() return character end,
      read_player_attr = function(_, key) return attrs[key] end,
      read_char_attr = function(char, key) return char[key] end,
      get_player_attr_signal = function(_, key) return get_sig(key) end,
    })

    -- 初始属性立即同步
    assert.same({ health = 240, maxHealth = 300, hunger = 80, maxHunger = 100 }, {
      health = store.vitals:now().health,
      maxHealth = store.vitals:now().maxHealth,
      hunger = store.vitals:now().hunger,
      maxHunger = store.vitals:now().maxHunger,
    })
    assert.equals(15, store.coin:now())
    assert.equals(1, attr_signals.FishCoin:Count())
    assert.equals(1, attr_signals.Health:Count())

    -- 属性信号更新血量/饥饿/金币
    attrs.Health = 180
    attrs.Hunger = 45
    attr_signals.Health:Fire()
    assert.equals(180, store.vitals:now().health)
    assert.equals(45, store.vitals:now().hunger)

    attrs.FishCoin = 99
    attr_signals.FishCoin:Fire()
    assert.equals(99, store.coin:now())

    -- ItemBarState.coin 同步汇聚到 store.coin
    remote_events.ItemBarState.OnClientEvent:Fire({ slots = {}, coin = 250 })
    assert.equals(250, store.coin:now())

    -- 后续 Health / Hunger 属性信号触发时，不得用陈旧 attrs.FishCoin(99) 回退已更新的 store.coin(250)
    attrs.Hunger = 44
    attr_signals.Hunger:Fire()
    assert.equals(44, store.vitals:now().hunger)
    assert.equals(250, store.coin:now())

    attrs.Health = 175
    attr_signals.Health:Fire()
    assert.equals(175, store.vitals:now().health)
    assert.equals(250, store.coin:now())

    -- Heartbeat 同步 local_character 与归一化 camera_distance
    heartbeat:Fire(0.016)
    assert.equals(character, store.local_character:now())
    assert.equals(26, store.camera_distance:now())

    -- 超上限非法数值被 BodyScale.Sanitize 钳制到 39，NaN 变为 nil
    character.CameraDistance = 999
    heartbeat:Fire(0.016)
    assert.equals(39, store.camera_distance:now())

    character.CameraDistance = 0 / 0
    heartbeat:Fire(0.016)
    assert.is_nil(store.camera_distance:now())

    -- 释放宿主绑定后所有属性信号与心跳连接归零
    binding:dispose()
    assert.equals(0, heartbeat:Count())
    assert.equals(0, attr_signals.FishCoin:Count())
    assert.equals(0, attr_signals.Health:Count())
  end)

  it("CameraZoomView 挂载到 RootView：跟随角色缩放、检测手动改距让权、角色切换与销毁时恢复原始距离", function()
    local store, writer = ClientStore.new({ initial_now = 0 })
    local root_node = Eui.Node({ Name = "UIRoot" })
    local first_char = { Name = "CharA" }
    local second_char = { Name = "CharB" }
    local camera = { Distance = 8, TrackingUnit = first_char }

    local view = RootView.mount(root_node, store, {
      hud = {
        CameraZoomView.spec({
          get_camera = function() return camera end,
        }),
      },
    })
    assert.is_nil(view.root.fault)

    -- 1) 首角色应用体型缩放距离（52 被钳制为 39）
    writer:update_camera_target(first_char, 52)
    assert.equals(39, camera.Distance)

    -- 2) 玩家手动改相机距离 → 下一帧检测并让权，不再覆盖
    camera.Distance = 12
    writer:step_clock(0.016, 0.016)
    assert.equals(12, camera.Distance)
    writer:update_camera_target(first_char, 26)
    assert.equals(12, camera.Distance)

    -- 3) 切换新角色：旧相机因已让权保留 12 作为新基准，新角色接管后更新为 26
    camera.TrackingUnit = second_char
    writer:update_camera_target(second_char, 26)
    assert.equals(26, camera.Distance)

    -- 4) 根 UI 销毁 → Spoke on_cleanup 自动恢复原始距离 12
    root_node:Destroy()
    assert.is_false(view.is_alive:now())
    assert.equals(12, camera.Distance)
  end)

  it("CameraZoomView 仅在活跃 Phase 内订阅 on_frame，关屏、无角色或让权后停止逐帧空转", function()
    local store, writer = ClientStore.new({ initial_now = 0 })
    local root_node = Eui.Node({ Name = "UIRoot" })
    local char = { Name = "Hero" }
    local camera = { Distance = 8, TrackingUnit = char }
    local camera_reads = 0

    local view = RootView.mount(root_node, store, {
      hud = {
        CameraZoomView.spec({
          get_camera = function()
            camera_reads = camera_reads + 1
            return camera
          end,
        }),
      },
    })
    assert.is_nil(view.root.fault)

    -- 1) 初始无角色：推进多帧不应触发 on_frame 空转
    local reads_init = camera_reads
    writer:step_clock(0.016, 0.016)
    writer:step_clock(0.016, 0.032)
    assert.equals(reads_init, camera_reads)

    -- 2) 绑定角色后活跃期订阅 on_frame；关屏 hud_visible=false 后自动退订停止空转
    writer:update_camera_target(char, 26)
    assert.equals(26, camera.Distance)
    writer:set_hud_visible(false)
    local reads_hidden = camera_reads
    writer:step_clock(0.016, 0.048)
    writer:step_clock(0.016, 0.064)
    assert.equals(reads_hidden, camera_reads)

    -- 3) 恢复开屏后重新进入活跃期，手动改距触发让权后立即退订停止空转
    writer:set_hud_visible(true)
    camera.Distance = 15
    writer:step_clock(0.016, 0.080)
    local reads_yielded = camera_reads
    writer:step_clock(0.016, 0.096)
    writer:step_clock(0.016, 0.112)
    assert.equals(reads_yielded, camera_reads)

    view:dispose()
  end)
end)
