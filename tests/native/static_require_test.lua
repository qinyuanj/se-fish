-- 按名字加载模块的两处入口（MgrGameUI:GetScreen、AbilityAPI.AttachAnchor）改用登记表 + 字面量 require，
-- 架构图扫描器才能解析出依赖。失败方式先列：
--   1. 新增界面 handler 文件却没登记 → 按节点名打开时找不到 handler；
--   2. GameCfg 新配的锚点行为没登记 → 挂接时报"锚点行为模块不可用"；
--   3. 登记的模块路径写错或包升级改名 → 运行时 require 失败；
--   4. 回退成拼字符串的 require → 图上依赖再次丢失。
-- 只读源码文本校对（两个模块都依赖引擎服务），与 grill_test 的接线断言同口径。

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

local function assert_no_dynamic_require(src, path)
  for arg in src:gmatch("require%s*%(%s*([^%)]-)%s*%)") do
    assert.is_truthy(arg:match('^"[^"]*"$') or arg:match("^'[^']*'$"),
      path .. " 含非字面量 require(" .. arg .. ")")
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
  it("test_every_screen_handler_is_registered_with_literal_require", function()
    local src = read_file("client/MgrGameUI.lua")
    local pipe = assert(io.popen("ls client/ScreenHandlers"))
    local count = 0
    for file in pipe:lines() do
      local name = file:match("^(.+)%.lua$")
      if name then
        count = count + 1
        assert.matches(name .. ' = function() return require("client.ScreenHandlers.' .. name .. '") end',
          src, nil, true)
      end
    end
    pipe:close()
    assert.is_true(count > 0)
    assert_no_dynamic_require(src, "client/MgrGameUI.lua")
  end)

  it("test_every_configured_anchor_behavior_is_registered_with_literal_require", function()
    local src = read_file("server/AbilityAPI.lua")
    for name in pairs(configured_anchor_behaviors()) do
      local mod = src:match(name .. ' = function%(%) return require%("([%w_%.]+)"%) end')
      assert.is_truthy(mod, "锚点行为未登记: " .. name)
      assert.equals(name, mod:match("([%w_]+)$"))
      local path = mod:gsub("%.", "/") .. ".lua"
      assert.is_true(file_exists(path), path .. " 不存在（行为模块名写错或包升级改名）")
    end
    assert_no_dynamic_require(src, "server/AbilityAPI.lua")
  end)
end)
