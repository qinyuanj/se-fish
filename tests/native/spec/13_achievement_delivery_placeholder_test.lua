-- 条款 13-12、13-13、13-14、13-18（docs/acceptance/13-compendium-achievements.md）：
--   13-12 平台成就后台 ID 交付前，本地先保存通关完成标记，重进后继续补交；
--   13-13 重复交付同一成就不得重复授予，已送达标记落账后不再提交；
--   13-14 平台查询与提交失败时保留补交，不把失败当成已授予；
--   13-18 平台成就 ID 未交付时保留本地完成标记并支持重复补交；真实平台授予作为生产开关单列。
-- 只走业务入口：server/main.lua 的 MgrMap 注册的 MgrAchievements（通关成就交付队列）＋ MgrPlayerData
-- （玩家数据实例）＋ MgrSave（持久操作协议），按 main.lua 的接线注入同一份协作关系；引擎边界
-- （ArchiveService、Players、World 时钟）与存档写入用替身。**不执行 main.lua 本体**：它一开头就要完整引擎
-- 服务，所以照 MgrMap 的接线手工装配，再读 main.lua 源码核对那几条接线确实存在（见 WIRING）。
-- 通关完成标记的落账入口是第七区兑换（PlayerFisherman），本文件不重测那条写路径：完成标记按存档契约
-- （PlayerData:Serialize / ApplySave，即重进后权威状态的来路）建立，本文件判的是它之后**交付队列**的语义。
-- 失败方式（先列后写）：
--   0. main.lua 的接线被改掉（成就交付不再拿玩家数据或存档）：本文件先红；
--   1. 平台 ID 未交付时完成标记在重进后丢；
--   2. 平台失败被当成已授予（落已送达），或失败后不再补交；
--   3. 已送达后再提交/再发奖（重复授予）；
--   4. 未交付/占位期间把「平台说已完成」当成本成就的授予。
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

describe('条款 13-12 / 13-13 / 13-14 / 13-18：通关成就的本地标记与平台补交', function()
    local env, saved

    -- 玩家数据实例：真实 PlayerData（存档契约的真源），按 MgrPlayerData 的进世界路径初始化。
    local function newData()
        local data = assert(loadfile('server/Data/PlayerData.lua'))().New(env.player, function() end)
        data:Init()
        return data
    end

    -- 平台成就服务替身：记录调用序，答案由 completed / queryError / submitError 控制。
    local function newArchive()
        return {
            IsAchievementCompleted = function(_, player, id)
                assert.same(env.player, player)
                env.queries[#env.queries + 1] = id
                if env.queryError then error('平台查询暂不可用') end
                return env.completed == true
            end,
            SetAchievementProgress = function(_, player, id, count)
                assert.same(env.player, player)
                assert.same(1, count)
                env.submits[#env.submits + 1] = id
                if env.submitError then error('平台提交暂不可用') end
            end,
        }
    end

    -- 与 main.lua 的 MgrMap 接线同形的协作关系；存档写入用替身，只做 transform 与 done 的协议语义。
    local function wire(data)
        local playerData = { GetDataInst = function(_, player) return player == env.player and data end }
        local save = {
            NextOperation = function() return { id = '26302:' .. tostring(env.writes + 1) } end,
            Execute = function(_, player, target, operation, transform, done)
                assert.same(env.player, player)
                env.writes = env.writes + 1
                local accepted, result = transform(target)
                if not accepted then return false, 'rejected' end
                if done then done(true, result) end
                return true
            end,
        }
        local mgr = assert(loadfile('server/Mgr/MgrAchievements.lua'))()
        mgr.PlayerData, mgr.Save = playerData, save
        mgr.Players = { GetPlayers = function() return { env.player } end }
        mgr.World = { GetServerTime = function() return env.now end }
        mgr.Archive = newArchive()
        return { mgr = mgr, save = save }
    end

    before_each(function()
        assert_wiring()
        saved = {
            platformId = GameCfg.Achievements.final.PlatformId,
            placeholderId = GameCfg.Achievements.final.PlaceholderId,
            debug = GameCfg.Debug.Enabled,
        }
        GameCfg.Achievements.final.PlatformId = nil
        GameCfg.Debug.Enabled = false
        env = { now = 0, queries = {}, submits = {}, writes = 0 }
        env.player = { UserId = 26302, SetAttribute = function() end }
        env.data = newData()
        env.wire = wire(env.data)
    end)

    after_each(function()
        GameCfg.Achievements.final.PlatformId = saved.platformId
        GameCfg.Achievements.final.PlaceholderId = saved.placeholderId
        GameCfg.Debug.Enabled = saved.debug
        env = nil
    end)

    local function delivered()
        return env.data.Extra.achievementDelivered
    end

    local function advance(window)
        env.now = env.now + (window or (GameCfg.AchievementDelivery.RetrySec + 1))
        env.wire.mgr:Update()
    end

    -- 重进：按存档契约把权威状态还原到新的玩家数据实例（旧实例的标记必须还在存档里）。
    local function relogin()
        local payload = env.data:Serialize()
        env.data = newData()
        env.data:ApplySave(payload)
        env.wire = wire(env.data)
        return env.data
    end

    it('13-12 平台 ID 交付前本地先存完成标记，重进后继续补交', function()
        env.data.Extra.achievements.final = true
        env.wire.mgr:Update()
        advance()
        assert.same(0, #env.queries + #env.submits, '没有平台 ID 时不碰平台')
        assert.is_nil(delivered(), '没有平台 ID 时不许落已送达')
        -- 重进：标记要在存档里（本地先保存），还原后还在。
        local restored = relogin()
        assert.is_true(restored.Extra.achievements.final, '完成标记必须随存档重进保留')
        -- 平台侧交付真实 ID（只替换共享配置）之后，同一个交付队列继续补交。
        GameCfg.Achievements.final.PlatformId = 3801
        advance()
        assert.same({ 3801 }, env.submits, '重进后要继续补交')
    end)

    it('13-13 重复交付不重复授予，已送达落账后不再提交', function()
        GameCfg.Achievements.final.PlatformId = 3801
        env.data.Extra.achievements.final = true
        advance()
        assert.same({ 3801 }, env.submits, '平台说没完成时提交一次')
        env.completed = true
        advance()
        assert.is_true((delivered() or {}).final, '平台确认后落已送达')
        local writes = env.writes
        -- 再交付一次同一个成就、再走几个窗口：既不重复提交，也不重复写已送达。
        env.completed = false
        env.data.Extra.achievements.final = true
        env.wire.mgr:Update()
        advance()
        advance()
        assert.same(1, #env.submits, '已送达之后不许再提交（不重复发奖）')
        assert.same(writes, env.writes, '已送达之后不许再落一次账')
        assert.is_true(delivered().final)
        -- 已送达标记本身也要能重进保留。
        local restored = relogin()
        assert.is_true(restored.Extra.achievementDelivered.final, '已送达标记随存档保留')
    end)

    it('13-14 平台查询与提交失败都保留补交，不把失败当成已授予', function()
        GameCfg.Achievements.final.PlatformId = 3801
        env.data.Extra.achievements.final = true
        env.queryError = true
        env.wire.mgr:Update()
        assert.is_nil(delivered(), '查询失败不得当成已授予')
        assert.same(0, #env.submits, '查询失败时不盲提交')
        env.queryError = false
        env.submitError = true
        advance()
        assert.same({ 3801 }, env.submits, '查询说没完成就该提交')
        assert.is_nil(delivered(), '提交失败不得当成已授予')
        assert.is_true(env.data.Extra.achievements.final, '失败后完成标记不许丢')
        env.submitError = false
        advance()
        assert.same({ 3801, 3801 }, env.submits, '失败后继续补交')
        assert.is_nil(delivered())
        env.completed = true
        advance()
        assert.is_true(delivered().final, '平台确认后才落已送达')
    end)

    it('13-18 平台成就 ID 未交付：标记留着、可重复补交，真实授予单列', function()
        local placeholder = GameCfg.Achievements.final.PlaceholderId
        assert.is_nil(GameCfg.Achievements.final.PlatformId, '平台侧未交付时真实 ID 留空')
        env.data.Extra.achievements.final = true
        -- 生产构建（非调试）：不拿占位 ID 去问或去写平台，本地标记一直留着。
        env.wire.mgr:Update()
        advance()
        assert.same(0, #env.queries + #env.submits)
        assert.is_true(env.data.Extra.achievements.final)
        assert.is_nil(delivered())
        -- 调试构建：占位 ID 反复走通补交路径，但平台怎么回答都不算本成就已授予。
        GameCfg.Debug.Enabled = true
        env.completed = false
        env.wire.mgr:Update()
        assert.same({ placeholder }, env.queries)
        assert.same({ placeholder }, env.submits)
        env.completed = true
        advance()
        assert.same({ placeholder, placeholder }, env.queries, '可重复补交')
        assert.is_nil(delivered(), '占位 ID 不宣称真实授予')
        assert.is_true(env.data.Extra.achievements.final, '完成标记不许丢')
        -- 重进之后标记仍在，真实 ID 到位时立刻按真实 ID 补交（真实平台授予作为生产开关单列）。
        local restored = relogin()
        assert.is_true(restored.Extra.achievements.final)
        env.completed = false
        GameCfg.Achievements.final.PlatformId = 3801
        advance()
        assert.same(3801, env.queries[#env.queries])
        assert.same(3801, env.submits[#env.submits])
    end)
end)
