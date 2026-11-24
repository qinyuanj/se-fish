-- #86 迁移（原 tests/gameplay/grill_test.lua，#137 T16 烧烤）：
-- 服务端曲线计时、取出结算、烤糊伤害与会话恢复
-- 数值来源：策划案--渔力全开.docx 烧烤段与 issue #137 验收（0/2/2.5/4.5 秒边界、
-- 烤糊 3 米 30 伤害、信物烤前提示、按玩家独立会话、关闭/死亡/断线/满格不复制不吞物）。
-- 失败方式（先列后写）：
--   1. 曲线：0/2/2.5/4.5 秒边界倍率错；按帧累加导致快慢帧收益不同（必须按服务器时刻一次算）；
--   2. 烤糊：4.5 秒不到就糊 / 到了不糊；糊两次（重复损毁、重复爆炸）；爆炸漏掉 3 米内或误伤
--      3 米外；伤害绕过 MgrVitals 统一入口（NewHit/ApplyHit）；
--   3. 会话：两玩家互相取到对方烤鱼；无会话能取出物品；取出后还能再取（复制）；烤糊后还能取；
--   4. 结算：关闭/死亡/断线时物品丢失或复制；满格取出吞掉可取回物；重进后倍率丢失；
--   5. 资格：烤过的鱼还能再烤；烤过信物还能兑换/抽奖（#138 守卫）；信物未经提示直接开烤；
--   6. 价格/恢复：烤过的鱼不按当时倍率出价；吃不按倍率恢复；倍率 <1 的存档被 Migrate 拒收。
-- 说明：describe 按旧 LuaUnit 的执行顺序登记（类名字节序、其内方法字节序），保持案例顺序一致。
-- 随机数：烤糊倍率与伤害由服务器时刻（假 World.GetServerTime）一次算出，烤位取场景锚点而非随机点位；
-- fencing 命名空间），不参与任何断言，因此无需固定或恢复随机数函数。
local GameCfg = require('common.game_cfg')
local Curve = require('common.grill_curve')
local PlayerData = require('server.data.player_data')
local LotteryEligibility = require('common.lottery_eligibility')
local ShopFeedHost = require('tests.support.shop_feed_host')

local function signal()
    local handlers = {}
    return {
        Connect = function(_, fn)
            handlers[#handlers + 1] = fn
            return { Disconnect = function() for i, cb in ipairs(handlers) do
                if cb == fn then handlers[i] = nil end
            end end }
        end,
        Fire = function(_, ...) for _, cb in ipairs(handlers) do cb(...) end end,
    }
end

local function rate(elapsed)
    return Curve.Rate(elapsed, GameCfg.Grill)
end

local function vec(x, y, z) return { x = x, y = y, z = z } end

-- 配置值与场景锚点（切片一）
describe("烧烤配置对齐策划案", function()
    -- 配置值对齐策划案/docx 与 issue #137 验收
    it("test_anchors_cover_zones_three_to_seven", function()
        for index, zone in ipairs(GameCfg.Zones) do
            if index >= 3 then
                assert.is_not_nil(zone.Scene.GrillName)
            else
                assert.is_nil(zone.Scene.GrillName)
            end
        end
    end)

    it("test_values_match_design_doc", function()
        local cfg = GameCfg.Grill
        assert.is_not_nil(cfg)
        assert.same(2, cfg.Radius)          -- docx：2 米内出现「烧烤」操作
        assert.same(2, cfg.RiseSec)         -- 0-2 秒：1 → 1.5
        assert.same(0.5, cfg.HoldSec)       -- 2-2.5 秒：保持 1.5
        assert.same(2, cfg.FallSec)         -- 2.5-4.5 秒：1.5 → 0
        assert.same(1.5, cfg.MaxRate)       -- 烤熟 1.5 倍
        assert.same(4.5, cfg.BurnSec)       -- 4.5 秒烤糊
        assert.same(cfg.RiseSec + cfg.HoldSec + cfg.FallSec, cfg.BurnSec)
        assert.same(30, cfg.BurnDamage)     -- docx：烤糊爆炸 30 伤害
        assert.same(3, cfg.BurnRadius)      -- docx：周围 3 米
        assert.same('你没有可烤的鱼', cfg.NoFishText)
        assert.same('你的鱼烤糊了！', cfg.BurntText)
        assert.same('烤', cfg.CookedPrefix)  -- GLOSSARY.md 烤鱼条 Avoid「烤过的鱼」，前缀用「烤」
        assert.is_not_nil(cfg.TokenWarnText)
    end)
end)

-- 切片二：烤制倍率表示统一（取出倍率可以是 (0, 1.5] 的任意值）
describe("烤制倍率的来源", function()
    -- CookRate 统一读取三种来源：顶层数值（内存格位/快照）、saved.k（读档还原）、
    -- 旧布尔 saved.cooked（#127 之前的手工标记，等价烤熟价倍率）；非法值一律 nil
    it("test_sources", function()
        assert.same(0.75, GameCfg.Items.CookRate({ cooked = 0.75 }))
        assert.same(1.2, GameCfg.Items.CookRate({ saved = { k = 1.2 } }))
        assert.same(GameCfg.Items.CookedPriceScale, GameCfg.Items.CookRate({ saved = { cooked = true } }))
        assert.is_nil(GameCfg.Items.CookRate({}))
        assert.is_nil(GameCfg.Items.CookRate({ cooked = 0 }))
        assert.is_nil(GameCfg.Items.CookRate({ cooked = -1 }))
        assert.is_nil(GameCfg.Items.CookRate({ cooked = 'x' }))
        assert.is_nil(GameCfg.Items.CookRate(nil))
    end)
end)

describe("烤制值的存档字段", function()
    local ctx

    before_each(function()
        ctx = {}
        ctx.oldDebug = GameCfg.Debug
        GameCfg.Debug = { Enabled = false }
        ctx.player = { UserId = 73001, SetAttribute = function() end }
        ctx.data = PlayerData.New(ctx.player)
        ctx.data:Init()
    end)

    after_each(function()
        GameCfg.Debug = ctx.oldDebug
    end)

    -- PlayerData 存档字段接缝：曲线下降段取出的倍率 <1，序列化往返不丢、不被 Migrate 拒收
    it("test_sub_one_rate_survives_save_roundtrip", function()
        assert.is_true(ctx.data:AddItem('bass', 1.5, 0.75))
        local snapshot = ctx.data:Serialize()
        local restored = PlayerData.New(ctx.player)
        restored:Init()
        assert.is_true(restored:ApplySave(snapshot))
        local entry = restored.Data.Containers[GameCfg.Items.ContainerId.ItemBar][1]
        assert.same(0.75, entry.cooked)
        assert.same(0.75, entry.saved.k)
    end)

    -- 倍率 0（烤糊）与负数永远是坏档：烤糊物品根本不进入库存
    it("test_zero_or_negative_rate_is_rejected", function()
        assert.is_true(ctx.data:AddItem('bass', 1.5, 0.75))
        local snapshot = ctx.data:Serialize()
        snapshot.bar[1].k = 0
        assert.is_false(ctx.data:ApplySave(snapshot))
        local snapshot2 = ctx.data:Serialize()
        snapshot2.bar[1].k = -0.5
        assert.is_false(ctx.data:ApplySave(snapshot2))
    end)
end)

describe("烧烤曲线纯函数", function()
    -- 验收边界：0 / 2 / 2.5 秒取出倍率；4.5 秒起为烤糊（物品损毁，不再给倍率）
    it("test_boundary_rates", function()
        assert.same(1, rate(0))
        assert.same(1.5, rate(2))
        assert.same(1.5, rate(2.5))
        assert.is_true(Curve.IsBurnt(4.5, GameCfg.Grill))
        assert.is_false(Curve.IsBurnt(4.49, GameCfg.Grill))
    end)

    -- 界面两位小数（策划案：界面显示烧烤时间/倍率两位小数）
    it("test_format_two_decimals", function()
        assert.same('1.00', Curve.Format(1))
        assert.same('1.50', Curve.Format(1.5))
        assert.same('1.25', Curve.Format(rate(1)))
    end)

    -- 非法输入：负数按 0 秒（刚投入），非数字不给倍率
    it("test_invalid_elapsed", function()
        assert.same(1, rate(-3))
        assert.is_nil(rate('1'))
        assert.is_nil(rate(nil))
    end)

    -- 快慢帧不改变收益：倍率只由「投入时刻到取出时刻」的服务器时长一次算出，与调用次数无关
    it("test_rate_depends_only_on_elapsed", function()
        assert.same(rate(1), rate(1))                        -- 重复查询结果稳定
        assert.near(rate(1), rate(0.5 + 0.5), 1e-9)          -- 一次算 1 秒 = 直接查 1 秒
        assert.near(0.5 * 0.1 / 2, rate(0.1) - 1, 1e-9)      -- 按整段时长插值，不按步长累加
    end)

    -- 线段中点：上升段线性 1→1.5，下降段线性 1.5→0
    it("test_segment_midpoints", function()
        assert.near(1.25, rate(1), 1e-9)     -- 0-2 秒中点
        assert.near(1.5, rate(2.2), 1e-9)    -- 保持段
        assert.near(0.75, rate(3.5), 1e-9)   -- 2.5-4.5 秒中点
    end)
end)

-- 切片四：吃通道接缝（Operate 两步吃烤鱼时把格位倍率带给 Vitals）
describe("吃通道传递烤制倍率", function()
    local ctx

    before_each(function()
        ctx = { events = {}, eaten = {} }
        ctx.oldRE = _G.REUtil
        ctx.oldDebug = GameCfg.Debug
        GameCfg.Debug = { Enabled = false }
        _G.REUtil = { CheckRECD = function() return false end, GetRE = function(_, name)
            if not ctx.events[name] then
                ctx.events[name] = { OnServerEvent = signal(),
                    FireClient = function(_, player, payload) player.lastResult = payload end }
            end
            return ctx.events[name]
        end }
        ctx.player = { UserId = 9102, Character = { Name = 'Eggy' },
            CharacterAdded = signal(), CharacterRemoving = signal(), SetAttribute = function() end }
        ctx.mgr = assert(loadfile('server/player_data_host.lua'))()
        ctx.mgr.Vitals = { CanEat = function() return true end,
            Eat = function(_, player, itemId, rate)
                ctx.eaten[#ctx.eaten + 1] = { itemId = itemId, rate = rate }
                return true
            end }
        ctx.mgr:Start()
        ctx.mgr:OnPlayerAdded(ctx.player)
        ctx.data = ctx.mgr:GetDataInst(ctx.player)
    end)

    -- 管理器实例、全局与配置逐例恢复；setUp 中途失败也照样清理。
    after_each(function()
        if ctx.mgr then
            if ctx.player then ctx.mgr:OnPlayerRemoving(ctx.player) end
            ctx.mgr.Vitals = nil
        end
        _G.REUtil = ctx.oldRE
        GameCfg.Debug = ctx.oldDebug
    end)

    local function operate(payload)
        ctx.events.ItemBarAction.OnServerEvent:Fire(ctx.player, payload)
        return ctx.player.lastResult
    end

    -- #137 审查修复：吃通道走 CookRate 统一口径，#127 之前的旧布尔档 saved.cooked==true 按烤熟价倍率恢复
    it("test_operate_eat_legacy_boolean_archive_passes_scale", function()
        assert.is_true(ctx.data:AddItem('carp', 1.5))
        local entry = ctx.data.Data.Containers[GameCfg.Items.ContainerId.ItemBar][1]
        entry.saved = { [GameCfg.Items.CookedFlag] = true }
        operate({ action = 'Operate', op = 'eat', slot = 1 })
        operate({ action = 'Operate', op = 'eat', slot = 1 })
        assert.same(1, #ctx.eaten)
        assert.same(GameCfg.Items.CookedPriceScale, ctx.eaten[1].rate, '旧布尔档按烤熟价倍率恢复')
    end)

    it("test_operate_eat_passes_cook_rate", function()
        assert.is_true(ctx.data:AddItem('carp', 1.5, 1.5))
        operate({ action = 'Operate', op = 'eat', slot = 1 })
        local second = operate({ action = 'Operate', op = 'eat', slot = 1 })
        assert.same(true, second.ok)
        assert.same(1, #ctx.eaten)
        assert.same('carp', ctx.eaten[1].itemId)
        assert.same(1.5, ctx.eaten[1].rate, '烤鱼按倍率恢复')
    end)

    it("test_operate_eat_plain_fish_passes_no_rate", function()
        assert.is_true(ctx.data:AddItem('carp', 1.5))
        operate({ action = 'Operate', op = 'eat', slot = 1 })
        operate({ action = 'Operate', op = 'eat', slot = 1 })
        assert.same(1, #ctx.eaten)
        assert.is_nil(ctx.eaten[1].rate)
    end)
end)

describe("吃烤鱼的恢复量", function()
    local ctx

    before_each(function()
        ctx = {}
        ctx.oldGame = _G.game
        ctx.now = 500
        _G.game = { GetService = function(_, name)
            if name == 'World' then return { GetServerTime = function() return ctx.now end } end
        end }
        local Host = require('tests.support.life_host')
        ctx.host = Host.start({ now = 500 })
        ctx.vitals = ctx.host.runtime.life
        ctx.player = Host.player(9101)
        ctx.player.Character.Controller.Health = 100
        ctx.controller = ctx.player.Character.Controller
        ctx.host:add(ctx.player)
        ctx.vitals:SetHunger(ctx.player, 0)
    end)

    -- 玩家与引擎全局逐例恢复；setUp 中途失败也照样清理。
    after_each(function()
        if ctx.host then ctx.host:shutdown() end
        _G.game = ctx.oldGame
    end)

    -- 恢复量同倍率（验收：价格、恢复量同乘当时倍率）：电鳗头 EatPercent=50，
    -- 烤熟 1.5 倍 → 恢复 75%（225 饥饿）；未烤 → 50%（150）；下降段 0.5 倍 → 25%（75）
    it("test_eat_restores_scaled_by_cook_rate", function()
        assert.is_true(ctx.vitals:Eat(ctx.player, 'eelHead', 1.5))
        assert.same(225, ctx.host:tree(ctx.player).states.hunger:now())
        assert.same(300, ctx.controller.Health, '100 + 225 封顶 300')

        local tree = ctx.host:tree(ctx.player)
        ctx.vitals:SetHunger(ctx.player, 0)
        ctx.controller.Health = 100
        assert.is_true(ctx.vitals:Eat(ctx.player, 'eelHead'))
        assert.same(150, tree.states.hunger:now(), '未烤按原恢复量')
        assert.same(250, ctx.controller.Health)

        ctx.vitals:SetHunger(ctx.player, 0)
        ctx.controller.Health = 100
        assert.is_true(ctx.vitals:Eat(ctx.player, 'eelHead', 0.5))
        assert.same(75, tree.states.hunger:now(), '下降段取出恢复量打折')
        assert.same(175, ctx.controller.Health)
    end)

    -- 非法倍率按未烤处理，不能吃时（死亡）照旧拒绝
    it("test_eat_with_bad_rate_falls_back_to_plain", function()
        assert.is_true(ctx.vitals:Eat(ctx.player, 'eelHead', -1))
        assert.same(150, ctx.host:tree(ctx.player).states.hunger:now())
    end)
end)

describe("回收烤鱼的金币结算", function()
    local ctx

    before_each(function()
        ctx = { seq = 0 }
        ctx.cfg = GameCfg
        ctx.host = ShopFeedHost.start()
        ctx.player, ctx.data = ctx.host:join(1, GameCfg.Interact.Fishermen[1].AnchorNames[1])
        ctx.replies = ctx.host.results[1].InteractResult
    end)

    -- 配置模块缓存与全局逐例恢复；setUp 中途失败也照样清理。
    after_each(function()
        ctx.host:shutdown()
    end)

    local function feed()
        ctx.seq = ctx.seq + 1
        local reply = ctx.host:send(ctx.player, 'InteractAction', { target = 'fisherman', action = 'Feed', seq = ctx.seq })
        return reply and reply.ok or false
    end

    local function lastReply()
        return ctx.replies[#ctx.replies]
    end

    -- 数值烤制倍率的鱼获按当时倍率结金币（不再只看布尔标记）
    it("test_numeric_cooked_fish_sells_at_rate", function()
        assert.is_true(ctx.data:AddItem('bass', 2, 0.75))
        assert.is_true(ctx.data:SelectSlot(1))
        assert.is_true(feed())
        assert.same(9, ctx.data.Data.FishCoin) -- floor(6 × 2 × 0.75)
    end)

    -- 数值标记的烤过信物不能走兑换链，只按倍率售卖
    it("test_numeric_cooked_token_never_exchanges", function()
        assert.is_true(ctx.data:AddItem('eelHead', nil, 1.2))
        assert.is_true(ctx.data:SelectSlot(1))
        assert.is_true(feed())
        assert.same(0, ctx.data:ItemCount('eelHead'))
        assert.same(0, ctx.data:ItemCount('duck'), '烤过的精英信物不能再换首领饵')
        assert.same(12, ctx.data.Data.FishCoin) -- floor(10 × 1 × 1.2)
        assert.is_nil(lastReply().exchange)
    end)
end)

describe("烤过物品的抽奖资格", function()
    -- #138 抽奖机守卫（本单先留接口）：烤过信物/极品鱼获哪怕倍率 <1 也算烤过，拒绝投入
    it("test_cooked_rate_below_one_is_still_cooked", function()
        local ok, reason = LotteryEligibility.Check({ itemId = 'item47', count = 1, mult = 1.2, cooked = 0.75 })
        assert.is_false(ok)
        assert.same('cooked', reason)
    end)

    it("test_uncooked_premium_still_eligible", function()
        assert.is_true(LotteryEligibility.Check({ itemId = 'item47', count = 1, mult = 1.2 }))
    end)
end)

describe("烤鱼的售价", function()
    -- 旧布尔标记仍是烤熟价 ×1.5
    it("test_legacy_boolean_keeps_cooked_scale", function()
        assert.same(30, GameCfg.Items.SalePrice('garHead', nil, true))  -- floor(20 × 1 × 1.5)
        assert.same(18, GameCfg.Items.SalePrice('bass', 2, true))
        assert.same(12, GameCfg.Items.SalePrice('bass', 2))             -- 未烤原价
    end)

    -- 取出倍率直接定价：价格 = 基础价 × 个体倍率 × 烤制倍率（#137）
    it("test_numeric_rate_prices", function()
        assert.same(25, GameCfg.Items.SalePrice('garHead', nil, 1.25))  -- floor(20 × 1 × 1.25)
        assert.same(10, GameCfg.Items.SalePrice('garHead', nil, 0.5))   -- 下降段取出也值钱
        assert.same(9, GameCfg.Items.SalePrice('bass', 2, 0.75))        -- floor(6 × 2 × 0.75)
        assert.same(18, GameCfg.Items.SalePrice('bass', 2, 1.5))        -- floor(6 × 2 × 1.5)
    end)
end)

-- 切片五接线断言：双端入口与 ScreenMain 前缀渲染
describe("烧烤的接线", function()
    it("test_client_main_starts_screen_grill", function()
        local file = assert(io.open('client/main.lua', 'r'))
        local src = file:read('*a')
        file:close()
        assert.matches('local GrillView = require("client.views.grill_view")', src, nil, true)
        assert.matches('GrillView.spec()', src, nil, true)
        assert.is_nil(src:find('ScreenGrill', 1, true), '旧烧烤屏幕不得再由客户端入口拉起')
        local file2 = assert(io.open('client/views/main_hud_item_bar_view.lua', 'r'))
        local src2 = file2:read('*a')
        file2:close()
        assert.matches('GameCfg.Grill.CookedPrefix', src2, nil, true)
    end)

    it("test_server_main_wires_grill", function()
        local file = assert(io.open('server/main.lua', 'r'))
        local src = file:read('*a')
        file:close()
        assert.matches('bind_grill_action', src, nil, true)
        assert.matches('GrillAction', src, nil, true)
        assert.is_nil(src:find('MgrGrill', 1, true), '旧烧烤管理器不得再挂进服务端入口')
        assert.is_nil(src:find('MgrMap.MgrGrill.Loot'), '满格走 ready 冻结重试，不接 MgrLoot')
        local runtime = assert(io.open('server/world_host/server_runtime.lua', 'r'))
        local runtime_src = runtime:read('*a')
        runtime:close()
        assert.matches('PlayerGrill.mount', runtime_src, nil, true)
        assert.is_not_nil(runtime_src:find('mount_phase("alive", "grill"', 1, true),
            '烧烤会话必须挂在存活相位，离场随相位结算')
    end)
end)
