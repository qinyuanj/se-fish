local GameCfg = require("common.game_cfg")
local Records = require("common.records")
local Tokens = require("client.ui.tokens")
local Layout = require("client.ui.layout")
local Primitives = require("client.ui.primitives")
local Controls = require("client.ui.controls")
local Modal = require("client.views.economy_modal")
local ViewUtil = require("client.views.view_util")

local CompendiumView = {}

local PANEL_W = 1040
local PANEL_H = 680
local PAD = Tokens.SPACE.PANEL_PAD
local ROW_W = 272
local ROW_H = 56
local ROW_GAP_X = 16
local ROW_GAP_Y = 16

local GRADES = { normal = "普通", rare = "极品", elite = "精英", boss = "首领" }
local GRADE_ORDER = {
  { id = "normal", label = "普通" },
  { id = "rare", label = "极品" },
  { id = "elite", label = "精英" },
  { id = "boss", label = "首领" },
}
local RANK = { normal = 1, rare = 2, elite = 3, boss = 4 }

function CompendiumView.grade_tabs()
  return GRADE_ORDER
end

local function fish_rows()
  local rows = {}
  for id, fish in pairs(GameCfg.Fish) do
    rows[#rows + 1] = { id = id, fish = fish }
  end
  table.sort(rows, function(a, b)
    local zoneA, zoneB = 99, 99
    for index, zone in ipairs(GameCfg.Zones) do
      if zone.Id == a.fish.ZoneId then zoneA = index end
      if zone.Id == b.fish.ZoneId then zoneB = index end
    end
    if zoneA ~= zoneB then return zoneA < zoneB end
    if RANK[a.fish.Grade] ~= RANK[b.fish.Grade] then return RANK[a.fish.Grade] < RANK[b.fish.Grade] end
    if a.fish.SourceId ~= b.fish.SourceId then return a.fish.SourceId < b.fish.SourceId end
    return a.id < b.id
  end)
  return rows
end

local function zone_name(zoneId)
  for _, zone in ipairs(GameCfg.Zones) do
    if zone.Id == zoneId then return zone.Name end
  end
  return tostring(zoneId or "未知")
end

function CompendiumView.catalog_spec()
  local rows = fish_rows()
  for _, row in ipairs(rows) do
    for index, zone in ipairs(GameCfg.Zones) do
      if zone.Id == row.fish.ZoneId then row.zone = index break end
    end
  end
  return rows
end

function CompendiumView.page_spec(page, grade)
  local all = CompendiumView.catalog_spec()
  local zone = GameCfg.Zones[page]
  local view = {
    zone = zone and zone.Name or "未知",
    zoneId = zone and zone.Id or nil,
    total = #all,
    entries = {},
  }
  for _, row in ipairs(all) do
    if row.zone == page and (grade == nil or row.fish.Grade == grade) then
      view.entries[#view.entries + 1] = {
        id = row.id,
        fish = row.fish,
        name = row.fish.Name,
        grade = GRADES[row.fish.Grade] or tostring(row.fish.Grade),
        zone = view.zone,
      }
    end
  end
  return view
end

-- 图鉴面板句柄：面板节点、当前页/品级/选中鱼与快照都留在句柄上；
-- 方法名沿用拆分前的局部函数名，挂载入口只做装配。
---@class CompendiumPanelHandle: table<string, any>
---@type CompendiumPanelHandle
local CompendiumBehavior = {}

--- 重排鱼行、刷新收集统计、成就、翻页条与详情栏。
---@param self CompendiumPanelHandle
function CompendiumBehavior.refresh(self)
  local bag = type(self.snapshot) == "table" and self.snapshot or {}
  local collected = 0
  for _, unlocked in pairs(bag.unlocked or {}) do
    if unlocked == true then collected = collected + 1 end
  end
  self.summary.Text = string.format("已收集 %d/%d，累计钓取 %d", collected, #self.views, tonumber(bag.total) or 0)
  self.achievement.Text = bag.state ~= "ready" and "通关成就：数据暂不可用"
    or bag.completed == true and (GameCfg.Achievements.final.Name .. "：已完成")
    or (GameCfg.Achievements.final.Name .. "：未完成")

  local total_pages = math.max(1, #GameCfg.Zones)
  for index, btn in ipairs(self.page_buttons) do
    Controls.set_button_style(btn, index == self.page and "primary" or "surface")
  end
  for id, btn in pairs(self.grade_buttons) do
    Controls.set_button_style(btn, id == self.grade and "primary" or "surface")
  end
  if self.page_info then
    local zone = GameCfg.Zones[self.page]
    self.page_info.Text = string.format("第 %d/%d 区 · %s", self.page, total_pages, zone and zone.Name or "未知")
  end
  Controls.set_button_enabled(self.prev_btn, self.page > 1, "blue")
  Controls.set_button_enabled(self.next_btn, self.page < total_pages, "blue")

  local record = self.record
  local visible_index = 0
  for _, row in ipairs(self.views) do
    local is_unlocked = bag.unlocked and bag.unlocked[row.id] == true
    local is_visible = (row.zone == self.page) and (row.fish.Grade == self.grade)
    row.node.Visible = is_visible
    if is_visible then
      visible_index = visible_index + 1
      local cell = Layout.grid_cell(PANEL_H, PAD, 228, 2, visible_index, ROW_W, ROW_H, ROW_GAP_X, ROW_GAP_Y)
      Layout.apply(row.node, cell)
      Layout.apply(row.button, Layout.center_in(ROW_W, ROW_H, ROW_W, ROW_H))
    end
    Controls.set_button_text(row.button, is_unlocked and row.fish.Name or "？？？")
    if row.id == self.selected then
      Controls.set_button_style(row.button, "selected")
      local personal = bag.weights and bag.weights[row.id] or nil
      local record_text = Records.describe(record)
      if type(record) == "table" and record.stale then
        record_text = record_text .. "（数据可能过期）"
      end
      self.detail.Text = string.format(
        "%s｜品级：%s｜钓鱼区：%s\n\n个人最大钓取重量：%s\n\n全服纪录：%s",
        is_unlocked and row.fish.Name or "？？？",
        GRADES[row.fish.Grade] or tostring(row.fish.Grade),
        zone_name(row.fish.ZoneId),
        type(personal) == "number" and string.format("%.2f 千克", personal) or "尚未钓取",
        record_text
      )
    else
      Controls.set_button_style(row.button, is_unlocked and "card" or "surface")
    end
  end
end

--- 选鱼：记下鱼 id、请求纪录并刷新。
---@param self CompendiumPanelHandle
---@param fish_id string
function CompendiumBehavior.select_fish(self, fish_id)
  self.selected, self.record = fish_id, nil
  local services = self.services
  if type(services.request_records) == "function" then services.request_records(fish_id) end
  self:refresh()
end

CompendiumBehavior.select_page = ViewUtil.refresh_setter("page")
CompendiumBehavior.select_grade = ViewUtil.refresh_setter("grade")

--- 建面板节点：浅奶白底板 + 顶部页签/品级筛选 + 左侧纯容器列表 + 右侧详情栏 + 底部翻页条。
---@param self CompendiumPanelHandle
function CompendiumBehavior.create_nodes(self)
  local scope, ctx = self.scope, self.ctx
  local panel = Modal.panel(scope, ctx, "ScreenCompendium", "图鉴与全服纪录", {
    width = PANEL_W,
    height = PANEL_H,
    close_name = "BtnCompendiumClose",
    modal_id = "compendium",
  })
  self.panel = panel

  -- 顶部第 1 排：7 个钓鱼区页签（132×40，间距 8，全 4px 栅格）
  for index, zone in ipairs(GameCfg.Zones) do
    local rect = Layout.from_top_left(PANEL_H, PAD + (index - 1) * 140, 84, 132, 40)
    local btn = Controls.button(scope, ctx, {
      name = "BtnCompendiumPage_" .. tostring(index),
      parent = panel,
      rect = rect,
      text = zone.Name,
      variant = "surface",
      font_size = Tokens.FONT_SIZE.CAPTION,
      z_order = 2,
      on_click = function()
        self:select_page(index)
      end,
    })
    self.page_buttons[index] = btn
  end

  -- 顶部第 2 排：4 个品级筛选按钮（104×36，间距 12）
  for index, item in ipairs(GRADE_ORDER) do
    local rect = Layout.from_top_left(PANEL_H, PAD + (index - 1) * 116, 136, 104, 36)
    local btn = Controls.button(scope, ctx, {
      name = "BtnCompendiumGrade_" .. item.id,
      parent = panel,
      rect = rect,
      text = item.label,
      variant = "surface",
      font_size = Tokens.FONT_SIZE.CAPTION,
      z_order = 2,
      on_click = function()
        self:select_grade(item.id)
      end,
    })
    self.grade_buttons[item.id] = btn
  end

  -- 顶部第 3 排：收集统计与通关成就
  self.summary = Primitives.label(scope, ctx, {
    name = "LabelCompendiumSummary",
    parent = panel,
    rect = Layout.from_top_left(PANEL_H, PAD, 184, 480, 32),
    text = "图鉴加载中",
    font_size = Tokens.FONT_SIZE.CAPTION,
    color = Tokens.COLOR.TEXT_DARK,
    align_x = 0,
    align_y = 1,
    z_order = 2,
  })
  self.achievement = Primitives.label(scope, ctx, {
    name = "LabelCompendiumAchievement",
    parent = panel,
    rect = Layout.from_top_left(PANEL_H, 528, 184, 480, 32),
    text = "通关成就：数据暂不可用",
    font_size = Tokens.FONT_SIZE.CAPTION,
    bold = true,
    color = Tokens.COLOR.TEXT_GOLD_DARK,
    align_x = 2,
    align_y = 1,
    z_order = 2,
  })

  -- 左侧鱼种列表：行容器严格用 Primitives.container（纯 EUILayout），杜绝 EUIImage 透明色块
  for index, item in ipairs(CompendiumView.catalog_spec()) do
    local zone_index = 1
    for idx_zone, zone in ipairs(GameCfg.Zones) do
      if zone.Id == item.fish.ZoneId then zone_index = idx_zone break end
    end
    local init_rect = Layout.from_top_left(PANEL_H, PAD, 228, ROW_W, ROW_H)
    local node = Primitives.container(scope, ctx, {
      name = "CompendiumRow_" .. tostring(index),
      parent = panel,
      rect = init_rect,
      visible = false,
      z_order = 2,
    })
    local button = Controls.button(scope, ctx, {
      name = "BtnCompendiumFish_" .. item.id,
      parent = node,
      rect = Layout.center_in(ROW_W, ROW_H, ROW_W, ROW_H),
      text = item.fish.Name,
      variant = "card",
      font_size = Tokens.FONT_SIZE.BODY,
      z_order = 1,
      on_click = function()
        self:select_fish(item.id)
      end,
    })
    self.views[#self.views + 1] = {
      id = item.id,
      fish = item.fish,
      zone = zone_index,
      node = node,
      button = button,
    }
  end

  -- 左侧底部翻页栏
  self.prev_btn = Controls.button(scope, ctx, {
    name = "BtnCompendiumPrevPage",
    parent = panel,
    rect = Layout.from_top_left(PANEL_H, PAD, 600, 136, 48),
    text = "上一区",
    variant = "blue",
    font_size = Tokens.FONT_SIZE.CAPTION,
    z_order = 2,
    on_click = function()
      if self.page > 1 then self:select_page(self.page - 1) end
    end,
  })
  self.page_info = Primitives.label(scope, ctx, {
    name = "LabelCompendiumPageInfo",
    parent = panel,
    rect = Layout.from_top_left(PANEL_H, 180, 600, 264, 48),
    text = "",
    font_size = Tokens.FONT_SIZE.CAPTION,
    bold = true,
    color = Tokens.COLOR.TEXT_MUTED,
    align_x = 1,
    align_y = 1,
    z_order = 2,
  })
  self.next_btn = Controls.button(scope, ctx, {
    name = "BtnCompendiumNextPage",
    parent = panel,
    rect = Layout.from_top_left(PANEL_H, 456, 600, 136, 48),
    text = "下一区",
    variant = "blue",
    font_size = Tokens.FONT_SIZE.CAPTION,
    z_order = 2,
    on_click = function()
      if self.page < #GameCfg.Zones then self:select_page(self.page + 1) end
    end,
  })

  -- 右侧详情卡片（单层扁平浅米色卡片 + 深灰正文）
  local detail_card_rect = Layout.from_top_left(PANEL_H, 616, 228, 392, 420)
  local detail_card = Modal.surface(scope, ctx, panel, "CompendiumDetailCard", detail_card_rect, { z_order = 1 })
  self.detail = Primitives.label(scope, ctx, {
    name = "LabelCompendiumDetail",
    parent = detail_card,
    rect = Layout.from_top_left(420, 20, 20, 352, 380),
    text = "选择一条鱼查看纪录",
    font_size = Tokens.FONT_SIZE.BODY,
    color = Tokens.COLOR.TEXT_DARK,
    align_x = 0,
    align_y = 0,
    z_order = 2,
  })
end

---@param self CompendiumPanelHandle
---@param es table EffectScope
function CompendiumBehavior.on_compendium_projection(self, es)
  self.snapshot = es:d(self.ctx.store.compendium)
  self:refresh()
end

---@param self CompendiumPanelHandle
---@param es table EffectScope
function CompendiumBehavior.on_records_projection(self, es)
  local value = es:d(self.ctx.store.records)
  if type(value) == "table" and value.fishId == self.selected then self.record = value end
  self:refresh()
end

--- 挂载图鉴面板：造句柄、建节点、接投影与首帧刷新。
---@param scope table
---@param ctx table
local function mount(scope, ctx)
  ---@type CompendiumPanelHandle
  local self = {
    scope = scope,
    ctx = ctx,
    services = ctx.services or {},
    page = 1,
    grade = "normal",
    selected = "bass",
    snapshot = nil,
    record = nil,
    views = {},
    page_buttons = {},
    grade_buttons = {},
    panel = nil,
    summary = nil,
    achievement = nil,
    detail = nil,
    prev_btn = nil,
    next_btn = nil,
    page_info = nil,
  }
  for name, method in pairs(CompendiumBehavior) do self[name] = method end
  self:create_nodes()

  scope:effect("CompendiumProjection", function(es) self:on_compendium_projection(es) end)
  scope:effect("RecordsProjection", function(es) self:on_records_projection(es) end)
  self:refresh()
end

function CompendiumView.entry_spec()
  return {
    name = "CompendiumEntry",
    mount = function(scope, ctx)
      local services = ctx.services or {}
      local rect = type(services.hud_entry_rect) == "function" and services.hud_entry_rect("CompendiumEntry") or nil
      local btn = Controls.button(scope, ctx, {
        name = "BtnCompendiumEntry",
        parent = ctx.root_node,
        rect = rect or Layout.rect(100, 100, 112, 48),
        text = "图鉴",
        variant = "hud",
        font_size = Tokens.FONT_SIZE.BODY,
        z_order = Tokens.Z.HUD_CONTENT,
        on_click = function()
          if type(services.open_modal) == "function" then services.open_modal("compendium") end
          if type(services.request_compendium) == "function" then services.request_compendium() end
        end,
      })
      if rect then
        Layout.apply(btn, rect)
      end
    end,
  }
end

function CompendiumView.modal_spec()
  return mount
end

return CompendiumView
