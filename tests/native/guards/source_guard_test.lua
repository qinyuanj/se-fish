-- 三端源码守卫：原 CODING_STANDARDS.md 里能机械判定的条目搬到这里（人审只留判断类规则）。
-- 失败方式先列：
--   1. require 少写工程前缀 → 裸名不在宿主的模块搜索路径里，运行期才炸；
--   2. require 的大小写与文件名不一致 → 本机（不区分大小写）能跑，换环境或宿主后炸；
--   3. require 到不存在的文件 → 模块改名或删除后只在运行时报错；
--   4. 业务代码 require 引擎存根 EggyAPI / EggyEditorAPI → 类型存根被当模块加载；
--   5. 业务代码出现 io / os / package / debug 调用 → SE 沙盒里这些是 nil，调用即崩；
-- 三端 packages/ 是整包交付的外来件（ADR-0021），不吃第 5、6 条；第 2、3 条照查（包按原始字节交付，路径同样不能错）。
-- 这边只管源码文本的卫生，所以两边各自独立，改登记表不必动这里。
local fs = require("tests.support.fs_fixture")
local Arch = require("tools.arch_policy")
local lfs = require("lfs")

local BUSINESS_ROOTS = { "client", "common", "server" }
local BANNED_GLOBALS = { "io", "os", "package", "debug" }
local REENTRANT_ENTRIES = {
  mount = true,
  OnPlayerAdded = true,
  Attach = true,
  Bind = true,
  bind_host = true,
  WatchCharacter = true,
}

local function is_reentrant_entry(path, name)
  if REENTRANT_ENTRIES[name] then return true end
  if path:match("^client/views/") and (name == "spec" or name:match("_spec$")) then
    return true
  end
  return false
end

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

local function business_files()
  local out = {}
  for _, path in ipairs(source_files()) do
    if not path:find("/packages/", 1, true) then out[#out + 1] = path end
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

-- 每条断言都是同一形状：逐文件收问题，排序后要求为空。collect 返回 nil 或问题列表，
-- 这样一条违规不会掩盖同一文件里的下一条，失败消息也自带文件路径。
local function scan(files, collect)
  local bad = {}
  for _, path in ipairs(files) do
    for _, why in ipairs(collect(path, source_of(path)) or {}) do
      bad[#bad + 1] = why
    end
  end
  table.sort(bad)
  assert.same({}, bad)
end

describe("三端源码守卫", function()
  it("test_scans_the_whole_business_tree", function()
    assert.is_true(#source_files() > 200,
      "三端只扫到 " .. #source_files() .. " 个模块文件，扫描口径坏了")
  end)

  it("test_requires_carry_project_prefix", function()
    scan(business_files(), function(path, src)
      local bad = {}
      for _, mod in ipairs(Arch.requires(src)) do
        if not mod:match("^client%.") and not mod:match("^common%.") and not mod:match("^server%.") then
          bad[#bad + 1] = path .. " → " .. mod
        end
      end
      return bad
    end)
  end)

  it("test_require_paths_match_file_case", function()
    local exact = {}
    for _, path in ipairs(source_files()) do exact[path] = true end
    scan(source_files(), function(path, src)
      local bad = {}
      for _, mod in ipairs(Arch.requires(src)) do
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
      return bad
    end)
  end)

  it("test_business_code_does_not_require_engine_stubs", function()
    local stubs = { EggyAPI = true, EggyEditorAPI = true }
    scan(business_files(), function(path, src)
      local bad = {}
      for _, mod in ipairs(Arch.requires(src)) do
        if stubs[mod] or stubs[mod:match("[^.]+$")] then
          bad[#bad + 1] = path .. " → " .. mod
        end
      end
      return bad
    end)
  end)

  it("test_business_code_avoids_sandbox_removed_globals", function()
    scan(business_files(), function(path, src)
      local code = Arch.code_only(src)
      local bad = {}
      for _, name in ipairs(BANNED_GLOBALS) do
        -- 同名 local 会遮蔽全局（如 server/data/player_data.lua 的 local debug = GameCfg.Debug），
        -- 这类文件整份放行：宁可漏报，不误伤。
        local position = not shadows_local(code, name) and code:find("%f[%w_]" .. name .. "%s*[%.:]")
        if position then
          bad[#bad + 1] = path .. ":" .. line_of(code, position) .. " 用了 " .. name
        end
      end
      return bad
    end)
  end)

  it("test_reentrant_entrypoints_keep_connection_handles", function()
    local matched_entries = 0
    scan(business_files(), function(path, src)
      local code = Arch.code_only(src)
      local bad = {}
      local entry, entry_indent
      local number = 0
      for line in (code .. "\n"):gmatch("([^\n]*)\n") do
        number = number + 1
        local indent, opened = line:match("^([ \t]*)function%s+[%w_.]+[.:]([%w_]+)%s*%(")
        if opened then
          if is_reentrant_entry(path, opened) then
            entry = opened
            entry_indent = indent
            matched_entries = matched_entries + 1
          elseif entry and #indent <= #entry_indent then
            entry = nil
            entry_indent = nil
          end
        elseif entry then
          local fn_indent = line:match("^([ \t]*)function%s")
          if line:match("^" .. entry_indent .. "end%s*$")
              or line:match("^" .. entry_indent .. "end%s*;")
              or (fn_indent and #fn_indent <= #entry_indent) then
            entry = nil
            entry_indent = nil
          else
            local position = line:find(":%s*Connect%s*%(")
            if position then
              local prefix = line:sub(1, position - 1):match("[^;]*$") or ""
              if not has_assignment(prefix) and not prefix:find("%f[%w_]return%f[^%w_]") then
                bad[#bad + 1] = path .. ":" .. number .. " " .. entry .. " 里的 Connect 没存句柄"
              end
            end
          end
        end
      end
      return bad
    end)
    assert.is_true(matched_entries > 0, "未扫到任何可重入口函数，扫描口径失效")
  end)

  it("test_remote_event_creation_stays_inside_reutil", function()
    scan(business_files(), function(path, src)
      local code, bad = Arch.code_only(src), {}
      local old = code:find("game%s*:%s*CreateRemoteEvent%s*%(")
      if old then
        bad[#bad + 1] = path .. ":" .. line_of(code, old) .. " 使用未公开 game:CreateRemoteEvent"
      end
      if path ~= "common/re_util.lua" then
        local direct = code:find("RemoteEvent%s*%.%s*New%s*%(")
        if direct then
          bad[#bad + 1] = path .. ":" .. line_of(code, direct) .. " 绕过 REUtil 直接调用 RemoteEvent.New"
        end
      end
      return bad
    end)
  end)

  it("test_realm_specific_services_stay_on_their_realm", function()
    local banned = {
      client = { DataStoreService = true, MemoryStoreService = true },
      server = { UserInputService = true },
    }
    scan(business_files(), function(path, src)
      local realm = path:match("^([^/]+)/")
      if not banned[realm] then return {} end
      local code, bad, from = Arch.code_only(src), {}, 1
      while true do
        local first, last = code:find("GetService%s*%(", from)
        if not first then break end
        local service = src:sub(first):match("^GetService%s*%(%s*['\"]([^'\"]+)['\"]")
        if service and banned[realm][service] then
          bad[#bad + 1] = path .. ":" .. line_of(code, first) .. " 在 " .. realm .. " 使用 " .. service
        end
        from = last + 1
      end
      if realm == "server" then
        local local_player = code:find("Players%s*%.%s*LocalPlayer%f[^%w_]")
        if local_player then
          bad[#bad + 1] = path .. ":" .. line_of(code, local_player) .. " 在 server 访问 Players.LocalPlayer"
        end
      end
      return bad
    end)
  end)

  it("test_last_seq_is_cleared_on_player_removing", function()
    local checked = 0
    scan(business_files(), function(path, src)
      if not path:match("^server/") then return {} end
      local code = Arch.code_only(src)
      if not code:find("self%s*%.%s*LastSeq%f[^%w_]") then return {} end
      checked = checked + 1
      local padded = "\n" .. code
      local first, last, indent = padded:find("\n([ \t]*)function%s+[%w_.]+%s*:%s*OnPlayerRemoving%s*%b()")
      if not first then
        return { path .. " 使用 self.LastSeq 但没有 OnPlayerRemoving" }
      end
      local body_end = padded:find("\n" .. indent .. "end%f[^%w_]", last + 1)
        or padded:find("\n" .. indent .. "function%s", last + 1)
      local body = padded:sub(last + 1, body_end)
      local cleared = false
      for line in (body .. "\n"):gmatch("([^\n]*)\n") do
        for statement in line:gmatch("[^;]+") do
          local from = 1
          while true do
            local equal = statement:find("=", from, true)
            if not equal then break end
            if statement:sub(equal + 1, equal + 1) ~= "="
                and not statement:sub(equal - 1, equal - 1):match("[=~<>]") then
              local lhs, rhs = statement:sub(1, equal - 1), statement:sub(equal + 1)
              if lhs:find("self%s*%.%s*LastSeq%f[^%w_]") and rhs:find("nil%f[^%w_]") then
                cleared = true
              end
            end
            from = equal + 1
          end
        end
      end
      if not cleared then return { path .. " 的 OnPlayerRemoving 没有给 self.LastSeq 赋 nil" } end
      return {}
    end)
    assert.is_true(checked > 0, "未扫到任何使用 self.LastSeq 的服务端模块，扫描口径失效")
  end)
end)
