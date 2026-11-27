-- Issue #367 反向单测：时钟与分辨率显式注入契约，清零回退 0、隐式 Trigger 与 1920x1080 硬编码。
-- 失败方式先列：
--   1. FishTree 缺注入时钟时仍隐式创建 Spoke.Trigger 而不拒绝构造；
--   2. WorldRecords / 客户端视图 / server/main.lua 在时钟异常时静默回退 0 污染缓存年龄、倒计时、进度或入口时钟；
--   3. ViewUtil.get_resolution 或 client/main.lua 在无注入且宿主不可用时仍硬编码返回 1920x1080，或客户端视图在分辨率为 nil 时崩溃。

local Spoke = require("common.packages.spoke.api")
local SpokeClock = require("common.spoke_clock")
local GameCfg = require("common.game_cfg")
local ClientStore = require("client.store.client_store")
local RootView = require("client.views.root_view")
local ViewUtil = require("client.views.view_util")
local AttackView = require("client.views.attack_view")
local ReelOverlayView = require("client.views.reel_overlay_view")
local SurvivalOverlayView = require("client.views.survival_overlay_view")
local FerryView = require("client.views.ferry_view")
local GuideView = require("client.views.guide_view")
local StoryView = require("client.views.story_view")
local SquadView = require("client.views.squad_view")
local MainHudVitalsView = require("client.views.main_hud_vitals_view")
local MainHudActionButtonsView = require("client.views.main_hud_action_buttons_view")
local MainHudBackpackView = require("client.views.main_hud_backpack_view")
local MainHudEquipPopups = require("client.views.main_hud_equip_popups")
local MainHudItemBarView = require("client.views.main_hud_item_bar_view")
local FishTree = require("server.world_host.fish_tree")
local WorldRecords = require("server.world_host.world_records")
local ModifierLeaf = require("server.world_host.modifier_leaf")
local Eui = require("tests.support.eui_double")

local function capture_print()
  local saved = _G.print
  local lines = {}
  _G.print = function(...)
    local parts = {}
    for _, v in ipairs({ ... }) do
      parts[#parts + 1] = tostring(v)
    end
    lines[#lines + 1] = table.concat(parts, "\t")
  end
  return function()
    _G.print = saved
    return lines
  end
end

local function make_node_factory()
  return function(kind, props)
    local node = Eui.node({
      Kind = kind,
      Name = props and props.Name,
      Parent = props and props.Parent,
      Visible = props and props.Visible,
      Text = props and (props.Text or props.ButtonText) or "",
      ButtonText = props and props.ButtonText,
      Position = props and props.Position,
      Size = props and props.Size,
      TouchEnabled = kind == "EUIButton",
    })
    if kind == "EUIButton" then
      node.OnTouchBegan = Eui.Signal()
      node.OnTouchEnded = Eui.Signal()
    end
    return node
  end
end

describe("时钟与分辨率显式注入与失败隔离（#367）", function()
  local saved_globals

  before_each(function()
    saved_globals = {
      Vector2 = rawget(_G, "Vector2"),
      Color = rawget(_G, "Color"),
      game = rawget(_G, "game"),
      REUtil = rawget(_G, "REUtil"),
      RemoteEvent = rawget(_G, "RemoteEvent"),
    }
    _G.Vector2 = { New = function(x, y) return { x = x, y = y } end }
    _G.Color = { New = function(...) return { ... } end }
  end)

  after_each(function()
    _G.Vector2 = saved_globals.Vector2
    _G.Color = saved_globals.Color
    _G.game = saved_globals.game
    _G.REUtil = saved_globals.REUtil
    _G.RemoteEvent = saved_globals.RemoteEvent
  end)

  it("FishTree 缺注入时钟时拒绝构造并报错，不再隐式创建 Trigger", function()
    assert.has_error(function() FishTree.new() end)
    assert.has_error(function() FishTree.new({}) end)
    assert.has_error(function() FishTree.new({ clock = { now = function() return 1 end } }) end)

    local host = setmetatable({ Fish = {}, next_id = 0, held = {}, links = {} }, { __index = FishTree })
    assert.has_error(function() host:frame_clock() end)
    assert.is_nil(host.clock)
  end)

  it("ModifierLeaf.create_entity_store 缺注入 now 函数时直接报错", function()
    assert.has_error(function() ModifierLeaf.create_entity_store({}) end)
    assert.has_error(function() ModifierLeaf.create_entity_store({ now = 123 }) end)
  end)

  it("WorldRecords 缺注入时钟拒绝挂载，运行期异常输出日志且不以 0 污染缓存与到期时间", function()
    local scope = Spoke.Effect.new("TestRecordsNoClock", function() end)
    assert.has_error(function()
      WorldRecords.mount(scope, { clock = nil }, { player_data = {} })
    end)

    local broken = false
    local now_val = 1000
    local clock = SpokeClock.new(1000)
    local test_clock = {
      second = clock.second,
      on_second = clock.on_second,
      on_frame = clock.on_frame,
      now = function()
        if broken then error("clock-boom") end
        return now_val
      end,
    }
    _G.REUtil = {
      get_re = function()
        return { OnServerEvent = { Connect = function() return { Disconnect = function() end } end } }
      end,
      check_recd = function() return false end,
    }
    local world = { clock = test_clock }
    local tree = Spoke.SpokeTree.spawn("TestWorldRecords", Spoke.Effect.new("Root", function(s)
      WorldRecords.mount(s, world, { clock = test_clock, player_data = {} })
    end))
    local session = world.records
    assert.is_not_nil(session)

    assert.is_true(session:cache_set("bass", { w = 120, u = 1, n = "甲" }, nil))
    assert.equals(1000, session.cache.bass.at)
    assert.is_true(session:fresh(session.cache.bass))

    broken = true
    local restore_print = capture_print()
    local set_ok = session:cache_set("bass", { w = 999, u = 2, n = "乙" }, "io-err")
    local is_fresh = session:fresh(session.cache.bass)
    local landed_ok, landed_err = session:note_landing({ UserId = 7, Name = "乙" }, "carp", 2.5)
    local lines = restore_print()

    assert.is_false(set_ok)
    assert.equals(1000, session.cache.bass.at)
    assert.equals(120, session.cache.bass.entry.w)
    assert.is_false(is_fresh)
    assert.is_false(landed_ok)
    assert.equals("clock", landed_err)
    assert.is_nil(session.pending.carp)
    assert.matches("%[WorldRecords%] 读取时钟失败", table.concat(lines, "\n"))

    tree:dispose()
  end)

  it("客户端视图缺注入时钟在挂载期报错，运行期异常记录日志且不以 0 污染倒计时与收线进度", function()
    local store = ClientStore.new({ initial_now = 100 })
    local root = Eui.node({ Name = "UIRoot" })
    local fake_scope = {
      memo = function(_, _, fn) return fn({ d = function(_, sig) return sig:now() end }) end,
      phase = function() end,
      subscribe = function() end,
      effect = function() end,
      on_cleanup = function() end,
    }
    local no_clock_ctx = { root_node = root, store = store, services = {}, create_node = make_node_factory() }
    assert.has_error(function() AttackView.mount(fake_scope, no_clock_ctx) end)
    assert.has_error(function() ReelOverlayView.spec().mount(fake_scope, no_clock_ctx) end)
    assert.has_error(function() SurvivalOverlayView.spec().mount(fake_scope, no_clock_ctx) end)
    assert.has_error(function() MainHudItemBarView.mount(fake_scope, no_clock_ctx) end)

    local broken = false
    local clock = SpokeClock.new(100)
    local store_ok, writer = ClientStore.new({ clock = clock })
    local sent_reel, sent_attack = {}, {}
    local reel = {}
    local view_root = Eui.node({ Name = "RootClockFail" })
    local view = RootView.mount(view_root, store_ok, {
      services = {
        reel = reel,
        now = function()
          if broken then error("client-clock-fail") end
          return clock.now()
        end,
        get_device_resolution = function() return { x = 1920, y = 1080 } end,
        send_reel = function(p) sent_reel[#sent_reel + 1] = p end,
        send_weapon = function(p) sent_attack[#sent_attack + 1] = p end,
      },
      hud = { AttackView.spec() },
      overlays = {
        survival = SurvivalOverlayView.spec(),
        reel = ReelOverlayView.spec(),
      },
      create_node = make_node_factory(),
    })
    assert.is_nil(view.root.fault)

    writer:ingest_event("SurvivalState", { phase = "alive", weakUntil = 120 })
    writer:ingest_event("CastState", { phase = "hooked", reelSession = "s1", castId = 1 })
    writer:ingest_event("ReelInRE", { action = "started", session = "s1", progress = 50 })
    writer:ingest_event("ItemBarState", { weapons = { item137 = 1 }, held = { kind = "weapon", id = "item137" }, slots = {} })
    local weak = view_root:FindFirstChild("SurvivalWeak", true)
    assert.equals(GameCfg.Survival.WeakText .. "（20 秒）", weak.Text)
    assert.equals(50, reel.progress())
    local reel_bar = view_root:FindFirstChild("ReelBar", true)
    assert.equals("EUILoadingBar", reel_bar.Kind)
    assert.equals(50, reel_bar.Percent)

    broken = true
    local restore_print = capture_print()
    clock:advance(1)
    assert.is_false(reel.click("s1"))
    local btn_attack = view_root:FindFirstChild("BtnAttack", true)
    btn_attack.OnTouchBegan:Fire()
    btn_attack.OnTouchEnded:Fire()
    local lines = restore_print()

    assert.equals(GameCfg.Survival.WeakText .. "（20 秒）", weak.Text)
    assert.equals(50, reel.progress())
    assert.equals(0, #sent_attack)
    local joined = table.concat(lines, "\n")
    assert.matches("%[SurvivalOverlayView%] 读取时钟失败", joined)
    assert.matches("%[ReelOverlayView%] 读取时钟失败", joined)
    assert.matches("%[AttackView%] 读取时钟失败", joined)

    -- 切到濒死横幅时，时钟恢复可显示倒计时，再次异常时不被 0 污染
    broken = false
    writer:ingest_event("SurvivalState", { phase = "downed", endsAt = 116 })
    local title = view_root:FindFirstChild("SurvivalTitle", true)
    assert.equals(GameCfg.Survival.DownedTitle .. "（15 秒）", title.Text)
    broken = true
    local restore_banner_print = capture_print()
    clock:advance(1)
    local banner_lines = restore_banner_print()
    assert.equals(GameCfg.Survival.DownedTitle .. "（15 秒）", title.Text)
    assert.matches("%[SurvivalOverlayView%] 读取时钟失败", table.concat(banner_lines, "\n"))

    view:dispose()
  end)

  it("ViewUtil.get_resolution 无注入且宿主不可用时返回 nil 并记录日志，客户端视图对 nil 分辨率安全不崩溃", function()
    _G.game = nil
    local restore_print = capture_print()
    local res_missing = ViewUtil.get_resolution({})
    local res_throwing = ViewUtil.get_resolution({
      services = { get_device_resolution = function() error("eui-broken") end },
    })
    local res_invalid = ViewUtil.get_resolution({
      services = { get_device_resolution = function() return { x = 0, y = -1 } end },
    })
    local lines = restore_print()

    assert.is_nil(res_missing)
    assert.is_nil(res_throwing)
    assert.is_nil(res_invalid)
    local joined = table.concat(lines, "\n")
    assert.matches("%[ViewUtil%] 未获取到有效设备分辨率，返回 nil", joined)
    assert.matches("%[ViewUtil%] 读取分辨率失败", joined)

    local store, writer = ClientStore.new({ initial_now = 100 })
    local root = Eui.node({ Name = "NilResRoot" })
    local view = RootView.mount(root, store, {
      services = {},
      hud = {
        AttackView.spec(),
        FerryView.spec(),
        GuideView.spec(),
        SquadView.hud_spec(),
        MainHudVitalsView.spec(),
        MainHudActionButtonsView.spec(),
        MainHudBackpackView.spec(),
        MainHudEquipPopups.spec(),
        MainHudItemBarView.spec(),
      },
      modals = { story = StoryView.modal_spec() },
      overlays = {
        survival = SurvivalOverlayView.spec(),
        reel = ReelOverlayView.spec(),
      },
      create_node = make_node_factory(),
    })
    assert.is_nil(view.root.fault, tostring(view.root.fault))

    writer:ingest_event("SurvivalState", { phase = "downed", endsAt = 115, weakUntil = 120 })
    writer:ingest_event("CastState", { phase = "hooked", reelSession = "s1", castId = 1 })
    writer:ingest_event("ReelInRE", { action = "started", session = "s1", progress = 40 })
    writer:ingest_event("FerryState", { route_id = "fishPond_beachIsland", phase = "countdown", seconds = 5, operation = 1 })
    writer:ingest_event("ItemBarState", { weapons = { item137 = 1 }, held = { kind = "weapon", id = "item137" }, slots = {} })
    writer:open_modal("story", { title = "测试", lines = { "第一段" } })
    assert.is_nil(view.root.fault, tostring(view.root.fault))
    assert.is_nil(root:FindFirstChild("ReelMask", true))
    assert.is_nil(root:FindFirstChild("SurvivalBanner", true))
    assert.is_nil(root:FindFirstChild("FerryCountdown", true))

    view:dispose()
  end)

  it("server/main.lua 时钟异常时记录日志且不将入口时钟归零覆盖，client/main.lua 无 EUI 返回 nil", function()
    local saved_loaded = {}
    for _, name in ipairs({
      "common.re_util", "server.MgrUtil", "common.zone_markers", "server.packages.attr_rule.api",
      "server.packages.modifier_system.api", "server.packages.ability_system.api",
      "server.save_host", "server.player_data_host", "server.platform_host", "server.fish_ability",
      "server.world_host.server_runtime",
    }) do
      saved_loaded[name] = package.loaded[name]
    end

    local server_now_broken = false
    local current_server_now = 250
    local heartbeat_handlers = {}
    local function sig()
      return { Connect = function(_, fn) heartbeat_handlers[#heartbeat_handlers + 1] = fn return { Disconnect = function() end } end }
    end
    local dummy_unit = { Destroy = function() end, SetAttribute = function() end, GetAttribute = function() end, FindFirstChild = function() end }
    _G.Vector3 = { New = function(x, y, z) return { x = x, y = y, z = z } end }
    _G.game = {
      BindToClose = function() end,
      GetService = function(_, name)
        if name == "Task" then return { Spawn = function() end, Wait = function() end } end
        if name == "Players" then return { PlayerAdded = sig(), PlayerRemoving = sig(), GetPlayers = function() return {} end, GetPlayerFromCharacter = function() end } end
        if name == "RunService" then return { Heartbeat = sig(), IsServer = function() return true end, IsClient = function() return false end } end
        if name == "World" then
          return {
            GetServerTime = function()
              if server_now_broken then error("server-clock-down") end
              return current_server_now
            end,
            CreateUnit = function() return dummy_unit end,
            CreateAsset = function() return { dummy_unit } end,
          }
        end
        if name == "DataStoreService" then return { GetDataStore = function() return { GetAsync = function() end, UpdateAsync = function() end } end } end
        return {}
      end,
    }
    local re_util_stub = {
      get_re = function() return { OnServerEvent = sig(), FireClient = function() end, FireAllClients = function() end } end,
      check_recd = function() return false end,
    }
    _G.REUtil = re_util_stub
    _G.RemoteEvent = {
      New = function()
        return { OnServerEvent = sig(), OnClientEvent = sig(), FireServer = function() end, FireClient = function() end, FireAllClients = function() end }
      end,
    }
    package.loaded["common.re_util"] = re_util_stub

    local server_logs = {}
    local sandbox = setmetatable({
      print = function(...)
        local parts = {}
        for _, v in ipairs({ ... }) do parts[#parts + 1] = tostring(v) end
        server_logs[#server_logs + 1] = table.concat(parts, "\t")
      end,
      require = function(path)
        if path == "common.re_util" then return re_util_stub end
        if path == "common.zone_markers" then return { start = function() end } end
        if path == "server.packages.attr_rule.api" then return { Enums = { AttrComponentType = {} }, Funcs = {} } end
        if path == "server.packages.modifier_system.api" then return { Enums = { CreateResult = {} } } end
        if path == "server.packages.ability_system.api" then return {} end
        if path == "server.save_host" then return assert(loadfile("server/save_host.lua"))() end
        if path == "server.player_data_host" then return assert(loadfile("server/player_data_host.lua"))() end
        if path == "server.platform_host" then return {} end
        if path == "server.fish_ability" then return { start = function() end, update = function() end } end
        return require(path)
      end,
    }, { __index = _G })

    local ok, rt = pcall(function()
      return assert(loadfile("server/main.lua", "t", sandbox))()
    end)
    if ok then
      assert.equals(250, rt.clock.now())
      server_now_broken = true
      heartbeat_handlers[#heartbeat_handlers](0.5)
      assert.equals(250.5, rt.clock.now())
      assert.matches("%[server%.main%] 读取宿主时钟失败", table.concat(server_logs, "\n"))
      rt:shutdown()
    end

    for name, value in pairs(saved_loaded) do
      package.loaded[name] = value
    end
    assert.is_true(ok, tostring(rt))
  end)

  it("client/main.lua 宿主 EUI 不可用时 get_device_resolution 与 hud_entry_rect 返回 nil 并记录日志", function()
    local saved_loaded = {}
    local to_restore = {
      "common.zone_markers", "common.re_util", "client.game_ui", "client.packages.ability_system.api",
      "client.store.client_store", "client.views.root_view", "common.util",
      "client.LocalMgrUtil", "client.LocalMotorUnitCtrl", "client.LocalLoot", "client.views.GarBiteWarning",
      "client.views.grill_view",
    }
    for _, name in ipairs(to_restore) do
      saved_loaded[name] = package.loaded[name]
    end
    local saved_client_spoke = rawget(_G, "ClientSpoke")
    local saved_platform_shop = rawget(_G, "PlatformShop")
    local saved_gm = rawget(_G, "GM")
    local saved_notice = rawget(_G, "local_msg_notice")
    local saved_mgr_game_ui = rawget(_G, "MgrGameUI")

    local ui_root = Eui.node({ Name = "UIRoot" })
    local mounted_opts
    local noop = function() end
    local hb_sig = Eui.Signal()
    _G.MgrGameUI = { HideLiftButton = noop, HideNativeHealth = noop, OpenScreen = noop, StartGM = noop }
    _G.RemoteEvent = { New = function() return { OnServerEvent = Eui.Signal(), OnClientEvent = Eui.Signal(), FireServer = noop } end }
    _G.game = {
      GetService = function(_, name)
        if name == "Task" then return { Spawn = function(_, fn) fn() end, Wait = noop, Delay = noop } end
        if name == "World" then return { GetServerTime = function() return 60 end, FindFirstChild = function() return nil end, CreateUnit = function(_, k, p) return Eui.node({ Kind = k, Name = p and p.Name }) end } end
        if name == "RunService" then return { Heartbeat = hb_sig, IsClient = function() return true end, IsServer = function() return false end } end
        if name == "Players" then return { LocalPlayer = { Character = nil }, GetPlayers = function() return {} end } end
        return {}
      end,
    }
    local re_stub = { get_re = function() return { OnClientEvent = Eui.Signal(), FireServer = noop } end }
    package.loaded["common.zone_markers"] = { start = noop, Zones = {} }
    package.loaded["common.re_util"] = re_stub
    package.loaded["common.util"] = nil
    for _, name in ipairs({ "client.LocalMgrUtil", "client.LocalMotorUnitCtrl", "client.LocalLoot", "client.views.GarBiteWarning" }) do
      package.loaded[name] = { Start = noop }
    end
    package.loaded["client.game_ui"] = { get_ui_root = function() return ui_root end, get_eui_manager = function() return nil end }
    package.loaded["client.packages.ability_system.api"] = { StartClientLifecycle = noop }
    package.loaded["client.store.client_store"] = nil
    package.loaded["client.views.root_view"] = {
      mount = function(_, _, opts)
        mounted_opts = opts
        return { root = {}, dispose = noop }
      end,
    }
    package.loaded["client.views.grill_view"] = {
      new_shared = function() return {} end,
      spec = function() return { name = "Grill", mount = noop } end,
      bubble_spec = function() return { name = "GrillBubble", mount = noop } end,
    }

    local restore_print = capture_print()
    local ok, err = pcall(function()
      assert(loadfile("client/main.lua"))()
    end)
    local res_val = (ok and mounted_opts) and mounted_opts.services.get_device_resolution() or nil
    local rect_val = (ok and mounted_opts) and mounted_opts.services.hud_entry_rect("ShopEntry") or nil
    local lines = restore_print()

    for _, name in ipairs(to_restore) do
      package.loaded[name] = saved_loaded[name]
    end
    _G.ClientSpoke = saved_client_spoke
    _G.PlatformShop = saved_platform_shop
    _G.GM = saved_gm
    _G.local_msg_notice = saved_notice
    _G.MgrGameUI = saved_mgr_game_ui

    assert.is_true(ok, tostring(err))
    assert.is_not_nil(mounted_opts)
    assert.is_nil(res_val)
    assert.is_nil(rect_val)
    assert.matches("%[client%.main%] EUI 未就绪", table.concat(lines, "\n"))
  end)
end)
