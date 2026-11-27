-- #406 只读几何导出器契约与 ZoneMarkers.resolve_baked 单测
local Exporter = require('tools.export_scene_geometry')
local ZoneMarkers = require('common.zone_markers')
local GameCfg = require('common.game_cfg')
local SceneGeometry = require('common.cfg.scene_geometry')
local SceneWaterGeometry = require('common.cfg.scene_water_geometry')
local ZoneFixtures = require('tests.support.zone_fixtures')

local function clone_raw_from_baked()
    local raw = { zone_counts = {}, items = {} }
    for index, z in ipairs(SceneGeometry.zones) do
        raw.zone_counts[z.name] = 1
        local prefix = 'Z' .. index .. '_'
        for side, w in pairs(z.boundary) do
            raw.items[#raw.items + 1] = {
                zone = z.name,
                name = prefix .. 'Boundary' .. side,
                pos = { x = w.x, y = w.y, z = w.z },
                size = { x = w.sx, y = w.sy, z = w.sz },
            }
        end
        for pname, p in pairs(z.points) do
            raw.items[#raw.items + 1] = {
                zone = z.name,
                name = pname,
                pos = { x = p.x, y = p.y, z = p.z },
                size = { x = 1, y = 1, z = 1 },
            }
        end
        for _, row in ipairs(SceneWaterGeometry.zones[index]) do
            raw.items[#raw.items + 1] = {
                zone = z.name,
                name = row[1],
                pos = { x = row[2], y = row[3], z = row[4] },
                size = { x = row[5], y = row[6], z = row[7] },
            }
        end
    end
    return raw
end

describe('scene_geometry_export (#406)', function()
    after_each(function()
        ZoneFixtures.apply(GameCfg)
    end)

    it('test_baked_geometry_resolves_all_7_zones_189_waters_17_baits_and_anchors', function()
        local snapshot = ZoneMarkers.resolve_baked(GameCfg)
        assert.is_true(snapshot.ready)
        assert.same(189, #snapshot.Waters)
        assert.same(17, #snapshot.BaitSpots)
        assert.same(6, #snapshot.ferry_routes)
        assert.is_not_nil(ZoneMarkers.anchor_position('Z1_Shop'))
        assert.is_not_nil(ZoneMarkers.anchor_position('Z2_Fisherman'))
        assert.is_not_nil(ZoneMarkers.anchor_position('Z1_FerryOut'))
        assert.is_not_nil(ZoneMarkers.anchor_position('Z2_FerryReturn'))
        assert.is_nil(ZoneMarkers.anchor_position('TGUnitShop'))
        assert.is_nil(ZoneMarkers.anchor_position('FerryBoat'))
    end)

    it('test_exporter_rejects_missing_duplicate_oob_illegal_size_and_overlapping_water', function()
        -- 1. 缺标记阻断
        local missing = clone_raw_from_baked()
        for i, item in ipairs(missing.items) do
            if item.name == 'Z1_Shop' then table.remove(missing.items, i) break end
        end
        assert.error_matches(function() Exporter.validate_and_build(missing, GameCfg) end, '区域标记缺失: Z1_Shop', nil, true)

        -- 2. 重名阻断
        local dup = clone_raw_from_baked()
        dup.items[#dup.items + 1] = {
            zone = '01 鱼塘', name = 'Z1_Safe',
            pos = { x = -616, y = 1, z = 68 }, size = { x = 1, y = 1, z = 1 },
        }
        assert.error_matches(function() Exporter.validate_and_build(dup, GameCfg) end, '区域标记重名: Z1_Safe', nil, true)

        -- 3. 越出本区边界阻断
        local oob = clone_raw_from_baked()
        for _, item in ipairs(oob.items) do
            if item.name == 'Z1_Lottery' then item.pos.x = 9999 break end
        end
        assert.error_matches(function() Exporter.validate_and_build(oob, GameCfg) end, '区域标记越出本区边界', nil, true)

        -- 4. 非法尺寸阻断
        local bad_size = clone_raw_from_baked()
        for _, item in ipairs(bad_size.items) do
            if item.name == 'Z1_BoundaryWest' then item.size.x = 0 break end
        end
        assert.error_matches(function() Exporter.validate_and_build(bad_size, GameCfg) end, '区域标记尺寸非法', nil, true)

        -- 5. 水域重叠阻断
        local overlap = clone_raw_from_baked()
        local w1 = SceneWaterGeometry.zones[1][1]
        overlap.items[#overlap.items + 1] = {
            zone = '01 鱼塘', name = 'Z1_Water999',
            pos = { x = w1[2], y = w1[3], z = w1[4] },
            size = { x = w1[5], y = w1[6], z = w1[7] },
        }
        assert.error_matches(function() Exporter.validate_and_build(overlap, GameCfg) end, '区域水域重叠', nil, true)
    end)

    it('test_exporter_render_is_deterministic_and_idempotent', function()
        local baked = Exporter.validate_and_build(clone_raw_from_baked(), GameCfg)
        local g1 = Exporter.render_geometry_lua(baked)
        local g2 = Exporter.render_geometry_lua(baked)
        local w1 = Exporter.render_water_lua(baked)
        local w2 = Exporter.render_water_lua(baked)
        assert.same(g1, g2)
        assert.same(w1, w2)
    end)
end)
