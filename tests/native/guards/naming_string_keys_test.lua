-- 旧名字符串键守卫：#337 的第二层，L3a/L3b 改过的方法名不许再以字符串键形式留在业务源码里。
-- 失败方式先列：
--   1. `local Actions = { board = "board" }` 这类分发表仍用旧方法名 → 运行期取不到方法，L3b 的 7 轮修键成本重演；
--   2. `has_method(x, "Start")` / `x["Attach"]` 这类按名查找仍用旧名 → 静态改名器看不见，测试也未必覆盖；
--   3. 把守卫写成「所有旧名子串一律禁」→ `action = "board"` 这类协议串、`Kind = 'land'` 这类策划枚举、
--      `GetService("Players")` 这类官方契约会常红，最后被人静音。
-- 口径：业务源码里所有旧名字符串字面量都拦；协议字段名、官方服务名/属性名、配置枚举键与已知协议调用走白名单。
-- 映射数据来自 tools/naming/data/l3a_renames.txt、l3b_renames.txt 与 post_l3_renames.txt。
local fs = require("tests.support.fs_fixture")
local guard = require("tools.naming_guard")

describe("旧名字符串键守卫", function()
  it("test_rejects_old_name_as_table_value", function()
    local bad = guard.scan_source("server/x.lua", [[
local Actions = { board = "Board", Return = "ReturnBack" }
]], {})
    assert.equals(2, #bad)
    assert.equals("server/x.lua:1", bad[1].where)
    assert.equals("Board", bad[1].literal)
  end)

  it("test_rejects_plain_old_name_literal", function()
    local bad = guard.scan_source("server/x.lua", [[local method = "Board"]], {})
    assert.equals(1, #bad)
    assert.equals("Board", bad[1].literal)
    assert.equals("server/x.lua:1", bad[1].where)
  end)

  it("test_allows_official_and_protocol_call_contexts", function()
    local bad = guard.scan_source("server/x.lua", [[
self:reply(player, "Invite", true)
default_fire_re("WeaponAction", payload)
ps:dock("PopupCells")
write_attr(player, "MaxHealth", 1)
local keys = { "Health", "MaxHealth" }
]], {})
    assert.equals(0, #bad)
  end)

  it("test_allows_official_names_in_assignments_and_folded_calls", function()
    local bad = guard.scan_source("server/x.lua", [=[
local label = "Text"
local hp = "MaxHealth"
self:reply(player,
  true,
  "Board")
]=], {})
    assert.equals(0, #bad)
  end)

  it("test_rejects_old_name_under_non_protocol_dispatch_key", function()
    local bad = guard.scan_source("server/x.lua", [[local Actions = { command = "Start" }]], {})
    assert.equals(1, #bad)
    assert.equals("Start", bad[1].literal)
  end)

  it("test_rejects_failed_lookalike_context", function()
    local bad = guard.scan_source("server/x.lua", [[local failed = "Board"]], {})
    assert.equals(1, #bad)
  end)

  it("test_rejects_old_name_in_has_method_and_bracket_lookup", function()
    local bad = guard.scan_source("server/x.lua", [[
if has_method(host, "Start") then return host["Attach"](host) end
]], {})
    assert.equals(2, #bad)
    assert.equals("Start", bad[1].literal)
    assert.equals("Attach", bad[2].literal)
  end)

  it("test_allows_protocol_and_official_keys", function()
    local bad = guard.scan_source("server/x.lua", [[
local a = { action = "Board", Kind = 'Land', name = "Text" }
local p = game:GetService("Players")
local hp = player:GetAttribute("MaxHealth")
]], {})
    assert.equals(0, #bad)
  end)

  it("test_ignores_comments_and_long_strings", function()
    local bad = guard.scan_source("server/x.lua", [=[
-- { board = "Board" }
local text = [[{ board = "Board" }]]
local quoted = "{ board = \"Board\" }"
]=], {})
    assert.equals(0, #bad)
  end)

  it("test_honors_exemption_for_gm_protocol_action", function()
    local src = [[local Actions = { GetState = 'GetState' }]]
    assert.equals(1, #guard.scan_source("server/world_host/player_gm.lua", src, {}))
    local exemptions = guard.load_exemptions(fs.repo_root())
    assert.equals(0, #guard.scan_source("server/world_host/player_gm.lua", src, exemptions))
  end)

  it("test_reports_file_and_line_for_repo_violation", function()
    local bad = guard.scan_source("server/world_host/ferry_route.lua", [[
local Actions = { board = "Board" }
]], {})
    assert.equals(1, #bad)
    assert.equals("server/world_host/ferry_route.lua:1", bad[1].where)
    assert.equals("Board", bad[1].literal)
    assert.equals("board", bad[1].new_name)
  end)

  it("test_repo_has_no_unexempted_old_name_strings", function()
    local bad, reason = guard.scan(fs.repo_root())
    assert.is_truthy(bad, reason)
    local lines = {}
    for _, item in ipairs(bad) do lines[#lines + 1] = item.where .. " " .. item.literal .. " -> " .. item.new_name end
    assert.equals(0, #bad, "旧名字符串键：\n" .. table.concat(lines, "\n"))
  end)

  it("test_empty_scan_root_is_not_a_green_pass", function()
    local empty = fs.temp_dir()
    local bad, reason = guard.scan(empty, fs.repo_root())
    fs.rmrf(empty)
    assert.is_nil(bad)
    assert.matches("没有扫到任何业务文件", reason, 1, true)
  end)

  it("test_rejects_post_l3_and_rawget_rawset_old_keys", function()
    local bad = guard.scan_source("server/x.lua", [[
local a = tbl["upgradeLevel"]
local k = "routeId"
local h = rawget(tbl, "maxHealth")
rawset(tbl, "LongPressSec", 1)
local mh = rawget(tbl, "MaxHealth")
local z = rawget(_G, "REUtil")
local t = fish["ActiveUntil"]
]], {})
    assert.equals(5, #bad)
    assert.equals("upgradeLevel", bad[1].literal)
    assert.equals("routeId", bad[2].literal)
    assert.equals("maxHealth", bad[3].literal)
    assert.equals("LongPressSec", bad[4].literal)
    assert.equals("MaxHealth", bad[5].literal)
  end)

  it("test_mapping_data_is_unique_and_snake_case", function()
    local names = guard.load_names(fs.repo_root())
    local conflicts = guard.find_duplicate_new_names({ l3a = { { old_name = "A", new_name = "x" }, { old_name = "B", new_name = "x" } }, l3b = {} })
    assert.same({ "x" }, conflicts)
    assert.equals(449, #names.l3a)
    assert.equals(45, #names.l3b)
    assert.equals(18, #names.post_l3)
    assert.equals(0, #guard.find_duplicate_old_names(names))
    assert.equals(0, #guard.find_duplicate_new_names(names))
    for _, row in ipairs(names.l3a) do
      assert.is_truthy(row.new_name:match("^[a-z0-9][a-z0-9_]*$"), row.old_name .. " -> " .. row.new_name)
    end
    for _, row in ipairs(names.l3b) do
      assert.is_truthy(row.new_name:match("^[a-z0-9][a-z0-9_]*$"), row.old_name .. " -> " .. row.new_name)
    end
    for _, row in ipairs(names.post_l3) do
      assert.is_truthy(row.new_name:match("^[a-z0-9][a-z0-9_]*$"), row.old_name .. " -> " .. row.new_name)
    end
  end)
end)
