local GameCfg = require("common.game_cfg")
local ClientStore = require("client.store.client_store")
local RootView = require("client.views.root_view")
local CompendiumView = require("client.views.compendium_view")
local GuideView = require("client.views.guide_view")
local MessageView = require("client.views.message_view")
local StoryView = require("client.views.story_view")
local GMView = require("client.views.gm_view")
local Eui = require("tests.support.eui_double")

local function child(root, name) return root:FindFirstChild(name, true) end

describe("客户端图鉴纪录与剩余模态宿主接缝（#315）", function()
  local root, store, writer, view, sent, oldVector, oldColor
  before_each(function()
    oldVector, oldColor = rawget(_G, "Vector2"), rawget(_G, "Color")
    _G.Vector2 = { New = function(x, y) return { x = x, y = y } end }
    _G.Color = { New = function(...) return { ... } end }
    sent = { compendium = 0, records = {}, story = {}, gm = {} }
    store, writer = ClientStore.new()
    root = Eui.Node({ Name = "UIRoot" })
    view = RootView.mount(root, store, {
      services = {
        open_modal = function(id, payload) writer:open_modal(id, payload) end,
        close_modal = function(id) writer:close_modal(id) end,
        request_compendium = function() sent.compendium = sent.compendium + 1 end,
        request_records = function(fishId) sent.records[#sent.records + 1] = fishId end,
        send_story = function(payload) sent.story[#sent.story + 1] = payload end,
        send_gm = function(payload) sent.gm[#sent.gm + 1] = payload end,
      },
      hud = { CompendiumView.entry_spec(), GuideView.spec(), MessageView.spec() },
      modals = {
        compendium = CompendiumView.modal_spec(),
        story = StoryView.modal_spec(),
        gm = GMView.modal_spec(),
      },
      create_node = function(kind, props)
        return Eui.Node({
          Kind = kind, Name = props and props.Name, Parent = props and props.Parent,
          Visible = props and props.Visible, Text = props and props.Text,
          ButtonText = props and props.ButtonText, Position = props and props.Position,
          Size = props and props.Size, TouchEnabled = kind == "EUIButton",
        })
      end,
    })
  end)
  after_each(function()
    if view then view:dispose() end
    _G.Vector2, _G.Color = oldVector, oldColor
  end)

  -- 13-07 / 13-08：五项详情、真实保持者与未取得数据。
  it("图鉴七页九十八项展示个人最大重量与真实全服纪录", function()
    Eui.Click(child(root, "BtnCompendiumEntry"))
    assert.same(1, sent.compendium)
    assert.is_not_nil(child(root, "ScreenCompendium"))
    local count = 0
    for _, node in pairs(child(root, "ScreenCompendium").Children) do
      if tostring(node.Name):match("^CompendiumRow_") then count = count + 1 end
    end
    assert.same(98, count)
    writer:ingest_event("CompendiumState", {
      state = "ready", unlocked = { bass = true }, catches = { bass = 2 },
      weights = { bass = 12.5 }, total = 2,
    })
    Eui.Click(child(root, "BtnCompendiumFish_bass"))
    assert.same("bass", sent.records[#sent.records])
    writer:ingest_event("RecordsState", {
      state = "ok", fishId = "bass", weight = 20, holder = "纪录保持者", userId = 9,
    })
    local detail = child(root, "LabelCompendiumDetail").Text
    for _, text in ipairs({ "鲈鱼", "品级", "钓鱼区", "12.5", "20", "纪录保持者" }) do
      assert.matches(text, detail)
    end
    writer:ingest_event("RecordsState", { state = "missing", fishId = "carp" })
    assert.matches("20", child(root, "LabelCompendiumDetail").Text)
    writer:ingest_event("RecordsState", { state = "unavailable", fishId = "bass" })
    assert.matches("未取得数据", child(root, "LabelCompendiumDetail").Text)
  end)

  it("任务和消息是 HUD 投影，剧情已读与 GM 操作只发上行意图", function()
    writer:ingest_event("QuestState", { step = 1, count = 2, need = 5, text = "新手任务：拾取蚯蚓" })
    local quest_label = child(root, "QuestLabel")
    assert.is_true(child(root, "QuestToggle").Visible)
    assert.matches("拾取蚯蚓", quest_label.Text)
    Eui.Click(child(root, "QuestToggle"))
    assert.is_false(quest_label.Visible)
    Eui.Click(child(root, "QuestToggle"))
    assert.is_true(quest_label.Visible)
    writer:show_notice("拾取 5 只蚯蚓")
    assert.same("拾取 5 只蚯蚓", child(root, "LabelMessage").Text)
    writer:ingest_event("StoryNotice", { title = "开场", lines = { "欢迎来到钓场" }, readKey = "opening" })
    assert.is_not_nil(child(root, "ScreenStory"))
    local story_title, story_body = child(root, "DialogueTitle"), child(root, "DialogueBody")
    assert.is_true(story_title.Position.y > story_body.Position.y)
    assert.is_true(story_body.Position.y > child(root, "DialogueRead").Position.y)
    Eui.Click(child(root, "DialogueRead"))
    assert.same({ action = "read", readKey = "opening" }, sent.story[1])
    writer:ingest_event("StoryState", { read = true, readKey = "opening" })
    assert.is_nil(child(root, "ScreenStory"))
    writer:open_modal("gm")
    Eui.Click(child(root, "BtnGMCoin"))
    assert.same({ action = "Coin", amount = 100 }, sent.gm[1])
    writer:ingest_event("GMResult", { ok = true, action = "Coin", target = 7 })
    assert.matches("成功", child(root, "LabelGMResult").Text)
  end)

  it("切窗、关闭与根 UI 销毁都释放节点和事件连接", function()
    writer:open_modal("compendium")
    local compendium = child(root, "ScreenCompendium")
    writer:open_modal("gm")
    assert.is_true(compendium.Destroyed)
    local gm = child(root, "ScreenGM")
    local button = child(root, "BtnGMCoin")
    assert.same(1, button.OnClicked:Count())
    writer:close_modal("gm")
    assert.is_true(gm.Destroyed)
    assert.same(0, button.OnClicked:Count())
    writer:open_modal("story", { title = "开场", lines = { "文本" }, readKey = "opening" })
    local story = child(root, "ScreenStory")
    root:Destroy()
    assert.is_true(story.Destroyed)
    assert.same(0, root.Destroying:Count())
  end)

  it("盲盒不伪造重量，迟到图鉴与纪录快照不能回滚新状态", function()
    writer:open_modal("compendium")
    assert.is_true(writer:ingest_event("CompendiumState", {
      seq = 2, state = "ready", unlocked = { bass = true }, weights = {}, catches = {}, total = 0, completed = true,
    }))
    assert.is_false(writer:ingest_event("CompendiumState", {
      seq = 1, state = "ready", unlocked = {}, weights = {}, catches = {}, total = 0,
    }))
    assert.matches("已收集 1/98", child(root, "LabelCompendiumSummary").Text, 1, true)
    assert.matches("已完成", child(root, "LabelCompendiumAchievement").Text, 1, true)
    assert.is_false(writer:ingest_event("CompendiumState", { seq = 3, unlocked = true, weights = {} }))
    Eui.Click(child(root, "BtnCompendiumFish_bass"))
    assert.matches("尚未钓取", child(root, "LabelCompendiumDetail").Text, 1, true)
    assert.is_true(writer:ingest_event("RecordsState", { seq = 2, fishId = "bass", state = "ok", weight = 3, holder = "新" }))
    assert.is_false(writer:ingest_event("RecordsState", { seq = 1, fishId = "bass", state = "missing" }))
    assert.matches("新", child(root, "LabelCompendiumDetail").Text, 1, true)
  end)

  -- 13-17：纪录服务不可用时只展示明确的未取得数据。
  it("未取得数据与平台不可用同文案，过期真实纪录保持明确标记", function()
    writer:open_modal("compendium")
    Eui.Click(child(root, "BtnCompendiumFish_bass"))
    writer:ingest_event("RecordsState", { seq = 1, fishId = "bass", state = "missing" })
    assert.matches("未取得数据", child(root, "LabelCompendiumDetail").Text, 1, true)
    writer:ingest_event("RecordsState", { seq = 2, fishId = "bass", state = "unavailable" })
    assert.matches("未取得数据", child(root, "LabelCompendiumDetail").Text, 1, true)
    writer:ingest_event("RecordsState", { seq = 3, fishId = "bass", state = "ok", weight = 0.2, holder = "钓鱼佬", stale = true })
    local detail = child(root, "LabelCompendiumDetail").Text
    assert.matches("钓鱼佬", detail, 1, true)
    assert.matches("数据可能过期", detail, 1, true)
  end)

  it("GM 鱼类分页有边界，状态字段按上行意图发送并接收服务器快照", function()
    writer:open_modal("gm")
    assert.same(GameCfg.Fish.eel.Name, child(root, "BtnGMNextFish_1").ButtonText)
    Eui.Click(child(root, "BtnGMNextFish_1"))
    assert.same({ action = "NextFish", fishId = "eel" }, sent.gm[#sent.gm])
    Eui.Click(child(root, "BtnGMFishPrev"))
    assert.matches("1/", child(root, "LabelGMFishPage").Text, 1, true)
    Eui.Click(child(root, "BtnGMFishNext"))
    assert.matches("2/", child(root, "LabelGMFishPage").Text, 1, true)
    assert.is_true(#child(root, "BtnGMNextFish_1").ButtonText > 0)
    child(root, "GMInput_coin").Text = "0"
    child(root, "GMInput_container").Text = "backpack"
    child(root, "GMInput_index").Text = "2"
    Eui.Click(child(root, "BtnGMApplyState"))
    assert.same({ action = "ApplyState", coin = 0, container = "backpack", index = 2 }, sent.gm[#sent.gm])
    writer:ingest_event("GMResult", { ok = true, action = "GetState", snapshot = { coin = 0, upgradeLevel = 3 }, status = { slot = "qa-one" } })
    assert.same("0", child(root, "GMInput_coin").Text)
    assert.same("3", child(root, "GMInput_upgradeLevel").Text)
    assert.same("qa-one", child(root, "GMInput_slot").Text)
  end)

  it("任务折叠跨快照保留，长文本在面板内换行", function()
    writer:ingest_event("QuestState", { text = "12345678901234567890" })
    local label = child(root, "QuestLabel")
    assert.matches("\n", label.Text)
    Eui.Click(child(root, "QuestToggle"))
    assert.is_false(label.Visible)
    writer:ingest_event("QuestState", { text = "新的任务" })
    assert.is_false(label.Visible)
    Eui.Click(child(root, "QuestToggle"))
    assert.is_true(label.Visible)
    assert.same("新的任务", label.Text)
  end)
end)
