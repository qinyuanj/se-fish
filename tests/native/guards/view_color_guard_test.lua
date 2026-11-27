-- 视图颜色入口收拢守卫（#415）：
-- 6 个视图各自重造的本地 make_color 收拢到 client/views/view_util.lua 的 ViewUtil.color，
-- hud_widgets.lua 的 3 处内联 Color.New(...) 也改走同一函数。失败方式先列：
--   1. 某个视图重新长出 `local function make_color` 或重新导出/引用 `.make_color` → 复制品回潮，
--      各文件「alpha 缺省 / Color 缺失」的处理再次分叉；
--   2. hud_widgets.lua 重新出现内联 `Color.New(` → 按钮三色绕开共享件；
--   3. 收拢后的视图不再引用 `ViewUtil.color` → 名义收拢、实际各写各的；
--   4. 视图颜色来源出现 3 元素表（缺 alpha）→ ViewUtil.color 补 255，旧本地实现传 nil，
--      玩家看到的颜色会变；这是本票「行为差异不可接受」的边界；
--   5. ViewUtil.color 对 4 元素颜色表不再与旧本地实现逐参数等价，或 Color 缺失时不再回退原表
--      → 本票「行为不变」的前提失效。
-- 第 4 条的证据是逐个调用点核对：本地 COLORS 常量、GameCfg.Vitals、道具 IconColor 恒为 4 元素；
-- 第 5 条把票面接受的两处语义差（rgba[4] 为 nil 才补 255、Color 缺失回退原表）写成可执行断言。

local fs = require("tests.support.fs_fixture")
local GameCfg = require("common.game_cfg")
local PlaceholderAssets = require("common.cfg.placeholder_assets")
local ViewUtil = require("client.views.view_util")

local VIEW_FILES = {
  "client/views/economy_modal.lua",
  "client/views/main_hud_action_buttons_projection.lua",
  "client/views/main_hud_action_buttons_view.lua",
  "client/views/main_hud_backpack_panel.lua",
  "client/views/main_hud_backpack_view.lua",
  "client/views/main_hud_equip_popups.lua",
  "client/views/main_hud_item_bar_view.lua",
  "client/views/main_hud_vitals_view.lua",
}

-- 视图从共享配置取色的两个真源：GameCfg.Vitals（血量环/饥饿红边）与道具 IconColor。
local COLOR_SOURCE_FILES = {
  "common/game_cfg.lua",
  "common/cfg/placeholder_assets.lua",
}

local HUD_WIDGETS = "client/views/hud_widgets.lua"
local THREE_NUMBERS = "%{%s*%d+%s*,%s*%d+%s*,%s*%d+%s*}"

local function read(path)
  local body = fs.slurp(path)
  assert.is_truthy(body, "读不到 " .. path)
  return body
end

local function count(body, pattern)
  local n = 0
  for _ in body:gmatch(pattern) do n = n + 1 end
  return n
end

local function three_element_tables(path)
  local body = read(path)
  local found = {}
  local line_no = 0
  for line in (body .. "\n"):gmatch("(.-)\n") do
    line_no = line_no + 1
    if line:find(THREE_NUMBERS) then
      local trimmed = line:gsub("^%s+", "")
      found[#found + 1] = string.format("%s:%d %s", path, line_no, trimmed:sub(1, 60))
    end
  end
  return found
end

describe("视图颜色入口收拢（#415）", function()
  it("视图不再有本地 make_color 定义，都引用 ViewUtil.color", function()
    local offenders = {}
    for _, path in ipairs(VIEW_FILES) do
      local body = read(path)
      if count(body, "local%s+function%s+make_color%s*%(") > 0 then
        offenders[#offenders + 1] = path .. " 仍有本地 make_color 定义"
      end
      if count(body, "%.[Mm]ake_color") > 0 then
        offenders[#offenders + 1] = path .. " 仍有 .make_color 导出或引用"
      end
      if not body:find("ViewUtil.color", 1, true) then
        offenders[#offenders + 1] = path .. " 未引用 ViewUtil.color"
      end
    end
    assert.same({}, offenders)
  end)

  it("hud_widgets 的按钮三色不再内联 Color.New", function()
    local body = read(HUD_WIDGETS)
    assert.equals(0, count(body, "Color%.New%s*%("), "hud_widgets.lua 仍有内联 Color.New")
    assert.equals(3, count(body, "ViewUtil%.color%s*%("), "hud_widgets.lua 三个按钮颜色应各走一次 ViewUtil.color")
  end)

  it("视图颜色来源恒为 4 元素（缺 alpha 会从 nil 变 255）", function()
    local offenders = {}
    for _, path in ipairs(VIEW_FILES) do
      for _, hit in ipairs(three_element_tables(path)) do
        offenders[#offenders + 1] = hit
      end
    end
    for _, path in ipairs(COLOR_SOURCE_FILES) do
      for _, hit in ipairs(three_element_tables(path)) do
        offenders[#offenders + 1] = hit
      end
    end
    for _, key in ipairs({ "HealthColor", "HungerColor", "FlashColor" }) do
      local rgba = GameCfg.Vitals[key]
      if type(rgba) ~= "table" or #rgba ~= 4 then
        offenders[#offenders + 1] = "GameCfg.Vitals." .. key .. " 不是 4 元素颜色表"
      end
    end
    for name, rgba in pairs(PlaceholderAssets.Grades) do
      if #rgba ~= 4 then
        offenders[#offenders + 1] = "Assets.Grades." .. name .. " 不是 4 元素颜色表"
      end
    end
    for name, rgba in pairs(PlaceholderAssets.ItemColors) do
      if #rgba ~= 4 then
        offenders[#offenders + 1] = "Assets.ItemColors." .. name .. " 不是 4 元素颜色表"
      end
    end
    assert.same({}, offenders)
  end)
end)

describe("ViewUtil.color 的语义差判据（#415）", function()
  local saved_color

  before_each(function()
    saved_color = rawget(_G, "Color")
  end)

  after_each(function()
    _G.Color = saved_color
  end)

  it("4 元素颜色表逐参数等价，只有缺 alpha 才补 255", function()
    local recorded = {}
    _G.Color = { New = function(...) recorded[#recorded + 1] = { ... }; return { ... } end }
    assert.same({ 54, 100, 140, 255 }, ViewUtil.color({ 54, 100, 140, 255 }))
    assert.same({ 54, 100, 140, 255 }, recorded[1])
    assert.same({ 54, 100, 140, 255 }, ViewUtil.color({ 54, 100, 140 }))
    assert.same({ 54, 100, 140, 255 }, recorded[2])
  end)

  it("Color 缺失时回退原表（编辑器/测试替身环境；生产恒有 Color）", function()
    _G.Color = nil
    local rgba = { 54, 100, 140, 255 }
    assert.is_true(ViewUtil.color(rgba) == rgba)
  end)
end)
