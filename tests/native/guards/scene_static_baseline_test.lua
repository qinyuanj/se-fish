-- #411 场景静态化基线守卫：把本轮压降后的「编辑态导出几何 + 运行期只读锚点」锁进自动化检查。
-- 失败方式先列：
--   1. 导出只读几何表的区 / 点位 / 水域数量漂移（场景写入漏项、误删或重复导出）；
--   2. 水域 SurfaceY 与玩法水面高度脱节，或 7 区水域重叠（ADR-0013 的硬约束）；
--   3. 交互锚点从导出表缺失，运行期只能拿到 nil，交互静默失效；
--   4. 运行期交互点重新依赖场景单位（静态化后必然查不到，回归静默）；
--   5. 7 个钓鱼佬外观与锚点混用（锚点已静态化，客户端脉冲反馈会失去宿主）。
-- 口径：本守卫只读导出表做纯计算，不调用 ZoneMarkers.resolve_baked，避免污染其他用例的全局快照；
-- 活体场景清点由 tools/export_scene_geometry.lua --check 另行守门。
local ZoneMarkers = require('common.zone_markers')
local GameCfg = require('common.game_cfg')
local SceneGeometry = require('common.cfg.scene_geometry')
local SceneWaterGeometry = require('common.cfg.scene_water_geometry')
local LuaSourceStrip = require('tests.support.lua_source_strip')

local function read_source(path)
    local handle = assert(io.open(path, 'rb'))
    local text = handle:read('*a')
    handle:close()
    return text
end

local function count_points(zones)
    local counts = {}
    for _, zone in ipairs(zones) do
        for name in pairs(zone.points) do
            local kind = name:match('^Z%d+_([%a]+)%d*$') or 'other'
            counts[kind] = (counts[kind] or 0) + 1
        end
    end
    return counts
end

local function water_box(row)
    local name, x, y, z, sx, sy, sz = row[1], row[2], row[3], row[4], row[5], row[6], row[7]
    return { name = name, cx = x, cz = z, hx = sx / 2, hz = sz / 2, surface_y = y + sy }
end

local function boxes_overlap(a, b)
    return math.abs(a.cx - b.cx) < (a.hx + b.hx) and math.abs(a.cz - b.cz) < (a.hz + b.hz)
end

describe('scene_static_baseline (#411)', function()
    it('test_baked_geometry_keeps_7_zones_28_walls_62_markers_and_189_waters', function()
        assert.same(7, #SceneGeometry.zones)

        local walls = 0
        for _, zone in ipairs(SceneGeometry.zones) do
            for _, side in ipairs({ 'West', 'East', 'South', 'North' }) do
                local wall = zone.boundary[side]
                assert.is_not_nil(wall, '缺少边界墙: ' .. zone.name .. '/' .. side)
                assert.is_true(wall.sx > 0 and wall.sy > 0 and wall.sz > 0)
                walls = walls + 1
            end
        end
        assert.same(28, walls)

        local points = count_points(SceneGeometry.zones)
        assert.same(7, points.Safe)
        assert.same(6, points.FerryOut)
        assert.same(6, points.FerryReturn)
        assert.same(7, points.Lottery)
        assert.same(5, points.Grill)
        assert.same(17, points.Bait)
        assert.same(7, points.Shop)
        assert.same(7, points.Fisherman)
        assert.same(62, points.Safe + points.FerryOut + points.FerryReturn
            + points.Lottery + points.Grill + points.Bait + points.Shop + points.Fisherman)

        local per_zone_waters = { 33, 35, 46, 19, 22, 5, 29 }
        local total = 0
        for index, expected in ipairs(per_zone_waters) do
            assert.same(expected, #SceneWaterGeometry.zones[index], '第 ' .. index .. ' 区水域数量漂移')
            total = total + expected
        end
        assert.same(189, total)
    end)

    it('test_all_waters_share_play_surface_and_never_overlap', function()
        local boxes = {}
        for _, rows in ipairs(SceneWaterGeometry.zones) do
            for _, row in ipairs(rows) do boxes[#boxes + 1] = water_box(row) end
        end
        assert.same(189, #boxes)
        for _, box in ipairs(boxes) do
            assert.near(-0.25, box.surface_y, 1e-4, '水域水面高度必须与玩法 SurfaceY 对齐: ' .. box.name)
        end
        local checked = 0
        for i = 1, #boxes do
            for j = i + 1, #boxes do
                assert.is_false(boxes_overlap(boxes[i], boxes[j]),
                    '水域重叠: ' .. boxes[i].name .. ' / ' .. boxes[j].name)
                checked = checked + 1
            end
        end
        assert.same(189 * 188 / 2, checked)
    end)

    it('test_every_contract_anchor_is_present_in_baked_geometry', function()
        for _, entry in ipairs(ZoneMarkers.contract(GameCfg)) do
            if entry.role ~= 'Boundary' then
                local zone = SceneGeometry.zones[entry.zone_index]
                local position = zone and zone.points[entry.Name]
                assert.is_not_nil(position, '导出几何缺少契约标记: ' .. entry.Name)
                assert.is_number(position.x)
                assert.is_number(position.y)
                assert.is_number(position.z)
            end
        end
        for index, route in ipairs(GameCfg.Ferry.Routes) do
            assert.is_not_nil(SceneGeometry.zones[index].points[route.Outbound.AnchorName])
            assert.is_not_nil(SceneGeometry.zones[index + 1].points[route.Return.AnchorName])
        end
    end)

    it('test_interaction_points_resolve_from_anchor_snapshot_only', function()
        local InteractionPoints = require('server.world_host.interaction_points')
        local saved = ZoneMarkers.anchor_positions
        local ok, err = pcall(function()
            ZoneMarkers.anchor_positions = { Z1_Shop = { x = 12, y = 3, z = 4 } }
            local anchor = InteractionPoints:find_anchor('Z1_Shop')
            assert.is_not_nil(anchor)
            assert.same('Z1_Shop', anchor.Name)
            assert.same(12, anchor.Position.x)
            assert.same(4, anchor.Position.z)
            assert.is_nil(InteractionPoints:find_anchor('TGUnitShop'))
        end)
        ZoneMarkers.anchor_positions = saved
        assert.is_true(ok, tostring(err))

        -- 7 个钓鱼佬外观与锚点分离：模型名齐全、锚点来自导出表（模型保持非静态，见 #407）。
        assert.same(7, #GameCfg.Interact.Fishermen)
        for _, npc in ipairs(GameCfg.Interact.Fishermen) do
            assert.is_not_nil(npc.ModelName)
            assert.is_true(npc.ModelName ~= npc.AnchorNames[1])
        end
    end)

    it('test_runtime_anchor_consumers_do_not_search_scene_units', function()
        for _, path in ipairs({
            'server/world_host/interaction_points.lua',
            'server/world_host/grill_rules.lua',
        }) do
            local code = LuaSourceStrip.strip_comments_and_strings(read_source(path))
            assert.is_nil(code:match('FindFirstChild%s*%('),
                '交互判定不得再按名查场景单位（静态化后查不到）: ' .. path)
        end

        -- client/main.lua 白名单：只允许对非静态钓鱼佬外观（npc.ModelName）调用 1 次 wait_for_child，
        -- 严禁对任何交互锚点调用 wait_for_child 或 FindFirstChild。
        local client_code = LuaSourceStrip.strip_comments_and_strings(read_source('client/main.lua'))
        assert.is_not_nil(client_code:match('ZoneMarkers%.anchor_position%s*%('))
        local wait_calls = {}
        for args in client_code:gmatch('wait_for_child%s*%(([^%)]*)%)') do
            wait_calls[#wait_calls + 1] = args:gsub('%s+', ' ')
        end
        assert.same({ 'World, npc.ModelName' }, wait_calls,
            'client/main.lua 仅允许查找非静态钓鱼佬外观 npc.ModelName')
        assert.is_nil(client_code:match('FindFirstChild%s*%('),
            'client/main.lua 不得再调用 FindFirstChild 挂载交互气泡')

        -- 全部 5 类客户端交互视图均接入跨设施互斥仲裁器（#410）。
        for _, view_path in ipairs({
            'client/views/shop_view.lua',
            'client/views/fisherman_view.lua',
            'client/views/grill_view.lua',
            'client/views/ferry_view.lua',
            'client/views/lottery_interaction.lua',
        }) do
            local view_code = LuaSourceStrip.strip_comments_and_strings(read_source(view_path))
            assert.is_not_nil(view_code:match('InteractPromptArbiter%.is_exclusive%s*%('),
                '交互视图缺少跨设施互斥校验: ' .. view_path)
        end
    end)

    it('test_legacy_six_anchor_names_never_reenter_production_code', function()
        local seam = require('tools.seam')
        local roots = { 'client', 'common', 'server' }
        local legacy = {
            'TGUnitShop', 'TGUnitShopShrimp',
            'TGUnitFish', 'TGUnitFishShrimp',
            'FerryBoat',
        }
        local violations = {}
        for _, root in ipairs(roots) do
            for _, rel_path in ipairs(seam.list_files(root)) do
                local full = root .. '/' .. rel_path
                if full:match('%.lua$') and not full:find('/packages/', 1, true) then
                    local src = read_source(full)
                    for _, old_name in ipairs(legacy) do
                        if src:find(old_name, 1, true) then
                            violations[#violations + 1] = full .. ' 包含旧锚点名 ' .. old_name
                        end
                    end
                    for pos in src:gmatch('()FerryReturn') do
                        local prev = pos > 1 and src:sub(pos - 1, pos - 1) or ''
                        local after = src:sub(pos, math.min(#src, pos + 40))
                        -- 排除 Z2_FerryReturn..Z7_FerryReturn 及 zone_markers 契约角色声明 'FerryReturn', route.Return
                        if prev ~= '_' and not (full == 'common/zone_markers.lua' and after:find("FerryReturn', route.Return", 1, true)) then
                            violations[#violations + 1] = full .. ' 包含独立旧锚点名 FerryReturn'
                            break
                        end
                    end
                end
            end
        end
        assert.same({}, violations)
    end)
end)
