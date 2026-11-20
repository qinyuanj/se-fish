-- 运行期建点台账守卫（#208）：脚本建出的单位数与 #206 台账同源，扫描口径必须同时认出两种建法。
-- 失败方式先列：
--   1. 新增或删除运行期建点却没同步 #206 台账与本计数 → 计数漂移（第一条用例）；
--   2. 换掉建法让扫描认不出（如 `local New = World.CreateUnit` 后 `New(...)`）→ 少算；
--   3. 注释或字符串里的 CreateUnit 文案被误计 → 多算（后两条失败都由第一条用例报出）；
--   4. 已按本单删除的四组零调用封装被重新引用（require、_G 注册、注释掉的死代码）→ 入口复活（第二条用例）。
-- 口径：client/、common/、server/ 递归取 *.lua，含 packages 与 _trigger，与台账取材一致
-- （引擎声明 EggyAPI.lua 在仓库根，不在三端内）；抹掉注释与字符串字面量的内容后，
-- 数「以 `.` 或 `:` 访问的 CreateUnit」——`World:CreateUnit(...)` 的方法调用与
-- `pcall(world.CreateUnit, world, ...)` 的点号取函数都命中，
-- `print("WARNING: CreateUnit ... failed")` 这类文案落在字符串里，抹掉后不算。

local Arch = require("tools.arch_policy")
local fs = require("tests.support.fs_fixture")
local lfs = require("lfs")

-- 63：#214 审查修复把商品行子节点的两处建点（图片 / 文字各一支）合成一处驱动表建点，client 40 → 39
-- 64：#253 队伍界面 client/ScreenHandlers/ScreenParty.lua 的 create() 是新建点，client 39 → 40
local SITES = 64
local SITE_ROOTS = { "client", "common", "server" }
local REF_ROOTS = { "client", "common", "server", "tests", "tools" }
local REMOVED = { "FXUtil", "WeldTo", "MarkPointPart", "CreateHPBar" }
local SELF = "tests/native/build_site_inventory_test.lua"

-- 只在失败时构造消息：通过时不产生任何字符串。
local function fail(fmt, ...)
  assert.is_true(false, string.format(fmt, ...))
end

-- 目录递归取 *.lua，返回相对仓库根、正斜杠分隔的路径并按名字排序，失败消息与扫描顺序都稳定。
local function lua_files(root)
  local out = {}
  local function walk(relative)
    local directory = relative == "" and root or root .. "/" .. relative
    for _, entry in ipairs(fs.list_dir(directory)) do
      local path = relative == "" and entry or relative .. "/" .. entry
      local attr = lfs.attributes(root .. "/" .. path)
      if attr and attr.mode == "directory" then
        walk(path)
      elseif entry:match("%.lua$") then
        out[#out + 1] = root .. "/" .. path
      end
    end
  end
  walk("")
  table.sort(out)
  return out
end

local function source_of(path)
  local source = fs.slurp(path)
  if not source then fail("读不到 " .. path) end
  return source
end

-- 数建点：注释与字符串内容在 code_only 里已抹成空格，剩下的 `.CreateUnit` / `:CreateUnit` 才是调用点。
local function count_sites()
  local total, per_root = 0, {}
  for _, root in ipairs(SITE_ROOTS) do
    local counted = 0
    for _, path in ipairs(lua_files(root)) do
      for _ in Arch.code_only(source_of(path)):gmatch("[:.]%s*CreateUnit") do
        counted = counted + 1
      end
    end
    per_root[root] = counted
    total = total + counted
  end
  return total, per_root
end

local function breakdown(per_root)
  local parts = {}
  for _, root in ipairs(SITE_ROOTS) do parts[#parts + 1] = root .. " " .. per_root[root] end
  return table.concat(parts, " / ")
end

describe("运行期建点台账", function()
  it("三端运行期建点数与 #206 台账同为 63 个", function()
    local total, per_root = count_sites()
    if total ~= SITES then
      fail("运行期建点 %d 个，台账与本守卫断言 %d 个（%s）。新增或删除建点要同步 #206 台账与本计数。",
        total, SITES, breakdown(per_root))
    end
  end)

  it("已删除的四组零调用封装不再被引用", function()
    local hits = {}
    for _, root in ipairs(REF_ROOTS) do
      for _, path in ipairs(lua_files(root)) do
        if path ~= SELF then
          local source = source_of(path)
          for _, name in ipairs(REMOVED) do
            if source:find(name, 1, true) then hits[#hits + 1] = path .. " -> " .. name end
          end
        end
      end
    end
    if #hits > 0 then
      fail("#208 已删除这些零调用封装，仓里仍有引用（require、_G 注册或注释掉的死代码）：\n%s\n要重新引入须先改 #206 方案与本守卫。",
        table.concat(hits, "\n"))
    end
  end)
end)
