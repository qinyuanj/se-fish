-- 迁移自 tests/gameplay/reel_progress_test.lua（#85）。
-- 被测接缝：common.reel_progress 的收线进度推进（上岸 / 脱钩 / 抢救窗口）。
-- it 名字沿用旧方法名，注册顺序 = LuaUnit sortedPairs 的实际执行顺序。
local Core = require('common.reel_progress')
local cfg = require('common.game_cfg').ReelIn

describe('收线进度（ReelProgress）', function()
  it('test_exact_hundred_and_batch_integral', function()
    local reel = Core.New(0, cfg)
    assert.same('landed', reel:advance(0, 10, 0.1))
    assert.same(100, reel.Progress)
    local spread = Core.New(0, cfg)
    spread:advance(1, 3, 0.1)
    assert.near(60, spread.Progress, 0.00001)
    local distributed = Core.New(0, cfg)
    distributed:advance(0.1, 1, 0.1)
    assert.near(54.5, distributed.Progress, 0.00001)
  end)

  it('test_frame_partition_error_under_half_percent', function()
    local a, b = Core.New(0, cfg), Core.New(0, cfg)
    for i = 1, 100 do a:advance(i / 100) end
    b:advance(1)
    assert.is_true(math.abs(a.Progress - b.Progress) <= 0.5)
  end)

  it('test_natural_unhook_and_grace', function()
    local reel = Core.New(0, cfg)
    assert.is_nil(reel:advance(10))
    assert.same(0, reel.Progress)
    assert.near(10, reel.ZeroAt, 0.00001)
    assert.is_nil(reel:advance(10.17))
    assert.same('unhooked', reel:advance(10.181))
    assert.same('unhooked', reel:advance(20, 10))
  end)

  it('test_zero_rescue_and_late_packet', function()
    local reel = Core.New(0, cfg)
    reel:advance(10.1)
    assert.is_nil(reel:advance(10.16, 1, 0.1))
    assert.near(5, reel.Progress, 0.5)
    local late = Core.New(0, cfg)
    late:advance(10.1)
    assert.same('unhooked', late:advance(10.19, 1, 0.1))
    local withoutTick = Core.New(0, cfg)
    assert.same('unhooked', withoutTick:advance(10.19, 1, 0.1))
  end)
end)
