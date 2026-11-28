-- 条款 13-03（docs/acceptance/13-compendium-achievements.md）：
-- 普通与极品分类展示，精英与首领另有明确的品级入口。
local GameCfg = require("common.game_cfg")
local ClientStore = require("client.store.client_store")
local RootView = require("client.views.root_view")
local CompendiumView = require("client.views.compendium_view")
local Eui = require("tests.support.eui_double")

local function child(root, name)
  return root:FindFirstChild(name, true)
end

local function visible_fish_ids(panel)
  local ids = {}
  for _, node in pairs(panel.children) do
    if tostring(node.Name):match("^CompendiumRow_") and node.Visible then
      for _, sub in pairs(node.children) do
        local id = tostring(sub.Name):match("^BtnCompendiumFish_(.+)$")
        if id then
          ids[#ids + 1] = id
        end
      end
    end
  end
  table.sort(ids)
  return ids
end

local function btn_label_text(btn)
  assert.same("", btn.ButtonText or "", tostring(btn.Name) .. " 必须清空原生 ButtonText 防重影")
  local sub = btn:FindFirstChild("LabelButtonText", false)
  assert.is_not_nil(sub, tostring(btn.Name) .. " 缺少子 LabelButtonText")
  return sub.Text
end

local function rects_overlap(a, b)
  local ax1, ax2 = a.Position.x - a.Size.x / 2, a.Position.x + a.Size.x / 2
  local ay1, ay2 = a.Position.y - a.Size.y / 2, a.Position.y + a.Size.y / 2
  local bx1, bx2 = b.Position.x - b.Size.x / 2, b.Position.x + b.Size.x / 2
  local by1, by2 = b.Position.y - b.Size.y / 2, b.Position.y + b.Size.y / 2
  return ax1 < bx2 - 0.01 and ax2 > bx1 + 0.01 and ay1 < by2 - 0.01 and ay2 > by1 + 0.01
end

describe("条款 13-03：图鉴四档品级筛选与七区分页正交", function()
  local root, store, writer, view, sent, oldVector, oldColor

  before_each(function()
    oldVector, oldColor = rawget(_G, "Vector2"), rawget(_G, "Color")
    _G.Vector2 = { New = function(x, y) return { x = x, y = y } end }
    _G.Color = { New = function(...) return { ... } end }
    sent = { compendium = 0, records = {} }
    store, writer = ClientStore.new()
    root = Eui.node({ Name = "UIRoot" })
    view = RootView.mount(root, store, {
      services = {
        open_modal = function(id, payload) writer:open_modal(id, payload) end,
        close_modal = function(id) writer:close_modal(id) end,
        request_compendium = function() sent.compendium = sent.compendium + 1 end,
        request_records = function(fishId) sent.records[#sent.records + 1] = fishId end,
      },
      hud = { CompendiumView.entry_spec() },
      modals = { compendium = CompendiumView.modal_spec() },
      create_node = function(kind, props)
        local n = Eui.node({
          Kind = kind,
          Name = props and props.Name,
          Parent = props and props.Parent,
          Visible = props and props.Visible,
          Text = props and props.Text,
          Position = props and props.Position,
          Size = props and props.Size,
          TouchEnabled = kind == "EUIButton",
        })
        if props and props.ButtonText ~= nil then
          n.ButtonText = props.ButtonText
        end
        return n
      end,
    })
  end)

  after_each(function()
    if view then view:dispose() end
    _G.Vector2, _G.Color = oldVector, oldColor
  end)

  it("13-03：四档品级按钮存在、可点且与七区分页按钮无重叠遮挡", function()
    Eui.click(child(root, "BtnCompendiumEntry"))
    local panel = child(root, "ScreenCompendium")
    assert.is_not_nil(panel)

    local buttons = {}
    for index = 1, 7 do
      local page_btn = child(panel, "BtnCompendiumPage_" .. tostring(index))
      assert.is_not_nil(page_btn)
      assert.is_true(page_btn.TouchEnabled)
      buttons[#buttons + 1] = page_btn
    end

    local expected = {
      { id = "normal", label = "普通" },
      { id = "rare", label = "极品" },
      { id = "elite", label = "精英" },
      { id = "boss", label = "首领" },
    }
    for _, item in ipairs(expected) do
      local grade_btn = child(panel, "BtnCompendiumGrade_" .. item.id)
      assert.is_not_nil(grade_btn)
      assert.same(item.label, btn_label_text(grade_btn))
      assert.is_true(grade_btn.TouchEnabled)
      buttons[#buttons + 1] = grade_btn
    end

    for i = 1, #buttons do
      for j = i + 1, #buttons do
        if rects_overlap(buttons[i], buttons[j]) then
          error(string.format("按钮 %s 与 %s 发生矩形重叠", tostring(buttons[i].Name), tostring(buttons[j].Name)))
        end
      end
    end
  end)

  it("13-03：默认选中第 1 区普通，四档品级切换精确过滤鱼种", function()
    Eui.click(child(root, "BtnCompendiumEntry"))
    local panel = child(root, "ScreenCompendium")

    local normal_ids = visible_fish_ids(panel)
    assert.same(6, #normal_ids)
    for _, id in ipairs(normal_ids) do
      assert.same("fishPond", GameCfg.Fish[id].ZoneId)
      assert.same("normal", GameCfg.Fish[id].Grade)
    end

    Eui.click(child(panel, "BtnCompendiumGrade_rare"))
    local rare_ids = visible_fish_ids(panel)
    assert.same(6, #rare_ids)
    for _, id in ipairs(rare_ids) do
      assert.same("fishPond", GameCfg.Fish[id].ZoneId)
      assert.same("rare", GameCfg.Fish[id].Grade)
    end

    Eui.click(child(panel, "BtnCompendiumGrade_elite"))
    assert.same({ "eel" }, visible_fish_ids(panel))

    Eui.click(child(panel, "BtnCompendiumGrade_boss"))
    assert.same({ "alligatorGar" }, visible_fish_ids(panel))

    -- page_spec 向后兼容与带 grade 过滤校验
    assert.same(14, #CompendiumView.page_spec(1).entries)
    assert.same(1, #CompendiumView.page_spec(1, "elite").entries)
  end)

  it("13-03：品级筛选与七区分页独立正交，不互相重置", function()
    Eui.click(child(root, "BtnCompendiumEntry"))
    local panel = child(root, "ScreenCompendium")

    Eui.click(child(panel, "BtnCompendiumGrade_elite"))
    assert.same({ "eel" }, visible_fish_ids(panel))

    -- 切到第 2 区（虾池），品级仍保持精英
    Eui.click(child(panel, "BtnCompendiumPage_2"))
    assert.same({ "fish15Elite" }, visible_fish_ids(panel))

    -- 切回普通，仍停留在第 2 区（虾池）
    Eui.click(child(panel, "BtnCompendiumGrade_normal"))
    local shrimp_normal = visible_fish_ids(panel)
    assert.same(6, #shrimp_normal)
    for _, id in ipairs(shrimp_normal) do
      assert.same("shrimpPond", GameCfg.Fish[id].ZoneId)
      assert.same("normal", GameCfg.Fish[id].Grade)
    end
  end)

  it("13-03：筛选后未收集剪影文案、五项详情、全服纪录与 98 总数不回归", function()
    Eui.click(child(root, "BtnCompendiumEntry"))
    local panel = child(root, "ScreenCompendium")

    writer:ingest_event("CompendiumState", {
      state = "ready",
      unlocked = { eel = true },
      catches = { eel = 1 },
      weights = { eel = 8.5 },
      total = 1,
    })

    assert.matches("已收集 1/98", child(panel, "LabelCompendiumSummary").Text, 1, true)
    assert.same("？？？", btn_label_text(child(panel, "BtnCompendiumFish_bass")))

    Eui.click(child(panel, "BtnCompendiumGrade_elite"))
    local eel_btn = child(panel, "BtnCompendiumFish_eel")
    assert.same("电鳗", btn_label_text(eel_btn))
    Eui.click(eel_btn)
    assert.same("eel", sent.records[#sent.records])

    writer:ingest_event("RecordsState", {
      state = "ok",
      fishId = "eel",
      weight = 15.2,
      holder = "精英纪录者",
      userId = 101,
    })
    local detail = child(panel, "LabelCompendiumDetail").Text
    for _, text in ipairs({ "电鳗", "精英", "鱼塘", "8.50", "15.2", "精英纪录者" }) do
      assert.matches(text, detail, 1, true)
    end
  end)
end)
