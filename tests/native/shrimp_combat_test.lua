-- #84 迁移：虾池精英 / 首领战斗（原 tests/gameplay/shrimp_combat_test.lua，10 例）。
-- 接缝：MgrFishUnit 的 shrimp / dragon 状态机——连击两下 20 后接尾刺位移、雨云 6 个秒槽不延长不追溯、
-- 俯冲与眩晕互斥、脚本化追击按 dt 位移且不越过咬距、移除与逃跑时限清招式与预警。
-- 沿用 tests/support/fish_combat 共享夹具；describe/it 名称保留旧类名与方法名，
-- 并按方法名字典序注册以保持旧套件执行顺序。
local FishCombat = require('tests.support.fish_combat')

local function drop(env, id)
    env:prepare()
    env.player.Character.Controller.Health = 2000
    env.player.Character.Controller.TakeDamage = function() end
    local fish = env:held_fish(env.player, id)
    env.mgr:drop(env.player)
    local p = fish.carrier.body.Position
    env.player.Character.Position = { x = p.x, y = p.y, z = p.z + 1 }
    env.other.Character.Controller.Health = 0
    return fish
end

describe('TestShrimpCombat', function()
    local env

    before_each(function()
        env = FishCombat.new()
        env:set_up()
    end)
    after_each(function()
        env:tear_down()
    end)

    it('test_airborne_dive_over_water_survives_and_timeout_lands', function()
        local fish = drop(env, 'fish16Boss')
        env.now = 30; env.mgr:update()
        env.now = 36; env.mgr:update()
        local ground = fish.Move.Center.y
        fish.carrier.body.Position = { x = 240, y = ground + 3, z = -44 }
        env.now = 37; env.mgr:update()
        assert.is_not.equal('escaping', fish.State)
        env.now = fish.flee_at; env.mgr:update()
        assert.are.equal(ground, fish.carrier.body.Position.y)
        assert.is_nil(fish.Move)
    end)

    it('test_dragon_rain_six_ticks_then_dive_and_stun_are_mutually_exclusive', function()
        local fish = drop(env, 'fish16Boss')
        env.mgr:update()
        env.now = 1.5; env.mgr:update()
        assert.are.equal(50, env.vitalsCalls[1][3])
        env.now = 30; env.mgr:update()
        assert.are.equal('rain', fish.Move.Name)
        local start = #env.vitalsCalls
        for t = 31, 36 do
            env.now = t; env.mgr:update(); env.mgr:update()
        end
        assert.are.equal(6, #env.vitalsCalls - start)
        assert.are.equal('dive', fish.Move.Name)
        env.now = 37; env.mgr:update()
        assert.is_true(fish.carrier.body.Position.y > fish.Move.Center.y)
        env.now = 38; env.mgr:update(); env.mgr:update()
        assert.are.equal(7, #env.vitalsCalls - start)
        assert.are.equal('stunned', fish.State)
        assert.are.equal(43, fish.wake_at)
        env.now = 42.9; env.mgr:update()
        assert.are.equal(7, #env.vitalsCalls - start)
        env.now = 60; env.mgr:update()
        assert.are.equal('rain', fish.Move.Name)
    end)

    it('test_rain_jitter_keeps_six_slots_without_extending_duration', function()
        local fish = drop(env, 'fish16Boss')
        env.now = 30; env.mgr:update()
        for _, t in ipairs({ 31.01, 32.02, 33.03, 34.04, 35.05, 36.01 }) do
            env.now = t; env.mgr:update(); env.mgr:update()
        end
        assert.are.equal(6, #env.vitalsCalls)
        assert.are.equal('dive', fish.Move.Name)
    end)

    it('test_rain_large_dt_does_not_retroactively_hit_new_arrival', function()
        local fish = drop(env, 'fish16Boss')
        env.now = 30; env.mgr:update()
        env.now = 36; env.mgr:update(); env.mgr:update()
        assert.are.equal(1, #env.vitalsCalls)
        assert.are.equal('dive', fish.Move.Name)
        local notice = env.notices[#env.notices]
        assert.are.equal(fish.Move.destination.x, notice.position.x)
        assert.are.equal(fish.Move.destination.z, notice.position.z)
    end)

    it('test_remove_and_timeout_cancel_moves_and_stun', function()
        local fish = drop(env, 'fish16Boss')
        env.now = 30; env.mgr:update()
        env.mgr:remove(fish)
        env.now = 40; env.mgr:update()
        assert.is_nil(fish.Move)
        assert.are.equal(0, #env.vitalsCalls)
        fish = drop(env, 'fish15Elite')
        env.mgr:update()
        env.now = fish.flee_at; env.mgr:update()
        assert.are.equal('escaping', fish.State)
        assert.is_nil(fish.Move)
        assert.is_nil(fish.wake_at)
    end)

    it('test_script_chase_moves_kinematic_body_without_overshooting', function()
        local fish = drop(env, 'fish15Elite')
        local p = fish.carrier.body.Position
        env.player.Character.Position = { x = p.x + 10, y = p.y, z = p.z }
        env.mgr:update()
        env.now = 1; env.mgr:update()
        assert.near(p.x + 7.5, fish.carrier.body.Position.x, 1e-6)
        env.now = 2; env.mgr:update()
        assert.is_not.is_nil(fish.Move)
        env.downed[env.player] = true
        local payloads = {}
        env.mgr.combat_publisher = function(payload) payloads[#payloads + 1] = payload end
        env.mgr:update()
        assert.is_nil(fish.MoveName)
        assert.is_nil(payloads[#payloads].move)
    end)

    it('test_shrimp_combo_is_two_hits_then_tail_with_no_duplicate_frame', function()
        local fish = drop(env, 'fish15Elite')
        env.mgr:update()
        assert.is_not.is_nil(fish.Move)
        for _, t in ipairs({ 2, 4, 6 }) do env.now = t; env.mgr:update(); env.mgr:update() end
        assert.are.equal(3, #env.vitalsCalls)
        for _, call in ipairs(env.vitalsCalls) do assert.are.equal(20, call[3]) end
        local p = fish.carrier.body.Position
        assert.near(p.z + 4, env.player.Character.Position.z, 1e-6)
        assert.near(p.y + 1, env.player.Character.Position.y, 1e-6)
    end)

    it('test_shrimp_stun_cancels_warning_and_restarts_after_five_seconds', function()
        local fish = drop(env, 'fish15Elite')
        env.mgr:update()
        env.now = 15; env.mgr:update()
        assert.are.equal('stunned', fish.State)
        assert.is_nil(fish.Move)
        assert.are.equal(20, fish.wake_at)
        env.now = 19.9; env.mgr:update()
        assert.are.equal(0, #env.vitalsCalls)
        env.now = 20; env.mgr:update()
        assert.are.equal('combat', fish.State)
        assert.is_not.is_nil(fish.Move)
    end)

    it('test_stun_wake_and_warning_cancel_do_not_accumulate_chase_time', function()
        local fish = drop(env, 'fish15Elite')
        env.mgr:update()
        env.now = 15; env.mgr:update()
        local p = fish.carrier.body.Position
        env.player.Character.Position = { x = p.x + 50, y = p.y, z = p.z }
        env.now = 20; env.mgr:update()
        assert.same(p, fish.carrier.body.Position)
        env.now = 21; env.mgr:update()
        assert.near(p.x + 8, fish.carrier.body.Position.x, 1e-6)
        env.player.Character.Position = { x = p.x + 9, y = p.y, z = p.z }
        env.now = 22; env.mgr:update()
        assert.is_not.is_nil(fish.Move)
        local before = fish.carrier.body.Position
        env.player.Character.Position = { x = p.x + 50, y = p.y, z = p.z }
        env.now = 24; env.mgr:update()
        assert.same(before, fish.carrier.body.Position)
        env.now = 25; env.mgr:update()
        assert.near(before.x + 8, fish.carrier.body.Position.x, 1e-6)
    end)

    it('test_tail_rejected_hit_does_not_displace_and_downed_cancels', function()
        local fish = drop(env, 'fish15Elite')
        env.mgr:update()
        env.now = 2; env.mgr:update()
        env.now = 4; env.mgr:update()
        local cp = env.player.Character.Position
        env.mgr.Vitals.apply_hit = function() return false end
        env.now = 6; env.mgr:update()
        assert.same(cp, env.player.Character.Position)
        env.downed[env.player] = true
        env.mgr:update()
        assert.is_nil(fish.Move)
    end)
end)
