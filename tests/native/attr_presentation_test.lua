-- #89 迁移（原 tests/gameplay/attr_presentation_test.lua），#297-B 迁入 Spoke CameraZoomView：
-- 失败方式：派生范围无消费者、非法复制属性扩大距离、相机覆盖其他模式、角色重建残留。
describe('TestAttrPresentation', function()
    -- 相机刷新尊重其他拥有者，清理时恢复
    it('test_camera_rebuild_restores_old_camera_and_uses_new_character_projection', function()
        local CameraZoomView = require('client.Views.CameraZoomView')
        local ctrl = CameraZoomView.new_controller()
        local first = { GetAttribute = function() return 39 end }
        local second = { GetAttribute = function() return 13 end }
        local camera = { Distance = 8, TrackingUnit = first }
        assert.is_true(ctrl:refresh(first, camera))
        camera.TrackingUnit = second
        assert.is_true(ctrl:refresh(second, camera))
        assert.same(13, camera.Distance)
        ctrl:release()
        assert.same(8, camera.Distance)
    end)

    -- 相机刷新尊重外部改动（他人拥有）并在清理后恢复；新实例不残留上一份
    it('test_camera_refresh_respects_other_owner_and_restores_on_stop', function()
        local CameraZoomView = require('client.Views.CameraZoomView')
        local ctrl = CameraZoomView.new_controller()
        local character = { GetAttribute = function() return 52 end }
        local camera = { Distance = 8, TrackingUnit = character }
        assert.is_true(ctrl:refresh(character, camera))
        assert.same(39, camera.Distance)
        camera.Distance = 12
        assert.is_false(ctrl:refresh(character, camera))
        assert.same(12, camera.Distance)
        ctrl:release()
        assert.same(12, camera.Distance)
        local fresh = CameraZoomView.new_controller()
        camera.Distance = 8
        assert.is_true(fresh:refresh(character, camera))
        fresh:release()
        assert.same(8, camera.Distance)
    end)

    -- 交互半径按体型派生缩放，非法属性回落基础半径
    it('test_interaction_radius_scales_and_falls_back_for_invalid_attributes', function()
        local body = require('common.body_scale')
        local value = body.Derive(3).InteractRange
        local character = { GetAttribute = function() return value end }
        assert.same(12, body.InteractionRadius(character, 4))
        value = math.huge
        assert.same(4, body.InteractionRadius(character, 4))
        value = body.Derive(100).InteractRange
        assert.same(12, body.InteractionRadius(character, 4))
    end)

    -- 服务端判定按体型缩放半径，同时保留 slack；没有角色时拒绝
    it('test_server_range_scales_radius_but_keeps_slack_and_rejects_missing_character', function()
        local mgr = require('server.WorldHost.InteractionPoints')
        local anchor = { Position = { x = 0, z = 0 } }
        mgr.FindAnchor = function() return anchor end
        local value = require('common.body_scale').Derive(3).InteractRange
        local character = { Position = { x = 12.5, z = 0 }, GetAttribute = function() return value end }
        local p = { Character = character }
        local point = { AnchorName = 'test', Radius = 4, Slack = 0.5 }
        assert.same(anchor, mgr:InRange(p, point))
        character.Position.x = 12.51
        assert.is_nil(mgr:InRange(p, point))
        value = math.huge
        character.Position.x = 4.5
        assert.same(anchor, mgr:InRange(p, point))
        character.Position.x = 4.51
        assert.is_nil(mgr:InRange(p, point))
        p.Character = nil
        assert.is_nil(mgr:InRange(p, point))
    end)
end)
