-- #296 客户端只读响应式状态仓库与统一 Spoke 根视图树主干契约测试（ADR-0032）
-- 失败方式先列：
--   1. EUI 测试双缺少 Destroying 信号或重复触发 → spoke_eggy.behaviour 无法随宿主 UI 销毁自动清理整棵视图树；
--   2. 只读状态仓库暴露内部写入入口或允许视图侧篡改字段 → 破坏单向响应式数据流；
--   3. 服务端下行 RemoteEvent 或本地位置/钓鱼区传感器未归一化/批处理写入 → 视图观察到坏数据或撕裂中间态；
--   4. 根视图树在弹窗互斥切换、蒙版关闭、Dock 项移除、重连重置或根 UI 销毁后遗留子节点或点击信号连接 → 悬空节点与重复监听。

local eui = require("tests.support.eui_double")
local spoke_eggy = require("common.packages.spoke_eggy.api")

describe("客户端 Spoke 主干契约（#296）", function()
  describe("EUI 测试双 Destroying 生命周期与 spoke_eggy.behaviour 联动", function()
    it("宿主 UI 节点销毁与父级级联销毁均自动触发 spoke_eggy 清理且幂等", function()
      local root = eui.Node({ Name = "UIRoot" })
      local panel = eui.Node({ Name = "SpokePanel", Parent = root })
      local btn = eui.Node({ Name = "CloseBtn", Parent = panel, TouchEnabled = true })

      local alive_history = {}
      local cleanup_count = 0
      local clicks = 0

      local behaviour = spoke_eggy.behaviour(panel, function(s, self)
        s:effect(function(es)
          alive_history[#alive_history + 1] = es:d(self.is_alive)
        end)
        local click_conn = btn.OnClicked:Connect(function()
          clicks = clicks + 1
        end)
        s:on_cleanup(function()
          cleanup_count = cleanup_count + 1
          click_conn:Disconnect()
        end)
      end, { name = "PanelBehaviour" })

      assert.is_nil(behaviour.root.fault)
      assert.is_true(behaviour.is_alive:now())
      assert.same({ true }, alive_history)
      assert.is_true(eui.Click(btn))
      assert.equals(1, clicks)

      -- 销毁父节点时，级联触发子节点 Destroying，spoke_eggy 先翻 is_alive 再拆树清理
      local parent_at_destroying = "unseen"
      local name_at_destroying = nil
      local observer_calls = 0
      local obs_conn = panel.Destroying:Connect(function()
        observer_calls = observer_calls + 1
        parent_at_destroying = panel.Parent
        name_at_destroying = panel.Name
      end)

      root:Destroy()

      assert.is_true(root.Destroyed)
      assert.is_true(panel.Destroyed)
      assert.is_true(btn.Destroyed)
      assert.is_nil(parent_at_destroying)
      assert.equals("SpokePanel", name_at_destroying)
      assert.equals(1, observer_calls)
      assert.is_false(behaviour.is_alive:now())
      assert.same({ true, false }, alive_history)
      assert.equals(1, cleanup_count)
      assert.equals(0, btn.OnClicked:Count())

      -- 重复 Destroy 幂等，不会再次触发 Destroying 或 cleanup
      panel:Destroy()
      root:Destroy()
      assert.equals(1, observer_calls)
      assert.equals(1, cleanup_count)

      obs_conn:Disconnect()
    end)
  end)

  describe("客户端只读响应式状态仓库（client_store）", function()
    it("只读状态面禁止视图层调用写入接口或篡改字段，且隔离时钟驱动接口", function()
      local client_store = require("client.store.client_store")
      local store, writer = client_store.new({ initial_now = 10 })

      -- 视图侧只读面不暴露任何写入方法或写侧引用
      assert.is_nil(store.writer)
      assert.is_nil(store.ingest_event)
      assert.is_nil(store.update_spatial)
      assert.is_nil(store.reset_session)
      assert.is_nil(store.survival.set)
      assert.is_nil(store.survival.update)
      assert.is_nil(store.position.set)
      assert.is_nil(store.zone_id.set)
      assert.is_nil(store.active_modal.set)
      assert.is_nil(store.on_server_event.invoke)
      assert.is_nil(store.on_reconnect.invoke)
      assert.is_nil(store.clock.step)
      assert.is_nil(store.clock.advance)
      assert.is_nil(store.clock.second.set)

      -- 视图侧尝试覆写只读表或只读信号字段直接抛错
      assert.has_error(function() store.survival = {} end)
      assert.has_error(function() store.survival.set = function() end end)
      assert.has_error(function() store.on_server_event.invoke = function() end end)
      assert.has_error(function() store.clock.step = function() end end)

      -- 写侧正常可写，且写入后视图只读面同步可读
      assert.equals(10, store.clock.now())
      writer:open_modal("shop", { stand = "fishPond" })
      assert.equals("shop", store.active_modal:now())
      assert.equals("fishPond", store.modal_payload:now().stand)

      -- 视图侧禁止就地篡改嵌套快照/位置/蒙版表，且不污染内部状态
      writer:set_overlay("aim", true)
      writer:update_spatial({ x = 10, y = 2, z = 5 }, {
        fishPond = { Boundary = { MinX = -50, MaxX = 50, MinZ = -50, MaxZ = 50 } },
      })
      writer:ingest_event("PartyState", {
        state = "party",
        partyId = 3,
        members = { { userId = 1, name = "甲", health = 300, maxHealth = 300 } },
      })

      assert.has_error(function() store.survival:now().phase = "dead" end)
      assert.has_error(function() store.overlays:now().aim = false end)
      assert.has_error(function() store.overlays:now().injected = true end)
      assert.has_error(function() store.position:now().x = 999 end)
      assert.has_error(function() store.modal_payload:now().stand = "hacked" end)
      assert.has_error(function() store.party:now().members[1].health = 0 end)

      assert.equals("alive", store.survival:now().phase)
      assert.is_true(store.overlays:now().aim)
      assert.is_nil(store.overlays:now().injected)
      assert.equals(10, store.position:now().x)
      assert.equals("fishPond", store.modal_payload:now().stand)
      assert.equals(300, store.party:now().members[1].health)
    end)

    it("宿主绑定一次性连接下行 RemoteEvent 与 Heartbeat，归一化写入并在单次 batch 内同步位置与钓鱼区", function()
      local spoke = require("common.packages.spoke.api")
      local client_store = require("client.store.client_store")
      local store, writer = client_store.new({ initial_now = 100 })

      local remote_events = {}
      local function get_re(name)
        if not remote_events[name] then
          remote_events[name] = { OnClientEvent = eui.Signal() }
        end
        return remote_events[name]
      end

      local heartbeat = eui.Signal()
      local server_now = 100.0
      local char_pos = nil
      local zones = {
        fishPond = { Boundary = { MinX = -50, MaxX = 50, MinZ = -50, MaxZ = 50 } },
        shrimpPond = { Boundary = { MinX = 100, MaxX = 200, MinZ = -50, MaxZ = 50 } },
      }

      local binding = writer:bind_host({
        get_re = get_re,
        heartbeat = heartbeat,
        get_server_time = function() return server_now end,
        get_local_position = function() return char_pos end,
        get_zones = function() return zones end,
      })

      local spatial_renders = {}
      local survival_phases = {}
      local received_events = {}
      local tree = spoke.SpokeTree.spawn("StoreObserver", spoke.Effect.new(function(s)
        s:effect(function(es)
          local pos = es:d(store.position)
          local zid = es:d(store.zone_id)
          local zname = es:d(store.zone_name)
          spatial_renders[#spatial_renders + 1] = {
            x = pos and pos.x or nil,
            zone_id = zid,
            zone_name = zname,
          }
        end)
        s:effect(function(es)
          local surv = es:d(store.survival)
          survival_phases[#survival_phases + 1] = surv.phase
        end)
        s:subscribe(store.on_server_event, function(ev)
          received_events[#received_events + 1] = ev
        end)
      end))

      assert.same({ { x = nil, zone_id = nil, zone_name = nil } }, spatial_renders)
      assert.same({ "alive" }, survival_phases)

      -- 1) 服务端合法快照写入，坏载荷被忽略不破坏上次可信状态
      remote_events.SurvivalState.OnClientEvent:Fire({ phase = "downed", endsAt = 115 })
      assert.same({ "alive", "downed" }, survival_phases)
      assert.equals(115, store.survival:now().endsAt)

      remote_events.SurvivalState.OnClientEvent:Fire("bad-payload")
      remote_events.SurvivalState.OnClientEvent:Fire({ phase = 12345 })
      assert.equals("downed", store.survival:now().phase)
      assert.same({ "alive", "downed" }, survival_phases)

      remote_events.PartyState.OnClientEvent:Fire({
        state = "party",
        partyId = 7,
        members = {
          { userId = 1, name = "甲", health = 300, maxHealth = 300, self = true },
          { userId = 2, name = "乙", health = 120, maxHealth = 300 },
        },
      })
      assert.equals("party", store.party:now().state)
      assert.equals(2, #store.party:now().members)

      remote_events.PartyState.OnClientEvent:Fire({ state = "party", members = "invalid" })
      assert.equals("party", store.party:now().state)
      assert.equals(2, #store.party:now().members)

      remote_events.ItemBarState.OnClientEvent:Fire({ coins = 250, selectedSlot = 2 })
      assert.equals(250, store.item_bar:now().coins)
      assert.equals(2, store.item_bar:now().selectedSlot)

      -- 离散通知/回执走 on_server_event 只读触发
      remote_events.damage_notice.OnClientEvent:Fire({ amount = 35, crit = true })
      assert.equals("damage_notice", received_events[#received_events].channel)
      assert.equals(35, received_events[#received_events].payload.amount)

      -- 2) Heartbeat 推进时钟并同步位置与所属钓鱼区，单次 batch 内合并刷新（无撕裂中间态）
      char_pos = { x = 10, y = 2, z = 5 }
      server_now = 101.0
      heartbeat:Fire(1.0)
      assert.equals(101, store.clock.second:now())
      assert.same({
        { x = nil, zone_id = nil, zone_name = nil },
        { x = 10, zone_id = "fishPond", zone_name = "鱼塘" },
      }, spatial_renders)

      -- 相同坐标不重复触发重跑
      server_now = 101.2
      heartbeat:Fire(0.2)
      assert.equals(2, #spatial_renders)

      -- 非法 NaN 坐标被忽略，不破坏上次有效定位
      char_pos = { x = 0 / 0, y = 0, z = 0 }
      server_now = 101.4
      heartbeat:Fire(0.2)
      assert.equals("fishPond", store.zone_id:now())
      assert.equals(2, #spatial_renders)

      -- 跨区移动到虾池，一次 batch 同时更新位置与区域
      char_pos = { x = 150, y = 2, z = 0 }
      server_now = 102.0
      heartbeat:Fire(0.6)
      assert.same({ x = 150, zone_id = "shrimpPond", zone_name = "虾池" }, spatial_renders[#spatial_renders])
      assert.equals(3, #spatial_renders)

      -- 卡顿单帧跨多秒：spoke_clock 须逐秒排空，前一秒卸载的 Phase 在后续整秒不再误跑
      local ticking = spoke.State.new("ticking", true)
      local ticks_left = 2
      local phase_secs = {}
      local countdown_tree = spoke.SpokeTree.spawn("StutterCountdown", spoke.Effect.new(function(s)
        s:phase("ActiveCountdown", ticking, function(ps)
          ps:subscribe(store.clock.on_second, function(sec)
            phase_secs[#phase_secs + 1] = sec
            ticks_left = ticks_left - 1
            if ticks_left <= 0 then
              ticking:set(false)
            end
          end)
        end)
      end))
      server_now = 106.0
      heartbeat:Fire(4.0)
      assert.equals(106, store.clock.second:now())
      assert.is_false(ticking:now())
      assert.same({ 103, 104 }, phase_secs)
      countdown_tree:dispose()

      -- 3) 释放宿主绑定后断开全部连接，后续事件不再写入仓库
      binding:dispose()
      binding:dispose() -- 幂等
      assert.equals(0, heartbeat:Count())
      assert.equals(0, remote_events.SurvivalState.OnClientEvent:Count())
      assert.equals(0, remote_events.ItemBarState.OnClientEvent:Count())

      remote_events.SurvivalState.OnClientEvent:Fire({ phase = "dead", endsAt = 150 })
      char_pos = { x = 0, y = 0, z = 0 }
      server_now = 110.0
      heartbeat:Fire(4.0)
      assert.equals("downed", store.survival:now().phase)
      assert.equals("shrimpPond", store.zone_id:now())
      assert.equals(106, store.clock.second:now())

      tree:dispose()
    end)
  end)

  describe("统一 Spoke 根视图树主干（root_view）", function()
    local function make_factory()
      local created = {}
      local function create_node(kind, props)
        props = props or {}
        local node = eui.Node({
          Name = props.Name or (kind .. "_" .. tostring(#created + 1)),
          Kind = kind,
          Parent = props.Parent,
          Visible = props.Visible,
          Text = props.Text,
          TouchEnabled = props.TouchEnabled,
        })
        created[#created + 1] = node
        return node
      end
      return create_node, created
    end

    it("承载常驻 HUD、互斥模态弹窗 Phase、覆盖蒙版 Phase 与动态集合 Dock，切换与移除零残留", function()
      local client_store = require("client.store.client_store")
      local root_view = require("client.views.root_view")
      local store, writer = client_store.new({ initial_now = 0 })
      local root_node = eui.Node({ Name = "UIRoot" })
      local create_node = make_factory()

      local hud_mounts = 0
      local hud_coin_node = nil
      local modal_nodes = {}
      local modal_clicks = {}
      local overlay_nodes = {}
      local overlay_clicks = 0
      local dock_mounts = {}
      local dock_nodes = {}
      local dock_clicks = {}

      local view = root_view.mount(root_node, store, {
        create_node = create_node,
        hud = {
          {
            name = "CoinHud",
            mount = function(s, ctx)
              hud_mounts = hud_mounts + 1
              local label = ctx.create_node(s, "EUITextLabel", { Name = "HudCoinLabel" })
              hud_coin_node = label
              s:effect(function(es)
                local bar = es:d(ctx.store.item_bar)
                label.Text = tostring(bar and bar.coins or 0)
              end)
            end,
          },
        },
        modals = {
          shop = function(s, ctx)
            local btn = ctx.create_node(s, "EUIButton", { Name = "ShopBuyBtn", TouchEnabled = true })
            modal_nodes.shop = btn
            ctx.connect(s, btn.OnClicked, function()
              modal_clicks.shop = (modal_clicks.shop or 0) + 1
            end)
          end,
          compendium = function(s, ctx)
            local btn = ctx.create_node(s, "EUIButton", { Name = "CompendiumTabBtn", TouchEnabled = true })
            local close_btn = ctx.create_node(s, "EUIButton", { Name = "CompendiumCloseBtn", TouchEnabled = true })
            modal_nodes.compendium = btn
            modal_nodes.compendium_close = close_btn
            ctx.connect(s, btn.OnClicked, function()
              modal_clicks.compendium = (modal_clicks.compendium or 0) + 1
            end)
            ctx.connect(s, close_btn.OnClicked, function()
              writer:close_modal("compendium")
            end)
          end,
        },
        overlays = {
          survival = {
            when = function(ms, st)
              return ms:d(st.survival).phase ~= "alive"
            end,
            mount = function(s, ctx)
              local btn = ctx.create_node(s, "EUIButton", { Name = "ReviveBtn", TouchEnabled = true })
              overlay_nodes.survival = btn
              ctx.connect(s, btn.OnClicked, function()
                overlay_clicks = overlay_clicks + 1
              end)
            end,
          },
          aim = {
            mount = function(s, ctx)
              overlay_nodes.aim = ctx.create_node(s, "EUILayout", { Name = "AimOverlay" })
            end,
          },
        },
        docks = {
          teammates = {
            items = function(ms, st)
              return ms:d(st.party).members or {}
            end,
            key_of = function(member)
              return "u:" .. tostring(member.userId)
            end,
            mount = function(s, ctx, item_sig, key)
              dock_mounts[key] = (dock_mounts[key] or 0) + 1
              local btn = ctx.create_node(s, "EUIButton", { Name = "Row_" .. key, TouchEnabled = true })
              dock_nodes[key] = btn
              s:effect(function(es)
                local m = es:d(item_sig)
                btn.Text = string.format("%s:%s", m.name, tostring(m.health or 0))
              end)
              ctx.connect(s, btn.OnClicked, function()
                dock_clicks[key] = (dock_clicks[key] or 0) + 1
              end)
            end,
          },
        },
      })

      assert.is_nil(view.root.fault)
      assert.equals(1, hud_mounts)
      assert.equals("0", hud_coin_node.Text)

      -- 1) 常驻 HUD 响应仓库变化
      writer:ingest_event("ItemBarState", { coins = 88 })
      assert.equals("88", hud_coin_node.Text)
      assert.equals(1, hud_mounts)

      -- 2) 互斥模态弹窗：打开 shop -> 切到 compendium -> 关闭
      writer:open_modal("shop")
      local shop_btn = modal_nodes.shop
      assert.is_truthy(shop_btn)
      assert.is_nil(shop_btn.Destroyed)
      assert.equals(1, shop_btn.OnClicked:Count())
      assert.is_true(eui.Click(shop_btn))
      assert.equals(1, modal_clicks.shop)

      writer:open_modal("compendium")
      local comp_btn = modal_nodes.compendium
      assert.is_true(shop_btn.Destroyed)
      assert.equals(0, shop_btn.OnClicked:Count())
      assert.is_nil(comp_btn.Destroyed)
      assert.equals(1, comp_btn.OnClicked:Count())
      assert.is_true(eui.Click(comp_btn))
      assert.equals(1, modal_clicks.compendium)
      -- 弹窗切换不重建常驻 HUD
      assert.equals(1, hud_mounts)

      -- 点击弹窗内部的关闭按钮（回调中同步卸载自身 Phase）应干净销毁全部节点与连接
      local comp_close = modal_nodes.compendium_close
      assert.is_true(eui.Click(comp_close))
      assert.is_nil(store.active_modal:now())
      assert.is_true(comp_btn.Destroyed)
      assert.is_true(comp_close.Destroyed)
      assert.equals(0, comp_btn.OnClicked:Count())
      assert.equals(0, comp_close.OnClicked:Count())

      -- 3) 覆盖蒙版：业务状态条件与显式 overlays 均能对称建拆
      writer:ingest_event("SurvivalState", { phase = "downed", endsAt = 15 })
      local revive_btn = overlay_nodes.survival
      assert.is_truthy(revive_btn)
      assert.is_nil(revive_btn.Destroyed)
      assert.equals(1, revive_btn.OnClicked:Count())
      assert.is_true(eui.Click(revive_btn))
      assert.equals(1, overlay_clicks)

      writer:set_overlay("aim", true)
      local aim_node = overlay_nodes.aim
      assert.is_truthy(aim_node)
      assert.is_nil(aim_node.Destroyed)

      writer:ingest_event("SurvivalState", { phase = "alive" })
      assert.is_true(revive_btn.Destroyed)
      assert.equals(0, revive_btn.OnClicked:Count())
      assert.is_nil(aim_node.Destroyed)

      writer:set_overlay("aim", false)
      assert.is_true(aim_node.Destroyed)

      -- 4) 动态集合 Dock：新增、同身份原地刷新（不重建节点）、移除自动销毁与断开连接
      writer:ingest_event("PartyState", {
        state = "party",
        partyId = 1,
        members = {
          { userId = 10, name = "乙", health = 300, maxHealth = 300 },
          { userId = 20, name = "丙", health = 150, maxHealth = 300 },
        },
      })
      local row10 = dock_nodes["u:10"]
      local row20 = dock_nodes["u:20"]
      assert.equals("乙:300", row10.Text)
      assert.equals("丙:150", row20.Text)
      assert.equals(1, dock_mounts["u:10"])
      assert.equals(1, row10.OnClicked:Count())
      assert.is_true(eui.Click(row10))
      assert.equals(1, dock_clicks["u:10"])

      -- 乙掉血、丙离队：乙复用原节点刷新，丙节点销毁且信号断开
      writer:ingest_event("PartyState", {
        state = "party",
        partyId = 1,
        members = {
          { userId = 10, name = "乙", health = 120, maxHealth = 300 },
        },
      })
      assert.equals(row10, dock_nodes["u:10"])
      assert.equals(1, dock_mounts["u:10"])
      assert.equals("乙:120", row10.Text)
      assert.is_true(row20.Destroyed)
      assert.equals(0, row20.OnClicked:Count())

      view:dispose()
    end)

    it("重连重置与根 UI 节点销毁均清空全部动态子节点与点击信号连接，零悬空与重复监听", function()
      local client_store = require("client.store.client_store")
      local root_view = require("client.views.root_view")
      local store, writer = client_store.new({ initial_now = 0 })
      local root_node = eui.Node({ Name = "UIRoot" })
      local create_node, created = make_factory()

      local hud_btn = nil
      local hud_clicks = 0
      local modal_btn = nil
      local modal_clicks = 0

      local view = root_view.mount(root_node, store, {
        create_node = create_node,
        hud = {
          {
            name = "QuickBtnHud",
            mount = function(s, ctx)
              local btn = ctx.create_node(s, "EUIButton", { Name = "QuickBtn", TouchEnabled = true })
              hud_btn = btn
              ctx.connect(s, btn.OnClicked, function()
                hud_clicks = hud_clicks + 1
              end)
            end,
          },
        },
        modals = {
          lottery = function(s, ctx)
            local btn = ctx.create_node(s, "EUIButton", { Name = "DrawBtn", TouchEnabled = true })
            modal_btn = btn
            ctx.connect(s, btn.OnClicked, function()
              modal_clicks = modal_clicks + 1
            end)
          end,
        },
      })

      writer:open_modal("lottery")
      local first_hud_btn = hud_btn
      local first_modal_btn = modal_btn
      assert.equals(1, first_hud_btn.OnClicked:Count())
      assert.equals(1, first_modal_btn.OnClicked:Count())

      -- 重连重置：旧轮 HUD 与弹窗节点全部销毁、连接归零，新轮以干净状态重新挂载
      writer:reset_session("reconnect")
      assert.is_true(first_hud_btn.Destroyed)
      assert.equals(0, first_hud_btn.OnClicked:Count())
      assert.is_true(first_modal_btn.Destroyed)
      assert.equals(0, first_modal_btn.OnClicked:Count())
      assert.is_nil(store.active_modal:now())

      local second_hud_btn = hud_btn
      assert.are_not.equal(first_hud_btn, second_hud_btn)
      assert.is_nil(second_hud_btn.Destroyed)
      assert.equals(1, second_hud_btn.OnClicked:Count())
      assert.is_true(eui.Click(second_hud_btn))
      assert.equals(1, hud_clicks)

      -- 重连后重新打开弹窗，只绑定 1 份监听
      writer:open_modal("lottery")
      local second_modal_btn = modal_btn
      assert.equals(1, second_modal_btn.OnClicked:Count())
      assert.is_true(eui.Click(second_modal_btn))
      assert.equals(1, modal_clicks)

      -- 宿主根 UI 节点销毁 → spoke_eggy.behaviour 自动销毁整棵根视图树
      root_node:Destroy()
      assert.is_false(view.is_alive:now())
      assert.is_nil(view.root.fault)
      for _, node in ipairs(created) do
        assert.is_true(node.Destroyed, "根 UI 销毁后不得残留动态子节点: " .. tostring(node.Name))
        assert.equals(0, node.OnClicked:Count(), "根 UI 销毁后不得残留点击信号连接: " .. tostring(node.Name))
      end
    end)

    it("client/main.lua 在宿主测试双下真实装配只读 ClientSpoke、绑定事件传感并挂载 root_view", function()
      local stub_modules = {
        "common.zone_markers",
        "common.re_util",
        "common.util",
        "client.game_ui",
        "client.LocalMgrUtil",
        "client.LocalMotorUnitCtrl",
        "client.LocalLoot",
        "client.views.lottery_view",
        "client.views.blindbox_view",
        "client.views.platform_shop_view",
        "client.views.lottery_interaction",
        "client.views.ferry_view",
        "client.views.GarBiteWarning",
        "client.packages.ability_system.api",
        "client.store.client_store",
        "client.views.root_view",
        "client.views.camera_zoom_view",
        "client.views.main_hud_vitals_view",
      }
      local saved_loaded = {}
      for _, name in ipairs(stub_modules) do
        saved_loaded[name] = package.loaded[name]
      end
      local saved_globals = {
        game = rawget(_G, "game"),
        Vector2 = rawget(_G, "Vector2"),
        Color = rawget(_G, "Color"),
        game_ui = rawget(_G, "game_ui"),
        MgrGameUI = rawget(_G, "MgrGameUI"),
        ClientSpoke = rawget(_G, "ClientSpoke"),
        PlatformShop = rawget(_G, "PlatformShop"),
      }

      local heartbeat = eui.Signal()
      local remote_events = {}
      local server_now = 50.0
      local char_pos = { x = 12, y = 2, z = 8 }
      local ui_root = eui.Node({ Name = "MainUIRoot" })
      local created_hud_nodes = {}
      local mounted_view
      local mounted_options
      local fired = {}
      local zones = {
        fishPond = { Boundary = { MinX = -50, MaxX = 50, MinZ = -50, MaxZ = 50 } },
      }
      local noop = function() end
      local noop_module = { Start = noop }

      local ok, err = pcall(function()
        _G.Vector2 = { New = function(x, y) return { x = x, y = y } end }
        _G.Color = { New = function(...) return { ... } end }
        package.loaded["common.zone_markers"] = { Start = noop, Zones = zones }
        package.loaded["common.re_util"] = {
          GetRE = function(_, name)
            if not remote_events[name] then
              remote_events[name] = {
                OnClientEvent = eui.Signal(),
                FireServer = function(_, payload)
                  fired[name] = fired[name] or {}
                  fired[name][#fired[name] + 1] = payload
                end,
              }
            end
            return remote_events[name]
          end,
        }
        local game_ui_stub = {
          GetUIRoot = function() return ui_root end,
          GetEuiManager = function()
            return { GetDeviceResolution = function() return { x = 1920, y = 1080 } end }
          end,
        }
        package.loaded["client.game_ui"] = game_ui_stub
        _G.game_ui = game_ui_stub
        package.loaded["client.packages.ability_system.api"] = { StartClientLifecycle = noop }
        package.loaded["common.util"] = nil
        for _, name in ipairs({
          "client.LocalMgrUtil", "client.LocalMotorUnitCtrl",
          "client.LocalLoot",
          "client.views.GarBiteWarning",
        }) do
          package.loaded[name] = noop_module
        end
        local empty_spec = function() return { name = "EconomyEntry", mount = noop } end
        local empty_modal = function() return noop end
        package.loaded["client.views.lottery_view"] = { modal_spec = empty_modal }
        package.loaded["client.views.blindbox_view"] = { entry_spec = empty_spec, modal_spec = empty_modal }
        package.loaded["client.views.platform_shop_view"] = { entry_spec = empty_spec, modal_spec = empty_modal }
        package.loaded["client.views.lottery_interaction"] = { spec = empty_spec }
        package.loaded["client.views.ferry_view"] = { spec = empty_spec, legs_spec = empty_spec }

        -- 强制重新加载真实 client_store / Views 以绑定到 stub 后的 zone_markers / re_util
        package.loaded["client.store.client_store"] = nil
        package.loaded["client.views.root_view"] = nil
        package.loaded["client.views.camera_zoom_view"] = nil
        package.loaded["client.views.main_hud_vitals_view"] = nil
        local root_view_module = require("client.views.root_view")
        local real_mount = root_view_module.mount
        root_view_module.mount = function(rn, st, opts)
          mounted_options = opts
          mounted_view = real_mount(rn, st, opts)
          return mounted_view
        end
        package.loaded["client.views.grill_view"] = nil

        _G.MgrGameUI = {
          HideLiftButton = noop,
          HideNativeHealth = noop,
          OpenScreen = noop,
          StartGM = noop,
        }
        _G.ClientSpoke = nil
        _G.game = {
          GetService = function(_, name)
            if name == "Task" then
              return {
                Spawn = function(_, fn) fn() end,
                Delay = noop,
                Wait = noop,
              }
            end
            if name == "World" then
              return {
                GetServerTime = function() return server_now end,
                FindFirstChild = function() return nil end,
                CreateUnit = function(_, kind, props)
                  props = props or {}
                  local node = eui.Node({
                    Name = props.Name or (kind .. "_" .. tostring(#created_hud_nodes + 1)),
                    Kind = kind,
                    Parent = props.Parent,
                    Visible = props.Visible,
                    Text = props.Text,
                    TouchEnabled = props.TouchEnabled,
                  })
                  created_hud_nodes[#created_hud_nodes + 1] = node
                  return node
                end,
              }
            end
            if name == "RunService" then
              return {
                Heartbeat = heartbeat,
                IsClient = function() return true end,
                IsServer = function() return false end,
              }
            end
            if name == "Players" then
              local players = { LocalPlayer = { Character = { Position = char_pos } } }
              players.GetPlayers = function() return { players.LocalPlayer } end
              return players
            end
            return {}
          end,
        }

        assert(loadfile("client/main.lua"))()

        -- 验证仅暴露只读侧 Store 与 Clock，不暴露 writer
        assert.is_table(_G.ClientSpoke)
        assert.is_nil(_G.ClientSpoke.writer)
        assert.is_nil(_G.ClientSpoke.Writer)
        local cs = _G.ClientSpoke.Store
        assert.has_error(function() cs.survival = {} end)
        assert.has_error(function() cs.survival:now().phase = "dead" end)
        assert.equals(50, _G.ClientSpoke.Clock.second:now())

        -- 验证下行远程事件与 Heartbeat 传感均已接通
        remote_events.ItemBarState.OnClientEvent:Fire({ coins = 321 })
        assert.equals(321, cs.item_bar:now().coins)
        server_now = 51.0
        heartbeat:Fire(1.0)
        assert.equals(51, cs.clock.second:now())
        assert.equals("fishPond", cs.zone_id:now())
        assert.equals("鱼塘", cs.zone_name:now())

        -- 验证 root_view 与 main_hud_vitals_view 已挂载到根 UI 节点并在销毁时自动清理
        assert.is_not_nil(mounted_view)
        assert.is_not_nil(mounted_options)
        assert.is_nil(mounted_view.root.fault, tostring(mounted_view.root.fault))
        for _, modal_id in ipairs({
          "shop", "fisherman", "confirm", "lottery", "blindbox", "platform", "compendium", "story", "gm",
        }) do
          assert.is_function(mounted_options.modals[modal_id], "缺少模态弹窗挂载: " .. modal_id)
        end
        assert.is_function(mounted_options.services.create_scene_node_at)
        assert.is_function(mounted_options.services.create_anchor_scene_node)
        assert.is_function(mounted_options.services.set_overlay)
        mounted_options.services.send_grill({ action = "Takeout" })
        assert.equals("Takeout", fired.GrillAction[1].action)
        assert.is_true(type(fired.GrillAction[1].seq) == "number" and fired.GrillAction[1].seq >= 1)
        remote_events.LootState.OnClientEvent:Fire({ list = { { id = "loot-near", x = 12, y = 2, z = 8 } } })
        mounted_options.services.set_overlay("aim_pickup", true)
        local aim_mask = ui_root:FindFirstChild("AimPickupMask", true)
        assert.is_not_nil(aim_mask)
        assert.is_true(eui.Click(aim_mask))
        assert.same({ action = "Pickup", value = "loot-near" }, fired.ItemBarAction[#fired.ItemBarAction])
        assert.is_nil(ui_root:FindFirstChild("AimPickupMask", true))
        assert.is_true(#created_hud_nodes > 0)
        assert.equals(1, ui_root.Destroying:Count())
        ui_root:Destroy()
        assert.equals(0, ui_root.Destroying:Count())
        for _, node in ipairs(created_hud_nodes) do
          assert.is_true(node.Destroyed, "根 UI 销毁后不得残留主 HUD 节点: " .. tostring(node.Name))
        end
      end)

      for name, value in pairs(saved_loaded) do
        package.loaded[name] = value
      end
      for name, value in pairs(saved_globals) do
        _G[name] = value
      end
      if not ok then
        error(err, 0)
      end
    end)

    it("client_store reset_session 完整重置 shop 状态（含 purchases/upgradeLevels/upgradeLevel）", function()
      local client_store = require("client.store.client_store")
      local store, writer = client_store.new({ initial_now = 10 })
      assert.is_true(writer:ingest_event("ShopResult", {
        ok = true, action = "UpgradeStorage", number = 5, kind = "rod", level = 2, coinAfter = 88,
      }))
      assert.equals(1, store.shop:now().purchases[5])
      assert.equals(2, store.shop:now().upgradeLevels.rod)
      assert.equals(2, store.shop:now().upgradeLevel)
      assert.equals(88, store.coin:now())

      writer:reset_session("reconnect")
      assert.same({}, store.shop:now().purchases)
      assert.same({}, store.shop:now().upgradeLevels)
      assert.equals(0, store.shop:now().upgradeLevel)
      assert.equals(0, store.coin:now())
    end)
  end)
end)
