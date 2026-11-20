-- 三端源码守卫：原 CODING_STANDARDS.md 里能机械判定的条目搬到这里（人审只留判断类规则）。
-- 失败方式先列：
--   1. require 少写工程前缀 → 裸名不在宿主的模块搜索路径里，运行期才炸；
--   2. require 的大小写与文件名不一致 → 本机（不区分大小写）能跑，换环境或宿主后炸；
--   3. require 到不存在的文件 → 模块改名或删除后只在运行时报错；
--   4. 业务代码 require 引擎存根 EggyAPI / EggyEditorAPI → 类型存根被当模块加载；
--   5. 业务代码出现 io / os / package / debug 调用 → SE 沙盒里这些是 nil，调用即崩；
--   6. 可重入口（OpenScreen / CloseScreen / Init）里 Connect 不存句柄 → 每次开窗叠一个监听。
-- 三端 packages/ 是整包交付的外来件（ADR-0005），不吃第 5、6 条；第 2、3 条照查（包按原始字节交付，路径同样不能错）。
-- 与同目录 static_require_test.lua 的分工：那边管「按名加载的登记表」（界面 handler、锚点行为、MgrMap），
-- 这边只管源码文本的卫生，所以两边各自独立，改登记表不必动这里。
local fs = require("tests.support.fs_fixture")
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
        -- 同名 local 会遮蔽全局（如 server/Data/PlayerData.lua 的 local debug = GameCfg.Debug），
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
    -- 行级启发式：本仓 handler 的函数头与 end 都顶格写，所以进入可重入口后
    -- 遇到顶格 end 或下一个 function 即为该函数结束。
    scan(business_files(), function(path, src)
      local bad = {}
      local entry
      local number = 0
      for line in (src .. "\n"):gmatch("([^\n]*)\n") do
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
      return bad
    end)
  end)
end)
