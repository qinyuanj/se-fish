-- 命名门禁：三端自写代码的文件名与目录名一律 snake_case（ADR-0034 第一层）；
-- 模块表与类型名的绑定必须是 PascalCase（ADR-0037）。
-- 失败方式先列：
--   1. 新文件沿用 PascalCase / camelCase → 规范再次分叉，L2、L3 的改名成本要重来一遍；
--   2. 目录名带大写 → require 与文件名大小写精确匹配，本机不区分大小写能跑，换宿主就炸；
--   3. 豁免口径写错 → 上游整包与引擎生成物让门禁常红，最后被人静音，等于没门禁。
-- 豁免口径与 ADR-0034 一致：packages/ 上游整包、server/_trigger/ 编辑器生成物（都不进扫描）；
-- data/ 是引擎导出，不在三端扫描范围内。
local lfs = require("lfs")

local ROOTS = { "client", "common", "server" }
local SKIP_DIR_NAMES = { packages = true, _trigger = true }
local SNAKE = "^[a-z0-9][a-z0-9_]*$"

-- 名字是否合规：目录名直接判；文件名先去掉 .lua 再判
local function is_bad_name(name, is_dir)
  local stem = name
  if not is_dir then
    stem = name:gsub("%.lua$", "")
  end
  return stem:match(SNAKE) == nil
end

local function scan(path, rel, bad)
  for entry in lfs.dir(path) do
    if entry ~= "." and entry ~= ".." then
      local full = path .. "/" .. entry
      local sub = rel == "" and entry or rel .. "/" .. entry
      local mode = lfs.attributes(full, "mode")
      if mode == "directory" then
        if not SKIP_DIR_NAMES[entry] then
          if is_bad_name(entry, true) then
            bad[#bad + 1] = "目录非 snake_case：" .. sub
          end
          scan(full, sub, bad)
        end
      elseif mode == "file" and entry:match("%.lua$") then
        if is_bad_name(entry, false) then
          bad[#bad + 1] = "文件非 snake_case：" .. sub
        end
      end
    end
  end
end

describe("命名门禁", function()
  it("test_judge_rejects_pascal_and_camel_keeps_snake", function()
    assert.is_true(is_bad_name("GameUI.lua", false))
    assert.is_true(is_bad_name("worldHost.lua", false))
    assert.is_true(is_bad_name("Views", true))
    assert.is_false(is_bad_name("ability_behaviors", true))
    assert.is_false(is_bad_name("game_ui.lua", false))
    assert.is_false(is_bad_name("world_host", true))
    assert.is_false(is_bad_name("v1_2_notes.lua", false))
  end)

  it("test_three_ends_only_snake_case_files_and_dirs", function()
    local bad = {}
    for _, root in ipairs(ROOTS) do
      assert.is_truthy(lfs.attributes(root, "mode"), root .. " 不存在")
      scan(root, root, bad)
    end
    assert.equals(0, #bad, "以下路径不是 snake_case：\n" .. table.concat(bad, "\n"))
  end)
end)

-- 第二层（ADR-0037）：文件名是 snake_case，但模块表与类型名必须是 PascalCase。
-- 失败方式先列：把 local X = require(...) 的 X 写成 snake_case，会让「类型」与「值」同形，
-- 读代码时分不出 client_store 是模块表还是数字，口径迟早漂回全 snake。
local PASCAL = "^[A-Z][A-Za-z0-9]*$"

local function walk_lua(path, rel, out)
  for entry in lfs.dir(path) do
    if entry ~= "." and entry ~= ".." then
      local full = path .. "/" .. entry
      local sub = rel .. "/" .. entry
      local mode = lfs.attributes(full, "mode")
      if mode == "directory" then
        if not SKIP_DIR_NAMES[entry] then walk_lua(full, sub, out) end
      elseif mode == "file" and entry:match("%.lua$") then
        out[#out + 1] = { path = full, rel = sub }
      end
    end
  end
end

describe("模块表命名", function()
  it("test_module_table_bindings_are_pascal_case", function()
    local files, bad = {}, {}
    for _, root in ipairs(ROOTS) do
      walk_lua(root, root, files)
    end
    for _, item in ipairs(files) do
      local handle = io.open(item.path, "r")
      local src = handle:read("*a")
      handle:close()
      for name in src:gmatch("local%s+([%a_][%w_]*)%s*=%s*require%s*%(") do
        if not name:match(PASCAL) then
          bad[#bad + 1] = item.rel .. " : local " .. name .. " = require(...)"
        end
      end
    end
    assert.equals(0, #bad, "模块表绑定不是 PascalCase：\n" .. table.concat(bad, "\n"))
  end)

  it("test_pascal_judgement_accepts_types_rejects_values", function()
    assert.is_truthy(("GameCfg"):match(PASCAL))
    assert.is_truthy(("SpokeRuntime"):match(PASCAL))
    assert.is_nil(("game_cfg"):match(PASCAL))
    assert.is_nil(("_private"):match(PASCAL))
  end)
end)

-- 第三层兜底（#337）：旧名字符串键与动态字段守卫。
-- 失败方式先列：
--   1. 动态下标 t["OldField"]、表键 ["OldField"] = ... 或 rawget/rawset(t, "OldField")
--      在 EmmyLua 重命名与静态检查中是盲区，漏改会导致运行时静默取 nil；
--   2. 若用“所有字符串键一律 snake_case”的粗暴规则，会把 EUI 节点键、Spoke 作用域名、
--      全局模块名 REUtil、策划表 ID 与 ADR-0037 冻结键全打成误报，导致守卫被静音。
-- 口径：拦截动态键位置中出现已迁移的旧自研字段/方法名（以及未豁免的 camelCase 键），
-- 同时显式豁免 ADR-0037 冻结动态键、全局模块名与策划表 ID 枚举文件。
local BANNED_OLD_KEYS = {
  -- L3/L4 已迁移的高危旧字段与旧方法名
  Active = true,
  AddFish = true,
  AddItem = true,
  AfterIdle = true,
  BackpackCapacity = true,
  BindCombatChannel = true,
  CallBack = true,
  CameraDistance = true,
  CanAct = true,
  CheckZone = true,
  CombatRE = true,
  DropItem = true,
  EatBait = true,
  FishCoin = true,
  GetAttack = true,
  GetFish = true,
  GetItem = true,
  GetReelState = true,
  GetState = true,
  GetUiRoot = true,
  HeadHeight = true,
  InteractRange = true,
  IsDead = true,
  IsDowned = true,
  ItemBarCapacity = true,
  LastReason = true,
  LongPressSec = true,
  MaxHealth = true,
  MaxHunger = true,
  MoveSlot = true,
  Msg = true,
  NextFish = true,
  PlayerWalkSpeed = true,
  Ref = true,
  Root = true,
  SafePoint = true,
  SetFocus = true,
  SetHealth = true,
  SetHunger = true,
  Settle = true,
  -- 通信与自研 camelCase 旧键
  fishId = true,
  itemId = true,
  maxHealth = true,
  maxHunger = true,
  readKey = true,
  requestKey = true,
  routeId = true,
  targetId = true,
  targetType = true,
  upgradeLevel = true,
  upgradeLevels = true,
}

-- 策划表 ID 枚举文件与全局模块名豁免（ADR-0034 / ADR-0037）
local STRING_KEY_SKIP_FILES = {
  ["common/cfg/content_ledger.lua"] = true,
}
local STRING_KEY_EXEMPT = {
  REUtil = true,
  -- ADR-0037 冻结的 25 个动态键（含 Regions / Rects / 计时动态键）
  ActiveUntil = true,
  SpecialAt = true,
  JabAt = true,
  PinchAt = true,
  ChargeAt = true,
  JumpAt = true,
  RoarAt = true,
  TailAt = true,
  ClawAt = true,
  NextReefDiveAt = true,
  NextThrowAt = true,
  CreateResult = true,
}

local function strip_line_comment(line)
  return line:gsub("%-%-.*$", "")
end

local function find_bad_string_keys_in_line(line, rel, line_no, bad)
  if STRING_KEY_SKIP_FILES[rel] then return end
  local code = strip_line_comment(line)
  local function check_key(k)
    if STRING_KEY_EXEMPT[k] then return end
    if BANNED_OLD_KEYS[k] then
      bad[#bad + 1] = string.format("%s:%d : 禁止使用已迁移旧名字符串键 %q", rel, line_no, k)
    end
  end
  for _, key in code:gmatch("%[%s*([\"'])([%a_][%w_]*)%1%s*%]") do
    check_key(key)
  end
  for _, key in code:gmatch("raw[gs]et%s*%([^,]+,%s*([\"'])([%a_][%w_]*)%1") do
    check_key(key)
  end
end

describe("旧名字符串键守卫", function()
  it("test_string_key_guard_rejects_old_keys_and_respects_exemptions", function()
    local bad = {}
    find_bad_string_keys_in_line('local x = tbl["GetState"]', "client/foo.lua", 10, bad)
    find_bad_string_keys_in_line('local y = rawget(tbl, "fishId")', "server/bar.lua", 20, bad)
    find_bad_string_keys_in_line('local z = rawget(_G, "REUtil")', "client/foo.lua", 30, bad)
    find_bad_string_keys_in_line('local t = fish["ActiveUntil"]', "server/world_host/fish_tree.lua", 40, bad)
    assert.equals(2, #bad)
    assert.is_truthy(bad[1]:find("GetState", 1, true))
    assert.is_truthy(bad[2]:find("fishId", 1, true))
  end)

  it("test_three_ends_no_banned_old_string_keys", function()
    local files, bad = {}, {}
    for _, root in ipairs(ROOTS) do
      walk_lua(root, root, files)
    end
    for _, item in ipairs(files) do
      local handle = io.open(item.path, "r")
      local idx = 0
      for line in handle:lines() do
        idx = idx + 1
        find_bad_string_keys_in_line(line, item.rel, idx, bad)
      end
      handle:close()
    end
    assert.equals(0, #bad, "发现残留的旧名字符串键：\n" .. table.concat(bad, "\n"))
  end)
end)
