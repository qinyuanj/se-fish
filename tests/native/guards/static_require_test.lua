-- 按名字加载模块的两处入口（MgrGameUI:GetScreen、AbilityAPI.AttachAnchor）改用登记表 + 字面量 require，
-- 架构图扫描器才能解析出依赖。失败方式先列：
--   1. 新增界面 handler 或锚点行为文件却没登记 → 按名加载时报"未登记"；
--   2. GameCfg 新配的锚点行为没登记 → 挂接时报"锚点行为模块不可用"；
--   3. 登记的模块文件被删或包升级改名 → 运行时 require 失败；
--   4. 登记键与模块文件名不一致 → 按名加载到别的模块；
--   5. 未登记的名字被静默吞掉 → 配置或节点名写错时没有报错；
--   6. 回退成拼字符串的 require → 图上依赖再次丢失。
-- 登记覆盖（1~4、6）只读源码文本校对，与 grill_test 的接线断言同口径；失败路径（5）加载真实模块验证。
-- 包内锚点框架 anchor_logic.lua 不进任何登记表（server/AbilityAPI.lua 直接按字面量 require 它），
-- 文件被删或包升级改名同样只在运行时炸，由文末「字面量 require 的包内模块」单独登记。


local fs = require("tests.support.fs_fixture")

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
  for _, file in ipairs(fs.list_dir(dir)) do
    local name = file:match("^(.+)%.lua$")
    if name then names[#names + 1] = name end
  end
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

describe("字面量 require 的包内模块", function()
  it("test_anchor_framework_module_exists", function()
    local path = "server/packages/ability_system/anchor_logic.lua"
    assert.is_true(file_exists(path), path .. " 不存在（AbilityAPI 按字面量 require 它）")
  end)
end)

-- ── 三端源码守卫 ───────────────────────────────────────────────
-- 原 CODING_STANDARDS.md 里能机械判定的条目搬到这里（人审只留判断类规则）：
--   1. require 少写工程前缀 → 裸名不在宿主的模块搜索路径里，运行期才炸；
--   2. require 的大小写与文件名不一致 → 本机（不区分大小写）能跑，换环境或宿主后炸；
--   3. require 到不存在的文件 → 模块改名或删除后只在运行时报错；
--   4. 业务代码 require 引擎存根 EggyAPI / EggyEditorAPI → 类型存根被当模块加载；
--   5. 业务代码出现 io / os / package / debug 调用 → SE 沙盒里这些是 nil，调用即崩；
--   6. 新增 server/Mgr/*.lua 没进 server/main.lua 的 MgrMap → 管理器永远收不到 Start / OnPlayerAdded；
--   7. 可重入口（OpenScreen / CloseScreen / Init）里 Connect 不存句柄 → 每次开窗叠一个监听。
-- 三端 packages/ 是整包交付的外来件（ADR-0005），不吃第 5、7 条；第 2、3 条照查（包按原始字节交付，路径同样不能错）。
local Arch = require("tools.arch_policy")
local lfs = require("lfs")

local BUSINESS_ROOTS = { "client", "common", "server" }
local BANNED_GLOBALS = { "io", "os", "package", "debug" }
local REENTRANT = { OpenScreen = true, CloseScreen = true, Init = true }

local function is_dir(path)
  return lfs.attributes(path, "mode") == "directory"
end

local function walk(dir, out)
  for _, name in ipairs(fs.list_dir(dir)) do
    local full = dir .. "/" .. name
    if is_dir(full) then
      walk(full, out)
    elseif name:match("%.lua$") then
      out[#out + 1] = full
    end
  end
  return out
end

local source_files_memo
local function source_files()
  if source_files_memo then return source_files_memo end
  local out = {}
  for _, root in ipairs(BUSINESS_ROOTS) do walk(root, out) end
  table.sort(out)
  source_files_memo = out
  return out
end

local function is_package(path)
  return path:find("/packages/", 1, true) ~= nil
end

local function business_files()
  local out = {}
  for _, path in ipairs(source_files()) do
    if not is_package(path) then out[#out + 1] = path end
  end
  return out
end

local sources_memo
local function source_of(path)
  sources_memo = sources_memo or {}
  if not sources_memo[path] then
    sources_memo[path] = assert(fs.slurp(path), "读不到源码 " .. path)
  end
  return sources_memo[path]
end

local function shadows_local(code, name)
  for decl in code:gmatch("local%s+([%w_,%s]+)") do
    for candidate in decl:gmatch("[%w_]+") do
      if candidate == name then return true end
    end
  end
  return false
end

local function line_of(text, position)
  return select(2, text:sub(1, position):gsub("\n", "")) + 1
end

describe("三端源码守卫", function()
  it("test_scans_the_whole_business_tree", function()
    assert.is_true(#source_files() > 200,
      "三端只扫到 " .. #source_files() .. " 个模块文件，扫描口径坏了")
  end)

  it("test_requires_carry_project_prefix", function()
    local bad = {}
    for _, path in ipairs(business_files()) do
      for _, mod in ipairs(Arch.requires(source_of(path))) do
        if not mod:match("^client%.") and not mod:match("^common%.") and not mod:match("^server%.") then
          bad[#bad + 1] = path .. " → " .. mod
        end
      end
    end
    table.sort(bad)
    assert.same({}, bad)
  end)

  it("test_require_paths_match_file_case", function()
    local exact = {}
    for _, path in ipairs(source_files()) do exact[path] = true end
    local bad = {}
    for _, path in ipairs(source_files()) do
      for _, mod in ipairs(Arch.requires(source_of(path))) do
        local want = mod:gsub("%.", "/") .. ".lua"
        if not exact[want] then
          local near
          for candidate in pairs(exact) do
            if candidate:lower() == want:lower() then
              near = candidate
              break
            end
          end
          if near then
            bad[#bad + 1] = path .. " → " .. mod .. "（实际文件是 " .. near .. "）"
          else
            bad[#bad + 1] = path .. " → " .. mod .. "（没有这个文件）"
          end
        end
      end
    end
    table.sort(bad)
    assert.same({}, bad)
  end)

  it("test_business_code_does_not_require_engine_stubs", function()
    local stubs = { EggyAPI = true, EggyEditorAPI = true }
    local bad = {}
    for _, path in ipairs(business_files()) do
      for _, mod in ipairs(Arch.requires(source_of(path))) do
        if stubs[mod] or stubs[mod:match("[^.]+$")] then
          bad[#bad + 1] = path .. " → " .. mod
        end
      end
    end
    table.sort(bad)
    assert.same({}, bad)
  end)

  it("test_business_code_avoids_sandbox_removed_globals", function()
    local bad = {}
    for _, path in ipairs(business_files()) do
      local code = Arch.code_only(source_of(path))
      for _, name in ipairs(BANNED_GLOBALS) do
        -- 同名 local 会遮蔽全局（如 server/Data/PlayerData.lua 的 local debug = GameCfg.Debug），
        -- 这类文件整份放行：宁可漏报，不误伤。
        local position = not shadows_local(code, name) and code:find("%f[%w_]" .. name .. "%s*[%.:]")
        if position then
          bad[#bad + 1] = path .. ":" .. line_of(code, position) .. " 用了 " .. name
        end
      end
    end
    table.sort(bad)
    assert.same({}, bad)
  end)

  it("test_every_manager_is_registered_in_mgr_map", function()
    local src = assert(fs.slurp("server/main.lua"), "读不到 server/main.lua")
    local body = assert(src:match("local MgrMap = (%b{})"), "找不到 local MgrMap 表")
    local registered = {}
    for key, mod in body:gmatch("([%w_]+)%s*=%s*require%s*%(%s*[\"']server%.Mgr%.([%w_]+)[\"']%s*%)") do
      registered[key] = mod
    end
    local expected = {}
    for _, name in ipairs(fs.list_dir("server/Mgr")) do
      local base = name:match("^(%w+)%.lua$")
      if base then expected[base] = true end
    end
    local problems = {}
    for name in pairs(expected) do
      if not registered[name] then problems[#problems + 1] = "server/Mgr/" .. name .. ".lua 没进 MgrMap" end
    end
    for key, mod in pairs(registered) do
      if key ~= mod then problems[#problems + 1] = "MgrMap." .. key .. " 装的是 server.Mgr." .. mod end
    end
    for key in pairs(registered) do
      if not expected[key] then problems[#problems + 1] = "MgrMap." .. key .. " 没有对应文件" end
    end
    table.sort(problems)
    assert.same({}, problems)
  end)

  it("test_reentrant_entrypoints_keep_connection_handles", function()
    -- 行级启发式：本仓 handler 的函数头与 end 都顶格写，所以进入可重入口后
    -- 遇到顶格 end 或下一个 function 即为该函数结束。
    local bad = {}
    for _, path in ipairs(business_files()) do
      local entry
      local number = 0
      for line in (source_of(path) .. "\n"):gmatch("([^\n]*)\n") do
        number = number + 1
        local opened = line:match("^function%s+[%w_.]+:(%w+)%s*%(")
        if opened then
          entry = REENTRANT[opened] and opened or nil
        elseif line:match("^end%s*$") or line:match("^function%s") then
          entry = nil
        elseif entry then
          local position = line:find(":Connect%s*%(")
          if position and not line:sub(1, position - 1):find("=") then
            bad[#bad + 1] = path .. ":" .. number .. " " .. entry .. " 里的 Connect 没存句柄"
          end
        end
      end
    end
    table.sort(bad)
    assert.same({}, bad)
  end)
end)

