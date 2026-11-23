-- #296 客户端只读响应式状态仓库与统一 Spoke 根视图树主干契约测试（ADR-0032）
-- 失败方式先列：
--   1. EUI 测试双缺少 Destroying 信号或重复触发 → spoke_eggy.behaviour 无法随宿主 UI 销毁自动清理整棵视图树；
--   2. 只读状态仓库暴露内部写入入口或允许视图侧篡改字段 → 破坏单向响应式数据流；
--   3. 服务端下行 RemoteEvent 或本地位置/钓鱼区传感器未归一化/批处理写入 → 视图观察到坏数据或撕裂中间态；
--   4. 根视图树在弹窗互斥切换、蒙版关闭、Dock 项移除、重连重置或根 UI 销毁后遗留子节点或点击信号连接 → 悬空节点与重复监听。

local Eui = require("tests.support.eui_double")
local spoke_eggy = require("common.packages.spoke_eggy.api")

describe("客户端 Spoke 主干契约（#296）", function()
  describe("EUI 测试双 Destroying 生命周期与 spoke_eggy.behaviour 联动", function()
    it("宿主 UI 节点销毁与父级级联销毁均自动触发 spoke_eggy 清理且幂等", function()
      local root = Eui.Node({ Name = "UIRoot" })
      local panel = Eui.Node({ Name = "SpokePanel", Parent = root })
      local btn = Eui.Node({ Name = "CloseBtn", Parent = panel, TouchEnabled = true })

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
      assert.is_true(Eui.Click(btn))
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

  describe("客户端只读响应式状态仓库（ClientStore）", function()
    it("只读状态面禁止视图层调用写入接口或篡改字段，且隔离时钟驱动接口", function()
      local ClientStore = require("client.Store.ClientStore")
      local store, writer = ClientStore.new({ initial_now = 10 })

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
      assert.same({ stand = "fishPond" }, store.modal_payload:now())
    end)

    it("宿主绑定一次性连接下行 RemoteEvent 与 Heartbeat，归一化写入并在单次 batch 内同步位置与钓鱼区", function()
      local spoke = require("common.packages.spoke.api")
      local ClientStore = require("client.Store.ClientStore")
      local store, writer = ClientStore.new({ initial_now = 100 })

      local remote_events = {}
      local function get_re(name)
        if not remote_events[name] then
          remote_events[name] = { OnClientEvent = Eui.Signal() }
        end
        return remote_events[name]
      end

      local heartbeat = Eui.Signal()
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
      remote_events.DamageNotice.OnClientEvent:Fire({ amount = 35, crit = true })
      assert.equals("DamageNotice", received_events[#received_events].channel)
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

      -- 3) 释放宿主绑定后断开全部连接，后续事件不再写入仓库
      binding:dispose()
      binding:dispose() -- 幂等
      assert.equals(0, heartbeat:Count())
      assert.equals(0, remote_events.SurvivalState.OnClientEvent:Count())
      assert.equals(0, remote_events.ItemBarState.OnClientEvent:Count())

      remote_events.SurvivalState.OnClientEvent:Fire({ phase = "dead", endsAt = 150 })
      char_pos = { x = 0, y = 0, z = 0 }
      server_now = 105.0
      heartbeat:Fire(3.0)
      assert.equals("downed", store.survival:now().phase)
      assert.equals("shrimpPond", store.zone_id:now())
      assert.equals(102, store.clock.second:now())

      tree:dispose()
    end)
  end)

  describe("统一 Spoke 根视图树主干（RootView）", function()
    local function make_factory()
      local created = {}
      local function create_node(kind, props)
        props = props or {}
        local node = Eui.Node({
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
      local ClientStore = require("client.Store.ClientStore")
      local RootView = require("client.Views.RootView")
      local store, writer = ClientStore.new({ initial_now = 0 })
      local root_node = Eui.Node({ Name = "UIRoot" })
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

      local view = RootView.mount(root_node, store, {
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
      assert.is_true(Eui.Click(shop_btn))
      assert.equals(1, modal_clicks.shop)

      writer:open_modal("compendium")
      local comp_btn = modal_nodes.compendium
      assert.is_true(shop_btn.Destroyed)
      assert.equals(0, shop_btn.OnClicked:Count())
      assert.is_nil(comp_btn.Destroyed)
      assert.equals(1, comp_btn.OnClicked:Count())
      assert.is_true(Eui.Click(comp_btn))
      assert.equals(1, modal_clicks.compendium)
      -- 弹窗切换不重建常驻 HUD
      assert.equals(1, hud_mounts)

      -- 点击弹窗内部的关闭按钮（回调中同步卸载自身 Phase）应干净销毁全部节点与连接
      local comp_close = modal_nodes.compendium_close
      assert.is_true(Eui.Click(comp_close))
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
      assert.is_true(Eui.Click(revive_btn))
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
      assert.is_true(Eui.Click(row10))
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
      local ClientStore = require("client.Store.ClientStore")
      local RootView = require("client.Views.RootView")
      local store, writer = ClientStore.new({ initial_now = 0 })
      local root_node = Eui.Node({ Name = "UIRoot" })
      local create_node, created = make_factory()

      local hud_btn = nil
      local hud_clicks = 0
      local modal_btn = nil
      local modal_clicks = 0

      local view = RootView.mount(root_node, store, {
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
      assert.is_true(Eui.Click(second_hud_btn))
      assert.equals(1, hud_clicks)

      -- 重连后重新打开弹窗，只绑定 1 份监听
      writer:open_modal("lottery")
      local second_modal_btn = modal_btn
      assert.equals(1, second_modal_btn.OnClicked:Count())
      assert.is_true(Eui.Click(second_modal_btn))
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

    it("client/main.lua 已接入 SpokeClock、ClientStore 与 RootView 主干", function()
      local fs = require("tests.support.fs_fixture")
      local src = assert(fs.slurp("client/main.lua"), "读不到 client/main.lua")
      assert.is_truthy(src:find("common.SpokeClock", 1, true))
      assert.is_truthy(src:find("client.Store.ClientStore", 1, true))
      assert.is_truthy(src:find("client.Views.RootView", 1, true))
    end)
  end)
end)
