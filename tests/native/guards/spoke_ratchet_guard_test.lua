-- Spoke 原生重构机械棘轮守卫（#294 / ADR-0032 §4、§5）：
-- 失败方式先列：
--   1. 新 Spoke 命名空间（common.SpokeClock、server.World.*、client.Store.*、client.Views.*）
--      反向 require 存量旧债务模块（server.Mgr.*、client.MgrGameUI、client.ScreenHandlers.*、
--      client.Local*、common.OwnedUnits 等）→ 触发架构分层反向/环或把旧债务带入新树；
--   2. 就地修改 common/packages/spoke/ 或 common/packages/spoke_eggy/ 或与 docs/packages-reference.md
--      记录的上游 SHA 漂移 → 破坏上游双包零扩展边界；
--   3. 存量旧债务（OwnedUnits 调用总数、旧债务模块裸 :Connect( 数、server/main.lua MgrMap 成员数）
--      不降反增 → 重构半途回潮；
--   4. 新 Spoke 命名空间出现不保存句柄的裸 :Connect( → 局部信号无法在 s:on_cleanup 回收。

local Arch = require("tools.arch_policy")
local sha256 = require("tools.sha256")
local fs = require("tests.support.fs_fixture")
local lfs = require("lfs")

-- 上游双包完整性基线（与 docs/packages-reference.md 同步；上游整包升级时一并更新）。
local UPSTREAM_SPOKE_SHA = "ae94f086cb3eac8b51445483d819a3d648ce1db3"
local PACKAGE_SNAPSHOTS = {
  {
    root = "common/packages/spoke",
    file_count = 35,
    tree_sha256 = "3d26d684d52fdda6b8158b12c894364542cc1839653e47d3ddef1bd125d6eb59",
  },
  {
    root = "common/packages/spoke_eggy",
    file_count = 1,
    tree_sha256 = "bc1288f0146c132693a98f3a4d5fa7c8aee651c993fd9920530f72c1c16b18d8",
  },
}

-- 三类存量债务水位线（只减不增；每个垂直切片完成后单调下调对应数值直至归零）。
local DEBT_WATERMARKS = {
  owned_units_calls = 45,
  legacy_raw_connects = 124,
  mgr_map_members = 31,
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

local function package_tree_fingerprint(base_dir, relative_root)
  local full_root = base_dir == "." and relative_root or (base_dir .. "/" .. relative_root)
  local files = walk_files(full_root, false)
  local prefix = base_dir == "." and "" or (base_dir .. "/")
  local manifest = {}
  for _, full_path in ipairs(files) do
    local rel = prefix ~= "" and full_path:sub(#prefix + 1) or full_path
    local raw = assert(fs.slurp(full_path), "读不到包内文件: " .. full_path)
    manifest[#manifest + 1] = rel .. ":" .. sha256.hex(raw)
  end
  return #files, sha256.hex(table.concat(manifest, "\n"))
end

local function is_legacy_debt_file(path)
  return path:match("^server/Mgr/") ~= nil
    or path == "server/AbilityAPI.lua"
    or path:match("^server/AbilityBehaviors/") ~= nil
    or path == "client/MgrGameUI.lua"
    or path:match("^client/Local[^/]+%.lua$") ~= nil
    or path:match("^client/ScreenHandlers/") ~= nil
end

local function is_spoke_namespace_file(path)
  return path == "common/SpokeClock.lua"
    or path:match("^server/World/") ~= nil
    or path:match("^client/Store/") ~= nil
    or path:match("^client/Views/") ~= nil
end

local function format_breakdown(items)
  table.sort(items)
  return table.concat(items, "\n")
end

describe("Spoke 原生重构机械棘轮守卫", function()
  describe("新 Spoke 命名空间零反向依赖存量旧债务", function()
    it("分层门禁正确分类新 Spoke 命名空间并拦截一切对旧债务的反向依赖", function()
      local valid = Arch.check(Arch.policy, {
        modules = {
          "common.SpokeClock",
          "common.GameCfg",
          "common.packages.spoke.api",
          "server.Data.PlayerData",
          "server.World.PlayerTree",
          "server.Mgr.MgrVitals",
          "client.GameUI",
          "client.Store.ClientStore",
          "client.Views.RootView",
          "client.ScreenHandlers.ScreenMain",
        },
        edges = {
          { from = "common.SpokeClock", to = "common.packages.spoke.api" },
          { from = "server.World.PlayerTree", to = "common.SpokeClock" },
          { from = "server.World.PlayerTree", to = "server.Data.PlayerData" },
          { from = "server.Mgr.MgrVitals", to = "server.World.PlayerTree" },
          { from = "client.Store.ClientStore", to = "common.SpokeClock" },
          { from = "client.Views.RootView", to = "client.Store.ClientStore" },
          { from = "client.Views.RootView", to = "client.GameUI" },
          { from = "client.ScreenHandlers.ScreenMain", to = "client.Store.ClientStore" },
        },
      })
      assert.is_true(valid.ok, valid.message)

      local invalid_edges = {
        { from = "server.World.PlayerTree", to = "server.Mgr.MgrVitals" },
        { from = "server.World.PlayerTree", to = "server.AbilityAPI" },
        { from = "server.World.PlayerTree", to = "common.OwnedUnits" },
        { from = "client.Store.ClientStore", to = "client.LocalAttr" },
        { from = "client.Store.ClientStore", to = "client.Views.RootView" },
        { from = "client.Views.RootView", to = "client.MgrGameUI" },
        { from = "client.Views.RootView", to = "client.ScreenHandlers.ScreenMain" },
        { from = "client.Views.RootView", to = "client.LocalReelIn" },
        { from = "client.Views.RootView", to = "common.OwnedUnits" },
        { from = "common.SpokeClock", to = "common.OwnedUnits" },
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
              local managed = statement:find("=", 1, true) ~= nil
                or statement:find("return", 1, true) ~= nil
                or statement:find("use%s*%(") ~= nil
                or statement:find("on_cleanup%s*%(") ~= nil
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
        local count, digest = package_tree_fingerprint(".", expected.root)
        if count ~= expected.file_count or digest ~= expected.tree_sha256 then
          fail(
            "上游包 %s 已被修改（文件数 %d vs 基线 %d；SHA-256 %s vs 基线 %s）。"
              .. "严禁就地修改 spoke/spoke_eggy；整包升级请按 docs/packages-reference.md 同步上游 SHA 与本守卫。",
            expected.root, count, expected.file_count, digest, expected.tree_sha256
          )
        end
      end
    end)

    describe("篡改检出夹具（确保双包完整性守卫生效）", function()
      local root = fs.repo_root() .. "/tmp/spoke-pkg-guard-test"
      after_each(function() fs.rmrf(root) end)

      it("修改 1 字节或增删文件都会改变树哈希", function()
        fs.rmrf(root)
        fs.write_file(root .. "/pkg/a.lua", "return 1\n")
        local c0, h0 = package_tree_fingerprint(root, "pkg")

        fs.write_file(root .. "/pkg/a.lua", "return 2\n")
        local c1, h1 = package_tree_fingerprint(root, "pkg")
        assert.equals(c0, c1)
        assert.is_not_equal(h0, h1)

        fs.write_file(root .. "/pkg/a.lua", "return 1\n")
        fs.write_file(root .. "/pkg/b.lua", "return 0\n")
        local c2, h2 = package_tree_fingerprint(root, "pkg")
        assert.equals(c0 + 1, c2)
        assert.is_not_equal(h0, h2)
      end)
    end)
  end)

  describe("存量债务水位线只减不增棘轮", function()
    it("OwnedUnits 调用总数不超过水位线（且禁止换别名绕过统计）", function()
      local total = 0
      local detail = {}
      local bad_aliases = {}
      for _, path in ipairs(business_lua_files()) do
        if path ~= "common/OwnedUnits.lua" then
          local src = assert(fs.slurp(path), "读不到源码: " .. path)
          local code = Arch.code_only(src)
          for _, req in ipairs(Arch.requires(src)) do
            if req == "common.OwnedUnits" then
              local alias = src:match("local%s+([%w_]+)%s*=%s*require%s*%(?%s*[\"']common%.OwnedUnits[\"']")
              if alias ~= "OwnedUnits" then
                bad_aliases[#bad_aliases + 1] = path .. " 使用非标准别名 require common.OwnedUnits: " .. tostring(alias)
              end
            end
          end
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
      assert.same({}, bad_aliases)
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
      local body = src:match("local MgrMap = (%b{})")
      local members = {}
      if body then
        for key in body:gmatch("([%w_]+)%s*=%s*require%s*%(") do
          members[#members + 1] = key
        end
      end
      if #members > DEBT_WATERMARKS.mgr_map_members then
        fail("MgrMap 成员数 %d 超过水位线 %d（只减不增）：%s",
          #members, DEBT_WATERMARKS.mgr_map_members, table.concat(members, ", "))
      end
    end)
  end)
end)
