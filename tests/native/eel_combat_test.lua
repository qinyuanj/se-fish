-- #84 迁移：电鳗技能与战斗状态字标签（原 tests/gameplay/eel_combat_test.lua，12 + 3 例）。
-- 接缝：MgrFishUnit 的 eel 状态机——5 次放电每秒一次、施法被拒不计数不入睡、5 次满才睡 10 秒、
-- Busted 案例体在沙箱 _ENV 中，写业务可见的全局（Quaternion）必须用 _G.Quaternion。
-- describe/it 名称保留旧类名与方法名，并按方法名字典序注册以保持旧套件执行顺序。
local game_cfg = require('common.game_cfg')
local fish_escape = require('tests.support.fish_escape')

-- 放下一条电鳗；castOk 决定每次施法结果，返回鱼与计数表
local function droppedEel(env, castOk)
    env:prepare()
    local log = { casts = 0, removed = 0, published = {} }
    env.castOk = castOk or function() return true end
    env.mgr.Ability = {
        EquipFish = function() return true end,
        CastFish = function()
            if not env.castOk() then return false end
            log.casts = log.casts + 1
            return true
        end,
        RemoveFish = function() log.removed = log.removed + 1 end,
    }
    env.mgr.CombatPublisher = function(payload) log.published[#log.published + 1] = payload end
    local fish = env:heldFish(env.player, 'eel')
    env.mgr:Drop(env.player)
    return fish, log
end

local function at(env, now, times)
    env.now = now
    for _ = 1, times or 1 do env.mgr:Update() end
end

describe('TestEelCombat', function()
    local env

    before_each(function()
        env = fish_escape.new()
        env:setUp()
    end)
    after_each(function()
        env:tearDown()
    end)

    it('test_client_snapshots_follow_state_changes', function()
        local fish, log = droppedEel(env)
        local first = log.published[1]
        assert.same({ 'combat', 180, 180, 0, 5 },
            { first.state, first.fleeAt, first.escapeSec, first.discharges, first.dischargeCount })
        assert.are.equal('eel', first.fishId)
        assert.is_not.is_nil(first.position)
        for t = 0, 5.5, 0.5 do at(env, t) end -- 预警与放电各占一个半秒相位
        local states, seen = {}, {}
        for i = 2, #log.published do
            local p = log.published[i]
            local key = p.state .. ':' .. p.discharges
            if not seen[key] then seen[key] = true; states[#states + 1] = key end
        end
        assert.same({ 'attacking:0', 'attacking:1', 'attacking:2', 'attacking:3',
            'attacking:4', 'attacking:5', 'sleeping:5' }, states)
        assert.are.equal(15, log.published[#log.published].wakeAt)
        at(env, 15)
        assert.are.equal('combat', log.published[#log.published - 1].state)
        assert.are.equal('attacking', log.published[#log.published].state)
        assert.is_true(fish.CombatPublished)
    end)

    it('test_combat_fish_is_not_counted_as_escaping', function()
        -- 再放普通鱼不能提前清掉尚未到逃跑时限的精英鱼。
        env:prepare()
        local eel = env:heldFish(env.player, 'eel')
        env.mgr:Drop(env.player)
        env.now = 1
        local normal = env:heldFish(env.player, 'bass')
        env.mgr:Drop(env.player)
        assert.same(eel, env.mgr.Fish[eel.Id])
        assert.same({ normal }, env.mgr:Escaping())
    end)

    it('test_escape_goes_straight_and_vanishes_in_water', function()
        local fish = droppedEel(env)
        at(env, 180)
        assert.are.equal('escaping', fish.State)
        local heading = fish.Heading
        env.hits = { { Instance = { Name = 'Wall' }, Distance = 1 } }
        at(env, 184)
        assert.same(heading, fish.Heading)
        fish.Carrier.Body.Position = Vector3.New(-11.75, 5, -12.25)
        env.mgr:Update()
        assert.is_nil(env.mgr.Fish[fish.Id])
    end)

    it('test_five_discharges_one_second_apart_then_sleeps_ten_seconds', function()
        local fish, log = droppedEel(env)
        assert.are.equal('combat', fish.State)
        at(env, 0) -- 首个更新只发预警
        for i = 0, 4 do
            at(env, i + 0.5) -- 预警后 0.5 秒才放电
            assert.are.equal(i + 1, log.casts)
            assert.are.equal('attacking', fish.State)
            at(env, i + 1)
            assert.are.equal(i + 1, log.casts)
        end
        at(env, 5)
        assert.are.equal('sleeping', fish.State)
        assert.are.equal(15, fish.WakeAt)
        at(env, 14.99)
        assert.are.equal(5, log.casts)
        assert.are.equal('sleeping', fish.State)
        for t = 15, 15.5, 0.5 do at(env, t) end
        assert.are.equal(6, log.casts)
        assert.are.equal('attacking', fish.State)
        assert.are.equal(1, fish.Discharges)
    end)

    it('test_flee_deadline_mid_attack_stops_casting_and_removes_skill', function()
        local fish, log = droppedEel(env)
        at(env, 0)
        at(env, 5)
        at(env, 177.5)
        assert.are.equal('attacking', fish.State)
        local casts = log.casts
        at(env, 180)
        assert.are.equal('escaping', fish.State)
        assert.are.equal(1, log.removed)
        at(env, 181)
        assert.are.equal(casts, log.casts)
        assert.are.equal('escaping', log.published[#log.published].state)
    end)

    it('test_killed_mid_attack_stops_and_label_disappears', function()
        local fish, log = droppedEel(env)
        at(env, 0)
        at(env, 1)
        assert.is_not.is_nil(env.mgr:TakeKilled(fish))
        assert.are.equal(1, log.removed)
        assert.same({ id = fish.Id, state = 'gone' }, log.published[#log.published])
        at(env, 2)
        assert.are.equal(1, log.casts)
        assert.is_nil(env.mgr:TakeKilled(fish))
    end)

    it('test_large_dt_neither_bursts_nor_swallows_sleep', function()
        local fish, log = droppedEel(env)
        at(env, 0)
        at(env, 3.7)
        assert.are.equal(1, log.casts)
        at(env, 3.7, 2)
        assert.are.equal(1, log.casts) -- 同一时刻重复帧不连放
        at(env, 4.8)
        assert.are.equal(2, log.casts)
        for t = 5, 8, 0.5 do at(env, t) end
        assert.are.equal(5, log.casts)
        assert.are.equal('sleeping', fish.State)
        assert.near(18, fish.WakeAt, 1e-9)
        at(env, 17.9)
        assert.are.equal(5, log.casts)
        for t = 18, 18.5, 0.5 do at(env, t) end
        assert.are.equal(6, log.casts)
    end)

    it('test_moving_elite_shares_flee_bar_with_throttled_refresh', function()
        -- 逃跑时限条与鳄雀鳝共用：会移动的精英按限频补发坐标，不带放电字段，逃跑时标签收起。
        env:prepare()
        local published = {}
        env.mgr.Ability = { EquipFish = function() return true end, CastFish = function() return true end,
            RemoveFish = function() end }
        env.mgr.CombatPublisher = function(payload) published[#published + 1] = payload end
        local fish = env:heldFish(env.player, 'alligatorGar')
        env.mgr:Drop(env.player)
        local escapeSec = game_cfg.Fish.alligatorGar.EscapeSec
        assert.same({ 'combat', escapeSec, escapeSec }, { published[1].state, published[1].fleeAt, published[1].escapeSec })
        assert.is_nil(published[1].dischargeCount)
        local refresh = game_cfg.FishCombatLabel.MovingRefreshSec
        at(env, 0, 3)
        local count = #published
        at(env, refresh / 2)
        assert.are.equal(count, #published)
        at(env, refresh)
        assert.are.equal(count + 1, #published)
        at(env, escapeSec)
        assert.are.equal('escaping', fish.State)
        assert.are.equal('escaping', published[#published].state)
    end)

    it('test_rejected_cast_is_not_counted_and_retried', function()
        -- 打断：施法被技能包拒绝（InCast 未清 / 技能未就绪）不计数、不入睡，下帧重试
        local accept = false
        local fish, log = droppedEel(env, function() return accept end)
        at(env, 0)
        at(env, 3)
        assert.are.equal('attacking', fish.State) -- 预警已发出，施法一直被拒
        assert.are.equal(0, log.casts)
        accept = true
        at(env, 3.1)
        assert.are.equal('attacking', fish.State)
        accept = false
        at(env, 4.1)
        at(env, 4.2)
        assert.are.equal(1, fish.Discharges)
        assert.are.equal('attacking', fish.State)
        accept = true
        at(env, 4.3)
        assert.are.equal(1, fish.Discharges)
        at(env, 4.7)
        assert.are.equal(2, fish.Discharges)
        assert.near(5.1, fish.WarnAt, 1e-9)
    end)

    it('test_repeated_updates_at_same_time_discharge_once', function()
        local fish, log = droppedEel(env)
        at(env, 0, 3) -- 起手帧只发预警
        assert.are.equal(0, log.casts)
        at(env, 0.5, 3)
        assert.are.equal(1, log.casts)
        for t = 1, 6, 0.5 do at(env, t) end
        assert.truthy(log.casts >= 2)
        assert.are.equal(log.casts, fish.Discharges) -- 同一时刻重复帧不重复计数
    end)

    it('test_sleep_lies_sideways_and_waking_restores_rotation', function()
        env:prepare()
        local oldQuaternion = _G.Quaternion
        local rotation = setmetatable({}, { __mul = function(_, value) return value end })
        -- Busted 案例体在沙箱 _ENV：业务模块读的是真 _G，必须写 _G.Quaternion
        _G.Quaternion = { FromEulerAngles = function(x, y, z) return { x = x, y = y, z = z } end }
        env.mgr.Ability = { EquipFish = function() end, CastFish = function() return true end }
        local fish = env:heldFish(env.player, 'eel')
        fish.Carrier.Body.Rotation = rotation
        env.mgr:Drop(env.player)
        for t = 0, 5.5, 0.5 do at(env, t) end
        local sleepRotation = fish.Carrier.Body.Rotation
        at(env, 15)
        local wakeRotation = fish.Carrier.Body.Rotation
        _G.Quaternion = oldQuaternion
        assert.are.equal('attacking', fish.State)
        assert.are.equal(game_cfg.Ability.FishAbilities.eel.SleepRollRadians, sleepRotation.z)
        assert.are_not.equal(sleepRotation.z, wakeRotation.z)
    end)
end)

local eui = require('tests.support.eui_double')
local client_store = require('client.store.client_store')
local root_view = require('client.views.root_view')
local fish_combat_view = require('client.views.fish_combat_view')
local spoke_clock = require('common.spoke_clock')

describe('TestFishCombatLabel', function()
    local env

    local function mountView()
        local clock = spoke_clock.new(90)
        local store, writer = client_store.new({ clock = clock })
        local root = eui.Node({ Name = 'UIRoot' })
        local created = {}
        local view = root_view.mount(root, store, {
            create_node = function(kind, props)
                local node = eui.Node(props or {})
                node.UnitType = kind
                created[#created + 1] = node
                return node
            end,
            docks = { fish_combat = fish_combat_view.bar_spec() },
        })
        return { root = root, writer = writer, view = view, created = created }
    end

    local function aliveByName(viewEnv, name)
        for _, node in ipairs(viewEnv.created) do
            if not node.Destroyed and node.Name == name then return node end
        end
    end

    local function aliveCount(viewEnv, prefix)
        local count = 0
        for _, node in ipairs(viewEnv.created) do
            if not node.Destroyed and type(node.Name) == 'string' and node.Name:find(prefix, 1, true) == 1 then
                count = count + 1
            end
        end
        return count
    end

    before_each(function()
        env = mountView()
    end)
    after_each(function()
        if env and env.view then env.view:dispose() end
        env = nil
    end)

    it('test_crab_move_names_render_chinese_labels', function()
        for move, name in pairs({ jab = '蟹钳乱刺', pinch = '蟹钳双击', charge = '冲撞', spin = '旋转' }) do
            assert.is_true(env.writer:ingest_event('FishCombatState', {
                list = {
                    { id = 24, fishId = 'fish24Boss', name = '蟹老板', health = 1000, maxHealth = 1200,
                      move = move, label = name },
                },
            }))
            local bar = aliveByName(env, 'FishBar_24')
            local tag = aliveByName(env, 'FishTag_24')
            assert.is_not_nil(bar)
            assert.are.equal('蟹老板 1000/1200', bar.Text)
            assert.is_not_nil(tag)
            assert.matches(name, tag.Text, nil, true)
        end
    end)

    it('test_text_shows_discharges_sleep_and_flee_bar', function()
        assert.is_true(env.writer:ingest_event('FishCombatState', {
            list = {
                { id = 1, fishId = 'eel', name = '电鳗', health = 240, maxHealth = 300, label = '放电 3/5' },
            },
        }))
        assert.are.equal('电鳗 240/300', aliveByName(env, 'FishBar_1').Text)
        assert.are.equal('放电 3/5', aliveByName(env, 'FishTag_1').Text)

        assert.is_true(env.writer:ingest_event('FishCombatState', {
            list = {
                { id = 1, fishId = 'eel', name = '电鳗', health = 180, maxHealth = 300, label = '睡眠 8 秒' },
            },
        }))
        assert.are.equal('电鳗 180/300', aliveByName(env, 'FishBar_1').Text)
        assert.are.equal('睡眠 8 秒', aliveByName(env, 'FishTag_1').Text)

        assert.is_true(env.writer:ingest_event('FishCombatState', {
            list = {
                { id = 2, fishId = 'alligatorGar', name = '鳄雀鳝', health = 500, maxHealth = 500 },
            },
        }))
        assert.is_nil(aliveByName(env, 'FishBar_1'))
        assert.is_nil(aliveByName(env, 'FishTag_1'))
        assert.are.equal('鳄雀鳝 500/500', aliveByName(env, 'FishBar_2').Text)
        assert.is_nil(aliveByName(env, 'FishTag_2'))

        assert.is_true(env.writer:ingest_event('FishCombatState', { list = {} }))
        assert.are.equal(0, aliveCount(env, 'FishBar_'))
        assert.are.equal(0, aliveCount(env, 'FishTag_'))
    end)

    it('test_valid_rejects_malformed_payloads', function()
        assert.is_false(env.writer:ingest_event('FishCombatState', nil))
        assert.is_true(env.writer:ingest_event('FishCombatState', {
            list = {
                'bad-row',
                { fishId = 'eel', name = '缺编号' },
            },
        }))
        assert.are.equal(0, aliveCount(env, 'FishBar_'))
        assert.are.equal(0, aliveCount(env, 'FishTag_'))

        assert.is_true(env.writer:ingest_event('FishCombatState', {
            list = {
                { id = 7, fishId = 'eel', name = '电鳗', health = 300, maxHealth = 300, label = '战斗' },
            },
        }))
        assert.are.equal(1, aliveCount(env, 'FishBar_'))
        assert.are.equal('电鳗 300/300', aliveByName(env, 'FishBar_7').Text)
    end)
end)
