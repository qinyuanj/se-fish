-- 原生 Busted（#87 迁移自 tests/gameplay/compendium_ui_test.lua 的 TestCompendiumUI）。
-- #39 失败方式：七区漏条/重条、普通与极品合并、未收集泄漏完整图像、
-- 盲盒显示伪重量、纪录不可用变成零、旧回包覆盖新数据、通关受全图鉴阻塞。
-- 接缝：ScreenCompendium 的公开快照消费与页面显示数据；引擎边界另经编辑器 E2E。
-- 迁移说明：案例按旧 LuaUnit 实际执行序（方法名字典序）逐个 it 注册；
--   旧文件的 tearDown 声明夹在两个用例之间，LuaUnit 仍按每例 setUp/tearDown 运行，
--   原生侧统一为 describe 内的 before_each/after_each，语义一致。
--   lu.assertStrContains 省略第 3 参即 plain 子串查找，映射为 assert.matches(sub, s, 1, true)。
local OwnedUnits = require("common.OwnedUnits")
local RandomGuard = require("tests.support.random_guard")

local MODULE_KEYS = { "common.REUtil", "client.GameUI" }
local GLOBAL_KEYS = { "game", "Vector2", "Color", "MgrGameUI" }

--- 换掉图鉴界面依赖的模块缓存与全局（World / UI 管理器替身）；调用方负责 cleanup() 还回原引用。
local function newWorld()
  local env = { created = {} }
  env.previous = {}
  for _, name in ipairs(MODULE_KEYS) do
    env.previous[name] = package.loaded[name]
  end
  for _, key in ipairs(GLOBAL_KEYS) do env.previous[key] = rawget(_G, key) end
  package.loaded["common.REUtil"] = {
    GetRE = function()
      return { FireServer = function() end }
    end,
  }
  package.loaded["client.GameUI"] = {
    GetEuiManager = function()
      return { GetDeviceResolution = function() return { x = 1920, y = 1080 } end }
    end,
  }
  local world = {}
  function world:CreateUnit(kind, props)
    -- 引擎的 UI 节点自带 OnClicked 信号；替身只需提供 Button 会用的 Connect。
    local node = { Kind = kind, Destroyed = false,
      OnClicked = { Connect = function() return { Disconnect = function() end } end } }
    function node:Destroy() self.Destroyed = true end
    for key, value in pairs(props) do node[key] = value end
    env.created[#env.created + 1] = node
    return node
  end
  _G.game = { GetService = function(_, name)
    if name == "World" then return world end
  end }
  _G.Vector2 = { New = function(x, y) return { x = x, y = y } end }
  _G.Color = { New = function(...) return { ... } end }
  _G.MgrGameUI = { GetScreen = function() end, CloseScreen = function() end }

  function env:cleanup()
    for _, name in ipairs(MODULE_KEYS) do
      package.loaded[name] = self.previous[name]
    end
    for _, key in ipairs(GLOBAL_KEYS) do _G[key] = self.previous[key] end
  end

  return env
end

describe("图鉴界面表现（ScreenCompendium）", function()
  local env
  before_each(function()
    env = newWorld()
  end)
  after_each(function()
    RandomGuard.restore()
    if env then
      env:cleanup()
      env = nil
    end
  end)

  it("test_blindbox_has_collection_without_weight_and_late_snapshot_cannot_undo_completion", function()
    local screen = assert(loadfile("client/ScreenHandlers/ScreenCompendium.lua"))()
    screen:Request()
    screen:Request()
    assert.is_true(screen:NoteState({
      seq = 2, state = "ready", unlocked = { item7 = true },
      weights = {}, catches = {}, total = 0, completed = true,
    }))
    assert.is_false(screen:NoteState({
      seq = 1, state = "ready", unlocked = {}, weights = {}, catches = {}, total = 0,
    }))
    local view = screen:View()
    assert.is_false(view.entries[7].silhouette)
    assert.same("未钓取", view.entries[7].weightText)
    assert.same(1, view.collected)
    assert.same("通关成就：已完成", view.achievementText)
    assert.is_false(screen:NoteState({ seq = 3, state = "ready", unlocked = true, weights = {} }))
  end)

  it("test_record_missing_unavailable_and_stale_are_distinct_and_late_selection_is_ignored", function()
    local screen = assert(loadfile("client/ScreenHandlers/ScreenCompendium.lua"))()
    screen:SelectFish("goldfish")
    assert.is_true(screen:NoteRecord({ fishId = "goldfish", seq = 1, state = "missing" }))
    assert.same("全服纪录：暂无", screen:View().recordText)
    screen:SelectFish("goldfish")
    assert.is_true(screen:NoteRecord({ fishId = "goldfish", seq = 2, state = "unavailable" }))
    assert.same("全服纪录：暂不可用", screen:View().recordText)
    screen:SelectFish("goldfish")
    assert.is_true(screen:NoteRecord({
      fishId = "goldfish", seq = 3, state = "ok", weight = 0.2, holder = "钓鱼佬", stale = true,
    }))
    assert.matches("0.20", screen:View().recordText, 1, true)
    assert.matches("上次可信", screen:View().recordText, 1, true)
    screen:SelectFish("carp")
    assert.is_false(screen:NoteRecord({
      fishId = "goldfish", seq = 3, state = "ok", weight = 9, holder = "旧回包",
    }))
    assert.same("全服纪录：暂不可用", screen:View().recordText)
  end)

  it("test_seven_pages_show_98_distinct_entries_with_separate_grades", function()
    local screen = assert(loadfile("client/ScreenHandlers/ScreenCompendium.lua"))()
    local seen, total = {}, 0
    for page = 1, 7 do
      screen.Page = page
      local view = screen:View()
      assert.same(14, #view.entries)
      assert.same("普通", view.entries[1].grade)
      assert.same("极品", view.entries[7].grade)
      assert.same("精英", view.entries[13].grade)
      assert.same("首领", view.entries[14].grade)
      for _, entry in ipairs(view.entries) do
        assert.is_nil(seen[entry.id])
        seen[entry.id], total = true, total + 1
        assert.is_true(entry.silhouette)
        assert.same("未钓取", entry.weightText)
      end
    end
    assert.same(98, total)
  end)

  -- #210 建点/清场：BuildNodes 建的每个节点都登记在册；换 UI 根重建前先清旧节点，关闭后登记表归空。
  -- 失败方式：Screen:Create 只写按名查找表不登记 → 销毁路径漏节点、换根重建时旧图鉴在场上叠加。
  it("test_build_nodes_registers_every_node_and_clear_nodes_destroys_them", function()
    local screen = assert(loadfile("client/ScreenHandlers/ScreenCompendium.lua"))()
    assert.is_true(screen:BuildNodes({ Name = "UIRoot" }))
    assert.is_true(#env.created > 0)
    assert.same(#env.created, OwnedUnits.Count(screen)) -- 每个建点都登记在册
    local previous = env.created
    env.created = {}
    assert.is_true(screen:BuildNodes({ Name = "UIRoot2" })) -- 换根重建：先清旧节点再建新的
    for _, node in ipairs(previous) do
      assert.is_true(node.Destroyed, "旧 UI 根下的节点应被销毁")
    end
    assert.same(#env.created, OwnedUnits.Count(screen)) -- 登记表只剩新一轮
    screen:ClearNodes()
    assert.same(0, OwnedUnits.Count(screen))
    assert.is_nil(next(screen.Nodes)) -- 按名查找表一并复位
    for _, node in ipairs(env.created) do
      assert.is_true(node.Destroyed, "关闭后节点应被销毁")
    end
    screen:ClearNodes() -- 幂等：重复清场不报错
    assert.same(0, OwnedUnits.Count(screen))
  end)
end)
