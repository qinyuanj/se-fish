-- 条款 17-18（docs/acceptance/17-tutorial-story-platform.md）：分享任务在平台能力未开放时走明确占位路径，
-- 不出现点了没反应的入口；平台开放情况作为生产开关。
-- 只走业务入口：server/main.lua 的 MgrMap 注册的 MgrPlatform（平台能力的唯一服务端入口），按 main.lua 的
-- 接线注入 MgrPlayerData 与 MgrSave；引擎边界（CommodityService / AdvertisementService / World 时钟 / RE 通道）
-- 全部替身。**不执行 main.lua 本体**：它一开头就要完整引擎服务，所以照 MgrMap 的接线手工装配，再读 main.lua
-- 源码核对那几条接线确实存在（见 WIRING）。
-- 只断言玩家可观察的结果：Share 回包（客户端据此显示占位文案）与玩家数据快照（金币、库存件数）。
-- 失败方式（先列后写）：
--   0. main.lua 的接线被改掉（平台入口不再拿玩家数据/存档）：本文件先红；
--   1. 分享能力未开放时入口静默吞掉请求（点了没反应）；
--   2. 回包不带可读文案，玩家不知道发生了什么；
--   3. 占位路径顺手发放了真实权益（商品件数或金币变化）。
local GameCfg = require('common.GameCfg')

local WIRING = {
    'MgrPlatform = require("server.Mgr.MgrPlatform"),',
    'MgrMap.MgrPlatform.Save = MgrMap.MgrSave',
    'MgrMap.MgrPlatform.PlayerData = MgrMap.MgrPlayerData',
}

local function assert_wiring()
    local handle = assert(io.open('server/main.lua', 'rb'), '读不到 server/main.lua')
    local source = handle:read('a')
    handle:close()
    for _, line in ipairs(WIRING) do
        assert.is_truthy(source:find(line, 1, true),
            'server/main.lua 里找不到本文件复现的接线：' .. line)
    end
end

local function channels()
    local posts, registry = {}, {}
    local function channel(name)
        if not registry[name] then
            registry[name] = {
                FireClient = function(_, _, payload)
                    posts[name] = posts[name] or {}
                    table.insert(posts[name], payload)
                end,
                FireServer = function() end,
                OnServerEvent = { Connect = function() end },
            }
        end
        return registry[name]
    end
    return { posts = posts, GetRE = function(_, name) return channel(name) end }
end

describe('条款 17-18：分享任务的占位入口', function()
    local env, saved

    before_each(function()
        assert_wiring()
        saved = { re = rawget(_G, 'REUtil'), debug = GameCfg.Debug.Enabled }
        env = { now = 0, posts = nil }
        env.re = channels()
        _G.REUtil = { GetRE = env.re.GetRE, CheckRECD = function() return false end }
        env.player = { UserId = 26303, SetAttribute = function() end }
        env.data = assert(loadfile('server/Data/PlayerData.lua'))().New(env.player, function() end)
        env.data:Init()
        env.platform = assert(loadfile('server/Mgr/MgrPlatform.lua'))()
        env.platform.PlayerData = { GetDataInst = function(_, player) return player == env.player and env.data end,
            SendItemBar = function() end }
        env.platform.Save = { NextOperation = function() return { id = '26303:1' } end,
            Execute = function(_, player, data, operation, transform, done)
                local accepted, result = transform(data)
                if not accepted then return false, 'rejected' end
                if done then done(true, result) end
                return true
            end }
        env.platform.World = { GetServerTime = function() return env.now end }
    end)

    after_each(function()
        _G.REUtil = saved.re
        GameCfg.Debug.Enabled = saved.debug
        env = nil
    end)

    -- 平台回包统一走 PlatformResult 通道（客户端据此显示提示），按 action 分辨是哪件事。
    local function lastReply()
        local list = env.re.posts.PlatformResult or {}
        return list[#list]
    end

    it('平台分享能力未开通时回明确占位，不点了没反应', function()
        -- 开放情况是生产开关（共享配置）：默认未开通。
        assert.is_false(GameCfg.Platform.Share.Enabled)
        local coin = env.data.Data.FishCoin
        local itemId = GameCfg.Survival.AdrenalineItemId
        local before = env.data:ItemCount(itemId)
        assert.is_false(env.platform:Share(env.player, 'tutorial'))
        local reply = lastReply()
        assert.is_table(reply, '分享入口必须有回包，不能静默吞掉')
        assert.is_false(reply.ok)
        assert.same('Share', reply.action)
        assert.same('placeholder', reply.reason, '未开放要走明确占位原因')
        assert.same(GameCfg.Platform.Share.UnavailableText, reply.text)
        assert.is_true(#reply.text > 0, '占位也要有玩家可读文案')
        -- 占位不发真实权益：金币与商品件数都不动。
        assert.same(coin, env.data.Data.FishCoin)
        assert.same(before, env.data:ItemCount(itemId))
    end)

    it('经平台操作通道进来的分享请求同样有明确回包', function()
        local handled = env.platform:HandleAction(env.player, { action = 'Share', purpose = 'tutorial' })
        assert.is_true(handled, '分享请求要被受理，不许丢掉')
        local reply = lastReply()
        assert.is_table(reply)
        assert.same('placeholder', reply.reason)
        assert.same('tutorial', reply.purpose)
    end)
end)
