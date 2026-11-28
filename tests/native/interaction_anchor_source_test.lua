-- #410 交互锚点单一来源、BodyScale 动态半径与跨设施互斥集成测试（ADR-0013）。
local ZoneMarkers = require('common.zone_markers')
local BodyScale = require('common.body_scale')
local GameCfg = require('common.game_cfg')
local GrillRules = require('server.world_host.grill_rules')
local InteractPromptArbiter = require('client.views.interact_prompt_arbiter')
local ClientStore = require('client.store.client_store')
local RootView = require('client.views.root_view')
local ShopView = require('client.views.shop_view')
local LotteryInteraction = require('client.views.lottery_interaction')
local Eui = require('tests.support.eui_double')

describe('interaction_anchor_source (#410)', function()
    local saved_positions, saved_ready, saved_vec3

    before_each(function()
        saved_positions = ZoneMarkers.anchor_positions
        saved_ready = ZoneMarkers.ready
        saved_vec3 = rawget(_G, 'Vector3')
        _G.Vector3 = { New = function(x, y, z) return { x = x, y = y, z = z } end }
        ZoneMarkers.ready = true
        ZoneMarkers.anchor_positions = {
            Z3_Grill = { x = 100, y = 2, z = 50 },
        }
    end)

    after_each(function()
        ZoneMarkers.anchor_positions = saved_positions
        ZoneMarkers.ready = saved_ready
        _G.Vector3 = saved_vec3
    end)

    it('test_grill_anchor_uses_baked_position_and_body_scale_radius', function()
        local function player(x, z, interact_range)
            return { Character = { Position = { x = x, y = 2, z = z },
                GetAttribute = function(_, key) return key == 'InteractRange' and interact_range or nil end } }
        end
        local name, anchor = GrillRules.anchor_in_range(player(100, 52.4), {})
        assert.same('Z3_Grill', name)
        assert.same(100, anchor.Position.x)
        assert.same(50, anchor.Position.z)

        assert.is_nil(GrillRules.anchor_in_range(player(100, 52.6), {}))
        local scaled = BodyScale.derive(3).InteractRange
        assert.same('Z3_Grill', (GrillRules.anchor_in_range(player(100, 56, scaled), {})))
    end)

    it('test_missing_baked_anchor_rejects_instead_of_falling_back_to_scene_units', function()
        ZoneMarkers.anchor_positions = {}
        local player = { Character = { Position = { x = 0, y = 1, z = 0 },
            GetAttribute = function() return nil end } }
        assert.is_nil(GrillRules.anchor_in_range(player, {}))
    end)

    it('test_arbiter_rejects_unready_or_unknown_anchor_without_silent_bypass', function()
        ZoneMarkers.anchor_positions = { Z1_Shop = { x = 0, y = 1, z = 0 } }
        local char = { GetAttribute = function() return nil end }
        assert.is_false(InteractPromptArbiter.is_exclusive({ x = 0, y = 1, z = 0 }, char, nil))
        assert.is_false(InteractPromptArbiter.is_exclusive({ x = 0, y = 1, z = 0 }, char, ''))
        assert.is_false(InteractPromptArbiter.is_exclusive({ x = 0, y = 1, z = 0 }, char, 'UnknownAnchor'))
        ZoneMarkers.ready = false
        assert.is_false(InteractPromptArbiter.is_exclusive({ x = 0, y = 1, z = 0 }, char, 'Z1_Shop'))
    end)

    it('test_adjacent_facilities_show_single_nearest_prompt_and_respect_body_scale', function()
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
        local big_range = BodyScale.derive(3).InteractRange
        local big_char = { GetAttribute = function() return big_range end }
        assert.same('Z1_Shop', InteractPromptArbiter.nearest_anchor({ x = -7, y = 1, z = 0 }, big_char))
        assert.is_false(InteractPromptArbiter.is_exclusive({ x = -7, y = 1, z = 0 }, big_char, 'Z1_Fisherman'))
    end)

    it('test_lottery_view_and_shop_view_stay_mutually_exclusive_under_body_scale_overlap', function()
        ZoneMarkers.anchor_positions = {
            Z1_Shop = { x = 0, y = 1, z = 0 },
            Z1_Lottery = { x = 10, y = 1, z = 0 },
        }
        local store, writer = ClientStore.new({ initial_now = 1000 })
        local root = Eui.node({ Name = 'UIRoot' })
        local lottery_nodes = {}
        local big_range = BodyScale.derive(3).InteractRange
        local big_char = {
            Position = { x = 2, y = 1, z = 0 },
            GetAttribute = function(_, key) return key == 'InteractRange' and big_range or nil end,
        }
        local view = RootView.mount(root, store, {
            docks = {
                shop = ShopView.bubble_spec({
                    anchors = { { stand = GameCfg.Shop.Stands[1], name = 'Z1_Shop', position = { x = 0, y = 1, z = 0 } } },
                }),
            },
            hud = { LotteryInteraction.spec() },
            services = {
                local_character = function() return big_char end,
                find_lottery_anchor = function(name)
                    local pos = ZoneMarkers.anchor_position(name)
                    return pos and { Name = name, Position = pos } or nil
                end,
                create_lottery_scene_node = function(_, anchor)
                    local node = Eui.node({ Name = 'LotteryBubble_' .. anchor.Name, Visible = false })
                    lottery_nodes[anchor.Name] = node
                    return node
                end,
            },
            create_node = function(kind, props)
                return Eui.node({
                    Kind = kind, Name = props and props.Name, Parent = props and props.Parent,
                    Text = props and (props.Text or props.ButtonText) or '',
                    TouchEnabled = kind == 'EUIButton',
                })
            end,
        })

        writer:update_spatial({ x = 2, y = 1, z = 0 }, big_char)
        assert.is_not_nil(root:FindFirstChild('BtnShopEnter_Z1_Shop', true))
        assert.is_false(lottery_nodes.Z1_Lottery.Visible)

        big_char.Position = { x = 8, y = 1, z = 0 }
        writer:update_spatial({ x = 8, y = 1, z = 0 }, big_char)
        assert.is_nil(root:FindFirstChild('BtnShopEnter_Z1_Shop', true))
        assert.is_true(lottery_nodes.Z1_Lottery.Visible)

        view.dispose()
    end)
end)
