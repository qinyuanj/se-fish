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

-- 第三层（ADR-0034 的 L3、ADR-0037 的口径）：方法名与自研配置段名必须是 snake_case。
-- 失败方式先列：
--   1. 新写 function PlayerData:Serialize() → 与已改完的 player_data:serialize 并存两套方法名，L3 剩下的方法要付第二遍改名成本；
--   2. 新写 GameCfg.SomeSection = { ... } → 与已改完的 GameCfg.some_section 并存，读代码分不清哪个还有效；
--   3. 把守卫写成「存量必须为零」→ L3 还在迁移中，全仓常红后必然被静音（ADR-0034「门禁先开会让全仓常红」的教训）。
-- 所以存量冻结在 data/legacy_pascal_names_baseline.txt：基线之外的新名字一律失败，基线内的等 L3 搬完再删行。
-- 扫描面只有两处：函数定义的名字尾段、GameCfg 的段名。官方契约五类豁免见 ADR-0034「官方契约原样」，
-- 包内接口实现的方法名跟随接口（ADR-0037），所以 Attach 这类由 INTERFACE_METHODS 点名放行。
local BASELINE = "tests/native/guards/data/legacy_pascal_names_baseline.txt"
local INTERFACE_METHODS = { Attach = true }

-- 方法名取最后一个 . 或 : 之后的尾段；表路径（GameCfg.Shop.list_for_page 里的 Shop）不参与判定。
local function pascal_method_tail(name)
  local _, tail = name:match("^(.-)([%.:]%u[%w_]*)$")
  return tail and tail:sub(2) or nil
end

local function collect_pascal_names(item, src, found)
  local line_no = 0
  for line in (src .. "\n"):gmatch("([^\n]*)\n") do
    line_no = line_no + 1
    local where = item.rel .. ":" .. line_no
    for name in line:gmatch("function%s+([%w_%.:]+)") do
      local tail = pascal_method_tail(name)
      if tail and not INTERFACE_METHODS[tail] then
        found[#found + 1] = { key = "method " .. tail, where = where }
      end
    end
    for name in line:gmatch("([%w_%.:]+)%s*=%s*function%s*%(") do
      local tail = pascal_method_tail(name)
      if tail and not INTERFACE_METHODS[tail] then
        found[#found + 1] = { key = "method " .. tail, where = where }
      end
    end
    for section in line:gmatch("GameCfg%.(%u[%w_]*)") do
      found[#found + 1] = { key = "cfg " .. section, where = where }
    end
  end
end

local function load_baseline()
  local handle = assert(io.open(BASELINE, "r"), "读不到基线 " .. BASELINE)
  local text = handle:read("*a")
  handle:close()
  local known, order, line_no = {}, {}, 0
  for line in (text .. "\n"):gmatch("([^\n]*)\n") do
    line_no = line_no + 1
    line = line:gsub("%s+$", "")
    if line ~= "" and not line:match("^#") then
      assert(not known[line], BASELINE .. ":" .. line_no .. " 行重复：" .. line)
      known[line] = true
      order[#order + 1] = line
    end
  end
  for i = 2, #order do
    assert(order[i - 1] < order[i], BASELINE .. " 未按字节序排序：" .. order[i - 1] .. " 之后是 " .. order[i])
  end
  return known
end

describe("方法与配置段命名", function()
  it("test_judge_reads_method_tail_only", function()
    assert.equals("Serialize", pascal_method_tail("PlayerData:Serialize"))
    assert.equals("Attach", pascal_method_tail("M.Attach"))
    assert.is_nil(pascal_method_tail("player_data:serialize"))
    assert.is_nil(pascal_method_tail("GameCfg.Shop.list_for_page"))
    assert.is_nil(pascal_method_tail("foo"))
  end)

  it("test_no_new_pascal_method_or_cfg_section", function()
    local known = load_baseline()
    local files, found = {}, {}
    for _, root in ipairs(ROOTS) do
      walk_lua(root, root, files)
    end
    for _, item in ipairs(files) do
      local handle = assert(io.open(item.path, "r"), "读不到 " .. item.path)
      local src = handle:read("*a")
      handle:close()
      collect_pascal_names(item, src, found)
    end
    local seen, bad = {}, {}
    for _, item in ipairs(found) do
      if not known[item.key] and not seen[item.key] then
        seen[item.key] = true
        bad[#bad + 1] = item.key .. "  首次出现 " .. item.where
      end
    end
    table.sort(bad)
    assert.same({}, bad, "新写的 PascalCase 方法名或 GameCfg 段名（ADR-0034 L3 / ADR-0037）：\n" .. table.concat(bad, "\n"))
  end)
end)

-- 旧名字符串键守卫已统一归口 tools/naming_guard.lua 与 tests/native/guards/naming_string_keys_test.lua（#337）。
