-- Spoke 原生重构机械棘轮守卫（#294 / ADR-0032 §4、§5）：
-- 失败方式先列：
--   1. 新 Spoke 命名空间（common.spoke_clock、server.world_host.*、client.store.*、client.views.*）
--      反向 require 存量旧债务模块（server.Mgr.*、server.ability_api、server.ability_behaviors.*、
--      client.MgrGameUI、client.ScreenHandlers.*、client.Local*、common.OwnedUnits）→ 破坏单向棘轮；
--   2. 就地修改 common/packages/spoke/ 或 common/packages/spoke_eggy/ 或与 docs/packages-reference.md
--      记录的上游 SHA 漂移 → 破坏上游双包零扩展边界；
--   3. 存量旧债务（OwnedUnits 调用总数、旧债务模块裸 :Connect( 数、server/main.lua MgrMap 成员数）
--      不降反增 → 重构半途回潮；
--   4. 新 Spoke 命名空间出现未保存句柄的裸 :Connect( → 局部信号无法在 s:on_cleanup 回收。

local Arch = require("tools.arch_policy")
local sha256 = require("tools.sha256")
local fs = require("tests.support.fs_fixture")
local lfs = require("lfs")

-- 上游双包完整性基线（与 docs/packages-reference.md 同步；上游整包升级时一并更新）。
local UPSTREAM_SPOKE_SHA = "7b822fe3fa0df940e5048320f1f162657e4fff28"
local PACKAGE_SNAPSHOTS = {
  {
    root = "common/packages/spoke",
    file_count = 35,
    tree_sha256 = "4d099aed50d85a2f84ec8622b7a0379345a8148b956ccda6d2b1e16b21feeeab",
  },
  {
    root = "common/packages/spoke_eggy",
    file_count = 1,
    tree_sha256 = "280865bbdf091ac3fab03d22a879c6b1ccd295dfb5ec037995c1d08e06b43c8d",
  },
}

local DEBT_WATERMARKS = {
  owned_units_calls = 0,
  legacy_raw_connects = 0,
  mgr_map_members = 0,
}

-- 以下两组为 #309 已删旧模块的防回潮对照清单，刻意保留旧路径/旧模块名以阻止回归，非失效引用。
local REMOVED_FISH_LEGACY_FILES = {
  "server/Mgr/MgrFishUnit.lua",
  "server/Mgr/MgrFishCarrier.lua",
  "server/Mgr/MgrAi.lua",
  "server/Mgr/MgrAiTarget.lua",
  "client/views/FishCombatLabel.lua",
  "client/views/GarBiteWarning.lua",
}

local FORBIDDEN_FISH_LEGACY_MODULES = {
  "server.Mgr.MgrFishUnit",
  "server.Mgr.MgrFishCarrier",
  "server.Mgr.MgrAi",
  "server.Mgr.MgrAiTarget",
  "client.views.FishCombatLabel",
  "client.views.GarBiteWarning",
}

local BUSINESS_ROOTS = { "client", "common", "server" }

local function fail(fmt, ...)
  assert.is_true(false, string.format(fmt, ...))
end

local function walk_files(root, skip_packages, out)
  out = out or {}
  local attr = lfs.attributes(root)
  if not attr or attr.mode ~= "directory" then return out end
  for _, name in ipairs(fs.list_dir(root)) do
    local full = root .. "/" .. name
    local mode = lfs.attributes(full, "mode")
    if mode == "directory" then
      if name ~= "_trigger" and (not skip_packages or name ~= "packages") then
        walk_files(full, skip_packages, out)
      end
    elseif mode == "file" then
      out[#out + 1] = full
    end
  end
  table.sort(out)
  return out
end

local function business_lua_files()
  local out = {}
  for _, root in ipairs(BUSINESS_ROOTS) do
    for _, path in ipairs(walk_files(root, true)) do
      if path:match("%.lua$") then
        out[#out + 1] = path
      end
    end
  end
  table.sort(out)
  return out
end

local function package_tree_fingerprint(relative_root)
  local files = walk_files(relative_root, false)
  local manifest = {}
  for _, full_path in ipairs(files) do
    local raw = assert(fs.slurp(full_path), "读不到包内文件: " .. full_path)
    manifest[#manifest + 1] = full_path .. ":" .. sha256.hex(raw)
  end
  return #files, sha256.hex(table.concat(manifest, "\n"))
end

local function is_legacy_debt_file(path)
  return path:match("^server/Mgr/") ~= nil
    or path == "server/ability_api.lua"
    or path:match("^server/ability_behaviors/") ~= nil
    or path == "client/MgrGameUI.lua"
    or path:match("^client/Local[^/]+%.lua$") ~= nil
    or path:match("^client/ScreenHandlers/") ~= nil
end

local function is_spoke_namespace_file(path)
  return path == "common/spoke_clock.lua"
    or path:match("^server/world_host/") ~= nil
    or path:match("^client/store/") ~= nil
    or path:match("^client/views/") ~= nil
end

local function format_breakdown(items)
  table.sort(items)
  return table.concat(items, "\n")
end

-- 仅识别真实赋值 `=`（排除 `==`、`~=`、`<=`、`>=`）。
local function has_assignment(statement)
  local from = 1
  while true do
    local eq = statement:find("=", from, true)
    if not eq then return false end
    local prev = eq > 1 and statement:sub(eq - 1, eq - 1) or ""
    local next_ch = statement:sub(eq + 1, eq + 1)
    if next_ch ~= "=" and not prev:match("[=~<>]") then
      return true
    end
    from = eq + 1
  end
end

-- 剥除 Lua 注释（保留字符串字面量与换行，便于按源码位置校验 require 绑定形式），
-- 同时记录字符串字面量区间避免把字符串内的伪 require 当作真实调用。
local function strip_comments(source)
  local out, holes, index = {}, {}, 1
  while index <= #source do
    local char, next_char = source:sub(index, index), source:sub(index + 1, index + 1)
    local long = source:match("^%[(=*)%[", index)
    if char == "-" and next_char == "-" then
      local eqs = source:match("^%[(=*)%[", index + 2)
      local stop
      if eqs then
        local closer = "]" .. eqs .. "]"
        local found = source:find(closer, index + 4 + #eqs, true)
        stop = found and found + #closer - 1 or #source
      else
        local newline = source:find("\n", index, true)
        stop = newline and newline - 1 or #source
      end
      out[#out + 1] = (source:sub(index, stop):gsub("[^\r\n]", " "))
      index = stop + 1
    elseif long then
      local closer = "]" .. long .. "]"
      local found = source:find(closer, index + 2 + #long, true)
      local stop = found and found + #closer - 1 or #source
      out[#out + 1] = source:sub(index, stop)
      holes[#holes + 1] = { index + 2 + #long, stop - #closer }
      index = stop + 1
    elseif char == '"' or char == "'" then
      local cursor = index + 1
      while cursor <= #source do
        local current = source:sub(cursor, cursor)
        if current == "\\" then
          cursor = cursor + 2
        elseif current == char then
          break
        else
          cursor = cursor + 1
        end
      end
      local stop = math.min(cursor, #source)
      out[#out + 1] = source:sub(index, stop)
      holes[#holes + 1] = { index + 1, stop - 1 }
      index = stop + 1
    else
      out[#out + 1] = char
      index = index + 1
    end
  end
  return table.concat(out), holes
end

local function in_hole(holes, position)
  for _, hole in ipairs(holes) do
    if position >= hole[1] and position <= hole[2] then return true end
  end
  return false
end

-- 逐一找出文件中所有指向 target_module 的静态 require，验证每一处都严格写成
-- `local OwnedUnits = require(...)` 且无后缀链式调用，避免换别名或直接链式调用绕过计数。
local function check_owned_units_bindings(path, src)
  local text, holes = strip_comments(src)
  local bad, from = {}, 1
  while true do
    local first, last = text:find("require", from, true)
    if not first then break end
    from = last + 1
    local before = first > 1 and text:sub(first - 1, first - 1) or ""
    local prev_token = text:sub(1, first - 1):match("([%.:]+)%s*$")
    local after = text:sub(last + 1, last + 1)
    if not in_hole(holes, first)
        and prev_token ~= "." and prev_token ~= ":"
        and not before:match("[%w_]") and not after:match("[%w_]") then
      local cursor = last + 1
      while text:sub(cursor, cursor):match("%s") do cursor = cursor + 1 end
      local has_paren = false
      if text:sub(cursor, cursor) == "(" then
        has_paren = true
        cursor = cursor + 1
        while text:sub(cursor, cursor):match("%s") do cursor = cursor + 1 end
      end
      local quote = text:sub(cursor, cursor)
      local value, call_end
      if quote == '"' or quote == "'" then
        local stop = cursor + 1
        while stop <= #text do
          local ch = text:sub(stop, stop)
          if ch == "\\" then
            stop = stop + 2
          elseif ch == quote then
            break
          else
            stop = stop + 1
          end
        end
        local decode = load("return " .. text:sub(cursor, stop), "require_literal", "t", {})
        if decode then value = decode() end
        call_end = stop
      else
        local eqs = text:match("^%[(=*)%[", cursor)
        if eqs then
          local start = cursor + 2 + #eqs
          local stop = text:find("]" .. eqs .. "]", start, true)
          if stop then
            value = text:sub(start, stop - 1):gsub("^\r?\n", "")
            call_end = stop + #eqs + 1
          end
        end
      end
      if value == "common.OwnedUnits" then
        local tail = call_end and text:sub(call_end + 1) or ""
        if has_paren then
          tail = tail:gsub("^%s*%)", "", 1)
        end
        local line_no = select(2, text:sub(1, first):gsub("\n", "")) + 1
        local prefix = text:sub(1, first - 1)
        local bound = prefix:match("local%s+OwnedUnits%s*=%s*$") ~= nil
        local chained = tail:match("^%s*[%.%:%[]") ~= nil
        if not bound or chained then
          bad[#bad + 1] = string.format(
            "%s:%d 须严格写作 `local OwnedUnits = require(\"common.OwnedUnits\")`（禁止换别名或链式调用绕过统计）",
            path, line_no
          )
        end
      end
    end
  end
  return bad
end

-- 解析去注释/字符串后的表体 `{ ... }`，统计全部顶层成员条目数（兼容任意右值写法）。
local function count_top_level_table_entries(table_body)
  local inner = table_body:sub(2, -2)
  local depth_brace, depth_paren, depth_bracket = 0, 0, 0
  local entries = {}
  local chunk_start = 1
  local function flush_chunk(stop_index)
    local item = inner:sub(chunk_start, stop_index):match("^%s*(.-)%s*$")
    if item ~= "" then
      entries[#entries + 1] = item
    end
  end
  for i = 1, #inner do
    local ch = inner:sub(i, i)
    if ch == "{" then
      depth_brace = depth_brace + 1
    elseif ch == "}" then
      depth_brace = depth_brace - 1
    elseif ch == "(" then
      depth_paren = depth_paren + 1
    elseif ch == ")" then
      depth_paren = depth_paren - 1
    elseif ch == "[" then
      depth_bracket = depth_bracket + 1
    elseif ch == "]" then
      depth_bracket = depth_bracket - 1
    elseif (ch == "," or ch == ";")
        and depth_brace == 0 and depth_paren == 0 and depth_bracket == 0 then
      flush_chunk(i - 1)
      chunk_start = i + 1
    end
  end
  flush_chunk(#inner)
  return entries
end

describe("Spoke 原生重构机械棘轮守卫", function()
  describe("新 Spoke 命名空间零反向依赖存量旧债务", function()
    it("分层门禁正确分类新 Spoke 命名空间并拦截一切对旧债务的反向依赖", function()
      local valid = Arch.check(Arch.policy, {
        modules = {
          "common.spoke_clock",
          "common.game_cfg",
          "common.packages.spoke.api",
          "server.data.player_data",
          "server.world_host.player_tree",
          "server.ability_behaviors.melee_hit",
          "client.game_ui",
          "client.store.ClientStore",
          "client.views.RootView",
          "server.ability_api",
        },
        edges = {
          { from = "common.spoke_clock", to = "common.packages.spoke.api" },
          { from = "server.world_host.player_tree", to = "common.spoke_clock" },
          { from = "server.world_host.player_tree", to = "server.data.player_data" },
          { from = "server.ability_behaviors.melee_hit", to = "server.world_host.player_tree" },
          { from = "client.store.ClientStore", to = "common.spoke_clock" },
          { from = "client.views.RootView", to = "client.store.ClientStore" },
          { from = "client.views.RootView", to = "client.game_ui" },
          { from = "server.ability_api", to = "server.world_host.player_tree" },
        },
      })
      assert.is_true(valid.ok, valid.message)

      local invalid_edges = {
        { from = "server.world_host.player_tree", to = "server.ability_behaviors.melee_hit" },
        { from = "server.world_host.player_tree", to = "server.ability_api" },
        { from = "client.store.ClientStore", to = "client.views.RootView" },
        { from = "client.views.RootView", to = "client.MgrGameUI" },
        { from = "client.views.RootView", to = "client.ScreenHandlers.ScreenMain" },
        { from = "client.views.ReelOverlayView", to = "client.LocalMotorUnitCtrl" },
        { from = "client.views.RootView", to = "common.OwnedUnits" },
        { from = "common.spoke_clock", to = "common.OwnedUnits" },
      }
      for _, edge in ipairs(invalid_edges) do
        local result = Arch.check(Arch.policy, {
          modules = { edge.from, edge.to },
          edges = { edge },
        })
        if result.ok then
          fail("门禁未拦截反向依赖：%s -> %s", edge.from, edge.to)
        end
      end
    end)

    it("真实仓库中新 Spoke 命名空间模块零反向依赖且不含无托管裸 :Connect(", function()
      local graph = assert(Arch.scan(".", Arch.policy))
      local result = Arch.check(Arch.policy, graph)
      local reverse_deps = {}
      for _, violation in ipairs(result.violations) do
        if violation.rule == "spoke_no_legacy_reverse_dep" then
          reverse_deps[#reverse_deps + 1] = violation.from .. " -> " .. violation.to
        end
      end
      assert.same({}, reverse_deps)

      local bad_connects = {}
      for _, path in ipairs(business_lua_files()) do
        if is_spoke_namespace_file(path) then
          local src = assert(fs.slurp(path), "读不到源码: " .. path)
          local code = Arch.code_only(src)
          local line_no = 0
          for line in (code .. "\n"):gmatch("([^\n]*)\n") do
            line_no = line_no + 1
            local pos = line:find(":%s*Connect%s*%(")
            if pos then
              local statement = line:sub(1, pos - 1):match("[^;]*$") or ""
              local managed = has_assignment(statement)
                or statement:find("%f[%w_]return%f[^%w_]") ~= nil
              if not managed then
                bad_connects[#bad_connects + 1] = path .. ":" .. line_no .. " 新 Spoke 模块出现未保存句柄的裸 :Connect("
              end
            end
          end
        end
      end
      assert.same({}, bad_connects)
    end)
  end)

  describe("spoke 与 spoke_eggy 上游双包零变更守卫", function()
    it("双包文件数与整树 SHA-256 与基线一致，且 docs/packages-reference.md 记录同源 SHA", function()
      local doc = assert(fs.slurp("docs/packages-reference.md"), "读不到 docs/packages-reference.md")
      local sha_hits = 0
      for _ in doc:gmatch(UPSTREAM_SPOKE_SHA) do
        sha_hits = sha_hits + 1
      end
      if sha_hits < 2 then
        fail("docs/packages-reference.md 须同时记录 spoke 与 spoke_eggy 的上游 SHA %s（实际命中 %d 处）",
          UPSTREAM_SPOKE_SHA, sha_hits)
      end

      for _, expected in ipairs(PACKAGE_SNAPSHOTS) do
        local count, digest = package_tree_fingerprint(expected.root)
        if count ~= expected.file_count or digest ~= expected.tree_sha256 then
          fail(
            "上游包 %s 已被修改（文件数 %d vs 基线 %d；SHA-256 %s vs 基线 %s）。"
              .. "严禁就地修改 spoke/spoke_eggy；整包升级请按 docs/packages-reference.md 同步上游 SHA 与本守卫。",
            expected.root, count, expected.file_count, digest, expected.tree_sha256
          )
        end
      end
    end)
  end)

  describe("存量债务水位线只减不增棘轮", function()
    it("OwnedUnits 调用总数不超过水位线（且禁止换别名或链式调用绕过统计）", function()
      local total = 0
      local detail = {}
      local bad_bindings = {}
      for _, path in ipairs(business_lua_files()) do
        if path ~= "common/OwnedUnits.lua" then
          local src = assert(fs.slurp(path), "读不到源码: " .. path)
          for _, problem in ipairs(check_owned_units_bindings(path, src)) do
            bad_bindings[#bad_bindings + 1] = problem
          end
          local code = Arch.code_only(src)
          local count = 0
          for _ in code:gmatch("%f[%w_]OwnedUnits%s*%.%s*[%w_]+%s*%(") do
            count = count + 1
          end
          if count > 0 then
            total = total + count
            detail[#detail + 1] = string.format("  %s = %d", path, count)
          end
        end
      end
      assert.same({}, bad_bindings)
      if total > DEBT_WATERMARKS.owned_units_calls then
        fail("OwnedUnits 调用总数 %d 超过水位线 %d（只减不增）：\n%s",
          total, DEBT_WATERMARKS.owned_units_calls, format_breakdown(detail))
      end
    end)

    it("旧债务模块裸 :Connect( 总数不超过水位线", function()
      local total = 0
      local detail = {}
      for _, path in ipairs(business_lua_files()) do
        if is_legacy_debt_file(path) then
          local src = assert(fs.slurp(path), "读不到源码: " .. path)
          local code = Arch.code_only(src)
          local count = 0
          for _ in code:gmatch(":%s*Connect%s*%(") do
            count = count + 1
          end
          if count > 0 then
            total = total + count
            detail[#detail + 1] = string.format("  %s = %d", path, count)
          end
        end
      end
      if total > DEBT_WATERMARKS.legacy_raw_connects then
        fail("旧债务模块裸 :Connect( 总数 %d 超过水位线 %d（只减不增）：\n%s",
          total, DEBT_WATERMARKS.legacy_raw_connects, format_breakdown(detail))
      end
    end)

    it("server/main.lua 的 MgrMap 成员数不超过水位线", function()
      local src = assert(fs.slurp("server/main.lua"), "读不到 server/main.lua")
      local code = Arch.code_only(src)
      local body = code:match("local%s+MgrMap%s*=%s*(%b{})")
      local mgr_files = {}
      for _, path in ipairs(walk_files("server/Mgr", true)) do
        if path:match("%.lua$") then
          mgr_files[#mgr_files + 1] = path
        end
      end
      if not body then
        if #mgr_files > 0 then
          fail("server/main.lua 找不到 local MgrMap 表，但 server/Mgr/ 仍有 %d 个模块未清空", #mgr_files)
        end
        return
      end
      local entries = count_top_level_table_entries(body)
      if #entries > DEBT_WATERMARKS.mgr_map_members then
        fail("MgrMap 成员数 %d 超过水位线 %d（只减不增）：\n%s",
          #entries, DEBT_WATERMARKS.mgr_map_members, table.concat(entries, "\n"))
      end
    end)
  end)

  describe("活鱼旧模块棘轮（#309）", function()
    it("旧活鱼、载体、AI 管理器与客户端战斗标签已不可加载且业务源码零引用", function()
      for _, path in ipairs(REMOVED_FISH_LEGACY_FILES) do
        assert.is_false(fs.exists(path), path .. " 仍在")
      end
      local hits = {}
      for _, path in ipairs(business_lua_files()) do
        local text = fs.slurp(path) or ""
        for _, name in ipairs(FORBIDDEN_FISH_LEGACY_MODULES) do
          if text:find(name, 1, true) then
            hits[#hits + 1] = path .. " -> " .. name
          end
        end
      end
      assert.equals(0, #hits, table.concat(hits, "\n"))
    end)
  end)
end)
