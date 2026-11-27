local GameCfg = require("common.game_cfg")
local Records = require("common.records")
local Modal = require("client.views.economy_modal")
local ViewUtil = require("client.views.view_util")
local CompendiumView = {}

local GRADES = { normal = "普通", rare = "极品", elite = "精英", boss = "首领" }
local GRADE_ORDER = {
  { id = "normal", label = "普通" },
  { id = "rare", label = "极品" },
  { id = "elite", label = "精英" },
  { id = "boss", label = "首领" },
}
local RANK = { normal = 1, rare = 2, elite = 3, boss = 4 }

local function apply_active_style(btn, active)
  if type(Color) == "table" and type(Color.New) == "function" then
    btn.ButtonNormalColor = active and Color.New(255, 200, 80, 255) or Color.New(70, 80, 95, 255)
  end
end

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
  local view = { zone = zone and zone.Name or "未知", zoneId = zone and zone.Id or nil,
    total = #all, entries = {} }
  for _, row in ipairs(all) do
    if row.zone == page and (grade == nil or row.fish.Grade == grade) then
      view.entries[#view.entries + 1] = { id = row.id, fish = row.fish, name = row.fish.Name,
        grade = GRADES[row.fish.Grade] or tostring(row.fish.Grade), zone = view.zone }
    end
  end
  return view
end

-- 图鉴面板句柄：面板节点、当前页/品级/选中鱼与快照都留在句柄上；
-- 方法名沿用拆分前的局部函数名，挂载入口只做装配。
---@class CompendiumPanelHandle: table<string, any>
---@type CompendiumPanelHandle
local CompendiumBehavior = {}

--- 重排鱼行、刷新收集统计、成就与详情。
---@param self CompendiumPanelHandle
function CompendiumBehavior.refresh(self)
  local bag = type(self.snapshot) == "table" and self.snapshot or {}
  local collected = 0
  for _, unlocked in pairs(bag.unlocked or {}) do if unlocked == true then collected = collected + 1 end end
  self.summary.Text = string.format("已收集 %d/%d，累计钓取 %d", collected, #self.views, tonumber(bag.total) or 0)
  self.achievement.Text = bag.state ~= "ready" and "通关成就：数据暂不可用"
    or bag.completed == true and (GameCfg.Achievements.final.Name .. "：已完成")
    or (GameCfg.Achievements.final.Name .. "：未完成")
  for index, btn in ipairs(self.page_buttons) do
    apply_active_style(btn, index == self.page)
  end
  for id, btn in pairs(self.grade_buttons) do
    apply_active_style(btn, id == self.grade)
  end
  local record = self.record
  local visible_index = 0
  for _, row in ipairs(self.views) do
    local unlocked = bag.unlocked and bag.unlocked[self.selected] == true
    local is_visible = (row.zone == self.page) and (row.fish.Grade == self.grade)
    row.node.Visible = is_visible
    if is_visible then
      local col = visible_index % 3
      local row_idx = math.floor(visible_index / 3)
      Modal.place(row.node, 20 + col * 288, 294 + row_idx * 48, 276, 40)
      Modal.place(row.button, 0, 0, 276, 40, 40)
      visible_index = visible_index + 1
    end
    Modal.set_button_text(row.button, (bag.unlocked and bag.unlocked[row.id]) and row.fish.Name or "？？？")
    if row.id == self.selected then
      local personal = bag.weights and bag.weights[row.id] or nil
      local recordText = Records.describe(record)
      if type(record) == "table" and record.stale then recordText = recordText .. "（数据可能过期）" end
      self.detail.Text = string.format("%s｜品级：%s｜钓鱼区：%s\n个人最大钓取重量：%s\n全服纪录：%s",
        unlocked and row.fish.Name or "？？？", GRADES[row.fish.Grade] or tostring(row.fish.Grade),
        zone_name(row.fish.ZoneId),
        type(personal) == "number" and string.format("%.2f 千克", personal) or "尚未钓取",
        recordText)
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

--- 写页码后刷新（两个选择器只差字段名，生成器见 ViewUtil.refresh_setter）。
CompendiumBehavior.select_page = ViewUtil.refresh_setter("page")

--- 写品级后刷新。
CompendiumBehavior.select_grade = ViewUtil.refresh_setter("grade")

--- 建面板节点：三行文本、鱼行、钓鱼区页签、品级页签与关闭按钮。
---@param self CompendiumPanelHandle
function CompendiumBehavior.create_nodes(self)
  local scope, ctx = self.scope, self.ctx
  local panel = Modal.panel(scope, ctx, "ScreenCompendium", "图鉴与全服纪录")
  self.panel = panel
  self.summary = Modal.place(Modal.label(scope, ctx, panel, "LabelCompendiumSummary", "图鉴加载中"), 20, 150, 420, 30)
  self.achievement = Modal.place(Modal.label(scope, ctx, panel, "LabelCompendiumAchievement", "通关成就：数据暂不可用"), 460, 150, 420, 30)
  self.detail = Modal.place(Modal.label(scope, ctx, panel, "LabelCompendiumDetail", "选择一条鱼查看纪录"), 20, 190, 860, 90)

  for index, item in ipairs(CompendiumView.catalog_spec()) do
    local zoneIndex = 1
    for indexZone, zone in ipairs(GameCfg.Zones) do if zone.Id == item.fish.ZoneId then zoneIndex = indexZone break end end
    local node = ctx.create_node(scope, "EUIImage", { Parent = panel, Name = "CompendiumRow_" .. tostring(index), Visible = false })
    if type(Color) == "table" and type(Color.New) == "function" then
      node.Color = Color.New(0, 0, 0, 0)
    end
    local button = Modal.button(scope, ctx, node, "BtnCompendiumFish_" .. item.id, item.fish.Name, function()
      self:select_fish(item.id)
    end)
    Modal.place(button, 0, 0, 276, 40, 40)
    self.views[#self.views + 1] = { id = item.id, fish = item.fish, zone = zoneIndex, node = node, button = button }
  end

  for index, zone in ipairs(GameCfg.Zones) do
    local btn = Modal.button(scope, ctx, panel, "BtnCompendiumPage_" .. tostring(index), zone.Name, function()
      self:select_page(index)
    end)
    Modal.place(btn, 20 + (index - 1) * 124, 58, 116, 36)
    self.page_buttons[index] = btn
  end

  for index, item in ipairs(GRADE_ORDER) do
    local btn = Modal.button(scope, ctx, panel, "BtnCompendiumGrade_" .. item.id, item.label, function()
      self:select_grade(item.id)
    end)
    Modal.place(btn, 20 + (index - 1) * 140, 104, 128, 36)
    self.grade_buttons[item.id] = btn
  end

  Modal.close(scope, ctx, panel, "BtnCompendiumClose", "compendium")
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
      local button = Modal.button(scope, ctx, ctx.root_node, "BtnCompendiumEntry", "图鉴", function()
        if type(services.open_modal) == "function" then services.open_modal("compendium") end
        if type(services.request_compendium) == "function" then services.request_compendium() end
      end)
      if type(services.hud_entry_rect) == "function" then
        local rect = services.hud_entry_rect("CompendiumEntry")
        if rect then
          button.Position = Vector2.New(rect.x, rect.y)
          button.Size = Vector2.New(rect.w, rect.h)
        end
      end
    end,
  }
end

function CompendiumView.modal_spec()
  return mount
end

return CompendiumView
