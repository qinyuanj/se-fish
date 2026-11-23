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
-- 64：#253 旧队伍界面的 create() 是新建点，client 39 → 40（该旧界面已由 #314 删除）
-- 65：#296 客户端 Spoke 根视图树 client/Views/RootView.lua 统一动态 UI 建点，client 40 → 41
-- 62：#297-B2 主 HUD 左上状态区迁入 client/Views/MainHudVitalsView.lua（复用 RootView 统一建点），剥离 ScreenMain 3 处建点，client 41 → 38
-- 61：#297-A3 左手持竿投影迁入 HeldRodLeaf，剥离 MgrPlayerData 2 处建点，在 server/main.lua 注入 1 处统一 create_unit，server 净减 1
-- 60：#297-C1 主 HUD 武器/鱼饵浮层与背包面板切流至 Spoke 视图（复用 RootView 统一建点），剥离 ScreenMain 1 处建点，client 38 → 37
-- 58：#297-C2 主 HUD 底部道具栏、拖拽与爆炸物瞄准切流至 Spoke 视图，剥离 ScreenMain 动态格位与瞄准遮罩 2 处建点（含循环内多节点建点），client 37 → 35
-- 57：#298 生存蒙版改挂 RootView 统一建点，删除 ScreenSurvival 自己的 1 处建点，client 35 → 34
-- 55：#300 攻击键改挂 RootView 统一建点，删除 LocalAttackButton 自己的 4 处建点；投掷物视觉复用 main 注入建点，client 34 → 30
-- 53：#299 删除 MgrSpecialItem 的两处占位外观建点，改由入口已有 create_unit 托管
-- 50：#301 地面物品改由 GroundLoot 的 on_cleanup 销毁，删除 MgrLoot 3 处建点
-- #309 旧活鱼驱动迁入 server/World/FishTree 等公开宿主。
-- #310 烧烤视图改由 RootView 统一建点，删除 ScreenGrill 自己的 1 处建点。
-- #302 抛竿/收线迁入统一生命周期并删除旧模块；合并后实测 client 29 / common 2 / server 26。
-- #313 倒计时改由 RootView 统一建点，删除 ScreenFerry 自己的 1 处建点，client 29 → 28。
-- #312 三类经济与场景视图复用 RootView，删除旧双端模块后实测 client 22 / common 2 / server 26。
-- 合并 #311 删除旧商店/钓鱼佬 4 处建点；实测 client 18 / common 2 / server 26。
-- #314 小队 HUD 复用 RootView 统一建点，删除旧队伍界面自己的 1 处建点。
-- #315 图鉴、GM 与消息改由 RootView 统一建点，删除旧客户端四处建点；合并后实测 client 13 / common 2 / server 26。
-- #316 删除 MgrGameUI、ScreenMain 与本地控制壳，复用 RootView 统一建点；实测 client 9 / common 2 / server 26。
local SITES = 37
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
  it("三端运行期建点数与 #206 台账一致", function()
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
