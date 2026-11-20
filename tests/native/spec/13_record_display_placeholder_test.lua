-- 条款 13-07、13-08、13-17（docs/acceptance/13-compendium-achievements.md）：
--   13-07 图鉴每条记录含鱼名、品级、钓鱼区、个人最大重量与全服纪录保持者五项；
--   13-08 缺少平台纪录时该记录显示「未取得数据」，不显示虚构纪录；
--   13-17 全服纪录服务未接入时该列只按「未取得数据」展示，不展示虚构纪录；真实纪录服务接入作为生产开关单列。
-- 只走业务入口：服务端进 server/main.lua 的 MgrMap 注册的 MgrRecords（RecordsRequest → RecordsState 协议），
-- 平台纪录服务经 MgrRecords.Adapter 这条可替换适配层注入（真实 DataStore 边界不在本断言内）；
-- 客户端进 client/ScreenHandlers/ScreenCompendium.lua 的公开入口（SelectFish / NoteState / NoteRecord / View）。
-- 引擎边界（World 时钟、Task 调度、RE 通道、EUI 节点）全部替身。**不执行 main.lua 本体**：它一开头就要
-- 完整引擎服务，所以照 MgrMap 的接线手工装配，再读 main.lua 的源码核对那几条接线确实存在（见 WIRING）——
-- 接线一改，本文件先红，逼人复核断言。
-- 失败方式（先列后写）：
--   0. main.lua 的接线被改掉（纪录管理器不再拿玩家数据）：本文件先红；
--   1. 没有纪录时显示重量或保持者（虚构纪录）；
--   2. 平台读不到被当成「没有纪录」（两态混同会掩盖真实故障，玩家会以为真的没人钓到）；
--   3. 不可用时显示任何数字（把不可用当纪录展示）；
--   4. 纪录行丢掉鱼名、品级、钓鱼区、个人最大重量、保持者五项之一。
local GameCfg = require('common.GameCfg')

-- 前提守卫：本文件复现的是 main.lua 的接线，而不是自造一套协作关系。
local WIRING = {
    'MgrRecords = require("server.Mgr.MgrRecords"),',
    'MgrMap.MgrRecords.PlayerData = MgrMap.MgrPlayerData',
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

-- 引擎替身：World 既给服务端时钟，也给客户端建 EUI 节点；Task:Spawn 当场执行。
local function newWorld()
    local env = { nodes = {}, world = {} }
    function env.world:GetServerTime() return 0 end
    function env.world:CreateUnit(kind, props)
        local node = { Kind = kind, OnClicked = { Connect = function() return { Disconnect = function() end } end } }
        function node:Destroy() self.Destroyed = true end
        for key, value in pairs(props) do node[key] = value end
        env.nodes[#env.nodes + 1] = node
        return node
    end
    return env
end

local function installEngine()
    local saved = { game = rawget(_G, 'game'), Vector2 = rawget(_G, 'Vector2'),
        Color = rawget(_G, 'Color'), MgrGameUI = rawget(_G, 'MgrGameUI'),
        REUtil = rawget(_G, 'REUtil'),
        reutilModule = package.loaded['common.REUtil'], gameuiModule = package.loaded['client.GameUI'] }
    return saved
end

local function restoreEngine(saved)
    _G.game, _G.Vector2, _G.Color, _G.MgrGameUI = saved.game, saved.Vector2, saved.Color, saved.MgrGameUI
    _G.REUtil = saved.REUtil
    package.loaded['common.REUtil'] = saved.reutilModule
    package.loaded['client.GameUI'] = saved.gameuiModule
end

-- RE 通道替身：按通道名收 FireClient 的载荷，就是客户端会收到的推送。
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

describe('条款 13-07 / 13-08 / 13-17：全服纪录列的占位口径', function()
    local saved, env, re, records, player

    before_each(function()
        assert_wiring()
        saved = installEngine()
        env = newWorld()
        _G.game = {
            GetService = function(_, name)
                if name == 'World' then return env.world end
                if name == 'Task' then return { Spawn = function(_, fn) fn() end } end
            end,
        }
        _G.Vector2 = { New = function(x, y) return { x = x, y = y } end }
        _G.Color = { New = function(...) return { ... } end }
        _G.MgrGameUI = { GetScreen = function() end, CloseScreen = function() end }
        re = channels()
        package.loaded['common.REUtil'] = { GetRE = re.GetRE }
        package.loaded['client.GameUI'] = {
            GetEuiManager = function()
                return { GetDeviceResolution = function() return { x = 1920, y = 1080 } end }
            end,
        }
        _G.REUtil = { GetRE = re.GetRE, CheckRECD = function() return false end }
        -- 平台纪录服务边界：Adapter 是这条可替换适配层，本文件按「读到什么」注入两种答案。
        records = assert(loadfile('server/Mgr/MgrRecords.lua'))()
        -- 与 server/main.lua 的 MgrMap 接线同形；本条款判纪录列，个人对账不是本文件的事。
        records.PlayerData = { GetDataInst = function() return nil end }
        player = { UserId = 't13-records-1', Name = '钓鱼佬' }
    end)

    after_each(function()
        restoreEngine(saved)
    end)

    local function answer(ok, entry, kind)
        records.Adapter = {
            Read = function() return ok, entry, kind end,
            Submit = function() error('本文件不应产生全服纪录写入') end,
        }
    end

    -- 从客户端入口发一次纪录查询，返回服务端回给客户端的 RecordsState 载荷。
    local function query(screen)
        screen:SelectFish('goldfish')
        local request = re.posts.RecordsRequest
        records:Handle(player, { fishId = 'goldfish', seq = screen.RecordSeq })
        local states = re.posts.RecordsState or {}
        assert.is_table(states[#states], '服务端没有回 RecordsState')
        return states[#states], request
    end

    local function client()
        return assert(loadfile('client/ScreenHandlers/ScreenCompendium.lua'))()
    end

    it('13-08 没有纪录时显示「未取得数据」，不显示虚构纪录', function()
        answer(true, nil, nil)
        local screen = client()
        local state = query(screen)
        assert.same('missing', state.state, '服务可用但没纪录，必须是 missing，不能冒充有纪录')
        assert.is_nil(state.weight)
        assert.is_nil(state.holder)
        assert.is_true(screen:NoteRecord(state))
        local text = screen:View().recordText
        assert.same('全服纪录：未取得数据', text)
        assert.is_nil(text:match('%d'), '未取得数据时不得出现任何数字')
        assert.is_nil(text:match('kg'), '未取得数据时不得出现重量单位')
    end)

    it('13-17 纪录服务未接入时该列只按「未取得数据」展示，不展示虚构纪录', function()
        -- 真实 DataStore 读不到 / 服务未接入：适配层报错，服务端必须按 unavailable 回，不猜成 missing。
        answer(false, nil, 'unavailable')
        local screen = client()
        local state = query(screen)
        assert.same('unavailable', state.state, '读不到不能被当成没有纪录')
        assert.is_nil(state.weight, '读不到时不得回一个重量')
        assert.is_nil(state.holder, '读不到时不得回一个保持者')
        assert.is_true(screen:NoteRecord(state))
        local text = screen:View().recordText
        assert.same('全服纪录：未取得数据', text)
        assert.is_nil(text:match('%d'), '未取得数据时不得出现任何数字')
        -- 换一位玩家再查一次仍然是「未取得数据」：不因为有人查询就凭空长出纪录。
        player = { UserId = 't13-records-2', Name = '旁观者' }
        local again = query(screen)
        assert.same('unavailable', again.state)
        assert.same('全服纪录：未取得数据', screen:View().recordText)
    end)

    it('13-07 纪录行含鱼名、品级、钓鱼区、个人最大重量与全服纪录保持者五项', function()
        answer(true, { w = 1234, u = 42, n = '钓鱼佬' }, nil)
        local screen = client()
        screen:Request()
        assert.is_true(screen:NoteState({ seq = screen.Seq, state = 'ready',
            unlocked = { goldfish = true }, weights = { goldfish = 1.23 },
            catches = { goldfish = 1 }, total = 1 }))
        local state = query(screen)
        assert.is_true(screen:NoteRecord(state))
        local view = screen:View()
        assert.same(GameCfg.Zones[1].Name, view.zone, '钓鱼区')
        local entry
        for _, row in ipairs(view.entries) do if row.id == 'goldfish' then entry = row end end
        assert.is_table(entry)
        assert.same(GameCfg.Fish.goldfish.Name, entry.name, '鱼名')
        assert.same('普通', entry.grade, '品级')
        assert.same('最大钓取 1.23 千克', entry.weightText, '个人最大重量')
        assert.same('全服纪录：12.34 kg（钓鱼佬）', view.recordText, '全服纪录保持者')
    end)
end)
