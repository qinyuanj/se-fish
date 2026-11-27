-- 礁石抛竿来源可视化宿主动作契约。
-- 失败方式先列：
--   1. 同一 castId:fishId 快照重复建来源单位，脱钩后来源与钓线未销毁；
--   2. 逐帧插值不看收线进度：t 未夹紧到 [0,1]、y 漏掉手部抬升、钓线起点不服手、终点不跟来源；
--   3. 角色优先序错乱：store 里有本地角色仍去读引擎 Players，或 store 缺位时不退化到引擎；
--   4. 角色缺失、Vector3 构造失败或宿主单位写位置失败时仍写半更新坐标，或失败后不清掉来源与钓线。

-- 礁石抛竿来源可视化宿主动作契约。
-- 失败方式先列：
--   1. 同一 castId:fishId 快照重复建来源单位，脱钩后来源与钓线未销毁；
--   2. 逐帧插值不看收线进度：t 未夹紧到 [0,1]、y 漏掉手部抬升、钓线起点不服手、终点不跟来源；
--   3. 角色优先序错乱：store 里有本地角色仍去读引擎 Players，或 store 缺位时不退化到引擎；
--   4. 角色缺失、Vector3 构造失败或宿主单位写位置失败时仍写半更新坐标，或失败后不清掉来源与钓线。

local Eui = require("tests.support.eui_double")
local ClientStore = require("client.store.client_store")
local RootView = require("client.views.root_view")
local CastSourceView = require("client.views.cast_source_view")
local SpokeClock = require("common.spoke_clock")

describe("礁石来源可视化宿主入口（#302）", function()
  local saved_v3, saved_color
  before_each(function()
    saved_v3, saved_color = rawget(_G, "Vector3"), rawget(_G, "Color")
    _G.Vector3 = { New = function(x, y, z) return { x = x, y = y, z = z } end }
    _G.Color = { New = function(r, g, b, a) return { r = r, g = g, b = b, a = a } end }
  end)
  after_each(function()
    _G.Vector3, _G.Color = saved_v3, saved_color
  end)

  it("同一上钩快照复用来源，脱钩销毁来源与钓线", function()
    local clock = SpokeClock.new(0)
    local store, writer = ClientStore.new({ clock = clock })
    local root = Eui.node({ Name = "UIRoot" })
    local units = {}
    local view = RootView.mount(root, store, {
      services = {
        create_unit = function(kind, props)
          local unit = Eui.node({ Name = props.Name, Kind = kind, Position = props.Position })
          unit.Destroyed = false
          units[#units + 1] = unit
          return unit
        end,
        reel = { active = function() return true end, progress = function() return 75 end },
      },
      hud = { CastSourceView.spec() },
      create_node = function(kind, props) return Eui.node({ Kind = kind, Name = props.Name, Parent = props.Parent }) end,
    })
    writer:ingest_event("CastState", { phase = "hooked", castId = 37, fishId = "item81", reelSession = "s37",
      hookPosition = { x = 880, y = 15, z = 144 } })
    assert.are.equal(2, #units)
    local body = units[1]
    assert.are.equal("CastSource_37", body.Name)
    assert.are.equal(15, body.Position.y)
    writer:ingest_event("CastState", { phase = "hooked", castId = 37, fishId = "item81", reelSession = "s37",
      hookPosition = { x = 880, y = 15, z = 144 } })
    assert.are.equal(2, #units)
    writer:ingest_event("CastState", { phase = "unhooked", castId = 37 })
    assert.is_true(body.Destroyed)
    assert.is_true(units[2].Destroyed)
    view:dispose()
  end)

  -- 逐帧插值需要真实帧驱动：用 SpokeClock + RootView 挂载，断言来源/钓线节点的 Position 与 EndPosition。
  local function mount_cast(opts)
    opts = opts or {}
    local clock = SpokeClock.new(0)
    local store, writer = ClientStore.new({ clock = clock })
    local root = Eui.node({ Name = "UIRoot" })
    local view = RootView.mount(root, store, {
      services = {
        create_unit = opts.create_unit or function(kind, props)
          return Eui.node({ Name = props.Name, Kind = kind, Position = props.Position })
        end,
        reel = opts.reel or { active = function() return true end, progress = function() return 75 end },
      },
      hud = { CastSourceView.spec() },
      create_node = function(kind, props) return Eui.node({ Kind = kind, Name = props.Name, Parent = props.Parent }) end,
    })
    return { clock = clock, store = store, writer = writer, root = root, view = view }
  end

  local function capture_units(units)
    return function(kind, props)
      local unit = Eui.node({ Name = props.Name, Kind = kind, Position = props.Position })
      unit.Destroyed = false
      units[#units + 1] = unit
      return unit
    end
  end

  local function character_host(character)
    return {
      GetService = function(_, service)
        if service ~= "Players" then return nil end
        return { LocalPlayer = { Character = character } }
      end,
    }
  end

  it("逐帧把来源单位从入水点插值到角色手上，钓线起点跟角色、终点跟来源，进度越界收敛到端点", function()
    local saved_game, saved_vector = rawget(_G, "game"), rawget(_G, "Vector3")
    local ok, err = pcall(function()
      local units = {}
      local progress = 0
      local env = mount_cast({
        create_unit = capture_units(units),
        reel = { active = function() return true end, progress = function() return progress end },
      })
      _G.game = character_host({ Position = { x = 1000, y = 30, z = 200 } })
      env.writer:ingest_event("CastState", { phase = "hooked", castId = 37, fishId = "item81", reelSession = "s37",
        hookPosition = { x = 880, y = 15, z = 144 } })
      assert.are.equal(2, #units)
      local body, line = units[1], units[2]

      -- 进度还没过半：t 夹紧到 0，来源停在水面入水点，钓线起点在角色手上
      env.clock:advance(0.1)
      assert.are.same({ x = 880, y = 15, z = 144 }, body.Position)
      assert.are.same({ x = 1000, y = 31, z = 200 }, line.Position)
      assert.are.same({ x = 880, y = 15, z = 144 }, line.EndPosition)

      -- 进度 75%：来源插值到一半（y 带 +2 的手部抬升），钓线终点跟随来源
      progress = 75
      env.clock:advance(0.1)
      assert.are.same({ x = 940, y = 23.5, z = 172 }, body.Position)
      assert.are.same({ x = 1000, y = 31, z = 200 }, line.Position)
      assert.are.same({ x = 940, y = 23.5, z = 172 }, line.EndPosition)

      -- 进度超过 100%：t 夹紧到 1，收敛到手上而不是越过目标
      progress = 140
      env.clock:advance(0.1)
      assert.are.same({ x = 1000, y = 32, z = 200 }, body.Position)
      env.view:dispose()
    end)
    _G.game, _G.Vector3 = saved_game, saved_vector
    if not ok then
      error(err, 0)
    end
  end)

  it("角色优先取 store 里的本地角色，store 缺位时才退化到引擎 Players 服务", function()
    local saved_game, saved_vector = rawget(_G, "game"), rawget(_G, "Vector3")
    local ok, err = pcall(function()
      local units = {}
      local progress = 100
      local env = mount_cast({
        create_unit = capture_units(units),
        reel = { active = function() return true end, progress = function() return progress end },
      })
      _G.game = character_host({ Position = { x = 0, y = 0, z = 0 } })
      env.writer:ingest_event("CastState", { phase = "hooked", castId = 38, fishId = "item81", reelSession = "s38",
        hookPosition = { x = 880, y = 15, z = 144 } })
      local body = units[1]

      -- store 里有本地角色：朝它插值（t=1 落在 (1000, 32, 200)，不是引擎角色的 (0, 2, 0)）
      env.writer:update_camera_target({ Position = { x = 1000, y = 30, z = 200 } }, nil)
      env.clock:advance(0.1)
      assert.are.same({ x = 1000, y = 32, z = 200 }, body.Position)

      -- store 角色消失：退化到引擎 Players 的本地角色
      env.writer:update_camera_target(nil, nil)
      env.clock:advance(0.1)
      assert.are.same({ x = 0, y = 2, z = 0 }, body.Position)
      env.view:dispose()
    end)
    _G.game, _G.Vector3 = saved_game, saved_vector
    if not ok then
      error(err, 0)
    end
  end)

  it("角色或向量不可用时该帧不写位置；写位置失败或向量构造失败时清掉来源与钓线", function()
    local saved_game, saved_vector = rawget(_G, "game"), rawget(_G, "Vector3")
    local ok, err = pcall(function()
      -- 1. 没有角色可跟随：该帧直接返回，来源停在入水点
      _G.game = nil
      local units_alone = {}
      local alone = mount_cast({ create_unit = capture_units(units_alone) })
      alone.writer:ingest_event("CastState", { phase = "hooked", castId = 41, fishId = "item81", reelSession = "s41",
        hookPosition = { x = 880, y = 15, z = 144 } })
      alone.clock:advance(0.1)
      assert.are.same({ x = 880, y = 15, z = 144 }, units_alone[1].Position)
      alone.view:dispose()

      -- 2. Vector3 构造失败：清掉来源与钓线，不留下半更新节点
      _G.game = character_host({ Position = { x = 1000, y = 30, z = 200 } })
      local units_vector = {}
      local broken_vector = mount_cast({ create_unit = capture_units(units_vector) })
      broken_vector.writer:ingest_event("CastState", { phase = "hooked", castId = 42, fishId = "item81", reelSession = "s42",
        hookPosition = { x = 880, y = 15, z = 144 } })
      _G.Vector3 = nil
      broken_vector.clock:advance(0.1)
      _G.Vector3 = saved_vector
      assert.is_true(units_vector[1].Destroyed)
      assert.is_true(units_vector[2].Destroyed)
      broken_vector.view:dispose()

      -- 3. 宿主单位已回收（写位置抛错）：记录日志并清掉来源与钓线
      -- Position 键不存在时 __newindex 才会触发：模拟宿主已回收、写位置抛错的单位
      local recycled = { Name = "CastSource_43", Kind = "WorldUnit", destroyed = false }
      recycled.Destroy = function(self) self.destroyed = true end
      setmetatable(recycled, { __newindex = function() error("unit-recycled") end })
      local line_unit
      local write_error = mount_cast({
        create_unit = function(kind, props)
          if kind == "LinkEffectUnit" then
            line_unit = Eui.node({ Name = props.Name, Kind = kind, Position = props.Position })
            return line_unit
          end
          return recycled
        end,
      })
      write_error.writer:ingest_event("CastState", { phase = "hooked", castId = 43, fishId = "item81", reelSession = "s43",
        hookPosition = { x = 880, y = 15, z = 144 } })
      local logs = {}
      local saved_print = _G.print
      _G.print = function(...)
        local parts = {}
        for i = 1, select("#", ...) do parts[i] = tostring((select(i, ...))) end
        logs[#logs + 1] = table.concat(parts, "\t")
      end
      write_error.clock:advance(0.1)
      _G.print = saved_print
      assert.matches("更新来源失败", table.concat(logs, "\n"))
      assert.is_true(recycled.destroyed)
      assert.is_true(line_unit.Destroyed)
      write_error.view:dispose()
    end)
    _G.game, _G.Vector3 = saved_game, saved_vector
    if not ok then
      error(err, 0)
    end
  end)
end)
