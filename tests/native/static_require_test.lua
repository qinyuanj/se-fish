-- 按名字加载模块的两处入口（MgrGameUI:GetScreen、AbilityAPI.AttachAnchor）改用登记表 + 字面量 require，
-- 架构图扫描器才能解析出依赖。失败方式先列：
--   1. 新增界面 handler 或锚点行为文件却没登记 → 按名加载时报"未登记"；
--   2. GameCfg 新配的锚点行为没登记 → 挂接时报"锚点行为模块不可用"；
--   3. 登记的模块文件被删或包升级改名 → 运行时 require 失败；
--   4. 登记键与模块文件名不一致 → 按名加载到别的模块；
--   5. 未登记的名字被静默吞掉 → 配置或节点名写错时没有报错；
--   6. 回退成拼字符串的 require → 图上依赖再次丢失。
-- 登记覆盖（1~4、6）只读源码文本校对，与 grill_test 的接线断言同口径；失败路径（5）加载真实模块验证。


local SCREEN_DIR = "client/ScreenHandlers"
local LOCAL_BEHAVIOR_DIR = "server/AbilityBehaviors"
local PACKAGE_ANCHOR_DIR = "server/packages/ability_system/anchors"

local function read_file(path)
  local file = assert(io.open(path, "rb"))
  local src = file:read("*a")
  file:close()
  return src
end

local function file_exists(path)
  local handle = io.open(path, "rb")
  if not handle then
    return false
  end
  handle:close()
  return true
end

local function lua_module_names(dir)
  local names = {}
  local pipe = assert(io.popen('ls "' .. dir .. '"'))
  for file in pipe:lines() do
    local name = file:match("^(.+)%.lua$")
    if name then names[#names + 1] = name end
  end
  pipe:close()
  assert.is_true(#names > 0, dir .. " 下没有模块")
  return names
end

-- 取 `local <tableName> = { ... }` 里 `键 = function() return require("模块") end` 形式的登记项
local function registry_of(src, tableName)
  local body = src:match("local " .. tableName .. " = (%b{})")
  assert.is_truthy(body, "找不到登记表 " .. tableName)
  local registry = {}
  for key, mod in body:gmatch('([%w_]+)%s*=%s*function%s*%(%s*%)%s*return%s+require%s*%(%s*"([%w_%.]+)"%s*%)%s*end') do
    registry[key] = mod
  end
  return registry
end

local function assert_registry_resolves(registry)
  for key, mod in pairs(registry) do
    assert.equals(key, mod:match("([%w_]+)$"), "登记键与模块名不一致: " .. key)
    local path = mod:gsub("%.", "/") .. ".lua"
    assert.is_true(file_exists(path), path .. " 不存在（文件被删或包升级改名）")
  end
end

local function assert_no_dynamic_require(src, path)
  for arg in src:gmatch("require%s*(%b())") do
    local inner = arg:sub(2, -2):match("^%s*(.-)%s*$")
    assert.is_truthy(inner:match('^"[^"]*"$') or inner:match("^'[^']*'$"),
      path .. " 含非字面量 require" .. arg)
  end
end

local function configured_anchor_behaviors()
  local GameCfg = require("common.GameCfg")
  local names = {}
  for _, entry in ipairs(GameCfg.Ability.InitialAbilities or {}) do
    if entry.AnchorBehavior then names[entry.AnchorBehavior] = true end
  end
  for _, entry in pairs(GameCfg.Ability.FishAbilities or {}) do
    if entry.AnchorBehavior then names[entry.AnchorBehavior] = true end
  end
  return names
end

describe("按名字加载的模块登记", function()
  it("test_screen_registry_matches_handler_files", function()
    local src = read_file("client/MgrGameUI.lua")
    local registry = registry_of(src, "ScreenHandlerLoaders")
    local expected = {}
    for _, name in ipairs(lua_module_names(SCREEN_DIR)) do
      expected[name] = "client.ScreenHandlers." .. name
    end
    assert.same(expected, registry)
    assert_registry_resolves(registry)
    assert_no_dynamic_require(src, "client/MgrGameUI.lua")
  end)

  it("test_anchor_registry_covers_behavior_files_and_config", function()
    local src = read_file("server/AbilityAPI.lua")
    local registry = registry_of(src, "AnchorBehaviorLoaders")
    -- 本图实现与包内同名时以本图为准（见 AbilityAPI 登记表注释）
    local expected = {}
    for _, name in ipairs(lua_module_names(PACKAGE_ANCHOR_DIR)) do
      expected[name] = "server.packages.ability_system.anchors." .. name
    end
    for _, name in ipairs(lua_module_names(LOCAL_BEHAVIOR_DIR)) do
      expected[name] = "server.AbilityBehaviors." .. name
    end
    assert.same(expected, registry)
    for name in pairs(configured_anchor_behaviors()) do
      assert.is_truthy(registry[name], "GameCfg 配置的锚点行为未登记: " .. name)
    end
    assert_registry_resolves(registry)
    assert_no_dynamic_require(src, "server/AbilityAPI.lua")
  end)
end)

describe("未登记名字的失败路径", function()
  local saved

  local function save(globals, modules)
    saved = { globals = {}, modules = {}, preload = {} }
    for _, name in ipairs(globals) do saved.globals[name] = rawget(_G, name) end
    for _, name in ipairs(modules) do
      saved.modules[name] = package.loaded[name]
      saved.preload[name] = package.preload[name]
    end
  end

  after_each(function()
    for name, value in pairs(saved.globals) do _G[name] = value end
    for name in pairs(saved.modules) do
      package.loaded[name] = saved.modules[name]
      package.preload[name] = saved.preload[name]
    end
    saved = nil
  end)

  it("test_unregistered_screen_name_errors", function()
    save({ "game", "MgrGameUI" }, { "client.GameUI", "common.REUtil" })
    _G.game = { GetService = function() return {} end }
    local node = { Name = "NoSuchScreen" }
    package.loaded["client.GameUI"] = { GetUIRoot = function()
      return { FindFirstChild = function() return node end }
    end }
    package.loaded["common.REUtil"] = { GetRE = function()
      return { OnClientEvent = { Connect = function() end } }
    end }
    local mgr = assert(loadfile("client/MgrGameUI.lua"))()
    assert.error_matches(function() mgr:GetScreen("NoSuchScreen") end,
      "界面 handler 未登记: NoSuchScreen", nil, true)
  end)

  it("test_unregistered_anchor_behavior_errors", function()
    local vendor = "server.packages.ability_system.api"
    local anchorLogic = "server.packages.ability_system.anchor_logic"
    save({ "game" }, { vendor, anchorLogic, "server.AbilityAPI" })
    _G.game = { GetService = function() return nil end }
    package.loaded[vendor] = nil
    package.preload[vendor] = function() return {} end
    local attached = {}
    package.loaded[anchorLogic] = { Attach = function(script) attached[#attached + 1] = script end }
    local api = assert(loadfile("server/AbilityAPI.lua"))()
    local anchor = {}
    assert.error_matches(function() api.AttachAnchor(anchor, "no_such_behavior") end,
      "锚点行为模块不可用: no_such_behavior", nil, true)
    assert.same({ anchor }, attached)
  end)
end)
