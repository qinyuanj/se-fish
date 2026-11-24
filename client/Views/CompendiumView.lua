local GameCfg = require("common.game_cfg")
local Records = require("common.records")
local Modal = require("client.Views.EconomyModal")
local CompendiumView = {}

local GRADES = { normal = "普通", rare = "极品", elite = "精英", boss = "首领" }
local RANK = { normal = 1, rare = 2, elite = 3, boss = 4 }

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

function CompendiumView.page_spec(page)
  local all = CompendiumView.catalog_spec()
  local zone = GameCfg.Zones[page]
  local view = { zone = zone and zone.Name or "未知", zoneId = zone and zone.Id or nil,
    total = #all, entries = {} }
  for _, row in ipairs(all) do
    if row.zone == page then
      view.entries[#view.entries + 1] = { id = row.id, fish = row.fish, name = row.fish.Name,
        grade = GRADES[row.fish.Grade] or tostring(row.fish.Grade), zone = view.zone }
    end
  end
  return view
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
  return function(scope, ctx)
    local services = ctx.services or {}
    local panel = Modal.panel(scope, ctx, "ScreenCompendium", "图鉴与全服纪录")
    local summary = Modal.label(scope, ctx, panel, "LabelCompendiumSummary", "图鉴加载中")
    local achievement = Modal.label(scope, ctx, panel, "LabelCompendiumAchievement", "通关成就：数据暂不可用")
    local detail = Modal.label(scope, ctx, panel, "LabelCompendiumDetail", "选择一条鱼查看纪录")
    local page = 1
    local selected = "bass"
    local snapshot, record = nil, nil
    local views = {}
    local function refresh()
      local bag = type(snapshot) == "table" and snapshot or {}
      local collected = 0
      for id, unlocked in pairs(bag.unlocked or {}) do if unlocked == true then collected = collected + 1 end end
      summary.Text = string.format("已收集 %d/%d，累计钓取 %d", collected, #views, tonumber(bag.total) or 0)
      achievement.Text = bag.state ~= "ready" and "通关成就：数据暂不可用"
        or bag.completed == true and (GameCfg.Achievements.final.Name .. "：已完成")
        or (GameCfg.Achievements.final.Name .. "：未完成")
      for _, row in ipairs(views) do
        local unlocked = bag.unlocked and bag.unlocked[selected] == true
        row.node.Visible = row.zone == page
        row.button.ButtonText = (bag.unlocked and bag.unlocked[row.id]) and row.fish.Name or "？？？"
        if row.id == selected then
          local personal = bag.weights and bag.weights[row.id] or nil
          local recordText = Records.Describe(record)
          if type(record) == "table" and record.stale then recordText = recordText .. "（数据可能过期）" end
          detail.Text = string.format("%s｜品级：%s｜钓鱼区：%s\n个人最大钓取重量：%s\n全服纪录：%s",
            unlocked and row.fish.Name or "？？？", GRADES[row.fish.Grade] or tostring(row.fish.Grade),
            zone_name(row.fish.ZoneId),
            type(personal) == "number" and string.format("%.2f 千克", personal) or "尚未钓取",
            recordText)
        end
      end
    end
    for index, item in ipairs(CompendiumView.catalog_spec()) do
      local zoneIndex = 1
      for indexZone, zone in ipairs(GameCfg.Zones) do if zone.Id == item.fish.ZoneId then zoneIndex = indexZone break end end
      local node = ctx.create_node(scope, "EUIImage", { Parent = panel, Name = "CompendiumRow_" .. tostring(index), Visible = false })
      local button = Modal.button(scope, ctx, node, "BtnCompendiumFish_" .. item.id, item.fish.Name, function()
        selected, record = item.id, nil
        if type(services.request_records) == "function" then services.request_records(item.id) end
        refresh()
      end)
      views[#views + 1] = { id = item.id, fish = item.fish, zone = zoneIndex, node = node, button = button }
    end
    for index, zone in ipairs(GameCfg.Zones) do
      Modal.button(scope, ctx, panel, "BtnCompendiumPage_" .. tostring(index), zone.Name, function()
        page = index
        refresh()
      end)
    end
    Modal.close(scope, ctx, panel, "BtnCompendiumClose", "compendium")
    scope:effect("CompendiumProjection", function(es)
      snapshot = es:d(ctx.store.compendium)
      refresh()
    end)
    scope:effect("RecordsProjection", function(es)
      local value = es:d(ctx.store.records)
      if type(value) == "table" and value.fishId == selected then record = value end
      refresh()
    end)
    refresh()
  end
end

return CompendiumView
