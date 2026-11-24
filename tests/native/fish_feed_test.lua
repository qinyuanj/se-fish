-- 迁移自 tests/gameplay/fish_feed_test.lua（#85）；行为契约原文见 #44、#127、#49。
-- #44 向钓鱼佬喂食换金币（真 PlayerData + 假钓鱼佬锚点单位）。
-- #127 起回收口径放宽：选中格里的**任何**有基础价的物品都按基础价 × 实例倍率回收（鱼竿、道具、船票同理），
-- 烤过的按烤熟价 ×1.5；「选中鱼竿也能换钱」不再是缺陷，「什么都没选」才是 'nothing'。
-- 失败方式（先列后写）：
--   1. 金币算错：四舍五入而不是 floor(基础售价 × 个体倍率)、倍率缺省不按 1、蚯蚓不是每只 1 金币、
--      用了商店买入价；
--   2. 扣错库存：鱼获不从选中格扣、扣了别的格或整格以外的东西；鱼饵不从 Bait 计数扣而另建库存；
--      空格 / 没选中时也能换钱；
--   3. 不复验：不在钓鱼佬 5 米内（按 x/z）、目标不是登记的交互点、动作不是喂食、玩家数据未就绪也能结算；
--   4. 重放：同一请求序号重复到达、旧序号回放各结算一次；
--   5. 扣除、入账、选中态归位不同步：扣了没加钱或加了没扣，选中格清空后仍指向空格，不推送库存；
--   6. 金币有第二个写入口，或 FishCoin 属性没随入账更新；
--   7. 吃动作失败（锚点没有动画）连带裁决失败。
-- it 名字沿用旧方法名，注册顺序 = LuaUnit sortedPairs 的实际执行顺序。

local GameCfg = require('common.game_cfg')
local Host = require('tests.support.shop_feed_host')
local function vec(x, y, z) return { x = x, y = y, z = z } end

describe('向钓鱼佬喂食换金币（PlayerFisherman）', function()
  local env
  local restore

  before_each(function()
    -- 快照先于任何改动：before_each 中途失败时 after_each 仍能还原。
    env = { seq = 0 }
    env.cfg = GameCfg
    local initial_grants = GameCfg.Debug.InitialGrants
    env.host = Host.start()
    GameCfg.Debug = { Enabled = true, InitialGrants = initial_grants }
    env.player, env.data = env.host:join(1, GameCfg.Interact.Fishermen[1].AnchorNames[1])
    env.stranger = { UserId = 2, Character = { Position = vec(100, 1, 0) }, SetAttribute = function() end }
    env.replies = env.host.results[1].InteractResult
    env.anchor = env.host.anchors[GameCfg.Interact.Fishermen[1].AnchorNames[1]]
    env.anchor.plays = {}
    env.plays = env.anchor.plays
  end)

  after_each(function()
    env.host:shutdown()
    env = nil
  end)

  local function feed(extra)
    env.seq = env.seq + 1
    local payload = { target = 'fisherman', action = 'Feed', seq = env.seq }
    for k, v in pairs(extra or {}) do payload[k] = v end
    local reply = env.host:send(env.player, 'InteractAction', payload)
    return reply and reply.ok or false
  end

  local function send(player, payload)
    local reply = env.host:send(player, 'InteractAction', payload)
    return reply and reply.ok or false
  end

  local function give(itemId, mult)
    assert.is_true(env.data:AddItem(itemId, mult))
    local items = env.data.Data.Containers.itemBar
    for index = 1, 8 do
      if items[index] and items[index].itemId == itemId and items[index].mult == mult then return index end
    end
  end

  it('test_feed_selected_bait_takes_one_worm_for_one_coin', function()
    assert.is_true(env.data:SelectBait('worm'))
    local before = env.data.Data.Bait.worm
    assert.is_true(feed())
    assert.same(before - 1, env.data.Data.Bait.worm)
    assert.same(1, env.data.Data.FishCoin)
    assert.same(1, env.player.attrs.FishCoin)
    assert.is_nil(env.data.Data.Bait.bait)
    assert.is_nil(env.data.Data.Containers.bait)
  end)

  it('test_feed_selected_fish_takes_that_slot_and_pays_once', function()
    give('carp', 1.1)
    assert.is_true(env.data:DiscardSlot(1))
    local slot = give('bass', 1.99)
    assert.is_true(env.data:SelectSlot(slot))
    assert.is_true(feed())
    assert.same(11, env.data.Data.FishCoin)
    assert.same(11, env.player.attrs.FishCoin)
    assert.is_nil(env.data.Data.Containers.itemBar[slot])
    assert.same('carp', env.data.Data.Containers.itemBar[2].itemId)
    assert.is_nil(env.data.Data.SelectedSlot)
    assert.same(env.cfg.Debug.InitialGrants[2].count, env.data.Data.Bait.worm)
    assert.same(1, env.host.sync_counts[1])
    assert.same({ env.cfg.Interact.Fisherman.EatAnimation }, env.plays)
    assert.is_true(env.replies[#env.replies].ok)
    assert.same(11, env.replies[#env.replies].coins)
  end)

  it('test_fish_coin_has_single_write_entry', function()
    local writers = 0
    for _, path in ipairs({ 'server/data/player_data.lua', 'server/world_host/player_fisherman.lua',
      'server/player_data_host.lua', 'server/world_host/ground_loot.lua' }) do
      local file = assert(io.open(path, 'r'))
      local text = file:read('a')
      file:close()
      for _ in text:gmatch('[%.%s]FishCoin%s*=%s*[^=]') do writers = writers + 1 end
    end
    -- PlayerData:Init 的初值 + AddCoin 里的唯一一处累加 + ApplySave 的读档恢复（#92，不是运行时收支）
    assert.same(3, writers)
  end)

  it('test_fish_price_is_floor_of_base_times_mult_and_defaults_to_one', function()
    local FishCatch = assert(loadfile('common/fish_catch.lua'))()
    assert.same(11, FishCatch.Price(env.cfg.Fish.bass, 1.99))   -- 6 × 1.99 = 11.94
    assert.same(9, FishCatch.Price(env.cfg.Fish.goldfish, 1.15)) -- 8 × 1.15 = 9.2
    assert.same(4, FishCatch.Price(env.cfg.Fish.tilapia, 1.5))   -- 3 × 1.5 = 4.5
    assert.same(4, FishCatch.Price(env.cfg.Fish.carp, 1.1))      -- 4 × 1.1 = 4.4，防浮点误差
    assert.same(4, FishCatch.Price(env.cfg.Fish.carp, nil))
  end)

  it('test_fish_without_mult_pays_base_price', function()
    local slot = give('goldfish', nil)
    env.data:SelectSlot(slot)
    assert.is_true(feed())
    assert.same(8, env.data.Data.FishCoin)
  end)

  it('test_last_worm_clears_bait_selection', function()
    env.data.Data.Bait.worm = 1
    env.data:SelectBait('worm')
    assert.is_true(feed())
    assert.same(0, env.data.Data.Bait.worm)
    assert.is_nil(env.data.Data.SelectedBait)
    assert.is_false(feed())
    assert.same(1, env.data.Data.FishCoin)
  end)

  it('test_missing_animation_does_not_block_settlement', function()
    env.anchor.PlayAnimation = nil
    env.data:SelectBait('worm')
    assert.is_true(feed())
    assert.same(1, env.data.Data.FishCoin)
    env.anchor.PlayAnimation = function() error('boom') end
    assert.is_true(feed())
    assert.same(2, env.data.Data.FishCoin)
  end)

  it('test_nothing_selected_is_refused_and_plain_items_are_recycled', function()
    -- 什么都不选（或选中格空）才是 'nothing'；选中鱼竿按物品表基础价回收（#127 取代 #44 的「不能卖竿」）
    assert.is_false(feed())             -- 什么都没选
    assert.same(0, env.data.Data.FishCoin)
    assert.same({}, env.plays)
    assert.same('nothing', env.replies[#env.replies].reason)

    env.data:SelectSlot(1)              -- 新手鱼竿（BasePrice = 3）
    assert.same(1, env.data.Data.SelectedSlot)
    assert.is_true(feed())
    assert.same(env.cfg.Items.SalePrice('starterRod'), env.data.Data.FishCoin)
    assert.is_nil(env.data.Data.Containers.itemBar[1])
    assert.same('starterRod', env.replies[#env.replies].itemId)
    assert.same('item', env.replies[#env.replies].category)
  end)

  it('test_replayed_or_stale_seq_settles_nothing', function()
    env.data:SelectBait('worm')
    assert.is_true(send(env.player, { target = 'fisherman', action = 'Feed', seq = 5 }))
    assert.is_true(send(env.player, { target = 'fisherman', action = 'Feed', seq = 5 }), '同操作重放返回原结果但不重复入账')
    assert.is_false(send(env.player, { target = 'fisherman', action = 'Feed', seq = 3 }))
    assert.is_false(send(env.player, { target = 'fisherman', action = 'Feed', seq = 5.5 }))
    assert.is_false(send(env.player, { target = 'fisherman', action = 'Feed' }))
    assert.same(1, env.data.Data.FishCoin)
    assert.is_true(send(env.player, { target = 'fisherman', action = 'Feed', seq = 6 }))
    assert.same(2, env.data.Data.FishCoin)
    -- 离线重进后序号重新从头算
    env.host:leave(env.player)
    env.data = env.host:rejoin(env.player)
    assert.is_true(send(env.player, { target = 'fisherman', action = 'Feed', seq = 1 }))
  end)

  it('test_selected_fish_wins_over_selected_bait', function()
    local slot = give('tilapia', 1.5)
    env.data:SelectSlot(slot)
    env.data:SelectBait('worm')
    local worms = env.data.Data.Bait.worm
    assert.is_true(feed())
    assert.same(4, env.data.Data.FishCoin)
    assert.same(worms, env.data.Data.Bait.worm)
  end)

  it('test_server_rechecks_distance_target_action_and_identity', function()
    env.data:SelectBait('worm')
    local r = env.cfg.Interact.Fisherman.Radius + env.cfg.Interact.Fisherman.Slack
    env.player.Character.Position = vec(env.anchor.Position.x + r + 0.1, 1, 0)
    assert.is_false(feed())
    env.player.Character.Position = vec(env.anchor.Position.x + r - 0.1, -50, 0)
    assert.is_false(feed({ target = 'shopkeeper' }))
    assert.is_false(feed({ action = 'Steal' }))
    assert.is_false(feed({ target = false }))
    assert.is_false(send(env.stranger, { target = 'fisherman', action = 'Feed', seq = 99 }))
    assert.is_false(send(env.player, 'Feed'))
    assert.same(0, env.data.Data.FishCoin)
    assert.is_true(feed())
    assert.same(1, env.data.Data.FishCoin)
  end)
end)
