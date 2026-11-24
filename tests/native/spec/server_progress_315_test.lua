local game_cfg = require("common.game_cfg")
local fish_catch = require("common.fish_catch")
local economy_world = require("tests.support.economy_world")

describe("服务端图鉴、纪录与玩家进度宿主接缝（#315）", function()
  local world, platformId
  before_each(function()
    platformId = game_cfg.Achievements.final.PlatformId
    world = economy_world.new()
  end)
  after_each(function()
    if world then world:tearDown() end
    game_cfg.Achievements.final.PlatformId = platformId
    world = nil
  end)

  it("上岸只记一次，个人最大重量只增并在重进后保留", function()
    local species = assert(game_cfg.Fish.bass)
    local first = fish_catch.Weight(species, 1)
    local heavier = fish_catch.Weight(species, 1.5)
    assert.is_true(world:landing("bass", 1, 1))
    assert.is_true(world:landing("bass", 1.5, 2))
    world:landing("bass", 1.5, 2)
    assert.is_true(world:landing("bass", 0.8, 3))
    local bag = world.data.Extra.collection
    assert.same(3, bag.total)
    assert.same(3, bag.catches.bass)
    assert.same(heavier, bag.weights.bass)
    assert.is_true(bag.unlocked.bass)
    assert.is_true(first < heavier)
    world:persistReady()
    world:reconnect()
    assert.same(heavier, world.data.Extra.collection.weights.bass)
    assert.same(3, world.data.Extra.collection.total)
    assert.is_nil(world.data.Extra.blindbox)
  end)

  it("图鉴查询返回真实存档，全服纪录经原子更新保留重量与保持者", function()
    world:request("CompendiumRequest", { seq = 1 })
    assert.same("ready", world:lastResult("CompendiumState").state)
    assert.is_true(world:landing("bass", 1.5, 11))
    world:advance(game_cfg.records.FlushIntervalSec)
    world:request("RecordsRequest", { fishId = "bass", seq = 1 })
    local record = world:lastResult("RecordsState")
    assert.same("ok", record.state)
    assert.same(world.player.UserId, record.userId)
    assert.same(world.player.Name, record.holder)
    assert.same(world.data.Extra.collection.weights.bass, record.weight)
  end)

  it("平台纪录不可读时保留个人图鉴并明确返回未取得数据", function()
    world.failReads = true
    assert.is_true(world:landing("bass", 1, 21))
    world:request("RecordsRequest", { fishId = "bass", seq = 1 })
    assert.same("unavailable", world:lastResult("RecordsState").state)
    assert.is_true(world.data.Extra.collection.unlocked.bass)
  end)

  it("九步任务只按当前步骤推进，重复事件不跳步也不发奖励", function()
    local before = world.data.data.FishCoin
    world:notify("PickBait", { itemId = "worm", count = 5, eventId = "pick-1" })
    world:notify("Feed", { itemId = "worm", count = 5, eventId = "feed-1" })
    world:notify("Buy", { itemId = "starterRod", eventId = "buy-1" })
    world:notify("EquipBait", { itemId = "worm", eventId = "equip-1" })
    world:notify("CastWater", { eventId = "cast-1" })
    assert.is_true(world:landing("bass", 1, 31))
    world:notify("DropShore", { itemId = "bass", eventId = "drop-1" })
    world:notify("Kill", { itemId = "bass", eventId = "kill-1" })
    world:notify("Feed", { category = "fish", eventId = "feed-fish-1" })
    world:notify("Feed", { category = "fish", eventId = "feed-fish-1" })
    assert.same(#game_cfg.Quest.Steps + 1, world.data.Extra.quest.step)
    assert.same(before, world.data.data.FishCoin)
    assert.same("新手任务完成！", world:lastResult("QuestState").text)
  end)

  it("离场等待已接受任务事实落账后才销毁玩家树", function()
    world.runtime:notify_quest("PickBait", world.player, { itemId = "worm", eventId = "leave-1" })
    world.runtime:on_player_removing(world.player)
    assert.is_not_nil(world.runtime:get_player_tree(world.player.UserId))
    world:drain()
    assert.is_nil(world.runtime:get_player_tree(world.player.UserId))
    local saved = world.values[world.save:Key(world.player.UserId)]
    assert.same(1, saved.extra.quest.count)
  end)

  it("剧情资源缺失时给可读兜底，显式已读在重进后不再弹出", function()
    world:clearEvents()
    world:request("RequestStory")
    local notice = world:lastResult("StoryNotice")
    assert.same("opening", notice.readKey)
    assert.is_true(#notice.lines > 0)
    world:request("StoryRead", { action = "read", readKey = "opening" })
    assert.is_true(world:lastResult("StoryState").read)
    world:persistReady()
    world:reconnect()
    world:clearEvents()
    world:request("RequestStory")
    assert.is_nil(world:lastResult("StoryNotice"))
  end)

  -- 13-12 / 13-13 / 13-14：本地标记、失败补交与确认去重。
  it("通关成就先保留本地标记，平台失败保留补交且确认后不重复", function()
    game_cfg.Achievements.final.PlatformId = 123456
    world.data.Extra.achievements.final = true
    world.archive.completed = false
    world:advance(1)
    assert.same(1, #world.archive.submissions)
    assert.is_nil((world.data.Extra.achievementDelivered or {}).final)
    world.archive.completed = true
    world:advance(game_cfg.AchievementDelivery.RetrySec + 1)
    world:advance(game_cfg.AchievementDelivery.RetrySec + 1)
    assert.is_true((world.data.Extra.achievementDelivered or {}).final)
    local submissions = #world.archive.submissions
    world:advance(game_cfg.AchievementDelivery.RetrySec + 1)
    assert.same(submissions, #world.archive.submissions)
  end)

  it("GM 只经上行意图修改调试状态，关闭调试后拒绝", function()
    local before = world.data.data.FishCoin
    world:request("GMAction", { action = "Coin", amount = 25 })
    assert.same(before + 25, world.data.data.FishCoin)
    assert.is_true(world:lastResult("GMResult").ok)
    game_cfg.Debug.Enabled = false
    world:request("GMAction", { action = "Coin", amount = 25 })
    assert.same(before + 25, world.data.data.FishCoin)
    assert.is_false(world:lastResult("GMResult").ok)
  end)
end)


describe("服务端旧进度玩法的公开宿主等价迁移（#315）", function()
  local world, platformId, placeholderId
  before_each(function()
    platformId = game_cfg.Achievements.final.PlatformId
    placeholderId = game_cfg.Achievements.final.PlaceholderId
    world = economy_world.new()
  end)
  after_each(function()
    if world then world:tearDown() end
    game_cfg.Achievements.final.PlatformId = platformId
    game_cfg.Achievements.final.PlaceholderId = placeholderId
    world = nil
  end)

  it("九十八种鱼各自解锁，盲盒计数不混入且重复上岸序列只落一次", function()
    world.data.Extra.lottery.pity = 3
    local serial = 0
    for fishId in pairs(game_cfg.Fish) do
      serial = serial + 1
      assert.is_true(world:landing(fishId, 1, serial))
    end
    world:request("CompendiumRequest", {})
    local snapshot = world:lastResult("CompendiumState")
    assert.same(98, snapshot.total)
    local count = 0
    for fishId in pairs(game_cfg.Fish) do
      assert.is_true(snapshot.unlocked[fishId], fishId)
      count = count + 1
    end
    assert.same(98, count)
    assert.same(3, world.data.Extra.lottery.pity)
    assert.is_nil(snapshot.catches.lottery)
    local operations = #world.data.SaveMeta.operations
    assert.is_false(world:landing("bass", 1, 98))
    world:request("CompendiumRequest", {})
    assert.same(98, world:lastResult("CompendiumState").total)
    assert.same(operations, #world.data.SaveMeta.operations)
  end)

  it("击杀、岸边掉落和物品入包不生成钓取重量，个人最佳重进后不回退", function()
    assert.is_true(world:landing("bass", 1.5, 1))
    assert.is_true(world:landing("bass", 0.5, 2))
    assert.is_false(world:landing("bass", 0.5, 2))
    assert.is_false(world:notify("Kill", { itemId = "goldfish", eventId = "kill-no-collection" }))
    assert.is_false(world:notify("DropShore", { itemId = "goldfish", eventId = "drop-no-collection" }))
    world:request("CompendiumRequest", {})
    local before = world:lastResult("CompendiumState")
    assert.same(2, before.total)
    assert.same(3, before.weights.bass)
    assert.is_nil(before.unlocked.goldfish)
    world:persistReady()
    world:reconnect()
    world:request("CompendiumRequest", {})
    local restored = world:lastResult("CompendiumState")
    assert.same(3, restored.weights.bass)
    assert.same(2, restored.catches.bass)
  end)

  it("已接受的图鉴上岸写在离场前排空，保存失败时不伪造图鉴", function()
    assert.is_true(world.runtime:record_landing(world.player, { fishId = "bass", mult = 1, reelSerial = 77 }))
    world.runtime:on_player_removing(world.player)
    assert.is_not_nil(world.runtime:get_player_tree(world.player.UserId))
    world:drain()
    assert.is_nil(world.runtime:get_player_tree(world.player.UserId))
    assert.same(2, world:saved(world.player.UserId).extra.collection.weights.bass)
  end)

  it("图鉴写失败保留空状态，平台恢复后新事件仍可落账", function()
    world.failWrites = true
    assert.is_true(world:landing("bass", 1, 1))
    world:request("CompendiumRequest", {})
    assert.same(0, world:lastResult("CompendiumState").total)
    world.failWrites = false
    world:usePlayer(world:addPlayer(2500, "新会话"))
    assert.is_true(world:landing("bass", 1, 2))
    world:request("CompendiumRequest", {})
    assert.same(1, world:lastResult("CompendiumState").total)
  end)

  it("全服纪录合并且只提交个人最佳，失败重试不丢保持者", function()
    assert.is_true(world:landing("bass", 1, 1))
    assert.is_true(world:landing("bass", 1.5, 2))
    world.recordWriteFailures = 1
    world:advance(game_cfg.records.FlushIntervalSec + 1)
    world:advance(game_cfg.records.RetryDelaySec + 1)
    assert.is_true(world.recordWrites >= 2)
    assert.same(300, world.values["rec:bass"].w)
    assert.same(world.player.UserId, world.values["rec:bass"].u)
    local writes = world.recordWrites
    assert.is_true(world:landing("bass", 0.5, 3))
    world:advance(game_cfg.records.FlushIntervalSec + 1)
    assert.same(writes, world.recordWrites)
    world:clearEvents()
    world:request("RecordsRequest", { fishId = "bass", seq = 1 })
    local record = world:lastResult("RecordsState")
    assert.same("ok", record.state)
    assert.same(3, record.weight)
    assert.same(world.player.Name, record.holder)
  end)

  it("同鱼并发查询共享一次平台读，损坏值与读取失败均不伪造纪录", function()
    world:fire("RecordsRequest", { fishId = "bass", seq = 1 })
    world:fire("RecordsRequest", { fishId = "bass", seq = 2 })
    assert.same(0, world.recordReads)
    world:drain()
    assert.same(1, world.recordReads)
    assert.same(2, #world:messages("RecordsState"))
    world:advance(game_cfg.records.MissCacheTtlSec + 1)
    world.values["rec:bass"] = { w = 200 }
    world:request("RecordsRequest", { fishId = "bass", seq = 3 })
    assert.same("missing", world:lastResult("RecordsState").state)
    world:advance(game_cfg.records.MissCacheTtlSec + 1)
    world.failRecordReads = true
    world:request("RecordsRequest", { fishId = "bass", seq = 4 })
    assert.same("unavailable", world:lastResult("RecordsState").state)
  end)

  it("丢失的平台提交会在缓存过期后的查询中按个人最佳调和", function()
    assert.is_true(world:landing("bass", 1, 1))
    world:advance(game_cfg.records.FlushIntervalSec + 1)
    assert.same(200, world.values["rec:bass"].w)
    world.values["rec:bass"] = nil
    world:advance(game_cfg.records.HolderCacheTtlSec + 1)
    world:request("RecordsRequest", { fishId = "bass", seq = 1 })
    world:advance(game_cfg.records.FlushIntervalSec + 1)
    assert.same(200, world.values["rec:bass"].w)
  end)

  it("字符串平台账号的重量、保持者和存档身份不串号", function()
    local player, data = world:addPlayer("aU5A95JB9rit0DUl", "甲")
    world:usePlayer(player)
    assert.is_true(world:landing("bass", 1, 1))
    world:advance(game_cfg.records.FlushIntervalSec + 1)
    assert.same("aU5A95JB9rit0DUl", world.values["rec:bass"].u)
    assert.same("甲", world.values["rec:bass"].n)
    assert.same(2, world:saved(player.UserId).extra.collection.weights.bass)
    assert.is_nil(world:saved(1472).extra.collection.weights.bass)
    world:persistReady()
    world:reconnect()
    assert.same(200, world.data:PersonalBestScaled("bass"))
  end)

  it("任务乱序与重复事实不推进、不发奖，部分计数跨重进且按新 epoch 去重", function()
    assert.is_false(world:notify("Feed", { itemId = "tilapia", eventId = "early" }))
    local coin = world.data.data.FishCoin
    assert.is_true(world:notify("PickBait", { itemId = "worm", eventId = "same" }))
    assert.same(coin, world.data.data.FishCoin)
    assert.is_false(world:notify("PickBait", { itemId = "worm", eventId = "same" }))
    world:persistReady()
    world:reconnect()
    assert.is_true(world:notify("PickBait", { itemId = "worm", count = 2, eventId = "same" }))
    assert.same(3, world.data.Extra.quest.count)
    world:persistReady()
    world:reconnect()
    assert.same(3, world.data.Extra.quest.count)
    assert.is_true(world:notify("PickBait", { itemId = "worm", count = 1, eventId = "same" }))
    assert.same(4, world.data.Extra.quest.count)
  end)

  it("剧情已读写失败保持未读并可重试，离场等待已接受已读写", function()
    world:clearEvents()
    world:request("RequestStory")
    assert.same("opening", world:lastResult("StoryNotice").readKey)
    world.failWrites = true
    world:request("StoryRead", { action = "read", readKey = "opening" })
    assert.is_nil(world.data.Extra.story.read.opening)
    world.failWrites = false
    world:usePlayer(world:addPlayer(2400, "重试"))
    world:clearEvents()
    world:request("RequestStory")
    world:request("StoryRead", { action = "read", readKey = "opening" })
    assert.is_true(world:lastResult("StoryState").read)
    world:clearEvents()
    world:request("RequestStory")
    assert.is_nil(world:lastResult("StoryNotice"))
    local other = world:addPlayer(2401, "离场")
    world:usePlayer(other)
    world:clearEvents()
    world:request("RequestStory")
    world:fire("StoryRead", { action = "read", readKey = "opening" })
    world.runtime:on_player_removing(other)
    assert.is_not_nil(world.runtime:get_player_tree(other.UserId))
    world:drain()
    assert.is_nil(world.runtime:get_player_tree(other.UserId))
    assert.is_true(world:saved(other.UserId).extra.story.read.opening)
  end)

  -- 13-18 / 17-17：占位 ID 只走可替换补交路径，不伪报平台授予。
  it("生产不写占位成就，调试占位只补交不宣称平台已授予", function()
    game_cfg.Achievements.final.PlatformId = nil
    game_cfg.Achievements.final.PlaceholderId = 990001
    game_cfg.Debug.Enabled = false
    world.data.Extra.achievements.final = true
    world:advance(game_cfg.AchievementDelivery.RetrySec + 1)
    assert.same(0, #world.archive.queries)
    assert.is_nil((world.data.Extra.achievementDelivered or {}).final)
    game_cfg.Debug.Enabled = true
    world.archive.completed = false
    world:advance(game_cfg.AchievementDelivery.RetrySec + 1)
    assert.same(990001, world.archive.submissions[1].id)
    world.archive.completed = true
    world:advance(game_cfg.AchievementDelivery.RetrySec + 1)
    assert.is_nil((world.data.Extra.achievementDelivered or {}).final)
  end)

  -- 13-18 / 17-17：真实 ID 确认与平台异常仍遵循同一持久化契约。
  it("成就平台查询和提交异常均可补交，真实 ID 确认只落一次", function()
    game_cfg.Achievements.final.PlatformId = 3801
    world.data.Extra.achievements.final = true
    world.archive.queryError = true
    world:advance(1)
    assert.same(0, #world.archive.submissions)
    world.archive.queryError = false
    world.archive.submitError = true
    world:advance(game_cfg.AchievementDelivery.RetrySec + 1)
    assert.same(0, #world.archive.submissions)
    world.archive.submitError = false
    world:advance(game_cfg.AchievementDelivery.RetrySec + 1)
    assert.same(1, #world.archive.submissions)
    world.archive.completed = true
    world:advance(game_cfg.AchievementDelivery.RetrySec + 1)
    assert.is_true((world.data.Extra.achievementDelivered or {}).final)
    local submissions = #world.archive.submissions
    world:advance(game_cfg.AchievementDelivery.RetrySec + 1)
    assert.same(submissions, #world.archive.submissions)
  end)

  it("GM 金币与物品按目标隔离，非法数量、离线路径和关闭调试均拒绝", function()
    local other, otherData = world:addPlayer(2001, "目标")
    world:request("GMAction", { action = "Coin", amount = 10 })
    world:request("GMAction", { action = "Coin", amount = 7, target = other.UserId })
    assert.same(10, world.data.data.FishCoin)
    assert.same(7, otherData.data.FishCoin)
    world:request("GMAction", { action = "Coin", amount = 7, target = 9999 })
    assert.is_false(world:lastResult("GMResult").ok)
    world:request("GMAction", { action = "Coin", amount = -4 })
    assert.same(6, world.data.data.FishCoin)
    for _, amount in ipairs({ 0, 2.5, -11 }) do
      world:request("GMAction", { action = "Coin", amount = amount })
      assert.same(6, world.data.data.FishCoin)
    end
    local bait = otherData.data.Bait.worm or 0
    world:request("GMAction", { action = "Item", itemId = "worm", count = 5, target = other.UserId })
    assert.same(bait + 5, otherData.data.Bait.worm)
    world:request("GMAction", { action = "Item", itemId = "starterRod", count = 2 })
    assert.same(2, world.data:ItemCount("starterRod"))
    assert.is_nil(world.data.data.Bait.starterRod)
    local snapshot = world.data:GetItemBarSnapshot()
    assert.is_not_nil(snapshot.slots)
    assert.is_not_nil(snapshot.backpack)
    game_cfg.Debug.Enabled = false
    world:request("GMAction", { action = "Coin", amount = 100 })
    assert.same(6, world.data.data.FishCoin)
  end)

  it("GM 临时补丁原子保留其他字段，显式保存失败不解除暂停，读档恢复权威快照", function()
    world:request("GMAction", { action = "Coin", amount = 20 })
    world:request("GMAction", { action = "ApplyState", coin = 101 })
    assert.same(101, world.data.data.FishCoin)
    assert.is_true(world:lastResult("GMResult").status.autosavePaused)
    local before = world.data:GetItemBarSnapshot()
    world:request("GMAction", { action = "ApplyState", coin = 500, upgradeLevel = 99 })
    assert.same(101, world.data.data.FishCoin)
    assert.same(before.upgradeLevel, world.data:GetItemBarSnapshot().upgradeLevel)
    world.failWrites = true
    world:request("GMAction", { action = "SaveState" })
    assert.is_false(world:lastResult("GMResult").ok)
    assert.is_true(world:lastResult("GMResult").status.autosavePaused)
    world.failWrites = false
    world:request("GMAction", { action = "SaveState" })
    assert.is_true(world:lastResult("GMResult").ok)
    assert.same(101, world:saved(world.player.UserId).coin)
    world:request("GMAction", { action = "ApplyState", coin = 777 })
    assert.same(777, world.data.data.FishCoin)
    world:request("GMAction", { action = "ReadState" })
    assert.same(101, world.data.data.FishCoin)
  end)

  it("GM 命名存档槽只在重进切换，攻击加成与下一鱼保持服务端权威", function()
    world:request("GMAction", { action = "SelectSaveSlot", slot = "qa-one" })
    assert.is_true(world:lastResult("GMResult").ok)
    world:reconnect()
    world:request("GMAction", { action = "GetState" })
    assert.same("qa-one", world:lastResult("GMResult").status.currentSlot)
    world:request("GMAction", { action = "AddAttack" })
    world:request("GMAction", { action = "GetAttack" })
    assert.is_true(world:lastResult("GMResult").damage > 0)
    world:request("GMAction", { action = "NextFish", fishId = "bass" })
    assert.is_true(world:lastResult("GMResult").ok)
    world:request("GMAction", { action = "NextFish", fishId = "not-a-fish" })
    assert.is_false(world:lastResult("GMResult").ok)
  end)

  it("GM 增删鱼币、发物品、ApplyState 与 ReadState 在 player_tree 存在时立即同步库存与 HUD", function()
    local tree = assert(world.runtime:get_player_tree(world.player.UserId))
    world:clearEvents()

    world:request("GMAction", { action = "Coin", amount = 50 })
    assert.same(50, tree.states.coin:now())
    assert.same(50, tree:get_item_bar_snapshot().coin)
    local hud = world:lastResult("ItemBarState")
    assert.is_not_nil(hud)
    assert.same(50, hud.coin)

    world:clearEvents()
    world:request("GMAction", { action = "Item", itemId = "starterRod", count = 1 })
    assert.same("starterRod", tree:get_item_bar_snapshot().slots[1].itemId)
    assert.same("starterRod", world:lastResult("ItemBarState").slots[1].itemId)

    world:request("GMAction", { action = "SaveState" })
    assert.is_true(world:lastResult("GMResult").ok)

    world:clearEvents()
    world:request("GMAction", { action = "ApplyState", coin = 321 })
    assert.same(321, tree.states.coin:now())
    assert.same(321, world:lastResult("ItemBarState").coin)

    world:clearEvents()
    world:request("GMAction", { action = "ReadState" })
    assert.same(50, tree.states.coin:now())
    assert.same(50, world:lastResult("ItemBarState").coin)

    local other = world:addPlayer(2601, "跨目标")
    local otherTree = assert(world.runtime:get_player_tree(other.UserId))
    world:clearEvents()
    world:request("GMAction", { action = "Coin", amount = 88, target = other.UserId })
    assert.same(88, otherTree.states.coin:now())
    local pushedToOther = false
    for _, ev in ipairs(world.events) do
      if ev.name == "ItemBarState" and ev.player == other and ev.value.coin == 88 then
        pushedToOther = true
      end
    end
    assert.is_true(pushedToOther)
  end)

  it("多玩家并发挂载与重连时全局 RE 仅单次 Connect，不呈 O(n) 扇出且按 UserId 隔离", function()
    local p2 = world:addPlayer(2701, "乙")
    local p3 = world:addPlayer(2702, "丙")
    local p4 = world:addPlayer(2703, "丁")

    for _, channel in ipairs({
      "CompendiumRequest", "RequestQuest", "RequestStory", "StoryRead", "GMAction", "RecordsRequest",
    }) do
      assert.same(1, world.channels[channel].OnServerEvent.connects,
        channel .. " 不得随在线玩家数线性重复 Connect")
    end

    world:clearEvents()
    world:fire("GMAction", { action = "Coin", amount = 13 }, p2)
    world:drain()
    assert.same(13, world.players:GetDataInst(p2).data.FishCoin)
    assert.same(0, world.players:GetDataInst(p3).data.FishCoin)
    assert.same(0, world.players:GetDataInst(p4).data.FishCoin)

    world:clearEvents()
    world:fire("CompendiumRequest", { seq = 1 }, p3)
    world:drain()
    local replies = 0
    for _, ev in ipairs(world.events) do
      if ev.name == "CompendiumState" then
        replies = replies + 1
        assert.same(p3, ev.player)
      end
    end
    assert.same(1, replies)

    world.runtime:on_player_removing(p3)
    world:drain()
    world:clearEvents()
    world:fire("CompendiumRequest", { seq = 2 }, p3)
    world:drain()
    assert.same(0, #world:messages("CompendiumState"))

    world:reconnect()
    for _, channel in ipairs({
      "CompendiumRequest", "RequestQuest", "RequestStory", "StoryRead", "GMAction", "RecordsRequest",
    }) do
      assert.same(1, world.channels[channel].OnServerEvent.connects,
        channel .. " 重连后仍应保持单次 Connect")
    end
  end)

  it("玩家离场清理图鉴与全服纪录的 LastSeq，重连后 seq=1 正常受理", function()
    world:request("CompendiumRequest", { seq = 10 })
    assert.same(10, world:lastResult("CompendiumState").seq)
    world:clearEvents()
    world:request("CompendiumRequest", { seq = 5 })
    assert.is_nil(world:lastResult("CompendiumState"))

    world:request("RecordsRequest", { fishId = "bass", seq = 10 })
    assert.same(10, world:lastResult("RecordsState").seq)
    world:clearEvents()
    world:request("RecordsRequest", { fishId = "bass", seq = 5 })
    assert.is_nil(world:lastResult("RecordsState"))

    local records = world.runtime:get_world().records
    local uid = world.player.UserId
    assert.same(10, records.LastSeq[uid])

    local oldPlayer = world.player
    world.runtime:on_player_removing(oldPlayer)
    world.platform:OnPlayerRemoving(oldPlayer)
    world.players:OnPlayerRemoving(oldPlayer)
    world:drain()
    assert.is_nil(records.LastSeq[uid], "玩家离场后 world_records.LastSeq 须清理")

    local back = world:addPlayer(uid, "重连玩家")
    world:usePlayer(back)
    world:clearEvents()
    world:request("CompendiumRequest", { seq = 1 })
    assert.same(1, world:lastResult("CompendiumState").seq)
    world:request("RecordsRequest", { fishId = "bass", seq = 1 })
    assert.same(1, world:lastResult("RecordsState").seq)
  end)

  it("图鉴/任务/剧情/成就已移除无调用的 Start 死代码，且非每帧模块不订阅 on_frame", function()
    assert.is_nil(require("server.world_host.player_compendium").Start)
    assert.is_nil(require("server.world_host.player_quest").Start)
    assert.is_nil(require("server.world_host.player_story").Start)
    assert.is_nil(require("server.world_host.player_achievements").Start)

    assert.is_true(world:landing("bass", 1.5, 99))
    local beforeWrites = world.recordWrites
    world:advance(0.2)
    assert.same(beforeWrites, world.recordWrites)
    world:advance(game_cfg.records.FlushIntervalSec)
    assert.is_true(world.recordWrites > beforeWrites)
  end)
end)
