-- 条款 17-17（docs/acceptance/17-tutorial-story-platform.md）：平台成就使用共享配置里的占位 ID
-- 走通完成与补交路径；真实成就 ID 由平台侧交付后只替换配置。
-- 只走业务入口：server/main.lua 的 MgrMap 注册的 MgrAchievements（通关成就的交付队列）＋ MgrPlayerData
-- （玩家数据实例）＋ MgrSave（持久操作协议），按 main.lua 的接线注入同一份协作关系。引擎边界
-- （ArchiveService 平台成就接口、Players、World 时钟）与存档写入用替身；**不执行 main.lua 本体**：它一开头
-- 就要完整引擎服务，所以照 MgrMap 的接线手工装配，再读 main.lua 源码核对那几条接线确实存在（见 WIRING）。
-- 只断言玩家可观察的结果：本地完成标记（界面据此显示「已完成」）、已送达标记（唯一代表「平台已授予」）
-- 与平台收到的成就 ID / 调用次数。
-- 失败方式（先列后写）：
--   0. main.lua 的接线被改掉（成就交付不再拿玩家数据或存档）：本文件先红；
--   1. 占位 ID 交付前什么都不试，或占位 ID 被当成真实 ID 写进「已送达」（占位宣称平台已授予）；
--   2. 真实 ID 到位后要改玩法代码才提交（不是「只替换配置」）；
--   3. 平台确认前就落已送达，或确认后再次提交（重复发奖）；
--   4. 占位期间向平台写入真实权益（用占位 ID 调提交却又不当占位处理）。
local GameCfg = require('common.GameCfg')

-- 前提守卫：本文件复现的是 main.lua 的接线，而不是自造一套协作关系。
local WIRING = {
    'MgrAchievements = require("server.Mgr.MgrAchievements"),',
    'MgrMap.MgrAchievements.PlayerData = MgrMap.MgrPlayerData',
    'MgrMap.MgrAchievements.Save = MgrMap.MgrSave',
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

describe('条款 17-17：平台成就占位 ID 与真实 ID 的交付口径', function()
    local env, saved

    before_each(function()
        assert_wiring()
        saved = {
            platformId = GameCfg.Achievements.final.PlatformId,
            placeholderId = GameCfg.Achievements.final.PlaceholderId,
            debug = GameCfg.Debug.Enabled,
        }
        env = { now = 0, queries = {}, submits = {}, completed = false }
        env.player = { UserId = 26301, SetAttribute = function() end }
        env.data = assert(loadfile('server/Data/PlayerData.lua'))().New(env.player, function() end)
        env.data:Init()
        -- 与 MgrMap 接线同形的三个管理器：成就交付读玩家数据、走存档持久操作协议。
        env.playerData = { GetDataInst = function(_, player) return player == env.player and env.data end }
        env.save = {
            NextOperation = function() return { id = '26301:1' } end,
            Execute = function(_, player, data, operation, transform, done)
                local accepted, result = transform(data)
                if not accepted then return false, 'rejected' end
                if done then done(true, result) end
                return true
            end,
        }
        env.mgr = assert(loadfile('server/Mgr/MgrAchievements.lua'))()
        env.mgr.PlayerData, env.mgr.Save = env.playerData, env.save
        env.mgr.Players = { GetPlayers = function() return { env.player } end }
        env.mgr.World = { GetServerTime = function() return env.now end }
        -- 平台成就服务替身：记录收到的成就 ID 与调用序，答案由 completed 控制。
        env.mgr.Archive = {
            IsAchievementCompleted = function(_, player, id)
                assert.same(env.player, player)
                env.queries[#env.queries + 1] = id
                return env.completed
            end,
            SetAchievementProgress = function(_, player, id, count)
                assert.same(env.player, player)
                assert.same(1, count)
                env.submits[#env.submits + 1] = id
            end,
        }
    end)

    after_each(function()
        GameCfg.Achievements.final.PlatformId = saved.platformId
        GameCfg.Achievements.final.PlaceholderId = saved.placeholderId
        GameCfg.Debug.Enabled = saved.debug
        env = nil
    end)

    local function advance(window)
        env.now = env.now + (window or (GameCfg.AchievementDelivery.RetrySec + 1))
        env.mgr:Update()
    end

    it('占位 ID 与真实 ID 都写在共享配置里，交付前用占位 ID', function()
        assert.is_nil(GameCfg.Achievements.final.PlatformId, '平台侧未交付时真实 ID 留空')
        local placeholder = GameCfg.Achievements.final.PlaceholderId
        assert.same('number', type(placeholder), '占位成就 ID 必须落在共享配置里')
        assert.is_true(placeholder > 0 and placeholder == math.floor(placeholder))
    end)

    it('生产构建不向平台写占位 ID：本地完成标记留着，等真实 ID 交付', function()
        GameCfg.Debug.Enabled = false
        env.data.Extra.achievements.final = true
        env.mgr:Update()
        advance()
        assert.same(0, #env.queries + #env.submits, '生产构建不得拿占位 ID 去问或去写平台')
        assert.is_true(env.data.Extra.achievements.final, '完成标记不许丢')
        assert.is_nil(env.data.Extra.achievementDelivered and env.data.Extra.achievementDelivered.final)
    end)

    it('调试构建里占位 ID 走通「完成 → 查询 → 提交」补交路径，但不宣称平台已授予', function()
        GameCfg.Debug.Enabled = true
        local placeholder = GameCfg.Achievements.final.PlaceholderId
        env.data.Extra.achievements.final = true
        env.mgr:Update()
        assert.same({ placeholder }, env.queries, '占位 ID 要走到平台查询这一步')
        assert.same({ placeholder }, env.submits, '平台说没完成时要真的提交一次')
        -- 平台对占位 ID 的回答不代表本成就已授予：不许落「已送达」。
        env.completed = true
        advance()
        assert.same({ placeholder, placeholder }, env.queries, '下一个窗口继续补交')
        assert.is_nil(env.data.Extra.achievementDelivered and env.data.Extra.achievementDelivered.final,
            '占位 ID 说已完成也不算本成就已授予')
        assert.is_true(env.data.Extra.achievements.final, '完成标记不许丢')
    end)

    it('真实 ID 交付后只替换配置：同一路径提交一次，平台确认后才落已送达', function()
        GameCfg.Debug.Enabled = false
        local real = 3801
        GameCfg.Achievements.final.PlatformId = real
        env.data.Extra.achievements.final = true
        env.mgr:Update()
        assert.same({ real }, env.queries, '提交用的是配置里的真实 ID，不是占位 ID')
        assert.same({ real }, env.submits)
        assert.is_nil(env.data.Extra.achievementDelivered and env.data.Extra.achievementDelivered.final,
            '平台确认前不算已授予')
        env.completed = true
        advance()
        assert.is_true((env.data.Extra.achievementDelivered or {}).final, '平台确认后落已送达')
        assert.same({ real }, env.submits, '确认之后不再提交，不重复发奖')
        advance()
        assert.same({ real }, env.submits, '之后的窗口也不重复提交')
        assert.same(2, #env.queries, '已送达之后不再查询平台')
    end)
end)
