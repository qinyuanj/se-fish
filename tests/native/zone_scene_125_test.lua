-- #125 失败方式：无穷值或重名水域让 Build 静默返回判定器、长方形水域被当成正方形
-- （贴边 0.1m 误判）、场景诊断把缺实体/重名/错位报成通过，以及场景实体与快照点不再共享同一张
-- 坐标表（复制成两份后改一处另一处不动）。
-- 迁移自 tests/gameplay/zone_scene_125_test.lua（#83）。单类 TestZoneScene125，无 setUp/tearDown。
-- 断言口径：旧 assertEquals 对 table 是深比较 → assert.same；旧 assertIs 要求同一引用
-- → 用 assert.are.equal（就是 `==`，深比较的 same 会把「共享同一表」弱化成「内容相等」而漏判）。
-- 七区几何、SafePoint 与航线 Destination、返程票价已由 zone_layout_plan_test 与 ferry_test
-- 对同一份快照断言，这里不再重算。
local judge = require('common.math_water_judge')
local cfg = require('common.game_cfg')

describe("TestZoneScene125", function()
  it("test_invalid_geometry_fails_before_a_judge_is_returned", function()
    for _, bad in ipairs({ math.huge, -math.huge, 0 / 0 }) do
      assert.error_matches(function()
        judge.Build({ { Id = '坏水域', Center = { x = bad, z = 0 }, HalfXZ = 1, SurfaceY = 2 } })
      end, '有限', nil, true)
    end
    local zone = { Id = '重复', Center = { x = 0, z = 0 }, HalfXZ = 1, SurfaceY = 2 }
    assert.error_matches(function()
      judge.Build({ zone, zone })
    end, '重复', nil, true)
  end)

  it("test_rectangular_water_preserves_dry_bank_and_inclusive_edges", function()
    local judge = judge.Build({ {
      Id = '巡航水面', Center = { x = 10, z = 20 },
      HalfX = 30, HalfZ = 5, SurfaceY = 2,
    } })
    assert.are.equal('巡航水面', judge({ x = 40, y = 2, z = 25 }).Id)
    assert.is_nil(judge({ x = 10, y = 2, z = 25.01 }))
    assert.is_nil(judge({ x = 40.01, y = 2, z = 20 }))
    assert.is_nil(judge({ x = 10, y = 2.01, z = 20 }))
  end)

  it("test_scene_diagnostic_names_missing_duplicate_and_moved_entities", function()
    local scenes = { { Id = 'crabLake', Name = '蟹湖', Scene = { State = 'planned', Entities = {
      { Name = 'CrabWater', Position = { x = 260, y = 2, z = 140 } },
      { Name = 'CrabSafe', Position = { x = 260, y = 6, z = 100 } },
      { Name = 'CrabShop', Position = { x = 250, y = 5, z = 100 } },
    } } } }
    local report = judge.InspectScene(scenes, {
      { Name = 'CrabSafe', Position = { x = 260, y = 6, z = 100 } },
      { Name = 'CrabSafe', Position = { x = 260, y = 6, z = 100 } },
      { Name = 'CrabShop', Position = { x = 250, y = 5, z = 110 } },
    })
    assert.is_nil(report.Ready)
    assert.same({
      { ZoneId = 'crabLake', ZoneName = '蟹湖', Name = 'CrabWater', Code = 'missing' },
      { ZoneId = 'crabLake', ZoneName = '蟹湖', Name = 'CrabSafe', Code = 'duplicate' },
      { ZoneId = 'crabLake', ZoneName = '蟹湖', Name = 'CrabShop', Code = 'position' },
    }, report.Issues)
    local complete = {}
    for _, e in ipairs(scenes[1].Scene.Entities) do complete[#complete + 1] = e end
    report = judge.InspectScene(scenes, complete)
    assert.is_true(report.EntitiesMatch)
    assert.is_nil(report.Ready) -- 名称和位置匹配不等于碰撞、保存或试玩通过。
    assert.same({ 'crabLake' }, report.PendingZones)
    scenes[1].Scene.State = 'resolved'
    report = judge.InspectScene(scenes, complete)
    assert.is_nil(report.Ready)
    assert.same({
      Saved = 'unverified', Synced = 'unverified', Collision = 'unverified', Playtested = 'unverified',
    }, report.Verification)

    -- 配置真值：实体与快照点必须是同一张表（不是内容相等）——共享点被复制成两份后，
    -- 改一处另一处不动就漂移，诊断按位置比也会各说一套。
    for _, zone in ipairs(cfg.Zones) do
      local scene = zone.Scene
      for _, entity in ipairs(scene.Entities) do
        if entity.Role == 'Safe' then assert.are.equal(scene.SafePoint, entity.Position) end
        if entity.Role == 'Water' then
          for _, water in ipairs(scene.Waters) do
            if water.EntityName == entity.Name then
              assert.are.equal(water.Center, entity.Position, entity.Name)
              break
            end
          end
        end
      end
    end
    assert.are.equal(cfg.Zones[1].Scene.BaitSpots.Positions[1], cfg.BaitSpots.Spots[1].Position)
    assert.are.equal(cfg.Zones[7].Scene.Waters[1], cfg.Zones[7].Scene.CruiseWater)
  end)
end)
