-- #410 交互提示定案「自研气泡 + 导出坐标」：运行期锚点只读编辑态只读几何表，
-- 14 个空壳 TriggerUnit 退役后不再按名查场景单位。
-- 失败方式先列：烧烤锚点仍查场景单位、半径不按体型缩放、缺锚点时静默回落到场景、
-- 交互锚点与导出表坐标不一致。
local ZoneMarkers = require('common.zone_markers')
local GameCfg = require('common.game_cfg')
local GrillRules = require('server.world_host.grill_rules')
local InteractPromptArbiter = require('client.views.interact_prompt_arbiter')

describe('interaction_anchor_source (#410)', function()
    local saved_anchor_positions

    before_each(function()
        saved_anchor_positions = ZoneMarkers.anchor_positions
        local positions = {}
        for _, entry in ipairs(ZoneMarkers.contract(GameCfg)) do
            if entry.role ~= 'Boundary' then positions[entry.Name] = { x = 0, y = 0, z = 0 } end
        end
        positions.Z3_Grill = { x = 100, y = 1, z = 50 }
        ZoneMarkers.anchor_positions = positions
    end)

    after_each(function()
        ZoneMarkers.anchor_positions = saved_anchor_positions
    end)

    it('test_grill_anchor_uses_baked_position_and_body_scale_radius', function()
        local function player(x, z, interact_range)
            return { Character = { Position = { x = x, y = 1, z = z },
                GetAttribute = function() return interact_range end } }
        end
        local name, anchor = GrillRules.anchor_in_range(player(100, 52.4), {})
        assert.same('Z3_Grill', name)
        assert.same(100, anchor.Position.x)
        assert.same(50, anchor.Position.z)

        -- 超出基础半径 2 + slack 0.5 → 不命中；体型缩放后命中。
        assert.is_nil(GrillRules.anchor_in_range(player(100, 52.6), {}))
        local scaled = require('common.body_scale').derive(3).InteractRange
        assert.same('Z3_Grill', (GrillRules.anchor_in_range(player(100, 56, scaled), {})))
    end)

    it('test_missing_baked_anchor_rejects_instead_of_falling_back_to_scene_units', function()
        ZoneMarkers.anchor_positions = {}
        local player = { Character = { Position = { x = 0, y = 1, z = 0 },
            GetAttribute = function() return nil end } }
        assert.is_nil(GrillRules.anchor_in_range(player, {}))
    end)

    it('test_adjacent_facilities_show_single_nearest_prompt_and_respect_body_scale', function()
        local saved_ready = ZoneMarkers.ready
        ZoneMarkers.ready = true
        ZoneMarkers.anchor_positions.Z1_Shop = { x = 0, y = 1, z = 0 }
        ZoneMarkers.anchor_positions.Z1_Fisherman = { x = 4, y = 1, z = 0 }
        local normal_char = { GetAttribute = function() return nil end }

        assert.same('Z1_Shop', InteractPromptArbiter.nearest_anchor({ x = 1, y = 1, z = 0 }, normal_char))
        assert.is_true(InteractPromptArbiter.is_exclusive({ x = 1, y = 1, z = 0 }, normal_char, 'Z1_Shop'))
        assert.is_false(InteractPromptArbiter.is_exclusive({ x = 1, y = 1, z = 0 }, normal_char, 'Z1_Fisherman'))

        assert.same('Z1_Fisherman', InteractPromptArbiter.nearest_anchor({ x = 3, y = 1, z = 0 }, normal_char))
        assert.is_false(InteractPromptArbiter.is_exclusive({ x = 3, y = 1, z = 0 }, normal_char, 'Z1_Shop'))
        assert.is_true(InteractPromptArbiter.is_exclusive({ x = 3, y = 1, z = 0 }, normal_char, 'Z1_Fisherman'))

        assert.is_nil(InteractPromptArbiter.nearest_anchor({ x = -7, y = 1, z = 0 }, normal_char))
        local big_range = require('common.body_scale').derive(3).InteractRange
        local big_char = { GetAttribute = function() return big_range end }
        assert.same('Z1_Shop', InteractPromptArbiter.nearest_anchor({ x = -7, y = 1, z = 0 }, big_char))
        assert.is_false(InteractPromptArbiter.is_exclusive({ x = -7, y = 1, z = 0 }, big_char, 'Z1_Fisherman'))
        ZoneMarkers.ready = saved_ready
    end)
end)
