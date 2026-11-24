-- 架构图扫描器才能解析出依赖。失败方式先列：
--   2. game_cfg 新配的锚点行为没登记 → 挂接时报"锚点行为模块不可用"；
--   3. 登记的模块文件被删或包升级改名 → 运行时 require 失败；
--   4. 登记键与模块文件名不一致 → 按名加载到别的模块；
--   5. 未登记的名字被静默吞掉 → 配置或节点名写错时没有报错；
--   6. 回退成拼字符串的 require → 图上依赖再次丢失。
-- 登记覆盖（1~4、6）只读源码文本校对，与 grill_test 的接线断言同口径；失败路径（5）加载真实模块验证。
-- 包内锚点框架 anchor_logic.lua 不进任何登记表（server/ability_api.lua 直接按字面量 require 它），
-- 文件被删或包升级改名同样只在运行时炸，由文末「字面量 require 的包内模块」单独登记。


local fs = require("tests.support.fs_fixture")
local arch = require("tools.arch_policy")

local LOCAL_BEHAVIOR_DIR = "server/ability_behaviors"
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
  local game_cfg = require("common.game_cfg")
  local names = {}
  for _, entry in ipairs(game_cfg.Ability.InitialAbilities or {}) do
    if entry.AnchorBehavior then names[entry.AnchorBehavior] = true end
  end
  for _, entry in pairs(game_cfg.Ability.FishAbilities or {}) do
    if entry.AnchorBehavior then names[entry.AnchorBehavior] = true end
  end
  return names
end

describe("按名字加载的模块登记", function()
  it("test_anchor_registry_covers_behavior_files_and_config", function()
    local src = read_file("server/ability_api.lua")
    local registry = registry_of(src, "AnchorBehaviorLoaders")
    -- 本图实现与包内同名时以本图为准（见 ability_api 登记表注释）
    local expected = {}
    for _, name in ipairs(lua_module_names(PACKAGE_ANCHOR_DIR)) do
      expected[name] = "server.packages.ability_system.anchors." .. name
    end
    for _, name in ipairs(lua_module_names(LOCAL_BEHAVIOR_DIR)) do
      expected[name] = "server.ability_behaviors." .. name
    end
    assert.same(expected, registry)
    for name in pairs(configured_anchor_behaviors()) do
      assert.is_truthy(registry[name], "game_cfg 配置的锚点行为未登记: " .. name)
    end
    assert_registry_resolves(registry)
    assert_no_dynamic_require(src, "server/ability_api.lua")
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

  it("test_unregistered_anchor_behavior_errors", function()
    local vendor = "server.packages.ability_system.api"
    local anchorLogic = "server.packages.ability_system.anchor_logic"
    save({ "game" }, { vendor, anchorLogic, "server.ability_api" })
    _G.game = { GetService = function() return nil end }
    package.loaded[vendor] = nil
    package.preload[vendor] = function() return {} end
    local attached = {}
    package.loaded[anchorLogic] = { Attach = function(script) attached[#attached + 1] = script end }
    local api = assert(loadfile("server/ability_api.lua"))()
    local anchor = {}
    assert.error_matches(function() api.AttachAnchor(anchor, "no_such_behavior") end,
      "锚点行为模块不可用: no_such_behavior", nil, true)
    assert.same({ anchor }, attached)
  end)
end)

describe("字面量 require 的包内模块", function()
  it("test_anchor_framework_module_exists", function()
    local path = "server/packages/ability_system/anchor_logic.lua"
    assert.is_true(file_exists(path), path .. " 不存在（ability_api 按字面量 require 它）")
  end)
end)
local function discover_server_hosts()
  local hosts = {}
  for _, file in ipairs(fs.list_dir("server")) do
    local name = file:match("^(.+_host)%.lua$")
    if not name and file == "fish_ability.lua" then
      name = "fish_ability"
    end
    if name then
      hosts[#hosts + 1] = name
    end
  end
  table.sort(hosts)
  assert.is_true(#hosts > 0, "server/ 下未扫描到任何 Spoke 宿主模块")
  return hosts
end

local function find_required_local(src, code, mod_pattern)
  local from = 1
  while true do
    local first, last, var_name = code:find("local%s+([%w_]+)%s*=%s*require%s*%(", from)
    if not first then return nil end
    if src:sub(first):match("^local%s+[%w_]+%s*=%s*require%s*%(%s*['\"]" .. mod_pattern .. "['\"]%s*%)") then
      return var_name
    end
    from = last + 1
  end
end

describe("宿主组合", function()
  it("test_spoke_hosts_are_explicitly_composed_without_mgr_map", function()
    local src = assert(fs.slurp("server/main.lua"), "读不到 server/main.lua")
    local main_code = arch.code_only(src)
    assert.is_nil(main_code:find("MgrMap", 1, true), "server/main.lua 不得恢复 MgrMap")

    local runtime_args = assert(main_code:match("server_runtime%.new%s*(%b())"),
      "server/main.lua 找不到 server_runtime.new(...) 组合根调用")

    local problems = {}
    for _, name in ipairs(discover_server_hosts()) do
      local host_path = "server/" .. name .. ".lua"
      local host_code = arch.code_only(assert(fs.slurp(host_path), "读不到宿主模块 " .. host_path))
      if not host_code:find("SpokeHost%s*=%s*true%f[^%w_]") then
        problems[#problems + 1] = host_path .. " 缺少 SpokeHost = true 标记"
      end

      local var_name = find_required_local(src, main_code, "server%." .. name)
      if not var_name then
        problems[#problems + 1] = name .. " 未在 server/main.lua 组合根加载"
      elseif not runtime_args:find("[%w_]+%s*=%s*" .. var_name .. "%f[^%w_]") then
        problems[#problems + 1] = name .. "（变量 " .. var_name .. "）未注入 server_runtime.new(...)"
      end
    end
    table.sort(problems)
    assert.same({}, problems)
  end)
end)
