-- #86 迁移（原 tests/gameplay/feed_exchange_test.lua，#87 信物兑换，GameSpec §8.1 已确认）：
-- 选中格是信物（电鳗头 / 鳄雀鳝鱼头）时喂钓鱼佬走 1:1 兑换，
-- 电鳗头 → 首领饵「鸭子」、鳄雀鳝鱼头 → 虾池船票，不给金币；背包与道具栏全满时拒绝、提示且不消耗信物。
-- #127 起：兑换按**交付后的容量**校验——先扣掉选中的信物（释放这一格）再发产物，
-- 所以道具栏 + 背包全满时仍能成交，产物落进刚释放的那一格；「使用本次交付释放的格位」是合法的。
-- 失败方式（先列后写）：
--   1. 选中信物却走了金币分支（按 BasePrice 入账），或穿过选中格掉进鱼饵分支扣了蚯蚓；
--   2. 产物发错：电鳗头没换鸭子、鳄雀鳝鱼头没换船票、数量不是 1、产物没进道具栏 / 背包；
--   3. 容量判定错：满格时拒绝兑换、产物没落进释放出的格，或尚有空位却被拒绝；
--   4. 扣除与发放不同步：信物扣了产物没发，或发了产物信物还在；金币被兑换改动；
--   5. 拒绝时缺提示（reason 不是 'full'），或成功回包缺兑换双方，客户端无法给兑换提示；
--   6. 兑换成功不播吃动作、不推送库存；未选中的信物被误当兑换物。
local GameCfg = require('common.game_cfg')
local Host = require('tests.support.shop_feed_host')

describe("喂钓鱼佬的信物兑换", function()
    local ctx

    -- 与旧 LuaUnit 的每例 setUp/tearDown 同级成对。
    before_each(function()
        ctx = { seq = 0 }
        ctx.cfg = GameCfg
        ctx.host = Host.start()
        ctx.player, ctx.data = ctx.host:join(1, GameCfg.Interact.Fishermen[1].AnchorNames[1])
        ctx.replies = ctx.host.results[1].InteractResult
        ctx.anchor = ctx.host.anchors[GameCfg.Interact.Fishermen[1].AnchorNames[1]]
        ctx.anchor.plays = {}
        ctx.plays = ctx.anchor.plays
    end)

    -- 配置模块缓存与全局逐例恢复；setUp 中途失败也照样清理。
    after_each(function()
        ctx.host:shutdown()
    end)

    local function feed()
        ctx.seq = ctx.seq + 1
        local reply = ctx.host:act(ctx.player, 'InteractAction', { target = 'fisherman', action = 'Feed', seq = ctx.seq })
        return reply and reply.ok or false
    end

    -- 放入物品并返回它实际落在的容器与下标。
    local function give(itemId)
        assert.is_true(ctx.data:AddItem(itemId))
        local bar = ctx.data.Data.Containers.itemBar
        for index = 1, ctx.data:ItemBarCapacity() do
            if bar[index] and bar[index].itemId == itemId then return index, 'itemBar' end
        end
        local backpack = ctx.data.Data.Containers.backpack
        for index = 1, ctx.data:BackpackCapacity() do
            if backpack[index] and backpack[index].itemId == itemId then return index, 'backpack' end
        end
    end

    local function countItem(itemId)
        local total = 0
        for _, container in pairs(ctx.data.Data.Containers) do
            for _, entry in pairs(container) do
                if entry.itemId == itemId then total = total + entry.count end
            end
        end
        return total
    end

    -- 把道具栏与背包除 keepSlot 外全部填满（用无兑换关系的普通鱼获）
    local function fillExcept(keepSlot)
        local bar = ctx.data.Data.Containers.itemBar
        for index = 1, ctx.data:ItemBarCapacity() do
            if index ~= keepSlot and (not bar[index] or bar[index].count <= 0) then
                assert.is_true(ctx.data:AddItem('tilapia'))
            end
        end
        while ctx.data:AddItem('tilapia') do end
    end

    it("test_eel_head_exchanges_for_one_duck_without_coins", function()
        local slot = give('eelHead')
        assert.is_true(ctx.data:SelectSlot(slot))
        assert.is_true(feed())
        assert.same(0, countItem('eelHead'))
        assert.same(1, countItem('duck'))
        assert.same(0, ctx.data.Data.FishCoin)
        assert.same(0, ctx.player.attrs.FishCoin)
        assert.is_nil(ctx.data.Data.SelectedSlot)
        assert.same(1, ctx.host.sync_counts[1])
        assert.same({ ctx.cfg.Interact.Fisherman.EatAnimation }, ctx.plays)
        local reply = ctx.replies[#ctx.replies]
        assert.is_true(reply.ok)
        assert.is_nil(reply.coins)
        assert.same({ from = 'eelHead', to = 'duck' }, reply.exchange)
    end)

    -- #127 容量口径：先交付选中格、再校验交付后的容量，满格也能用释放出的格位成交
    it("test_full_storage_exchanges_using_the_released_slot", function()
        local slot = give('eelHead')
        fillExcept(slot)
        assert.is_true(ctx.data:SelectSlot(slot))
        assert.is_true(feed())
        assert.same(0, countItem('eelHead'))
        assert.same(1, countItem('duck'))
        assert.same(0, ctx.data.Data.FishCoin)
        assert.same({ ctx.cfg.Interact.Fisherman.EatAnimation }, ctx.plays)
        local bar = ctx.data.Data.Containers.itemBar
        assert.same('duck', bar[slot] and bar[slot].itemId, '产物落进本次交付释放出的格')
        assert.same({ from = 'eelHead', to = 'duck' }, ctx.replies[#ctx.replies].exchange)
    end)

    it("test_gar_head_exchanges_for_one_shrimp_ticket", function()
        local slot = give('garHead')
        assert.is_true(ctx.data:SelectSlot(slot))
        assert.is_true(feed())
        assert.same(0, countItem('garHead'))
        assert.same(1, countItem('shrimpTicket'))
        assert.same(0, ctx.data.Data.FishCoin)
        assert.same({ from = 'garHead', to = 'shrimpTicket' }, ctx.replies[#ctx.replies].exchange)
    end)

    -- 信物扣掉后它自己的格就是第一个空格，产物落在那里（与 AddItem「优先填道具栏」一致）
    it("test_product_lands_in_first_free_slot", function()
        local slot = give('eelHead')
        assert.is_true(ctx.data:AddItem('tilapia')) -- 道具栏第二格占满
        assert.is_true(ctx.data:SelectSlot(slot))
        assert.is_true(feed())
        local bar = ctx.data.Data.Containers.itemBar
        assert.is_not_nil(bar[slot])
        assert.same('duck', bar[slot].itemId)
        assert.same(1, bar[slot].count)
        assert.same(0, countItem('eelHead'))
    end)

    it("test_selected_token_wins_over_selected_bait", function()
        ctx.data.Data.Bait.worm = 5
        local slot = give('eelHead')
        assert.is_true(ctx.data:SelectSlot(slot))
        assert.is_true(ctx.data:SelectBait('worm'))
        assert.is_true(feed())
        assert.same(1, countItem('duck'))
        assert.same(5, ctx.data.Data.Bait.worm)
        assert.same(0, ctx.data.Data.FishCoin)
    end)

    it("test_unselected_token_does_not_block_normal_coin_feed", function()
        give('eelHead')
        local fishSlot = give('carp')
        assert.is_true(ctx.data:SelectSlot(fishSlot))
        assert.is_true(feed())
        assert.same(ctx.cfg.Fish.carp.BasePrice, ctx.data.Data.FishCoin)
        assert.same(1, countItem('eelHead'))
        assert.same(0, countItem('duck'))
    end)
end)
